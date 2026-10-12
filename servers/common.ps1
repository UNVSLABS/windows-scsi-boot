# Shared by the server scripts, which dot-source it: the settings, and restarts that setup.sh follows up.

$root = Resolve-Path "$PSScriptRoot\.." # the copy of the repo that setup.sh makes on the server
$s = Import-PowerShellDataFile "$PSScriptRoot\settings.psd1"

function Step($text) { Write-Output "== $text" }

# The password or other secret that remote.sh sends along in servers\secret.txt, which is deleted once read: its first
# line, or with -All its lines
function Read-Secret([switch]$All) {
  $file = "$PSScriptRoot\secret.txt"
  if (-not (Test-Path $file)) { return $null }
  $secret = if ($All) { @(Get-Content $file | ForEach-Object Trim | Where-Object { $_ }) }
  else { (Get-Content $file -TotalCount 1).Trim() }
  Remove-Item $file -Force
  $secret
}

# A file from the repo with its @NAME@ values filled in. Windows' cmd wants CRLF and no byte-order mark; iPXE wants LF.
function Expand-Template($from, $to, $values, [switch]$Cmd) {
  $text = Get-Content $from -Raw
  foreach ($name in $values.Keys) { $text = $text.Replace("@$name@", $values[$name]) }
  if ($text -match '@[A-Z_]+@') { throw "$from`: no value for $($Matches[0])" }
  if ($Cmd) { $text = $text -replace '\r?\n', "`r`n" }
  [IO.File]::WriteAllText($to, $text, [Text.UTF8Encoding]::new($false))
}

# Restart Windows and end the script. setup.sh waits for the restart, then runs the script again: each one skips what's
# done. New clones of the template install updates by themselves, and a restart they leave pending blocks a promotion
# and can fail a role's install.
function Restart-ForRerun($why) {
  shutdown.exe /r /t 5 /c "windows-scsi-boot: $why" | Out-Null
  Exit-ForRestart $why
}

