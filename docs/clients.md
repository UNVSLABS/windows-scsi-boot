# Clients

Phase 3 of the [plan](../PLAN.md): a client is a machine with no disk that boots from its own differencing disk on the golden image, joined to the domain. `clients/new-client.sh` makes one from its row in [clients/clients.csv](../clients/clients.csv); it then only has to be switched on. Sources are in [clients/](../clients); the first boot is part of the golden image ([image/](../image)). The environment's values are in [servers/settings.psd1](../servers/settings.psd1) and `clients.csv`; change them for yours.

## Status

| Step | State |
|---|---|
| `new-client.sh`, `remove-client.sh`, `check.sh` | **Done 2026-10-12** |
| The first boot from the disk: the golden image's WinPE makes the client's NIC a boot NIC | **Done 2026-10-12**, in the image since `golden-v5` |
| Group Policy: Windows Update off, no sleep, hibernation or fast startup, NIC power saving off, a fixed pagefile | **Done 2026-10-12** |
| Three clients boot together from one golden image, joined to the domain; a domain user logs on; child disk sizes | **Done 2026-10-12** ([results](#results)) |

## What a client is

| | |
|---|---|
| Disk | `clients\<name>.vhdx` on the storage server: a differencing disk on the newest golden image, on target `<name>`, which accepts only the client's initiator, `<IqnPrefix>:<name>` |
| Boot | `boot/clients/<mac>.ipxe` on the domain controller: its name, initiator and disk, then the clients' menu ([boot/client.ipxe](../boot/client.ipxe)), which boots Windows from the disk |
| Address | A DHCP reservation, from `clients.csv`. The servers' scope keeps 10.31.1.x for reservations ([servers](servers.md#dhcp)) |
| Identity | Its computer name and an offline domain join, written into its disk before its first boot. Sysprep gives it its own SID |
| Domain | A computer account in the OU `Diskless clients`, made by `djoin /provision`, and the GPO `Diskless clients` linked there ([below](#group-policy)) |
| Lifetime | Until its disk is made again (an image update, phase 4) or `remove-client.sh`. `/reuse` keeps its computer account when its disk is made again |

## How New-Client works

```
clients/new-client.sh <name>                                                         PC, WSL or Git Bash
 1 vm-dl-dc-1    the clients' OU and GPO, if they're missing (clients/dc/policy.ps1); a DHCP reservation;
                 the computer account and its offline domain join: djoin /provision /reuse /printblob
 2 vm-dl-san-1   clients\<name>.vhdx on the newest golden-vN; into its Windows\Panther\unattend.xml, which sysprep
                 left there: the computer name, and the join (Microsoft-Windows-UnattendedJoin, AccountData); a
                 SetupComplete.cmd that deletes that answer file after setup; target <name> for the client's IQN
 3 vm-dl-dc-1    boot/clients/<mac>.ipxe
then, switched on:
 4 client        PXE ─▶ snponly.efi ─▶ clients/<mac>.ipxe ─▶ client.ipxe: sanboot the disk
                 Windows Boot Manager: the first-boot WinPE, its default ─▶ the NIC's interface ─▶ default Windows,
                 restart ─▶ sanboot again ─▶ Windows: specialize joins the domain ─▶ the logon screen
```

- **The join's data** holds the computer account's machine password. The domain controller prints it, `new-client.sh` passes it straight to the storage server (as `servers/secret.txt`, deleted once read), and it's written only into the client's disk. Windows runs `SetupComplete.cmd` once setup is done, which deletes the answer file it was in.
- **The answer file** is the one sysprep left in the image, `Windows\Panther\unattend.xml`, which a client's first boot uses for its specialize and oobeSystem passes. New-Client changes only its copy in the child disk: `ComputerName` from `*` (random) to the client's name, and the domain join in the specialize pass. It needs no image password.
- **From the PC, one SSH connection per step,** as the servers' setup does ([servers/remote.sh](../servers/remote.sh)). A script on the storage server can't reach the domain controller as the admin: an SSH logon with a key carries no credentials for a second hop.
- **A client with a disk already** is refused: `remove-client.sh` first. A failed New-Client can be run again once removed.

## The first boot

A client's NIC needs its network interface in the disk's Windows before Windows can boot from it, unless the image has that NIC already: the build NIC's model at the build NIC's PCI slot ([image](image.md#nic-independence)). `dism /Add-NetAdapter` makes it, from the live NIC, so it runs on the client, in WinPE, before Windows' first boot.

**The golden image does it itself.** Its build puts a WinPE into it, with a boot entry that starts it as Windows Boot Manager's default ([image/windows/firstboot-entry.ps1](../image/windows/firstboot-entry.ps1)). So the first time any machine boots a new disk on the image:
1. Windows Boot Manager on the disk loads that WinPE into memory, from `Windows\Setup\Diskless\firstboot.wim` on the disk.
2. WinPE connects the disk from the iBFT, as WinPE booted by iPXE does, and its startup ([image/winpe/startnet-firstboot.cmd](../image/winpe/startnet-firstboot.cmd)) runs [image/winpe/firstboot.ps1](../image/winpe/firstboot.ps1) from the disk:
   - it finds the NIC, the connected physical one;
   - it checks that the image has the NIC's driver service, which setup made for each NIC family of the build. Without it, it stops: the image can't boot this NIC;
   - if the image doesn't have the NIC itself, as a device in its `SYSTEM` hive, it runs `dism /Add-NetAdapter` for it;
   - it sets the boot manager's default back to Windows, takes its own entry out of the boot manager's list, and restarts.
3. Windows boots, finishes setup, and joins the domain.

Log: `Windows\Temp\firstboot.log` on the disk. On a failure, WinPE stops with the error on screen, and its entry stays the default, so the next start tries again.

**Why from the disk:** nothing outside the client has to change between its two boots. A client's iPXE script is a static file, and WinPE has no way to change it. So a client is ready as soon as New-Client is done, VM or physical, and an image update, which gives every client a new disk, needs nothing per machine.

| | |
|---|---|
| WinPE | The network WinPE ([image](image.md#how-a-build-works)), with its own startup: `winpe/firstboot.wim` on the domain controller, 471 MB. Stored once, in the golden image |
| Its boot entry | `{bd965c03-fdb1-459d-9aa1-04822bba2c6b}`, a RAM disk entry: `ramdisk=[C:]\Windows\Setup\Diskless\firstboot.wim`, with `boot.sdi` beside it. First in the boot manager's list, and its default, with a timeout of 0 |
| Time | About 3 minutes more on a first boot: a client is set up and joined 6–7 minutes after it's switched on |
| Made by | `generalize.ps1`, once sysprep has generalised the image; `seal.ps1` checks that it's there |

**To run it again,** for example after a client's NIC is replaced: in Windows on the client, before the change, `bcdedit /displayorder {bd965c03-fdb1-459d-9aa1-04822bba2c6b} /addfirst` and `bcdedit /default {bd965c03-fdb1-459d-9aa1-04822bba2c6b}`. Or make its disk again.

## Group Policy

The GPO `Diskless clients`, linked to the OU `Diskless clients`, which New-Client puts computer accounts in ([clients/dc/policy.ps1](../clients/dc/policy.ps1)):

| Setting | How | Why |
|---|---|---|
| Windows Update off | Policy: Configure Automatic Updates, Disabled | Updates come in new golden images. Updating each child would grow every child disk by the same updates |
| No sleep | Policies: sleep timeout 0 and standby states (S1–S3) off, plugged in and on battery | The disk is on the network |
| No hibernation | Policy: hibernate timeout 0. Preference: `HibernateEnabled` 0 | Hibernation writes memory to the disk, and resumes from it |
| No fast startup | Preference: `HiberbootEnabled` 0 | Fast startup is a hibernation |
| A fixed pagefile | Preference: `PagingFiles` `C:\pagefile.sys 2048 2048`, from `PagefileMB` in `settings.psd1` | The pagefile is on the child disk, and every page written grows it. Fixed, it can't grow unseen. From the boot after the policy first applies |
| NIC power saving off | Startup script ([clients/dc/nic-power.ps1](../clients/dc/nic-power.ps1)): `PnPCapabilities` 24 in each physical NIC's driver key | It's a setting of each NIC's device, so no policy has it. Written to the registry, it takes effect from the next boot: changing it through the NIC would restart the NIC, and with it the iSCSI connection the client runs from |

- **Policies and preferences.** The update and power settings are policies; the rest have no policy, so they're Group Policy preferences, which write the registry.
- **Only what differs is set.** Each change is a new version of the GPO, which every client applies again.
- **The startup script** goes into the GPO's folder in SYSVOL with a `scripts.ini`, and the GPO lists the scripts extension. Group Policy runs startup scripts under the execution policy, which allows none by default, so a `.cmd` starts PowerShell with `-ExecutionPolicy Bypass`.

## Removing a client

`clients/remove-client.sh <name>` reverses New-Client: on the storage server, the target and the disk, refused while the client's target has a session; then on the domain controller, the boot script, the reservation, the DNS records and the computer account. The client then gets the menu for machines that aren't clients. Its row in `clients.csv` stays.

## What each piece is for

Each of these was a failure on the way, on 2026-10-12:

| Problem | Fix |
|---|---|
| The first-boot WinPE never started: Windows booted instead, and stopped with INACCESSIBLE_BOOT_DEVICE, as the client's NIC had no interface. Windows Boot Manager starts only entries in its list (`displayorder`), whatever its default is: "There are 0x1 boot options" in the boot events | The entry is first in the list, with a timeout of 0, so there's no menu; WinPE takes it out of the list again |
| Made on the storage server with the disk mounted, the boot entry named the VHDX file, `vhd=[D:]\iSCSI\clients\...vhdx`, which a client can't find. bcdedit stores a mounted VHDX's partitions relative to the file | The entry is made by the build VM's running Windows, where the disk is a disk: by the Windows partition's identity, which every child disk of the image shares |
| bcdedit refused a RAM disk found by its path (`ramdisk=[locate]...`): it looks the file up on the running system | By partition, as above |
| `bcdedit /enum` of an entry that doesn't exist succeeds | `bcdedit /delete` without checking, ignoring its result |
| After a host restart, no client got its boot file over TFTP, and the iSCSI target listened on nothing | Both servers' services now come back by themselves ([servers](servers.md#what-each-piece-is-for)) |
| `servers/remote.sh` sent only `servers/`, `boot/` and `image/` to the servers | And `clients/` |
| `Set-GPPrefRegistryValue` adds an item each time, and any GPO change is a new version | Each setting is compared first |

## Results

The plan's test for phase 3, on srv-pve-1, 2026-10-12, with `golden-v5`: `new-client.sh` for the three clients, then `check.sh --boot`, which started them together.

| | dl-ws-1 | dl-ws-2 | dl-ws-3 |
|---|---|---|---|
| NIC | vmxnet3 | e1000e at `net0`: the build NIC's model and slot | vmxnet3 |
| Its first boot's WinPE | `/Add-NetAdapter` | nothing: the image has this NIC | `/Add-NetAdapter` |
| Set up and joined, from power-on | 7 minutes | 6 minutes | 6 minutes |
| Name | `DL-WS-1` | `DL-WS-2` | `DL-WS-3` |
| Machine SID | S-1-5-21-1095917956-… | S-1-5-21-3216931516-… | S-1-5-21-1784561079-… |
| Disk, after the first boot | 1.18 GB | 1.24 GB | 1.21 GB |
| After the second boot | 1.34 GB | 1.77 GB, with a domain user's first logon | 1.34 GB |

- **`new-client.sh`** took about 5 seconds per client.
- **All three** were in the domain with a working secure channel, on their reserved addresses, with the GPO applied: Windows Update off, hibernation and fast startup off, `PnPCapabilities` 24, and the pagefile 2048 MB, fixed, from the second boot. The answer file with the join was gone.
- **A domain user,** `DISKLESS\testuser`, in Domain Users only, logged on at dl-ws-2's console and got a desktop, with its profile on the client's disk; an interactive logon as that user worked on all three. dl-ws-2 reached the internet, and DNS through the domain controller.
- **Restarted together,** the three were back in Windows within a minute, with no WinPE.
- **`remove-client.sh`** refused dl-ws-1 while it ran. It removed dl-ws-3 completely, in 2.5 minutes as dl-ws-3 had only just been switched off, and was safe to run again: no boot script, reservation, DNS record, computer account, disk or target was left. `new-client.sh` then made dl-ws-3 again, a new computer account with a new SID, set up and joined 6 minutes after it was switched on.
- **Child disks are smaller than the plan's estimate** of about 2 GB after the first boot: 1.2 GB, plus about 0.4 GB for a user's first logon. The pagefile's 2 GB is allocated but grows the disk only as it's written.
- **`golden-v5`** took 21 minutes to build (WinPE and setup 10, Windows 11): 12.2 GB, with 471 MB of first-boot WinPE.

The first boot from the disk was proven first on throwaway children of `golden-v4`, with the boot entry made by hand in their Windows: an e1000e at `net0`, which WinPE left as it was, and then the same disk on a vmxnet3, which got its interface and booted.

## Using it

From this repo in WSL, after [the golden image](image.md), with `golden-v5` or later: an image without the first boot is refused.

1. **Add the client** to [clients/clients.csv](../clients/clients.csv): its name (up to 15 letters, digits and hyphens: a computer name), its MAC, and an address in the reserved range. For the lab's VMs, `terraform output clients` in `lab/` prints them.
2. **Make it:**
   ```sh
   clients/new-client.sh dl-ws-1          # the newest sealed golden image; or a version: clients/new-client.sh dl-ws-1 5
   ```
3. **Switch it on.** A physical machine needs UEFI network boot with Secure Boot off ([plan](../PLAN.md#physical-workstations)). Its first boot takes 6–7 minutes in the lab and restarts once.
4. **Check it:**
   ```sh
   . ~/.config/proxmox/diskless.env
   clients/check.sh dl-ws-1               # --boot to start VM clients that are off and wait for them first
   ```
   For a VM client it shows its name, machine SID, domain and secure channel, NIC, the GPO and its settings, and its first boot's log; for any client, its disk and whether it's running.

**To remove it:** switch it off, then `clients/remove-client.sh dl-ws-1`.
