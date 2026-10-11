# Configure the domain controller once promote.ps1 has made it one (PLAN.md, phase 1; docs/servers.md): DNS, DHCP with
# the network-boot policies, TFTP through WDS and HTTP through IIS for the boot files. Run as the domain's
# Administrator, from a copy of the repo's servers/ and boot/ (setup.sh makes it, and runs this again after a restart it
# asks for). Safe to re-run.
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\common.ps1"

# Pinned releases, checked against the hashes recorded when they were added. Member: the file to take from an archive.
$downloads = @(
  @{ Url = 'https://github.com/ipxe/ipxe/releases/download/v2.0.0/ipxeboot.tar.gz'
     Sha256 = '01A526D4CC791FC30362259C609D6C506CC64A7BDFF51B9A5EB788354E17EEE1'
     Member = 'ipxeboot/x86_64/snponly.efi'; As = 'snponly.efi' }
  # The full iPXE, which drives every NIC: a golden image build with a second NIC chains it (boot/build.ipxe)
  @{ Url = 'https://github.com/ipxe/ipxe/releases/download/v2.0.0/ipxeboot.tar.gz'
     Sha256 = '01A526D4CC791FC30362259C609D6C506CC64A7BDFF51B9A5EB788354E17EEE1'
     Member = 'ipxeboot/x86_64/ipxe.efi'; As = 'ipxe.efi' }
  @{ Url = 'https://github.com/ipxe/wimboot/releases/download/v2.9.0/wimboot'
     Sha256 = '5F067CCDC4D084D5BF77B6C853BD0F8402DFC2B4CD1B103D358993AE97FAE8E3'; As = 'wimboot' }
  # memtest.org publishes this hash too (download/v8.10/sha256sum.txt). The binary is also an x86-64 EFI application.
  @{ Url = 'https://memtest.org/download/v8.10/mt86plus_8.10.binaries.zip'
     Sha256 = '7E6C5162CB84AB959AEB9D13C9CFD6976B0DEC3B34936B73820B20C55EB26C29'
     Member = 'mt86p_810_x86_64'; As = 'memtest.efi' }
)

Step 'waiting for Active Directory'
$deadline = (Get-Date).AddMinutes(15)
while ($true) {
  try { Get-ADDomain | Out-Null; break }
  catch { if ((Get-Date) -gt $deadline) { throw }; Start-Sleep 10 }
}
Wait-ServicingIdle

Step 'Windows Update: installs and restarts only when asked'
Set-UpdatePolicy

Step "admin as a domain and enterprise admin"
# admin came over from the local accounts into the domain's Administrators group only. Enterprise Admins can
# authorise DHCP servers, and the later phases run as admin.
foreach ($group in 'Domain Admins', 'Enterprise Admins') {
  if (-not (Get-ADGroupMember $group | Where-Object SamAccountName -eq 'admin')) { Add-ADGroupMember $group -Members admin }
}

Step 'DNS'
$nic = @(Get-NetAdapter -Physical | Where-Object Status -eq 'Up')[0]
Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $s.DcAddress, '127.0.0.1'
Set-DnsServerForwarder -IPAddress $s.Gateway
$net, $bits = $s.Network -split '/'
$octets = ($net -split '\.')[0..([int]$bits / 8 - 1)]
[array]::Reverse($octets)
$reverse = ($octets -join '.') + '.in-addr.arpa'
if (-not (Get-DnsServerZone $reverse -ErrorAction SilentlyContinue)) {
  Add-DnsServerPrimaryZone -NetworkId $s.Network -ReplicationScope Forest
}

Step 'DHCP'
Install-Feature DHCP
if (-not (Get-ADGroup -Filter "Name -eq 'DHCP Administrators'")) {
  Add-DhcpServerSecurityGroup
  Restart-Service DHCPServer
}
# In a domain, a DHCP server answers only once it's authorised in Active Directory
if (-not (Get-DhcpServerInDC | Where-Object IPAddress -eq $s.DcAddress)) {
  Add-DhcpServerInDC -DnsName "$env:COMPUTERNAME.$($s.DomainName)" -IPAddress $s.DcAddress
}
Set-ItemProperty HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12 ConfigurationState 2 # Server Manager's reminder

$scope = $s.Network.Split('/')[0]
if (-not (Get-DhcpServerv4Scope -ScopeId $scope -ErrorAction SilentlyContinue)) {
  Add-DhcpServerv4Scope -Name 'diskless' -StartRange $s.ScopeStart -EndRange $s.ScopeEnd -SubnetMask $s.SubnetMask -State Active
}
$exclusion = Get-DhcpServerv4ExclusionRange -ScopeId $scope -ErrorAction SilentlyContinue |
  Where-Object StartRange -eq $s.ReservedStart
