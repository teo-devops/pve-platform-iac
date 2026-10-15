# main.tf — la imagen base y las VMs/clusters que salen de requests/.
#
# Nadie edita este fichero para pedir infraestructura: cada VM o cluster es un
# YAML en requests/ (requests.tf los lee y los valida).

# Imagen base, una copia por nodo (sin almacenamiento compartido asumido).
#
# INMUTABLE (docs/seguridad.md, R-05): URL de una release FECHADA y su sha256
# exacto, de platform.yaml. Proxmox comprueba el checksum al descargar y falla si no
# coincide. `make image-pin` cambia la release verificando la firma de SHA256SUMS.
#
# content_type = "import" + extension .qcow2: el disco de la VM se importa con
# import_from, por la API (sin SSH a los nodos; modules/vm).
#
# El nombre lleva la fecha: subir de release crea un fichero nuevo y borra el
# anterior. Las VMs existentes no se tocan (ignore_changes en modules/vm); su disco
# ya es una copia independiente.
resource "proxmox_download_file" "base_image" {
  for_each = local.nodes

  node_name    = each.key
  datastore_id = local.platform.proxmox.image_datastore
  content_type = "import"
  file_name    = "ubuntu-24.04-noble-${local.platform.image.release}.qcow2"

  url                 = local.platform.image.url
  checksum            = local.platform.image.sha256
  checksum_algorithm  = "sha256"
  verify              = true # TLS al descargar desde cloud-images.ubuntu.com
  overwrite           = false
  overwrite_unmanaged = false
  upload_timeout      = 1800
}

locals {
  image_ids = { for n, f in proxmox_download_file.base_image : n => f.id }
  node_list = keys(local.nodes)
}

module "k3s_cluster" {
  source   = "./modules/k3s-cluster"
  for_each = local.clusters

  cluster_name = each.key
  pool         = each.value.pool
  flavor_size  = each.value.flavor_size
  worker_count = each.value.worker_count
  vmid_base    = each.value.vmid_base
  ip_base      = each.value.ip_base
  tags         = ["iac", "p-${each.value.project}", "k3s"]

  network_prefix    = local.net.prefix
  nodes             = local.node_list
  flavors           = local.flavors
  bridge            = local.platform.proxmox.bridge
  vlan_tag          = try(local.platform.proxmox.vlan_tag, null)
  gateway           = local.net.gateway
  network_cidr_bits = local.net.cidr_bits
  dns_servers       = try(local.net.dns, [])
  datastore_id      = local.platform.proxmox.datastore
  template_file_ids = local.image_ids
  ci_user           = var.ci_user
  ssh_keys          = local.ops_keys
}

module "standalone_vm" {
  source   = "./modules/vm"
  for_each = local.standalone_vms

  name      = each.key
  node_name = local.node_list[each.value.vmid % length(local.node_list)]
  vmid      = each.value.vmid
  pool_id   = each.value.pool
  cores     = local.flavors[each.value.flavor].cores
  memory    = local.flavors[each.value.flavor].memory
  disk_size = local.flavors[each.value.flavor].disk
  tags      = ["iac", "p-${each.value.project}", each.value.profile]

  ip_address        = each.value.ip
  bridge            = local.platform.proxmox.bridge
  vlan_tag          = try(local.platform.proxmox.vlan_tag, null)
  gateway           = local.net.gateway
  network_cidr_bits = local.net.cidr_bits
  dns_servers       = try(local.net.dns, [])
  datastore_id      = local.platform.proxmox.datastore
  template_file_id  = local.image_ids[local.node_list[each.value.vmid % length(local.node_list)]]
  ci_user           = var.ci_user
  ssh_keys          = local.ops_keys
}
