variable "name" {
  type = string
}

variable "node_name" {
  description = "Nodo de Proxmox donde vive la VM (round-robin en main.tf / k3s-cluster)"
  type        = string
}

variable "vmid" {
  type = number
}

variable "cores" {
  type    = number
  default = 2
}

variable "memory" {
  description = "MiB"
  type        = number
  default     = 4096
}

variable "disk_size" {
  description = "GiB"
  type        = number
  default     = 32
}

variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "vlan_tag" {
  description = "null = sin tag (mismo L2 que el bridge)"
  type        = number
  default     = null
}

variable "ip_address" {
  type = string
}

variable "gateway" {
  type = string
}

variable "network_cidr_bits" {
  description = "Bits de mascara de la IP estatica que fija cloud-init"
  type        = number
  default     = 24
}

variable "dns_servers" {
  type    = list(string)
  default = []
}

variable "datastore_id" {
  type = string
}

variable "template_file_id" {
  description = "id <datastore>:import/<fichero> de la imagen descargada (main.tf)"
  type        = string
}

variable "ci_user" {
  type = string
}

variable "ssh_keys" {
  type = list(string)
}

variable "pool_id" {
  description = "Pool del PROYECTO (projects.yaml). El token de apply solo tiene permisos en esos pools."
  type        = string
}

variable "tags" {
  description = "Etiquetas visibles en la UI de Proxmox (proyecto, perfil)"
  type        = list(string)
  default     = []
}
