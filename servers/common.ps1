# Shared by the server scripts, which dot-source it: the settings, and restarts that setup.sh follows up.

$root = Resolve-Path "$PSScriptRoot\.." # the copy of the repo that setup.sh makes on the server
$s = Import-PowerShellDataFile "$PSScriptRoot\settings.psd1"

function Step($text) { Write-Output "== $text" }

# The password setup.sh sends along in servers\secret.txt, which is deleted once read
function Read-Secret {
  $file = "$PSScriptRoot\secret.txt"
  if (-not (Test-Path $file)) { return $null }
  $secret = (Get-Content $file -TotalCount 1).Trim()
  Remove-Item $file -Force
  $secret
}

# Restart Windows and end the script. setup.sh waits for the restart, then runs the script again: each one skips what's
# done. New clones of the template install updates by themselves, and a restart they leave pending blocks a promotion
# and can fail a role's install.
function Restart-ForRerun($why) {
  shutdown.exe /r /t 5 /c "windows-scsi-boot: $why" | Out-Null
  Exit-ForRestart $why
}

function Test-RestartPending {
  (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
  (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}

# End the script for a restart, ours or one Windows started by itself, as servicing does to finish updates. setup.sh
# knows the restart has happened once the boot time differs from the one printed here.
function Exit-ForRestart($why) {
  "restarting: $why"
  "booted: " + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
  exit 0
}

# Call before changing anything. After a restart, servicing (TrustedInstaller) can go on installing updates, and then
# restarts Windows by itself. So wait for it to finish, and restart now if it left a restart pending.
function Wait-ServicingIdle {
  $deadline = (Get-Date).AddMinutes(30)
  while (Get-Process TiWorker -ErrorAction SilentlyContinue) {
    if ((Get-Date) -gt $deadline) { throw 'Windows servicing (TiWorker) was still busy after 30 minutes' }
    Start-Sleep 15
  }
  if (Test-RestartPending) { Restart-ForRerun 'updates are waiting for a restart' }
}

function Install-Feature([string[]]$Name) {
  try { $result = Install-WindowsFeature $Name -IncludeManagementTools }
  catch {
    if ("$_" -match '0x8007045b') { Exit-ForRestart 'Windows is already shutting down' } # ERROR_SHUTDOWN_IN_PROGRESS
    throw
  }
  if (-not $result.Success) { throw "installing $Name failed" }
  if ($result.RestartNeeded -eq 'Yes') { Restart-ForRerun "to finish installing $Name" }
}
