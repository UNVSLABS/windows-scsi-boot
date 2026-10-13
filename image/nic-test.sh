#!/usr/bin/env bash
# Boot a golden image on a test client (PLAN.md, NIC independence; docs/image.md), from the PC in WSL with the Proxmox
# token loaded as for Terraform:
#   image/nic-test.sh <version> <client VM> [none|bootflags|bootstart|reflect|netadapter] [--keep]
# The client gets a new differencing disk on golden-v<version>, changed for the variant (image/san/test-client.ps1;
# netadapter: by WinPE on the client first, image/winpe/netadapter.cmd). It boots it, and passes if Windows finishes its
# first boot within 20 minutes: the guest agent then reports IMAGE_STATE_COMPLETE. It prints the client's NIC and driver.
# Then it stops the client and removes its disk, target and boot script, unless --keep.
set -euo pipefail

VERSION=${1:-}
CLIENT=${2:-}
VARIANT=${3:-none}
KEEP=${4:-}
[[ $VERSION =~ ^[0-9]+$ && -n $CLIENT && $VARIANT =~ ^(none|bootflags|bootstart|reflect|netadapter)$ &&
  (-z $KEEP || $KEEP == --keep) ]] || { sed -n '4p' "$0" >&2; exit 1; }
cd "$(dirname "$0")/.."
# shellcheck source=servers/remote.sh
. servers/remote.sh
# shellcheck source=lab/pve.sh
. lab/pve.sh
TAG="$CLIENT $VARIANT"

IQN=$(setting IqnPrefix):$CLIENT
find_vm "$CLIENT"
[[ $(vm_status) == stopped ]] || { log "$CLIENT (VM $VMID) is running: stop it first"; exit 1; }
MAC=$(vm_mac)
MODEL=$(pve GET "/nodes/$NODE/qemu/$VMID/config" | json 'print(d["net0"].split("=")[0])')
log "$MODEL NIC $MAC: a new disk on golden-v$VERSION"
out=$(run "admin@$SAN" image/san/test-client.ps1 "$VERSION" "$CLIENT" "$IQN" "$VARIANT")
echo "$out"
TARGET=$(sed -n 's/^target-iqn: //p' <<<"$out" | tr -d '\r')
[[ -n $TARGET ]] || { log 'test-client.ps1 printed no target'; exit 1; }

teardown() {
  [[ $(vm_status) == stopped ]] || vm_stop
  if [[ -z $KEEP ]]; then
    run "admin@$DC" image/dc/test-client.ps1 "$CLIENT" "$MAC" remove >/dev/null
    run "admin@$SAN" image/san/test-client.ps1 "$VERSION" "$CLIENT" "$IQN" remove >/dev/null
  fi
}
trap teardown EXIT

if [[ $VARIANT == netadapter ]]; then
  log 'WinPE first, to make this NIC a boot NIC of the Windows on the disk'
  run "admin@$DC" image/dc/test-client.ps1 "$CLIENT" "$MAC" netadapter "$IQN" "$TARGET"
  vm_start
  if ! wait_stopped 900; then
    log "WinPE didn't power off within 15 minutes: see the console"
    exit 1
  fi
  run "admin@$SAN" image/san/read-client.ps1 "$CLIENT" 'Windows\Temp\netadapter.log'
fi

run "admin@$DC" image/dc/test-client.ps1 "$CLIENT" "$MAC" windows "$IQN" "$TARGET"
log "booting Windows from the disk"
vm_start
start=$SECONDS state=
until [[ $state == IMAGE_STATE_COMPLETE ]]; do
  if ((SECONDS - start > 1200)); then
    log "FAILED: no finished Windows after 20 minutes (image state: ${state:-no guest agent}). See the console."
    exit 1
  fi
  sleep 20
  state=$(image_state) || true
done
log "PASSED: Windows finished its first boot after $(((SECONDS - start) / 60)) minutes"
# shellcheck disable=SC2016 # PowerShell's variables
guest_ps '"name: $env:COMPUTERNAME"
Get-NetAdapter -Physical | ForEach-Object {
  $guid = $_.InterfaceGuid
  $name = (Get-CimInstance Win32_NetworkAdapter | Where-Object GUID -eq $guid).ServiceName
  $service = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
  "nic: $($_.InterfaceDescription), driver $($_.DriverFileName) $($_.DriverVersion), $($_.Status), $($_.LinkSpeed)"
  "nic service: $name, Start $($service.Start), BootFlags $($service.BootFlags)"
}
"address: " + ((Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias (Get-NetAdapter -Physical)[0].Name).IPAddress)
"iscsi: " + ((Get-CimInstance -Namespace root\wmi MSiSCSIInitiator_SessionClass -ErrorAction SilentlyContinue).TargetName -join ", ")'
