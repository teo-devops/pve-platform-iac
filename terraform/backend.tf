# backend.tf — el estado vive en HCP Terraform (antes Terraform Cloud), plan Free.
#
# El workspace esta en modo de ejecucion LOCAL: HCP solo guarda el estado (cifrado,
# con historial de versiones) y hace de lock. Los plan/apply corren en NUESTROS
# runners del homelab, que son los unicos que llegan a la API de Proxmox
# (docs/diseno.md, D-03).
#
# La organizacion NO se escribe aqui: la lee Terraform de TF_CLOUD_ORGANIZATION
# (variable del repo en GitHub; en local, exportala). El token, de
# TF_TOKEN_app_terraform_io (secreto; docs/credenciales.md).
#
# Bloqueo: cada plan/apply que escribe el estado bloquea el workspace. Los planes
# de PR y de deriva usan -lock=false (no escriben nada).
terraform {
  cloud {
    workspaces {
      name = "homelab"
    }
  }
}