if ($exclusion -and "$($exclusion.EndRange)" -ne $s.ReservedEnd) {
  Remove-DhcpServerv4ExclusionRange -ScopeId $scope -StartRange $exclusion.StartRange -EndRange $exclusion.EndRange
  $exclusion = $null
}
if (-not $exclusion) {
  Add-DhcpServerv4ExclusionRange -ScopeId $scope -StartRange $s.ReservedStart -EndRange $s.ReservedEnd
  Restart-Service DHCPServer # else it goes on offering addresses it had already offered, and refusing them
}
Set-DhcpServerv4OptionValue -ScopeId $scope -Router $s.Gateway -DnsServer $s.DcAddress -DnsDomain $s.DomainName

# Network boot. UEFI x64 firmware sends vendor class "PXEClient:Arch:00007:UNDI:003016" and gets iPXE over TFTP. iPXE
# then sends user class "iPXE", and gets boot.ipxe over HTTP. iPXE sends the same vendor class too, so its policy comes
# first: for an option both set, the first matching policy's value wins.
if (-not (Get-DhcpServerv4Class 'PXEClient UEFI x64' -ErrorAction SilentlyContinue)) {
  Add-DhcpServerv4Class -Name 'PXEClient UEFI x64' -Type Vendor -Data 'PXEClient:Arch:00007'
}
if (-not (Get-DhcpServerv4Class 'iPXE' -ErrorAction SilentlyContinue)) {
  Add-DhcpServerv4Class -Name 'iPXE' -Type User -Data 'iPXE'
}
if (-not (Get-DhcpServerv4Policy -ScopeId $scope -Name 'iPXE' -ErrorAction SilentlyContinue)) {
  Add-DhcpServerv4Policy -ScopeId $scope -Name 'iPXE' -Condition OR -UserClass EQ, 'iPXE' -ProcessingOrder 1
}
Set-DhcpServerv4OptionValue -ScopeId $scope -PolicyName 'iPXE' -OptionId 67 -Value "http://$($s.DcAddress)/boot/boot.ipxe"
if (-not (Get-DhcpServerv4Policy -ScopeId $scope -Name 'UEFI x64 PXE' -ErrorAction SilentlyContinue)) {
  # The trailing * matches the class's data as a prefix
  Add-DhcpServerv4Policy -ScopeId $scope -Name 'UEFI x64 PXE' -Condition OR -VendorClass EQ, 'PXEClient UEFI x64*' -ProcessingOrder 2
}
Set-DhcpServerv4OptionValue -ScopeId $scope -PolicyName 'UEFI x64 PXE' -OptionId 66 -Value $s.DcAddress
Set-DhcpServerv4OptionValue -ScopeId $scope -PolicyName 'UEFI x64 PXE' -OptionId 67 -Value 'boot\x64\snponly.efi'

Step 'TFTP: WDS, with its PXE responder off'
Install-Feature WDS
# WDS's PXE provider can't set itself up beside a DHCP server on the same machine (0x425), and as it's marked critical,
# its failure stops the whole WDS server, TFTP too. It isn't needed: DHCP hands out the boot file.
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WDSServer\Providers\WDSPXE' IsCritical 0
function Wds { $out = wdsutil @args 2>&1; if ($LASTEXITCODE) { throw "wdsutil $args`n$out" } }
wdsutil /Get-Server /Show:Config 2>&1 | Out-Null # fails until the server is initialised
if ($LASTEXITCODE) { Wds /Initialize-Server "/RemInst:$($s.TftpRoot)" /Standalone }
Wds /Set-Server /AnswerClients:None # never answer PXE
Wds /Set-Server /UseDhcpPorts:No    # leave UDP 67 to the DHCP server
# WDS also makes the DHCP server send option 60 "PXEClient", which sends PXE firmware to WDS's own responder for its
# boot program (boot\x64\wdsmgfw.efi) instead of using option 67
Wds /Set-Server /DhcpOption60:No
if (Get-DhcpServerv4OptionValue -OptionId 60 -ErrorAction SilentlyContinue) { Remove-DhcpServerv4OptionValue -OptionId 60 }
Start-Service WDSServer

