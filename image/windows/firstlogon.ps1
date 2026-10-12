# First-logon provisioning of the golden image (docs/image.md), run once by autounattend.xml from C:\Windows\Setup\build,
# where WinPE copied it. Installs the QEMU guest agent, OpenSSH, updates if there's a file `updates` here, and RDP, and
# sets the iSCSI timeout. Then it sets generalize.ps1 to run at the next startup and restarts. The drivers are already
# in: setup added the driver pack.
# Log: C:\Windows\Temp\firstlogon.log
$ErrorActionPreference = 'Stop'
Start-Transcript C:\Windows\Temp\firstlogon.log

# Windows Update would start on its own now, and everything below would wait for it, and so would sysprep. Clients get
# updates in new golden images instead, so it stays off in the image too.
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item $au -Force | Out-Null
Set-ItemProperty $au NoAutoUpdate 1 -Type DWord

# The guest agent, which VMs' clients have (lab/main.tf). On a physical machine its service stays stopped.
$p = Start-Process msiexec "/i `"$PSScriptRoot\qemu-ga-x86_64.msi`" /qn /norestart" -Wait -PassThru
if ($p.ExitCode -notin 0, 3010) { throw "guest agent MSI exited with $($p.ExitCode)" }

# The network is up already: Windows boots over it. Wait for the internet.
$nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
for ($i = 0; ; $i++) {
  try { Invoke-WebRequest http://www.msftconnecttest.com/connecttest.txt -UseBasicParsing | Out-Null; break }
  catch { if ($i -ge 60) { throw }; Start-Sleep 5 }
}
try { Set-NetConnectionProfile -InterfaceIndex $nic.ifIndex -NetworkCategory Private } catch { "Network profile left as is: $_" }

# SSH with the servers' keys and the account's password. Admins' keys live in administrators_authorized_keys, readable
# only by admins and SYSTEM. Windows 11 has OpenSSH Server only as an optional feature from Windows Update, which can
# take half an hour on a fresh install, so it gets Microsoft's own MSI from GitHub instead.
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
  $msi = "$env:TEMP\OpenSSH-Win64.msi"
  Invoke-WebRequest https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-Win64-v10.0.0.0.msi -OutFile $msi -UseBasicParsing
  if ((Get-FileHash $msi -Algorithm SHA256).Hash -ne 'DDEC9C53864280759CF9F74791CEFD387100E3946AA849A1C138A4ED1B96B7D9') { throw 'OpenSSH MSI checksum mismatch' }
  $p = Start-Process msiexec "/i `"$msi`" /qn /norestart" -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "OpenSSH MSI exited with $($p.ExitCode)" }
  Remove-Item $msi
}
Set-Service sshd -StartupType Automatic
New-Item -ItemType Directory -Force "$env:ProgramData\ssh" | Out-Null
$keys = "$env:ProgramData\ssh\administrators_authorized_keys"
Get-Content "$PSScriptRoot\authorized_keys" | Set-Content $keys -Encoding ascii
icacls $keys /inheritance:r /grant '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
if (-not (Get-NetFirewallRule -Name OpenSSH-Server-In-TCP -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name OpenSSH-Server-In-TCP -DisplayName 'OpenSSH SSH Server (sshd)' -Protocol TCP -LocalPort 22 -Action Allow | Out-Null
}
Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -Profile Any

# Updates, with build.sh --updates. Optional ones (e.g. the next feature update) are skipped. Windows Update's API only
# works in a local session like this one, and the policy above doesn't stop it. Not fatal: the image is usable without.
if (Test-Path "$PSScriptRoot\updates") {
  try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $updates = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software' and BrowseOnly=0").Updates
    if ($updates.Count) {
      foreach ($u in $updates) { if (-not $u.EulaAccepted) { $u.AcceptEula() } }
      $downloader = $session.CreateUpdateDownloader(); $downloader.Updates = $updates; $downloader.Download() | Out-Null
      $installer = $session.CreateUpdateInstaller(); $installer.Updates = $updates
      "Installed $($updates.Count) updates, result code $($installer.Install().ResultCode)"
    }
  } catch { "Windows Update failed: $_" }
}

# RDP and ping
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' fDenyTSConnections 0
Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'
New-NetFirewallRule -Name allow-ping -DisplayName 'Ping' -Protocol ICMPv4 -IcmpType 8 -Action Allow | Out-Null

# Clients never sleep or hibernate: the disk is on the network, and fast startup is a hibernation
powercfg /change standby-timeout-ac 0
powercfg /hibernate off

# Clients wait for their disk while the storage server restarts, rather than going down
& "$PSScriptRoot\iscsi-timeouts.ps1"

# Generalise after a restart, which lets updates finish first: generalize.ps1 runs as SYSTEM at the next startup
$action = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -File $PSScriptRoot\generalize.ps1"
Register-ScheduledTask -TaskName generalize -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -User SYSTEM -RunLevel Highest | Out-Null

# Auto-logon is spent; remove it and the answer file's copies of the password
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $winlogon AutoAdminLogon '0'
Remove-ItemProperty $winlogon DefaultPassword -ErrorAction SilentlyContinue
Remove-Item C:\Windows\Panther\unattend.xml, C:\Windows\Panther\Unattend -Recurse -Force -ErrorAction SilentlyContinue

Stop-Transcript
Restart-Computer -Force
