# Delete golden-v<version>.vhdx from the storage server, for image/remove.sh (docs/golden-image.md). Refuses while a
# disk has it as its parent, or a VM runs it: a build or change, on the build target. A sealed image's ACL lets admins
# only read it, but they can clear its read-only attribute, and the folder lets them delete it: whether SYSTEM owns it
# (a build's) or Administrators (a change's copy). Then the golden images that are left. Run as admin. Safe to re-run.
param([Parameter(Mandatory)][int]$Version)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"

$images = "$($s.SanDataDrive):\iSCSI\images"
$path = "$images\golden-v$Version.vhdx"
if (Test-Path $path) {
  $children = @(Get-IscsiVirtualDisk | Where-Object ParentPath -eq $path)
  if ($children) {
    throw "golden-v$Version has $($children.Count) disks on it: $(($children.Path | Split-Path -Leaf) -join ', ')"
  }
  # On the build target, a build or change that isn't finished: refused while the build VM runs it
  foreach ($target in Get-IscsiServerTarget | Where-Object { $_.LunMappings.Path -contains $path }) {
    if ($target.Status -eq 'Connected') { throw "golden-v$Version is in use on target $($target.TargetName): stop its VM first" }
    Remove-IscsiVirtualDiskTargetMapping -TargetName $target.TargetName -Path $path
  }
  if (Get-IscsiVirtualDisk -Path $path -ErrorAction SilentlyContinue) { Remove-IscsiVirtualDisk -Path $path }
  Set-ItemProperty $path IsReadOnly $false
  Remove-Item $path -Force
}
"golden-v$Version`: deleted"
Get-ChildItem $images -Filter 'golden-v*.vhdx' | Sort-Object { [int]($_.BaseName -replace '^golden-v') } |
  ForEach-Object { "{0}: {1:n1} GB{2}" -f $_.BaseName, ($_.Length / 1GB), $(if (-not $_.IsReadOnly) { ', not sealed' }) }
