#!/usr/bin/env bash
# Give a newly cloned Windows server its static address and computer name through the QEMU guest agent. The flat
# network has no DHCP until the domain controller runs it, so a new clone has only a link-local address and SSH can't
# reach it. Terraform runs this after creating each server (main.tf), with the provider's PROXMOX_VE_ENDPOINT and
# PROXMOX_VE_API_TOKEN in the environment. Safe to re-run:
#   bootstrap-server.sh <node> <vmid> <name> <address/prefix> <gateway> <dns>
set -euo pipefail

[[ $# -eq 6 ]] || { sed -n '6p' "$0" >&2; exit 1; }
NODE=$1 VMID=$2 NAME=$3 CIDR=$4 GATEWAY=$5 DNS=$6
API="${PROXMOX_VE_ENDPOINT%/}/api2/json/nodes/$NODE/qemu/$VMID/agent"
AUTH="Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN"

log() { echo "[$NAME] $*" >&2; }

# Run a PowerShell script in the guest. Prints its output and returns its exit code. Fails if the agent stops
# answering (the guest restarted or crashed) or the script runs for more than 10 minutes.
guest_ps() {
  local encoded pid status deadline=$((SECONDS + 600))
  # Without the preference, PowerShell writes its progress bars to stderr as CLIXML
  encoded=$(printf '%s' "\$ProgressPreference = 'SilentlyContinue'
$1" | iconv -t UTF-16LE | base64 -w0)
  pid=$(curl -fsS -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"command\":[\"powershell.exe\",\"-NoProfile\",\"-NonInteractive\",\"-EncodedCommand\",\"$encoded\"]}" \
    "$API/exec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["pid"])') || return 1
  while :; do
    status=$(curl -fsS -H "$AUTH" "$API/exec-status?pid=$pid") || { log "the guest agent stopped answering"; return 1; }
    python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["data"].get("exited") else 1)' <<<"$status" && break
    ((SECONDS < deadline)) || { log "a guest command ran for 10 minutes"; return 1; }
    sleep 2
  done
  python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
sys.stdout.write(d.get("out-data", ""))
err = d.get("err-data", "")
sys.stderr.write(err if err.endswith("\n") or not err else err + "\n")
sys.exit(d.get("exitcode", 1))' <<<"$status"
}

agent_up() { curl -fsS -o /dev/null -X POST -H "$AUTH" "$API/ping" 2>/dev/null; }

# When the running Windows booted. It changes once a restart has really happened, which a failed ping doesn't prove.
boot_time() {
  guest_ps '(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString("o")' | tr -d '\r\n'
}

# Wait up to $1 seconds until the agent answers and Windows has finished its first-boot setup
wait_ready() {
  local deadline=$((SECONDS + $1)) state
  while :; do
    state=$(agent_up && guest_ps '(Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State).ImageState' 2>/dev/null | tr -d '\r\n') || true
    [[ $state == IMAGE_STATE_COMPLETE ]] && return
    ((SECONDS < deadline)) || { log "Windows not ready after $(($1 / 60)) minutes (image state: ${state:-no agent})"; exit 1; }
    sleep 10
  done
}

# PowerShell: the values first, then the steps. Prints "restarting" when it renamed the computer.
read -r -d '' SET_IDENTITY <<'EOF' || true
$ErrorActionPreference = 'Stop'
$nic = @(Get-NetAdapter -Physical | Where-Object Status -eq 'Up')[0]
$current = @(Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
if (-not ($current | Where-Object { $_.IPAddress -eq $Address -and $_.PrefixOrigin -eq 'Manual' })) {
  Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Disabled
  $current | Remove-NetIPAddress -Confirm:$false
  Get-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false
  New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $Address -PrefixLength $Prefix -DefaultGateway $Gateway |
    Out-Null
}
Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $Dns
if ($env:COMPUTERNAME -ne $Name) {
  Rename-Computer -NewName $Name -Force
  shutdown.exe /r /t 5 /c "bootstrap-server.sh: renamed to $Name"
  'restarting'
}
EOF

log "waiting for Windows to finish its first boot"
wait_ready 1800
log "setting $CIDR, gateway $GATEWAY, DNS $DNS and the computer name"
booted=$(boot_time)
out=$(guest_ps "\$Name='$NAME'; \$Address='${CIDR%/*}'; \$Prefix=${CIDR#*/}; \$Gateway='$GATEWAY'; \$Dns='$DNS'
$SET_IDENTITY")
if [[ $out == *restarting* ]]; then
  log "restarting for the new name"
  deadline=$((SECONDS + 600))
  until now=$(boot_time 2>/dev/null) && [[ -n $now && $now != "$booted" ]]; do
    ((SECONDS < deadline)) || { log "Windows didn't come back from its restart within 10 minutes"; exit 1; }
    sleep 10
  done
  wait_ready 600
fi
# The check doubles as a smoke test of the clone's Windows: on a host with faulty memory, clones read corrupted
# system files, and their PowerShell couldn't load NetTCPIP (docs/environment.md)
# shellcheck disable=SC2016 # $env is PowerShell's
now=$(guest_ps '"$env:COMPUTERNAME " + (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Manual).IPAddress' | tr -d '\r\n')
log "now: $now"
[[ ${now,,} == "${NAME,,} ${CIDR%/*}" ]] || { log "expected: $NAME ${CIDR%/*}"; exit 1; }
