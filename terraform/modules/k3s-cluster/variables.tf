variable "cluster_name" {
  type = string
}

variable "pool" {
  description = "Pool del proyecto (projects.yaml)"
  type        = string
}

variable "flavor_size" {
  description = "Familia de catalog/flavors.yaml: usa <familia>-master y <familia>-worker"
  type        = string
}

variable "worker_count" {
  type = number
}

variable "vmid_base" {
  description = "VMID del master; los workers usan los siguientes"
  type        = number
}

variable "ip_base" {
  description = "Ultimo octeto del master; los workers usan los siguientes"
  type        = number
}

variable "network_prefix" {
  description = "Tres primeros octetos de la red de las VMs (p. ej. 192.168.50)"
  type        = string
}

variable "nodes" {
  type = list(string)
}

variable "flavors" {
  type = map(object({ cores = number, memory = number, disk = number }))
}

variable "bridge" {
  type = string
}

variable "vlan_tag" {
  type    = number
  default = null
}

variable "gateway" {
  type = string
}

variable "network_cidr_bits" {
  type = number
}

variable "dns_servers" {
  type = list(string)
}

variable "datastore_id" {
  type = string
}

variable "template_file_ids" {
  description = "Nodo -> id de la imagen descargada en ese nodo"
  type        = map(string)
}

variable "ci_user" {
  type = string
}

variable "ssh_keys" {
  type = list(string)
}

variable "tags" {
  type    = list(string)
  default = []
}
