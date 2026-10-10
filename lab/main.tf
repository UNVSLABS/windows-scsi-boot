# The lab for diskless Windows boot (PLAN.md): a domain controller and a storage server cloned from a Windows Server
# 2025 template, and empty diskless clients that boot from the network. The environment's values are in
# lab.auto.tfvars. The provider's endpoint and token come from the environment (docs/environment.md):
#   . ~/.config/proxmox/diskless.env && terraform apply

terraform {
  required_version = ">= 1.5"
  required_providers {
    proxmox = { source = "bpg/proxmox", version = "~> 0.114" }
  }
}

provider "proxmox" {}

variable "node" { type = string }
variable "pool" { type = string }
variable "datastore" { type = string }     # VM disks
variable "iso_datastore" { type = string } # install media
variable "bridge" { type = string }
variable "vlan" { type = number }
variable "prefix_length" { type = number } # the flat network's
variable "gateway" { type = string }       # also the servers' DNS until the domain controller runs DNS
variable "template_vmid" { type = number } # Windows Server 2025, sysprepped, OpenSSH with key logins

variable "servers" {
  description = "Windows Servers cloned from the template: name => VMID, static address, size, data disk (GB, 0 for none), ISO"
  type = map(object({
    vm_id     = number
    address   = string
    cores     = number
    memory    = number # MiB
    data_disk = number
    iso       = string # file name on iso_datastore, or "" for none. The provider allows one CD drive
  }))
}

variable "clients" {
  description = "Diskless clients: name => VMID, the address of their DHCP reservation, size, NIC model"
  type = map(object({
    vm_id     = number
    address   = string
    cores     = number
    memory    = number # MiB
    nic_model = string # virtio, e1000e, vmxnet3, ... (PLAN.md, NIC independence)
  }))
}

locals {
  # A fixed MAC per address, 02:00 and then the address in hex, so DHCP reservations and ARP caches survive a rebuild
  mac = { for name, vm in merge(var.servers, var.clients) :
    name => format("02:00:%s", join(":", [for octet in split(".", vm.address) : format("%02X", tonumber(octet))]))
  }
}

resource "proxmox_virtual_environment_vm" "server" {
  for_each        = var.servers
  name            = each.key
  vm_id           = each.value.vm_id
  node_name       = var.node
  pool_id         = var.pool
  tags            = ["diskless", "server"]
  on_boot         = false
  stop_on_destroy = true

  clone {
    vm_id   = var.template_vmid
    full    = true # long-lived: independent of the template
    retries = 3    # two clones at once can time out on local-zfs's storage lock
  }

  # As in the template, so the clone keeps booting through UEFI with its EFI disk and TPM
  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  operating_system { type = "win11" }
  boot_order = ["scsi0"]

  lifecycle {
    # Long-lived: a rebuilt template or new clone settings mustn't replace a running server. Proxmox pins Windows
    # guests to the machine version they were created with (pc-q35-11.0+pve2), which would otherwise show as drift.
    ignore_changes = [clone, machine]
  }

  agent {
    enabled = true
    trim    = true
    # The network has no DHCP yet, so Windows only gets a link-local address. bootstrap-server.sh waits instead.
    wait_for_ip { disabled = true }
  }
  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }
  memory { dedicated = each.value.memory }
  disk {
    datastore_id = var.datastore
    interface    = "scsi0"
    size         = 64 # the template's
    discard      = "on"
    iothread     = true
    ssd          = true
  }
  dynamic "disk" {
    for_each = each.value.data_disk > 0 ? [each.value.data_disk] : []
    content {
      datastore_id = var.datastore
      interface    = "scsi1"
      size         = disk.value
      discard      = "on"
      iothread     = true
      ssd          = true
    }
  }
  dynamic "cdrom" {
    for_each = each.value.iso == "" ? [] : [each.value.iso]
    content {
      interface = "ide2"
      file_id   = "${var.iso_datastore}:iso/${cdrom.value}"
    }
  }
  network_device {
    bridge      = var.bridge
    vlan_id     = var.vlan
    mac_address = local.mac[each.key]
  }
}

# A new clone has no address the PC can reach until it has its static one, so this sets it, and the computer name,
# through the guest agent.
resource "terraform_data" "bootstrap" {
  for_each         = var.servers
  triggers_replace = [proxmox_virtual_environment_vm.server[each.key].id]
  provisioner "local-exec" {
    command = join(" ", [
      "${path.module}/bootstrap-server.sh", var.node, each.value.vm_id, each.key,
      "${each.value.address}/${var.prefix_length}", var.gateway, var.gateway,
    ])
  }
}

resource "proxmox_virtual_environment_vm" "client" {
  for_each  = var.clients
  name      = each.key
  vm_id     = each.value.vm_id
  node_name = var.node
  pool_id   = var.pool
  # No tags: Proxmox checks tag permission on /vms/<id> before a new VM joins the pool, so the pool's ACL can't
  # cover it (PVE::GuestHelpers::assert_tag_permissions). Clones, like the servers, are in the pool by then.
  on_boot         = false
  started         = false # started by hand for tests, to keep srv-pve-1's memory free
  stop_on_destroy = true
  # Made after the servers' full clones, which hold local-zfs's storage lock long enough to time out a new VM's disks
  depends_on = [proxmox_virtual_environment_vm.server]

  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  operating_system { type = "win11" }
  boot_order = ["net0"]

  lifecycle {
    ignore_changes = [machine] # pinned by Proxmox for Windows guests, as for the servers
  }

  # No Secure Boot keys: the stock iPXE snponly.efi is unsigned
  efi_disk {
    datastore_id      = var.datastore
    type              = "4m"
    pre_enrolled_keys = false
  }
  tpm_state {
    datastore_id = var.datastore
    version      = "v2.0"
  }
  # OVMF offers no network boot without a random number generator: since 2025 its network stack needs the entropy
  rng {
    source = "/dev/urandom"
  }
  agent {
    enabled = true # the golden image has the guest agent
    wait_for_ip { disabled = true }
  }
  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }
  memory { dedicated = each.value.memory }
  network_device {
    bridge      = var.bridge
    vlan_id     = var.vlan
    model       = each.value.nic_model
    mac_address = local.mac[each.key]
  }
}

output "servers" {
  value = { for name, vm in var.servers : name => vm.address }
}

output "clients" {
  description = "For clients.csv: name => MAC and the address of its DHCP reservation"
  value       = { for name, vm in var.clients : name => { mac = local.mac[name], address = vm.address } }
}
