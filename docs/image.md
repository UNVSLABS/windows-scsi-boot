# Golden image

Phase 2 of the [plan](../PLAN.md): a sysprepped Windows 11 Enterprise LTSC 2024 installed onto an iSCSI disk, which clients boot from through differencing disks. Plus the test of whether one image boots on different NICs. Sources are in [image/](../image) and [boot/](../boot). The environment's values are in [servers/settings.psd1](../servers/settings.psd1), and the driver pack is in [image/drivers.psd1](../image/drivers.psd1); change them for yours.

## Status

| Step | State |
|---|---|
| Build VM, test clients with three NIC models (Terraform) | **Done 2026-10-11** |
| Domain controller: Windows ADK, WinPE with the NIC drivers, the install share with the media and the driver pack | **Done 2026-10-11** |
| The build's boot: iPXE boots WinPE with the blank build disk attached, and WinPE fetches its job and maps the share | **Done 2026-10-11** |
| WinPE runs setup onto the iSCSI disk, and Windows boots from it ([below](#booting-from-iscsi)) | **Done 2026-10-11** |
| Sysprep, sealing `golden-v1` | **Done 2026-10-11**: 12.4 GB, generalised, read-only. `generalize.ps1`'s fix went into that build by hand, so a clean build with the scripts as they are is still to run |
| The NIC test | **Run 2026-10-11:** the build's NIC model passes on a new machine; virtio and vmxnet3 don't boot with any variant so far ([results](#results-2026-10-11-on-golden-v1-built-on-an-e1000e)) |

## What a build makes

`golden-v<N>.vhdx` on the storage server, in `D:\iSCSI\images`: a dynamic 64 GB VHDX, read-only once built.

| | |
|---|---|
| Windows | Windows 11 Enterprise LTSC 2024 (image 1 of the media's `install.wim`), with Microsoft's KMS client key, so unactivated without a KMS host |
| Installed onto | An iSCSI disk, by Windows setup in WinPE, so that setup itself makes the boot NIC a boot device |
| Account | `admin`, with `IMAGE_PASSWORD` from `.env`. It's kept apart from the servers' password: every client has it |
| Remote access | OpenSSH with the servers' keys (Microsoft's MSI), RDP and ping, on every network profile |
| Drivers | The driver pack, added by setup before the image's first boot: virtio-win 0.1.302 (all its Windows 11 drivers), Intel 82574L 12.15.22.6 and vmxnet3 1.9.21.0. Plus the QEMU guest agent |
| Settings | en-AU formats and keyboard, Adelaide time, en-US display. No automatic BitLocker, no sleep, no hibernation |
| Windows Update | Off, by local policy. Clients get updates in new golden images. `--updates` installs them in the build |
| Sysprep | Generalised for other hardware (no `/mode:vm`), keeping every installed driver. A client's first boot takes a random name and its own SID, with no questions |

## How a build works

```
image/build.sh <N>                                                    PC, WSL
 1 vm-dl-san-1   blank golden-v<N>.vhdx on target "build", which accepts only dl-build-1's IQN
 2 vm-dl-dc-1    the ADK and WinPE with the NIC drivers (once); the install share with the media and drivers (once);
                 this build's answer files, a new password for the share's account, and for dl-build-1 its boot
                 script, its WinPE job and a DHCP reservation
 3 dl-build-1    PXE ─▶ iPXE ─▶ clients/<mac>.ipxe ─▶ build.ipxe:
                   clear the gateway, which iPXE would put in the iBFT,
                   sanboot the build disk, which fails while it's blank,
                   so sanhook it, and boot WinPE (wimboot)
                 WinPE fetches jobs/<mac>.cmd: map \\<dc>\install, run setup onto the iSCSI disk (/noreboot), copy the
                 first logon's files, restart
                 iPXE ─▶ build.ipxe: sanboot now boots the disk ─▶ setup finishes ─▶ firstlogon.ps1 ─▶ restart
                 ─▶ generalize.ps1: sysprep, then power off
 4 vm-dl-san-1   take golden-v<N> off the target, check that it's generalised, make it read-only
 5 vm-dl-dc-1    remove the build's files, and disable the share's account (also when the build fails)
```

- **The build VM,** `dl-build-1`, is an empty diskless VM like the clients, with an Intel e1000e NIC ([lab/lab.auto.tfvars](../lab/lab.auto.tfvars)). Its boot script and job exist only during a build; otherwise it gets the menu for machines that aren't clients.
- **WinPE** is the ADK's, 10.1.26100.9457. It has WMI and SecureStartup for Windows 11's setup, PowerShell, and the driver pack's NIC drivers. wimboot boots it from `http://<dc>/boot/winpe/`, with the BCD and `boot.sdi` from the ADK's WinPE media.
- **WinPE's jobs.** WinPE's own `startnet.cmd` ([image/winpe/startnet.cmd](../image/winpe/startnet.cmd)) fetches `http://<dc>/boot/jobs/<mac>.cmd` for its MAC and runs it. The build's job is [image/winpe/build.cmd](../image/winpe/build.cmd). Without a job, WinPE stops at a prompt, for recovery.
- **Setup is the previous version,** `sources\setup.exe`. Windows 11 24H2's new setup has been reported to quit silently at an iSCSI disk.
- **The install share,** `\\<dc>\install`, holds:
  - the media (`media\`);
  - the driver pack (`drivers\`);
  - the guest agent (`tools\`).

  WinPE maps it by address with the domain account `winpe`, which nothing else uses. `build.sh` gives the account a new random password for each build, and disables it after.
- **Passwords during a build:**
  - The share's password is in WinPE's job, over anonymous HTTP.
  - The image's password is in the answer files on the share, readable only by admins and `winpe`.
  - Both are removed when the build ends.
  - Windows blanks the image's password in its own copy once a client has used it.
- **A failure in WinPE** leaves it at a prompt. So 20 minutes in, `build.sh` checks that setup has written to the disk, and stops if it hasn't. The VM stays on for a look.

## Booting from iSCSI

How WinPE and then Windows take over the iSCSI disk that iPXE attached, as seen in the build of 2026-10-11:

- **The iBFT has no gateway.** Windows adds a route to the iSCSI target through the gateway in the iBFT, even when the target is on its own subnet. A gateway that doesn't route that traffic back onto the subnet breaks the connection: WinPE made the boot session, but it never connected, and the target logged no login. iPXE copies the NIC's gateway into the iBFT, so [build.ipxe](../boot/build.ipxe) and [client.ipxe](../boot/client.ipxe) clear it (`set net0/gateway 0.0.0.0`) before `sanboot` or `sanhook`. Windows then reaches the target directly, and still takes its default gateway from DHCP, so the internet works.
- **WinPE connects the disk itself,** once plug and play has loaded the NIC's driver. The driver doesn't load at boot in WinPE: DISM only stages NIC drivers. The job waits up to 3 minutes for the disk.
- **Setup makes the NIC a boot device of the new Windows.** It matches the iBFT's NIC to WinPE's (`NICs in iBFT: 1; NICs resolved: 1` in `setupact.log`) and runs `dism /Add-NetAdapter` on the new Windows (log: `Windows\Panther\iscsi_boot_net.log`). The NIC's driver must be in the new Windows by then. The answer file adds the driver pack in the offlineServicing pass, which setup applies just before.
- **What the new Windows boots with:**

  | Service | Start | `BootFlags` |
  |---|---|---|
  | `e1iexpress`: the pack's Intel 82574L driver, 12.15.22.6 | 3 (on demand) | 1: loads at boot when booting from the network |
  | `iScsiPrt`: the iSCSI initiator | 3 | 1 |
  | `Tcpip` | 0 (at boot) | 1 |

- **Logs when something fails:** WinPE's job prints the routes, the TCP state on port 3260 and the boot session if the disk doesn't appear, and setup's errors if setup fails.

## NIC independence

Found while preparing the [plan's test](../PLAN.md#nic-independence):

- **Drivers.** Windows 11 24H2 has the e1000e (82574L) and vmxnet3 drivers inbox. WinPE has neither, so they're in the driver pack.
- **Device identity.** QEMU's e1000e and vmxnet3 expose a PCIe serial number made from the MAC address. Most physical NICs have one too, and Windows builds the NIC's device ID from it. So to an image, every machine's NIC is a new device, even when the model is the same. virtio-net has no serial number, so its ID depends only on the PCI slot.
- **`BootFlags` alone** can't help a NIC the image has never installed: Windows creates a driver's service only when it installs a device for it. Windows setup handles the boot NIC with an undocumented `dism /Add-NetAdapter`, which is the `netadapter` variant below.

[image/nic-test.sh](../image/nic-test.sh) tests a golden image on one client:
- it gives a client a new differencing disk on the image;
- then it applies a variant: `none`, `bootflags`, `bootstart`, or `netadapter` (WinPE on the client first copies its NIC driver's service into the disk's Windows with `BootFlags` 1, then runs DISM's `/Add-NetAdapter` on it);
- then it boots the client, and passes if Windows finishes its first boot within 20 minutes.

The clients have three NIC models: `dl-ws-1` virtio, `dl-ws-2` e1000e, `dl-ws-3` vmxnet3.

### Results, 2026-10-11, on `golden-v1` (built on an e1000e)

| Client NIC | `none` | `/Add-NetAdapter` only | `/Add-NetAdapter`, with the driver's service and `BootFlags` 1 |
|---|---|---|---|
| e1000e, new MAC | **Passed:** Windows finished its first boot in 2 minutes | | |
| virtio | INACCESSIBLE_BOOT_DEVICE | INACCESSIBLE_BOOT_DEVICE | |
| vmxnet3 | INACCESSIBLE_BOOT_DEVICE | INACCESSIBLE_BOOT_DEVICE | INACCESSIBLE_BOOT_DEVICE, a few minutes later |

`bootflags` and `bootstart` weren't run: they change only the services of NICs the image has installed, and it has none for virtio or vmxnet3 (`test-client.ps1` reports `service netkvm: none`), so they're the same as `none` for those NICs.

What the build's own logs show (`Windows\INF\setupapi.offline.log` in the image):
- **The answer file's driver pack only stages network drivers.** DISM imports them into the image's driver store, but makes no service for them: network drivers aren't boot-critical.
- **Setup does three things for its boot NIC:** it imports the driver package that WinPE is using, then *reflects it as critical* ("Reflect Critical Driver Package"): it registers it in the image's `SYSTEM` hive and creates its service (`e1iexpress`, with `BootFlags` 1 from its INF). Then it runs `/Add-NetAdapter`. Windows can then set up a new NIC of that model while it boots, which is why the e1000e client with a new MAC passed.
- **`/Add-NetAdapter` alone creates the NIC and its TCP/IP binding, but no service.** Copying WinPE's service into the image, with `BootFlags` 1 and its driver file, isn't enough either: the package also has to be reflected as critical. DISM does that only through an undocumented function in `drvstore.dll` (`DriverStoreReflectCriticalW`), for drivers it counts as boot-critical, and has no switch for network drivers.

## What each piece is for

Each of these was a failure on the way, on 2026-10-10 and 11:

| Problem | Fix |
|---|---|
| The virtio ISO failed its checksum: fedorapeople.org answers browsers with a proof-of-work page (Anubis), and Windows PowerShell's default user agent looks like a browser | Downloads send their own user agent |
| The build VM reported powering off at once: a start request returns before the VM runs | `lab/pve.sh` waits for each Proxmox task to finish |
| iPXE's build script stopped at the first `sanboot`, which fails on a blank disk: a failing command ends an iPXE script unless `\|\|` handles it | `sanboot ... \|\| goto install` |
| Boot Manager: `\EFI\Microsoft\Boot\BCD` missing (0xc000000f). wimboot found no BCD in the ADK's WinPE | The BCD and `boot.sdi` come from the ADK's WinPE media |
| WinPE never ran the build: wimboot names an `initrd` file after its URL unless given `--name`, so `startnet.cmd` was never replaced | WinPE fetches its job over HTTP instead |
| The storage server's iSCSI target stopped listening after Windows Update restarted the server ([servers](servers.md#what-each-piece-is-for)) | Updates install only when an admin says so, and the target service starts late |
| WinPE made the iSCSI boot session, but it never connected, with any NIC, driver or iPXE build: Windows routed it through the iBFT's gateway ([above](#booting-from-iscsi)) | iPXE clears the gateway before attaching the disk |
| Setup stopped at "Windows could not apply the Windows PE bootstrap setting". Setup also applies the answer file's windowsPE pass to the running WinPE, and the ADK's WinPE refused its driver paths (`E_INVALIDARG` at `PathAndCredentials` in `setuperr.log`) | The driver pack is in the offlineServicing pass |
| WinPE's job stopped without a word after setup: WinPE has no `tasklist` or `findstr`, and a missing command before a pipe with `\|\|` ends a batch file | PowerShell and `find` instead |
| A build straight after a stopped one refused to start: the target keeps a powered-off VM's session until its idle check logs it off, about two minutes later | `build-disk.ps1` and `seal.ps1` wait for it |
| Sysprep never ran: `Optimize-Volume -ReTrim` failed, because the iSCSI target presents the disk as fully provisioned, so Windows can't trim it | No trim |

## Building

After [the servers](servers.md), from this repo in WSL:

1. **The build VM and test clients:** `terraform apply` in `lab/` ([environment](environment.md)).
2. **The password:** set `IMAGE_PASSWORD` in `.env` ([.env.example](../.env.example)), 16+ letters and digits.
3. **Build:**
   ```sh
   . ~/.config/proxmox/diskless.env
   image/build.sh 1               # golden-v1; --updates to install Windows updates in it
   ```
   It refuses a version that's already built. An unfinished build of the same version is replaced. The first run takes half an hour more, for the ADK and WinPE.

**To change WinPE,** for example after a change to the driver pack or its startup: delete `C:\BootFiles\winpe` on the domain controller, and the next build makes it again. **To take a new driver release:** change its entry in `drivers.psd1`, and delete its folder in `C:\Install\drivers` and `C:\BootFiles\winpe`.
