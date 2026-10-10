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
}
