# Generalise the golden image with sysprep, add the clients' first boot (firstboot-entry.ps1), then power off
# (docs/image.md). First, the part of Windows' automatic maintenance that each client would otherwise do for itself.
# Run once as SYSTEM at the startup after firstlogon.ps1, or after reseal.ps1 when an image is changed, from
# C:\Windows\Setup\build. image/build.sh and change.sh wait for the build VM to stop. If sysprep fails, the VM stays on
# for a look. Log: C:\Windows\Temp\generalize.log
$ErrorActionPreference = 'Stop'
Start-Transcript C:\Windows\Temp\generalize.log
Unregister-ScheduledTask -TaskName generalize -Confirm:$false

# Sysprep refuses an encrypted disk. autounattend.xml stops Windows 11 encrypting it; this is in case it did anyway.
if ((Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) -and (Get-BitLockerVolume C:).VolumeStatus -ne 'FullyDecrypted') {
  'Decrypting C:'
  Disable-BitLocker C: | Out-Null
  while ((Get-BitLockerVolume C:).VolumeStatus -ne 'FullyDecrypted') { Start-Sleep 10 }
}

# Windows' automatic maintenance runs in a client's first idle minutes, and everything it moves or rewrites lands in the
# client's own child disk (docs/clients.md, Automatic maintenance). So nothing defragments a client's disk, which is
# never worth it:
# - no boot optimization: SysMain, the prefetcher, has defrag.exe -b move the files that start Windows and apps
#   together, unless EnableAutoLayout is 0;
# - no scheduled defrag. The first time defrag.exe runs after setup, whatever runs it, it registers its task again,
#   enabled, unless fUpgradeRestored says it has done so already.
# And .NET's queued native images are compiled here, once for every client. Not fatal: an image without them works,
# and clients compile them.
foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OptimalLayout', 'HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings') {
  if (-not (Test-Path $key)) { New-Item $key | Out-Null }
}
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OptimalLayout' EnableAutoLayout 0 -Type DWord
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName ScheduledDefrag | ForEach-Object { "scheduled defrag: $($_.State)" }
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings' fUpgradeRestored 1 -Type DWord
foreach ($ngen in Get-ChildItem "$env:SystemRoot\Microsoft.NET\Framework*\v4.*\ngen.exe") {
  $out = @(& $ngen.FullName executeQueuedItems /nologo)
  "$($ngen.FullName) executeQueuedItems: exit code $LASTEXITCODE, $(@($out -match 'Compiling assembly').Count) assemblies compiled"
}

# A smaller image: no downloaded updates. Trimming free space can't shrink it: the iSCSI target presents the disk as
# fully provisioned, so Windows can't trim it.
Remove-Item C:\Windows\SoftwareDistribution\Download\* -Recurse -Force -ErrorAction SilentlyContinue

# After updates, Windows goes on servicing them for a while, and sysprep fails if it asks in the meantime (0x80010108,
# "Failed to query pending CBS operations"). Wait for servicing to stop, then try a few times. Sysprep exits 0 even
# when it fails, so success is the image state it leaves. No /mode:vm: clients aren't the build VM's hardware.
Start-Sleep 60
for ($try = 1; $try -le 3; $try++) {
  for ($i = 0; (Get-Process TiWorker -ErrorAction SilentlyContinue) -and $i -lt 180; $i++) { Start-Sleep 10 }
  $p = Start-Process "$env:SystemRoot\System32\Sysprep\sysprep.exe" -Wait -PassThru `
    -ArgumentList "/generalize /oobe /quiet /quit /unattend:$PSScriptRoot\sysprep.xml"
  $state = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
  "sysprep try $try exited $($p.ExitCode), image state $state"
  if ($state -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
    # Then the clients' first boot: WinPE, which makes a client's NIC a boot NIC, as the boot manager's default
    # (docs/clients.md). If this fails, the VM stays on.
    & "$PSScriptRoot\firstboot-entry.ps1" -From "$PSScriptRoot\firstboot"
    # Sysprep has its own copy of the answers, and Windows blanks its passwords once a client uses them. This folder's
    # copies, and the build's other files, go.
    Set-Location C:\
    Remove-Item $PSScriptRoot -Recurse -Force
    Remove-Item C:\Windows\Temp\diskless -Recurse -Force -ErrorAction SilentlyContinue # a change's copy of the repo
    Stop-Transcript
    Stop-Computer -Force
    exit 0
  }
  Get-Content C:\Windows\System32\Sysprep\Panther\setuperr.log -Tail 6
  Start-Sleep 60
}
'sysprep failed: the VM stays on. See C:\Windows\System32\Sysprep\Panther\setuperr.log'
Stop-Transcript
