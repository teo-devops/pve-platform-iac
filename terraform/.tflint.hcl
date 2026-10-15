# tflint del CI (pr-validate.yml). Solo el ruleset de Terraform: no hay ruleset
# para el provider de Proxmox.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
