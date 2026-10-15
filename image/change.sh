#!/usr/bin/env bash
# Change a golden image into a new version (docs/golden-image.md), from the PC in WSL, with the
# Proxmox token loaded as for Terraform. Two steps, with the changes in between:
#   image/change.sh <version> [<from version>]   golden-v<version>, a copy of golden-v<from> (the newest sealed one
#                                                unless given), started on the build VM for the changes
#   image/change.sh <version> --seal             then: sysprep, the clients' first boot again, and read-only
# The changes are made in the image's Windows on the build VM, as its admin: over SSH with the servers' keys, over RDP
# with IMAGE_PASSWORD from .env, or at its console. It may restart. Everything left in it goes to every client. Then
# clients/update-clients.sh <version> moves the clients to the new version. A change that was started and isn't sealed
# goes on as it is: image/change.sh <version> starts the build VM on it again. --seal reads IMAGE_PASSWORD from .env.
set -euo pipefail

VERSION=${1:-}
ARG=${2:-}
[[ $VERSION =~ ^[0-9]+$ && (-z $ARG || $ARG == --seal || $ARG =~ ^[0-9]+$) ]] || { sed -n '4,5p' "$0" >&2; exit 1; }
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
. ./.env
# shellcheck source=servers/remote.sh
. servers/remote.sh
# shellcheck source=lab/pve.sh
. lab/pve.sh
TAG=golden-v$VERSION

BUILD_VM=$(setting BuildVm)
IQN=$(setting IqnPrefix):$BUILD_VM
find_vm "$BUILD_VM"
MAC=$(vm_mac)
# Its reservation's address: fixed MACs are 02:00 and then the address (lab/main.tf)
ADDRESS=$(IFS=: read -r _ _ a b c d <<<"$MAC" && echo "$((16#$a)).$((16#$b)).$((16#$c)).$((16#$d))")

if [[ $ARG == --seal ]]; then
  [[ ${IMAGE_PASSWORD:-} =~ ^[A-Za-z0-9]{16,}$ ]] || { log 'IMAGE_PASSWORD in .env must be 16+ letters and digits'; exit 1; }
  [[ $(vm_status) == running ]] || { log "$BUILD_VM isn't running: image/change.sh $VERSION starts it on golden-v$VERSION"; exit 1; }
  run "admin@$SAN" image/san/change-disk.ps1 "$VERSION" -Check
  log "$BUILD_VM at $ADDRESS: sysprep, at its next startup, then it powers off"
  SECRET=$IMAGE_PASSWORD run "admin@$ADDRESS" image/windows/reseal.ps1
  start=$SECONDS
  wait_stopped 3600 ||
    { log 'still running after an hour: see its console, and C:\Windows\Temp\generalize.log in it. It stays on.'; exit 1; }
  log "$BUILD_VM powered off after $(((SECONDS - start) / 60)) minutes"
  run "admin@$SAN" image/san/seal.ps1 "$VERSION"
  run "admin@$DC" image/dc/cleanup.ps1 "$MAC" >/dev/null # the build VM's boot script
  log "done: clients/update-clients.sh $VERSION moves the clients to it"
  exit 0
fi

[[ $(vm_status) == stopped ]] || { log "$BUILD_VM (VM $VMID) is running: stop it first"; exit 1; }
log "golden-v$VERSION on the build target, for $IQN"
args=("$VERSION" -InitiatorIqn "$IQN")
[[ -z $ARG ]] || args+=(-From "$ARG")
out=$(run "admin@$SAN" image/san/change-disk.ps1 "${args[@]}") || { echo "$out"; exit 1; }
echo "$out"
TARGET=$(sed -n 's/^target-iqn: //p' <<<"$out" | tr -d '\r')
[[ -n $TARGET ]] || { log 'image/san/change-disk.ps1 printed no target'; exit 1; }
run "admin@$DC" image/dc/build-script.ps1 "$MAC" "$IQN" "$TARGET" windows

# A sealed image's first start is a client's first boot: its WinPE finds the build VM's NIC in it already, then Windows
# sets itself up, with a random name
log "starting $BUILD_VM (VM $VMID) on golden-v$VERSION: a first boot, then Windows. About 10 minutes"
vm_start
start=$SECONDS state=
until [[ $state == IMAGE_STATE_COMPLETE ]]; do
  ((SECONDS - start < 1800)) || { log "no Windows after 30 minutes (image state: ${state:-no guest agent}): see its console"; exit 1; }
  sleep 30
  state=$(image_state) || true
done
log "golden-v$VERSION runs on $BUILD_VM at $ADDRESS, after $(((SECONDS - start) / 60)) minutes. Make the changes there as" \
  "admin (ssh admin@$ADDRESS, RDP or its console), then: image/change.sh $VERSION --seal"
