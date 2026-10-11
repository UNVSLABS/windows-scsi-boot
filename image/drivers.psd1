# The driver pack (docs/image.md): drivers that go into WinPE and into the golden image. image/dc/prepare.ps1 downloads
# each once into the install share's drivers\<Name>, checked against its pinned SHA-256. To take a new release, change
# its entry and delete its folder, and C:\BootFiles\winpe so that WinPE is rebuilt with it. Physical NICs' packs go here.
@{
  Drivers = @(
    # virtio: the virtio clients' NIC and the other virtio devices. Fedora publishes no checksum; pinned 2026-10-03, as in the
    # lab repo's images/windows/. From the ISO: each driver's Windows 11 folder, and the QEMU guest agent.
    @{ Name = 'virtio'
       Url = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso'
       Sha256 = '303F7AE40DAD495D6AE474FDC571DF58958A4DBC5C37A522D80F9A203867949D'
       Folders = '*\w11\amd64'
       Tools = 'guest-agent\qemu-ga-x86_64.msi' }
    # Intel 82574L (QEMU's e1000e), the build VM's NIC: 12.15.22.6, from the Microsoft Update Catalog ("Surface - Net -
    # 12.15.22.6", update 156cda9a-c324-463f-ac98-0053703a4036), WHQL-signed. Its INF marks the driver to load when
    # booting from the network (BootFlags 1). Windows 11 has its own 82574L driver, but WinPE doesn't.
    @{ Name = 'intel-82574l'
       Url = 'https://catalog.s.download.windowsupdate.com/c/msdownload/update/driver/drvs/2019/04/0_a11ef9665bab5977ed5a26de5b8f3dd7ef52aa2b.cab'
       Sha256 = 'AB558D1D14921C41251FF157DE250A5B6DEDFB89B5F5E1772060AE5DB3015539' }
    # vmxnet3 1.9.21.0, from the Microsoft Update Catalog ("Broadcom Inc. Net Driver Update (1.9.21.0)"), the build's
    # second NIC (servers/settings.psd1). It stands in for a second family of physical NICs, whose vendor driver would
    # go here. Windows 11 has 1.8.17.0 inbox.
    @{ Name = 'vmxnet3'
       Url = 'https://catalog.s.download.windowsupdate.com/d/msdownload/update/driver/drvs/2026/07/cf7c5218-fd6d-4f0f-b376-dde4c97289ca_604c6fab636da81ba79a6438ddad6f6a89eaadf6.cab'
       Sha256 = '4F8B5E1B18A848819BF2C2D8A8587C79CA2209CB9A648168F843C7423048D47C' }
  )
}
