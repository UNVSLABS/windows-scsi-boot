# A blank golden image on the build target, for image/build.sh (docs/image.md): <data drive>:\iSCSI\images\
# golden-v<version>.vhdx, a dynamic VHDX on target "build", which accepts only the build VM's initiator. Prints the
# target's IQN. With a second NIC for the build (settings.psd1), also target "build-second", with a small disk of its
# own, which the build VM reaches through that NIC; prints its IQN too. Run as admin. An unfinished build of the same
# version is replaced; a finished, read-only one is refused.
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

if ($s.BuildSecondNic) {
  # Its disk only puts the second NIC in the iBFT, for setup: nothing is written to it, and it's kept between builds
  $second = 'build-second'
  $secondPath = "$($s.SanDataDrive):\iSCSI\images\$second.vhdx"
  Step "target $second, through the second address $($s.SanSecondAddress), for $InitiatorIqn only"
  $portal = (Get-IscsiTargetServerSetting).Portals | Where-Object { "$($_.IPEndpoint.Address)" -eq $s.SanSecondAddress }
  if (-not $portal.Enabled) { throw "no iSCSI portal on $($s.SanSecondAddress): run servers/san/configure.ps1" }
  Wait-TargetIdle $second
  if (-not (Get-IscsiServerTarget -TargetName $second -ErrorAction SilentlyContinue)) {
    New-IscsiServerTarget -TargetName $second -InitiatorIds "IQN:$InitiatorIqn" | Out-Null
  } else { Set-IscsiServerTarget -TargetName $second -InitiatorIds "IQN:$InitiatorIqn" }
  if (-not (Get-IscsiVirtualDisk -Path $secondPath -ErrorAction SilentlyContinue)) {
    Remove-Item $secondPath -Force -ErrorAction SilentlyContinue
    New-IscsiVirtualDisk -Path $secondPath -SizeBytes 64MB | Out-Null
  }
  if ((Get-IscsiServerTarget -TargetName $second).LunMappings.Path -notcontains $secondPath) {
    Add-IscsiVirtualDiskTargetMapping -TargetName $second -Path $secondPath
  }
  "second-target-iqn: $((Get-IscsiServerTarget -TargetName $second).TargetIqn)"
}
