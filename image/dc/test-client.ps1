# A test client's boot for image/nic-test.sh (docs/golden-image.md): its clients/<mac>.ipxe on the domain controller,
# and its WinPE job, jobs/<mac>.cmd. Mode:
#   windows      its menu (boot/client.ipxe), which boots Windows from its disk
#   netadapter   WinPE with its disk attached. Its job (image/winpe/netadapter.cmd) makes the client's NIC a boot NIC of
#                the Windows on that disk, then powers off.
#   remove       neither: the client gets the menu for machines that aren't clients
# Run as admin.
param(
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string]$Mac,
  [Parameter(Mandatory)][ValidateSet('windows', 'netadapter', 'remove')][string]$Mode,
  [string]$InitiatorIqn,
  [string]$TargetIqn
)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"

$id = $Mac.ToLower() -replace ':', '-' # as iPXE's ${net0/mac:hexhyp}
$script = "$($s.BootFiles)\clients\$id.ipxe"
$job = "$($s.BootFiles)\jobs\$id.cmd"
Remove-Item $job -Force -ErrorAction SilentlyContinue
if ($Mode -eq 'remove') {
  Remove-Item $script -Force -ErrorAction SilentlyContinue
  "removed $Name's boot script"
  return
}
if (-not $InitiatorIqn -or -not $TargetIqn) { throw 'need the initiator and the target' }

Copy-Item "$root\boot\*.ipxe" $s.BootFiles -Force
$lines = @(
  '#!ipxe'
  "# $Name, a test client of image/nic-test.sh ($Mode)"
  "set client $Name"
  "set initiator-iqn $InitiatorIqn"
  "set root-path iscsi:$($s.SanAddress)::::$TargetIqn"
)
if ($Mode -eq 'windows') { $lines += 'chain ../client.ipxe' } else {
  $lines += @(
    'set net0/gateway 0.0.0.0' # not into the iBFT, as boot/client.ipxe
    'sanhook ${root-path} || shell'
    'kernel ../wimboot || shell'
    'initrd ../winpe/BCD BCD || shell'
    'initrd ../winpe/boot.sdi boot.sdi || shell'
    'initrd ../winpe/boot.wim boot.wim || shell'
    'boot || shell'
  )
  New-Item -ItemType Directory -Force (Split-Path $job) | Out-Null
  [IO.File]::WriteAllText($job, ((Get-Content "$root\image\winpe\netadapter.cmd" -Raw) -replace '\r?\n', "`r`n")) # cmd wants CRLF
}
[IO.File]::WriteAllText($script, ($lines -join "`n") + "`n")
icacls $s.BootFiles /reset /t /q | Out-Null # IIS's anonymous user must be able to read every file
"$Name`: $Mode, $id"
