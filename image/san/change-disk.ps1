# A golden image to change, for image/change.sh (PLAN.md, Client lifecycle; docs/image.md): golden-v<version>.vhdx, a
# copy of golden-v<from> (the newest sealed one unless given) that can be written, on the build target, which accepts
# only the build VM's initiator. Prints the target's IQN. If golden-v<version> is there already and not sealed, a change
# that was started and not sealed yet, it goes on the target as it is. Run as admin, while the build VM is off.
# With -Check, before image/change.sh seals it: fails unless golden-v<version> isn't sealed, is on the build target,
# and has a session there, which is the build VM running it.
param(
  [Parameter(Mandatory)][int]$Version,
  [string]$InitiatorIqn, # the build VM's
  [int]$From,
  [switch]$Check
)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"

$images = "$($s.SanDataDrive):\iSCSI\images"
$path = "$images\golden-v$Version.vhdx"
$target = 'build'

if ($Check) {
  if (-not (Test-Path $path)) { throw "no golden-v$Version`: image/change.sh $Version starts a change" }
  if ((Get-Item $path).IsReadOnly) { throw "golden-v$Version is sealed already" }
  $t = Get-IscsiServerTarget -TargetName $target -ErrorAction SilentlyContinue
  if ($t.LunMappings.Path -notcontains $path -or $t.Status -ne 'Connected') {
    throw "the build VM isn't running golden-v$Version`: image/change.sh $Version starts it again"
  }
  "golden-v$Version`: not sealed, running on the build VM"
  return
}

if (-not $InitiatorIqn) { throw 'need the build VM''s initiator' }
Step "target $target, for $InitiatorIqn only"
Set-BuildTarget $InitiatorIqn
if (Test-Path $path) {
  if ((Get-Item $path).IsReadOnly) { throw "golden-v$Version is sealed already: a change makes a new version" }
  "golden-v$Version is there already, not sealed: a change that isn't finished, which goes on as it is"
} else {
  $From = Resolve-GoldenImage $From
  Step "golden-v$Version, a copy of golden-v$From"
  # Under another name until it's whole. A copy takes the folder's permissions, not the sealed image's ACL; its
  # read-only attribute goes.
  Copy-Item "$images\golden-v$From.vhdx" "$path.tmp" -Force
  Set-ItemProperty "$path.tmp" IsReadOnly $false
  Rename-Item "$path.tmp" (Split-Path $path -Leaf)
}
if (-not (Get-IscsiVirtualDisk -Path $path -ErrorAction SilentlyContinue)) { Import-IscsiVirtualDisk -Path $path | Out-Null }
Add-IscsiVirtualDiskTargetMapping -TargetName $target -Path $path
"golden-v$Version`: $([math]::Round((Get-Item $path).Length / 1GB, 1)) GB, on target $target"
"target-iqn: $((Get-IscsiServerTarget -TargetName $target).TargetIqn)"
