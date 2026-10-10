#!/usr/bin/env bash
# Create the Proxmox pool, roles, user and ACLs that this repo's Terraform runs as (PLAN.md, phase 0). Run as root on
# any node of the cluster. Safe to re-run. Override the defaults through the environment, e.g. VLAN=40 pve-setup.sh.
# The API token is made separately, so its secret never reaches a terminal (docs/environment.md).
set -euo pipefail

POOL=${POOL:-diskless}
PVE_USER=${PVE_USER:-diskless@pve}
TEMPLATE=${TEMPLATE:-9021}         # Windows Server 2025 template the servers are cloned from
STORAGE=${STORAGE:-local-zfs}      # VM disks
ISO_STORAGE=${ISO_STORAGE:-local}  # Windows 11 and virtio-win ISOs
BRIDGE=${BRIDGE:-vmbr0}
VLAN=${VLAN:-31}
TEMPLATE_VLAN=${TEMPLATE_VLAN:-30}  # the template's NIC: a clone starts on it, so cloning checks SDN.Use on it too
ROLE=Diskless
ISO_ROLE=DisklessIsoReader

# Everything needed to create, configure, run and delete the pool's VMs. VM.GuestAgent.Unrestricted lets
# bootstrap-server.sh give a new server its address through the guest agent, before the network has DHCP.
PRIVS="Pool.Audit VM.Allocate VM.Audit VM.Clone VM.Console VM.PowerMgmt VM.Snapshot VM.Snapshot.Rollback \
VM.Config.CDROM VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options \
VM.GuestAgent.Audit VM.GuestAgent.Unrestricted"
# Attaching an ISO needs read access to its storage, nothing more (PVE::Storage::check_volume_access)
ISO_PRIVS="Datastore.Audit"

role() {
  if pveum role list --output-format json | grep -q "\"roleid\":\"$1\""; then
    pveum role modify "$1" --privs "$2"
  else
    pveum role add "$1" --privs "$2"
  fi
}
role "$ROLE" "$PRIVS"
role "$ISO_ROLE" "$ISO_PRIVS"
pvesh get "/pools/$POOL" >/dev/null 2>&1 || pveum pool add "$POOL" --comment "Diskless Windows boot (windows-scsi-boot repo)"
pveum user list --output-format json | grep -q "\"userid\":\"$PVE_USER\"" ||
  pveum user add "$PVE_USER" --comment "Terraform for the windows-scsi-boot repo"

pveum acl modify "/pool/$POOL" --users "$PVE_USER" --roles "$ROLE"                               # the pool's VMs
pveum acl modify "/vms/$TEMPLATE" --users "$PVE_USER" --roles PVETemplateUser                    # clone the template
pveum acl modify "/storage/$STORAGE" --users "$PVE_USER" --roles PVEDatastoreUser                # disks
pveum acl modify "/storage/$ISO_STORAGE" --users "$PVE_USER" --roles "$ISO_ROLE"                 # ISOs, read only
for v in $VLAN $TEMPLATE_VLAN; do                                                                # these VLANs only
  pveum acl modify "/sdn/zones/localnetwork/$BRIDGE/$v" --users "$PVE_USER" --roles PVESDNUser
done

pveum acl list --output-format json |
  python3 -c "import json,sys; [print(a['path'], a['roleid']) for a in json.load(sys.stdin) if a['ugid'] == '$PVE_USER']"
