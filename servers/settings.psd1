# This environment's values for the Windows servers (PLAN.md, Target environment). Change them for yours. The
# addresses must match lab/lab.auto.tfvars.
@{
  DomainName   = 'diskless.adl.unvslab.com'
  NetbiosName  = 'DISKLESS'
  DcAddress    = '10.31.0.10'
  SanAddress   = '10.31.0.20'
  Gateway      = '10.31.0.1'     # also where the domain controller forwards DNS queries outside the domain
  Network      = '10.31.0.0/16'  # /8, /16 or /24, for the reverse DNS zone
  SubnetMask   = '255.255.0.0'   # the same network, for the DHCP scope

  # One DHCP scope. Clients' reservations take 10.31.1.x, kept out of the dynamic pool; other machines lease 10.31.2.x
  ScopeStart    = '10.31.1.1'
  ScopeEnd      = '10.31.2.254'
  ReservedStart = '10.31.1.1'
  ReservedEnd   = '10.31.1.255' # in a /16, .255 is a host address too

  BootFiles    = 'C:\BootFiles'    # on the domain controller, served as http://<DcAddress>/boot/
  TftpRoot     = 'C:\RemoteInstall' # WDS's, which its TFTP server serves
  SanDataDrive = 'D'               # on the storage server: images and child disks under D:\iSCSI

  # The golden image (image/, docs/image.md)
  InstallShare = 'C:\Install'      # on the domain controller, shared as \\<DcAddress>\install for WinPE
  ShareAccount = 'winpe'           # the domain account WinPE maps the share with. Enabled only during a build
  ImageIndex   = '1'               # Windows 11 Enterprise LTSC 2024, in the media's install.wim
  ProductKey   = 'M7XTQ-FN8P6-TTKYV-9D4CC-J462D' # its KMS client key (learn.microsoft.com, "KMS client activation")
  ImageSizeGB  = '64'              # the golden image's size; the VHDX grows as it's written
  ImageUser    = 'admin'           # the image's local administrator, with IMAGE_PASSWORD from .env
  Locale       = 'en-AU'           # formats and keyboard
  UILanguage   = 'en-US'           # display: one the media has
  TimeZone     = 'Cen. Australia Standard Time'
  BuildVm      = 'dl-build-1'      # the Proxmox VM that builds images (lab/lab.auto.tfvars)
  IqnPrefix    = 'iqn.2026-10.com.unvslab.adl.diskless' # initiators are <IqnPrefix>:<VM name>

  # A second NIC family the image boots through (docs/image.md, NIC independence): the build VM has it as net1 while
  # setup runs in WinPE, reaching a second target through the storage server's second address, so that setup makes it a
  # boot NIC of the image too. One: Windows reads two NICs from the iBFT. vmxnet3 is a stand-in for a second family of
  # physical NICs, which would need the NIC passed through to the build VM. '' for none, and SanSecondAddress '' too
  # (docs/image.md, Building for one NIC family).
  BuildSecondNic    = 'vmxnet3'
  BuildSecondNicMac = '02:00:0A:1F:01:FC' # 10.31.1.252's, as lab/main.tf makes MACs. It leases from the dynamic pool
  SanSecondAddress  = '10.31.0.21'        # on the storage server's NIC as well, never a source address
}
