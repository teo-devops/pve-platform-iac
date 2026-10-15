# Un cluster k3s: 1 master (server) + N workers (agent). La instalacion de k3s la
# hace Ansible (playbooks/k3s.yml); aqui solo se crean las VMs.
locals {
  master_flavor = var.flavors["${var.flavor_size}-master"]
  worker_flavor = var.flavors["${var.flavor_size}-worker"]
  node_count    = length(var.nodes)

  instance_list = concat(
    [{
      key    = "${var.cluster_name}-master"
      role   = "server" # rol k3s: server = control-plane
      vmid   = var.vmid_base
      octet  = var.ip_base
      flavor = local.master_flavor
      idx    = 0
    }],
    [
      for i in range(var.worker_count) : {
        key    = "${var.cluster_name}-worker-${format("%02d", i + 1)}"
        role   = "agent" # rol k3s: agent = worker
        vmid   = var.vmid_base + i + 1
        octet  = var.ip_base + i + 1
        flavor = local.worker_flavor
        idx    = i + 1
      }
    ]
  )

  instances = { for inst in local.instance_list : inst.key => inst }
}

# El round-robin sobre idx reparte master y workers de un mismo cluster entre los
# nodos disponibles, para no perderlo entero si cae uno (con un solo nodo, todos
# caen en el mismo: es lo esperado en un cluster pequeño).
module "vm" {
  source = "../vm"

  for_each = local.instances

  name         = each.key
  node_name    = var.nodes[each.value.idx % local.node_count]
  vmid         = each.value.vmid
  cores        = each.value.flavor.cores
  memory       = each.value.flavor.memory
  disk_size    = each.value.flavor.disk
  bridge       = var.bridge
  vlan_tag     = var.vlan_tag
  ip_address   = "${var.network_prefix}.${each.value.octet}"
  gateway      = var.gateway
  dns_servers  = var.dns_servers
  datastore_id = var.datastore_id
  pool_id      = var.pool
  tags         = var.tags

  network_cidr_bits = var.network_cidr_bits

  template_file_id = var.template_file_ids[var.nodes[each.value.idx % local.node_count]]

  ci_user  = var.ci_user
  ssh_keys = var.ssh_keys
}

output "inventory" {
  description = "Para el inventario de Ansible: nombre -> ip/vmid/rol k3s"
  value = {
    for k, v in module.vm : k => {
      ip   = v.ip_address
      vmid = v.vmid
      role = local.instances[k].role
    }
  }
}
