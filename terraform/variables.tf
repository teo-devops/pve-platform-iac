# variables.tf — solo lo que NO puede estar en el repo.
#
# Todo lo demas sale de ficheros versionados, no de variables: la plataforma de
# platform.yaml, los proyectos de projects.yaml, el catalogo de catalog/ y las
# peticiones de requests/ (requests.tf). Asi nadie edita HCL para pedir una VM.

# Token de API de Proxmox. Dos, segun el job (docs/seguridad.md#inventario-de-secretos):
#   iac@pve!plan  -> PVEAuditor en los pools: planes de PR (sin refrescar)
#   iac@pve!apply -> rol IaCApply en los pools: plan de main, apply y deriva
# Ninguno tiene ACL en "/" (`make proxmox-acl`, docs/seguridad.md R-07).
variable "pm_api_token" {
  description = "Token completo 'iac@pve!<id>=<uuid>'"
  type        = string
  sensitive   = true

  validation {
    # Corta los dos errores que la API responde con un 401 opaco: pegar solo el
    # uuid del secreto, o pegar la password del usuario en vez del token.
    condition     = can(regex("^[^@]+@[^!]+![^=]+=[0-9a-f-]{36}$", var.pm_api_token))
    error_message = "pm_api_token debe ser el valor COMPLETO 'usuario@realm!tokenid=uuid', no solo el uuid ni una password."
  }
}

# Usuario de ARRANQUE que crea cloud-init con las claves de admins y `ci`. Es la
# cuenta de la automatizacion; las personas entran con la suya (rol base).
variable "ci_user" {
  type    = string
  default = "ops"
}
