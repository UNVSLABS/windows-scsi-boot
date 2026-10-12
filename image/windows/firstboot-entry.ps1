# The clients' first boot (docs/clients.md), put into the golden image by generalize.ps1 once sysprep has generalised it:
# WinPE (firstboot.wim) as a RAM disk image on the Windows volume, the script it runs (image/winpe/firstboot.ps1), and a
# boot entry for it as Windows Boot Manager's default. Each client's first boot then starts this WinPE, which makes the
# client's NIC a boot NIC of this Windows, sets the default back to Windows, and restarts. Made here, by the running
# Windows, so that the entry finds its files by the Windows partition's own identity, which every child disk of the
# image shares: bcdedit on the storage server, with the image mounted, ties such an entry to the VHDX file it mounted.
param([Parameter(Mandatory)][string]$From) # the folder with firstboot.wim, boot.sdi and firstboot.ps1
$ErrorActionPreference = 'Stop'
$firstBoot = '{bd965c03-fdb1-459d-9aa1-04822bba2c6b}' # the entry, as image/winpe/firstboot.ps1 knows it
$c = $env:SystemDrive
$dir = "$c\Windows\Setup\Diskless"

New-Item -ItemType Directory -Force $dir | Out-Null
# Moved, not copied: a copy's blocks would stay in the image's VHDX after generalize.ps1 deletes the build's files
Move-Item "$From\firstboot.wim", "$From\boot.sdi", "$From\firstboot.ps1" $dir -Force
function Bcd { $out = bcdedit @args 2>&1; if ($LASTEXITCODE) { throw "bcdedit $args`: $out" }; $out }
foreach ($id in $firstBoot, '{ramdiskoptions}') { bcdedit /delete $id /f 2>&1 | Out-Null } # from the start, if there
Bcd /create '{ramdiskoptions}' /d 'First boot (windows-scsi-boot)' | Out-Null
Bcd /set '{ramdiskoptions}' ramdisksdidevice "partition=$c" | Out-Null
Bcd /set '{ramdiskoptions}' ramdisksdipath '\Windows\Setup\Diskless\boot.sdi' | Out-Null
Bcd /create $firstBoot /d 'First boot: the NIC (windows-scsi-boot)' /application osloader | Out-Null
$device = "ramdisk=[$c]\Windows\Setup\Diskless\firstboot.wim,{ramdiskoptions}"
Bcd /set $firstBoot device $device | Out-Null
Bcd /set $firstBoot osdevice $device | Out-Null
Bcd /set $firstBoot path '\Windows\System32\Boot\winload.efi' | Out-Null
Bcd /set $firstBoot systemroot '\Windows' | Out-Null
Bcd /set $firstBoot winpe yes | Out-Null
Bcd /set $firstBoot detecthal yes | Out-Null
# The default, and first in the boot manager's list: it starts only entries in its list, whatever the default. With no
# time to choose, it shows no menu. firstboot.ps1 takes the entry out of the list again.
Bcd /displayorder $firstBoot /addfirst | Out-Null
Bcd /default $firstBoot | Out-Null
Bcd /timeout 0 | Out-Null
Bcd /enum $firstBoot
