# Obligatorio aunque parezca redundante con el root: sin este bloque Terraform
# infiere el source del prefijo del recurso ("hashicorp/proxmox", que no existe) y
# `terraform init` falla. La CONFIGURACION del provider se hereda del root; la
# version exacta la fija el lockfile del root.
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.111.0"
    }
  }
}
