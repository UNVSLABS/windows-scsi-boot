# Environment

Phase 0 of the [plan](../PLAN.md): the Proxmox pool and permissions, the flat network, and Terraform that creates the two Windows Servers and three diskless clients. Sources are in [lab/](../lab). The environment's values are all in [lab/lab.auto.tfvars](../lab/lab.auto.tfvars); change them for yours.

## What it creates

| VM | VMID | Made from | Size | Address | State after apply |
|---|---|---|---|---|---|
| vm-dl-dc-1 | 5010 | Full clone of 9021 `tpl-win2025`, with the Windows 11 LTSC ISO in its CD drive | 2 vCPU, 4 GiB, 64 GB | 10.31.0.10 | Running, named, on its static address |
| vm-dl-san-1 | 5020 | Full clone of 9021, plus a 200 GB data disk | 4 vCPU, 8 GiB, 64 GB + 200 GB | 10.31.0.20 | Running, named, on its static address |
| dl-ws-1 to dl-ws-3 | 5031-5033 | Empty: UEFI without Secure Boot keys, TPM 2.0, a VirtIO RNG, no disk, boots from `net0` | 2 vCPU, 4 GiB | DHCP reservation for 10.31.1.1-.3 (phase 3) | Stopped |

- **Fixed MACs:** `02:00` followed by the address in hex (10.31.1.1 is `02:00:0A:1F:01:01`). DHCP reservations and ARP caches keep working across a rebuild. `terraform output clients` prints them for `clients.csv`.
- **Clients stay stopped.** Start them by hand for a test, so they use no memory otherwise.
- **The servers' first boot:**
  - finishes Windows setup with no questions, as every clone of the template does;
  - then [lab/bootstrap-server.sh](../lab/bootstrap-server.sh) gives each one its static address, gateway, DNS and computer name;
  - it does this through the QEMU guest agent, because the network has no DHCP until phase 1 and a new clone can't be reached over SSH.
