# Requirements

What each part needs, and why, so that you can set it up by hand or with other tools. [servers/dc/configure.ps1](../servers/dc/configure.ps1) and [servers/san/configure.ps1](../servers/san/configure.ps1) are working versions of everything here for the two servers. Values such as `<DcAddress>` are settings from [servers/settings.psd1](../servers/settings.psd1).

## Network

| Requirement | Why |
|---|---|
| One broadcast domain for the clients, the build machine and both servers | UEFI PXE finds its DHCP server by broadcast. A DHCP relay would also work, but isn't covered here |
| No DHCP server but the domain controller's | Another DHCP server, such as a router's, would answer clients without the boot options, and a client might take its offer |
| A gateway, if clients need the internet | Clients get it from DHCP. The image's build needs the internet too, for OpenSSH and, with `--updates`, Windows updates |
| Clients and the build machine reach the domain controller on DHCP (UDP 67), TFTP (UDP 69) and HTTP (TCP 80); and the storage server on iSCSI (TCP 3260) | The boot. The build machine also maps the domain controller's install share (SMB, TCP 445) from WinPE. Windows Server's role installs open their own firewall ports |
| The admin workstation reaches both servers, and the build machine during a change, on SSH (TCP 22) | The scripts. An intrusion prevention system in blocking mode on the way can take bursts of SSH connections for a scan: the scripts keep to one connection per step, but allow-list the workstation if it blocks them |

## Domain controller

Windows Server 2025, with OpenSSH Server accepting the admin's key for a local administrator, `admin`, if the scripts are to run on it. It becomes the first domain controller of a new forest ([promote.ps1](../servers/dc/promote.ps1)).

### Active Directory and DNS

