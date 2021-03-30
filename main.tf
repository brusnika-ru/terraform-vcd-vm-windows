data "vcd_edgegateway" "edge1" {
  name = var.vcd_edge_name
}
data "vcd_vapp" "vApp" {
  name = var.vapp_name
}
data "vcd_vapp_vm" "vm" {
  vapp_name  = data.vcd_vapp.vApp.name
  name       = var.vm_name
  depends_on = [vcd_vapp_vm.vm, vcd_vm_internal_disk.vmStorage]
}

locals {
  storage = flatten([
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

  mounts_group = { for mount in local.storage : mount.name => tonumber(mount.size)... }
  mounts = zipmap([ for k,v in local.mounts_group : k], [for v in local.mounts_group : sum(v) ])

  hot_add = var.vm_cpu != "8" ? true : false

  dnat_port_ssh = random_integer.dynamic_ports.result
  dnat_orig_ip  = data.vcd_edgegateway.edge1.default_external_network_ip

  ssh_ip   = local.dnat_orig_ip
  ssh_port = local.dnat_port_ssh
}

# Рандомный порт для проброса SSH
resource "random_integer" "dynamic_ports" {
  min = 49152 
  max = 65535
}

# Создание проброса SSH порта во вне
resource "vcd_nsxv_dnat" "dnat_ssh" {
  edge_gateway = var.vcd_edge_name 
  network_name = var.ext_net_name
  network_type = "ext"

  enabled         = true
  logging_enabled = true
  description     = "DNAT rule for SSH ${var.vm_name}"

  original_address   = local.ssh_ip
  original_port      = local.ssh_port

  translated_address = var.vm_net[0].ip
  translated_port    = 22
  protocol           = "tcp"
}

# Создание виртуальной машины
resource "vcd_vapp_vm" "vm" {
  vapp_name           = data.vcd_vapp.vApp.name
  name                = var.vm_name
  catalog_name        = var.catalog_name
  template_name       = var.template_name
  vm_name_in_template = var.vm_name_template
  memory              = var.vm_memory
  cpus                = var.vm_cpu
  cpu_cores           = var.vm_cpu
  
  cpu_hot_add_enabled    = local.hot_add
  memory_hot_add_enabled = local.hot_add

  prevent_update_power_off = true

  dynamic "network" {
    for_each = var.vm_net
    
    content {
      type               = "org"
      name               = network.value["name"]
      ip                 = network.value["ip"]
      ip_allocation_mode = "MANUAL"
    }
  }

  customization {
    force      = false
    enabled    = true
    change_sid = true
    
    allow_local_admin_password          = true
    auto_generate_password              = true
    must_change_password_on_first_login = false
  }

  metadata = local.mounts
}

# Пауза после создания машины, 5 минут
resource "time_sleep" "wait_5_minutes" {
  depends_on = [vcd_vapp_vm.vm]

  create_duration = "5m"
}

# Добавление файла для управления дисками
resource "null_resource" "manage_disk" {
  depends_on = [time_sleep.wait_5_minutes]

  connection {
    type        = "ssh"
    host        = local.ssh_ip
    port        = local.ssh_port
    user        = var.ssh_user
    private_key = file(var.ssh_key)
    agent       = false
  }

  provisioner "file" {
    source      = "../modules/vm_win/files/createdisk.ps1"
    destination = "/Windows/Temp/createdisk.ps1"
  }
  provisioner "file" {
    source      = "../modules/vm_win/files/resizepart.ps1"
    destination = "/Windows/Temp/resizepart.ps1"
  }
}

# Создание виртуального диска и присоединение к ВМ
resource "vcd_vm_internal_disk" "vmStorage" {
  for_each = {
    for disk in local.storage : "${disk.type}.${disk.name}.${disk.unit}" => disk
  }

  vapp_name       = var.vapp_name
  vm_name         = var.vm_name
  bus_type        = "paravirtual"
  size_in_mb      = (each.value.size * 1024)
  bus_number      = each.value.bus
  unit_number     = each.value.unit
  storage_profile = each.value.type
  
  depends_on = [null_resource.manage_disk]

  provisioner "local-exec" {
    command = "ssh -tt -p ${local.ssh_port} -i ${var.ssh_key} ${var.ssh_user}@${local.ssh_ip} 'powershell.exe -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\createdisk.ps1 ${self.bus_number} ${self.unit_number} ${each.value.name}'"
  }
}

# Расширение раздела при изменении размера диска
resource "null_resource" "extend_partitions" {
  triggers = {
    vm_disk_ids = join(",",data.vcd_vapp_vm.vm.internal_disk[*].size_in_mb)
  }
  provisioner "local-exec" {
    command = "ssh -p ${local.ssh_port} -i ${var.ssh_key} ${var.ssh_user}@${local.ssh_ip} 'powershell.exe -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\resizepart.ps1'"
  }
}
