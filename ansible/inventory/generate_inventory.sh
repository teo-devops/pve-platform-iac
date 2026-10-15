#!/usr/bin/env bash
# Genera inventory/hosts.ini y los group_vars de acceso a partir de los outputs de
# Terraform (estado en HCP) y de projects.yaml. Lo llama `scripts/iac configure`.
#
# Estructura que produce:
#
#   [<cluster>_server] / [<cluster>_agent]   un par por cluster k3s
#   [k3s_server] / [k3s_agent]               grupos padre (playbooks/k3s.yml)
#   [proxmox_standalone]                     VMs sueltas (con mvp_repo/ref/path si tienen MVP)
#   [<perfil>]                               VMs sueltas por perfil (`profile:` con "-" -> "_"):
#                                            vm, monitoring, dataspace_kind. Cada playbook
#                                            apunta al grupo de su perfil.
#   [proxmox_vms]                            padre de TODO (playbooks/site.yml)
#
# Y en inventory/group_vars/all/ (gitignorados, derivados):
#   ssh_keys.yml   ops_ssh_keys: claves de la cuenta `ops` (admins + service de projects.yaml)
#   access.yml     vm_access: por VM, quien tiene cuenta (miembros del proyecto + admins)
#
# Los nombres de grupo llevan "_" y no "-": Ansible solo admite [A-Za-z0-9_] ahi.
set -euo pipefail

cd "$(dirname "$0")/.."   # rutas relativas a ansible/

TF_DIR="../terraform"
OUT_FILE="inventory/hosts.ini"
ANSIBLE_USER="${ANSIBLE_USER:-ops}"

command -v jq >/dev/null || { echo "Falta jq (apt install jq)" >&2; exit 1; }
command -v terraform >/dev/null || { echo "Falta terraform" >&2; exit 1; }

# Una sola llamada al estado. Si falla, se explica en vez de dejar un inventario vacio.
if ! TF_OUT_ALL=$(terraform -chdir="$TF_DIR" output -json 2>&1); then
  if echo "$TF_OUT_ALL" | grep -Eqi "unauthorized|401|token|credentials|organization"; then
    {
      echo "========================================================================="
      echo " [ERROR] HCP Terraform pide autenticacion (el estado vive alli)."
      echo " En local:  export TF_CLOUD_ORGANIZATION=<org>"
      echo "            read -rs TF_TOKEN_app_terraform_io && export TF_TOKEN_app_terraform_io"
      echo " Detalle: docs/credenciales.md"
      echo "========================================================================="
    } >&2
    exit 1
  elif echo "$TF_OUT_ALL" | grep -Eqi "no outputs|empty|no state"; then
    echo "[AVISO] El estado aun no tiene outputs (¿primer apply pendiente?)." >&2
    TF_OUT_ALL="{}"
  else
    echo "[ERROR] 'terraform output' ha fallado:" >&2
    echo "$TF_OUT_ALL" >&2
    exit 1
  fi
fi

CLUSTERS_JSON=$(echo "$TF_OUT_ALL" | jq '.k3s_clusters.value // {}')
STANDALONE_JSON=$(echo "$TF_OUT_ALL" | jq '.standalone_vms.value // {}')
META_JSON=$(echo "$TF_OUT_ALL" | jq '.k3s_cluster_meta.value // {}')
ACCESS_JSON=$(echo "$TF_OUT_ALL" | jq '.vm_access.value // null')

