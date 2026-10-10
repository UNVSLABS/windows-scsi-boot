# shellcheck shell=bash
# The Proxmox API, with the token from the environment (PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN, as for Terraform:
# docs/environment.md), for bootstrap-server.sh and image/*.sh, which source this. The VM functions act on $NODE and
# $VMID, which find_vm sets. Needs curl, python3 and iconv.

pve() { # pve <GET|POST> <path under /api2/json> [curl argument...]: print the response's data as JSON
  local out
  out=$(curl -fsS -X "$1" -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
    "${PROXMOX_VE_ENDPOINT%/}/api2/json$2" "${@:3}") || return 1
  python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin)["data"]))' <<<"$out"
}
json() { python3 -c "import json, sys; d = json.load(sys.stdin); $1"; } # json <Python using d>: read JSON on stdin

find_vm() { # find_vm <name>: set NODE and VMID for the VM with that name
  local found
  found=$(pve GET '/cluster/resources?type=vm' |
    json "print(*next(([v['node'], v['vmid']] for v in d if v.get('name') == '$1'), []))") || return 1
  [[ -n $found ]] || { echo "no VM named $1" >&2; return 1; }
  read -r NODE VMID <<<"$found"
}
vm_status() { pve GET "/nodes/$NODE/qemu/$VMID/status/current" | json 'print(d["status"])'; } # running, stopped
task() { # task <POST path>: start a Proxmox task and wait for it to end. Fails if it fails.
  local upid status deadline=$((SECONDS + 300))
  upid=$(pve POST "$1" | json 'import urllib.parse; print(urllib.parse.quote(d, safe=""))') || return 1
  until status=$(pve GET "/nodes/$NODE/tasks/$upid/status") && json 'sys.exit(d["status"] != "stopped")' <<<"$status"; do
    ((SECONDS < deadline)) || { echo "$1 still running after 5 minutes" >&2; return 1; }
    sleep 2
  done
  json 'sys.exit(0 if d.get("exitstatus") == "OK" else "%s: %s" % (d.get("type"), d.get("exitstatus")))' <<<"$status"
}
vm_start() { task "/nodes/$NODE/qemu/$VMID/status/start"; }
vm_stop() { task "/nodes/$NODE/qemu/$VMID/status/stop"; } # at once, like pulling the plug
vm_mac() { # net0's MAC, in capitals
  pve GET "/nodes/$NODE/qemu/$VMID/config" | json 'import re; print(re.search(r"=([0-9A-Fa-f:]{17})", d["net0"])[1].upper())'
}
wait_stopped() { # wait_stopped <seconds>: until the VM is off. Fails if it isn't by then.
  local deadline=$((SECONDS + $1))
  until [[ $(vm_status) == stopped ]]; do
    ((SECONDS < deadline)) || return 1
    sleep 30
  done
}

agent_up() { pve POST "/nodes/$NODE/qemu/$VMID/agent/ping" >/dev/null 2>&1; }

# Run a PowerShell script in the guest. Prints its output and returns its exit code. Fails if the agent stops
# answering (the guest restarted or crashed) or the script runs for more than 10 minutes.
guest_ps() {
  local encoded pid status deadline=$((SECONDS + 600))
  # Without the preference, PowerShell writes its progress bars to stderr as CLIXML
  encoded=$(printf '%s' "\$ProgressPreference = 'SilentlyContinue'
$1" | iconv -t UTF-16LE | base64 -w0)
  pid=$(pve POST "/nodes/$NODE/qemu/$VMID/agent/exec" -H 'Content-Type: application/json' \
    -d "{\"command\":[\"powershell.exe\",\"-NoProfile\",\"-NonInteractive\",\"-EncodedCommand\",\"$encoded\"]}" |
    json 'print(d["pid"])') || return 1
  while :; do
    status=$(pve GET "/nodes/$NODE/qemu/$VMID/agent/exec-status?pid=$pid") ||
      { echo "the guest agent stopped answering" >&2; return 1; }
    json 'sys.exit(0 if d.get("exited") else 1)' <<<"$status" && break
    ((SECONDS < deadline)) || { echo "a guest command ran for 10 minutes" >&2; return 1; }
    sleep 2
  done
  json '
sys.stdout.write(d.get("out-data", ""))
err = d.get("err-data", "")
sys.stderr.write(err if err.endswith("\n") or not err else err + "\n")
sys.exit(d.get("exitcode", 1))' <<<"$status"
}

# Windows' setup state in the guest: IMAGE_STATE_COMPLETE once its first boot is done. Empty without the agent.
image_state() {
  agent_up && guest_ps '(Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State).ImageState' \
    2>/dev/null | tr -d '\r\n'
}
