@echo off
rem WinPE's job on the build VM (docs/image.md). image\dc\prepare.ps1 fills in the @...@ values and serves this from the
rem domain controller as jobs\<mac>.cmd while a build runs, and WinPE fetches and runs it (image\winpe\startnet.cmd).
rem It installs Windows from the install share onto the iSCSI disk that iPXE attached, copies the first logon's files
rem into the new Windows, and powers off. image\build.sh then boots that disk. On a failure it stops at a prompt, and
rem build.sh times out.
echo.
echo Building a golden image: Windows setup from \\@DC@\install onto the iSCSI disk

rem The share, by address: WinPE takes the boot NIC's settings from the iBFT, which may have no DNS server. The network
rem can take a minute to come up.
for /l %%i in (1,1,30) do (
  net use Z: \\@DC@\install /user:@ACCOUNT@ @SHARE_PASSWORD@ >nul 2>&1 && goto mapped
  ping -n 6 127.0.0.1 >nul
)
echo Couldn't map \\@DC@\install
goto failed
:mapped

rem The iBFT's disk, the build disk. WinPE connects it once the NIC's driver has loaded, which can take a minute or two
rem more.
for /l %%i in (1,1,36) do (
  powershell -NoProfile -Command "exit [int](@(Get-Disk).Count -lt 1)" && goto disks
  ping -n 6 127.0.0.1 >nul
)
echo No disk: WinPE didn't connect to the iSCSI target in the iBFT
powershell -NoProfile -Command "Get-Disk | Format-Table Number, FriendlyName, Size, BusType -AutoSize"
goto diagnose
:disks
powershell -NoProfile -Command "Get-Disk | Format-Table Number, FriendlyName, Size, BusType -AutoSize"

rem Setup installs onto the largest disk, the build disk: the answer file's DiskID 0 becomes its number, in a copy
set DISK=
for /f %%n in ('powershell -NoProfile -Command "(Get-Disk | Sort-Object Size | Select-Object -Last 1).Number"') do set DISK=%%n
if not defined DISK (echo No disk number& goto failed)
powershell -NoProfile -Command "(Get-Content Z:\build\autounattend.xml -Raw).Replace('<DiskID>0</DiskID>', '<DiskID>%DISK%</DiskID>') | Set-Content X:\autounattend.xml -Encoding UTF8" || goto failed
echo Installing onto disk %DISK%

rem Windows 11's setup checks for Secure Boot, which is off: the stock iPXE is unsigned
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f >nul

rem The previous version of setup, sources\setup.exe: 24H2's new one has been reported to quit at an iSCSI disk.
rem /noreboot leaves time to copy files in afterwards.
echo Running setup
Z:\media\sources\setup.exe /unattend:X:\autounattend.xml /noreboot
echo Setup exited with %errorlevel%
rem In case setup left a process running. WinPE has no tasklist or findstr.
:wait
powershell -NoProfile -Command "exit [int][bool](Get-Process setup, SetupHost -ErrorAction SilentlyContinue)" && goto installed
ping -n 6 127.0.0.1 >nul
goto wait
:installed

set W=
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y) do if exist %%d:\Windows\System32\config\SOFTWARE set W=%%d:
if not defined W (
  echo Setup didn't install Windows. Its errors, from X:\Windows\Panther\setuperr.log:
  type X:\Windows\Panther\setuperr.log
  goto failed
)
echo Copying the first logon's files into %W%\Windows\Setup\build
xcopy Z:\build\windows %W%\Windows\Setup\build\ /e /i /q /y || goto failed

rem What setup left for booting from the network: the NIC drivers' and iSCSI's services, and whether each loads at boot
rem (Start 0) or when booting from the network (BootFlags 1). Log: Windows\Temp\winpe-build.log.
set LOG=%W%\Windows\Temp\winpe-build.log
reg load HKLM\diskless %W%\Windows\System32\config\SYSTEM >nul || goto failed
for %%s in (e1iexpress e1i68x64 netkvm vmxnet3ndis6 iScsiPrt MSiSCSI Tcpip) do (
  echo %%s>> %LOG%
  reg query HKLM\diskless\ControlSet001\Services\%%s /v Start >> %LOG% 2>&1
  reg query HKLM\diskless\ControlSet001\Services\%%s /v BootFlags >> %LOG% 2>&1
)
reg unload HKLM\diskless >nul
type %LOG%
rem Off, not restarted: build.sh sets the build VM's boot to the new Windows
echo Powering off: image\build.sh then boots the new Windows
ping -n 20 127.0.0.1 >nul
wpeutil shutdown
goto :eof

:diagnose
rem Why there's no disk. Windows routes iSCSI through the iBFT's gateway: the routes, the reply from the target, and the
rem connection's TCP state. Then the boot session: the iSCSI Initiator service starts only once WinPE's Event Log is
rem out of its reduced mode, a WinPE bug since Windows 10 2004. A session with no connections is retrying.
echo.
ipconfig | find "IPv4"
ipconfig | find "Gateway"
route print -4 | find "@SAN@"
ping -n 2 @SAN@ | find "@SAN@"
netstat -an | find ":3260"
net stop eventlog >nul 2>&1
reg delete HKLM\SYSTEM\CurrentControlSet\Control\MiniNT /f >nul 2>&1
net start eventlog >nul 2>&1
net start msiscsi >nul 2>&1
iscsicli SessionList | find "Name"
iscsicli SessionList | find "Connections"
goto failed

:failed
echo.
echo The build stopped here.
