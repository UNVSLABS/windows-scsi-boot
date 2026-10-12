# Clients moved to another golden image on the storage server, for clients/update-clients.sh (PLAN.md, Client
# lifecycle; docs/clients.md), in two steps, around the domain controller's:
#   take <version> <name>...  For each client: skipped if it has no target here, or its disk is on golden-v<version>
#                             already; refused if it's running, which is a session on its target. Otherwise its disk
#                             comes off its target, so that it can't start while the disk is replaced, and it prints
#                             "ready: <name>". A running client prints "running: <name>".
#   make <version>            For each client in servers\secret.txt, a line "<name> <join data>" each: a new disk on
#                             golden-v<version> in place of its old one, with its computer name and new domain join
#                             (clients/san/disk.ps1), on the same target. Then the golden images, and how many disks each
#                             has: one that no disk uses is listed, not deleted (image/remove.sh deletes one).
# Run as admin. A client left with no disk on its target by a failure is ready again in the next run's take.
param(
  [Parameter(Mandatory)][ValidateSet('take', 'make')][string]$Action,
  [Parameter(Mandatory)][int]$Version,
  [Parameter(ValueFromRemainingArguments)][string[]]$Name
)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"
. "$PSScriptRoot\disk.ps1"
$joins = if ($Action -eq 'make') { Read-Secret -All } # first, so that it's deleted whatever happens next
$Version = Resolve-GoldenImage $Version
$parent = "$images\golden-v$Version.vhdx"

if ($Action -eq 'take') {
  $connected = @()
  foreach ($n in $Name) {
    $path = Get-ClientDiskPath $n
    $target = Get-IscsiServerTarget -TargetName $n -ErrorAction SilentlyContinue
    if (-not $target) { "$n`: skipped, no target: clients/new-client.sh makes it"; continue }
    $disk = Get-IscsiVirtualDisk -Path $path -ErrorAction SilentlyContinue
    if ($disk.ParentPath -eq $parent -and $target.LunMappings.Path -contains $path) { "$n`: on golden-v$Version already"; continue }
    if ($target.Status -eq 'Connected') { $connected += $n; continue }
    $target.LunMappings | ForEach-Object { Remove-IscsiVirtualDiskTargetMapping -TargetName $n -Path $_.Path }
    "ready: $n"
  }
  # A client that's just been switched off keeps its session for a couple of minutes, until the target's idle check
  $deadline = (Get-Date).AddSeconds(150)
  while ($connected) {
    $still = @()
    foreach ($n in $connected) {
      $target = Get-IscsiServerTarget -TargetName $n
      if ($target.Status -eq 'Connected') { $still += $n; continue }
      $target.LunMappings | ForEach-Object { Remove-IscsiVirtualDiskTargetMapping -TargetName $n -Path $_.Path }
      "ready: $n"
    }
    $connected = $still
    if (-not $connected -or (Get-Date) -gt $deadline) { break }
    Start-Sleep 15
  }
  foreach ($n in $connected) { "running: $n" }
  return
}

if (-not $joins) { throw 'need "<name> <join data>" lines in secret.txt' }
$failed = @()
foreach ($line in $joins) {
  $n, $accountData = $line -split ' ', 2
  $path = Get-ClientDiskPath $n
  try {
    $target = Get-IscsiServerTarget -TargetName $n
    if ($target.Status -eq 'Connected') { throw 'it has a session: was it started during the update?' }
    $target.LunMappings | ForEach-Object { Remove-IscsiVirtualDiskTargetMapping -TargetName $n -Path $_.Path }
    $old = (Get-IscsiVirtualDisk -Path $path -ErrorAction SilentlyContinue).ParentPath
    if (Get-IscsiVirtualDisk -Path $path -ErrorAction SilentlyContinue) { Remove-IscsiVirtualDisk -Path $path }
    Remove-Item $path -Force -ErrorAction SilentlyContinue
    New-ClientDisk $n $Version $accountData
    Add-IscsiVirtualDiskTargetMapping -TargetName $n -Path $path
    "$n`: golden-v$Version$(if ($old) { ", from $([IO.Path]::GetFileNameWithoutExtension($old))" }), disk $([math]::Round((Get-Item $path).Length / 1MB)) MB"
  } catch {
    "$n`: FAILED: $_"
    $failed += $n
  }
}

Step 'golden images'
$children = Get-IscsiVirtualDisk | Where-Object ParentPath | Group-Object ParentPath
foreach ($image in Get-ChildItem $images -Filter 'golden-v*.vhdx' | Sort-Object { [int]($_.BaseName -replace '^golden-v') }) {
  $disks = @($children | Where-Object Name -eq $image.FullName | ForEach-Object Group).Count
  "{0}: {1:n1} GB, {2}, {3}" -f $image.BaseName, ($image.Length / 1GB),
    $(if ($image.IsReadOnly) { 'sealed' } else { 'not sealed: a build or change' }),
    $(if ($disks) { "$disks disks" } elseif ($image.IsReadOnly) { 'no disks: image/remove.sh deletes it, once it isn''t needed to roll back to' } else { 'no disks' })
}
if ($failed) { throw "not updated: $($failed -join ', '). Run clients/update-clients.sh again for them." }
