# Prepare the domain controller for a golden image build, and publish the build's files (PLAN.md, phase 2;
# docs/image.md):
# - the Windows ADK and its WinPE add-on, and WinPE with the driver pack, served as http://<dc>/boot/winpe/boot.wim;
# - the install share, \\<dc>\install: the Windows media from the CD drive, the driver pack and the guest agent;
# - for this build: the answer files on the share, the share's account enabled with a new password, WinPE's startup
#   script (holding that password) over HTTP, and the build VM's iPXE script and DHCP reservation.
# Takes the image's password from servers\secret.txt. Run as admin by image/build.sh, which runs cleanup.ps1 when the
# build ends. Safe to re-run: the ADK, the downloads, the media and WinPE are made once.
param(
  [Parameter(Mandatory)][string]$Mac,          # the build VM's
  [Parameter(Mandatory)][string]$InitiatorIqn, # the build VM's, which the build target accepts
  [Parameter(Mandatory)][string]$TargetIqn,    # the build target's
  [string]$Updates                             # "updates" to install Windows updates in the image
)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"
$password = Read-Secret # first, so that it's deleted whatever happens next
if ($password -notmatch '^[A-Za-z0-9]{16,}$') { throw 'need the image password, 16+ letters and digits, in secret.txt' }
Wait-ServicingIdle

$share = $s.InstallShare
$account = "$($s.NetbiosName)\$($s.ShareAccount)"
$adk = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit"
$pe = "$adk\Windows Preinstallation Environment\amd64"

# Downloads a pinned file into a new temporary folder, and returns its path. Not as a browser: fedorapeople.org answers
# browsers, and Windows PowerShell's default user agent looks like one, with a proof-of-work page (Anubis).
function Get-Pinned($url, $sha256) {
  $dir = Join-Path $env:TEMP "diskless-$(Get-Random)"
  New-Item -ItemType Directory $dir | Out-Null
  $file = Join-Path $dir ([uri]$url).Segments[-1]
  Invoke-WebRequest $url -OutFile $file -UseBasicParsing -UserAgent 'windows-scsi-boot (PowerShell)'
  $hash = (Get-FileHash $file -Algorithm SHA256).Hash
  if ($hash -ne $sha256) {
    Remove-Item $dir -Recurse -Force
    throw "$url`: SHA-256 $hash, expected $sha256"
  }
  $file
}

# A file from the repo with its @NAME@ values filled in. Windows' cmd wants CRLF and no byte-order mark; iPXE wants LF.
function Expand-Template($from, $to, $values, [switch]$Cmd) {
  $text = Get-Content $from -Raw
  foreach ($name in $values.Keys) { $text = $text.Replace("@$name@", $values[$name]) }
  if ($text -match '@[A-Z_]+@') { throw "$from`: no value for $($Matches[0])" }
  if ($Cmd) { $text = $text -replace '\r?\n', "`r`n" }
  [IO.File]::WriteAllText($to, $text, [Text.UTF8Encoding]::new($false))
}

# A password for the share's account, which WinPE gets in plain text: random, and new for each build
function New-Password {
  $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
  $bytes = [byte[]]::new(24)
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  'Aa1' + -join ($bytes | ForEach-Object { $chars[$_ % $chars.Count] }) # the domain wants upper, lower and digits
}

