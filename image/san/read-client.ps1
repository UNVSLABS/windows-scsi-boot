# Print files from a test client's disk once it's off, for image/nic-test.sh (docs/image.md): logs that WinPE or Windows
# wrote there, when Windows can't be reached. Run as admin. Paths are relative to the disk's Windows volume.
param(
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string[]]$File
)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"

$path = "$($s.SanDataDrive):\iSCSI\clients\$Name.vhdx"
if ((Get-IscsiServerTarget -TargetName $Name -ErrorAction SilentlyContinue).Status -eq 'Connected') { throw "$Name is still running" }
$disk = Mount-DiskImage $path -Access ReadOnly -PassThru | Get-Disk
try {
  if ($disk.IsOffline) { $disk | Set-Disk -IsOffline $false }
  $partition = $disk | Get-Partition | Where-Object { ($_ | Get-Volume).FileSystemLabel -eq 'Windows' }
  if (-not $partition.DriveLetter) { $partition | Add-PartitionAccessPath -AssignDriveLetter; $partition = $partition | Get-Partition }
  foreach ($f in $File) {
    $full = "$($partition.DriveLetter):\$f"
    "== $f"
    if (Test-Path $full) { Get-Content $full } else { '(none)' }
  }
} finally { Dismount-DiskImage $path | Out-Null }
