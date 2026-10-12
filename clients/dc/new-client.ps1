# A new client's part on the domain controller, for clients/new-client.sh (PLAN.md, Client lifecycle; docs/clients.md):
# - the clients' OU and Group Policy (policy.ps1);
# - a DHCP reservation for the client's MAC;
# - its computer account in that OU, with an offline domain join: djoin /provision, with /reuse, so that a client keeps
#   its account when its disk is made again.
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

Step 'the clients'' OU and Group Policy'
& "$PSScriptRoot\policy.ps1"

Step "$Name`: DHCP reservation $Address for $Mac"
$scope = $s.Network.Split('/')[0]
$id = $Mac.ToLower() -replace ':', '-' # the DHCP server's client ID
$byAddress = Get-DhcpServerv4Reservation -IPAddress $Address -ErrorAction SilentlyContinue
if ($byAddress -and $byAddress.ClientId -ne $id) { throw "$Address is reserved for $($byAddress.ClientId) already" }
$byMac = Get-DhcpServerv4Reservation -ScopeId $scope | Where-Object ClientId -eq $id
if ($byMac -and "$($byMac.IPAddress)" -ne $Address) { Remove-DhcpServerv4Reservation -ScopeId $scope -ClientId $id }
if (-not $byAddress) {
  Add-DhcpServerv4Reservation -ScopeId $scope -IPAddress $Address -ClientId $id -Name $Name `
    -Description 'Diskless client (clients/new-client.sh)'
}

$ou = "OU=$($s.ClientOu),$((Get-ADDomain).DistinguishedName)"
Step "$Name`: computer account in $ou, and its offline domain join"
# djoin wants a file even when it prints the data; it's deleted at once
$file = Join-Path $env:TEMP "djoin-$(Get-Random).txt"
try { $out = djoin /provision /domain $s.DomainName /machine $Name /machineou $ou /reuse /savefile $file /printblob 2>&1 }
finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
if ($LASTEXITCODE) { throw "djoin /provision failed: $out" }
$blob = $out | Where-Object { "$_" -match '^[A-Za-z0-9+/]{100,}=*$' } | Select-Object -First 1
if (-not $blob) { throw 'djoin printed no provisioning data' }
"account: $((Get-ADComputer $Name).DistinguishedName)"
"account-data: $blob"