Step 'Windows ADK and its WinPE add-on'
# ADK 10.1.26100.9457 (September 2026), for Windows 11 24H2 and later. The installers fetch the rest from Microsoft.
$installers = @(
  @{ Url = 'https://download.microsoft.com/download/8e0c0f5a-abb5-4358-a51b-168eb40b1590/adk/adksetup.exe'
     Sha256 = 'AC6A930FDB5C2980BA5FEFE606D47EDAAFCF5F647B4337411500D158EA77300F'
     Feature = 'OptionId.DeploymentTools'; Installed = "$adk\Deployment Tools\DandISetEnv.bat" }
  @{ Url = 'https://download.microsoft.com/download/a4a79e7a-f085-41c4-aebf-2538fd000790/adkwinpeaddons/adkwinpesetup.exe'
     Sha256 = 'D4DE67ACC83DE253CCC941DD0590808D83726BDD8EA768A374A7BEAFF7949D6A'
     Feature = 'OptionId.WindowsPreinstallationEnvironment'; Installed = "$pe\en-us\winpe.wim" }
)
foreach ($i in $installers) {
  if (Test-Path $i.Installed) { continue }
  $exe = Get-Pinned $i.Url $i.Sha256
  $p = Start-Process $exe "/quiet /norestart /ceip off /features $($i.Feature)" -Wait -PassThru
  if ($p.ExitCode -notin 0, 3010) { throw "$(Split-Path $exe -Leaf) exited with $($p.ExitCode)" }
  if (-not (Test-Path $i.Installed)) { throw "$(Split-Path $exe -Leaf) didn't install $($i.Installed)" }
  Remove-Item (Split-Path $exe) -Recurse -Force
}

Step "install share $share"
New-Item -ItemType Directory -Force "$share\drivers", "$share\tools" | Out-Null
$media = "$share\media"
if (-not (Test-Path "$media\sources\install.wim")) {
  $cd = Get-Volume | Where-Object { $_.DriveType -eq 'CD-ROM' -and $_.DriveLetter -and
    (Test-Path "$($_.DriveLetter):\sources\install.wim") } | Select-Object -First 1
  if (-not $cd) { throw "no Windows media in a CD drive (the ISO in lab/lab.auto.tfvars)" }
  robocopy "$($cd.DriveLetter):\" $media /e /r:2 /w:5 /njh /njs /ndl /nfl /np | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "copying the media from $($cd.DriveLetter): failed ($LASTEXITCODE)" }
  attrib -r "$media\*" /s /d # the CD's read-only attribute
}
$image = Get-WindowsImage -ImagePath "$media\sources\install.wim" -Index $s.ImageIndex
"media: $($image.ImageName), $($image.Version)"

foreach ($d in (Import-PowerShellDataFile "$PSScriptRoot\..\drivers.psd1").Drivers) {
  $dir = "$share\drivers\$($d.Name)"
  if (Test-Path $dir) { continue }
  "driver pack: $($d.Name)"
  $file = Get-Pinned $d.Url $d.Sha256
  $tmp = "$dir.tmp"
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory $tmp | Out-Null
  switch -Wildcard ($file) {
    '*.iso' {
      $iso = (Mount-DiskImage $file -PassThru | Get-Volume).DriveLetter + ':\'
      try {
        foreach ($folder in Get-Item "$iso$($d.Folders)") {
          Copy-Item $folder.FullName "$tmp\$($folder.Parent.Parent.Name)" -Recurse # <driver>\w11\amd64 as <driver>
        }
        foreach ($tool in @($d.Tools)) { if ($tool) { Copy-Item "$iso$tool" "$share\tools" -Force } }
      } finally { Dismount-DiskImage $file | Out-Null }
    }
    '*.cab' { expand.exe $file -F:* $tmp | Out-Null; if ($LASTEXITCODE) { throw "expanding $file" } }
    default { throw "$file`: an .iso or a .cab" }
  }
  if (-not (Get-ChildItem $tmp -Recurse -Filter *.inf)) { throw "no drivers in $($d.Name)" }
  attrib -r "$tmp\*" /s /d
  Rename-Item $tmp (Split-Path $dir -Leaf)
  Remove-Item (Split-Path $file) -Recurse -Force
}

