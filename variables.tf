variable "catalog_name" {
  type        = string
  description = "Library catalog where placed VM templates"
}

variable "template_name" {
  type        = string
  description = "vApp templete contained VMs"
}

variable "vm_name_template" {
  type        = string
  description = "Name of VM source for deploy"
}

variable vcd_edge_name {
  type        = string
  description = "Name of the edge gateway"
}

variable "ext_net_name" {
  type        = string
  description = "Name of public internet network"
}

variable "vapp_name" {
  type        = string
  description = "Name of vApp to deploy VM"
}

variable "vm_name" {
  type        = string
  description = "A unique name for VM"
}

variable "vm_memory" {
  type        = number
  description = "Size of memory VM in MegaBytes"
}

variable "vm_cpu" {
  type        = number
  description = "Count of CPU cores VM"
}

variable "vm_storage" {
  description = "Size of disks in GigaBytes and name of mount points"
}

variable "types" {
  type = list(object({
    type = string
    iops = number
  }))
  default = [
    {
      type = "vcd-type-med"
      iops = 1000
    },
    {
      type = "vcd-type-ssd"
      iops = 5000
    }
  ]
}

variable "vm_net" {
  description = "Name networks for attach to VM. Manual IP (optional)"
}

variable "ssh_user" {
  type        = string
  description = "Account name for service connect"
}

variable "ssh_key" {
  type        = string
  description = "Path to private key for ssh_user"
}

locals {
  storages = flatten([
    for storage_key, storage in var.vm_storage : [
      for type_key, type in storage : {
        type = "vcd-type-${storage_key}"
        name = type.mount_name
        size = type.mount_size
        bus  = index(keys(var.vm_storage), storage_key) + 1
        unit = type_key
      }
    ]
  ])

  storages_w_iops = flatten([
    for s in local.storages : [
      for t in var.types : merge(s,t) if s.type == t.type
    ]
  ])

  mounts_group = { for mount in local.storages : mount.name => tonumber(mount.size)... }
  mounts       = zipmap([for k, v in local.mounts_group : k], [for v in local.mounts_group : sum(v)])

  hot_add = var.vm_cpu != "8" ? true : false

  dnat_port_ssh = random_integer.dynamic_ports.result
  dnat_orig_ip  = "176.53.182.12"

  ssh_ip   = local.dnat_orig_ip
  ssh_port = local.dnat_port_ssh
}
