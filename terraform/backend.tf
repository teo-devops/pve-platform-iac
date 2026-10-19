# backend.tf — el estado vive en HCP Terraform (antes Terraform Cloud), plan Free.
#
# El workspace esta en modo de ejecucion LOCAL: HCP solo guarda el estado (cifrado,
# con historial de versiones) y hace de lock. Los plan/apply corren en NUESTROS
# runners de la plataforma, que son los unicos que llegan a la API de Proxmox
# (docs/diseno.md, D-03).
#
# Ni la organizacion ni el workspace se escriben aqui: Terraform los lee de
# TF_CLOUD_ORGANIZATION y TF_WORKSPACE (variables del repo en GitHub; el workspace,
# por defecto `pve-platform`; en local los exporta el Makefile). Asi cada instalacion
# usa los suyos sin tocar el codigo. El token, de TF_TOKEN_app_terraform_io
# (secreto; docs/seguridad.md#inventario-de-secretos).
#
# Bloqueo: cada plan/apply que escribe el estado bloquea el workspace. Los planes
# de PR y de deriva usan -lock=false (no escriben nada).
terraform {
  cloud {}
}
