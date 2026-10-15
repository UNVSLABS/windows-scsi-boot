@echo off
rem WinPE's job on a test client for image\nic-test.sh's netadapter variant (docs/golden-image.md), served as
rem jobs\<mac>.cmd by image\dc\test-client.ps1. It makes the NIC that WinPE booted with a boot NIC of the Windows on the
rem client's iSCSI disk, as Windows setup does when it installs onto iSCSI: DISM's /Add-NetAdapter, which Microsoft
rem doesn't document, and BootFlags 1 on the NIC driver's service. Then it powers off, and nic-test.sh boots Windows
rem from the disk. Log: Windows\Temp\netadapter.log on that disk.

rem The Windows on the iSCSI disk. WinPE connects the disk from the iBFT once the NIC's driver has loaded, which can take
rem a minute or two.
set W=
for /l %%i in (1,1,36) do (
  for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist %%d:\Windows\System32\config\SYSTEM set W=%%d:
  if defined W goto found
  ping -n 6 127.0.0.1 >nul
)
echo No Windows on a disk: WinPE didn't connect to the iSCSI target in the iBFT
goto failed
:found
set LOG=%W%\Windows\Temp\netadapter.log
echo WinPE on %COMPUTERNAME%, Windows on %W% > %LOG%

rem The NIC: the one physical adapter that's connected
powershell -NoProfile -Command "Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=TRUE' | Format-List Name,GUID,ServiceName,MACAddress,NetEnabled,PNPDeviceID" >> %LOG% 2>&1
set GUID=
set SERVICE=
for /f "tokens=1,2" %%g in ('powershell -NoProfile -Command "Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=TRUE' | Where-Object NetEnabled | Select-Object -First 1 | ForEach-Object { $_.GUID + ' ' + $_.ServiceName }"') do (
  set GUID=%%g
  set SERVICE=%%h
)
if not defined GUID (echo No connected network adapter >> %LOG%& goto failed)

rem The NIC driver's service. The image has the driver, but only staged: DISM installs no service for a network driver.
rem Setup creates its boot NIC's (setupapi.offline.log: "Reflect Critical Driver Package"), and this copies WinPE's,
rem which WinPE made for this NIC from the same driver package, with the driver's file if it isn't in the driver store.
rem The service starts on demand, and Windows loads it at boot when booting from the network only with BootFlags 1,
rem which setup's boot NIC gets from its driver's INF. NetKVM's and vmxnet3's INFs don't set it.
set KEY=HKLM\diskless\ControlSet001\Services\%SERVICE%
reg load HKLM\diskless %W%\Windows\System32\config\SYSTEM >> %LOG% 2>&1 || goto failed
reg query %KEY% >nul 2>&1 && (echo Service %SERVICE% is in the image >> %LOG%) || (
  echo Service %SERVICE% copied from WinPE >> %LOG%
  reg copy HKLM\SYSTEM\CurrentControlSet\Services\%SERVICE% %KEY% /s /f >> %LOG% 2>&1
  rem WinPE's devices, which Windows keeps in a key it makes at each boot
  reg delete %KEY%\Enum /f >nul 2>&1
)
reg add %KEY% /v BootFlags /t REG_DWORD /d 1 /f >> %LOG% 2>&1
reg query %KEY% >> %LOG% 2>&1
reg unload HKLM\diskless >> %LOG% 2>&1
powershell -NoProfile -Command "$p = (Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\%SERVICE%).ImagePath -replace '^\\SystemRoot\\', ''; if (Test-Path %W%\Windows\$p) { 'driver file in the image: ' + $p } else { Copy-Item $env:SystemRoot\$p %W%\Windows\$p; 'driver file copied: ' + $p }" >> %LOG% 2>&1

rem The NIC itself, bound to TCP/IP at boot. WinPE's scratch space is small, so DISM works on the disk.
mkdir %W%\Windows\Temp\dism 2>nul
dism /Image:%W%\ /ScratchDir:%W%\Windows\Temp\dism /Add-NetAdapter /HostAdapter:%GUID% /BootDriver:ms_tcpip /BootDriver:ms_tcpip6 >> %LOG% 2>&1
echo dism exited with %errorlevel% >> %LOG%
type %LOG%
wpeutil shutdown
goto :eof

:failed
if defined LOG type %LOG%
echo.
echo Stopped here.
