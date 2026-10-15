# The lab

The environment this repo was built and tested in: two Windows Server VMs and diskless VM clients on one Proxmox VE node, on a VLAN of their own behind a UniFi gateway. Everything specific to it is on this page. [lab/](../lab) has its Terraform and setup scripts.

## Values

| | Here |
|---|---|
| Hypervisor | Proxmox VE 9.2, node `srv-pve-1` |
| VM storage | `local-zfs`, thin-provisioned. ISOs on `local` |
| Pool and access | Pool `diskless`; user `diskless@pve`, with an API token for Terraform and the scripts |
| VMIDs | 5000–5099 |
| Network | Bridge `vmbr0`, VLAN 31: 10.31.0.0/16, gateway 10.31.0.1 on the UniFi gateway, with its DHCP off |
| Server template | VMID 9021 `tpl-win2025`: Windows Server 2025 Standard, sysprepped, with the QEMU guest agent and OpenSSH accepting the admin's key as `admin`. Built by the separate lab repo's `images/windows/` |
| Windows media | `SW_DVD9_WIN_ENT_LTSC_2024_64-BIT_ENGLISH_MLF_X23-70046.ISO` on `local`, in the domain controller's CD drive |
| Domain | `diskless.adl.unvslab.com`, NetBIOS name `DISKLESS` |

The values in [servers/settings.psd1](../servers/settings.psd1):

| Setting | Here |
|---|---|
| `DcAddress`, `SanAddress`, `Gateway` | 10.31.0.10, 10.31.0.20, 10.31.0.1 |
| `Network`, `SubnetMask` | 10.31.0.0/16, 255.255.0.0 |
| `ScopeStart`, `ScopeEnd` | 10.31.1.1 to 10.31.2.254 |
| `ReservedStart`, `ReservedEnd` | 10.31.1.1 to 10.31.1.255: clients' reservations. Other machines lease from 10.31.2.x |
| `BootFiles`, `TftpRoot`, `InstallShare` | `C:\BootFiles`, `C:\RemoteInstall`, `C:\Install` |
| `SanDataDrive` | `D`, the storage server's 200 GB data disk |
| `IqnPrefix` | `iqn.2026-10.com.unvslab.adl.diskless` |
| `Locale`, `UILanguage`, `TimeZone` | `en-AU`, `en-US`, `Cen. Australia Standard Time` |
| `BuildVm` | `dl-build-1` |

## VMs

| VM | VMID | Made from | Size | Address |
|---|---|---|---|---|
| vm-dl-dc-1, the domain controller | 5010 | A full clone of the template, with the Windows 11 ISO in its CD drive | 2 vCPU, 4 GiB, 64 GB | 10.31.0.10 |
| vm-dl-san-1, the storage server | 5020 | A full clone of the template, plus a 200 GB data disk | 4 vCPU, 8 GiB, 64 GB + 200 GB | 10.31.0.20 |
| dl-ws-1 to dl-ws-3, clients | 5031–5033 | Empty. NICs: virtio, e1000e and vmxnet3, one of each NIC family in the driver pack | 2 vCPU, 4 GiB | Reservations 10.31.1.1–.3 |
| dl-build-1, the build machine | 5030 | Empty, with an e1000e NIC | 4 vCPU, 4 GiB | Reservation 10.31.1.250 |

