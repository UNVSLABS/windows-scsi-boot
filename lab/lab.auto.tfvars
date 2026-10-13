# This environment's values (PLAN.md, Target environment). Change them for yours.

node          = "srv-pve-1"
pool          = "diskless" # made by pve-setup.sh, with the user the token belongs to
datastore     = "local-zfs"
iso_datastore = "local"
bridge        = "vmbr0"
vlan          = 31 # the flat network: no DHCP but the domain controller's, gateway 10.31.0.1
prefix_length = 16
gateway       = "10.31.0.1"
template_vmid = 9021 # tpl-win2025, from the lab repo's images/windows/

# VMIDs 5000-5099. Servers on 10.31.0.x, clients' DHCP reservations on 10.31.1.x.
servers = {
  "vm-dl-dc-1" = {
    vm_id = 5010, address = "10.31.0.10", cores = 2, memory = 4096, data_disk = 0
    iso   = "SW_DVD9_WIN_ENT_LTSC_2024_64-BIT_ENGLISH_MLF_X23-70046.ISO" # for the install share
  }
  "vm-dl-san-1" = {
    vm_id = 5020, address = "10.31.0.20", cores = 4, memory = 8192, data_disk = 200 # golden images and child disks
    iso   = ""
  }
}

# The clients (clients/clients.csv). The golden image boots every NIC model whose driver is in its driver pack (PLAN.md,
# NIC independence; docs/image.md): e1000e, vmxnet3 and virtio. The build NIC's model at net0 needs nothing on its first
# boot.
clients = {
  "dl-ws-1" = { vm_id = 5031, address = "10.31.1.1", cores = 2, memory = 4096, nic_model = "vmxnet3" }
  "dl-ws-2" = { vm_id = 5032, address = "10.31.1.2", cores = 2, memory = 4096, nic_model = "e1000e" }
  "dl-ws-3" = { vm_id = 5033, address = "10.31.1.3", cores = 2, memory = 4096, nic_model = "vmxnet3" }
}

# Builds golden images on the build target, through WinPE (image/build.sh). Its reservation is at the top of the range.
# An Intel NIC: setup makes the build's NIC a boot NIC of the image, and fails at that for virtio's (docs/image.md).
build_vms = {
  "dl-build-1" = { vm_id = 5030, address = "10.31.1.250", cores = 4, memory = 4096, nic_model = "e1000e" }
}
