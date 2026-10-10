#!/usr/bin/env bash
# Configure the lab's Windows servers (PLAN.md, phase 1; docs/servers.md) over SSH, from the PC in Git Bash or WSL:
#   setup.sh dc     promote the domain controller to a new forest, then DNS, DHCP, TFTP and HTTP
#   setup.sh san    join the storage server to the domain, then iSCSI Target Server and its data disk
# Run dc first. Reads ADMIN_PASSWORD and DSRM_PASSWORD from .env at the repo root (.env.example). Safe to re-run:
# each script skips what's done. A script that restarts Windows (pending updates, a promotion, a join) prints
# "restarting: <why>", and runs again once Windows is back. Passwords travel in the copy as servers/secret.txt, which
# the script deletes once read.
set -euo pipefail
export MSYS_NO_PATHCONV=1 # Git Bash would rewrite the Windows paths below

ROLE=${1:-}
[[ $ROLE == dc || $ROLE == san ]] || { sed -n '3,4p' "$0" >&2; exit 1; }
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
. ./.env
setting() { sed -nE "s/^ *$1 *= *'([^']*)'.*/\1/p" servers/settings.psd1; }
DC=$(setting DcAddress)
SAN=$(setting SanAddress)
REMOTE='C:\Windows\Temp\diskless' # the copy of servers/ and boot/ that the scripts run from

# Addresses are reused when a server is rebuilt, so known host keys would only raise false alarms. The keepalives end a
# session whose server restarted under it, which would otherwise wait forever.
SSHO=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
# Few SSH connections: an IPS in blocking mode takes several new ones to port 22 within a couple of minutes for a scan,
# and blocks the PC. So each step is one connection, and a restart is polled once a minute.
POLL=60
log() { echo "[$ROLE] $*" >&2; }

# shellcheck disable=SC2029 # the remote command is built here, on purpose
run() { # run <user@host> <script under servers/> [secret]: send a fresh copy of servers/ and boot/, then run the script,
  # in one connection. The secret goes along as servers/secret.txt, which the script deletes once read.
  local stage status=0
  stage=$(mktemp -d)
  cp -r servers boot "$stage/"
  [[ -z ${3:-} ]] || (umask 077; printf '%s\n' "$3" > "$stage/servers/secret.txt")
  tar cf - -C "$stage" servers boot | ssh "${SSHO[@]}" "$1" "(if exist $REMOTE rmdir /s /q $REMOTE) & mkdir $REMOTE && \
tar xf - -C $REMOTE && powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $REMOTE\\servers\\${2//\//\\}" ||
    status=$?
  rm -rf "$stage"
  return "$status"
}
boot_time() { # when the host's Windows booted. It changes once a restart has really happened.
  timeout 120 ssh "${SSHO[@]}" "$1" 'powershell -NoProfile -Command "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString(\"o\")"' 2>/dev/null | tr -d '\r'
}
wait_restart() { # wait_restart <user@host> <boot time before>
  local deadline=$((SECONDS + 1200)) now
  sleep "$POLL"
  until now=$(boot_time "$1") && [[ -n $now && $now != "$2" ]]; do
    ((SECONDS < deadline)) || { log "$1 didn't come back within 20 minutes"; exit 1; }
    sleep "$POLL"
  done
  log "$1 is back"
}
converge() { # converge <user@host> <script under servers/> [secret]: run it until it stops restarting Windows
  local i out capture
  capture=$(mktemp)
  for i in 1 2 3 4 5 6; do
    run "$@" | tee "$capture" # shown as it runs, and kept when the script fails
    out=$(cat "$capture")
    [[ $out == *"restarting: "* ]] || { rm -f "$capture"; return 0; }
    log "$1 is restarting ($i of 6), then $2 runs again"
    wait_restart "$1" "$(sed -n 's/^booted: //p' <<<"$out" | tr -d '\r')"
  done
  log "$2 still asked for a restart after 6"
  exit 1
}

case $ROLE in
dc)
  log "promoting $DC"
  converge "admin@$DC" dc/promote.ps1 "$DSRM_PASSWORD"
  # After the promotion the local accounts are domain accounts. Administrator is the one in Enterprise Admins, which
  # can authorise the DHCP server; the keys in administrators_authorized_keys work for it as for admin.
  log "configuring $DC"
  converge "Administrator@$DC" dc/configure.ps1
  ;;
san)
  log "joining $SAN to the domain"
  converge "admin@$SAN" san/join.ps1 "$ADMIN_PASSWORD"
  log "configuring $SAN"
  converge "admin@$SAN" san/configure.ps1
  ;;
esac
log 'done'
