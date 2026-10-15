#!/usr/bin/env bash
# Configure the lab's Windows servers (docs/requirements.md) over SSH, from the PC in Git Bash or WSL:
#   setup.sh dc     promote the domain controller to a new forest, then DNS, DHCP, TFTP and HTTP
#   setup.sh san    join the storage server to the domain, then iSCSI Target Server and its data disk
# Run dc first. Reads ADMIN_PASSWORD and DSRM_PASSWORD from .env at the repo root (.env.example). Safe to re-run:
# each script skips what's done. A script that restarts Windows (pending updates, a promotion, a join) prints
# "restarting: <why>", and runs again once Windows is back (remote.sh).
set -euo pipefail

TAG=${1:-}
[[ $TAG == dc || $TAG == san ]] || { sed -n '3,4p' "$0" >&2; exit 1; }
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
. ./.env
# shellcheck source=servers/remote.sh
. servers/remote.sh

case $TAG in
dc)
  log "promoting $DC"
  SECRET=$DSRM_PASSWORD converge "admin@$DC" servers/dc/promote.ps1
  # After the promotion the local accounts are domain accounts. Administrator is the one in Enterprise Admins, which
  # can authorise the DHCP server; the keys in administrators_authorized_keys work for it as for admin.
  log "configuring $DC"
  converge "Administrator@$DC" servers/dc/configure.ps1
  ;;
san)
  log "joining $SAN to the domain"
  SECRET=$ADMIN_PASSWORD converge "admin@$SAN" servers/san/join.ps1
  log "configuring $SAN"
  converge "admin@$SAN" servers/san/configure.ps1
  ;;
esac
log 'done'
