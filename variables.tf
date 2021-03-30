variable vcd_edge_name {
  default = "brusnika2_EDGE"
}
variable "vapp_name" {
  type = string
}
variable "vm_name" {
  type = string
}
variable "vm_memory" {
  type = number
}
variable "vm_cpu" {
  type = number
}
variable "vm_net" {
  type = list(object({
    name = string
    ip   = string
  }))
}
variable "vm_storage" {
  type = object({
    med = list(object({
      mount_name = string
      mount_size = string
    }))
    ssd = list(object({
      mount_name = string
      mount_size = string
    }))
  })
}
variable "vmuser" {
  type = string
  default = "Administrator"
}
variable "vmpassword" {
  type = string
  default = "Brus123!"
}
variable "ssh_key" {
  type = string
  default = "/home/mshlmv/.ssh/id_cloud-svc"
}
variable "ssh_user" {
  type = string
  default = "cloud-svc"
}
