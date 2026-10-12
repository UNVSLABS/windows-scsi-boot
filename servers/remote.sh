# shellcheck shell=bash disable=SC2034 # the settings here are for the scripts that source this
# Running the repo's PowerShell scripts on the Windows servers over SSH, for setup.sh, image/*.sh and clients/*.sh, which
# source this from the repo root. Each script runs from a fresh copy of servers/, boot/, image/ and clients/ in
# C:\Windows\Temp\diskless, which the next run replaces: so one run at a time per server, and one of those scripts at a
# time. A script that restarts Windows
# prints "restarting: <why>" and its boot time (servers/common.ps1), and converge runs it again once Windows is back. A
# password or other secret goes along in $SECRET, as servers/secret.txt, which the script deletes once read.
export MSYS_NO_PATHCONV=1 # Git Bash would rewrite the Windows paths below

setting() { sed -nE "s/^ *$1 *= *'([^']*)'.*/\1/p" servers/settings.psd1; } # a value from settings.psd1
DC=$(setting DcAddress)
SAN=$(setting SanAddress)
REMOTE='C:\Windows\Temp\diskless'

# Addresses are reused when a server is rebuilt, so known host keys would only raise false alarms. The keepalives end a
# session whose server restarted under it, which would otherwise wait forever.
SSHO=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
# Few SSH connections: an IPS in blocking mode takes several new ones to port 22 within a couple of minutes for a scan,
# and blocks the PC. So each step is one connection, and a restart is polled once a minute.
POLL=60
log() { echo "[${TAG:-diskless}] $*" >&2; }

# shellcheck disable=SC2029 # the remote command is built here, on purpose
run() { # run <user@host> <script> [argument...]: send a fresh copy of the scripts, then run the script (its path in the
  # repo) with the arguments, in one connection. Arguments are single words: no spaces or quotes.
  local host=$1 script=${2//\//\\} stage status=0
  shift 2
  stage=$(mktemp -d)
  cp -r servers boot image clients "$stage/"
  [[ -z ${SECRET:-} ]] || (umask 077; printf '%s\n' "$SECRET" > "$stage/servers/secret.txt")
  tar cf - -C "$stage" servers boot image clients | ssh "${SSHO[@]}" "$host" "(if exist $REMOTE rmdir /s /q $REMOTE) & \
mkdir $REMOTE && tar xf - -C $REMOTE && \
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $REMOTE\\$script $*" || status=$?
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
converge() { # converge <user@host> <script> [argument...]: run it until it stops restarting Windows
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
