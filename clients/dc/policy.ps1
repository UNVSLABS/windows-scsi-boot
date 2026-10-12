# The clients' OU and Group Policy (PLAN.md, phase 3; docs/clients.md), on the domain controller. clients/dc/new-client.ps1
# runs this first; safe to re-run. The GPO, linked to the OU that New-Client puts computer accounts in:
# - Windows Update off: updates come in new golden images, which keeps child disks small;
# - no sleep, hibernation or fast startup: the disk is on the network, and fast startup is a hibernation;
# - a fixed pagefile size (PagefileMB in settings.psd1), so the pagefile doesn't grow a child disk unseen;
# - NIC power saving off, by a startup script (clients/dc/nic-power.ps1): it's a setting of each NIC's device.
# The power and update settings are policies; the rest are preferences, as Windows has no policy for them.
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"
Import-Module ActiveDirectory, GroupPolicy

$domain = Get-ADDomain
$ou = "OU=$($s.ClientOu),$($domain.DistinguishedName)"
if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ou'")) {
  New-ADOrganizationalUnit $s.ClientOu -Path $domain.DistinguishedName -Description 'Diskless clients (windows-scsi-boot clients/)'
}
$gpo = Get-GPO -Name $s.ClientGpo -ErrorAction SilentlyContinue
if (-not $gpo) { $gpo = New-GPO -Name $s.ClientGpo -Comment 'Settings for diskless clients (windows-scsi-boot clients/dc/policy.ps1)' }
if (-not ((Get-GPInheritance -Target $ou).GpoLinks | Where-Object GpoId -eq $gpo.Id)) {
  New-GPLink -Guid $gpo.Id -Target $ou | Out-Null
}

# Policies, under HKLM\Software\Policies. Each change is a new version of the GPO, which every client applies again, so
# only what differs is set.
function Set-Policy($key, $name, $value) {
  $at = @{ Guid = $gpo.Id; Key = "HKLM\Software\Policies\$key"; ValueName = $name }
  if ((Get-GPRegistryValue @at -ErrorAction SilentlyContinue).Value -ne $value) {
    Set-GPRegistryValue @at -Type DWord -Value $value | Out-Null
  }
}
Set-Policy 'Microsoft\Windows\WindowsUpdate\AU' NoAutoUpdate 1 # Configure Automatic Updates: Disabled
# Power Management, plugged in and on battery: never sleep or hibernate, no sleep states (S1-S3) at all
foreach ($setting in @(
    '29F6C1DB-86DA-48C5-9FDB-F2B67B1F44DA' # Specify the system sleep timeout: 0, never
    '9D7815A6-7EE4-497E-8888-515A05F02364' # Specify the system hibernate timeout: 0, never
    'ABFC2519-3608-4C2A-94EA-171B0ED546AB' # Allow standby states (S1-S3) when sleeping: Disabled
  )) {
  Set-Policy "Microsoft\Power\PowerSettings\$setting" ACSettingIndex 0
  Set-Policy "Microsoft\Power\PowerSettings\$setting" DCSettingIndex 0
}

# Preferences, for settings outside the policy keys. Set-GPPrefRegistryValue adds an item each time, so one that
# differs is replaced.
function Set-Preference($key, $name, $type, $value) {
  $at = @{ Guid = $gpo.Id; Context = 'Computer'; Key = $key; ValueName = $name }
  $items = @(Get-GPPrefRegistryValue @at -ErrorAction SilentlyContinue)
  if ($items.Count -eq 1 -and "$($items[0].Type)" -eq $type -and "$($items[0].Value)" -eq "$value") { return }
  if ($items) { Remove-GPPrefRegistryValue @at | Out-Null }
  Set-GPPrefRegistryValue @at -Action Update -Type $type -Value $value | Out-Null
}
Set-Preference 'HKLM\SYSTEM\CurrentControlSet\Control\Power' HibernateEnabled DWord 0
Set-Preference 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power' HiberbootEnabled DWord 0 # fast startup
Set-Preference 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' PagingFiles MultiString `
  "C:\pagefile.sys $($s.PagefileMB) $($s.PagefileMB)" # initial and maximum size: fixed

# The startup script: the GPO's Machine\Scripts in SYSVOL, its scripts.ini, the scripts extension in the GPO's list of
# client-side extensions, and a new version number so that clients apply it. Through the local SYSVOL folder.
$sysvol = Join-Path (Get-SmbShare SYSVOL).Path "$($s.DomainName)\Policies\{$($gpo.Id)}"
$scripts = "$sysvol\Machine\Scripts"
New-Item -ItemType Directory -Force "$scripts\Startup" | Out-Null
$changed = $false
foreach ($file in @{ "$scripts\Startup\nic-power.ps1" = Get-Content "$PSScriptRoot\nic-power.ps1" -Raw
    # GPO startup scripts run with the execution policy, which doesn't allow scripts by default; so cmd starts it
    "$scripts\Startup\nic-power.cmd" = "@powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0nic-power.ps1`"`r`n"
    # Unicode, as the Group Policy editor writes it
    "$scripts\scripts.ini" = "`r`n[Startup]`r`n0CmdLine=nic-power.cmd`r`n0Parameters=`r`n" }.GetEnumerator()) {
  $encoding = if ($file.Key -like '*.ini') { [Text.Encoding]::Unicode } else { [Text.UTF8Encoding]::new($false) }
  if ((Test-Path $file.Key) -and [IO.File]::ReadAllText($file.Key) -eq $file.Value) { continue }
  if (Test-Path $file.Key) { Set-ItemProperty $file.Key Attributes Normal }
  [IO.File]::WriteAllText($file.Key, $file.Value, $encoding)
  $changed = $true
}
(Get-Item "$scripts\scripts.ini" -Force).Attributes = 'Hidden'
$cse = '[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]' # Scripts (Startup/Shutdown)
$gpc = Get-ADObject "CN={$($gpo.Id)},CN=Policies,CN=System,$($domain.DistinguishedName)" -Properties gPCMachineExtensionNames, versionNumber
$names = $gpc.gPCMachineExtensionNames
if (-not "$names".Contains($cse)) {
  # A list of [{extension}{tool}...] entries, sorted by the extension's GUID
  $entries = @([regex]::Matches("$names", '\[[^\]]+\]').Value) + $cse | Sort-Object
  Set-ADObject $gpc -Replace @{ gPCMachineExtensionNames = -join $entries }
  $changed = $true
}
if ($changed) {
  # The computer half of the version is its low 16 bits; GPT.INI in SYSVOL keeps the same number
  $version = (Get-ADObject $gpc -Properties versionNumber).versionNumber + 1
  Set-ADObject $gpc -Replace @{ versionNumber = $version }
  $ini = "$sysvol\GPT.INI"
  [IO.File]::WriteAllText($ini, ((Get-Content $ini -Raw) -replace '(?m)^Version=\d+', "Version=$version"))
}

"GPO $($s.ClientGpo), linked to $ou, version $((Get-GPO -Guid $gpo.Id).Computer.DSVersion)"
