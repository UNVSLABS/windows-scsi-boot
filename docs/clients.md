# Clients

Phases 3 and 4 of the [plan](../PLAN.md): a client is a machine with no disk that boots from its own differencing disk on the golden image, joined to the domain. `clients/new-client.sh` makes one from its row in [clients/clients.csv](../clients/clients.csv); it then only has to be switched on. `clients/update-clients.sh` moves clients to a new golden image. Sources are in [clients/](../clients); the first boot is part of the golden image ([image/](../image)). The environment's values are in [servers/settings.psd1](../servers/settings.psd1) and `clients.csv`; change them for yours.

## Status

| Step | State |
|---|---|
| `new-client.sh`, `remove-client.sh`, `check.sh` | **Done 2026-10-12** |
| The first boot from the disk: the golden image's WinPE makes the client's NIC a boot NIC | **Done 2026-10-12**, in the image since `golden-v5` |
| Group Policy: Windows Update off, no sleep, hibernation or fast startup, NIC power saving off, a fixed pagefile | **Done 2026-10-12** |
| Three clients boot together from one golden image, joined to the domain; a domain user logs on; child disk sizes | **Done 2026-10-12** ([results](#results)) |
| `update-clients.sh`: the three clients from `golden-v5` to `golden-v6`, end to end | **Done 2026-10-12** ([results](#an-update-golden-v5-to-golden-v6)) |
| What clients do when the storage server or the domain controller goes away, and how to recover them | **Done 2026-10-12** ([below](#when-a-server-restarts)): clients wait up to 10 minutes for the storage server since `golden-v6` |

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

`clients/remove-client.sh <name>` reverses New-Client: on the storage server, the target and the disk, refused while the client's target has a session; then on the domain controller, the boot script, the reservation and its lease, the DNS records and the computer account. The client then gets the menu for machines that aren't clients. Its row in `clients.csv` stays.

## Updating clients

`clients/update-clients.sh <version>` moves clients to another golden image: every client in `clients.csv` that has a disk, or the ones named after the version. Each one gets a new disk on that image, made as New-Client makes one, so its next start is a first boot again ([above](#the-first-boot)), with nothing to do per machine. Run it while the clients are off.

```
clients/update-clients.sh <version> [<name>...]                                      PC, WSL or Git Bash
 1 vm-dl-san-1   for each client: skipped if it has no target, or its disk is on golden-v<version> already; left as
                 it is if its target has a session, which is a client that's running; otherwise its disk comes off
                 its target, so it can't start meanwhile ("ready")
 2 vm-dl-dc-1    the clients' OU and GPO (policy.ps1); for each ready client, its DHCP reservation from clients.csv,
                 and a new offline domain join: djoin /provision /reuse, which keeps its computer account and resets
                 the account's machine password
 3 vm-dl-san-1   for each ready client: its old disk deleted, a new one on golden-v<version> with its name and join,
                 on the same target; then the golden images, with how many disks each has
```

| Kept | Made again |
|---|---|
| The computer account, with its SID, groups and DNS records; the target and its IQN; the boot script; the DHCP reservation | The disk: the client's machine SID, its local profiles and anything else stored on it. Wiping them is the point of an update |

- **Never for a running client.** A new join resets the computer account's machine password, which a running client still uses: it would lose its trust with the domain. So the domain controller's step comes only after the storage server has found the client off and taken its disk away. A running client is reported, and the script exits with an error: switch it off and run it again. Clients already on the version are skipped, so a second run does only the rest.
- **A client switched off a moment ago** keeps its session for a couple of minutes, until the target's idle check. The first step waits up to 2.5 minutes for that.
- **A failure** leaves the clients it hadn't finished with no disk on their targets: they get iPXE's "Booting windows failed" until the next run.
- **Rolling back** is the same, with the version before: `update-clients.sh 5`.
- **Old golden images aren't deleted.** The last step lists the images that no disk uses any more. They're kept to roll back to, until deleted with `image/remove.sh <version>`, which refuses while any disk is on it.
- **Three SSH connections in all,** whatever the number of clients: the IPS takes bursts of them for a scan ([servers](servers.md#how-setupsh-runs-the-scripts)).

New-Client and the update share their code: the disk and the identity in it ([clients/san/disk.ps1](../clients/san/disk.ps1)), and the reservation and the join ([clients/dc/client.ps1](../clients/dc/client.ps1)).

## When a server restarts

Tested on 2026-10-12, with the three clients running and each writing a line to its disk every second, past Windows' cache, so that a stall shows as a gap ([results](#restart-results)).

### The storage server

A client's Windows runs from its disk, so it stops when the iSCSI target does. What happens next depends on how long the target is away:

| Target away | Clients |
|---|---|
| Less than about a minute, such as a restart of the storage server VM | Pause, and carry on where they were |
| Longer, with Windows' default timeouts (`golden-v5`) | Stop with CRITICAL_PROCESS_DIED about 85 seconds in, and restart. iPXE then tries their disks every 35 seconds or so, and they're back in Windows less than a minute after the target is |
| Longer, up to 10 minutes, with the golden image's own timeout (`golden-v6` and later) | Pause, and carry on where they were. Off for 3 minutes, the storage server took 3.4 minutes from shutdown to its target listening again, and the clients waited it out |

- **Why a minute:** Windows' iSCSI initiator holds a disk's requests for 60 seconds while it reconnects (`MaxRequestHoldTime`), then fails them, and a client whose Windows is on that disk goes down. The golden image sets it to 10 minutes since `golden-v6` ([image/windows/iscsi-timeouts.ps1](../image/windows/iscsi-timeouts.ps1)). Microsoft doesn't document it for iSCSI boot; storage vendors raise it for the same reason, AWS's Storage Gateway to 600 seconds. The disk's own timeout (`TimeOutValue`, 60 seconds) didn't need changing: set in the image, it was back at 60 on the clients, which still waited out the 3.4 minutes.
- **Past 10 minutes,** clients should go down as with the default, and come back by themselves once the target is back (not tested). A longer outage is better met by shutting the clients down first.
- **No crash dump:** the dump driver doesn't load on a Windows booted from iSCSI ("Crash dump initialization failed!"), so a crash leaves only the stop code on screen and an unexpected restart in the event log (Kernel-Power 41).
- **The iSCSI target can take a minute to listen after a cold start.** It didn't bind to the server's address at boot, and the startup task that `servers/san/configure.ps1` adds restarted it a minute after boot ([servers](servers.md#what-each-piece-is-for)). After a restart, it bound by itself.
- **Don't restart the iSCSI Target Server service while clients run.** With sessions open, it never stopped: it stayed "Stop Pending" for 10 minutes, still taking connections and answering none, until its process was ended. Its clients went down after the timeout, and their iPXE hung trying to attach the disk. A restart of the whole server stopped the service in 3 seconds.
- **Plan restarts, as before** ([servers](servers.md)): Windows Update installs and restarts only when an admin says so.

**To recover a client** that went down: once the target listens again, nothing, if the client is at iPXE's "Booting windows failed": it tries again every 35 seconds or so. If it's anywhere else, restart it. If the iSCSI Target Server service is stuck stopping, end its process, then start it:

```powershell
Stop-Process -Id (Get-CimInstance Win32_Service -Filter "Name='WinTarget'").ProcessId -Force
Start-Service WinTarget
```

### The domain controller

Running clients don't need it: their disk is on the storage server, and their address, from the iBFT, never expires (Windows shows the boot NIC's DHCP address with an infinite lifetime). With it away:

| | |
|---|---|
| Running clients | Carry on: the disk didn't pause. Their secure channel still tested fine |
| Names | Fail: the domain controller is the clients' DNS server. So the internet, by name, fails too. Domain logons should work only for users with a logon cached on that client (not tested) |
| A client that starts | Gets no address (PXE-E18), tries IPv6 PXE and HTTP boot, and stops at "No bootable option or device was found" after about 5 minutes, where it stays |
| Once it's back | DNS, the internet and the secure channel work again on their own. Its boot files are served about 2 minutes after it starts |

**To recover a client** that started while the domain controller was away: restart it once the domain controller is back.

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
| dl-ws-3, removed and made again, had no reservation, and leased from the dynamic pool (found in phase 4). A removed reservation leaves its lease, and `Get-DhcpServerv4Reservation -IPAddress` returns that lease as if it were a reservation, so New-Client took the reservation to be there | New-Client looks in the scope's list of reservations, and Remove-Client deletes the client's leases too. The update sets each client's reservation again, which put dl-ws-3's back |

## Results

### Three clients on one image

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
- **`remove-client.sh`** refused dl-ws-1 while it ran. It removed dl-ws-3 completely, in 2.5 minutes as dl-ws-3 had only just been switched off, and was safe to run again: no boot script, reservation, DNS record, computer account, disk or target was left. `new-client.sh` then made dl-ws-3 again, a new computer account with a new SID, set up and joined 6 minutes after it was switched on; but without its DHCP reservation, as phase 4 found ([above](#what-each-piece-is-for)).
- **Child disks are smaller than the plan's estimate** of about 2 GB after the first boot: 1.2 GB, plus about 0.4 GB for a user's first logon. The pagefile's 2 GB is allocated but grows the disk only as it's written.
- **`golden-v5`** took 21 minutes to build (WinPE and setup 10, Windows 11): 12.2 GB, with 471 MB of first-boot WinPE.

The first boot from the disk was proven first on throwaway children of `golden-v4`, with the boot entry made by hand in their Windows: an e1000e at `net0`, which WinPE left as it was, and then the same disk on a vmxnet3, which got its interface and booted.

### An update: golden-v5 to golden-v6

The plan's test for phase 4, 2026-10-12: `golden-v6` made from `golden-v5` by `image/change.sh`, with one change, a longer iSCSI timeout ([image](image.md#changing-an-image)); then `update-clients.sh 6` for the three clients, and `check.sh --boot`.

| | dl-ws-1 | dl-ws-2 | dl-ws-3 |
|---|---|---|---|
| Updated by | the second run, once it was off | the first run | the first run |
| Set up and joined, from power-on | 6 minutes | 6 minutes | 6 minutes |
| Machine SID | new: S-1-5-21-2610546512-… | new: S-1-5-21-1414685625-… | new: S-1-5-21-2723676216-… |
| Computer account | kept: the same SID and creation time, a new password | kept | kept |
| Address | 10.31.1.1 | 10.31.1.2 | 10.31.1.3, its reservation back |
| Disk, after the first boot | 1.08 GB | 1.11 GB | 1.08 GB |

- **The first run,** with dl-ws-2 and dl-ws-3 shut down and dl-ws-1 still running: dl-ws-2 and dl-ws-3 were ready at once, as a client shut down properly logs off its session; dl-ws-1 still had a session after the 2.5-minute wait, so it was reported and left as it was, and the script exited with an error. The domain controller made new joins for dl-ws-2 and dl-ws-3 only. 2 minutes 40 seconds.
- **The second run,** with dl-ws-1 off: it skipped the other two, on `golden-v6` already, updated dl-ws-1, and listed `golden-v5` as having no disks, kept to roll back to. 50 seconds.
- **All three** were in the domain with a working secure channel, the GPO applied and the answer file gone, and `MaxRequestHoldTime` 600 from the image. Their DNS records, owned by the same accounts, were updated.
- **A domain user** logged on to all three (`DISKLESS\testuser`, an interactive logon through `LogonUser`, by Kerberos), and at dl-ws-2's console, to a desktop.
- **`image/change.sh`** took 13 minutes for `golden-v6`: the copy 2.5, while the clients ran on `golden-v5`; the build VM's first boot and Windows 5; the seal 4. 12.2 GB, as `golden-v5`.
- **`remove-client.sh` and `new-client.sh` for dl-ws-3,** after the fix to its reservation, left no reservation or lease, then made both again.
- **`image/remove.sh`** refused `golden-v6`, with its three disks, and deleted a sealed test image, whether SYSTEM or Administrators owned it.
- **Not fixed: Windows' automatic maintenance grows a child disk.** dl-ws-1, left at its logon screen, grew from 1.08 GB to 6.96 GB within 20 minutes of its first boot, when Windows' idle maintenance ran: among others the scheduled defrag, which reported a boot optimization of C: (event 258), .NET's native image tasks, and Defender's. On a differencing disk, every block that's moved or rewritten lands in the child. dl-ws-2, with a user logged on, was at 2.52 GB. Likely fixes, not yet tried: the defrag task off on clients, and the build running the maintenance once before sysprep.

### Restart results

The tests behind [When a server restarts](#when-a-server-restarts), 2026-10-12, with the three clients running and writing to their disks every second.

| Test | Clients | Disk pause | Then |
|---|---|---|---|
| Domain controller off for 2 minutes (shut down, then started) | `golden-v5` | none | All carried on. A client reset meanwhile got no address, and stopped at the firmware's "No bootable option" 5 minutes later; restarted once the domain controller was back, it was in Windows in 76 seconds |
| `Restart-Service WinTarget` on the storage server | `golden-v5` | until restarted | The service stayed "Stop Pending" for 10 minutes. The clients restarted unexpectedly 100 seconds in, and iPXE hung trying their disks. Once the service's process was ended and the service started, a key at each client's iPXE prompt got it back to Windows within a minute |
| Storage server restart (`shutdown /r`) | `golden-v5` | 34–36 s | All carried on. Windows was down for 6 seconds, and the clients' sessions were back 26 seconds after it booted |
| Storage server off for 3 minutes | `golden-v5` | — | CRITICAL_PROCESS_DIED 84 seconds in, on all three. At boot the target didn't bind, and its startup task restarted it a minute later; the clients' iPXE, retrying, had them back in Windows 50 seconds after that |
| Storage server off for 3 minutes | `golden-v6` | 203–204 s | All carried on, with no restart. The target was back 12–17 seconds after the server started, and the clients went on at once |

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

**To move the clients to a new golden image,** once it's built (`image/build.sh`) or changed (`image/change.sh`, [image](image.md#changing-an-image)): switch them off, then
```sh
clients/update-clients.sh 6               # every client in clients.csv; or some: clients/update-clients.sh 6 dl-ws-1
```
Then switch them on: each one's first boot on the new image takes 6–7 minutes. A client that was still on is reported; switch it off and run the same again. To go back, the same with the old version, while it's still there. To delete an old image no client is on: `image/remove.sh 5`.

**To remove it:** switch it off, then `clients/remove-client.sh dl-ws-1`.
