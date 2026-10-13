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
| A second NIC family through the build: vmxnet3, standing in for a physical one | **Done 2026-10-11**: `golden-v3` boots e1000e and vmxnet3 clients ([results](#results)). Dropped for the seal's NIC step, since `golden-v11` |
| A clean build with the scripts as they are: `golden-v4` | **Done 2026-10-11**: 11.6 GB, in 25 minutes (WinPE and setup 13, Windows 12). Boots the e1000e and vmxnet3 clients |
| The clients' first boot in the image: WinPE, which makes a client's NIC a boot NIC on its own ([clients](clients.md#the-first-boot)): `golden-v5` | **Done 2026-10-12** |
| A change to an image as a new version, rather than a build ([below](#changing-an-image)): `golden-v6`, `golden-v5` with a longer iSCSI timeout | **Done 2026-10-12**: 13 minutes (copy 2.5, the first boot and Windows 5, the seal 4) |
| The seal's maintenance step: no last-access times, defrag or swap assessment, and .NET's native images compiled, so that clients don't each do it ([clients](clients.md#automatic-maintenance)) | **Done 2026-10-13**: `golden-v10`, by way of `golden-v7` to `golden-v9` |
| The seal's NIC step, which makes every NIC driver in the driver pack a boot driver, and a build with one NIC ([below](#how-the-seal-makes-nic-drivers-boot-drivers)): `golden-v11` | **Done 2026-10-13**: 12.3 GB, in 24 minutes (WinPE and setup 12, Windows 11). Boots e1000e, vmxnet3 and virtio clients ([results](#results)) |

## What a build makes

`golden-v<N>.vhdx` on the storage server, in `D:\iSCSI\images`: a dynamic 64 GB VHDX, read-only once built.

| | |
|---|---|
| Windows | Windows 11 Enterprise LTSC 2024 (image 1 of the media's `install.wim`), with Microsoft's KMS client key, so unactivated without a KMS host |
| Installed onto | An iSCSI disk, by Windows setup in WinPE, so that setup itself makes the build's NIC a boot NIC ([below](#booting-from-iscsi)) |
| Boot NIC families | Every NIC driver in the driver pack: Intel 1 GbE (the build VM's own NIC, QEMU's e1000e, and many physical Intel NICs), VMware's vmxnet3 and virtio's NetKVM. Setup makes the build NIC's driver a boot driver, and the seal the others ([below](#nic-independence)). Since `golden-v11`; before, the build NIC's family and the build's second NIC's |
| Account | `admin`, with `IMAGE_PASSWORD` from `.env`. It's kept apart from the servers' password: every client has it |
| Remote access | OpenSSH with the servers' keys (Microsoft's MSI), RDP and ping, on every network profile |
| Drivers | The driver pack, added by setup before the image's first boot: virtio-win 0.1.302 (all its Windows 11 drivers), Intel 82574L 12.15.22.6 and vmxnet3 1.9.21.0. Plus the QEMU guest agent |
| Settings | en-AU formats and keyboard, Adelaide time, en-US display. No automatic BitLocker, no sleep, no hibernation |
| iSCSI timeout | 10 minutes, rather than Windows' 60 seconds, for the iSCSI initiator to hold a disk's requests while it reconnects (`MaxRequestHoldTime`), so that clients wait while the storage server restarts ([clients](clients.md#the-storage-server), [image/windows/iscsi-timeouts.ps1](../image/windows/iscsi-timeouts.ps1)). Since `golden-v6`, which got them in a change. `firstlogon.ps1` sets them in a build, which hasn't run since |
| Windows Update | Off, by local policy. Clients get updates in new golden images. `--updates` installs them in the build |
| Automatic maintenance | No last-access times (`fsutil behavior set disablelastaccess 1`). No defrag: neither SysMain's boot optimization (`EnableAutoLayout` 0) nor the scheduled defrag (its task off, and kept off). No swap assessment (SysMain's task, which runs WinSAT's disk test). And .NET's queued native images compiled. So clients don't each do it into their own child disks ([clients](clients.md#automatic-maintenance)). `generalize.ps1` does it before sysprep, in a build and in a change. Since `golden-v10` |
| Sysprep | Generalised for other hardware (no `/mode:vm`), keeping every installed driver and device. A client's first boot takes a random name, or the one New-Client gives it, and its own SID, with no questions |
| First boot | A WinPE, `Windows\Setup\Diskless\firstboot.wim`, as Windows Boot Manager's default: on a client's first boot it makes the client's NIC a boot NIC, sets the default back to Windows, and restarts ([clients](clients.md#the-first-boot)). Since `golden-v5` |

## How a build works

```
image/build.sh <N>                                                    PC, WSL
 1 vm-dl-san-1   blank golden-v<N>.vhdx on target "build", which accepts only dl-build-1's IQN
 2 vm-dl-dc-1    the ADK and WinPE with the NIC drivers, and the first-boot WinPE (once); the install share with the
                 media and drivers (once); this build's answer files and first-boot files, a new password for the
                 share's account, and for dl-build-1 its boot script for setup, its WinPE job and a DHCP reservation
 3 dl-build-1    PXE ─▶ snponly.efi ─▶ clients/<mac>.ipxe ─▶ build.ipxe, setup: clear the gateway, which iPXE would
                 put in the iBFT; sanhook the build disk; boot WinPE (wimboot)
                 WinPE fetches jobs/<mac>.cmd: map \\<dc>\install, wait for the disk, run setup onto it (/noreboot),
                 copy the first logon's files, power off
 4 PC            dl-build-1's boot script for windows
 5 dl-build-1    PXE ─▶ snponly.efi ─▶ build.ipxe, windows: sanboot the build disk ─▶ setup finishes
                 ─▶ firstlogon.ps1 ─▶ restart ─▶ generalize.ps1: the clients' maintenance settings, .NET's native
                 images, sysprep, the clients' first boot, then power off
 6 vm-dl-san-1   the seal: take golden-v<N> off the target, check that it's generalised and has the first boot, make
                 the driver pack's NIC drivers boot drivers, make it read-only
 7 vm-dl-dc-1    remove the build's files, and disable the share's account (also when the build fails)
```

- **The build VM,** `dl-build-1`, is an empty diskless VM like the clients, with one NIC, an Intel e1000e ([lab/lab.auto.tfvars](../lab/lab.auto.tfvars)). Its boot script and job exist only during a build; otherwise it gets the menu for machines that aren't clients.
- **WinPE** is the ADK's, 10.1.26100.9457. It has WMI and SecureStartup for Windows 11's setup, PowerShell, and the driver pack's NIC drivers. wimboot boots it from `http://<dc>/boot/winpe/`, with the BCD and `boot.sdi` from the ADK's WinPE media.
- **WinPE's jobs.** WinPE's own `startnet.cmd` ([image/winpe/startnet.cmd](../image/winpe/startnet.cmd)) fetches `http://<dc>/boot/jobs/<mac>.cmd` for its MAC and runs it. The build's job is [image/winpe/build.cmd](../image/winpe/build.cmd). Without a job, WinPE stops at a prompt, for recovery.
- **The first-boot WinPE** is the same WinPE with another startup, which runs a client's first boot from the client's disk ([image/winpe/startnet-firstboot.cmd](../image/winpe/startnet-firstboot.cmd)). `prepare.ps1` makes it as `winpe/firstboot.wim` and puts it on the share with the build's files; WinPE copies it into the new Windows, and `generalize.ps1` adds its boot entry once sysprep is done ([clients](clients.md#the-first-boot)). The entry is made there, by the running Windows, because bcdedit on the storage server, with the image mounted, would tie it to the VHDX file.
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
- **Setup makes the iBFT's NIC, the build VM's, a boot NIC of the new Windows,** once it can match it to one of WinPE's (`NICs in iBFT: 1; NICs resolved: 1` in `setupact.log`). It imports the driver package that WinPE uses into the new Windows and *reflects it as critical* (`Driver Install ... Driver Result: [0x0]`), which registers it in the image's `SYSTEM` hive and creates its service; then it runs `dism /Add-NetAdapter` for it (log: `Windows\Panther\iscsi_boot_net.log`). The answer file adds the driver pack in the offlineServicing pass, which setup applies just before. Setup does this for up to two NICs in the iBFT ([below](#setup-takes-two-nics-from-the-ibft)); the seal makes the rest of the pack's NIC drivers boot drivers ([below](#how-the-seal-makes-nic-drivers-boot-drivers)).
- **What a sealed image boots with:**

  | Service | Start | `BootFlags` |
  |---|---|---|
  | `e1iexpress`: the pack's Intel 82574L driver, 12.15.22.6 | 3 (on demand) | 1: loads at boot when booting from the network. From its INF |
  | `vmxnet3ndis6`: the pack's vmxnet3 driver, 1.9.21.0 | 3 | 1. The seal sets it: vmxnet3's INF doesn't |
  | `netkvm`: virtio's NIC driver, 100.103.104.30200 (virtio-win 0.1.302) | 3 | 1. The seal sets it. It runs from the driver store |
  | `iScsiPrt`: the iSCSI initiator | 3 | 1 |
  | `Tcpip` | 0 (at boot) | 1 |

- **Logs when something fails:** WinPE's job prints the routes, the TCP state on port 3260 and the boot session if the disks don't appear, and setup's errors if setup fails.

## NIC independence

Found in the [plan's test](../PLAN.md#nic-independence), 2026-10-11; the seal's NIC step since 2026-10-13.

**A NIC boots the image only if two things are in it:**
1. **Its driver package, reflected as critical:** in the image's `SYSTEM` hive (`DriverDatabase`, with the package's configurations), and its service. The kernel then sets up a device of that model while it boots, before any disk is there. Setup does this for the build VM's NIC, and the seal for every other NIC driver in the driver pack ([below](#how-the-seal-makes-nic-drivers-boot-drivers)). DISM on its own, and the answer file's driver pack, only *stage* network drivers: in the `DRIVERS` hive, which the kernel can't read until the boot disk is there, with no configuration.
2. **A network interface for that device, at its PCI location:** what `dism /Add-NetAdapter` writes, binding TCP/IP to it at boot. It needs the live NIC (`/HostAdapter`), and keys the interface to the NIC's location path, such as `PCIROOT(0)#PCI(1E00)#PCI(0100)#PCI(1200)`.

Without the first, Windows stops with INACCESSIBLE_BOOT_DEVICE at once; without the second, a few minutes into the boot.

**Device identity.** Windows names a PCI device by its model and its location, or by a PCIe serial number where the device has one. Proxmox puts a q35 VM's NICs behind a PCI bridge, where QEMU's e1000e and vmxnet3 have no serial number, so `net0` is the same device in every VM with the same model: `...\5&2490727a&0&9008F0`. Sysprep keeps installed devices (`PersistAllDeviceInstalls`), so the build NIC's device and interface are in the image already. Any other NIC is a new device: another model, another slot, and physical machines.

**So each client's NIC needs its interface made once, unless it's the build NIC's model at the build NIC's slot:** WinPE on the client, with its disk attached, runs `/Add-NetAdapter` for its NIC on that disk. The test did it with WinPE from the network (the `netadapter` variant, [image/winpe/netadapter.cmd](../image/winpe/netadapter.cmd)); since `golden-v5`, the image does it itself on each client's first boot, with a WinPE it carries ([clients](clients.md#the-first-boot)).

**And each NIC family needs its driver package reflected: the seal does it for every NIC driver in the driver pack** ([below](#how-the-seal-makes-nic-drivers-boot-drivers)). A package covers every device its INF lists:

| Driver | Its package | What it covers |
|---|---|---|
| Intel, the build VM's NIC's | `net1ix64.inf` 12.15.22.6, from 2016: a Microsoft-published build of Intel's 1 GbE driver. Reflected by setup | Intel 82574L (`PCI\VEN_8086&DEV_10D3`), QEMU's e1000e. And physical Intel 1 GbE NICs: 82579, I217, I218, the early I219 revisions, I210/I211, I350, 82575/82576/82580. Not later I219 revisions, I225/I226 or 10 GbE. Check a NIC's PCI ID against the INF |
| VMware's vmxnet3 | vmxnet3 1.9.21.0. Reflected by the seal | VMware's virtual adapter (`PCI\VEN_15AD&DEV_07B0`), which Proxmox VMs can have too |
| virtio's NetKVM | `netkvm.inf` from virtio-win 0.1.302. Reflected by the seal | QEMU's virtio-net, legacy and modern (`PCI\VEN_1AF4&DEV_1000`, `DEV_1041`) |

**To boot another family,** such as workstations' Realtek, Intel I225/I226 or newer I219 NICs: its driver package in the driver pack ([image/drivers.psd1](../image/drivers.psd1)), and a new build. The NIC itself needn't be in the build. WinPE gets the driver too, which it needs to reach the disk through that NIC on a client's first boot. The seal stops if it can't reflect a package; whether the driver then boots shows on the first machine with that NIC.

**The build NIC isn't virtio:** setup itself fails to reflect virtio's NetKVM 0.1.302 (`Driver Install ... Driver Result: [0x80070001]`, "Windows installation cannot continue because a required driver could not be installed"), so an image built on a virtio NIC fails at setup. The seal reflects the same package without trouble, so virtio clients boot.

[image/nic-test.sh](../image/nic-test.sh) tests a golden image on one client:
- it gives a client a new differencing disk on the image;
- then it applies a variant: `none`, `bootflags`, `bootstart`, `reflect` (the seal's NIC step, for an image sealed before `golden-v11`), or `netadapter` (WinPE on the client runs `/Add-NetAdapter` for its NIC on the disk, and sets `BootFlags` 1 on the NIC's service, copying WinPE's if the image has none);
- then it boots the client, and passes if Windows finishes its first boot within 20 minutes.

The clients had three NIC models for the test: `dl-ws-1` virtio, `dl-ws-2` e1000e, `dl-ws-3` vmxnet3. `dl-ws-1` has had vmxnet3 since phase 3, when the image didn't boot virtio; `golden-v10` and `golden-v11` were tested on it with its NIC switched to each model in turn, keeping its MAC. On an image with the clients' first boot, `golden-v5` and later, every variant starts with that first boot, so `none` is the one to use.

### Results

| Image | Client NIC | `none` | `netadapter` | `reflect` |
|---|---|---|---|---|
| `golden-v1`, built on an e1000e | e1000e, `net0`: the build NIC's model and slot, a new MAC | **Passed,** 2 minutes. The build VM's device and interface, kept by sysprep | | |
| | e1000e, moved to `net1`: a new slot | INACCESSIBLE_BOOT_DEVICE, a few minutes in | **Passed,** 2 minutes. The kernel set up the new device at boot | |
| | virtio, vmxnet3 | INACCESSIBLE_BOOT_DEVICE: their drivers are only staged | INACCESSIBLE_BOOT_DEVICE | |
| `golden-v3` and `golden-v4`, built on an e1000e with vmxnet3 as the second NIC | e1000e, `net0` | **Passed,** 2 minutes | | |
| | vmxnet3, `net0`: the second NIC was `net1` | | **Passed,** 3 minutes | |
| `golden-v10`, built like `golden-v4`, with the clients' first boot | vmxnet3, `net0`: setup's reflection of its package replaced by DISM's | | | **Passed,** 6 minutes |
| | virtio, `net0`: NetKVM, which setup can't reflect | | | **Passed,** 5 minutes. A third NIC family |
| `golden-v11`, built on an e1000e alone; the seal reflected vmxnet3 and NetKVM | vmxnet3, `net0` | **Passed,** 6 minutes | | |
| | virtio, `net0` | **Passed,** 5 minutes | | |
| | e1000e, `net0`: the build NIC's model and slot | **Passed,** 5 minutes | | |

`golden-v3` was built with one-off scripts, `golden-v4` with the ones in this repo. `golden-v1` and `golden-v3` have since been deleted; `golden-v2`, a build whose iBFT had one NIC, too. `golden-v4` was deleted on 2026-10-12: it predates the clients' first boot, and `golden-v5` replaced it ([clients](clients.md#results)). `golden-v5` to `golden-v9` were deleted on 2026-10-13, once the clients were on `golden-v10` ([clients](clients.md#maintenance-results)). `golden-v11` was built by the scripts as they are.

### Setup takes two NICs from the iBFT

Tested 2026-10-13, with one-off scripts. The build VM had three NICs, each reaching a disk of its own through its own address on the storage server: the build's e1000e (`net0`), vmxnet3 (`net1`) and a second e1000e (`net2`). Setup ran in WinPE as in a build, onto a throwaway disk.

| Stage | What it had |
|---|---|
| iPXE | Three NICs and three targets in the iBFT, each target tied to its own NIC. The iBFT allows more than two: version 1.03 sets only a minimum length for the control structure that lists them, and iPXE lengthens it |
| WinPE | The same table among the ACPI tables (`GetSystemFirmwareTable`), and all three disks connected |
| Setup | `NICs in iBFT: 2; NICs resolved: 2`: the e1000e and vmxnet3. Both packages reflected, and `/Add-NetAdapter` for each. Nothing logged about the third |

So setup takes the first two NICs, whatever they are: the third was skipped although its driver package, Intel's, was being reflected for the first. An earlier test, on 2026-10-11, had three families, e1000e, virtio and vmxnet3, and setup again counted two, leaving out vmxnet3, the third. So the build has one NIC, and the seal makes the other NIC drivers boot drivers ([below](#how-the-seal-makes-nic-drivers-boot-drivers)).

### How the seal makes NIC drivers boot drivers

**Why DISM only stages NIC drivers.** Windows keeps each driver package in one of two driver databases: the `SYSTEM` hive's, which the kernel reads while it boots, or the `DRIVERS` hive's, which it can't read until the boot disk is there (`golden-v10`: 274 and 441 packages, DISM's 715 between them). A package goes into the `SYSTEM` hive's, and is *configured* there (its service and a configuration for each device it lists), only if its device class is marked boot critical: the class property `DEVPKEY_DeviceClass_BootCritical`, in the registry as `Control\Class\{class}\Properties\{6a3433f4-5626-40e8-a9b9-dbd9ecd2884b}\0003`. SCSIAdapter has it; Net doesn't. A staged NIC package has neither a service nor a configuration: just its name and version. Setup forces the reflection for the NICs it takes from the iBFT: in `Windows\INF\setupapi.offline.log` it adds WinPE's copy of the package again, into the `SYSTEM` hive's database, and logs "Forcing driver package to be boot critical".

**With the mark on the Net class, DISM does the same.** So the seal ([image/san/seal.ps1](../image/san/seal.ps1), with `Set-BootNicDrivers` in [servers/common.ps1](../servers/common.ps1)) does this in the offline image, for each of the driver pack's NIC packages that's only staged:
1. **The mark:** SCSIAdapter's `0003` copied to the Net class, in the image's `SYSTEM` hive. Admins can't open a class's `Properties` key, so `reg.exe` does it as SYSTEM, through a one-off scheduled task.
2. **The packages:** each removed (`dism /Remove-Driver`) and added again (`/Add-Driver`) from a copy of its files.
3. **The mark removed,** whatever happened. The packages stay where DISM put them.
4. **`BootFlags` 1 on the services of all the NIC packages.** DISM writes a service afresh, without it, and Windows loads a network driver at boot only with it.

A package reflected already, the build NIC's by setup or any by an earlier seal, is left as it is, so a change's seal redoes only what's missing. The seal stops if a package isn't reflected at the end. `golden-v11`'s:
```
== NIC drivers, as boot drivers
NIC driver: net1ix64.inf 12.15.22.6, Surface: reflected
NIC driver: vmxnet3.inf 1.9.21.0, Broadcom Inc.: reflected now
NIC driver: netkvm.inf 100.103.104.30200, Red Hat, Inc.: reflected now
NIC driver service: e1iexpress, BootFlags 1
NIC driver service: netkvm, BootFlags 1
NIC driver service: vmxnet3ndis6, BootFlags 1
```
A client's first boot then makes its interface, as for any other NIC ([clients](clients.md#the-first-boot)).

**Tested first on `golden-v10`,** 2026-10-13, on its disk and clients' disks, before it was in the seal:

| | `SYSTEM` hive's database | Service | Boot |
|---|---|---|---|
| vmxnet3, added by DISM without the mark | No: the `DRIVERS` hive's, with no configuration | Left from before | Not tried |
| vmxnet3, with the mark | Yes, the same 95 keys as setup's reflection. Setup's alone has `SystemCritical` 1 | `vmxnet3ndis6` | **Passed** |
| NetKVM, with the mark | Yes: 78 keys, no error | `netkvm`, its driver run from the driver store | **Passed,** with `/Add-NetAdapter` for it too |

DISM reads the mark from the image: the storage server's own Net class doesn't have it.

**What didn't work:** `bootflags` and `bootstart` change only the services of NICs the image has installed, and copying WinPE's service in isn't reflection, so neither helps a model setup hasn't seen. An undocumented `drvstore.dll` function that setup's reflection is reported to use (`DriverStoreOfflineAddDriverPackageW`) returned "invalid parameter" for every flag value tried, even for the package setup had reflected, and was dropped.

## Changing an image

A new version can also be made from the last one, rather than built: [image/change.sh](../image/change.sh) copies a sealed image, starts the copy on the build VM for the changes, then seals it again. It's for changes made in Windows, such as an application installed by hand. A change to what the build does, in its scripts or driver pack, takes a new build.

```
image/change.sh <N> [<from>]                                                         PC, WSL
 1 vm-dl-san-1   golden-v<N>.vhdx: a copy of golden-v<from>, the newest sealed one unless given, that can be written,
                 on target "build" (image/san/change-disk.ps1)
 2 vm-dl-dc-1    dl-build-1's boot script for windows, and its reservation (image/dc/build-script.ps1)
 3 dl-build-1    PXE ─▶ snponly.efi ─▶ build.ipxe, windows: sanboot golden-v<N> ─▶ the clients' first boot, whose
                 WinPE finds the build VM's NIC in the image already ─▶ Windows sets itself up, with a random name
then the changes, as the image's admin: ssh admin@<the build VM's address>, with the servers' keys; RDP, with
IMAGE_PASSWORD; or its console. Restarts are fine.
image/change.sh <N> --seal
 4 vm-dl-san-1   golden-v<N> isn't sealed, and the build VM runs it
 5 dl-build-1    over SSH (image/windows/reseal.ps1): what a build leaves in C:\Windows\Setup\build, sysprep.xml with
                 the image's password, generalize.ps1 and the clients' first boot; generalize.ps1 at the next startup;
                 restart ─▶ the clients' maintenance settings, .NET's native images, sysprep, the first boot's boot
                 entry again, power off
 6 vm-dl-san-1   the seal, as for a build (image/san/seal.ps1): generalised, the first boot there, the NIC drivers,
                 read-only
 7 vm-dl-dc-1    dl-build-1's boot script removed
```

- **What a change keeps:** everything in the image, the reflected NIC drivers and the build NIC's interface among them, and its first-boot WinPE. The seal checks the NIC drivers again, and reflects any that's only staged, such as one added during the change. The first-boot step itself, `firstboot.ps1`, is the repo's: the image takes the current one. So is the seal, `generalize.ps1`.
- **A change goes on until it's sealed.** If the build VM goes off before `--seal`, `image/change.sh <N>` starts it on the same copy again, with the changes made so far. To drop a change, `image/remove.sh <N>` once the build VM is off.
- **Clients don't see it** until `clients/update-clients.sh <N>` moves them to it ([clients](clients.md#updating-clients)). The image it was copied from stays as it is, for the clients still on it.
- **Each change generalises the image once more,** and each leaves something behind: the logs and profile of the change's own session, for one. A new build from time to time starts clean.

From this repo in WSL, with `IMAGE_PASSWORD` in `.env`:
```sh
. ~/.config/proxmox/diskless.env
image/change.sh 6                # golden-v6, from the newest sealed image, running on the build VM: about 8 minutes
ssh admin@10.31.1.250            # the changes, as admin; or RDP, or its console
image/change.sh 6 --seal         # about 5 minutes; then clients/update-clients.sh 6
```
`golden-v6`'s change was [image/windows/iscsi-timeouts.ps1](../image/windows/iscsi-timeouts.ps1), run through the same SSH connection the scripts use: 13 minutes in all. `golden-v7` to `golden-v10` had no change by hand: `--seal` straight after the start, each for a new part of the seal's maintenance step ([clients](clients.md#automatic-maintenance)).

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
| Only the build NIC's model booted the image ([above](#nic-independence)) | The client's interface made by WinPE, and the NIC drivers reflected by the seal |
| Setup aborted at virtio's driver: "a required driver could not be installed" (0x80070001) | An Intel build NIC. The seal reflects virtio's driver |
| Three NICs in iPXE's iBFT, two in setup's log: setup takes the first two ([above](#setup-takes-two-nics-from-the-ibft)) | The seal reflects NIC drivers with DISM, so the build has one NIC. Before `golden-v11` the build had a second, for setup, with a target and storage server address of its own and the full iPXE to drive both NICs |
| `reg.exe`, as admin, couldn't open the Net class's `Properties` key: "Access is denied" | The seal writes the boot-critical mark as SYSTEM, through a scheduled task |
| Adding a NIC driver again with DISM wrote its service without `BootFlags` | The seal sets it |
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

**To change WinPE,** for example after a change to the driver pack or its startup: delete `C:\BootFiles\winpe` on the domain controller, and the next build makes it again, the first-boot WinPE with it. Images already built keep the first-boot WinPE they were built with. **To take a new driver release:** change its entry in `drivers.psd1`, and delete its folder in `C:\Install\drivers` and `C:\BootFiles\winpe`. **To boot another NIC family:** its driver in `drivers.psd1`, then delete `C:\BootFiles\winpe` and build ([above](#nic-independence)).
