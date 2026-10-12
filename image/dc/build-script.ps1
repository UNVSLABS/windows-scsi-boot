# The build VM's own iPXE script, clients/<mac>.ipxe on the domain controller, for one phase of image/build.sh's build
# (docs/image.md). It sets the build's disks and phase, then chains boot/build.ipxe:
#   setup    WinPE, with the blank build disk attached, and through the build VM's second NIC, if the build has one, a
#            second disk on the storage server's second address
#   windows  the Windows on the build disk: the one setup installed, or a golden image being changed (image/change.sh)
# And the build VM's DHCP reservation. Run as admin, by image/dc/prepare.ps1 for setup, and by build.sh and change.sh
# for windows. image/dc/cleanup.ps1 deletes the script.
param(
  [Parameter(Mandatory)][string]$Mac,          # the build VM's
  [Parameter(Mandatory)][string]$InitiatorIqn, # the build VM's
  [Parameter(Mandatory)][string]$TargetIqn,    # the build target's
  [Parameter(Mandatory)][ValidateSet('setup', 'windows')][string]$Phase,
  [string]$SecondTargetIqn                     # the second target's, for setup with a second NIC
)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\servers\common.ps1"

# A host route to a target's address, as iPXE's static-routes setting (DHCP option 121) takes it: the prefix length,
# the address, and gateway 0.0.0.0, which is on the link
function Get-HostRoute($address) {
  '20:' + ((([ipaddress]$address).GetAddressBytes() | ForEach-Object { '{0:x2}' -f $_ }) -join ':') + ':00:00:00:00'
}

$id = $Mac.ToLower() -replace ':', '-' # as iPXE's ${net0/mac:hexhyp}
$lines = @(
  '#!ipxe'
  "# $($s.BuildVm), while image/build.sh builds a golden image: $Phase. Deleted when the build ends."
  "set initiator-iqn $InitiatorIqn"
  "set root-path iscsi:$($s.SanAddress)::::$TargetIqn"
  "set build-phase $Phase"
)
if ($Phase -eq 'setup' -and $SecondTargetIqn) {
  if (-not $s.SanSecondAddress) { throw 'a second target, but no SanSecondAddress in settings.psd1' }
  $lines += @(
    "set second-path iscsi:$($s.SanSecondAddress)::::$SecondTargetIqn"
    "set route0 $(Get-HostRoute $s.SanAddress)"
    "set route1 $(Get-HostRoute $s.SanSecondAddress)"
  )
}
$lines += 'chain ../build.ipxe'
$script = "$($s.BootFiles)\clients\$id.ipxe"
New-Item -ItemType Directory -Force (Split-Path $script) | Out-Null
Copy-Item "$root\boot\*.ipxe" $s.BootFiles -Force
[IO.File]::WriteAllText($script, ($lines -join "`n") + "`n")
icacls $s.BootFiles /reset /t /q | Out-Null # IIS's anonymous user must be able to read every file

# A reservation, so the build VM can be found while it runs. Fixed MACs are 02:00 and then the address (lab/main.tf).
$scope = $s.Network.Split('/')[0]
$address = (($Mac -split ':')[2..5] | ForEach-Object { [Convert]::ToInt32($_, 16) }) -join '.'
if (-not (Get-DhcpServerv4Reservation -ScopeId $scope | Where-Object ClientId -eq $id)) {
  Add-DhcpServerv4Reservation -ScopeId $scope -IPAddress $address -ClientId $id -Name $s.BuildVm `
    -Description 'Builds and changes golden images (image/build.sh, image/change.sh)'
}
"$($s.BuildVm): $Phase, at $address"
