#!/usr/bin/env bash
# Remove a diskless client (PLAN.md, Client lifecycle; docs/clients.md), from the PC in WSL or Git Bash:
#   clients/remove-client.sh <name>
# The reverse of new-client.sh. The storage server first: the client's target and disk, refused while the client is
# running (clients/san/remove-client.ps1). Then the domain controller: its boot script, DHCP reservation, DNS records and
# computer account (clients/dc/remove-client.ps1). Its row in clients/clients.csv stays. Safe to re-run.
set -euo pipefail

NAME=${1:-}
[[ $NAME =~ ^[A-Za-z0-9-]{1,15}$ ]] || { sed -n '3p' "$0" >&2; exit 1; }
cd "$(dirname "$0")/.."
# shellcheck source=servers/remote.sh
. servers/remote.sh
TAG=$NAME

read -r MAC < <(awk -F, -v n="$NAME" 'NR > 1 && tolower($1) == tolower(n) { print $2 }' clients/clients.csv | tr -d '\r') ||
  { log "$NAME isn't in clients/clients.csv"; exit 1; }
log 'storage server: the disk and its target'
run "admin@$SAN" clients/san/remove-client.ps1 "$NAME"
log 'domain controller: boot script, reservation, DNS records and computer account'
run "admin@$DC" clients/dc/remove-client.ps1 "$NAME" "$MAC"
log 'done'
