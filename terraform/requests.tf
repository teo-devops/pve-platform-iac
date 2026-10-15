# requests.tf — de donde sale lo que Terraform crea, y la segunda barrera de validacion.
#
# Fuentes (todas versionadas, nada de variables):
#   platform.yaml           plataforma: nodos, red, imagen
#   projects.yaml          admins, cuentas de servicio y proyectos (pool, rangos, miembros)
#   catalog/*.yaml         flavors y perfiles
#   requests/vms/*.yaml    una VM suelta por fichero
#   requests/clusters/*.yaml  un cluster k3s por fichero
#
# El nombre del fichero es la clave del for_each (requests/vms/dataspace-demo.yaml ->
# module.standalone_vm["dataspace-demo"]). RENOMBRAR un fichero destruye y recrea
# sus VMs; BORRARLO las destruye.
#
# Las reglas de abajo son las mismas que `scripts/iac check` (que corre antes en
# CI con mensajes mas detallados). Aqui estan por si alguien aplica sin pasar por
# ahi: con una regla rota, el plan se corta antes de tocar nada.

locals {
  repo_root = "${path.root}/.."

  platform = yamldecode(file("${local.repo_root}/platform.yaml"))
  people   = yamldecode(file("${local.repo_root}/projects.yaml"))
  catalog  = yamldecode(file("${local.repo_root}/catalog/flavors.yaml"))
  profiles = yamldecode(file("${local.repo_root}/catalog/profiles.yaml"))

  nodes    = local.platform.proxmox.nodes
  net      = local.platform.network
  projects = local.people.projects
  sizes    = local.catalog.cluster_sizes

  flavors = {
    for k, v in local.catalog.flavors : k => { cores = v.cores, memory = v.memory, disk = v.disk }
  }

  cluster_requests = {
    for f in fileset("${local.repo_root}/requests/clusters", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${local.repo_root}/requests/clusters/${f}"))
  }
  vm_requests = {
    for f in fileset("${local.repo_root}/requests/vms", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${local.repo_root}/requests/vms/${f}"))
  }

  # El pool NUNCA viene de la peticion: lo decide el proyecto. Asi una peticion no
  # puede apuntar al pool de otro proyecto (y el token no tiene permisos fuera de
  # los pools de projects.yaml).
  clusters = {
    for k, r in local.cluster_requests : k => {
      project      = r.project
      pool         = try(local.projects[r.project].pool, null)
      flavor_size  = r.flavor_size
      worker_count = try(r.workers, local.sizes[r.flavor_size].default_workers, 2)
      min_workers  = try(local.sizes[r.flavor_size].min_workers, 1)
      k3s_version  = try(r.k3s_version, local.sizes[r.flavor_size].k3s_version, null)
      vmid_base    = r.vmid_base
      ip_base      = r.ip_base
    }
  }
  standalone_vms = {
    for k, r in local.vm_requests : k => {
      project = r.project
      pool    = try(local.projects[r.project].pool, null)
      flavor  = try(r.flavor, "vm-small")
      profile = try(r.profile, "vm")
      vmid    = r.vmid
      ip      = r.ip
      mvp     = try(r.mvp, null)
    }
  }

  # Claves de la cuenta de ARRANQUE `ops` (cloud-init): admins + cuentas de servicio.
  ops_keys = concat(
    [for k, a in local.people.admins : trimspace(a.ssh_key)],
    [for k, s in try(local.people.service, {}) : trimspace(s.ssh_key)],
  )

  # Todas las VMs que resultan de las peticiones, clusters expandidos.
  all_vms = concat(
    flatten([
      for k, c in local.clusters : [
        for i in range(c.worker_count + 1) : {
          name    = i == 0 ? "${k}-master" : format("%s-worker-%02d", k, i)
          file    = "requests/clusters/${k}.yaml"
          request = k
          project = c.project
          vmid    = c.vmid_base + i
          octet   = c.ip_base + i
        }
      ]
    ]),
    [
      for k, v in local.standalone_vms : {
        name    = k
        file    = "requests/vms/${k}.yaml"
        request = k
        project = v.project
        vmid    = v.vmid
        octet   = tonumber(element(split(".", v.ip), 3))
      }
    ]
  )

  # --- Reglas -----------------------------------------------------------------
  unknown_project = distinct([for v in local.all_vms : "${v.file} ('${v.project}')" if !contains(keys(local.projects), v.project)])
  dup_vmids = distinct([
    for v in local.all_vms : "${v.vmid} (${v.name})" if length([for w in local.all_vms : w if w.vmid == v.vmid]) > 1
  ])
  dup_ips = distinct([
    for v in local.all_vms : "${local.net.prefix}.${v.octet} (${v.name})" if length([for w in local.all_vms : w if w.octet == v.octet]) > 1
  ])
  reserved_hits = [for v in local.all_vms : "${v.name} -> ${local.net.prefix}.${v.octet}" if contains(local.net.reserved_ips, v.octet)]
  vmid_out_of_range = [
    for v in local.all_vms : "${v.name} (vmid ${v.vmid}, proyecto ${v.project})"
    if !anytrue([for rg in try(local.projects[v.project].ranges, []) : v.vmid >= rg.vmids[0] && v.vmid <= rg.vmids[1]])
  ]
  ip_out_of_range = [
    for v in local.all_vms : "${v.name} (${local.net.prefix}.${v.octet}, proyecto ${v.project})"
    if !anytrue([for rg in try(local.projects[v.project].ranges, []) : v.octet >= rg.ips[0] && v.octet <= rg.ips[1]])
  ]
  ip_wrong_network = [for k, v in local.standalone_vms : "${k} (${v.ip})" if !startswith(v.ip, "${local.net.prefix}.")]
  bad_vm_flavor = [
    for k, v in local.standalone_vms : "${k}: flavor '${v.flavor}' / perfil '${v.profile}'"
    if !contains(try(local.profiles.vm_profiles[v.profile].flavors, []), v.flavor)
  ]
  missing_mvp = [
    for k, v in local.standalone_vms : k
    if contains(try(local.profiles.vm_profiles[v.profile].requires, []), "mvp") && v.mvp == null
  ]
  bad_cluster_size = [for k, c in local.clusters : "${k}: '${c.flavor_size}'" if !contains(keys(local.sizes), c.flavor_size)]
  too_few_workers = [
    for k, c in local.clusters : "${k}: ${c.worker_count} workers, minimo ${c.min_workers}" if c.worker_count < c.min_workers
  ]
  bad_keys = [
    for k in local.ops_keys : k
    if !can(regex("^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp[0-9]+) AAAA[0-9A-Za-z+/]{40,}={0,2}( |$)", k))
  ]
}

# Las reglas van como precondition de un output y no de un recurso: un error corta
# el plan con un mensaje claro sin añadir nada al estado.
output "requests" {
  description = "Resumen de lo pedido: nombre -> proyecto, vmid, ip"
  value = {
    for v in local.all_vms : v.name => {
      project = v.project
      vmid    = v.vmid
      ip      = "${local.net.prefix}.${v.octet}"
    }
  }

  precondition {
    condition     = length(local.unknown_project) == 0
    error_message = "Proyecto que no esta en projects.yaml: ${join(", ", local.unknown_project)}."
  }
  precondition {
    condition     = length(local.dup_vmids) == 0
    error_message = "VMIDs repetidos entre peticiones: ${join(", ", local.dup_vmids)}."
  }
  precondition {
    condition     = length(local.dup_ips) == 0
    error_message = "IPs repetidas entre peticiones: ${join(", ", local.dup_ips)}."
  }
  precondition {
    condition     = length(local.reserved_hits) == 0
    error_message = "IP reservada (platform.yaml network.reserved_ips): ${join(", ", local.reserved_hits)}."
  }
  precondition {
    condition     = length(local.vmid_out_of_range) == 0
    error_message = "VMID fuera de los rangos del proyecto: ${join(", ", local.vmid_out_of_range)}. Podria ser el de otro proyecto."
  }
  precondition {
    condition     = length(local.ip_out_of_range) == 0
    error_message = "IP fuera de los rangos del proyecto: ${join(", ", local.ip_out_of_range)}. Podria ser la de otro proyecto."
  }
  precondition {
    condition     = length(local.ip_wrong_network) == 0
    error_message = "IP fuera de la red ${local.net.prefix}.0/${local.net.cidr_bits}: ${join(", ", local.ip_wrong_network)}."
  }
  precondition {
    condition     = length(local.bad_vm_flavor) == 0
    error_message = "Flavor/perfil no validos (catalog/profiles.yaml): ${join(", ", local.bad_vm_flavor)}."
  }
  precondition {
    condition     = length(local.missing_mvp) == 0
    error_message = "Estas VMs necesitan un bloque `mvp:` (repo, ref y path): ${join(", ", local.missing_mvp)}."
  }
  precondition {
    condition     = length(local.bad_cluster_size) == 0
    error_message = "flavor_size inexistente (catalog/flavors.yaml cluster_sizes): ${join(", ", local.bad_cluster_size)}."
  }
  precondition {
    condition     = length(local.too_few_workers) == 0
    error_message = "Cluster con menos workers del minimo de su familia: ${join(", ", local.too_few_workers)}."
  }
  precondition {
    condition     = length(local.ops_keys) > 0 && length(local.bad_keys) == 0
    error_message = "projects.yaml: falta alguna ssh_key de admins/service o no es una clave publica real: ${join(" | ", local.bad_keys)}"
  }
}
