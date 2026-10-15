# Una VM a partir de la cloud image de Ubuntu descargada en su nodo (main.tf).
#
# Diferencias con el modulo del diseño anterior del que viene:
#   - Sin replicacion por `ssh root@nodo` + pvesh, y disco con `import_from` en vez
#     de `file_id`: el provider no hace NADA por SSH, y el pipeline no necesita
#     ninguna clave root de los nodos (docs/seguridad.md, R-06).
#   - `disk[0].import_from` ignorado: subir la imagen fijada (main.tf) solo afecta a las
#     VMs NUEVAS; las existentes no se recrean (docs/diseno.md, D-07).
resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  node_name = var.node_name
  vm_id     = var.vmid
  pool_id   = var.pool_id
  tags      = var.tags

  agent {
    enabled = true # qemu-guest-agent lo instala el rol Ansible `base`

    # El agente NO existe todavia cuando Terraform crea la VM: la cloud image no lo
    # trae. Con el timeout por defecto (15 min) el provider lo esperaria en CADA VM
    # y el apply pareceria colgado. Este modulo no usa ningun dato del agente: la IP
    # del output es la estatica de la peticion.
    timeout = "1m"
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.memory
  }

  disk {
    datastore_id = var.datastore_id
    # import_from (contenido "import") importa por la API. Con file_id el provider
    # importaria por SSH root al nodo, y el pipeline necesitaria esa clave.
    import_from = var.template_file_id
    interface   = "scsi0"
    size        = var.disk_size
    discard     = "on" # TRIM/UNMAP: en ZFS o LVM-thin devuelve el espacio liberado
    ssd         = true
  }

  network_device {
    bridge  = var.bridge
    vlan_id = var.vlan_tag
  }

  initialization {
    datastore_id = var.datastore_id

    ip_config {
      ipv4 {
        address = "${var.ip_address}/${var.network_cidr_bits}"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    # Solo el acceso de ARRANQUE: la cuenta `ops` con las claves de los admins y de
    # la cuenta `ci` (projects.yaml). Las personas entran con su propia cuenta, que
    # crea Ansible (rol base) con las claves de su perfil de GitHub.
    user_account {
      username = var.ci_user
      keys     = var.ssh_keys
    }
  }

  operating_system {
    type = "l26"
  }

  # Arrancar del disco y no del cdrom de cloud-init
  boot_order = ["scsi0"]

  lifecycle {
    ignore_changes = [
      # Una imagen nueva (main.tf) solo es para las VMs nuevas. Sin esto, cambiar la
      # imagen fijada RECREARIA todas las VMs existentes, discos incluidos. (El
      # provider ya trata import_from como de solo creacion; esto lo garantiza.)
      disk[0].import_from,
      # cloud-init solo se usa en el primer arranque. Cambiar las claves de los
      # admins o el usuario de arranque no debe verse como un cambio de la VM: el
      # acceso vivo lo mantiene Ansible.
      initialization[0].user_account,
    ]
  }
}

output "ip_address" {
  value = var.ip_address
}

output "vmid" {
  value = var.vmid
}
