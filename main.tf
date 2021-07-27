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

  original_address   = local.dnat_orig_ip
  original_port      = local.dnat_port_ssh

  translated_address = var.vm_net[0].ip #!= "" ? var.vm_net[0].ip : data.vcd_vapp_vm.vm.network[0].ip
  translated_port    = 22
  protocol           = "tcp"

}

# Создание правила Firewall для проброса SSH
resource "vcd_nsxv_firewall_rule" "dnat_ssh_firewall" {
  edge_gateway = var.vcd_edge_name

  name = "SSH to ${var.vm_name}"
  
  source {
    ip_addresses = ["any"]
  }

  destination {
    ip_addresses = [local.dnat_orig_ip]
  }

  service {
    protocol = "tcp"
    port     = local.dnat_port_ssh
  }
}

# Создание виртуальной машины
resource "vcd_vapp_vm" "vm" {
  vapp_name           = var.vapp_name
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
      adapter_type       = "VMXNET3"
      ip_allocation_mode = network.value["ip"] != "" ? "MANUAL" : "POOL"
      ip                 = network.value["ip"] != "" ? network.value["ip"] : ""
    }
  }

  # guest_properties = {
  #   "guest.hostname" = "vm1.host.ru"
  # }

  customization {
    force      = false
    enabled    = true
    change_sid = true
    
    allow_local_admin_password = true
    auto_generate_password     = false
    admin_password             = "Brus123!"
    
    must_change_password_on_first_login = false

    # initscript = <<EOF
    # @echo off
    # if "%1%" == "precustomization" (
    # echo Do precustomization tasks
    # ) else if "%1%" == "postcustomization" (
    # echo %DATE% %TIME% > C:\vm-is-ready
    # timeout /t 300
    # powershell -command "Set-NetConnectionProfile -InterfaceAlias 'Ethernet0 2' -NetworkCategory Private"
    # )
    # EOF
  }

  metadata = local.mounts
}

# Пауза после создания машины, 3 минут
resource "time_sleep" "wait_3_minutes" {
  depends_on = [
    vcd_vapp_vm.vm
  ]

  create_duration = "3m"
}

# Добавление файла для управления дисками
resource "null_resource" "manage_disk" {
  depends_on = [
    time_sleep.wait_3_minutes, 
    vcd_nsxv_dnat.dnat_ssh, 
    vcd_nsxv_firewall_rule.dnat_ssh_firewall
  ]

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
  depends_on = [
    null_resource.manage_disk
  ]

  for_each = {
    for disk in local.storages_w_iops : "${disk.type}.${disk.name}.${disk.unit}" => disk
  }

  vapp_name       = var.vapp_name
  vm_name         = var.vm_name
  bus_type        = "paravirtual"
  size_in_mb      = (each.value.size * 1024)
  bus_number      = each.value.bus
  unit_number     = each.value.unit
  iops            = each.value.iops
  storage_profile = each.value.type

  provisioner "local-exec" {
    command = "ssh -tt -p ${local.ssh_port} -i ${var.ssh_key} ${var.ssh_user}@${local.ssh_ip} 'powershell.exe -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\createdisk.ps1 ${self.bus_number} ${self.unit_number} ${each.value.name}'"
  }
}

data "vcd_vapp_vm" "vm" {
  depends_on = [
    vcd_vapp_vm.vm,
    vcd_vm_internal_disk.vmStorage
  ]

  vapp_name  = var.vapp_name
  name       = var.vm_name
}

# Расширение раздела при изменении размера диска
resource "null_resource" "extend_partitions" {
  depends_on = [
    vcd_nsxv_dnat.dnat_ssh,
    vcd_nsxv_firewall_rule.dnat_ssh_firewall
  ]

  triggers = {
    vm_disk_ids = join(",",data.vcd_vapp_vm.vm.internal_disk[*].size_in_mb)
  }

  provisioner "local-exec" {
    command = "ssh -p ${local.ssh_port} -i ${var.ssh_key} ${var.ssh_user}@${local.ssh_ip} 'powershell.exe -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\resizepart.ps1'"
  }
}