- **A new forest,** or any domain the clients can join. The domain name should be a subdomain of a domain you own: not `.local`, a single label, or your public apex.
- **DNS for the domain,** which the clients use (DHCP option 6). Names outside the domain are forwarded to the gateway, or any resolver. A reverse zone for the network holds the clients' PTR records.
- **An OU and a GPO for the clients** ([clients.md](clients.md#group-policy)), made by the client scripts.
- **An account that can authorise a DHCP server** (Enterprise Admins) and provision computer accounts (`djoin /provision`).

### DHCP

| Setting | Value | Why |
|---|---|---|
| Authorised in Active Directory | | In a domain, a Windows DHCP server answers only once it's authorised |
| Scope | The network, with a range kept out of the dynamic pool for clients' reservations | Each client keeps its address. The scripts reach the build machine by its reserved address. In a /16, the range's `.255` is a host address too, so the exclusion has to include it |
| Reservations | One per client MAC, and one for the build machine | As above |
| Options | Router (3), DNS server (6) `<DcAddress>`, domain name (15). **No option 60** | With option 60 `PXEClient`, firmware asks a PXE server for its boot program instead of using option 67, and gets WDS's (`boot\x64\wdsmgfw.efi`) |
| Policy 1, `iPXE`: user class `iPXE` | Boot file (67) `http://<DcAddress>/boot/boot.ipxe` | iPXE's own request. iPXE sends the PXE vendor class too, so this policy comes first: for an option two matching policies both set, the first one's value wins |
| Policy 2, `UEFI x64 PXE`: vendor class beginning `PXEClient:Arch:00007` | TFTP server (66) `<DcAddress>`, boot file (67) `boot\x64\snponly.efi` | UEFI x64 firmware's request. Firmware sends `PXEClient:Arch:00007:UNDI:003016`, so the class matches by prefix |

```powershell
$scope = '<network address>'
Add-DhcpServerv4Class -Name 'PXEClient UEFI x64' -Type Vendor -Data 'PXEClient:Arch:00007'
Add-DhcpServerv4Class -Name 'iPXE' -Type User -Data 'iPXE'
Add-DhcpServerv4Policy -ScopeId $scope -Name 'iPXE' -Condition OR -UserClass EQ, 'iPXE' -ProcessingOrder 1
Set-DhcpServerv4OptionValue -ScopeId $scope -PolicyName 'iPXE' -OptionId 67 -Value 'http://<DcAddress>/boot/boot.ipxe'
# The trailing * matches the class's data as a prefix
Add-DhcpServerv4Policy -ScopeId $scope -Name 'UEFI x64 PXE' -Condition OR -VendorClass EQ, 'PXEClient UEFI x64*' -ProcessingOrder 2
Set-DhcpServerv4OptionValue -ScopeId $scope -PolicyName 'UEFI x64 PXE' -OptionId 66 -Value '<DcAddress>'
Set-DhcpServerv4OptionValue -ScopeId $scope -PolicyName 'UEFI x64 PXE' -OptionId 67 -Value 'boot\x64\snponly.efi'
```

- **Restart the DHCP server after changing an exclusion range.** Otherwise it goes on offering an address it had offered before the change, and refusing it (a NACK, which firmware shows as PXE-E07).
- **Another DHCP server works the same,** if it can hand out a boot file by vendor class and by user class.

### TFTP

The firmware fetches `snponly.efi` over TFTP. WDS's TFTP server is used here, with WDS's PXE side doing nothing; any TFTP server that serves the file would do.

| Setting | Why |
|---|---|
| WDS's PXE provider not critical: `IsCritical` 0 under `HKLM\SYSTEM\CurrentControlSet\Services\WDSServer\Providers\WDSPXE` | The PXE provider can't set itself up beside a DHCP server on the same machine (0x425). It's marked critical, so its failure stops the whole WDS server, TFTP too |
| Initialised standalone, with its root (`<TftpRoot>`) | WDS needs no Active Directory integration to serve TFTP |
| `/AnswerClients:None` and `/UseDhcpPorts:No` | DHCP hands out the boot file. WDS answers no one, and leaves UDP 67 to the DHCP server |
| `/DhcpOption60:No`, and option 60 removed from the DHCP server | WDS sets option 60 on the DHCP server otherwise ([above](#dhcp)) |
| Delayed start, and restarts after any failure | At boot, WDS starts before Active Directory on the same server answers. Its image server then can't reach a domain controller (0x4F1), and that stops the whole WDS server. Windows applies a service's recovery actions only to crashes, unless the failure flag is set |
| `snponly.efi` at `<TftpRoot>\Boot\x64\snponly.efi` | The path in DHCP option 67 is relative to the TFTP root |

```powershell
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WDSServer\Providers\WDSPXE' IsCritical 0
wdsutil /Initialize-Server /RemInst:C:\RemoteInstall /Standalone
wdsutil /Set-Server /AnswerClients:None
wdsutil /Set-Server /UseDhcpPorts:No
wdsutil /Set-Server /DhcpOption60:No
sc.exe config WDSServer start= delayed-auto
sc.exe failure WDSServer reset= 3600 actions= restart/60000/restart/120000/restart/300000
sc.exe failureflag WDSServer 1
```

With delayed start, TFTP is served about 2 minutes after the domain controller boots, while DHCP answers within seconds. A client that starts in between gets an address but no boot file ([operations.md](operations.md#the-domain-controller)).

### HTTP

IIS serves `<BootFiles>` as `http://<DcAddress>/boot/`, static files only.

- **MIME types,** as IIS serves only extensions it knows: `.ipxe` and `.cmd` as `text/plain`; `.efi`, `.wim`, `.sdi`, `.bcd` and `.` (files without an extension, such as `wimboot` and WinPE's `BCD`) as `application/octet-stream`.
- **Every file readable by IIS's anonymous user,** as iPXE and WinPE fetch them anonymously. A file moved into the folder keeps the permissions of where it came from, and iPXE gets HTTP 401 ("Permission denied"). Copy files in, or reset the folder's permissions (`icacls <BootFiles> /reset /t`) after writing them.

What's served:

| File | From | For |
|---|---|---|
| `boot.ipxe`, `menu.ipxe`, `client.ipxe`, `build.ipxe` | [boot/](../boot) | Every machine's first script, and the menus ([architecture.md](architecture.md#the-menus)) |
| `clients/{mac}.ipxe` | Written per client by the client scripts, and for the build machine by the build | Its name, initiator and disk, then a menu |
| `snponly.efi` | iPXE v2.0.0, `ipxeboot.tar.gz` | Also copied to the TFTP root |
| `wimboot` | wimboot v2.9.0 | Boots WinPE from HTTP |
| `memtest.efi` | Memtest86+ v8.10, `mt86plus_8.10.binaries.zip` | Memory tests from the menus |
| `winpe/boot.wim`, `winpe/BCD`, `winpe/boot.sdi` | Made by the build ([golden-image.md](golden-image.md#winpe)) | WinPE, for builds and recovery |
| `jobs/{mac}.cmd` | Written by a build | WinPE's job on the build machine, only while a build runs |

The downloads are pinned to SHA-256 hashes in [configure.ps1](../servers/dc/configure.ps1).

### For building images

The domain controller also holds what a build needs ([golden-image.md](golden-image.md#how-an-image-is-built)): the Windows ADK and its WinPE add-on, to make WinPE; the Windows 11 media, from an ISO in its CD drive; and the install share, `\\<DcAddress>\install`, which WinPE maps with a domain account used for nothing else.

### Windows Update

Updates download automatically, but install, and restart the server, only when an admin says so (`AUOptions` 7 under `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU`). Left to itself, Windows Update restarts servers at night, and a domain controller restart stops clients starting.

## Storage server

Windows Server 2025, with OpenSSH Server as for the domain controller. A domain member, though iSCSI itself doesn't use the domain.

| Requirement | Why |
|---|---|
| iSCSI Target Server (`FS-iSCSITarget-Server`) | Serves the disks. Differencing VHDX parents and children are both iSCSI virtual disks |
| A data disk, NTFS, with `iSCSI\images` and `iSCSI\clients` | Golden images (about 12 GB each), and the clients' disks ([clients.md](clients.md#disk-growth)) |
| A startup task that restarts the iSCSI Target service until it listens on `<SanAddress>:3260` | The service can start before the static address is usable, fail to bind to it (event 10, error 10049), and then listen nowhere though it's running. It can't be made to start later: Windows refuses delayed start for it (error 87), as it's in a load order group |
| Windows Update installs and restarts only when an admin says so, as on the domain controller | Every running client pauses while the storage server restarts, and crashes if it's away for longer than it waits ([operations.md](operations.md#the-storage-server)) |
| Enough network for the clients | Microsoft's guide is about 60 clients per 1 GbE |

The startup task, as [configure.ps1](../servers/san/configure.ps1) registers it: a minute after boot, as SYSTEM, up to 10 tries 30 seconds apart:

```powershell
if (-not (Get-NetTCPConnection -LocalAddress <SanAddress> -LocalPort 3260 -State Listen -ErrorAction SilentlyContinue)) {
  Restart-Service WinTarget
}
```

**Don't restart the iSCSI Target service while clients are running.** With sessions open it doesn't stop: it stays "Stop Pending", taking connections and answering none, until its process is ended, and its clients crash. A restart of the whole server stops it in seconds ([operations.md](operations.md#the-storage-server)).

## Client machines

| Requirement | Why |
|---|---|
| UEFI x64 firmware, with network boot first in the boot order | The DHCP policy hands out an x64 UEFI binary. The client has no disk to boot otherwise |
| Secure Boot off | The stock `snponly.efi` is unsigned |
| A NIC that the firmware can network-boot from, and whose driver is in the image's driver pack | iPXE uses the firmware's NIC driver; Windows needs its own, as a boot driver ([golden-image.md](golden-image.md#booting-from-any-nic)) |
| On the clients' network, as its native (untagged) network | Firmware PXE sends untagged frames |
| Its MAC, name and address in [clients/clients.csv](../clients/clients.csv) | Its reservation, computer name and boot script are made from it. A name is a computer name: up to 15 letters, digits and hyphens |
| VMs on OVMF (EDK2, as on Proxmox and QEMU): a virtual random number generator, such as virtio-rng | OVMF's network stack needs the entropy, and without an RNG device recent OVMF offers no network boot at all: no PXE option, no DHCP request, and "No bootable option or device was found". Physical machines have a hardware RNG |

Nothing is configured on the machine itself, apart from its firmware settings. Windows' power and NIC settings come from Group Policy ([clients.md](clients.md#group-policy)).

## Build machine

A diskless machine like a client, which the image scripts boot to build and change images.

| Requirement | Why |
|---|---|
| One NIC, Intel, whose driver is in the driver pack (QEMU's e1000e in a VM) | Windows setup makes the NIC it installs through a boot NIC of the new Windows, and fails to for virtio's NetKVM ("a required driver could not be installed"). The seal makes the pack's other NIC drivers boot drivers, so one NIC is enough ([golden-image.md](golden-image.md#booting-from-any-nic)) |
| Windows 11's hardware requirements: UEFI, TPM 2.0, 4 GB of memory, two cores. Secure Boot can be off | Setup runs on it, and checks. WinPE's build job also sets setup's `BypassSecureBootCheck`, in case setup checks Secure Boot |
| A DHCP reservation | The workstation reaches it over SSH while an image is being changed |
| Started and stopped by the scripts | The scripts here do it through the Proxmox API ([scripts.md](scripts.md#hypervisor-specific-parts)) |

Clients with the build machine's NIC model at its PCI slot need no work on their first boot: the image has that NIC already ([clients.md](clients.md#the-first-boot)).

## Admin workstation

- **Bash,** in WSL or Git Bash, with `ssh`, `tar`, `awk` and `sed`. The scripts that drive VMs (`image/build.sh`, `change.sh`, `nic-test.sh`, `clients/check.sh`) also need `curl`, `python3` and `iconv`, and a Proxmox API token ([lab.md](lab.md#proxmox-access)).
- **An SSH key that both servers accept** for `admin` (and for the domain's `Administrator` on the domain controller), in `C:\ProgramData\ssh\administrators_authorized_keys`. Builds copy the domain controller's copy of that file into the image, so the same key reaches the build machine during a change.
- **The passwords,** in `.env` ([.env.example](../.env.example)).

## Sources

- Microsoft, [iSCSI target boot overview](https://learn.microsoft.com/en-us/windows-server/storage/iscsi/iscsi-boot-overview): about 60 clients per 1 GbE.
- Microsoft, [iSCSI Target Server scalability limits](https://learn.microsoft.com/en-us/windows-server/storage/iscsi/iscsi-target-server-limits): 256 differencing disks per parent, and diskless boot with iPXE.
- Microsoft, [Add-DhcpServerv4Policy](https://learn.microsoft.com/en-us/powershell/module/dhcpserver/add-dhcpserverv4policy?view=windowsserver2025-ps): vendor and user class conditions, and policies processed in order.
- Microsoft, [wdsutil set-server](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/wdsutil-set-server): `/AnswerClients`, `/UseDhcpPorts` and `/DhcpOption60`.
- Microsoft, [KB5129631](https://support.microsoft.com/help/5129631): WDS deprecated in the next Windows Server release.
- Proxmox developers' list, [OVMF without an RNG](https://lists.proxmox.com/pipermail/pve-devel/2025-September/075129.html): "the OVMF firmware disables PXE boot for guests without a random number generator".