- **Diskless VMs** (clients and the build machine): OVMF without Secure Boot keys, TPM 2.0, a VirtIO RNG, no disk, booting from `net0`. dl-ws-2's e1000e is the build NIC's model at its slot, so its first boot leaves the image's NIC as it is; the other two get their interfaces made.
- **Fixed MACs:** `02:00` followed by the address in hex, so 10.31.1.1 is `02:00:0A:1F:01:01`. DHCP reservations and ARP caches keep working across a rebuild. `terraform output clients` prints the clients' rows for `clients.csv`. The image scripts work out the build machine's address from its MAC this way ([scripts.md](scripts.md#hypervisor-specific-parts)).
- **Clients stay stopped,** so they use no memory until started by hand for a test, or by `clients/check.sh --boot`.
- **A random number generator** (`rng0`, from the host's `/dev/urandom`) on each diskless VM: Proxmox's OVMF offers no network boot without one ([requirements.md](requirements.md#client-machines)).
- **Servers are full clones,** not linked: they're long-lived, and shouldn't depend on the template. Terraform ignores later changes to the clone settings and the machine version, which Proxmox pins for Windows guests.
- **Clients have no tags.** Proxmox checks tag permission on `/vms/<id>` before a new VM joins its pool, so the pool's permissions don't cover it. Servers are clones, which are in the pool by the time they're tagged.
- **One CD drive per VM:** the bpg provider refuses a second, so the driver pack is downloaded by the domain controller rather than attached as an ISO.

## Network

In UniFi, the network `Diskless`:
- VLAN 31, gateway 10.31.0.1/16, DHCP mode None;
- in the firewall zone Development, so clients reach the internet but not the rest of the lab, and the workstation reaches them through the zone's policy for workstations;
- `vmbr0` already trunks every VLAN to the gateway.

The gateway runs its IPS in blocking mode, which took the scripts' bursts of SSH connections for a scan, and blocked and reset them. The workstation is allow-listed for the network. When SSH to a server times out while ping and RDP still work, that's the IPS: the block lapses after a few minutes, and the guest agent (`lab/pve.sh`'s `guest_ps`) reaches the VMs without the network.

## Proxmox access

[lab/pve-setup.sh](../lab/pve-setup.sh), as root on a node, makes:
- the pool `diskless`, and the user `diskless@pve`;
- the role `Diskless` on the pool: creating, configuring, running and deleting its VMs, and the guest agent, which bootstraps the servers;
- clone-only on the template (`PVETemplateUser`);
- `PVEDatastoreUser` on `local-zfs`;
- the role `DisklessIsoReader` (`Datastore.Audit`) on `local`: attaching an ISO needs only that;
- `PVESDNUser` on `vmbr0` VLAN 31, and on VLAN 30. A clone starts on the template's NIC, which is on VLAN 30, so cloning checks that VLAN too.

Terraform and [lab/pve.sh](../lab/pve.sh) use an API token from the environment (`PROXMOX_VE_ENDPOINT` and `PROXMOX_VE_API_TOKEN`), kept in `~/.config/proxmox/diskless.env` in WSL. Load it before Terraform or a script that drives VMs:

```sh
. ~/.config/proxmox/diskless.env
```

## Setting it up

From the repo, in Git Bash or WSL. Each step is safe to re-run.

1. **Pool, roles, user and permissions,** as root on a node (override a default with, for example, `VLAN=40`):
   ```sh
   ssh srv-pve-1 'bash -s' < lab/pve-setup.sh
   ```
2. **A token,** written straight into the environment file in WSL, so the secret is never shown ([lab/token-env.py](../lab/token-env.py)):
   ```sh
   ssh srv-pve-1 'pveum user token add diskless@pve pc --privsep 0 --output-format json' |
     python lab/token-env.py https://srv-pve-1.infra-1.adl.unvslab.com:8006/ |
     wsl -- bash -c 'umask 077; mkdir -p ~/.config/proxmox && cat > ~/.config/proxmox/diskless.env'
   ```
3. **The network,** in UniFi ([above](#network)).
4. **The VMs,** in WSL, with Terraform 1.5 or later:
   ```sh
   cd lab && . ~/.config/proxmox/diskless.env
   terraform init && terraform apply
   ```
   `apply` creates the five VMs and waits for both servers' bootstrap: about 10 minutes.
5. **Check:** `ssh admin@10.31.0.10 hostname` and `ssh admin@10.31.0.20 hostname`.

Then the servers, the image and the clients, as in [operations.md](operations.md#workflow), with `ADMIN_PASSWORD` in `.env` set to the template's admin password.

**Bootstrap.** The network has no DHCP until the domain controller runs it, so a new clone has only a link-local address, and SSH can't reach it. Terraform runs [lab/bootstrap-server.sh](../lab/bootstrap-server.sh) for each new server, which sets its static address, gateway, DNS and computer name through the QEMU guest agent, and restarts it. Its final check also shows whether the clone's Windows works at all.

## Operations

In WSL in `lab/`, with the token loaded.

| Task | How |
|---|---|
| Start or stop a client | `qm start 5031` as root on the node, the Proxmox UI, or `clients/check.sh --boot dl-ws-1` |
| Rebuild a server from scratch | `terraform apply -replace='proxmox_virtual_environment_vm.server["vm-dl-dc-1"]'`. Its bootstrap runs again; then `servers/setup.sh` |
| Re-run a server's bootstrap | `terraform apply -replace='terraform_data.bootstrap["vm-dl-dc-1"]'`. Only before the servers are set up: it sets the server's DNS back to the gateway |
| Change a client's NIC model | Its `nic_model` in `lab.auto.tfvars`, and `terraform apply`. Its MAC stays the same. It needs a first boot on the new NIC: a new disk, or the first boot run again ([clients.md](clients.md#the-first-boot)) |
| Remove everything | `terraform destroy`. Then, as root on the node: `pveum user delete diskless@pve`, `pveum pool delete diskless`, `pveum role delete Diskless` and `pveum role delete DisklessIsoReader` |
