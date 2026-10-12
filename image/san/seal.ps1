# Seal a golden image once image/build.sh's build VM has powered off (docs/image.md): take it off the build target,
# check that sysprep generalised it and that it has the clients' first boot (docs/clients.md), and make it read-only with
# both the file attribute and its ACL. A write to a parent breaks every child disk on it. Run as admin. Safe to re-run.
param([Parameter(Mandatory)][int]$Version)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"

$path = "$($s.SanDataDrive):\iSCSI\images\golden-v$Version.vhdx"
$target = 'build'
if (-not (Test-Path $path)) { throw "no $path" }

Step 'off the build target'
Wait-TargetIdle $target # build.sh runs this once the build VM is off
if (Get-IscsiVirtualDisk -Path $path -ErrorAction SilentlyContinue) {
  Remove-IscsiVirtualDiskTargetMapping -TargetName $target -Path $path -ErrorAction SilentlyContinue
  Remove-IscsiVirtualDisk -Path $path # from the iSCSI target's list; the file stays
}

Step 'generalised?'
# Windows records its setup state in Windows\Setup\State\State.ini as well as in the registry
$disk = Mount-DiskImage $path -Access ReadOnly -PassThru | Get-Disk
try {
  if ($disk.IsOffline) { $disk | Set-Disk -IsOffline $false } # Windows Server's SAN policy can leave it offline
  $partition = $disk | Get-Partition | Where-Object { ($_ | Get-Volume).FileSystemLabel -eq 'Windows' }
  if (-not $partition) { throw "golden-v$Version has no volume labelled Windows" }
  if (-not $partition.DriveLetter) { $partition | Add-PartitionAccessPath -AssignDriveLetter; $partition = $partition | Get-Partition }
  $state = (Get-Content "$($partition.DriveLetter):\Windows\Setup\State\State.ini" | Select-String '^ImageState=(.*)').Matches.Groups[1].Value
  "image state: $state"
  if ($state -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { throw "golden-v$Version isn't generalised" }
  # And the clients' first boot, which generalize.ps1 adds after sysprep (docs/clients.md)
  $firstBoot = "$($partition.DriveLetter):\Windows\Setup\Diskless"
  foreach ($file in 'firstboot.wim', 'boot.sdi', 'firstboot.ps1') {
    if (-not (Test-Path "$firstBoot\$file")) { throw "golden-v$Version has no $firstBoot\${file}: no first boot for clients" }
  }
  "first boot: $([math]::Round((Get-Item "$firstBoot\firstboot.wim").Length / 1MB)) MB of WinPE"
} finally { Dismount-DiskImage $path | Out-Null }

Step 'read-only'
# The iSCSI target reads a parent as SYSTEM. Administrators own the file, so they can still change its ACL, and delete
# it through the folder's.
Set-ItemProperty $path IsReadOnly $true
icacls $path /inheritance:r /grant:r '*S-1-5-18:R' '*S-1-5-32-544:R' | Out-Null
icacls $path
"golden-v$Version`: $([math]::Round((Get-Item $path).Length / 1GB, 1)) GB, read-only"
