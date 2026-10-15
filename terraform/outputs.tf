# outputs.tf — lo que consume Ansible (ansible/inventory/generate_inventory.sh) y
# `scripts/iac`. No hay secretos en ninguno.

output "k3s_clusters" {
  value = { for k, v in module.k3s_cluster : k => v.inventory }
}

output "k3s_cluster_meta" {
  description = "Por cluster: proyecto, familia y version de k3s que instala Ansible"
  value = {
    for k, c in local.clusters : k => {
      project     = c.project
      flavor_size = c.flavor_size
      k3s_version = c.k3s_version
    }
  }
}

output "standalone_vms" {
  description = "Por VM suelta: ip, vmid, proyecto, perfil (decide los playbooks) y MVP"
  value = {
    for k, v in module.standalone_vm : k => {
      ip      = v.ip_address
      vmid    = v.vmid
      project = local.standalone_vms[k].project
      profile = local.standalone_vms[k].profile
      mvp     = local.standalone_vms[k].mvp
    }
  }
}

# Quien entra en cada VM (rol base): los miembros de SU proyecto y los admins.
# Nombre de VM -> [{user, github}]. La cuenta Linux es el usuario de GitHub en
# minusculas; las claves, las de https://github.com/<usuario>.keys.
output "vm_access" {
  value = {
    for v in local.all_vms : v.name => [
      for u in distinct(concat(try(local.projects[v.project].members, []), keys(local.people.admins))) : {
        user   = lower(u)
        github = u
      }
    ]
  }
}

output "admins" {
  value = keys(local.people.admins)
}
