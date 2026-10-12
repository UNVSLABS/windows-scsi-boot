@echo off
rem The startup of the first-boot WinPE (docs/clients.md), which image\dc\prepare.ps1 makes from the network WinPE with
rem this as its startnet.cmd, and the golden image's build puts into the image (image\windows\firstboot-entry.ps1).
rem Windows Boot Manager boots it from the client's own disk on the client's first boot. WinPE connects that disk from the iBFT once the NIC's driver has loaded,
rem which can take a minute or two; then this runs the first-boot step from it (image\winpe\firstboot.ps1).
wpeinit
echo.
echo A diskless client's first boot: making its NIC a boot NIC of its Windows
set W=
for /l %%i in (1,1,36) do (
  for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist %%d:\Windows\Setup\Diskless\firstboot.ps1 set W=%%d:
  if defined W goto found
  ping -n 6 127.0.0.1 >nul
)
echo No disk: WinPE didn't connect the iSCSI disk in the iBFT.
goto :eof
:found
powershell -NoProfile -ExecutionPolicy Bypass -File %W%\Windows\Setup\Diskless\firstboot.ps1
echo.
echo The first boot stopped here. Its log: %W%\Windows\Temp\firstboot.log. The next start tries again.
