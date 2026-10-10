@echo off
rem WinPE's job on the build VM (docs/image.md). image\dc\prepare.ps1 fills in the @...@ values and serves this from the
rem domain controller as jobs\<mac>.cmd while a build runs, and WinPE fetches and runs it (image\winpe\startnet.cmd).
rem It installs Windows from the install share onto the iSCSI disk that iPXE attached, copies the first logon's files
rem into the new Windows, and restarts. iPXE then boots that disk. On a failure it stops at a prompt, and
rem image\build.sh times out.
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

rem The iSCSI disk must be the only disk, as the answer file wipes disk 0. WinPE connects it from the iBFT when it has
rem the NIC's driver.
echo list disk> X:\disks.txt
diskpart /s X:\disks.txt > X:\disks.out
type X:\disks.out
find "Disk 0" X:\disks.out >nul || (echo No disk: WinPE didn't connect to the iSCSI target in the iBFT& goto failed)
find "Disk 1" X:\disks.out >nul && (echo More than one disk& goto failed)

rem Windows 11's setup checks for Secure Boot, which is off: the stock iPXE is unsigned
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f >nul

rem The previous version of setup, sources\setup.exe: 24H2's new one has been seen to quit at an iSCSI disk. /noreboot
rem leaves time to copy files in afterwards.
echo Running setup
Z:\media\sources\setup.exe /unattend:Z:\build\autounattend.xml /noreboot
echo Setup exited with %errorlevel%
:wait
tasklist | find /i "setup" >nul || goto installed
ping -n 6 127.0.0.1 >nul
goto wait
:installed

set W=
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y) do if exist %%d:\Windows\System32\config\SOFTWARE set W=%%d:
if not defined W (echo Setup didn't install Windows: see X:\Windows\Panther\setupact.log& goto failed)
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
echo Restarting into the new Windows
ping -n 20 127.0.0.1 >nul
wpeutil reboot
goto :eof

:failed
echo.
echo The build stopped here.
