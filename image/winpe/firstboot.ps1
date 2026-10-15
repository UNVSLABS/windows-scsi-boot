# A client's first boot (docs/clients.md). WinPE, booted as a RAM disk by Windows Boot Manager
# from the client's own disk, makes the client's NIC a boot NIC of the Windows on that disk: dism /Add-NetAdapter, which
# Windows setup runs for the build's NICs (docs/golden-image.md, Booting from any NIC). Then it sets the boot manager's
# default back to Windows, and restarts. The golden image's build puts this, WinPE and the boot entry into the image
# (image/windows/firstboot-entry.ps1), so each new child disk does this on its first boot, on whatever machine boots it.
# WinPE's startup (image/winpe/startnet-firstboot.cmd) runs it from the disk. Log: Windows\Temp\firstboot.log on the
# disk. On a failure, WinPE stops at a prompt, and the boot entry stays the default: the next start tries again.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$w = Split-Path $PSScriptRoot -Qualifier       # the client's Windows volume, as WinPE sees it
$firstBoot = '{bd965c03-fdb1-459d-9aa1-04822bba2c6b}' # this boot entry, as image/windows/firstboot-entry.ps1 makes it
Start-Transcript "$w\Windows\Temp\firstboot.log" -Append | Out-Null
try {
  # The NIC that WinPE reached the disk through: the connected physical one
  $nic = @(Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=TRUE' | Where-Object NetEnabled)[0]
  if (-not $nic) { throw 'no connected network adapter' }
  "NIC: $($nic.Name), $($nic.MACAddress), driver service $($nic.ServiceName), device $($nic.PNPDeviceID)"

  # What the image has for it. The seal made each NIC driver in the driver pack a boot driver, with its service; sysprep
  # kept the build's NIC itself, interface included. A NIC is the same device only with the same model and PCI location
  # (and PCIe serial number, where it has one).
  reg load HKLM\diskless "$w\Windows\System32\config\SYSTEM" | Out-Null
  if ($LASTEXITCODE) { throw 'reg load failed' }
  try {
    $set = 'HKLM:\diskless\ControlSet{0:d3}' -f (Get-ItemProperty HKLM:\diskless\Select).Current
    $service = Get-ItemProperty "$set\Services\$($nic.ServiceName)" -ErrorAction SilentlyContinue
    $start, $bootFlags = $service.Start, $service.BootFlags
    $known = Test-Path -LiteralPath "$set\Enum\$($nic.PNPDeviceID)"
    Remove-Variable service
  } finally {
    [gc]::Collect(); [gc]::WaitForPendingFinalizers() # the registry provider's handles, or the unload fails
    reg unload HKLM\diskless 2>&1 | Out-Null
  }
  if ($null -eq $start) {
    throw "the image has no driver service $($nic.ServiceName): its driver pack has no driver for this NIC, so it can't boot from it (docs/golden-image.md, Booting from any NIC)"
  }
  "image: driver service $($nic.ServiceName), Start $start, BootFlags $bootFlags"

  if ($known) {
    'image: has this NIC already, with its interface (the build NIC''s model at its PCI location)'
  } else {
    'image: a new NIC, so its interface: dism /Add-NetAdapter'
    New-Item -ItemType Directory -Force "$w\Windows\Temp\dism" | Out-Null # WinPE's own scratch space is small
    dism /Image:$w\ /ScratchDir:$w\Windows\Temp\dism /Add-NetAdapter /HostAdapter:$($nic.GUID) /BootDriver:ms_tcpip /BootDriver:ms_tcpip6
    if ($LASTEXITCODE) { throw "dism /Add-NetAdapter exited with $LASTEXITCODE" }
  }

  # Windows as the boot manager's default again, in the boot configuration on the disk's EFI system partition
  $esp = Get-Partition -DiskNumber (Get-Partition -DriveLetter $w[0]).DiskNumber |
    Where-Object GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
  $esp | Add-PartitionAccessPath -AssignDriveLetter
  $letter = ($esp | Get-Partition).DriveLetter
  try {
    $bcd = "${letter}:\EFI\Microsoft\Boot\BCD"
    $windows = (bcdedit /store $bcd /enum osloader /v | Select-String '^identifier\s+(\{\S+\})').Matches |
      ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne $firstBoot } | Select-Object -First 1
    if (-not $windows) { throw 'no Windows boot entry on the disk' }
    $out = bcdedit /store $bcd /default $windows 2>&1
    if ($LASTEXITCODE) { throw "bcdedit /default $windows`: $out" }
    $out = bcdedit /store $bcd /displayorder $firstBoot /remove 2>&1 # kept, but out of the boot manager's list
    if ($LASTEXITCODE) { throw "bcdedit /displayorder: $out" }
    "boot manager: default $windows, Windows"
  } finally { Remove-PartitionAccessPath -DiskNumber $esp.DiskNumber -PartitionNumber $esp.PartitionNumber -AccessPath "${letter}:\" }
  'done: restarting into Windows'
  Stop-Transcript | Out-Null
  wpeutil reboot
} catch {
  "FAILED: $_"
  Stop-Transcript | Out-Null
  exit 1
}
