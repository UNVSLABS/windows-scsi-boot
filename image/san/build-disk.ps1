# A blank golden image on the build target, for image/build.sh (docs/golden-image.md): <data drive>:\iSCSI\images\
# golden-v<version>.vhdx, a dynamic VHDX on target "build", which accepts only the build VM's initiator. Prints the
# target's IQN. Run as admin. An unfinished build of the same version is replaced; a finished, read-only one is refused.
param(
  [Parameter(Mandatory)][int]$Version,
  [Parameter(Mandatory)][string]$InitiatorIqn # the build VM's
)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"

$path = "$($s.SanDataDrive):\iSCSI\images\golden-v$Version.vhdx"
$target = 'build'
if ((Test-Path $path) -and (Get-Item $path).IsReadOnly) { throw "golden-v$Version is built already: $path is read-only" }

Step "target $target, for $InitiatorIqn only"
Set-BuildTarget $InitiatorIqn

Step "blank golden-v$Version, $($s.ImageSizeGB) GB"
if (Get-IscsiVirtualDisk -Path $path -ErrorAction SilentlyContinue) { Remove-IscsiVirtualDisk -Path $path }
Remove-Item $path -Force -ErrorAction SilentlyContinue
New-IscsiVirtualDisk -Path $path -SizeBytes ([int64]$s.ImageSizeGB * 1GB) | Out-Null # dynamic: it grows as it's written
Add-IscsiVirtualDiskTargetMapping -TargetName $target -Path $path
"target-iqn: $((Get-IscsiServerTarget -TargetName $target).TargetIqn)"
