# The clients' startup script (clients/dc/policy.ps1 puts it in their GPO; docs/clients.md): no power saving on the NICs.
# "Allow the computer to turn off this device to save power" off, as PnPCapabilities 24 in each physical NIC's driver key.
# Windows reads it when it starts the device, so it takes effect from the next boot: changing it through the NIC's own
# settings would restart the NIC, and with it the iSCSI connection the client runs from. Runs as SYSTEM at each startup.
$ErrorActionPreference = 'Stop'
foreach ($nic in Get-NetAdapter -Physical) {
  $driver = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($nic.PnPDeviceID)").Driver # {class}\<number>
  $key = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$driver"
  if ((Get-ItemProperty $key).PnPCapabilities -ne 24) { Set-ItemProperty $key PnPCapabilities 24 -Type DWord }
}
