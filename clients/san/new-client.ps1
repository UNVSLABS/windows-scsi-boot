# A new client's disk on the storage server, for clients/new-client.sh (docs/clients.md):
# a differencing disk <data drive>:\iSCSI\clients\<name>.vhdx on a golden image, the newest sealed one unless given, with
# the client's computer name and its offline domain join (from servers\secret.txt) in the disk's answer file
# (clients/san/disk.ps1); and target <name>, which accepts only the client's initiator. Prints the target's IQN. Run as
# admin. Refuses a client that has a disk already: clients/remove-client.sh removes it.
param(
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string]$InitiatorIqn,
  [int]$Version # golden-v<version>
)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"
. "$PSScriptRoot\disk.ps1"
$accountData = Read-Secret # first, so that it's deleted whatever happens next
if (-not $accountData) { throw 'need the offline domain join data in secret.txt' }

$Version = Resolve-GoldenImage $Version
$path = Get-ClientDiskPath $Name
if ((Test-Path $path) -or (Get-IscsiServerTarget -TargetName $Name -ErrorAction SilentlyContinue)) {
  throw "$Name has a disk or target already: clients/remove-client.sh removes them"
}
New-ClientDisk $Name $Version $accountData

Step "$Name`: target $Name, for $InitiatorIqn only"
New-IscsiServerTarget -TargetName $Name -InitiatorIds "IQN:$InitiatorIqn" | Out-Null
Add-IscsiVirtualDiskTargetMapping -TargetName $Name -Path $path
"$Name`: golden-v$Version, disk $([math]::Round((Get-Item $path).Length / 1MB)) MB"
"target-iqn: $((Get-IscsiServerTarget -TargetName $Name).TargetIqn)"
