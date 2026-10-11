#!/usr/bin/env bash
# Build golden image <version>, golden-v<version>.vhdx (PLAN.md, phase 2; docs/image.md), from the PC in WSL, with the
# Proxmox token loaded as for Terraform:
#   . ~/.config/proxmox/diskless.env && image/build.sh <version> [--updates]
# The build VM network-boots WinPE, which installs Windows from the domain controller's install share onto a blank disk
# on the storage server's build target, and powers off. Windows then boots from that disk, provisions itself, and
# sysprep powers the VM off. The image is then made read-only. With a second NIC for the build (BuildSecondNic in
# servers/settings.psd1), the build VM has it only while setup runs in WinPE, so that setup makes it a boot NIC too.
# Reads IMAGE_PASSWORD from .env: the image's local admin password. Takes about 45 minutes, plus half an hour the first
# time for the ADK and WinPE; with --updates, up to 4 hours.
set -euo pipefail

VERSION=${1:-}
UPDATES=${2:-}
[[ $VERSION =~ ^[0-9]+$ && (-z $UPDATES || $UPDATES == --updates) ]] || { sed -n '4p' "$0" >&2; exit 1; }
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
. ./.env
# shellcheck source=servers/remote.sh
. servers/remote.sh
# shellcheck source=lab/pve.sh
. lab/pve.sh
TAG=golden-v$VERSION
[[ ${IMAGE_PASSWORD:-} =~ ^[A-Za-z0-9]{16,}$ ]] || { log 'IMAGE_PASSWORD in .env must be 16+ letters and digits'; exit 1; }

BUILD_VM=$(setting BuildVm)
IQN=$(setting IqnPrefix):$BUILD_VM
SECOND_NIC=$(setting BuildSecondNic)
find_vm "$BUILD_VM"
[[ $(vm_status) == stopped ]] || { log "$BUILD_VM (VM $VMID) is running: stop it first"; exit 1; }
MAC=$(vm_mac)

# second_nic <add|remove>: the build VM's net1, the second NIC model, on net0's network. Only while setup runs: present
# at the new Windows' first boot, it made setup's specialize pass restart (docs/image.md). Terraform doesn't know it.
second_nic() {
  local net0
  if [[ $1 == add ]]; then
    net0=$(pve GET "/nodes/$NODE/qemu/$VMID/config" | json 'print(d["net0"])')
    pve PUT "/nodes/$NODE/qemu/$VMID/config" \
      --data-urlencode "net1=$(sed -E "s/^[^=]+=[0-9A-Fa-f:]{17}/$SECOND_NIC=$(setting BuildSecondNicMac)/" <<<"$net0")" >/dev/null
  elif pve GET "/nodes/$NODE/qemu/$VMID/config" | json 'sys.exit("net1" not in d)'; then
    pve PUT "/nodes/$NODE/qemu/$VMID/config" --data-urlencode 'delete=net1' >/dev/null
  fi
}

log "a blank disk on the build target, for $IQN"
out=$(run "admin@$SAN" image/san/build-disk.ps1 "$VERSION" "$IQN")
echo "$out"
TARGET=$(sed -n 's/^target-iqn: //p' <<<"$out" | tr -d '\r')
[[ -n $TARGET ]] || { log 'build-disk.ps1 printed no target'; exit 1; }
SECOND_TARGET=$(sed -n 's/^second-target-iqn: //p' <<<"$out" | tr -d '\r')
[[ -z $SECOND_NIC || -n $SECOND_TARGET ]] || { log 'build-disk.ps1 printed no second target'; exit 1; }

# The build's files on the domain controller hold passwords: they go when the build ends, however it ends
cleanup() {
  log 'removing the build files from the domain controller'
  run "admin@$DC" image/dc/cleanup.ps1 "$MAC" || log 'that failed: run image/dc/cleanup.ps1 there by hand'
  [[ $(vm_status) != stopped ]] || second_nic remove # left on a VM that's still on, for a look
}
trap cleanup EXIT
log 'preparing the domain controller: the ADK, WinPE, the install share and the build files'
args=()
[[ -z $SECOND_TARGET ]] || args+=(-SecondTargetIqn "$SECOND_TARGET")
[[ -z $UPDATES ]] || args+=(-Updates updates)
SECRET=$IMAGE_PASSWORD converge "admin@$DC" image/dc/prepare.ps1 "$MAC" "$IQN" "$TARGET" "${args[@]}"

# WinPE and setup. A failure in WinPE leaves it at a prompt, so this times out.
if [[ -n $SECOND_NIC ]]; then
  second_nic add
  log "$BUILD_VM has a second NIC for setup: $SECOND_NIC"
fi
log "starting $BUILD_VM (VM $VMID) for WinPE and setup. WinPE powers it off: up to 45 minutes"
vm_start
start=$SECONDS
until [[ $(vm_status) == stopped ]]; do
  ((SECONDS - start < 2700)) || { log "WinPE still running after 45 minutes: see its console. It stays on."; exit 1; }
  sleep 30
done
DISK="$(setting SanDataDrive):\\iSCSI\\images\\golden-v$VERSION.vhdx"
# shellcheck disable=SC2029 # the path is expanded here, on purpose
size=$(ssh "${SSHO[@]}" "admin@$SAN" "powershell -NoProfile -Command (Get-Item '$DISK').Length" | tr -d '\r')
((size > 2 * 1024 ** 3)) || { log "WinPE powered off, but setup hasn't written to the disk ($size bytes)"; exit 1; }
log "WinPE powered off after $(((SECONDS - start) / 60)) minutes"

# The new Windows
second_nic remove
run "admin@$DC" image/dc/build-script.ps1 "$MAC" "$IQN" "$TARGET" windows
HOURS=2
[[ -z $UPDATES ]] || HOURS=4
log "starting $BUILD_VM (VM $VMID) for Windows. It powers off when sysprep is done: up to $HOURS hours"
vm_start
start=$SECONDS next=600
until [[ $(vm_status) == stopped ]]; do
  ((SECONDS - start < HOURS * 3600)) || { log "still running after $HOURS hours: see its console. It stays on."; exit 1; }
  ((SECONDS - start < next)) || { log "building: $(((SECONDS - start) / 60)) minutes"; next=$((next + 600)); }
  sleep 30
done
log "$BUILD_VM powered off after $(((SECONDS - start) / 60)) minutes"
run "admin@$SAN" image/san/seal.ps1 "$VERSION"
log 'done'
