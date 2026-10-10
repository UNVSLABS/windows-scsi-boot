@echo off
rem WinPE's job on a test client for image\nic-test.sh's netadapter variant (docs/image.md), served as jobs\<mac>.cmd
rem by image\dc\test-client.ps1. It makes the NIC that WinPE booted with a boot NIC of the Windows on the client's iSCSI
rem disk, as Windows setup does when it installs onto iSCSI: DISM's /Add-NetAdapter, which Microsoft doesn't document.
rem Then it powers off, and nic-test.sh boots Windows from the disk. Log: Windows\Temp\netadapter.log on that disk.

set W=
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist %%d:\Windows\System32\config\SYSTEM set W=%%d:
if not defined W (echo No Windows on a disk: WinPE didn't connect to the iSCSI target in the iBFT& goto failed)
set LOG=%W%\Windows\Temp\netadapter.log
echo WinPE on %COMPUTERNAME%, Windows on %W% > %LOG%

rem The NIC: the one physical adapter that's connected
powershell -NoProfile -Command "Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=TRUE' | Format-List Name,GUID,ServiceName,MACAddress,NetEnabled,PNPDeviceID" >> %LOG% 2>&1
set GUID=
for /f %%g in ('powershell -NoProfile -Command "(Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=TRUE' | Where-Object NetEnabled | Select-Object -First 1).GUID"') do set GUID=%%g
if not defined GUID (echo No connected network adapter >> %LOG%& goto failed)

rem WinPE's scratch space is small, so DISM works on the disk
mkdir %W%\Windows\Temp\dism 2>nul
dism /Image:%W%\ /ScratchDir:%W%\Windows\Temp\dism /Add-NetAdapter /? >> %LOG% 2>&1
dism /Image:%W%\ /ScratchDir:%W%\Windows\Temp\dism /Add-NetAdapter /HostAdapter:%GUID% /BootDriver:ms_tcpip /BootDriver:ms_tcpip6 >> %LOG% 2>&1
echo dism exited with %errorlevel% >> %LOG%
type %LOG%
wpeutil shutdown
goto :eof

:failed
if defined LOG type %LOG%
echo.
echo Stopped here.
