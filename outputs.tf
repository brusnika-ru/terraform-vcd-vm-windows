output "vm_name" {
  value = data.vcd_vapp_vm.vm.network[0].ip
}
