# A new client's part on the domain controller, for clients/new-client.sh (PLAN.md, Client lifecycle; docs/clients.md):
# - the clients' OU and Group Policy (policy.ps1);
# - a DHCP reservation for the client's MAC;
# - its computer account in that OU, with an offline domain join: djoin /provision, with /reuse, so that a client keeps
#   its account when its disk is made again (client.ps1).
# Prints the join's data for the client's answer file as "account-data: ...". It holds the account's machine password:
# new-client.sh passes it straight on to the storage server, and nothing keeps it. Run as admin. Safe to re-run.
param(
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string]$Mac,
  [Parameter(Mandatory)][string]$Address
)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"
. "$PSScriptRoot\client.ps1"

Step 'the clients'' OU and Group Policy'
& "$PSScriptRoot\policy.ps1"

Step "$Name`: DHCP reservation $Address for $Mac"
Set-ClientReservation $Name $Mac $Address

Step "$Name`: computer account in OU $($s.ClientOu), and its offline domain join"
$blob = Get-JoinData $Name
"account: $((Get-ADComputer $Name).DistinguishedName)"
"account-data: $blob"
