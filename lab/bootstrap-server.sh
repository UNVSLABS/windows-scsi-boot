#!/usr/bin/env bash
# Give a newly cloned Windows server its static address and computer name through the QEMU guest agent. The flat
# network has no DHCP until the domain controller runs it, so a new clone has only a link-local address and SSH can't
# reach it. Terraform runs this after creating each server (main.tf), with the provider's PROXMOX_VE_ENDPOINT and
# PROXMOX_VE_API_TOKEN in the environment. Safe to re-run:
#   bootstrap-server.sh <node> <vmid> <name> <address/prefix> <gateway> <dns>
set -euo pipefail

[[ $# -eq 6 ]] || { sed -n '6p' "$0" >&2; exit 1; }
NODE=$1 VMID=$2 NAME=$3 CIDR=$4 GATEWAY=$5 DNS=$6
# shellcheck source=lab/pve.sh
. "$(dirname "$0")/pve.sh"

log() { echo "[$NAME] $*" >&2; }

# When the running Windows booted. It changes once a restart has really happened, which a failed ping doesn't prove.
boot_time() {
  guest_ps '(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString("o")' | tr -d '\r\n'
}

# Wait up to $1 seconds until the agent answers and Windows has finished its first-boot setup
wait_ready() {
  local deadline=$((SECONDS + $1)) state
  while :; do
    state=$(image_state) || true
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
