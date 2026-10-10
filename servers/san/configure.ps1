# Configure the storage server once join.ps1 has joined it to the domain (PLAN.md, phase 1; docs/servers.md): iSCSI
# Target Server, and its data disk for golden images and child disks. Run as admin, from a copy of the repo's servers/
# (setup.sh makes it, and runs this again after a restart it asks for). Safe to re-run.
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\common.ps1"
Wait-ServicingIdle

Step 'Windows Update: installs and restarts only when asked'
Set-UpdatePolicy

Step 'iSCSI Target Server'
Install-Feature FS-iSCSITarget-Server
# Started at once, the service can start before the static address is usable, fail to bind to it (event 10, error
# 10049), and then listen nowhere. Delayed, it starts a couple of minutes after boot.
sc.exe config WinTarget start= delayed-auto | Out-Null
if (-not (Get-NetTCPConnection -LocalPort 3260 -State Listen -ErrorAction SilentlyContinue)) { Restart-Service WinTarget }

Step "data disk as $($s.SanDataDrive):"
$label = 'iSCSI'
if (-not (Get-Volume -FileSystemLabel $label -ErrorAction SilentlyContinue)) {
  # The only blank disk. Windows Server leaves new disks offline and read-only.
  $disk = @(Get-Disk | Where-Object PartitionStyle -eq 'RAW')
  if ($disk.Count -ne 1) { throw "expected one blank data disk, found $($disk.Count)" }
  $disk[0] | Set-Disk -IsOffline $false
  $disk[0] | Set-Disk -IsReadOnly $false
  $disk[0] | Initialize-Disk -PartitionStyle GPT
  $disk[0] | New-Partition -UseMaximumSize -DriveLetter $s.SanDataDrive |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel $label | Out-Null
}
# Golden images (read-only parents) and the clients' differencing disks
foreach ($dir in 'images', 'clients') { New-Item -ItemType Directory -Force "$($s.SanDataDrive):\iSCSI\$dir" | Out-Null }

Step 'check'
Get-WindowsFeature FS-iSCSITarget-Server | ForEach-Object { "$($_.Name): $($_.InstallState)" }
Get-Volume -FileSystemLabel $label | ForEach-Object { "$($_.DriveLetter): $($_.FileSystem) $([math]::Round($_.Size / 1GB)) GB" }
$delayed = (Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\WinTarget).DelayedAutostart -eq 1
Get-Service WinTarget | ForEach-Object { "service $($_.Name): $($_.Status), $($_.StartType)$(if ($delayed) { ', delayed' })" }
Get-NetTCPConnection -LocalPort 3260 -State Listen | ForEach-Object { "listening on $($_.LocalAddress):3260" }
"Windows Update: AUOptions $((Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU).AUOptions)"