- **Clients have a random number generator** (`rng0`, from the host's `/dev/urandom`). Since 2025, OVMF offers no network boot without one: its network stack needs the entropy. Without it the firmware lists no PXE option at all, sends no DHCP request, and stops at "No bootable option or device was found". Physical machines have a hardware RNG.
- **Clients have no tags.** Proxmox checks tag permission on `/vms/<id>` before a new VM joins its pool, so the pool's ACL doesn't cover it. Servers are clones, which are already in the pool when tagged.
- **One CD drive per VM.** The bpg provider (0.116) refuses a second `cdrom` block. So virtio-win is downloaded where it's needed (phase 2), rather than attached.

## Prerequisites

| What | Here | Requirement |
|---|---|---|
| Proxmox VE | 9.2, node srv-pve-1 | A VLAN-aware bridge, and a thin-provisioned storage for VM disks |
| Server template | VMID 9021 `tpl-win2025` ([lab repo images/windows](../../lab/docs/windows-images.md)) | Windows Server 2025, sysprepped, with the QEMU guest agent, and OpenSSH that accepts your key as `admin` |
| ISOs | `local:iso/SW_DVD9_WIN_ENT_LTSC_2024_64-BIT_ENGLISH_MLF_X23-70046.ISO` | Windows 11 media for the install share |
| Network | VLAN 31, 10.31.0.0/16, gateway 10.31.0.1 on the UniFi gateway, DHCP off, firewall zone Development | One broadcast domain with no DHCP server. A gateway if the clients need the internet. Reachable from where you run SSH. An IPS in blocking mode on the way may take the setup's SSH sessions for a scan and block them: allow-list the workstation to the network, or exclude the network from IPS |
| Workstation | WSL Ubuntu with Terraform ≥ 1.5, curl, python3, iconv | Runs Terraform and `bootstrap-server.sh` |

## Setting it up

From this repo on the PC, in Git Bash. Each step is safe to re-run.

1. **Pool, roles, user and permissions** ([lab/pve-setup.sh](../lab/pve-setup.sh)), as root on a node:
   ```sh
   ssh srv-pve-1 'bash -s' < lab/pve-setup.sh       # e.g. VLAN=40 TEMPLATE=9000 to override a default
   ```
   It creates:
   - pool `diskless`, user `diskless@pve`;
   - role `Diskless` on the pool;
   - clone-only on the template;
   - `PVEDatastoreUser` on `local-zfs`;
   - role `DisklessIsoReader` (`Datastore.Audit`) on `local`: attaching an ISO needs only that;
   - `PVESDNUser` on `vmbr0` VLAN 31, and on VLAN 30. A clone starts on the template's NIC, which is on VLAN 30, so cloning checks that VLAN too.
2. **A token for Terraform,** written straight into a file in WSL, so the secret is never shown ([lab/token-env.py](../lab/token-env.py)):
   ```sh
   ssh srv-pve-1 'pveum user token add diskless@pve pc --privsep 0 --output-format json' |
     python lab/token-env.py https://srv-pve-1.infra-1.adl.unvslab.com:8006/ |
     wsl -- bash -c 'umask 077; mkdir -p ~/.config/proxmox && cat > ~/.config/proxmox/diskless.env'
   ```
3. **The network.** In UniFi, create network `Diskless`:
   - VLAN 31, gateway 10.31.0.1/16;
   - DHCP mode None;
   - zone Development, so clients reach the internet but not the rest of the lab, and the PC reaches them through the zone's existing `workstations to dev machines` policy.
   - `vmbr0` already trunks every VLAN to the gateway.
4. **The VMs,** in WSL:
   ```sh
   cd lab && . ~/.config/proxmox/diskless.env
   terraform init && terraform apply
   ```
   `apply` waits for both servers' bootstrap.
5. **Check:** `ssh admin@10.31.0.10 hostname` and `ssh admin@10.31.0.20 hostname`.

## Verified

On srv-pve-1, 2026-10-10:
- **Permissions.** The token saw only template 9021 and its own pool, listed the ISOs on `local`, and got 403 for a prod VM.
- **Apply from scratch** took 8 minutes 20 seconds, and created all five VMs.
  - The two full clones took about 6 minutes together, or 2 alone.
  - The clients took 5–7 seconds once the clones were done.
  - Created at the same time as the clones, two clients had timed out on `local-zfs`'s storage lock, hence `depends_on` and `clone.retries`.
- **Clients** are as intended: no disk, `boot: order=net0`, an EFI disk without keys, TPM 2.0, fixed MAC, VLAN 31, stopped. The RNG (`rng0`) came in phase 1, when a client without one wouldn't network-boot ([servers](servers.md#what-each-piece-is-for)).
- **Bootstrap.** Both servers came up with their names and addresses, `VM-DL-DC-1` on 10.31.0.10 and `VM-DL-SAN-1` on 10.31.0.20, about 2 minutes after their clones finished, restart included.
  - Re-running it on a server that's already set changed nothing and passed its check in 11 seconds.
  - Its final check caught clones whose Windows was broken: a host with a faulty memory stick fed them corrupted reads (lab repo [windows-images.md](../../lab/docs/windows-images.md#known-problem-clones-crash-on-srv-pve-1)). Rebuild such a VM with `-replace`.
- **`destroy`** removed all 7 resources, and left no VMs or volumes in 5000–5099. A plan after `apply` showed no changes.

- **Network.**
  - `ssh admin@10.31.0.10` and `admin@10.31.0.20` from the PC returned the servers' names.
  - Both resolved DNS through the gateway and reached the internet on TCP 443.
  - From VLAN 31, the Proxmox UI (10.10.0.10:8006) and SSH on prod hosts (10.20.0.50 and .80) were unreachable, as the Development zone intends.

## Operations

All in WSL in `lab/`, with `diskless.env` loaded.

| Task | How |
|---|---|
| Start or stop a client | `qm start 5031` as root on the node, or from the Proxmox UI |
| Rebuild a server from scratch | `terraform apply -replace='proxmox_virtual_environment_vm.server["vm-dl-dc-1"]'`. Its bootstrap runs again |
| Re-run a server's bootstrap | `terraform apply -replace='terraform_data.bootstrap["vm-dl-dc-1"]'` |
| Change a client's NIC model (PLAN.md, NIC independence) | Edit its `nic_model` in `lab.auto.tfvars` and `terraform apply`. Its MAC stays the same |
| Remove everything | `terraform destroy`. Then, as root on the node: `pveum user delete diskless@pve`, `pveum pool delete diskless`, `pveum role delete Diskless` and `pveum role delete DisklessIsoReader` |
