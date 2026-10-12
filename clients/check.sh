#!/usr/bin/env bash
# Show diskless clients' state (docs/clients.md), from the PC in WSL, with the Proxmox token loaded as for Terraform:
#   clients/check.sh [--boot] <name>...
# With --boot, it first starts those that are Proxmox VMs and off, all at once, and waits up to 30 minutes for each to
# be set up and joined to the domain. Then for each client: from the storage server, its disk and whether its target has
# a session (clients/san/show-client.ps1); and from Windows, through a VM client's QEMU guest agent, its name and machine
# SID, domain membership, NIC, the Group Policy settings it has, whether defrag is off, and its first boot's log.
set -euo pipefail

BOOT=
[[ ${1:-} == --boot ]] && { BOOT=1; shift; }
(($#)) || { sed -n '3p' "$0" >&2; exit 1; }
cd "$(dirname "$0")/.."
# shellcheck source=servers/remote.sh
. servers/remote.sh
# shellcheck source=lab/pve.sh
. lab/pve.sh
TAG=check

declare -A node vmid
for name in "$@"; do
  if find_vm "$name" 2>/dev/null; then node[$name]=$NODE vmid[$name]=$VMID; fi
done
use() { NODE=${node[$1]} VMID=${vmid[$1]}; }
# Done when Windows has finished setup and is in the domain, with a working secure channel
joined() {
  agent_up && guest_ps '$state = (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State).ImageState
if ($state -eq "IMAGE_STATE_COMPLETE" -and (Get-CimInstance Win32_ComputerSystem).PartOfDomain -and
  (Test-ComputerSecureChannel)) { "yes" }' 2>/dev/null | grep -q yes
}

if [[ -n $BOOT ]]; then
  for name in "${!vmid[@]}"; do
    use "$name"
    [[ $(vm_status) == running ]] || { vm_start; log "$name started"; }
  done
  start=$SECONDS
  pending=("${!vmid[@]}")
  while ((${#pending[@]})); do
    ((SECONDS - start < 1800)) || { log "not set up and joined after 30 minutes: ${pending[*]}. See their consoles."; exit 1; }
    sleep 30
    left=()
    for name in "${pending[@]}"; do
      use "$name"
      if joined; then log "$name: set up and joined after $(((SECONDS - start) / 60)) minutes"; else left+=("$name"); fi
    done
    pending=("${left[@]}")
  done
fi

run "admin@$SAN" clients/san/show-client.ps1 "$@"
for name in "${!vmid[@]}"; do
  use "$name"
  echo "== $name, VM ${vmid[$name]}: $(vm_status)"
  agent_up || { echo 'no guest agent: Windows not running, or still in its first boot'; continue; }
  # shellcheck disable=SC2016 # PowerShell's variables
  guest_ps '$cs = Get-CimInstance Win32_ComputerSystem
$state = (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State).ImageState
"name: $env:COMPUTERNAME, machine SID $((Get-LocalUser | Select-Object -First 1).SID.AccountDomainSid)"
"setup: $state, booted $((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString("yyyy-MM-dd HH:mm"))"
"domain: $(if ($cs.PartOfDomain) { "$($cs.Domain), secure channel $(Test-ComputerSecureChannel)" } else { "none, $($cs.Workgroup)" })"
Get-NetAdapter -Physical | ForEach-Object {
  $service = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$((Get-CimInstance Win32_NetworkAdapter | Where-Object GUID -eq $_.InterfaceGuid).ServiceName)"
  $class = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.PnPDeviceID)").Driver
  "nic: $($_.InterfaceDescription), $($_.DriverVersion), $($_.Status) $($_.LinkSpeed), BootFlags $($service.BootFlags), PnPCapabilities $((Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$class").PnPCapabilities)"
  "address: $((Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $_.ifIndex).IPAddress -join ", ")"
}
$gpos = (Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\GPO-List" -ErrorAction SilentlyContinue | Get-ItemProperty).DisplayName
"group policy: $($gpos -join ", ")"
"pagefile: $((Get-CimInstance Win32_PageFileUsage | ForEach-Object { "$($_.Name) $($_.AllocatedBaseSize) MB" }) -join ", "); set: $((Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management").PagingFiles)"
"power: hibernation $((Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\Power).HibernateEnabled), fast startup $((Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power").HiberbootEnabled), Windows Update NoAutoUpdate $((Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU -ErrorAction SilentlyContinue).NoAutoUpdate)"
"defrag: scheduled $((Get-ScheduledTask -TaskPath "\Microsoft\Windows\Defrag\" -TaskName ScheduledDefrag).State), boot layout EnableAutoLayout $((Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OptimalLayout -ErrorAction SilentlyContinue).EnableAutoLayout)"
"answer file: $(if (Test-Path C:\Windows\Panther\unattend.xml) { "still there" } else { "deleted" })"
Get-Content C:\Windows\Temp\firstboot.log -ErrorAction SilentlyContinue | Where-Object { $_ -match "^(NIC|image|boot manager|done|FAILED)" } | ForEach-Object { "first boot: $_" }' || true
done
