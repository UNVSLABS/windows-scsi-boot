# A test client's disk for image/nic-test.sh (PLAN.md, NIC independence; docs/image.md): a new differencing disk
# <data drive>:\iSCSI\clients\<name>.vhdx on golden-v<version>, on target <name>, which accepts only the client's
# initiator. For two of the variants, it also changes the disk's Windows before its first boot, in its registry:
#   bootflags   BootFlags 1 (load when booting from the network) on the services of the image's network adapters
#   bootstart   that, and Start 0 (load at boot)
# Prints the target's IQN. Run as admin. Replaces a test client of the same name. With -Remove, removes it instead.
param(
  [Parameter(Mandatory)][int]$Version,
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string]$InitiatorIqn,
  [ValidateSet('none', 'bootflags', 'bootstart', 'netadapter', 'remove')][string]$Variant = 'none'
)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"

$parent = "$($s.SanDataDrive):\iSCSI\images\golden-v$Version.vhdx"
$path = "$($s.SanDataDrive):\iSCSI\clients\$Name.vhdx"
if (-not (Test-Path $parent) -or -not (Get-Item $parent).IsReadOnly) { throw "golden-v$Version isn't built and sealed" }

Wait-TargetIdle $Name # nic-test.sh runs this while the client is off
$t = Get-IscsiServerTarget -TargetName $Name -ErrorAction SilentlyContinue
if (Get-IscsiVirtualDisk -Path $path -ErrorAction SilentlyContinue) { Remove-IscsiVirtualDisk -Path $path }
Remove-Item $path -Force -ErrorAction SilentlyContinue
if ($Variant -eq 'remove') {
  if ($t) { Remove-IscsiServerTarget -TargetName $Name }
  "removed $Name's disk and target"
  return
}

Step "$Name`: a new disk on golden-v$Version"
New-IscsiVirtualDisk -Path $path -ParentPath $parent | Out-Null

if ($Variant -in 'bootflags', 'bootstart') {
  Step "$Name`: $Variant"
  $hive = 'HKLM\diskless-test'
  Use-WindowsVolume $path {
    param($volume)
    reg load $hive "$volume\Windows\System32\config\SYSTEM" | Out-Null
    if ($LASTEXITCODE) { throw "reg load failed" }
    try {
      $set = "HKLM:\diskless-test\ControlSet00$((Get-ItemProperty HKLM:\diskless-test\Select).Current)"
      # The services of the network adapters that Windows has installed: drivers only staged in the driver store have none
      $net = '{4d36e972-e325-11ce-bfc1-08002be10318}'
      $services = Get-ChildItem "$set\Enum\PCI" | Get-ChildItem | Get-ItemProperty |
        Where-Object ClassGUID -eq $net | ForEach-Object Service | Sort-Object -Unique
      foreach ($service in $services) {
        Set-ItemProperty "$set\Services\$service" BootFlags 1 -Type DWord
        if ($Variant -eq 'bootstart') { Set-ItemProperty "$set\Services\$service" Start 0 -Type DWord }
        $v = Get-ItemProperty "$set\Services\$service"
        "service $service`: Start $($v.Start), BootFlags $($v.BootFlags)"
      }
      # The pack's NIC drivers that have no service: Windows hasn't installed them on any device
      foreach ($service in 'netkvm', 'e1i68x64', 'vmxnet3ndis6') {
        if (-not (Test-Path "$set\Services\$service")) { "service $service`: none" }
      }
      Remove-Variable v -ErrorAction SilentlyContinue
    } finally {
      [gc]::Collect(); [gc]::WaitForPendingFinalizers() # the registry provider's handles, or the unload fails
      reg unload $hive 2>&1 | Out-Null
    }
  }
}

Step "$Name`: target $Name, for $InitiatorIqn only"
if (-not $t) { New-IscsiServerTarget -TargetName $Name -InitiatorIds "IQN:$InitiatorIqn" | Out-Null }
else { Set-IscsiServerTarget -TargetName $Name -InitiatorIds "IQN:$InitiatorIqn" }
Add-IscsiVirtualDiskTargetMapping -TargetName $Name -Path $path
"target-iqn: $((Get-IscsiServerTarget -TargetName $Name).TargetIqn)"
