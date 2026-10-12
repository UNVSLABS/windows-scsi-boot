# Clients' new domain joins on the domain controller, for clients/update-clients.sh (PLAN.md, Client lifecycle;
# docs/clients.md). First the clients' OU and Group Policy (policy.ps1), and the boot scripts (boot/*.ipxe), so that a
# change to them lands with the update.
# Then for each client, given as its row of clients.csv, "<name>,<mac>,<address>": its DHCP reservation, as
# new-client.ps1 makes it; and its offline domain join again (client.ps1), which keeps its computer account and resets
# the account's machine password. So only for clients that are off: a running client would lose its trust with the
# domain until its disk is made again. Prints "account-data <name>: <data>" for each: update-clients.sh passes it
# straight on to the storage server, and nothing keeps it. Run as admin.
param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Client)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"
. "$PSScriptRoot\client.ps1"

Step 'the clients'' OU and Group Policy, and the boot scripts'
& "$PSScriptRoot\policy.ps1"
Copy-Item "$root\boot\*.ipxe" $s.BootFiles -Force
icacls $s.BootFiles /reset /t /q | Out-Null # IIS's anonymous user must be able to read every file

foreach ($row in $Client) {
  $name, $mac, $address = $row -split ','
  Step "$name`: DHCP reservation $address for $mac, and a new offline domain join for its computer account"
  Set-ClientReservation $name $mac $address
  $blob = Get-JoinData $name
  "account: $((Get-ADComputer $name).DistinguishedName)"
  "account-data $name`: $blob"
}
