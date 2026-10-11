# Research: installing Windows onto iSCSI from WinPE

Written 2026-10-11, before deciding whether to abandon the WinPE route for a local-disk build ([image.md](image.md#blocked-winpe-doesnt-connect-the-iscsi-disk)). It combines web research (iPXE docs, mailing list and forum, GitHub discussions, Microsoft docs, first-hand reports) with checks made on the lab servers the same day. Untracked working notes: fold what matters into image.md once the next test has run.

## Summary

The previous session's diagnosis was one layer too deep. The evidence says WinPE did read the iBFT and did create the boot session, but its TCP connection to the target never completed. The most likely cause, which the previous session did not try, is the gateway that iPXE wrote into the iBFT: Windows routes iSCSI traffic to the target through the iBFT's gateway even when the target is on the same subnet. The fix that iPXE's own documentation and three independent reports give is one line in the iPXE script before `sanhook`:

```
set net0/gateway 0.0.0.0
```

Two other things the previous session hit have known explanations:

- **The NIC driver does not need to be boot-start for WinPE itself.** A 2025 report with the same chain (UEFI, iPXE `sanhook`, wimboot, ADK WinPE, Intel driver merely injected with DISM) connected its iBFT disks after `wpeinit`. So the `BootFlags`, `BootDriverFlags` and `ipxe.efi` experiments were aimed at the installed OS's problem, not WinPE's.
- **The iSCSI Initiator service not starting is a separate, known WinPE bug** since Windows 10 2004, with a documented workaround. Its `ServiceDll` is normal: the `C:\WINDOWS` reading came from inspecting the WIM's hive on the domain controller, where PowerShell expanded `%SystemRoot%`. The service is only needed for manual logins and diagnostics anyway; the kernel driver makes the iBFT connection.

The local-disk fallback does not avoid this problem: writing the boot NIC into the image (`dism /Add-NetAdapter`, [image/winpe/netadapter.cmd](../image/winpe/netadapter.cmd)) must run from a WinPE that has the iSCSI disk attached. So the WinPE connection is on the critical path either way, and it is worth one more build with the gateway line before changing course.

## What the lab shows

Checked on 2026-10-11, read-only:

| Where | What | Means |
|---|---|---|
| Storage server, `Microsoft-Windows-iSCSITarget-Service/Admin` | Every build attempt shows the same pattern: initiator `dl-build-1` logs on (event 20) and off (event 21) for the failed `sanboot`, logs on again for `sanhook`, and logs off 6–26 s later, when wimboot hands over to WinPE. Then nothing. No refused login (events 22 or 40) in the whole log | WinPE never completed a TCP connection. The target's IQN restriction, CHAP and the stale-session theory can't be the cause: a refused login would be logged |
| Storage server | Target `build` listening on 10.31.0.20:3260, firewall rule `iSCSI Target (TCP-In)` enabled, status `NotConnected` | Server side is fine |
| WinPE image (`C:\BootFiles\winpe\boot.wim`, 10.0.26100.1) | `iscsicli.exe`, `iscsiexe.dll`, `iscsidsc.dll`, `iscsiwmi.dll`, `msiscsi.sys` all present | The ADK's WinPE still has the whole initiator |
| WinPE `Services\MSiSCSI` | `Start=3`, `svchost -k netsvcs -p`, `ServiceDll` is `REG_EXPAND_SZ %systemroot%\system32\iscsiexe.dll`, and `msiscsi` is in the `netsvcs` group | The service definition is normal |
| WinPE `Services\iScsiPrt` | `Start=3`, `BootFlags=1`. `Tcpip` and `AFD` also carry `BootFlags=1` | The kernel iSCSI port driver is promoted to boot-start when an iBFT is present. That is the component that made the session the previous session saw |
| WinPE `Control\BootDriverFlags` | `0x1c` (USB3, SD, USB). No `CriticalDeviceDatabase` key: gone since Windows 8 | As expected for WinPE |
| WinPE driver store | Intel `net1ix64.inf` (two copies: services `e1iexpress` and `e1i68x64`), `netkvm.inf`, `vmxnet3.inf`. All `BootCritical=False`, none has a service key offline. Intel's INF: `StartType=3` plus `HKR,, BootFlags, 0x00010001, 0x1` | DISM stages Net-class drivers; it never reflects them. So no injected NIC driver can be boot-start in WinPE, and that is fine for WinPE (next section) |

## Finding 1: the iBFT gateway

iPXE's WDS/iSCSI how-to says Windows "will always create a static route to the iSCSI target via the default gateway", which breaks when the router does not forward the traffic back onto the originating subnet, and gives the fix: "If booting only from the local subnet, run `set netX/gateway 0.0.0.0` in iPXE before booting from the target." ([ipxe.org/howto/wds_iscsi](https://ipxe.org/howto/wds_iscsi)). iPXE copies the NIC's gateway setting into the iBFT NIC record; with the setting zeroed, the field is left empty ([ibft.c](https://github.com/ipxe/ipxe/blob/master/src/drivers/block/ibft.c)).

Reports with the same symptom and this fix:

- iPXE forum 19465 (2019, Windows 10, VMware e1000, ADK WinPE): `sanhook` reported connected, the initiator showed the session as "reconnecting", diskpart showed no disk. Fixed solely by a `set net0/gateway` line in the boot script.
- iPXE forum 7558 (2014, Windows 7, Hyper-V, Microsoft iSCSI target): disk absent in WinPE until `set net0/gateway 0.0.0.0` was added before `sanhook`.
- iPXE GitHub discussion 1544 (July 2026) and 324 (2023): the same advice from the iPXE regulars, with "check the destination MAC in a packet capture".

Why it fits this lab: DHCP hands the build VM the UniFi gateway 10.31.0.1, iPXE writes it into the iBFT, and Windows sends the SYN for 10.31.0.20 to the gateway's MAC. The gateway would have to forward it back onto VLAN 31, and the reply goes directly from the storage server to the client. A stateful gateway sees only half the flow. Whether it forwards or drops, the target logged no completed login, which matches. iPXE itself connected fine because it routes on-subnet traffic directly.

Microsoft's own definition of what the previous session saw: in `iscsicli SessionList`, "a session that has no connections is not connected to the target and is in a retry state" ([iSCSI Initiator Command Line Reference](https://learn.microsoft.com/en-us/archive/blogs/san/iscsi-initiator-command-line-reference-and-server-core-configuration)). The retry is the kernel driver's; it can only succeed once a route to the target works.

**Consequence for the installed OS.** The installed Windows creates the same host route at every boot, so the line belongs before `sanboot` too, in `client.ipxe`, not only in `build.ipxe`. Clients then boot with no default gateway in the iBFT. Whether Windows still gets one from DHCP on the boot NIC afterwards (the iBFT records the address as DHCP-assigned) is not documented in anything found; it needs checking in phase 3. If not, a persistent default route in the image or a Group Policy script is the fallback.

## Finding 2: who makes the connection, and what WinPE needs

- The kernel driver `iScsiPrt` (`msiscsi.sys`) is demand-start with `BootFlags=1`, and a Microsoft engineer states the network-boot promotion "is set iff IBFT is present" ([OSR thread](https://community.osr.com/t/network-boot-and-bootflags-how-does-windows-know/52391)). Microsoft's 2011 description: the "Boot Parameter driver" reads the iBFT and the initiator connects with its parameters once Windows starts ([storage team blog](https://learn.microsoft.com/en-us/archive/blogs/storageserver/diskless-servers-can-boot-and-run-from-the-microsoft-iscsi-software-target-using-a-regular-network-card)). The user-mode service's documented automatic logins are only persistent targets and SendTargets portals; nothing says it logs in to iBFT targets.
- In a RAM-booted WinPE the NIC driver loads through PnP after boot, and the kernel session connects once the NIC has an address. The 2025 report ([terinstock.com](https://terinstock.com/post/2025/02/Netboot-Windows-11-with-iSCSI-and-iPXE/)) is the closest match to this build: UEFI, `sanhook` of two targets, wimboot, ADK WinPE from the Windows 11 24H2 kit, Intel driver added with `dism /add-driver`, nothing else. "wpeinit ran automatically, configured the NIC, and connected the iSCSI disks." iPXE's maintainer notes WinPE waits up to about 60 s for the iBFT disk at boot, and that the `msiscsi` service should not need starting ([forum 7558](https://forum.ipxe.org/showthread.php?tid=7558)).
- Boot-start matters later, for the installed OS, and that is where the Intel driver's `BootFlags` earns its place: Setup's `/Add-NetAdapter` step failed with `0x80073b01` on virtio `netkvm` in a 2020 report ([forum 22696](https://forum.ipxe.org/showthread.php?tid=22696)), consistent with the decision to build on an Intel NIC.
- Nothing implicates OVMF, `snponly.efi` versus `ipxe.efi`, wimboot or iPXE 2.0: the iBFT is installed through the firmware's ACPI table protocol, and the session's correct IQNs prove Windows parsed it. The only documented UEFI failures are firmware that lacks the protocol (VMware, one ASUS board), which fail loudly in iPXE.

## Finding 3: the service start failure

Since Windows 10 2004, the iSCSI Initiator service fails to start in WinPE with "Access is denied" because it needs a working Event Log, which WinPE runs in a reduced mode ([PhoenixPE issue 30](https://github.com/PhoenixPE/PhoenixPE/issues/30), [NTLite thread](https://ntlite.com/community/threads/workaround-for-win-11-winpe-iscsi-initiator-service-not-starting.3705/)). The documented workaround in `startnet.cmd`, after `wpeinit`:

```
net stop eventlog
reg delete HKLM\SYSTEM\CurrentControlSet\Control\MiniNT /f
net start eventlog
net start msiscsi
```

Not verified on the 26100 ADK by any source, but nothing suggests it was fixed. Use it for diagnostics only:

- `iscsicli SessionList` to see the boot session and its connection count;
- `iscsicli NodeName <iqn>` before any manual login, because WinPE's default initiator name is derived from its random computer name and the target accepts one IQN;
- a manual login is not the fix. Two reports say replacing the iBFT session with a manual one makes Setup refuse the disk as not bootable ([ipxe-devel 2012](https://lists.ipxe.org/pipermail/ipxe-devel/2012-December/002092.html), [forum 7558](https://forum.ipxe.org/showthread.php?tid=7558)), and the service refuses a second session to a target that already has one in retry unless the login passes flag `0x2`.

## Finding 4: what comes after the disk appears

Things the research found at the Setup stage, in the order the build will meet them:

1. **The 24H2 Setup bug is real.** The new Setup closed silently at "Searching for Disks" with iSCSI disks attached; the previous version of Setup worked ([terinstock.com](https://terinstock.com/post/2025/02/Netboot-Windows-11-with-iSCSI-and-iPXE/)). The build already runs `sources\setup.exe`. Right call.
2. **Setup's own iBFT check** refuses a disk with "iSCSI deployment is disabled since no NICs referenced in the iBFT can be resolved to actual NT-visible devices" when the iBFT's NIC does not map to a device WinPE has started. With the Intel driver in WinPE this should pass. `X:\Windows\Panther\setupact.log` shows a "Detected iBFT" line and `DiskInfo` lines with bus type iSCSI when it does.
3. **Setup writes the boot NIC into the image** in a step logged as `DeployIscsiDriversOffline`, which runs `dism /Image:... /Add-NetAdapter /HostAdapter:<WinPE NIC GUID> /BootDriver:ms_tcpip /BootDriver:ms_tcpip6` and checks a "host OS and target OS" support matrix. Its log is `$WINDOWS.~BT\Sources\Panther\iscsi_boot_net.log` on the new disk. It needs the NIC driver in the image's driver store as well as in WinPE (the answer file's `DriverPaths` does that) and WinPE and the target OS from the same servicing family (ADK 26100 and LTSC 2024 are both 26100). Failures seen elsewhere: `0x80073b01` with virtio, `0x800710dd` with a Broadcom driver on a mismatched build.
4. **No local disk during install** so the EFI partition lands on the iSCSI disk. The build VM has none. Microsoft recommends this explicitly.
5. **Pagefile on iSCSI.** Several Windows 10 1903+ reports of `DRIVER_IRQL_NOT_LESS_OR_EQUAL` in `NDIS.SYS` after install, worked around by clearing `PagingFiles` in the offline SYSTEM hive. Single-source and disputed; keep in mind if the first boot from the disk crashes. The plan's fixed pagefile through Group Policy may or may not interact with this.
6. **Client SKUs are unsupported for iSCSI boot** in Microsoft's only statement on it (2008 R2 era), but Windows 10 and 11 installs to iSCSI are reported working through 25H2. Reports on 26H1 preview builds say the handover broke there. LTSC 2024 and Windows Server 2025 share build 26100, so initiator-side fixes and regressions in Server 2025 updates apply to the image: KB5051987 (February 2025) fixed an iSCSI boot "inaccessible boot device" on Server 2025, and an HPE advisory (unverifiable, page empty) claims a November 2025 update stopped the Server 2025 installer seeing iSCSI targets. `--updates` builds should be tested separately from plain ones.

## Finding 5: the local-disk route is not a shortcut

- Microsoft's "the image installed on a local hard drive can not be used for iSCSI boot" is from a 2011 blog about the 2008 R2 era. The official 2008 R2 guide of the same time allows capturing an iSCSI-installed image and deploying it to machines with the same NIC, and the current overview has no such restriction. Conversion is unsupported, not impossible.
- What has to be true in the image: the boot NIC's service boot-start with `BootFlags=1`, `iScsiPrt` boot-start, the NIC bound to TCP/IP as a boot binding (what `/Add-NetAdapter` creates), no non-boot-start filter driver on the NIC, and the same NIC model as at install. On Windows 7 this was the Critical Device Database recipe (the Cyberus series); on Windows 8 and later the database is gone and `/Add-NetAdapter` is the replacement. 2025–2026 reports: a Windows 11 25H2 local install imaged onto a LUN booted after a `BootFlags` fix (two people); others ended in `0x7B` on 26H1 builds, Realtek and I226 NICs, and raw clones.
- Every one of those conversions ran `/Add-NetAdapter` or its registry equivalent from a WinPE with the iSCSI disk attached, which is what [netadapter.cmd](../image/winpe/netadapter.cmd) does. So the fallback needs the WinPE connection working too, unless the image is written server-side with a NIC of the build model attached to the storage server, which is a bigger change.
- Sysprep: Microsoft's own golden-image design is `sysprep /generalize` on the LUN, deployed to the same NIC model. One Windows 10 2004 report: a generalised iSCSI image boots on the same hardware, `0x7B` on different hardware. No source tests `PersistAllDeviceInstalls` for iSCSI. For the NIC-independence test this means the `netadapter` variant is the one with evidence behind it; the `bootflags` and `bootstart` variants alone are unlikely to be enough, because they cannot create the device and binding.
- Differencing VHDX constraints (server limits page): parent and child are absolute local `.vhdx` paths, not on a share or in compressed, sparse or transacted folders; 256 children per parent (not enforced), two levels deep; snapshots of differencing disks unsupported. A read-only parent is practice, not enforced. The plan is consistent with all of it.

## Ruled out, with the reason

| Theory | Why not |
|---|---|
| Target restricted to the wrong IQN, CHAP, firewall | No refused login in the target's log; the rule is enabled; iPXE logs in with the same IQN the boot session shows |
| iPXE's stale session blocking Windows | The target logs iPXE's logoff within seconds of the handover (TCP drop). No stale session exists. iPXE never sends a logout PDU and uses a random ISID, so Windows' login would be a new session anyway; Microsoft lists iPXE among the initiators it tested against this target |
| UEFI, OVMF, wimboot, `snponly.efi` | The session shows the iBFT's IQNs, so the table was installed and parsed. Legacy BIOS would change nothing here and the clients are UEFI by design |
| NIC driver not boot-start in WinPE | WinPE connects after PnP loads the driver (Finding 2). DISM cannot make an injected Net-class driver boot-start anyway (lab check) |
| The service's `ServiceDll` | Normal `REG_EXPAND_SZ` value (lab check); the start failure is the Event Log bug |

## Next build: what to change and what to look at

1. In the build VM's script (`clients/<mac>.ipxe`, written by [image/dc/prepare.ps1](../image/dc/prepare.ps1)) or at the top of [build.ipxe](../boot/build.ipxe) and [client.ipxe](../boot/client.ipxe): `set net0/gateway 0.0.0.0` before any `sanboot` or `sanhook`. WinPE still maps the share by address on the same /16, so nothing else in the job needs the gateway.
2. In [build.cmd](../image/winpe/build.cmd): poll for the disk instead of checking once, since WinPE can take a minute or more after `wpeinit` to attach it. On failure, print `route print`, `ping 10.31.0.20`, and after the Event Log workaround `iscsicli SessionList`, so the console tells the story.
3. On the storage server during the attempt: `netstat -ano | findstr 3260` shows `SYN_RECEIVED` entries if the half-open handshake theory is right, and Windows Server 2025's built-in `pktmon` can capture SYNs from 10.31.1.250 if it isn't.
4. If the disk appears and Setup still refuses it, read `X:\Windows\Panther\setupact.log` for the iBFT lines (Finding 4, item 2). If Setup installs but the first boot from the disk fails, read `iscsi_boot_net.log` on the new disk (item 3) before anything else.
5. Only if the disk still never appears with the gateway cleared: capture on the storage server to see whether SYNs arrive at all, then the media's own `boot.wim` (index 2) with the same driver as a control. The WinPE base is the same, so it is a control, not a likely fix.

## Sources

Primary ones; each finding above links its own.

- [ipxe.org/howto/wds_iscsi](https://ipxe.org/howto/wds_iscsi), [ipxe.org/howto/winpe](https://ipxe.org/howto/winpe), [ipxe.org/cmd/sanhook](https://ipxe.org/cmd/sanhook), [ipxe.org/cmd/sanboot](https://ipxe.org/cmd/sanboot)
- iPXE forum threads [19465](https://forum.ipxe.org/showthread.php?tid=19465), [7558](https://forum.ipxe.org/showthread.php?tid=7558), [22696](https://forum.ipxe.org/showthread.php?tid=22696), [6896](https://forum.ipxe.org/showthread.php?tid=6896); GitHub discussions [1544](https://github.com/ipxe/ipxe/discussions/1544), [324](https://github.com/ipxe/ipxe/discussions/324), [817](https://github.com/ipxe/ipxe/discussions/817)
- [Netboot Windows 11 with iSCSI and iPXE (2025)](https://terinstock.com/post/2025/02/Netboot-Windows-11-with-iSCSI-and-iPXE/)
- Microsoft: [iSCSI Initiator Command Line Reference](https://learn.microsoft.com/en-us/archive/blogs/san/iscsi-initiator-command-line-reference-and-server-core-configuration), [About iSCSI Boot (2008 R2)](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2008-R2-and-2008/ee619722(v=ws.10)), [Creating, Validating, and Testing Boot Images (2008 R2)](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2008-R2-and-2008/ee619769(v=ws.10)), [Diskless servers can boot from the iSCSI Software Target (2011)](https://learn.microsoft.com/en-us/archive/blogs/storageserver/diskless-servers-can-boot-and-run-from-the-microsoft-iscsi-software-target-using-a-regular-network-card), [iSCSI Target Server scalability limits](https://learn.microsoft.com/en-us/windows-server/storage/iscsi/iscsi-target-server-limits), [Specifying driver load order](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/specifying-driver-load-order), [KB976042](https://support.microsoft.com/en-us/help/976042/windows-may-fail-to-boot-from-an-iscsi-drive-if-networking-hardware-is), [Q&A 337717 (Add-NetAdapter log)](https://learn.microsoft.com/en-us/answers/questions/337717/installation-of-hyper-v-2019-on-iscsi-via-bcm5720)
- [OSR: Network boot and BootFlags](https://community.osr.com/t/network-boot-and-bootflags-how-does-windows-know/52391)
- [PhoenixPE issue 30](https://github.com/PhoenixPE/PhoenixPE/issues/30), [NTLite: WinPE iSCSI service workaround](https://ntlite.com/community/threads/workaround-for-win-11-winpe-iscsi-initiator-service-not-starting.3705/)
- Cyberus Technology, Windows on iSCSI parts [1](https://cyberus-technology.de/en/articles/windows-on-iscsi-part1/), [2](https://cyberus-technology.de/en/articles/windows-on-iscsi-part2/), [3](https://cyberus-technology.de/en/articles/windows-on-iscsi-part3/)

The full research notes (four files, about 230 KB, with a URL on every claim) are in this session's scratchpad under `research_notes/WinPE iSCSI install research/`.
