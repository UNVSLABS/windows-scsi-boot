"""Turn `pveum user token add ... --output-format json` on stdin into an env file for Terraform's bpg provider, on
stdout. Pipe it straight into the file, so the secret is never shown (docs/environment.md):
    token-env.py <endpoint, e.g. https://pve.example.com:8006/>"""
import json, sys

if len(sys.argv) != 2:
    sys.exit(__doc__)
sys.stdout.reconfigure(newline="\n")  # Python on Windows would end lines with CRLF, and the token with a \r
d = json.load(sys.stdin)
print(f"# windows-scsi-boot: token {d['full-tokenid']}, made by lab/pve-setup.sh's user")
print(f"export PROXMOX_VE_ENDPOINT={sys.argv[1]}")
print(f"export PROXMOX_VE_API_TOKEN='{d['full-tokenid']}={d['value']}'")
