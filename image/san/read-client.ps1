# Print files from a test client's disk once it's off, for image/nic-test.sh (docs/golden-image.md): logs that WinPE or
# Windows wrote there, when Windows can't be reached. Run as admin. Paths are relative to the disk's Windows volume.
param(
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string[]]$File
)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"

$path = "$($s.SanDataDrive):\iSCSI\clients\$Name.vhdx"
Wait-TargetIdle $Name # nic-test.sh runs this once the client is off
Use-WindowsVolume $path -ReadOnly {
  param($volume)
  foreach ($f in $File) {
    "== $f"
    if (Test-Path "$volume\$f") { Get-Content "$volume\$f" } else { '(none)' }
  }
}
