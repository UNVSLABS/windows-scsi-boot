#!/usr/bin/env bash
# Build golden image <version>, golden-v<version>.vhdx (PLAN.md, phase 2; docs/image.md), from the PC in WSL, with the
# Proxmox token loaded as for Terraform:
#   . ~/.config/proxmox/diskless.env && image/build.sh <version> [--updates]
# The build VM network-boots WinPE, which installs Windows from the domain controller's install share onto a blank disk
# on the storage server's build target. Windows then boots from that disk, provisions itself, and sysprep powers the VM
# off. The image is then made read-only. Reads IMAGE_PASSWORD from .env: the image's local admin password. Takes about
# 45 minutes, plus half an hour the first time for the ADK and WinPE; with --updates, up to 4 hours.
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
find_vm "$BUILD_VM"
[[ $(vm_status) == stopped ]] || { log "$BUILD_VM (VM $VMID) is running: stop it first"; exit 1; }
MAC=$(vm_mac)

log "a blank disk on the build target, for $IQN"
out=$(run "admin@$SAN" image/san/build-disk.ps1 "$VERSION" "$IQN")
echo "$out"
TARGET=$(sed -n 's/^target-iqn: //p' <<<"$out" | tr -d '\r')
[[ -n $TARGET ]] || { log 'build-disk.ps1 printed no target'; exit 1; }

# The build's files on the domain controller hold passwords: they go when the build ends, however it ends
cleanup() {
  log 'removing the build files from the domain controller'
  run "admin@$DC" image/dc/cleanup.ps1 "$MAC" || log 'that failed: run image/dc/cleanup.ps1 there by hand'
}
trap cleanup EXIT
log 'preparing the domain controller: the ADK, WinPE, the install share and the build files'
SECRET=$IMAGE_PASSWORD converge "admin@$DC" image/dc/prepare.ps1 "$MAC" "$IQN" "$TARGET" "${UPDATES#--}"

HOURS=2
[[ -z $UPDATES ]] || HOURS=4
log "starting $BUILD_VM (VM $VMID). It powers off when sysprep is done: up to $HOURS hours"
vm_start
# A failure in WinPE leaves it at a prompt. So 20 minutes in, when setup has written gigabytes, check the disk.
DISK="$(setting SanDataDrive):\\iSCSI\\images\\golden-v$VERSION.vhdx"
start=$SECONDS next=600 checked=
until [[ $(vm_status) == stopped ]]; do
  ((SECONDS - start < HOURS * 3600)) || { log "still running after $HOURS hours: see its console. It stays on."; exit 1; }
  ((SECONDS - start < next)) || { log "building: $(((SECONDS - start) / 60)) minutes"; next=$((next + 600)); }
  if [[ -z $checked ]] && ((SECONDS - start > 1200)); then
    checked=1
    # shellcheck disable=SC2029 # the path is expanded here, on purpose
    size=$(ssh "${SSHO[@]}" "admin@$SAN" "powershell -NoProfile -Command (Get-Item '$DISK').Length" | tr -d '\r')
    ((size > 2 * 1024 ** 3)) || { log "setup hasn't written to the disk ($size bytes): see the console. It stays on."; exit 1; }
  fi
  sleep 30
done
log "$BUILD_VM powered off after $(((SECONDS - start) / 60)) minutes"
run "admin@$SAN" image/san/seal.ps1 "$VERSION"
log 'done'
