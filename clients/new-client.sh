#!/usr/bin/env bash
# Make a diskless client (PLAN.md, Client lifecycle; docs/clients.md), from the PC in WSL or Git Bash:
#   clients/new-client.sh <name> [<golden image version>]
# Its MAC and address come from clients/clients.csv; the golden image is the newest sealed one unless given.
#   1 domain controller  the clients' OU and Group Policy, a DHCP reservation, and the client's computer account with an
#                        offline domain join (clients/dc/new-client.ps1)
#   2 storage server     its disk on the golden image, with its computer name and the join in the disk's answer file,
#                        and its target (clients/san/new-client.ps1)
#   3 domain controller  its boot script (clients/dc/boot-script.ps1)
# Then power the client on. Its first boot needs nothing more: WinPE from its disk makes its NIC a boot NIC and restarts,
# and Windows finishes setup and joins the domain. clients/check.sh shows how far it is.
set -euo pipefail

NAME=${1:-}
VERSION=${2:-}
[[ $NAME =~ ^[A-Za-z0-9-]{1,15}$ && (-z $VERSION || $VERSION =~ ^[0-9]+$) ]] ||
  { sed -n '3p' "$0" >&2; echo 'A name is up to 15 letters, digits and hyphens: a computer name.' >&2; exit 1; }
cd "$(dirname "$0")/.."
# shellcheck source=servers/remote.sh
. servers/remote.sh
TAG=$NAME

read -r MAC ADDRESS < <(awk -F, -v n="$NAME" 'NR > 1 && tolower($1) == tolower(n) { print $2, $3 }' clients/clients.csv | tr -d '\r') ||
  { log "$NAME isn't in clients/clients.csv"; exit 1; }
[[ $MAC =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ && $ADDRESS =~ ^[0-9.]+$ ]] ||
  { log "clients/clients.csv: $NAME needs a MAC (02:00:0A:1F:01:01) and an address"; exit 1; }
IQN=$(setting IqnPrefix):$NAME

log "domain controller: reservation $ADDRESS for $MAC, computer account and offline domain join"
# Its output holds the join's data, with the account's machine password: it goes on to the storage server, and is
# neither shown nor kept
out=$(run "admin@$DC" clients/dc/new-client.ps1 "$NAME" "$MAC" "$ADDRESS") ||
  { grep -v '^account-data: ' <<<"$out"; exit 1; }
grep -v '^account-data: ' <<<"$out"
account=$(sed -n 's/^account-data: //p' <<<"$out" | tr -d '\r')
[[ -n $account ]] || { log 'clients/dc/new-client.ps1 printed no domain join data'; exit 1; }

log "storage server: the disk and its target"
args=("$NAME" "$IQN")
[[ -z $VERSION ]] || args+=(-Version "$VERSION")
out=$(SECRET=$account run "admin@$SAN" clients/san/new-client.ps1 "${args[@]}") || { echo "$out"; exit 1; }
unset account
echo "$out"
TARGET=$(sed -n 's/^target-iqn: //p' <<<"$out" | tr -d '\r')
[[ -n $TARGET ]] || { log 'clients/san/new-client.ps1 printed no target'; exit 1; }

log 'domain controller: the boot script'
run "admin@$DC" clients/dc/boot-script.ps1 "$NAME" "$MAC" "$IQN" "$TARGET"
log "done: power $NAME on. Its first boot takes 6-7 minutes, with a restart; clients/check.sh $NAME shows it"
