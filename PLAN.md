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
| 2 | Golden image, and the NIC-independence test | **In progress:** `golden-v1` is built on iSCSI, 2026-10-11. In the NIC test, it boots a new machine with the build's NIC model, but not yet other models ([docs/image.md](docs/image.md#results-2026-10-11-on-golden-v1-built-on-an-e1000e)) |
| 3 | Clients on differencing disks, joined to the domain | Not started |
| 4 | Image updates and failure behaviour | Not started |

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
```

- **iPXE is the stock `snponly.efi`.** It drives the NIC through the firmware's own UEFI driver, so any NIC that can network-boot works before Windows starts. Nothing has to be compiled.
- **DHCP policies on the domain controller choose what to hand out:** a UEFI x64 PXE request gets `snponly.efi` over TFTP, and a request from iPXE gets `boot.ipxe` over HTTP.
- **Each client's boot script is a static file** (`boot/<mac>.ipxe`), written by `New-Client.ps1`. No custom web service is needed.
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
| vm-dl-san-1 | Full clone of 9021 | 4 vCPU, 8 GiB, 64 GB OS disk + 200 GB thin data disk | 10.31.0.20, MAC `02:00:0A:1F:00:14` |
| dl-ws-1 to dl-ws-3 | Empty: UEFI without Secure Boot keys, TPM 2.0, a VirtIO RNG, no disk, boots from the network. NICs virtio, e1000e and vmxnet3 | 2 vCPU, 4 GiB each | DHCP reservation per fixed MAC |
| dl-build-1 | Empty, like the clients, with an Intel e1000e NIC. Builds golden images | 4 vCPU, 4 GiB | DHCP reservation, 10.31.1.250 |

- **Fixed MACs** are `02:00` followed by the IPv4 address in hex.
- **Full clones, not linked,** because the servers are long-lived and shouldn't depend on the template.
- **Configuration:** Terraform (bpg provider) creates the VMs. PowerShell over SSH as `admin` configures the servers.
- **Bootstrap:** the network has no DHCP until the domain controller provides it. So Terraform sets each new server's static address and computer name through the QEMU guest agent ([docs/environment.md](docs/environment.md)).

### Physical workstations

A physical workstation becomes a client by:
1. connecting to VLAN 31, e.g. a switch port with VLAN 31 as its native network;
2. setting its firmware to UEFI network boot with Secure Boot off;
3. adding its MAC to `clients.csv`.

Its NIC driver must be in the golden image ([NIC independence](#nic-independence)).

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
  - The client's first boot finishes Windows setup into the child, on its own hardware.
- **Children persist until the next image update.** An update recreates every child from the new golden image, so anything stored on a client is wiped then.
- **Windows Update is off on clients,** through Group Policy. Updates arrive in new golden images, which keeps children small.

| Storage (estimates, to be measured in phase 3) | Size |
|---|---|
| Golden image, per version | about 15–20 GB. Current and previous version kept |
| Child, after first boot | about 2 GB |
| Child, grows by | the client's writes until the next image update, plus its pagefile. The pagefile gets a fixed size through Group Policy |

Microsoft's own example: one 40 GB base image plus 2 GB per client is 552 GB for 256 machines, instead of about 10 TB of full copies.

## Client lifecycle

All driven by `clients/clients.csv` (name, MAC, IP). The scripts run on vm-dl-san-1 as a domain admin, and use PowerShell remoting for the domain controller's part.

**`New-Client.ps1 <name>`:**
1. **On the domain controller:**
   - adds a DHCP reservation for the MAC;
   - pre-creates the computer account and an offline domain-join file (`djoin /provision /reuse`);
   - writes `boot/<mac>.ipxe`.
2. **On the storage server:**
   - creates `clients\<name>.vhdx` with the current golden image as parent;
   - mounts it, writes an answer file into it with the computer name and the domain-join data, and unmounts it;
   - creates target `<name>` restricted to the client's IQN, and assigns the disk to it.
3. **The client's first boot** finishes Windows setup and joins the domain, with no prompts.

**`Update-Clients.ps1 <version>`:** run while the clients are off.
- For each client: deletes its child disk and repeats step 2 against the new golden image. `/reuse` keeps the same computer account.
- It refuses any client whose target still has an active session.
- An old golden image is deleted once no child uses it.

**`Remove-Client.ps1 <name>`:** reverses `New-Client.ps1`.

**Changing the image:**
1. Copy the current golden image to `golden-v(N+1).vhdx`.
2. Assign it to the build target and boot a maintenance VM from it.
3. Make the changes, run sysprep, and set it read-only.
4. Run `Update-Clients.ps1`.

The domain-join files hold machine passwords. They're made when needed and deleted after use, and never stored in the repo.

## NIC independence

**Goal:** one golden image, built in a VM, boots any client whose NIC driver it contains.

**Why it's hard:**
- Windows booted from iSCSI must load the boot NIC's driver at the very start of boot.
- Microsoft says an image installed on a local disk can't boot from iSCSI at all, because drivers load in a different order. That's why the golden image is installed onto an iSCSI LUN.
- The documented way to boot on other NICs is from the Windows 7 era. It edited a registry list (the Critical Device Database) that Windows 8 and later no longer have.

**Found in phase 2** ([docs/image.md](docs/image.md#nic-independence)):
- **The NIC's driver must declare `BootFlags` 0x1 in its INF** for the installed Windows to boot from iSCSI through it: the driver starts on demand, and the flag loads it at boot when booting from the network. Intel's drivers do. virtio's NetKVM and vmxnet3's don't. So the master is built on an Intel NIC. WinPE doesn't need the flag: it connects the disk once plug and play has loaded the driver.
- **Every machine's NIC is a new device to the image,** even with the same model. Most NICs, QEMU's e1000e and vmxnet3 included, carry a serial number made from the MAC, and Windows builds the device's ID from it. Only virtio-net doesn't.
- **Windows has a driver's service only once it has installed a device for it.** So setting `BootFlags` can't help a NIC the image has never installed. Windows setup makes its boot NIC by registering its driver as boot-critical in the image, which creates the service, and then with an undocumented `dism /Add-NetAdapter`. Only the second can be run by hand: the first is an undocumented function in `drvstore.dll`.
- **A new machine with the build's NIC model boots the image unchanged.** virtio and vmxnet3 don't, even after `/Add-NetAdapter` and a copied service ([results](docs/image.md#results-2026-10-11-on-golden-v1-built-on-an-e1000e)).

**What to test:**
1. **Include drivers for every NIC we target:** Windows' built-in ones, virtio, and vendor packs for physical NICs.
2. **Build the master on an Intel NIC, then boot it on each NIC model,** with a new MAC each time:

| Client NIC | Driver | What it shows |
|---|---|---|
| Intel e1000e | the build's | The build's NIC model on a new machine, as a physical fleet of one model |
| virtio | `netkvm`, added | A different NIC, whose driver doesn't declare network boot |
| VMware vmxnet3 | added, newer than the one built in | A different NIC, with a driver we added, as for a physical NIC |

- **Variants:**
  1. as setup leaves it;
  2. with `BootFlags` 0x1 on the NIC services;
  3. also with the start type set to boot-start;
  4. after WinPE on the client runs `dism /Add-NetAdapter` on its disk.

  Record which variant works.
- **Fallback:** build the golden image on a physical workstation with the same scripts. Each NIC family then needs its own image.

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
   - A blank VHDX on the build target. The build VM boots WinPE through wimboot, with the target attached by `sanhook`.
   - WinPE runs setup unattended from the install share onto the iSCSI disk.
   - It reuses the answer files and scripts from the lab repo's `images/windows/`, adapted for the iSCSI disk: `autounattend.xml`, `firstlogon.ps1`, `generalize.ps1` and `sysprep.xml`. `SetupComplete.cmd` isn't needed: Windows Update stays off in the image.
   - Sysprep, then set `golden-v1` read-only. Then the [NIC test](#nic-independence).
   - *Done when:* `golden-v1` boots clients over iSCSI, and the NIC result is recorded.
3. **Clients**
   - `New-Client.ps1` and `Remove-Client.ps1`.
   - Group Policy: Windows Update off, no hibernation or fast startup, NIC power saving off, fixed pagefile size.
   - *Done when:*
     - three clients boot together from one golden image;
     - each has its own name and SID, is joined to the domain and logs in as a domain user;
     - child disk sizes are measured against the estimates.
4. **Lifecycle**
   - `Update-Clients.ps1` from v1 to v2.
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
| Build NIC | Intel (an e1000e in the lab), not virtio | Windows uses a NIC for iSCSI only if its driver declares network boot (`BootFlags`). NetKVM's doesn't; Intel's does |
| Server updates | Downloaded automatically, installed and restarted by an admin | Clients hang while the storage server restarts, so restarts must be planned |

## Risks

| Risk | Effect | What we do |
|---|---|---|
| One image may not boot on different NICs | Images built in VMs can't serve physical workstations directly | Tested early in phase 2. Fallback: build the image on a physical workstation |
| Windows 11 booting from iSCSI isn't officially supported; Microsoft's docs cover Windows Server | No vendor support | Widely used with iPXE. Setup onto iSCSI is checked first in phase 2 |
| WinPE doesn't connect the iSCSI disk in the iBFT (**happened**, phase 2) | Setup can't install onto iSCSI, so there's no golden image | Solved: Windows routed iSCSI through the iBFT's gateway, which iPXE now leaves out ([docs/image.md](docs/image.md#booting-from-iscsi)) |
| Windows 11 setup may refuse to install with Secure Boot off | The golden image build stops | Setup's hardware-check bypass in WinPE, or Secure Boot on with the signed iPXE shim |
| The storage server goes away | Every running client hangs | Behaviour and recovery written down in phase 4 |
| A write to a golden image | Every child built on it breaks | Read-only attribute and ACL. Versioned file names. Only `Update-Clients.ps1` touches parents |

## Open questions

1. **Physical NIC models to support.** Their drivers go in the driver pack, and into the phase 2 test where possible.

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
image/           build.sh and nic-test.sh (from the PC); drivers.psd1, the NIC driver pack; dc/ and san/, their
                 parts on the servers; winpe/, WinPE's startup and jobs; windows/, the answer files and scripts
clients/         clients.csv, New-Client.ps1, Update-Clients.ps1, Remove-Client.ps1
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
