# A client's part on the domain controller, removed, for clients/remove-client.sh (docs/clients.md): its boot script, so
# that it gets the menu for machines that aren't clients; its DHCP reservation; its DNS records; and its computer
# account. Run as admin. Safe to re-run.
param(
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string]$Mac
)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"

$id = $Mac.ToLower() -replace ':', '-' # as iPXE's ${net0/mac:hexhyp}, and the DHCP server's client ID
Remove-Item "$($s.BootFiles)\clients\$id.ipxe", "$($s.BootFiles)\jobs\$id.cmd" -Force -ErrorAction SilentlyContinue
"$Name`: no boot script"

$scope = $s.Network.Split('/')[0]
$reservation = Get-DhcpServerv4Reservation -ScopeId $scope | Where-Object ClientId -eq $id
if ($reservation) { Remove-DhcpServerv4Reservation -ScopeId $scope -ClientId $id }
"$Name`: no DHCP reservation"

$a = Get-DnsServerResourceRecord -ZoneName $s.DomainName -Name $Name -RRType A -ErrorAction SilentlyContinue
foreach ($record in $a) {
  $address = $record.RecordData.IPv4Address.IPAddressToString
  Remove-DnsServerResourceRecord -ZoneName $s.DomainName -InputObject $record -Force
  # Its reverse record, in the zone servers/dc/configure.ps1 made for the network
  foreach ($zone in Get-DnsServerZone | Where-Object IsReverseLookupZone) {
    Get-DnsServerResourceRecord -ZoneName $zone.ZoneName -RRType Ptr -ErrorAction SilentlyContinue |
      Where-Object { $_.RecordData.PtrDomainName -like "$Name.*" } |
      ForEach-Object { Remove-DnsServerResourceRecord -ZoneName $zone.ZoneName -InputObject $_ -Force }
  }
  "$Name`: DNS records for $address removed"
}

$computer = Get-ADComputer -Filter "Name -eq '$Name'"
if ($computer) { Remove-ADObject $computer -Recursive -Confirm:$false }
"$Name`: no computer account"
