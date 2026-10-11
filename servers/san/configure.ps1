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
# The service can start before the static address is usable, fail to bind to it (event 10, error 10049), and then
# listen nowhere. It can't be made to start later: Windows refuses delayed start for it (error 87), as it's in a load
# order group. So it's restarted here if it isn't listening.
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

if ($s.SanSecondAddress) {
  Step "second address $($s.SanSecondAddress), for the build VM's second NIC (image/, docs/image.md)"
  # iPXE puts a disk's NIC in the iBFT by routing to its target, so the build's second disk needs an address of its own.
  # Never a source address, so Windows neither sends from it nor registers it in DNS.
  if (-not (Get-NetIPAddress -IPAddress $s.SanSecondAddress -ErrorAction SilentlyContinue)) {
    $nic = (Get-NetIPAddress -IPAddress $s.SanAddress).InterfaceAlias
    New-NetIPAddress -InterfaceAlias $nic -IPAddress $s.SanSecondAddress -PrefixLength $s.Network.Split('/')[1] `
      -SkipAsSource $true | Out-Null
    Start-Sleep 5 # until the iSCSI target lists the new address as a portal
  }
  # The iSCSI target lists a portal for each address, but serves only those enabled
  $portal = (Get-IscsiTargetServerSetting).Portals | Where-Object { "$($_.IPEndpoint.Address)" -eq $s.SanSecondAddress }
  if (-not $portal.Enabled) { Set-IscsiTargetServerSetting -IP $s.SanSecondAddress -Port 3260 -Enable $true }
}

Step 'check'
Get-WindowsFeature FS-iSCSITarget-Server | ForEach-Object { "$($_.Name): $($_.InstallState)" }
Get-Volume -FileSystemLabel $label | ForEach-Object { "$($_.DriveLetter): $($_.FileSystem) $([math]::Round($_.Size / 1GB)) GB" }
Get-Service WinTarget | ForEach-Object { "service $($_.Name): $($_.Status), $($_.StartType)" }
Get-NetTCPConnection -LocalPort 3260 -State Listen | ForEach-Object { "listening on $($_.LocalAddress):3260" }
(Get-IscsiTargetServerSetting).Portals | Where-Object { $_.IPEndpoint.AddressFamily -eq 'InterNetwork' } |
  ForEach-Object { "portal $($_.IPEndpoint): $(if ($_.Enabled) { 'enabled' } else { 'disabled' })" }
"Windows Update: AUOptions $((Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU).AUOptions)"
