# A client's part on the domain controller (docs/clients.md), for clients/dc/new-client.ps1 and update-clients.ps1,
# which dot-source this after servers/common.ps1: its DHCP reservation, and its offline domain join.

# A DHCP reservation for the client's MAC at its address, replacing one for the MAC at another address. Found in the
# scope's list of reservations: Get-DhcpServerv4Reservation -IPAddress also returns the lease that a removed
# reservation leaves behind.
function Set-ClientReservation($Name, $Mac, $Address) {
  $scope = $s.Network.Split('/')[0]
  $id = $Mac.ToLower() -replace ':', '-' # the DHCP server's client ID
  $reservations = Get-DhcpServerv4Reservation -ScopeId $scope
  $byAddress = $reservations | Where-Object { "$($_.IPAddress)" -eq $Address }
  if ($byAddress -and $byAddress.ClientId -ne $id) { throw "$Address is reserved for $($byAddress.ClientId) already" }
  $byMac = $reservations | Where-Object ClientId -eq $id
  if ($byMac -and "$($byMac.IPAddress)" -ne $Address) { Remove-DhcpServerv4Reservation -ScopeId $scope -ClientId $id }
  if (-not $byAddress) {
    Add-DhcpServerv4Reservation -ScopeId $scope -IPAddress $Address -ClientId $id -Name $Name `
      -Description 'Diskless client (clients/new-client.sh)'
  }
}

# The join's data for the client's answer file, from djoin /provision with /reuse: it makes the computer account in the
# clients' OU, or keeps one that's there and resets its machine password, so a client keeps its account when its disk
# is made again. The data holds that password: the caller prints it for the storage server, and nothing keeps it.
function Get-JoinData($Name) {
  $ou = "OU=$($s.ClientOu),$((Get-ADDomain).DistinguishedName)"
  # djoin wants a file even when it prints the data; it's deleted at once
  $file = Join-Path $env:TEMP "djoin-$(Get-Random).txt"
  try { $out = djoin /provision /domain $s.DomainName /machine $Name /machineou $ou /reuse /savefile $file /printblob 2>&1 }
  finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
  if ($LASTEXITCODE) { throw "djoin /provision failed: $out" }
  $blob = $out | Where-Object { "$_" -match '^[A-Za-z0-9+/]{100,}=*$' } | Select-Object -First 1
  if (-not $blob) { throw 'djoin printed no provisioning data' }
  $blob
}
