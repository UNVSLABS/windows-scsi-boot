# Golden image

Phase 2 of the [plan](../PLAN.md): a sysprepped Windows 11 Enterprise LTSC 2024 installed onto an iSCSI disk, which clients boot from through differencing disks. Plus the test of whether one image boots on different NICs. Sources are in [image/](../image) and [boot/](../boot). The environment's values are in [servers/settings.psd1](../servers/settings.psd1), and the driver pack is in [image/drivers.psd1](../image/drivers.psd1); change them for yours.

## Status

| Step | State |
|---|---|
| Build VM, test clients with three NIC models (Terraform) | **Done 2026-10-11** |
| Domain controller: Windows ADK, WinPE with the NIC drivers, the install share with the media and the driver pack | **Done 2026-10-11** |
| The build's boot: iPXE boots WinPE with the blank build disk attached, and WinPE fetches its job and maps the share | **Done 2026-10-11** |
| WinPE runs setup onto the iSCSI disk, and Windows boots from it ([below](#booting-from-iscsi)) | **Done 2026-10-11** |
| Sysprep, sealing `golden-v1` | **Done 2026-10-11**: 12.4 GB, generalised, read-only |
| The NIC test, and what makes a NIC a boot NIC | **Done 2026-10-11** ([below](#nic-independence)) |
| A second NIC model through the build: vmxnet3 | **Done 2026-10-11**: `golden-v3` boots e1000e and vmxnet3 clients ([results](#results)) |
| A clean build with the scripts as they are: `golden-v4` | **Done 2026-10-11**: 11.6 GB, in 25 minutes (WinPE and setup 13, Windows 12). Boots the e1000e and vmxnet3 clients |

## What a build makes

`golden-v<N>.vhdx` on the storage server, in `D:\iSCSI\images`: a dynamic 64 GB VHDX, read-only once built.

| | |
|---|---|
| Windows | Windows 11 Enterprise LTSC 2024 (image 1 of the media's `install.wim`), with Microsoft's KMS client key, so unactivated without a KMS host |
| Installed onto | An iSCSI disk, by Windows setup in WinPE, so that setup itself makes the build's NICs boot NICs ([below](#nic-independence)) |
| Boot NICs | Intel 82574L (QEMU's e1000e), the build VM's own; and vmxnet3, the build's second NIC (`BuildSecondNic`) |
| Account | `admin`, with `IMAGE_PASSWORD` from `.env`. It's kept apart from the servers' password: every client has it |
| Remote access | OpenSSH with the servers' keys (Microsoft's MSI), RDP and ping, on every network profile |
| Drivers | The driver pack, added by setup before the image's first boot: virtio-win 0.1.302 (all its Windows 11 drivers), Intel 82574L 12.15.22.6 and vmxnet3 1.9.21.0. Plus the QEMU guest agent |
| Settings | en-AU formats and keyboard, Adelaide time, en-US display. No automatic BitLocker, no sleep, no hibernation |
| Windows Update | Off, by local policy. Clients get updates in new golden images. `--updates` installs them in the build |
| Sysprep | Generalised for other hardware (no `/mode:vm`), keeping every installed driver and device. A client's first boot takes a random name and its own SID, with no questions |

## How a build works

```
image/build.sh <N>                                                    PC, WSL
 1 vm-dl-san-1   blank golden-v<N>.vhdx on target "build", which accepts only dl-build-1's IQN; with a second NIC,
                 target "build-second" too, a small disk on the server's second address
 2 vm-dl-dc-1    the ADK and WinPE with the NIC drivers (once); the install share with the media and drivers (once);
                 this build's answer files, a new password for the share's account, and for dl-build-1 its boot
                 script for setup, its WinPE job and a DHCP reservation
 3 dl-build-1    with its second NIC as net1 (vmxnet3):
                 PXE ─▶ snponly.efi ─▶ clients/<mac>.ipxe ─▶ build.ipxe, setup:
                   clear the gateway, which iPXE would put in the iBFT,
                   chain ipxe.efi, which drives both NICs, and run again in it:
                   sanhook the build disk through net0 and the second disk through net1, boot WinPE (wimboot)
                 WinPE fetches jobs/<mac>.cmd: map \\<dc>\install, wait for both disks, run setup onto the large one
                 (/noreboot), copy the first logon's files, power off
 4 PC            take net1 away; dl-build-1's boot script for windows
 5 dl-build-1    PXE ─▶ snponly.efi ─▶ build.ipxe, windows: sanboot the build disk ─▶ setup finishes
                 ─▶ firstlogon.ps1 ─▶ restart ─▶ generalize.ps1: sysprep, then power off
 6 vm-dl-san-1   take golden-v<N> off the target, check that it's generalised, make it read-only
 7 vm-dl-dc-1    remove the build's files, and disable the share's account (also when the build fails)
```

- **The build VM,** `dl-build-1`, is an empty diskless VM like the clients, with an Intel e1000e NIC ([lab/lab.auto.tfvars](../lab/lab.auto.tfvars)). Its boot script and job exist only during a build; otherwise it gets the menu for machines that aren't clients.
- **Its second NIC** is added by `build.sh` through the Proxmox API for steps 3 and 4 only, as `net1`, with the model and MAC in `settings.psd1`. Without `BuildSecondNic`, the build has one NIC and one disk.
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
- **A failure in WinPE** leaves it at a prompt, and `build.sh` stops after 45 minutes. The VM stays on for a look. WinPE powering off without setup having written to the disk stops it too.

## Booting from iSCSI

How WinPE and then Windows take over the iSCSI disk that iPXE attached, as seen in the builds of 2026-10-11:

- **The iBFT has no gateway.** Windows adds a route to the iSCSI target through the gateway in the iBFT, even when the target is on its own subnet. A gateway that doesn't route that traffic back onto the subnet breaks the connection: WinPE made the boot session, but it never connected, and the target logged no login. iPXE copies the NIC's gateway into the iBFT, so [build.ipxe](../boot/build.ipxe) and [client.ipxe](../boot/client.ipxe) clear it (`set net0/gateway 0.0.0.0`) before `sanboot` or `sanhook`. Windows then reaches the target directly, and still takes its default gateway from DHCP, so the internet works.
- **WinPE connects the disks itself,** once plug and play has loaded the NICs' drivers. The drivers don't load at boot in WinPE: DISM only stages NIC drivers. The job waits up to 3 minutes for the disks.
- **Setup makes each iBFT NIC a boot NIC of the new Windows,** for every NIC it can match to one of WinPE's (`NICs in iBFT: 2; NICs resolved: 2` in `setupact.log`). For each, it imports the driver package that WinPE uses into the new Windows and *reflects it as critical* (`Driver Install ... Driver Result: [0x0]`), which registers it in the image's `SYSTEM` hive and creates its service; then it runs `dism /Add-NetAdapter` for it (log: `Windows\Panther\iscsi_boot_net.log`). The answer file adds the driver pack in the offlineServicing pass, which setup applies just before.
- **What the new Windows boots with:**

  | Service | Start | `BootFlags` |
  |---|---|---|
  | `e1iexpress`: the pack's Intel 82574L driver, 12.15.22.6 | 3 (on demand) | 1: loads at boot when booting from the network. From its INF |
  | `vmxnet3ndis6`: the pack's vmxnet3 driver, 1.9.21.0 | 3 | 1. Setup sets it: vmxnet3's INF doesn't |
  | `iScsiPrt`: the iSCSI initiator | 3 | 1 |
  | `Tcpip` | 0 (at boot) | 1 |

- **Logs when something fails:** WinPE's job prints the routes, the TCP state on port 3260 and the boot session if the disks don't appear, and setup's errors if setup fails.

## NIC independence

Found in the [plan's test](../PLAN.md#nic-independence), 2026-10-11.

**A NIC boots the image only if two things are in it:**
1. **Its driver package, reflected as critical:** in the image's `SYSTEM` hive (`DriverDatabase`, with the package's configurations), and its service. The kernel then sets up a device of that model while it boots, before any disk is there. Setup does this only for the NICs in the iBFT. DISM, and the answer file's driver pack, only *stage* network drivers: their configurations stay in the `DRIVERS` hive, which the kernel can't read until the boot disk is there.
2. **A network interface for that device, at its PCI location:** what `dism /Add-NetAdapter` writes, binding TCP/IP to it at boot. It needs the live NIC (`/HostAdapter`), and keys the interface to the NIC's location path, such as `PCIROOT(0)#PCI(1E00)#PCI(0100)#PCI(1200)`.

Without the first, Windows stops with INACCESSIBLE_BOOT_DEVICE at once; without the second, a few minutes into the boot.

**Device identity.** Windows names a PCI device by its model and its location, or by a PCIe serial number where the device has one. Proxmox puts a q35 VM's NICs behind a PCI bridge, where QEMU's e1000e and vmxnet3 have no serial number, so `net0` is the same device in every VM with the same model: `...\5&2490727a&0&9008F0`. Sysprep keeps installed devices (`PersistAllDeviceInstalls`), so the build NIC's device and interface are in the image already. Any other NIC is a new device: another model, another slot, and physical machines.

**So each client's NIC needs its interface made once, unless it's the build NIC's model at the build NIC's slot:** WinPE on the client, with its disk attached, runs `/Add-NetAdapter` for its NIC on that disk (the `netadapter` variant of the test, [image/winpe/netadapter.cmd](../image/winpe/netadapter.cmd)). That's a step of the client's first boot in phase 3.

**And each NIC model needs to have been in the iBFT when setup ran.** The build adds a second model (`BuildSecondNic`):
- **One second model:** Windows reads two NICs from the iBFT, whatever iPXE writes. A third was left out.
- **Through a target of its own:** iPXE puts a disk's NIC in the iBFT by routing to the disk's target. So the second NIC reaches a small second disk through the storage server's second address, with a host route each (iPXE's `static-routes`, DHCP option 121), and the build disk keeps going through `net0`.
- **With the full iPXE:** the stock `snponly.efi` drives only the NIC it was loaded from, so the build's boot chains `ipxe.efi`, from the same iPXE release, before anything is attached.
- **For setup only:** with the second NIC still there at the new Windows' first boot, setup's specialize pass restarted the VM while installing devices. So WinPE powers off, and `build.sh` takes the NIC away first.
- **Not virtio:** setup itself fails to reflect virtio's NetKVM 0.1.302 (`Driver Install ... Driver Result: [0x80070001]`, "Windows installation cannot continue because a required driver could not be installed"). An image built on a virtio NIC would fail at the same step. VM clients use e1000e or vmxnet3.
- **Physical NIC models** can be added only with the NIC itself in the build VM, passed through from the host, or by building on a physical machine.

[image/nic-test.sh](../image/nic-test.sh) tests a golden image on one client:
- it gives a client a new differencing disk on the image;
- then it applies a variant: `none`, `bootflags`, `bootstart`, or `netadapter` (WinPE on the client runs `/Add-NetAdapter` for its NIC on the disk, and sets `BootFlags` 1 on the NIC's service, copying WinPE's if the image has none);
- then it boots the client, and passes if Windows finishes its first boot within 20 minutes.

The clients have three NIC models: `dl-ws-1` virtio, `dl-ws-2` e1000e, `dl-ws-3` vmxnet3.

### Results

| Image | Client NIC | `none` | `netadapter` |
|---|---|---|---|
| `golden-v1`, built on an e1000e | e1000e, `net0`: the build NIC's model and slot, a new MAC | **Passed,** 2 minutes. The build VM's device and interface, kept by sysprep | |
| | e1000e, moved to `net1`: a new slot | INACCESSIBLE_BOOT_DEVICE, a few minutes in | **Passed,** 2 minutes. The kernel set up the new device at boot |
| | virtio, vmxnet3 | INACCESSIBLE_BOOT_DEVICE: their drivers are only staged | INACCESSIBLE_BOOT_DEVICE |
| `golden-v3` and `golden-v4`, built on an e1000e with vmxnet3 as the second NIC | e1000e, `net0` | **Passed,** 2 minutes | |
| | vmxnet3, `net0`: the second NIC was `net1` | | **Passed,** 3 minutes |

`golden-v3` was built with one-off scripts, `golden-v4` with the ones in this repo. `golden-v1` and `golden-v3` have since been deleted; `golden-v2`, a build whose iBFT had one NIC, too.

`bootflags` and `bootstart` change only the services of NICs the image has installed, and copying WinPE's service in isn't reflection, so neither helps a model setup hasn't seen. An undocumented `drvstore.dll` function that setup's reflection is reported to use (`DriverStoreOfflineAddDriverPackageW`) returned "invalid parameter" for every flag value tried, even for the package setup had reflected, and was dropped.

## What each piece is for

Each of these was a failure on the way, on 2026-10-10 and 11:

| Problem | Fix |
|---|---|
| The virtio ISO failed its checksum: fedorapeople.org answers browsers with a proof-of-work page (Anubis), and Windows PowerShell's default user agent looks like a browser | Downloads send their own user agent |
| The build VM reported powering off at once: a start request returns before the VM runs | `lab/pve.sh` waits for each Proxmox task to finish |
| iPXE's build script stopped at the first `sanboot`, which fails on a blank disk: a failing command ends an iPXE script unless `\|\|` handles it | `sanboot ... \|\| goto install`, and now a phase for each boot |
| Boot Manager: `\EFI\Microsoft\Boot\BCD` missing (0xc000000f). wimboot found no BCD in the ADK's WinPE | The BCD and `boot.sdi` come from the ADK's WinPE media |
| WinPE never ran the build: wimboot names an `initrd` file after its URL unless given `--name`, so `startnet.cmd` was never replaced | WinPE fetches its job over HTTP instead |
| The storage server's iSCSI target stopped listening after Windows Update restarted the server ([servers](servers.md#what-each-piece-is-for)) | Updates install only when an admin says so |
| WinPE made the iSCSI boot session, but it never connected, with any NIC, driver or iPXE build: Windows routed it through the iBFT's gateway ([above](#booting-from-iscsi)) | iPXE clears the gateway before attaching the disk |
| Setup stopped at "Windows could not apply the Windows PE bootstrap setting". Setup also applies the answer file's windowsPE pass to the running WinPE, and the ADK's WinPE refused its driver paths (`E_INVALIDARG` at `PathAndCredentials` in `setuperr.log`) | The driver pack is in the offlineServicing pass |
| WinPE's job stopped without a word after setup: WinPE has no `tasklist` or `findstr`, and a missing command before a pipe with `\|\|` ends a batch file | PowerShell and `find` instead |
| A build straight after a stopped one refused to start: the target keeps a powered-off VM's session until its idle check logs it off, about two minutes later | `build-disk.ps1` and `seal.ps1` wait for it |
| Sysprep never ran: `Optimize-Volume -ReTrim` failed, because the iSCSI target presents the disk as fully provisioned, so Windows can't trim it | No trim |
| Only the build NIC's model booted the image ([above](#nic-independence)) | A second NIC model through the build, and the client's interface made by WinPE |
| iPXE saw only the build VM's first NIC: `snponly.efi` drives only the NIC it was loaded from | The build chains `ipxe.efi` for setup |
| Three NICs in iPXE's iBFT, two in setup's log: Windows reads two | One second model |
| Setup aborted at virtio's driver: "a required driver could not be installed" (0x80070001) | vmxnet3 as the second model |
| Setup's specialize pass restarted the VM, "The computer restarted unexpectedly", with the second NIC still in it | WinPE powers off, and `build.sh` takes the NIC away before Windows' first boot |
| The iBFT had one NIC again when iPXE had tried to boot the blank disk before chaining `ipxe.efi` | The build's boot chains it before attaching anything, and knows its phase rather than trying the disk |
| The answer file installed onto disk 0, which with two iBFT disks needn't be the build disk | WinPE's job writes the large disk's number into its copy of the answer file |

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

**To change WinPE,** for example after a change to the driver pack or its startup: delete `C:\BootFiles\winpe` on the domain controller, and the next build makes it again. **To take a new driver release:** change its entry in `drivers.psd1`, and delete its folder in `C:\Install\drivers` and `C:\BootFiles\winpe`. **To change the second NIC model:** `BuildSecondNic` in `settings.psd1`; `''` builds with one NIC.
