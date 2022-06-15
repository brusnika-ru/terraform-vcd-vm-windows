# Создание виртуальной машины
resource "vcd_vapp_vm" "vm" {
  vapp_name           = var.vapp
  name                = var.name
  catalog_name        = var.common.catalog
  template_name       = var.common.template_name
  vm_name_in_template = var.template != "" ? var.template : var.common.vm_name_template
  memory              = var.ram
  cpus                = var.cpu
  cpu_cores           = var.cpu >= 10 ? var.cpu / 2 : var.cpu
  
  cpu_hot_add_enabled    = local.hot_add
  memory_hot_add_enabled = local.hot_add

  prevent_update_power_off = true

  dynamic "network" {
    for_each = var.networks
    
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
    
    allow_local_admin_password = false
    auto_generate_password     = false
    
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

data "vcd_vapp_vm" "vm_ip" {
  depends_on = [
    vcd_vapp_vm.vm
  ]

  vapp_name  = var.vapp
  name       = var.name
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
    time_sleep.wait_3_minutes
  ]

  count = var.storages == {} ? 0 : 1

  connection {
    type            = "ssh"
    host            = local.ssh_ip
    port            = local.ssh_port
    user            = var.common.ssh_user
    private_key     = file(var.common.ssh_key)
    agent           = false
    target_platform = "windows"
  }

  provisioner "file" {
    source      = "${path.module}/files/createdisk.ps1"
    destination = "/Windows/Temp/createdisk.ps1"
  }
  provisioner "file" {
    source      = "${path.module}/files/resizepart.ps1"
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

  vapp_name       = var.vapp
  vm_name         = var.name
  bus_type        = "paravirtual"
  size_in_mb      = (each.value.size * 1024)
  bus_number      = each.value.bus
  unit_number     = each.value.unit
  iops            = each.value.iops
  storage_profile = each.value.type

  provisioner "local-exec" {
    command = "ssh -o StrictHostKeyChecking=no -tt -p ${local.ssh_port} -i ${var.common.ssh_key} ${var.common.ssh_user}@${local.ssh_ip} 'powershell.exe -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\createdisk.ps1 ${self.bus_number} ${self.unit_number} ${each.value.name}'"
  }
}

data "vcd_vapp_vm" "vm_disks" {
  depends_on = [
    vcd_vapp_vm.vm,
    vcd_vm_internal_disk.vmStorage
  ]

  vapp_name  = var.vapp
  name       = var.name
}

# Расширение раздела при изменении размера диска
resource "null_resource" "extend_partitions" {
  depends_on = [
    null_resource.manage_disk,
    vcd_vm_internal_disk.vmStorage
  ]

  count = var.storages == {} ? 0 : 1

  triggers = {
    vm_disk_ids = join(",",data.vcd_vapp_vm.vm_disks.internal_disk[*].size_in_mb)
  }

  provisioner "local-exec" {
    command = "ssh -o StrictHostKeyChecking=no -p ${local.ssh_port} -i ${var.common.ssh_key} ${var.common.ssh_user}@${local.ssh_ip} 'powershell.exe -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\resizepart.ps1'"
  }
}

# Пауза после создания машины, 3 минуты
resource "time_sleep" "wait_3_minutes_2" {
  depends_on = [
    vcd_vapp_vm.vm,
    null_resource.extend_partitions
  ]

  create_duration = "3m"
}

resource "null_resource" "run_ansible" {
  depends_on = [
    time_sleep.wait_3_minutes_2
  ]

  triggers = {
    playbook = filebase64("${var.name}.conf.yml")
  }

  provisioner "local-exec" {
    command = "ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -u ${var.common.ssh_user} -i '${local.ssh_ip},' -e 'ansible_port=${local.ssh_port} vm_name=${var.name} vapp_name=${var.vapp} vm_ip=${data.vcd_vapp_vm.vm_ip.network[0].ip}' --key-file ${var.common.ssh_key} ${var.name}.conf.yml"
  }
}
