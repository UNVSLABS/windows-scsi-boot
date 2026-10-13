# Diskless Windows boot from Windows Server

Windows 11 clients with no local disk boot over the network from their own iSCSI disk on a Windows Server. Each client's disk is a differencing VHDX on one shared, read-only golden image, so storage grows only with each client's own writes. A second Windows Server provides the domain, DHCP and the network boot files.

This plan builds it on Proxmox VE, as an example and starting point for the same setup elsewhere. The values specific to this environment are in [Target environment](#target-environment); substitute your own. Decided 2026-10-10.

## What it does

1. **Windows Server hosts the images,** with the built-in iSCSI Target Server.
2. **Differencing disks keep storage small:** each golden image version is stored once, plus each client's own writes.
3. **Any machine that can UEFI network-boot on the network becomes a client,** VM or physical. It gets its own disk by MAC address, with nothing configured on the machine itself.
4. **Images are built and changed in VMs** and also boot physical workstations. Ideally the NIC model doesn't matter ([NIC independence](#nic-independence)).
5. **Clients are joined to the domain** and keep their changes until the next image update.

Not covered: CHAP authentication, backups, Windows activation, and user data on a share. Clients use Microsoft's KMS client keys and stay unactivated.

## Status

| Phase | What | State |
|---|---|---|
| 0 | Environment setup, repo, Terraform for the VMs | **Done 2026-10-10** ([docs/environment.md](docs/environment.md#verified)) |
| 1 | Domain controller with DHCP and boot files; storage server with iSCSI Target | **Done 2026-10-10** ([docs/servers.md](docs/servers.md#verified)) |
| 2 | Golden image, and the NIC-independence test | **Done 2026-10-11:** `golden-v4` is built on iSCSI by the scripts, and boots clients with the build's two NIC families, Intel's (e1000e) and vmxnet3, a stand-in for a second physical family, at any PCI slot ([docs/image.md](docs/image.md#nic-independence)) |
| 3 | Clients on differencing disks, joined to the domain | **Done 2026-10-12:** three clients boot together from `golden-v5`, each with its own name and SID, joined to the domain, and a domain user logs on. A client needs only to be switched on: the golden image's first boot makes its NIC a boot NIC by itself ([docs/clients.md](docs/clients.md#results)) |
| 4 | Image updates and failure behaviour | **Done 2026-10-12:** `golden-v6`, made from `golden-v5` by changing it on the build VM, and the three clients moved to it by `update-clients.sh`, keeping their computer accounts. Clients ride out a storage server restart: since `golden-v6` they wait up to 10 minutes for their disk, where Windows' default of 60 seconds took them down. They don't need the domain controller while they run ([docs/clients.md](docs/clients.md#when-a-server-restarts)) |

Details are in [Phases](#phases).

## How it works

```
Client (VM or physical)                              vm-dl-dc-1: AD DS, DNS, DHCP, TFTP, HTTP
 1 UEFI PXE ──DHCP, x64 UEFI client───────────────▶  its reserved IP + boot file snponly.efi
 2          ──TFTP────────────────────────────────▶  snponly.efi (iPXE)
 3 iPXE     ──DHCP, user class "iPXE"─────────────▶  boot file http://<dc>/boot/boot.ipxe
 4          ──HTTP────────────────────────────────▶  boot/<mac>.ipxe: the menu, with this client's target

                                                     vm-dl-san-1: iSCSI Target Server only
 5          ──iSCSI :3260, sanboot────────────────▶  target <name>, which accepts only this client's IQN
 6 Windows Boot Manager loads from the LUN;             LUN = clients\<name>.vhdx (differencing disk)
   Windows reads the iBFT, reconnects to the same         └─ parent: images\golden-vN.vhdx (read-only)
   target, and the disk never drops
   (a new disk's first boot: WinPE from the disk first, which makes this machine's NIC a boot NIC, then restarts)
```

- **iPXE is the stock `snponly.efi`.** It drives the NIC through the firmware's own UEFI driver, so any NIC that can network-boot works before Windows starts. Nothing has to be compiled.
- **DHCP policies on the domain controller choose what to hand out:** a UEFI x64 PXE request gets `snponly.efi` over TFTP, and a request from iPXE gets `boot.ipxe` over HTTP.
- **Each client's boot script is a static file** (`boot/<mac>.ipxe`), written by `New-Client.ps1`. No custom web service is needed.
- **A client's first boot needs nothing from outside.** The golden image carries a WinPE and a boot entry that starts it, as Windows Boot Manager's default. On a new disk's first boot, that WinPE makes the machine's NIC a boot NIC of the disk's Windows, sets the default back to Windows, and restarts ([NIC independence](#nic-independence)). So a client only has to be switched on, and an image update needs nothing per machine.
- **The menu:**
  - a known client gets Windows from its own disk; WinPE with its disk attached (`sanhook`), for recovery; and Memtest86+;
  - an unknown MAC gets WinPE and Memtest86+ only;
  - building the golden image uses a separate build menu.
- **iPXE writes the session's settings into the iBFT** (iSCSI Boot Firmware Table). That's how Windows' own iSCSI initiator takes over the session once the kernel loads.
- **The iBFT has no gateway.** Windows sends iSCSI through the iBFT's gateway even to a target on its own subnet, so the boot scripts clear it before attaching the disk. Windows still gets its default gateway from DHCP.
- **Secure Boot is off on clients,** because the stock `snponly.efi` is unsigned. iPXE has had a Microsoft-signed shim since 2025 (iPXE 16.1), if Secure Boot is needed later.

## Target environment

| Item | Value here | Purpose |
|---|---|---|
| Hypervisor | Proxmox VE 9.2, node srv-pve-1 | Runs both servers and the test clients |
| VM storage | `local-zfs`, thin-provisioned | VM disks |
| Pool and access | Pool `diskless`; user `diskless@pve` with an API token for Terraform | Keeps the project's VMs and permissions separate |
| VMIDs | 5000–5099 | |
| Network | Bridge `vmbr0`, VLAN 31, 10.31.0.0/16 | One flat network: storage and normal traffic share each machine's single NIC |
| Gateway | 10.31.0.1 (UniFi), with its DHCP off | Internet for clients. The domain controller is the only DHCP server |
| Server template | VMID 9021 `tpl-win2025`: Windows Server 2025 Standard, sysprepped, OpenSSH with key logins. Built by the lab repo's [images/windows/](../lab/docs/windows-images.md) | Both servers are full clones of it |
| Install media | The Windows 11 Enterprise LTSC 2024 ISO on `local`, in the domain controller's CD drive. The driver pack (virtio-win and others) is downloaded by the domain controller: the provider allows one CD drive per VM | WinPE and Windows setup for the golden image |
| AD domain | `diskless.adl.unvslab.com`, NetBIOS name `DISKLESS` | The clients' domain. A subdomain of a domain you own: not `.local`, a single label, or your public apex |

### Network requirements

- **One broadcast domain** shared by clients and both servers.
- **No other DHCP server** on it.
- **Client VMs with a random number generator:** since 2025, OVMF offers no network boot without one.
- **An IPS that lets the setup's SSH through.** An IPS in blocking mode can take its SSH sessions for a scan: allow-list the workstation to the network.
- **A gateway,** if clients need the internet.
- **Clients that can UEFI PXE-boot** with Secure Boot off.

### VMs

| VM | Made from | Size | Address |
|---|---|---|---|
| vm-dl-dc-1 | Full clone of 9021 | 2 vCPU, 4 GiB, 64 GB | 10.31.0.10, MAC `02:00:0A:1F:00:0A` |
| vm-dl-san-1 | Full clone of 9021 | 4 vCPU, 8 GiB, 64 GB OS disk + 200 GB thin data disk | 10.31.0.20, MAC `02:00:0A:1F:00:14`; and 10.31.0.21, for the build's second NIC |
| dl-ws-1 to dl-ws-3 | Empty: UEFI without Secure Boot keys, TPM 2.0, a VirtIO RNG, no disk, boots from the network. NICs vmxnet3, e1000e and vmxnet3: models the golden image boots | 2 vCPU, 4 GiB each | DHCP reservation per fixed MAC |
| dl-build-1 | Empty, like the clients, with an Intel e1000e NIC, and while setup runs a vmxnet3 NIC, standing in for a second physical NIC family. Builds golden images | 4 vCPU, 4 GiB | DHCP reservation, 10.31.1.250 |

- **Fixed MACs** are `02:00` followed by the IPv4 address in hex.
- **Full clones, not linked,** because the servers are long-lived and shouldn't depend on the template.
- **Configuration:** Terraform (bpg provider) creates the VMs. PowerShell over SSH as `admin` configures the servers.
- **Bootstrap:** the network has no DHCP until the domain controller provides it. So Terraform sets each new server's static address and computer name through the QEMU guest agent ([docs/environment.md](docs/environment.md)).

### Physical workstations

A physical workstation becomes a client by:
1. connecting to VLAN 31, e.g. a switch port with VLAN 31 as its native network;
2. setting its firmware to UEFI network boot with Secure Boot off;
3. adding its MAC to `clients.csv`.

Its NIC model must be one the golden image's build had ([NIC independence](#nic-independence)).

**Moving the setup.** Both servers are ordinary Proxmox VMs. The whole setup moves to another Proxmox host with vzdump and restore.

## Servers

| | vm-dl-dc-1 | vm-dl-san-1 |
|---|---|---|
| Roles | AD DS and DNS for the clients' domain; DHCP; WDS, TFTP only; IIS, static files only | iSCSI Target Server |
| Holds | The boot scripts, `snponly.efi`, wimboot, WinPE, Memtest86+, and a share with the Windows install media | Golden images and child disks, on its data disk |

- **The storage server does only iSCSI,** so its load and restarts stay separate from identity and network services.
- **The domain controller holds everything a client needs before its disk is attached.**
- **IIS on a domain controller** isn't Microsoft's preferred layout, so it serves static files only. Moving the boot files to another server changes only where the scripts write.
- **Sizing:** Microsoft's guide is about 60 clients per 1 GbE on the storage server.

## Differencing disks

- **Golden image** (`images\golden-vN.vhdx`):
  - Windows 11 Enterprise LTSC 2024, installed *onto an iSCSI LUN* and sysprepped.
  - Then set read-only, with both a file attribute and an ACL.
  - It's never written again, because any write to a parent breaks every child built on it.
  - It isn't joined to the domain. Each client joins on its first boot.
- **Child per client** (`clients\<name>.vhdx`):
  - Made with `New-IscsiVirtualDisk -Path ... -ParentPath ...`.
  - One iSCSI target per client, which accepts only that client's IQN.
  - The client's first boot makes its NIC a boot NIC, then finishes Windows setup into the child, on its own hardware.
- **Children persist until the next image update.** An update recreates every child from the new golden image, so anything stored on a client is wiped then.
- **Windows Update is off on clients,** through Group Policy. Updates arrive in new golden images, which keeps children small.
- **Nothing defragments a client's disk, NTFS keeps no last-access times, and .NET's native images are compiled in the golden image,** since `golden-v10`. Otherwise Windows' automatic maintenance, in a new client's first idle minutes, moves and writes over the whole disk, and a child grows by a 2 MB block for each part of the disk first written, however little ([docs/clients.md](docs/clients.md#automatic-maintenance)).

| Storage (measured in phase 3) | Size |
|---|---|
| Golden image, per version | 12.2 GB (`golden-v5` and `golden-v6`, with 0.5 GB of WinPE for the first boot). The clients' version, and the one before to roll back to, until deleted by hand |
| Child, after first boot | 1.1–1.2 GB; 1.3 GB after the second; about 0.4 GB more for each user's first logon |
| Child, grows by | the client's writes until the next image update, plus its pagefile as it's written, up to its fixed 2 GB (Group Policy); and about 1.5 GB at Windows' first automatic maintenance, 10 minutes after its first start (since `golden-v10`; 6 GB before) |

Microsoft's own example: one 40 GB base image plus 2 GB per client is 552 GB for 256 machines, instead of about 10 TB of full copies.

## Client lifecycle

All driven by `clients/clients.csv` (name, MAC, address). The scripts run from the workstation, like the server setup: each step is one SSH connection to one server. A script on the storage server couldn't do the domain controller's part as planned at first, through PowerShell remoting: an SSH logon with a key carries no credentials to pass on.

**`clients/new-client.sh <name>`** ([docs/clients.md](docs/clients.md)):
1. **On the domain controller:**
   - the clients' OU and Group Policy, if they're missing;
   - a DHCP reservation for the MAC;
   - the computer account in that OU, and an offline domain join for it (`djoin /provision /reuse /printblob`).
2. **On the storage server:**
   - creates `clients\<name>.vhdx` with the newest golden image as parent;
   - mounts it, and writes the computer name and the domain join into the answer file that sysprep left in it, with a `SetupComplete.cmd` that deletes that file once Windows setup is done;
   - creates target `<name>` restricted to the client's IQN, and assigns the disk to it.
3. **On the domain controller:** writes `boot/clients/<mac>.ipxe`.
4. **The client's first boot,** once it's switched on, needs nothing more:
   - Windows Boot Manager on the disk starts the image's first-boot WinPE. It runs `dism /Add-NetAdapter` for the client's NIC on the disk, unless the image has that NIC already: the build NIC's model at its PCI slot. Then it sets the boot manager's default back to Windows, and restarts ([NIC independence](#nic-independence)).
   - Windows finishes setup and joins the domain, with no prompts.

**`clients/update-clients.sh <version> [<name>...]`** ([docs/clients.md](docs/clients.md#updating-clients)): every client in `clients.csv` that has a disk, or those named, while they're off.
1. **On the storage server:** takes each client's disk off its target, unless the client is on that version already or running: a session on its target. A running client is left as it is, and reported.
2. **On the domain controller:** for each of those, its reservation, and a new offline domain join (`/reuse`), which keeps its computer account and resets the account's password. So never for a running client, which would lose its trust with the domain.
3. **On the storage server:** each one's new disk on the golden image, as in step 2 above, on the same target.

The client's next start is a first boot again, so the update needs nothing per machine. Rolling back is the same, with the older version. Golden images that no disk uses any more are listed, not deleted: they're kept to roll back to, until deleted with `image/remove.sh <version>`.

**`clients/remove-client.sh <name>`:** reverses `new-client.sh`. It refuses while the client is running.

**Changing the image** (`image/change.sh`, [docs/image.md](docs/image.md#changing-an-image)), or a new build with `image/build.sh`:
1. Copy the newest golden image to `golden-v(N+1).vhdx`, assign it to the build target, and boot the build VM from it.
2. Make the changes, in its Windows.
3. `image/change.sh <N+1> --seal`: sysprep, the clients' first boot again (`image/windows/firstboot-entry.ps1`, as the build does), and read-only.
4. `clients/update-clients.sh <N+1>`.

The domain-join data holds the computer account's machine password. It goes from the domain controller to the storage server through the workstation's memory, is written only into the client's own disk, and is deleted there once Windows setup is done. It's never stored in the repo.

## NIC independence

**Goal:** one golden image, built in a VM, boots any client whose NIC driver it contains.

**Why it's hard:**
- Windows booted from iSCSI must load the boot NIC's driver at the very start of boot.
- Microsoft says an image installed on a local disk can't boot from iSCSI at all, because drivers load in a different order. That's why the golden image is installed onto an iSCSI LUN.
- The documented way to boot on other NICs is from the Windows 7 era. It edited a registry list (the Critical Device Database) that Windows 8 and later no longer have.

**Found in phase 2** ([docs/image.md](docs/image.md#nic-independence)). A NIC boots the image only with two things in it:
1. **Its driver package, reflected as critical** into the image's `SYSTEM` hive, with its service. The kernel then sets up a device of that model during boot. Windows setup does this for the first two NICs in the iBFT when it installs onto iSCSI. DISM, and the answer file's driver pack, only stage network drivers, which the kernel can't use before the boot disk is there.
2. **A network interface for that device at its PCI location,** which `dism /Add-NetAdapter` makes, from the live NIC. Setup makes it for the build VM's NICs.

So:
- **An image covers up to two NIC families.** Setup takes the first two NICs in the iBFT, however many it lists ([docs/image.md](docs/image.md#setup-takes-two-nics-from-the-ibft)): the build VM's own, and a second NIC that the build adds only while setup runs, which reaches a small disk of its own through a second address on the storage server, so that iPXE puts it in the iBFT. Each family is a driver package, covering every NIC its INF lists: the e1000e's Intel package also covers many physical Intel 1 GbE NICs.
- **The second family here is vmxnet3, a stand-in for a second family of physical NICs,** such as workstations' Realtek or newer Intel NICs that Intel's package doesn't cover. vmxnet3's driver covers only VMware's virtual adapter. A physical family needs the NIC itself in the build: passed through to the build VM, or a build on a physical workstation with the same scripts.
- **A build can have one family only** ([docs/image.md](docs/image.md#building-for-one-nic-family)).
- **virtio can't be one:** setup itself fails to reflect virtio's NetKVM driver. VM clients use e1000e or vmxnet3.
- **Each client's NIC needs its interface,** except the build NIC's model at the build NIC's slot, which sysprep keeps. Proxmox VMs have no NIC serial numbers, so a VM's `net0` of the same model is the same device; physical NICs are always new devices.
- **The golden image makes it itself, on each client's first boot** ([docs/clients.md](docs/clients.md#the-first-boot)). The build puts a WinPE into the image, with a boot entry for it as Windows Boot Manager's default. WinPE then runs on the client, from the client's own disk: it adds the interface for the live NIC, unless the image has that NIC already, sets the default back to Windows, and restarts.

**Tested** with a new MAC each time ([results](docs/image.md#results)):

| Client NIC | Result |
|---|---|
| Intel e1000e, the build NIC's model and slot | Boots unchanged |
| Intel e1000e at another PCI slot | Boots once WinPE has made its interface |
| VMware vmxnet3, the build's second family, standing in for a physical one | Boots once WinPE has made its interface |
| virtio | Doesn't boot: setup can't reflect its driver |

## Phases

0. **Environment and repo**
   - **Proxmox:** pool `diskless` and user `diskless@pve`, with a token. The token may:
     - create VMs in the pool;
     - clone template 9021;
     - attach the ISOs on `local`;
     - use `local-zfs` and `vmbr0` VLAN 31, and VLAN 30, because the template's NIC is on it and cloning checks it.
   - **Gateway:** VLAN 31 network with DHCP off; clients reach the internet only.
   - Repo layout ([below](#repo-layout)), and Terraform for the two servers and three clients. Terraform also bootstraps the servers' addresses and names.
   - *Done when:* `terraform apply` creates all five VMs, the servers answer SSH on their static addresses, and `destroy` removes everything.
1. **Servers**
   - **vm-dl-dc-1:**
     - promote to a new forest; DNS forwarder to the gateway;
     - DHCP scope with its PXE and iPXE policies;
     - WDS in TFTP-only mode;
     - IIS with `boot/`, `snponly.efi`, wimboot and Memtest86+.
   - **vm-dl-san-1:** join the domain, install iSCSI Target Server, format the data disk.
   - *Done when:* a client VM network-boots to the iPXE menu, and Memtest86+ runs.
2. **Golden image**
   - Build WinPE (Windows ADK) with the NIC drivers, so it can reach the iSCSI target.
   - A blank VHDX on the build target. The build VM boots WinPE through wimboot, with the target attached by `sanhook`; and with a second NIC model, a small second target through that NIC ([NIC independence](#nic-independence)).
   - WinPE runs setup unattended from the install share onto the iSCSI disk.
   - It reuses the answer files and scripts from the lab repo's `images/windows/`, adapted for the iSCSI disk: `autounattend.xml`, `firstlogon.ps1`, `generalize.ps1` and `sysprep.xml`. `SetupComplete.cmd` isn't needed: Windows Update stays off in the image.
   - Sysprep, then set the image read-only. Then the [NIC test](#nic-independence).
   - *Done when:* a golden image built by the scripts boots clients over iSCSI, and the NIC result is recorded.
3. **Clients**
   - `clients/new-client.sh` and `remove-client.sh`.
   - The clients' first boot in the golden image: a WinPE that makes a client's NIC a boot NIC on its own.
   - Group Policy: Windows Update off, no hibernation or fast startup, NIC power saving off, fixed pagefile size.
   - *Done when:*
     - three clients boot together from one golden image;
     - each has its own name and SID, is joined to the domain and logs in as a domain user;
     - child disk sizes are measured against the estimates.
4. **Lifecycle**
   - `image/change.sh`: a new golden image version from the last one, changed on the build VM.
   - `update-clients.sh` from one version to the next.
   - What clients do when the storage server restarts. Microsoft warns that they hang.
   - What clients do when the domain controller restarts. They should keep running: the boot NIC's address comes from the iBFT.
   - *Done when:* an update is tested end to end, and both restart behaviours are written down with how to recover.

## Decisions

| Topic | Decision | Why |
|---|---|---|
| Image hosting | iSCSI Target Server on Windows Server 2025 | Built in, with differencing VHDX. Microsoft documents it for booting up to 256 clients from one sysprepped master, with iPXE as the boot loader. It isn't deprecated in 2025 |
| Servers | Two: a domain controller (AD DS, DNS, DHCP, TFTP, HTTP) and a storage server (iSCSI Target only) | Storage load and restarts stay separate from identity and network services |
| Boot chain | UEFI PXE → stock iPXE `snponly.efi` → HTTP script → iSCSI → iBFT | Works on any NIC that can network-boot, and nothing has to be compiled. The iBFT lets Windows take over the session |
| iBFT gateway | Cleared in iPXE before every `sanboot` and `sanhook` | Windows routes iSCSI through it even on its own subnet, and a gateway needn't route that back onto the subnet. Without it, WinPE never connected the disk ([docs/image.md](docs/image.md#booting-from-iscsi)) |
| Per-client mapping | Static `boot/<mac>.ipxe` written by `New-Client.ps1`, rather than a DHCP option per client | One script owns the mapping, and DHCP stays generic. No custom service to run |
| TFTP | WDS's TFTP server. Its PXE side is non-critical, answers no one, and sets no DHCP option 60 | First-party. WDS's PXE side can't run beside a DHCP server on the same machine ([docs/servers.md](docs/servers.md#tftp-through-wds)). WDS is deprecated from the *next* Windows Server release (KB5129631) but supported for 2025's lifecycle. Fallback: a standalone TFTP service |
| Persistence | Children persist until the next image update, which recreates them | Clients keep their state between reboots, and images are updated in one place |
| Client identity | An offline domain-join file and the computer name, written into each child disk before its first boot | Each client joins on first boot without credentials on the network, and keeps its computer account across updates |
| Client OS | Windows 11 Enterprise LTSC 2024 | No Store apps to update, and a long servicing life |
| Network | One flat network, one NIC per machine | No separate storage network, so ordinary single-NIC workstations work |
| Secure Boot | Off on clients | The stock `snponly.efi` is unsigned. The signed iPXE shim is the path to turning it on |
| Tooling | Terraform for VMs; PowerShell over SSH for everything in Windows. No Packer | Few moving parts, and every step can be re-run |
| Build NIC | Intel (an e1000e in the lab), not virtio | Setup makes the build's NICs boot NICs of the image, and fails to for virtio's NetKVM |
| Second NIC family | vmxnet3 as a stand-in for a second physical family, on the build VM only while setup runs, through a second storage server address. Optional: a build can have one family | Setup takes only the first two NICs in the iBFT. iPXE puts a NIC there only for a disk it reaches, so the second NIC has a target of its own. Present at Windows' first boot, it made setup restart. vmxnet3 is a NIC a VM can have whose driver setup reflects; a physical family needs its NIC in the build |
| A client's NIC | Its interface made on the client's first boot (`dism /Add-NetAdapter`), by a WinPE that the golden image carries and Windows Boot Manager starts first | Windows keys a boot NIC's TCP/IP binding to the NIC's PCI location, which differs between machines. From the disk, the first boot needs nothing from outside: no boot script to switch between boots, for a VM or a physical machine, and an image update needs nothing per machine |
| Client scripts | Run from the workstation, one SSH connection per server step, as for the servers | An SSH logon with a key carries no credentials, so a script on the storage server can't act on the domain controller |
| Changing an image | A copy of the newest golden image, booted on the build VM, changed, and sealed again as a new version (`image/change.sh`); or a new build | Changes made by hand, such as an application, need no build. A change to the build's own scripts takes a build |
| An update's order | The storage server takes the disks of clients that are off; only then does the domain controller make their new domain joins | A new join resets the computer account's password, which a running client still uses |
| Old golden images | Kept until deleted by hand (`image/remove.sh`), which refuses while any disk is on one | They're what clients roll back to |
| A failed disk boot | iPXE goes back to its menu after 30 seconds, whose default boots Windows | A client that starts, or goes down and restarts, while the storage server is away gets its disk once it's back, with no one there |
| Server updates | Downloaded automatically, installed and restarted by an admin | Clients pause while the storage server restarts, and go down if it's away for longer than they wait, so restarts must be planned |
| How long clients wait for their disk | 10 minutes: the iSCSI initiator's `MaxRequestHoldTime`, in the golden image, rather than Windows' 60 seconds | A storage server restart can take longer than a minute, and a client that stops waiting goes down ([docs/clients.md](docs/clients.md#the-storage-server)) |
| Windows' automatic maintenance on clients | The golden image's seal turns off NTFS's last-access times, SysMain's boot optimization (`EnableAutoLayout` 0), the scheduled defrag and SysMain's swap assessment, and compiles .NET's queued native images. The rest of the maintenance runs | Everything maintenance writes lands in a client's child disk for good, a whole 2 MB block for each part of the disk it first writes to. At its first maintenance a new client grew from 1.5 GB to 7.5–8 GB; with these, to about 2.8 GB. In the image, rather than Group Policy, because a client has it from its first start, and native images can only be compiled once in the image ([docs/clients.md](docs/clients.md#automatic-maintenance)) |

## Risks

| Risk | Effect | What we do |
|---|---|---|
| An image boots only the NIC families its build had (**found**, phase 2) | A VM-built image serves physical workstations only with Intel NICs its driver covers | Two families per image. A second physical family: its NIC passed through to the build VM in vmxnet3's place, or a build on a physical workstation |
| Windows 11 booting from iSCSI isn't officially supported; Microsoft's docs cover Windows Server | No vendor support | Widely used with iPXE. Setup onto iSCSI is checked first in phase 2 |
| WinPE doesn't connect the iSCSI disk in the iBFT (**happened**, phase 2) | Setup can't install onto iSCSI, so there's no golden image | Solved: Windows routed iSCSI through the iBFT's gateway, which iPXE now leaves out ([docs/image.md](docs/image.md#booting-from-iscsi)) |
| Windows 11 setup may refuse to install with Secure Boot off | The golden image build stops | Setup's hardware-check bypass in WinPE, or Secure Boot on with the signed iPXE shim |
| The storage server goes away (**tested**, phase 4) | Running clients pause; past 10 minutes, they go down | Since `golden-v6` they wait 10 minutes, so a restart is a pause. After longer, iPXE retries their disks, and they come back by themselves once it's back ([docs/clients.md](docs/clients.md#when-a-server-restarts)). Restarting only the iSCSI Target service with clients running doesn't work: it never stops |
| A write to a golden image | Every child built on it breaks | Read-only attribute and ACL. Versioned file names: a change works on a copy, under the next version |

## Open questions

1. **Windows' automatic maintenance on clients** (found in phase 4, partly addressed 2026-10-13): a new client's first maintenance, 10 minutes after it starts, grew its disk from 1.5 GB to 7.5–8 GB. Since `golden-v10`, with no defrag, last-access times or swap assessment, and the native images compiled in the image, it grows to about 2.8 GB. A disk I/O trace found that a child grows by whole 2 MB blocks, so small writes spread over the disk cost the most. The remaining 1.5 GB is such writes: single small ones into some 500 directories of Windows' apps and their assets, 4 to 9 minutes into maintenance, not caused by reading and not in NTFS's change journal. A trace of file operations by process is the next step ([docs/clients.md](docs/clients.md#automatic-maintenance)).
2. **Physical NIC models to support.** Each needs its driver in the driver pack and the NIC in the build ([NIC independence](#nic-independence)): passed through to the build VM, if the host can, or a physical build machine.

## Repo layout

```
PLAN.md          this plan
docs/            one doc per area as phases land: status, decisions, verified results
lab/             Proxmox setup, Terraform (bpg) for the servers, clients and build VM, the values in lab.auto.tfvars;
                 pve.sh, the Proxmox API for scripts
servers/         setup.sh, remote.sh (runs the scripts over SSH), settings.psd1 (the values), common.ps1
servers/dc/      promote to a new forest; DNS, DHCP scope and policies, WDS TFTP, IIS, boot files
servers/san/     join the domain; iSCSI Target Server and the data disk
boot/            boot.ipxe; the menus for non-clients, clients and the build; configure.ps1 fetches snponly.efi,
                 wimboot, Memtest86+
.env.example     the passwords the scripts read from .env (gitignored)
image/           build.sh, change.sh, remove.sh and nic-test.sh (from the PC); drivers.psd1, the NIC driver pack; dc/
                 and san/, their parts on the servers; winpe/, WinPE's startup and jobs; windows/, the answer files
                 and scripts
clients/         clients.csv; new-client.sh, update-clients.sh, remove-client.sh and check.sh (from the PC); dc/ and
                 san/, their parts on the servers, and the clients' Group Policy
```

## Sources

- [iSCSI target boot overview](https://learn.microsoft.com/en-us/windows-server/storage/iscsi/iscsi-boot-overview): 256 clients from one master image through differencing VHDs, iPXE as the loader, about 60 clients per 1 GbE
- [Diskless servers can boot from the Microsoft iSCSI Software Target](https://learn.microsoft.com/en-us/archive/blogs/storageserver/diskless-servers-can-boot-and-run-from-the-microsoft-iscsi-software-target-using-a-regular-network-card): the golden image must be installed onto iSCSI; clients hang if the target restarts
- [New-IscsiVirtualDisk](https://technet.microsoft.com/en-us/library/jj612821(v=wps.630)): `-ParentPath` for differencing disks
- [Features removed or no longer developed in Windows Server 2025](https://learn.microsoft.com/en-us/windows-server/get-started/removed-deprecated-features-windows-server-2025): iSCSI Target Server isn't listed
- [KB5129631](https://support.microsoft.com/help/5129631): WDS deprecated from the next Windows Server release
- [Specifying driver load order](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/specifying-driver-load-order): `BootFlags` and `CM_SERVICE_NETWORK_BOOT_LOAD`
- [Windows on iSCSI, part 2](https://www.cyberus-technology.de/post/windows-on-iscsi---part-2-3): the Windows 7 method for booting on other NICs, through the Critical Device Database
- [iPXE 16.1 shim signed](https://lists.ipxe.org/pipermail/ipxe-devel/2025-November/007651.html): Secure Boot with iPXE