# Claves de ops directamente de projects.yaml (misma regla que local.ops_keys en
# terraform/requests.tf). Del estado solo se verian tras un apply, y una clave
# nueva de admin no llegaria a las VMs existentes hasta entonces.
KEYS_JSON=$(python3 -c '
import json, sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
keys = [a["ssh_key"].strip() for a in (d.get("admins") or {}).values()]
keys += [s["ssh_key"].strip() for s in (d.get("service") or {}).values()]
print(json.dumps(keys))
' ../projects.yaml) || { echo "No pude leer las claves de ../projects.yaml (python3 + PyYAML)" >&2; exit 1; }

{
  echo "# Generado por generate_inventory.sh - no editar a mano"
  echo

  # --- clusters k3s: un grupo server y uno agent por cluster -------------------
  echo "$CLUSTERS_JSON" | jq -r '
    to_entries[] as $c |
    ($c.key | gsub("-";"_")) as $g |
    ($c.value | to_entries[] | select(.value.role=="server")) as $m |
    "[\($g)_server]\n\($m.key) ansible_host=\($m.value.ip) k3s_vmid=\($m.value.vmid)\n"
  '
  echo "$CLUSTERS_JSON" | jq -r '
    to_entries[] as $c |
    ($c.key | gsub("-";"_")) as $g |
    ($c.value | to_entries[] | select(.value.role=="server") | .value.ip) as $masterip |
    "[\($g)_agent]",
    ( $c.value | to_entries[] | select(.value.role=="agent") |
      "\(.key) ansible_host=\(.value.ip) k3s_vmid=\(.value.vmid)" ),
    "",
    "[\($g)_agent:vars]",
    "k3s_master_ip=\($masterip)",
    ""
  '
  # Version de k3s por cluster: server y agents tienen que llevar la misma.
  echo "$META_JSON" | jq -r '
    to_entries[] | select(.value.k3s_version != null) |
    (.key | gsub("-";"_")) as $g |
    "[\($g)_server:vars]", "k3s_version=\(.value.k3s_version)", "",
    "[\($g)_agent:vars]",  "k3s_version=\(.value.k3s_version)", ""
  '
  echo "[k3s_server:children]"
  echo "$CLUSTERS_JSON" | jq -r 'keys[] | gsub("-";"_") | "\(.)_server"'
  echo
  echo "[k3s_agent:children]"
  echo "$CLUSTERS_JSON" | jq -r 'keys[] | gsub("-";"_") | "\(.)_agent"'
  echo

  # --- VMs sueltas ------------------------------------------------------------
  # Las variables del MVP van en la linea del host; @sh las entrecomilla para que
  # un valor raro no rompa el INI (ademas, `iac check` ya los valida con regex).
  echo "[proxmox_standalone]"
  echo "$STANDALONE_JSON" | jq -r 'to_entries[] |
    "\(.key) ansible_host=\(.value.ip) project=\(.value.project | @sh)" +
    (if .value.mvp then
       " mvp_repo=\(.value.mvp.repo | @sh) mvp_ref=\(.value.mvp.ref | @sh) mvp_path=\(.value.mvp.path | @sh)"
     else "" end)'
  echo

  # --- un grupo por perfil ------------------------------------------------------
  # Se declaran SIEMPRE monitoring y dataspace_kind, aunque esten vacios: un
  # playbook cuyo grupo no existe da un warning confuso; uno vacio, un skip limpio.
  echo "$STANDALONE_JSON" | jq -r '
    (to_entries | group_by(.value.profile)
     | map({key: (.[0].value.profile | gsub("-";"_")), value: map(.key)})
     | from_entries) as $g |
    ({"monitoring": [], "dataspace_kind": []} + $g) | to_entries[] |
    "[\(.key)]", (.value[]), ""
  '

  echo "[proxmox_vms:children]"
  echo "k3s_server"
  echo "k3s_agent"
  echo "proxmox_standalone"
  echo
  echo "[all:vars]"
  echo "ansible_user=$ANSIBLE_USER"
} > "$OUT_FILE"

KEYS_FILE="inventory/group_vars/all/ssh_keys.yml"
ACCESS_FILE="inventory/group_vars/all/access.yml"
mkdir -p "$(dirname "$KEYS_FILE")"
{
  echo "---"
  echo "# Generado por generate_inventory.sh desde projects.yaml - no editar a mano."
  echo "ops_ssh_keys:"
  echo "$KEYS_JSON" | jq -r '.[]? | "  - \"" + . + "\""'
} > "$KEYS_FILE"
{
  echo "---"
  echo "# Generado por generate_inventory.sh desde el output vm_access de Terraform"
  echo "# (projects.yaml + requests/) - no editar a mano."
  if [ "$ACCESS_JSON" = "null" ]; then
    echo "vm_access_managed: false"
    echo "vm_access: {}"
  else
    echo "vm_access_managed: true"
    echo "vm_access: $(echo "$ACCESS_JSON" | jq -c .)"
  fi
} > "$ACCESS_FILE"
echo "Claves de ops: $(echo "$KEYS_JSON" | jq 'length'); acceso por VM en $ACCESS_FILE"
echo "Inventario generado en $OUT_FILE:"
cat "$OUT_FILE"
