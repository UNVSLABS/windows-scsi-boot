# Servers

Phase 1 of the [plan](../PLAN.md): the domain controller hands out addresses and the boot files, and the storage server runs iSCSI Target Server. A client network-boots to the iPXE menu, which can start Memtest86+. Sources are in [servers/](../servers) and [boot/](../boot). The environment's values are in [servers/settings.psd1](../servers/settings.psd1); change them for yours.

## What it sets up

| | vm-dl-dc-1 (10.31.0.10) | vm-dl-san-1 (10.31.0.20) |
|---|---|---|
| Domain | First domain controller of the new forest `diskless.adl.unvslab.com` (NetBIOS name `DISKLESS`), at the Windows Server 2025 functional level | Member |
| DNS | Runs it for the domain, plus the reverse zone `31.10.in-addr.arpa`. Forwards everything else to the gateway, 10.31.0.1 | Asks the domain controller |
| DHCP | One scope with the network-boot policies ([below](#dhcp)) | — |
| TFTP | WDS's TFTP server, serving `boot\x64\snponly.efi` from `C:\RemoteInstall`. WDS's PXE side answers no one ([below](#tftp-through-wds)) | — |
| HTTP | IIS: `C:\BootFiles` as `http://10.31.0.10/boot/`, static files only | — |
| iSCSI | — | iSCSI Target Server. The 200 GB data disk is `D:` (label `iSCSI`), with `D:\iSCSI\images` for golden images and `D:\iSCSI\clients` for child disks |
| Windows Update | Downloads updates; installs them, and restarts, only when an admin says so | The same |

`DISKLESS\admin` is a Domain Admin and Enterprise Admin. Its password, and the domain Administrator's, is the template's admin password.

### DHCP

| Setting | Value |
|---|---|
| Scope | 10.31.1.1–10.31.2.254, mask 255.255.0.0 |
| Exclusion | 10.31.1.1–10.31.1.255, for clients' reservations (phase 3). Other machines lease from 10.31.2.0 |
| Options | Router 10.31.0.1, DNS 10.31.0.10, domain name `diskless.adl.unvslab.com`. No option 60 |
| Policy 1 `iPXE` | User class `iPXE`. Boot file (67) `http://10.31.0.10/boot/boot.ipxe` |
| Policy 2 `UEFI x64 PXE` | Vendor class beginning `PXEClient:Arch:00007`. TFTP server (66) 10.31.0.10, boot file (67) `boot\x64\snponly.efi` |

iPXE sends the UEFI vendor class too, so its policy comes first. For an option two matching policies both set, the first one's value wins.

### TFTP through WDS

WDS is installed for its TFTP server only:
- **WDS's PXE provider can't set itself up beside a DHCP server** on the same machine (0x425), and it's marked critical, so its failure would stop the whole WDS server. [configure.ps1](../servers/dc/configure.ps1) sets `IsCritical` to 0 under `HKLM\SYSTEM\CurrentControlSet\Services\WDSServer\Providers\WDSPXE`.
- **WDS answers no clients,** and leaves UDP 67 to the DHCP server.
- **WDS doesn't set DHCP option 60** (`/DhcpOption60:No`). With option 60 `PXEClient`, firmware asks WDS's responder for its boot program, `boot\x64\wdsmgfw.efi`, instead of using option 67.

WDS is deprecated from the next Windows Server release, but supported on 2025 for its lifecycle. Any TFTP server that serves `C:\RemoteInstall` would do.

### Boot files

| File | From | Used for |
|---|---|---|
| `snponly.efi` | iPXE v2.0.0, `ipxeboot.tar.gz` | The firmware loads it over TFTP. It drives the NIC through the firmware's own UEFI driver |
| `boot.ipxe` | [boot/boot.ipxe](../boot/boot.ipxe) | iPXE fetches it first. It chains `clients/<mac>.ipxe`, or `menu.ipxe` for machines that aren't clients |
| `menu.ipxe` | [boot/menu.ipxe](../boot/menu.ipxe) | WinPE (`p`, phase 2), Memtest86+ (`m`), an iPXE shell (`s`), or the next boot device (`x`, the default after 30 s) |
| `client.ipxe`, `build.ipxe` | [boot/](../boot) | A client's menu, and the build VM's boot during a build ([image](image.md)). A machine's own `clients/<mac>.ipxe` sets its disk and chains one of them |
| `memtest.efi` | Memtest86+ v8.10, `mt86plus_8.10.binaries.zip` | An x86-64 EFI application, chained by iPXE |
| `wimboot` | wimboot v2.9.0 | Boots WinPE (phase 2) |

- **Pinned downloads:** they're checked against SHA-256 hashes pinned in [configure.ps1](../servers/dc/configure.ps1). To take a new release, change its entry and delete the file from `C:\BootFiles`.
- **Permissions:** every file must be readable by IIS's anonymous user, or iPXE gets HTTP 401 ("Permission denied"). So the downloads are copied into the folder rather than moved, its permissions are reset on each run, and the final check fetches every file anonymously.

## How setup.sh runs the scripts

- **One SSH connection per step.** It copies `servers/`, `boot/`, `image/` and `clients/` to `C:\Windows\Temp\diskless` through Windows' `tar`, then runs the script, in the same connection. The password a step needs goes along as `servers\secret.txt`, which the script reads and deletes first. The image and client scripts share this ([servers/remote.sh](../servers/remote.sh)).
- **Restarts.** A script that needs one restarts Windows and prints `restarting: <why>` and its boot time. `setup.sh` waits for the boot time to change, then runs the script again; each one skips what's done. The causes:
  - updates the template's clones install by themselves;
  - the promotion;
  - the domain join.
- **Windows servicing first.** Before changing anything, a script waits until servicing (`TiWorker`) is idle. After a restart, servicing can go on installing updates and then restart Windows by itself. A role install that meets a shutdown already under way (0x8007045b) counts as a restart too.
- **Few connections.** It polls a restart once a minute, with SSH keepalives, so an IPS in blocking mode doesn't take it for a scan.

## What each piece is for

Each of these was a failure on the way, on 2026-10-10:

| Problem | Fix |
|---|---|
| Promotion refused: "this computer needs to be restarted". The template is built without updates and turns Windows Update back on, so a new clone installs them by itself | Scripts restart when a restart is pending, and `setup.sh` runs them again |
| Windows servicing restarted the domain controller by itself while a role was installing, after one of our restarts | `Wait-ServicingIdle` before changing anything. A shutdown already under way counts as a restart |
| `setup.sh` waited forever: an SSH session to a server that restarted under it never ended | SSH keepalives, and a hard timeout on the boot-time check |
| SSH to the network was blocked, then reset mid-transfer. The gateway's IPS took the setup's bursts of SSH connections for a scan | One connection per step, a poll a minute, and an allow-list entry in the IPS |
| WDS's server stopped as it started (0x41D): its PXE provider couldn't set itself up beside the DHCP server, and is marked critical | `IsCritical` 0 for WDSPXE, so the server runs with TFTP alone |
| The client asked TFTP for `boot\x64\wdsmgfw.efi`: WDS had set server-wide DHCP option 60 | `wdsutil /Set-Server /DhcpOption60:No`, and option 60 removed |
| A client leased 10.31.1.255: in a /16 that's a host address, and the exclusion ended at .254. After the fix, the DHCP server went on offering it and refusing it (NACK, PXE-E07) | The exclusion ends at .255, and the DHCP server restarts after an exclusion change |
| The client's firmware had no network boot option at all | A VirtIO RNG on clients ([environment](environment.md#what-it-creates)) |
| Windows Update restarted the storage server twice one night by itself, and every client booted from it would hang meanwhile (found 2026-10-11) | Both servers download updates, but install them and restart only when an admin says so (`AUOptions` 7) |
| After that restart, the iSCSI target listened on nothing: its service had started before the static address was usable, and failed to bind (event 10, error 10049) | A startup task restarts it, a minute after each boot, until it listens on the server's address; `configure.ps1` does the same. Starting it later isn't possible: Windows refuses delayed start for it (error 87), as it's in a load order group, and the earlier `sc.exe` call to set it failed unnoticed. It happened again after a host restart on 2026-10-12, before the task |
| After the same host restart, clients got no boot file over TFTP (PXE-E18): WDS had stopped 14 seconds into the domain controller's boot. Its image server couldn't reach a domain controller (0x4F1), as Active Directory on the same server wasn't answering yet, and that stops the whole WDS server. Its restart-on-failure actions never ran: Windows applies them only to crashes (found 2026-10-12) | WDS starts delayed, a couple of minutes after boot, and restarts after any failure (`sc.exe failureflag WDSServer 1`). `configure.ps1`'s check fails if nothing listens on UDP 69. Both servers restarted together afterwards: TFTP and iSCSI listened again within 2 minutes, with no help (the target bound by itself that time, and its task found it listening) |
| iPXE: `memtest.efi... Permission denied` (HTTP 401) | Downloads copied, not moved, into `C:\BootFiles`, and its permissions reset |

## Setting it up

After [the environment](environment.md), from this repo on the PC, in Git Bash or WSL. Each step is safe to re-run.

1. **Passwords:** copy [.env.example](../.env.example) to `.env`.
   - `ADMIN_PASSWORD` is the template's (`WINDOWS_IMAGE_PASSWORD` in the lab repo's `.env`).
   - `DSRM_PASSWORD` is 16+ letters and digits, with upper and lower case.
2. **Domain controller:** `servers/setup.sh dc`. It runs [promote.ps1](../servers/dc/promote.ps1) as `admin` until the server is a domain controller, then [configure.ps1](../servers/dc/configure.ps1) as the domain's `Administrator`, which can authorise the DHCP server.
3. **Storage server:** `servers/setup.sh san`. It runs [join.ps1](../servers/san/join.ps1), then [configure.ps1](../servers/san/configure.ps1).
4. **Check:** start a client and watch its console. It should reach the menu, and `m` starts Memtest86+.

## Verified

A clean run on srv-pve-1, 2026-10-10: `terraform destroy` and `apply`, then `setup.sh dc` and `setup.sh san` with no manual steps. 58 minutes in all.

| Step | Time | Result |
|---|---|---|
| Terraform | 10 min | Five VMs, both servers bootstrapped |
| `setup.sh dc` | 23 min | Promoted to `diskless.adl.unvslab.com` (one restart). Configured DNS, DHCP, WDS TFTP, IIS and the boot files. Its check fetched every boot file anonymously over HTTP |
| `setup.sh san` | 25 min | Joined the domain (one restart). iSCSI Target Server installed and its service running. `D:` is 200 GB NTFS |
| Client | 24 s to the menu | dl-ws-1 powered on: UEFI PXE took a 10.31.2.x lease and `snponly.efi` over TFTP. iPXE fetched `boot.ipxe` and then `menu.ipxe` over HTTP, as dl-ws-1 isn't a client. `m` started Memtest86+ v8.10 |

Earlier runs, on servers left half-configured by the failures above, found every fix in [What each piece is for](#what-each-piece-is-for). Updates the clones installed by themselves cost the domain controller three to four restarts in those runs, and none in the clean one, which promoted before Windows Update started.
