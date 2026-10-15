#!/usr/bin/env bash
# Move diskless clients to another golden image (docs/clients.md), from the PC in WSL or Git
# Bash, while they're off:
#   clients/update-clients.sh <golden image version> [<name>...]
# Every client in clients/clients.csv that has a disk, or those named. Each gets a new disk on that image, made as
# new-client.sh makes one, on the same target, so its next start is a first boot again; its computer account and boot
# script stay, and its DHCP reservation is set from clients.csv. Whatever was stored on its old disk is gone. Running
# clients are left as they are: switch them off and run it again. To roll back, the same with the version before.
# Golden images that no disk uses any more are listed, not deleted (image/remove.sh).
#   1 storage server     takes each client's disk off its target, unless the client is running or on that image already
#                        (clients/san/update-clients.ps1 take)
#   2 domain controller  for each of those, its reservation and a new offline domain join, which resets its computer
#                        account's machine password: so never for a running client (clients/dc/update-clients.ps1)
#   3 storage server     their new disks, with their names and joins, on their targets (clients/san/update-clients.ps1
#                        make)
set -euo pipefail

VERSION=${1:-}
[[ $VERSION =~ ^[0-9]+$ ]] || { sed -n '4p' "$0" >&2; exit 1; }
shift
cd "$(dirname "$0")/.."
# shellcheck source=servers/remote.sh
. servers/remote.sh
TAG=golden-v$VERSION

names=("$@")
((${#names[@]})) || mapfile -t names < <(awk -F, 'NR > 1 && $1 != "" { print $1 }' clients/clients.csv | tr -d '\r')
# Each one's row, "<name>,<mac>,<address>", for its reservation
declare -A row
for name in "${names[@]}"; do
  [[ $name =~ ^[A-Za-z0-9-]{1,15}$ ]] || { log "$name isn't a computer name"; exit 1; }
  row[$name]=$(awk -F, -v n="$name" 'NR > 1 && tolower($1) == tolower(n) { print $1 "," $2 "," $3 }' clients/clients.csv |
    tr -d '\r')
  [[ ${row[$name]} =~ ^[A-Za-z0-9-]+,([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2},[0-9.]+$ ]] ||
    { log "clients/clients.csv needs a row for $name, with its MAC and address"; exit 1; }
done

log "storage server: taking the clients' disks off their targets: ${names[*]}"
out=$(run "admin@$SAN" clients/san/update-clients.ps1 take "$VERSION" "${names[@]}") || { echo "$out"; exit 1; }
echo "$out"
mapfile -t ready < <(sed -n 's/^ready: //p' <<<"$out" | tr -d '\r')
mapfile -t running < <(sed -n 's/^running: //p' <<<"$out" | tr -d '\r')

if ((${#ready[@]})); then
  # Their disks are off their targets now, so they can't start. If this stops here, they stay so until it's run again.
  log "domain controller: reservations and new domain joins for ${ready[*]}"
  rows=()
  for name in "${ready[@]}"; do rows+=("${row[$name]}"); done
  # Its output holds the joins' data, with the accounts' machine passwords: it goes on to the storage server, and is
  # neither shown nor kept
  out=$(run "admin@$DC" clients/dc/update-clients.ps1 "${rows[@]}") ||
    { grep -v '^account-data ' <<<"$out"; log "${ready[*]} have no disk on their targets: run this again"; exit 1; }
  grep -v '^account-data ' <<<"$out"
  joins=$(sed -n 's/^account-data \([^:]*\): /\1 /p' <<<"$out" | tr -d '\r')
  (($(wc -l <<<"$joins") == ${#ready[@]})) ||
    { log "clients/dc/update-clients.ps1 printed no join for some of ${ready[*]}: run this again"; exit 1; }

  log "storage server: new disks on golden-v$VERSION"
  SECRET=$joins run "admin@$SAN" clients/san/update-clients.ps1 make "$VERSION" ||
    { log 'see above: the clients that failed have no disk on their targets until this runs again'; exit 1; }
  unset joins
  log "updated: ${ready[*]}. Their next start is a first boot on golden-v$VERSION, 6-7 minutes with a restart;" \
    'clients/check.sh shows it'
fi

if ((${#running[@]})); then
  log "not updated, as they're running: ${running[*]}. Switch them off, and run this again."
  exit 1
fi
log 'done'
