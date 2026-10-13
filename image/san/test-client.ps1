# A test client's disk for image/nic-test.sh (PLAN.md, NIC independence; docs/image.md): a new differencing disk
# <data drive>:\iSCSI\clients\<name>.vhdx on golden-v<version>, on target <name>, which accepts only the client's
# initiator. For three of the variants, it also changes the disk's Windows before its first boot:
#   bootflags   BootFlags 1 (load when booting from the network) on the services of the image's network adapters
#   bootstart   that, and Start 0 (load at boot)
#   reflect     the image's NIC driver packages that no installed adapter uses reflected as boot critical, through the
#               Net class's boot-critical mark, and BootFlags 1 on their services
# Prints the target's IQN. Run as admin. Replaces a test client of the same name. With -Remove, removes it instead.
param(
  [Parameter(Mandatory)][int]$Version,
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string]$InitiatorIqn,
  [ValidateSet('none', 'bootflags', 'bootstart', 'reflect', 'netadapter', 'remove')][string]$Variant = 'none'
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

# reg.exe as SYSTEM, through a one-off scheduled task: admins can't open a device class's Properties key. Returns reg's
# exit code.
function Invoke-RegAsSystem([string]$Arguments) {
  $task = 'diskless-reg'
  $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\reg.exe" -Argument $Arguments
  Register-ScheduledTask $task -Action $action -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest -Force | Out-Null
  try {
    Start-ScheduledTask $task
    $deadline = (Get-Date).AddMinutes(1)
    while (($result = (Get-ScheduledTaskInfo $task).LastTaskResult) -in 0x41303, 0x41301) { # not run yet, running
      if ((Get-Date) -gt $deadline) { throw "reg $Arguments didn't finish as SYSTEM" }
      Start-Sleep -Milliseconds 500
    }
    $result
  } finally { Unregister-ScheduledTask $task -Confirm:$false }
}

if ($Variant -eq 'reflect') {
  Step "$Name`: reflect"
  # The kernel sets up a NIC at boot only from a driver package reflected into the SYSTEM hive's driver database, and
  # Windows reflects a package only if its device class is marked boot critical (DEVPKEY_DeviceClass_BootCritical). The
  # Net class isn't, so DISM only stages NIC drivers, and setup forces it just for the NICs in the iBFT (docs/image.md,
  # NIC independence). So: the SCSIAdapter class's mark copied to the Net class; each NIC driver package removed and added
  # again by DISM, which now reflects it; the mark removed; and BootFlags 1 on the packages' services.
  $hive = 'HKLM\diskless-test'
  $mark = 'Properties\{6a3433f4-5626-40e8-a9b9-dbd9ecd2884b}\0003'
  $scsiAdapter, $net = '{4d36e97b-e325-11ce-bfc1-08002be10318}', '{4d36e972-e325-11ce-bfc1-08002be10318}'
  $copies = "$env:TEMP\diskless-reflect"
  Use-WindowsVolume $path {
    param($volume)
    # reg.exe only while the hive is loaded: the registry provider's handles would stop the unload
    reg load $hive "$volume\Windows\System32\config\SYSTEM" | Out-Null
    if ($LASTEXITCODE) { throw 'reg load failed' }
    try {
      $current = (reg query "$hive\Select" /v Current | Select-String 'REG_DWORD\s+0x([0-9a-f]+)').Matches[0].Groups[1].Value
      $set = "$hive\ControlSet{0:d3}" -f [Convert]::ToInt32($current, 16)
      # The packages of the installed network adapters (the build NIC's, kept by sysprep) are left as they are
      $used = foreach ($key in reg query "$set\Control\Class\$net" | Where-Object { $_ -match '\\\d{4}\s*$' }) {
        reg query $key.Trim() /v InfPath | Select-String 'InfPath\s+REG_SZ\s+(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }
      }
      $code = Invoke-RegAsSystem "copy `"$set\Control\Class\$scsiAdapter\$mark`" `"$set\Control\Class\$net\$mark`" /s /f"
      if ($code) { throw "the boot-critical mark on the Net class: reg exited with $code" }
    } finally { reg unload $hive | Out-Null }
    "installed adapters' packages: $($used -join ', ')"

    $packages = @(Get-WindowsDriver -Path "$volume\" | Where-Object { $_.ClassName -eq 'Net' -and $_.Driver -notin $used })
    Remove-Item $copies -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($p in $packages) {
      $inf = Split-Path $p.OriginalFileName -Leaf
      if (-not (Test-Path $p.OriginalFileName)) { throw "no $($p.OriginalFileName)" }
      Copy-Item (Split-Path $p.OriginalFileName) "$copies\$($p.Driver)" -Recurse # the package's files, for adding it again
      dism /English /Image:$volume\ /Remove-Driver /Driver:$($p.Driver) | Out-Null
      if ($LASTEXITCODE) { throw "dism /Remove-Driver $($p.Driver) ($inf) exited with $LASTEXITCODE" }
      dism /English /Image:$volume\ /Add-Driver /Driver:$copies\$($p.Driver)\$inf | Out-Null
      if ($LASTEXITCODE) { throw "dism /Add-Driver $inf exited with $LASTEXITCODE" }
      "added again: $inf, $($p.ProviderName) $($p.Version)"
    }
    Remove-Item $copies -Recurse -Force
    $packages = @(Get-WindowsDriver -Path "$volume\" | Where-Object { $_.ClassName -eq 'Net' -and $_.Driver -notin $used })
    $services = foreach ($p in $packages) {
      (dism /English /Image:$volume\ /Get-DriverInfo /Driver:$($p.Driver) | Select-String 'Service Name : (\S+)').Matches |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    }

    reg load $hive "$volume\Windows\System32\config\SYSTEM" | Out-Null
    if ($LASTEXITCODE) { throw 'reg load failed' }
    try {
      $code = Invoke-RegAsSystem "delete `"$set\Control\Class\$net\$mark`" /f"
      if ($code) { throw "removing the Net class's boot-critical mark: reg exited with $code" }
      foreach ($p in $packages) { # reflected: in the SYSTEM hive's driver database, not the DRIVERS hive's
        $out = cmd /c "reg query $hive\DriverDatabase\DriverInfFiles\$($p.Driver) 2>&1"
        $state = if (-not $LASTEXITCODE) { 'reflected' } elseif ("$out" -match 'denied') { "unknown: $out" } else { 'NOT reflected' }
        "$($p.Driver), $(Split-Path $p.OriginalFileName -Leaf): $state"
      }
      foreach ($service in $services) {
        reg add "$set\Services\$service" /v BootFlags /t REG_DWORD /d 1 /f | Out-Null
        if ($LASTEXITCODE) { throw "BootFlags on $service failed" }
        "service $service`: " + ((reg query "$set\Services\$service" | Select-String '^\s+(Start|BootFlags)\s+REG_DWORD\s+(\S+)').Matches |
          ForEach-Object { "$($_.Groups[1].Value) $([Convert]::ToInt32($_.Groups[2].Value, 16))" }) -join ', '
      }
    } finally { reg unload $hive | Out-Null }
  }
}

Step "$Name`: target $Name, for $InitiatorIqn only"
if (-not $t) { New-IscsiServerTarget -TargetName $Name -InitiatorIds "IQN:$InitiatorIqn" | Out-Null }
else { Set-IscsiServerTarget -TargetName $Name -InitiatorIds "IQN:$InitiatorIqn" }
Add-IscsiVirtualDiskTargetMapping -TargetName $Name -Path $path
"target-iqn: $((Get-IscsiServerTarget -TargetName $Name).TargetIqn)"