Step "share account $account, with a new password"
Import-Module ActiveDirectory
$sharePassword = New-Password
$secure = ConvertTo-SecureString $sharePassword -AsPlainText -Force
if (-not (Get-ADUser -Filter "SamAccountName -eq '$($s.ShareAccount)'")) {
  New-ADUser $s.ShareAccount -SamAccountName $s.ShareAccount -AccountPassword $secure -CannotChangePassword $true `
    -PasswordNeverExpires $true `
    -Description 'Reads the install share for WinPE during golden image builds (windows-scsi-boot image/)'
} else {
  Set-ADAccountPassword $s.ShareAccount -Reset -NewPassword $secure
}
Enable-ADAccount $s.ShareAccount
if (-not (Get-SmbShare install -ErrorAction SilentlyContinue)) {
  New-SmbShare install -Path $share -ReadAccess $account -FullAccess 'BUILTIN\Administrators' `
    -Description 'Windows media and drivers for WinPE (windows-scsi-boot image/)' | Out-Null
}

Step 'WinPE'
$winpe = "$($s.BootFiles)\winpe\boot.wim"
if (-not (Test-Path $winpe)) {
  $work = 'C:\WinPE'
  $mount = "$work\mount"
  if (Test-Path $mount) { Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null }
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory $mount | Out-Null
  Copy-Item "$pe\en-us\winpe.wim" "$work\winpe.wim"
  Mount-WindowsImage -ImagePath "$work\winpe.wim" -Index 1 -Path $mount | Out-Null
  try {
    # WMI and SecureStartup for Windows 11's setup; PowerShell and its prerequisites, in order, with the storage and
    # DISM cmdlets, for scripts and recovery
    foreach ($oc in 'WMI', 'SecureStartup', 'NetFx', 'Scripting', 'PowerShell', 'StorageWMI', 'DismCmdlets') {
      foreach ($cab in "$pe\WinPE_OCs\WinPE-$oc.cab", "$pe\WinPE_OCs\en-us\WinPE-${oc}_en-us.cab") {
        if (Test-Path $cab) { Add-WindowsPackage -Path $mount -PackagePath $cab | Out-Null }
      }
    }
    # The pack's NIC drivers: WinPE reaches the iSCSI disk and the share through them. WinPE connects the iSCSI disk
    # in the iBFT only through a NIC whose driver is marked to load when booting from the network (BootFlags 1 in its
    # INF): Intel's are, virtio's and vmxnet3's aren't. So the build VM has an Intel NIC.
    $nics = Get-ChildItem "$share\drivers" -Recurse -Filter *.inf | Where-Object { Select-String -Path $_.FullName -Pattern '^\s*Class\s*=\s*Net\b' -Quiet }
    foreach ($inf in $nics) {
      Add-WindowsDriver -Path $mount -Driver $inf.FullName | Out-Null
      "WinPE driver: $($inf.Name)$(if (Select-String -Path $inf.FullName -Pattern 'BootFlags' -Quiet) { ', network boot' })"
    }
    # Its startup, which fetches and runs a job for the machine from the domain controller (image/winpe/startnet.cmd)
    Expand-Template "$root\image\winpe\startnet.cmd" "$mount\Windows\System32\startnet.cmd" @{ DC = $s.DcAddress } -Cmd
    Dismount-WindowsImage -Path $mount -Save | Out-Null
  } catch { Dismount-WindowsImage -Path $mount -Discard | Out-Null; throw }
  New-Item -ItemType Directory -Force (Split-Path $winpe) | Out-Null
  Export-WindowsImage -SourceImagePath "$work\winpe.wim" -SourceIndex 1 -DestinationImagePath "$work\boot.wim" | Out-Null
  Copy-Item "$work\boot.wim" $winpe # a copy takes the folder's permissions, which IIS needs
  Remove-Item $work -Recurse -Force
}
# wimboot takes the boot manager from the WIM, but not its boot configuration: that's in the ADK's WinPE media
Copy-Item "$pe\Media\EFI\Microsoft\Boot\BCD", "$pe\Media\Boot\boot.sdi" (Split-Path $winpe) -Force
"WinPE: $([math]::Round((Get-Item $winpe).Length / 1MB)) MB"

Step 'the build files'
$values = @{
  IMAGE_INDEX = $s.ImageIndex; PRODUCT_KEY = $s.ProductKey; LOCALE = $s.Locale; UI_LANGUAGE = $s.UILanguage
  TIMEZONE = $s.TimeZone; USER = $s.ImageUser; PASSWORD = $password
  DC = $s.DcAddress; ACCOUNT = $account; SHARE_PASSWORD = $sharePassword
}
# On the share: the answers, which hold the image's password, readable only by admins and the share's account
$build = "$share\build"
Remove-Item $build -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$build\windows" | Out-Null
icacls $build /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' "${account}:(OI)(CI)RX" | Out-Null
Expand-Template "$root\image\windows\autounattend.xml" "$build\autounattend.xml" $values
# What WinPE copies into the new Windows for its first logon
Expand-Template "$root\image\windows\sysprep.xml" "$build\windows\sysprep.xml" $values
Copy-Item "$root\image\windows\firstlogon.ps1", "$root\image\windows\generalize.ps1", "$share\tools\qemu-ga-x86_64.msi" "$build\windows"
Copy-Item "$env:ProgramData\ssh\administrators_authorized_keys" "$build\windows\authorized_keys" # the servers' keys
if ($Updates -eq 'updates') { New-Item "$build\windows\updates" | Out-Null }

# Over HTTP: WinPE's job on the build VM, which holds the share's password (image/winpe/startnet.cmd fetches it)
$id = $Mac.ToLower() -replace ':', '-' # as iPXE's ${net0/mac:hexhyp}, and the DHCP server's client ID
$job = "$($s.BootFiles)\jobs\$id.cmd"
New-Item -ItemType Directory -Force (Split-Path $job) | Out-Null
Expand-Template "$root\image\winpe\build.cmd" $job $values -Cmd
Copy-Item "$root\boot\*.ipxe" $s.BootFiles -Force
# The build VM's own script: the build target, then the build's boot (boot/build.ipxe)
$script = "$($s.BootFiles)\clients\$id.ipxe"
[IO.File]::WriteAllText($script, (@(
  '#!ipxe'
  "# $($s.BuildVm), while image/build.sh builds a golden image. Deleted when the build ends."
  "set initiator-iqn $InitiatorIqn"
  "set root-path iscsi:$($s.SanAddress)::::$TargetIqn"
  'chain ../build.ipxe'
) -join "`n") + "`n")
icacls $s.BootFiles /reset /t /q | Out-Null # IIS's anonymous user must be able to read every file

# A reservation, so the build VM can be found while it builds. Fixed MACs are 02:00 and then the address (lab/main.tf).
$scope = $s.Network.Split('/')[0]
$address = (($Mac -split ':')[2..5] | ForEach-Object { [Convert]::ToInt32($_, 16) }) -join '.'
if (-not (Get-DhcpServerv4Reservation -ScopeId $scope | Where-Object ClientId -eq $id)) {
  Add-DhcpServerv4Reservation -ScopeId $scope -IPAddress $address -ClientId $id -Name $s.BuildVm `
    -Description 'Builds golden images (image/build.sh)'
}

Step 'check'
# What the build VM fetches, as iPXE fetches it: anonymously
foreach ($path in 'build.ipxe', "clients/$id.ipxe", "jobs/$id.cmd", 'winpe/boot.wim', 'winpe/BCD', 'wimboot') {
  $url = "http://$($s.DcAddress)/boot/$path"
  $response = Invoke-WebRequest $url -UseBasicParsing -Method Head
  if ($response.StatusCode -ne 200) { throw "$url returned HTTP $($response.StatusCode)" }
}
"build VM: $($s.BuildVm), $Mac, reserved $address, initiator $InitiatorIqn"
"target: $TargetIqn"
