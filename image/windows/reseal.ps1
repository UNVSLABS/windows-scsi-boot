# Seal a changed golden image again, for image/change.sh --seal (PLAN.md, Client lifecycle; docs/image.md). Runs as
# admin over SSH on the build VM, in the Windows of the image being changed, with the image's password in
# servers\secret.txt. It leaves in C:\Windows\Setup\build what a build leaves there for generalize.ps1: the answers for
# clients' first boot (sysprep.xml, which holds the password), and the clients' first boot itself, the image's own WinPE
# with the repo's firstboot.ps1. A task then runs generalize.ps1 as SYSTEM at the next startup, and Windows restarts:
# sysprep, the first boot's boot entry again (firstboot-entry.ps1), and power off.
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"
$password = Read-Secret # first, so that it's deleted whatever happens next
if ($password -notmatch '^[A-Za-z0-9]{16,}$') { throw 'need the image password, 16+ letters and digits, in secret.txt' }

$build = 'C:\Windows\Setup\build'
$diskless = 'C:\Windows\Setup\Diskless'
Step "generalize.ps1 and its files, in $build"
New-Item -ItemType Directory -Force "$build\firstboot" | Out-Null
icacls $build /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
Expand-Template "$root\image\windows\sysprep.xml" "$build\sysprep.xml" @{
  LOCALE = $s.Locale; UI_LANGUAGE = $s.UILanguage; TIMEZONE = $s.TimeZone; USER = $s.ImageUser; PASSWORD = $password
}
Copy-Item "$root\image\windows\generalize.ps1", "$root\image\windows\firstboot-entry.ps1" $build -Force
# Moved, as firstboot-entry.ps1 moves them back. WinPE stays the one the image was built with; the step is the repo's.
foreach ($file in 'firstboot.wim', 'boot.sdi') {
  if (Test-Path "$diskless\$file") { Move-Item "$diskless\$file" "$build\firstboot" -Force }
  if (-not (Test-Path "$build\firstboot\$file")) { throw "no $diskless\$file`: this image has no first boot for clients" }
}
Copy-Item "$root\image\winpe\firstboot.ps1" "$build\firstboot" -Force
# This change's own first boot, on the build VM: each client's log starts with its own
Remove-Item C:\Windows\Temp\firstboot.log -Force -ErrorAction SilentlyContinue
Get-ChildItem $build -Recurse -File | ForEach-Object { "{0}, {1:n0} KB" -f $_.FullName, ($_.Length / 1KB) }

Step 'generalize.ps1 at the next startup, then a restart'
$action = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -File $build\generalize.ps1"
Register-ScheduledTask -TaskName generalize -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -User SYSTEM `
  -RunLevel Highest -Force | Out-Null
shutdown.exe /r /t 10 /c 'windows-scsi-boot: sealing the golden image (image/change.sh)' | Out-Null
'Windows restarts in 10 seconds; generalize.ps1 then runs sysprep and powers off'