function Test-RestartPending {
  (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
  (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}

# End the script for a restart, ours or one Windows started by itself, as servicing does to finish updates. setup.sh
# knows the restart has happened once the boot time differs from the one printed here.
function Exit-ForRestart($why) {
  "restarting: $why"
  "booted: " + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
  exit 0
}

# Call before changing anything. After a restart, servicing (TrustedInstaller) can go on installing updates, and then
# restarts Windows by itself. So wait for it to finish, and restart now if it left a restart pending.
function Wait-ServicingIdle {
  $deadline = (Get-Date).AddMinutes(30)
  while (Get-Process TiWorker -ErrorAction SilentlyContinue) {
    if ((Get-Date) -gt $deadline) { throw 'Windows servicing (TiWorker) was still busy after 30 minutes' }
    Start-Sleep 15
  }
  if (Test-RestartPending) { Restart-ForRerun 'updates are waiting for a restart' }
}

# Windows Update downloads updates, but installs them, and restarts, only when an admin says so. Left to itself, it
# restarted the storage server twice one night, and every client booted from it hangs while it's away.
function Set-UpdatePolicy {
  $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
  New-Item $au -Force | Out-Null
  Set-ItemProperty $au NoAutoUpdate 0 -Type DWord
  Set-ItemProperty $au AUOptions 7 -Type DWord # download automatically; notify to install, and to restart
}

function Install-Feature([string[]]$Name) {
  try { $result = Install-WindowsFeature $Name -IncludeManagementTools }
  catch {
    if ("$_" -match '0x8007045b') { Exit-ForRestart 'Windows is already shutting down' } # ERROR_SHUTDOWN_IN_PROGRESS
    throw
  }
  if (-not $result.Success) { throw "installing $Name failed" }
  if ($result.RestartNeeded -eq 'Yes') { Restart-ForRerun "to finish installing $Name" }
}

# On the storage server, once the target's client is off: wait for the target to have no session. A session outlives a
# client that's switched off, until the target's idle check logs it off, about two minutes later.
function Wait-TargetIdle($Target) {
  $deadline = (Get-Date).AddMinutes(5)
  while ((Get-IscsiServerTarget -TargetName $Target -ErrorAction SilentlyContinue).Status -eq 'Connected') {
    if ((Get-Date) -gt $deadline) { throw "target $Target still has a session after 5 minutes: is its client running?" }
    Start-Sleep 15
  }
}

# On the storage server: a golden image version, the one given or the newest sealed one. Fails unless it's sealed.
function Resolve-GoldenImage([int]$Version) {
  $images = "$($s.SanDataDrive):\iSCSI\images"
  if (-not $Version) {
    $Version = Get-ChildItem $images -Filter 'golden-v*.vhdx' | Where-Object IsReadOnly |
      ForEach-Object { [int]($_.BaseName -replace '^golden-v') } | Sort-Object | Select-Object -Last 1
    if (-not $Version) { throw "no sealed golden image in $images" }
  }
  $path = "$images\golden-v$Version.vhdx"
  if (-not (Test-Path $path) -or -not (Get-Item $path).IsReadOnly) { throw "golden-v$Version isn't built and sealed" }
  $Version
}

# On the storage server: target "build", which accepts only the build VM's initiator, with no disks on it yet, for
# image/build.sh and image/change.sh, which run this while the build VM is off
function Set-BuildTarget($InitiatorIqn) {
  $target = 'build'
  Wait-TargetIdle $target
  if (-not (Get-IscsiServerTarget -TargetName $target -ErrorAction SilentlyContinue)) {
    New-IscsiServerTarget -TargetName $target -InitiatorIds "IQN:$InitiatorIqn" | Out-Null
  } else { Set-IscsiServerTarget -TargetName $target -InitiatorIds "IQN:$InitiatorIqn" }
  foreach ($lun in (Get-IscsiServerTarget -TargetName $target).LunMappings) {
    Remove-IscsiVirtualDiskTargetMapping -TargetName $target -Path $lun.Path
  }
}

# On the storage server: run $Action with an iSCSI virtual disk's Windows volume, as a drive letter. The iSCSI target
# holds the file open while the disk is in its list, so the disk leaves the list meanwhile, then goes back with its
# target mappings. Its clients must be off.
function Use-WindowsVolume([string]$Path, [scriptblock]$Action, [switch]$ReadOnly) {
  $targets = @(Get-IscsiServerTarget | Where-Object { $_.LunMappings.Path -contains $Path }).TargetName
  foreach ($t in $targets) { Remove-IscsiVirtualDiskTargetMapping -TargetName $t -Path $Path }
  if (Get-IscsiVirtualDisk -Path $Path -ErrorAction SilentlyContinue) { Remove-IscsiVirtualDisk -Path $Path }
  try {
    $disk = Mount-DiskImage $Path -Access ($(if ($ReadOnly) { 'ReadOnly' } else { 'ReadWrite' })) -PassThru | Get-Disk
    try {
      if ($disk.IsOffline) { $disk | Set-Disk -IsOffline $false } # Windows Server's SAN policy can leave it offline
      $partition = $disk | Get-Partition | Where-Object { ($_ | Get-Volume).FileSystemLabel -eq 'Windows' }
      if (-not $partition) { throw "$Path has no volume labelled Windows" }
      if (-not $partition.DriveLetter) { $partition | Add-PartitionAccessPath -AssignDriveLetter; $partition = $partition | Get-Partition }
      & $Action "$($partition.DriveLetter):"
    } finally { Dismount-DiskImage $Path | Out-Null }
  } finally {
    Import-IscsiVirtualDisk -Path $Path | Out-Null
    foreach ($t in $targets) { Add-IscsiVirtualDiskTargetMapping -TargetName $t -Path $Path }
  }
}
