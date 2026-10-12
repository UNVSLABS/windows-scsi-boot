# Clients' disks on the storage server, for clients/check.sh (docs/clients.md): each one's size, its golden image, and
# whether its target has a session, which is a client that's running. Run as admin.
param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Name)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"

foreach ($n in $Name) {
  $path = "$($s.SanDataDrive):\iSCSI\clients\$n.vhdx"
  if (-not (Test-Path $path)) { "$n`: no disk"; continue }
  $disk = Get-IscsiVirtualDisk -Path $path -ErrorAction SilentlyContinue
  $target = Get-IscsiServerTarget -TargetName $n -ErrorAction SilentlyContinue
  "{0}: disk {1:n2} GB on {2}, target {3}" -f $n, ((Get-Item $path).Length / 1GB), (Split-Path $disk.ParentPath -Leaf),
    $(if ($target) { $target.Status } else { 'none' })
}