Step 'HTTP: IIS, static files under /boot'
Install-Feature Web-Server
Import-Module WebAdministration
New-Item -ItemType Directory -Force "$($s.BootFiles)\clients" | Out-Null
if (-not (Get-WebVirtualDirectory -Site 'Default Web Site' -Name boot)) {
  New-WebVirtualDirectory -Site 'Default Web Site' -Name boot -PhysicalPath $s.BootFiles | Out-Null
}
# IIS serves only the extensions it has MIME types for. "." is files without one, like wimboot and WinPE's BCD. WinPE
# needs .wim and .sdi, and fetches its jobs as .cmd (phase 2).
$types = [ordered]@{ '.ipxe' = 'text/plain'; '.efi' = 'application/octet-stream'; '.' = 'application/octet-stream'
  '.wim' = 'application/octet-stream'; '.sdi' = 'application/octet-stream'; '.bcd' = 'application/octet-stream'
  '.cmd' = 'text/plain' }
$at = @{ PSPath = 'MACHINE/WEBROOT/APPHOST'; Location = 'Default Web Site/boot'; Filter = 'system.webServer/staticContent' }
foreach ($ext in $types.Keys) {
  if (-not (Get-WebConfigurationProperty @at -Name collection | Where-Object fileExtension -eq $ext)) {
    Add-WebConfigurationProperty @at -Name . -Value @{ fileExtension = $ext; mimeType = $types[$ext] }
  }
}

Step 'boot files'
$tmp = Join-Path $env:TEMP 'diskless-downloads'
New-Item -ItemType Directory -Force $tmp | Out-Null
foreach ($d in $downloads) {
  $target = Join-Path $s.BootFiles $d.As
  if (Test-Path $target) { continue } # to take a new release, change its entry above and delete the file
  $file = Join-Path $tmp (Split-Path $d.Url -Leaf)
  Invoke-WebRequest $d.Url -OutFile $file -UseBasicParsing
  $hash = (Get-FileHash $file -Algorithm SHA256).Hash
  if ($hash -ne $d.Sha256) { throw "$($d.Url): SHA-256 $hash, expected $($d.Sha256)" }
  if ($d.Member) {
    tar.exe -xf $file -C $tmp $d.Member # Windows' tar reads .zip too
    if ($LASTEXITCODE) { throw "extracting $($d.Member) from $file" }
    $file = Join-Path $tmp $d.Member
  }
  Copy-Item $file $target -Force # a copy takes the folder's permissions; a move would keep the temp folder's
}
Remove-Item $tmp -Recurse -Force
New-Item -ItemType Directory -Force "$($s.TftpRoot)\Boot\x64" | Out-Null
Copy-Item "$($s.BootFiles)\snponly.efi" "$($s.TftpRoot)\Boot\x64\snponly.efi" -Force
Copy-Item "$root\boot\*.ipxe" $s.BootFiles -Force
# IIS's anonymous user must be able to read every file, or iPXE gets HTTP 401
icacls $s.BootFiles /reset /t /q | Out-Null

Step 'check'
# Every boot file over HTTP, as iPXE fetches it: anonymously
Get-ChildItem $s.BootFiles -File | Where-Object Name -ne 'web.config' | ForEach-Object {
  $url = "http://$($s.DcAddress)/boot/$($_.Name)"
  $response = Invoke-WebRequest $url -UseBasicParsing -Method Head
  if ($response.StatusCode -ne 200) { throw "$url returned HTTP $($response.StatusCode)" }
}
$fetched = (Invoke-WebRequest "http://$($s.DcAddress)/boot/boot.ipxe" -UseBasicParsing).Content
if ($fetched -notmatch '^#!ipxe') { throw 'http://.../boot/boot.ipxe did not return the iPXE script' }
Get-DhcpServerv4OptionValue | ForEach-Object { "server option $($_.OptionId): $($_.Value)" }
Get-DhcpServerv4OptionValue -ScopeId $scope | ForEach-Object { "scope option $($_.OptionId): $($_.Value)" }
Get-DhcpServerv4Policy -ScopeId $scope | Sort-Object ProcessingOrder | ForEach-Object {
  $options = Get-DhcpServerv4OptionValue -ScopeId $scope -PolicyName $_.Name | ForEach-Object { "$($_.OptionId)=$($_.Value)" }
  "policy $($_.ProcessingOrder) $($_.Name): $($_.VendorClass)$($_.UserClass) -> $($options -join ' ')"
}
Get-ChildItem $s.BootFiles -File | ForEach-Object { "boot file $($_.Name) $($_.Length)" }
