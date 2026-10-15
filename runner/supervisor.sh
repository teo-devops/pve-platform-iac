#!/usr/bin/env bash
# supervisor.sh — mantiene UN runner efimero de un tipo (plan | apply) siempre listo.
#
# Bucle: pide a GitHub una configuracion JIT (un runner de un solo uso, ya asignado
# a su grupo y con sus etiquetas), arranca un contenedor nuevo con ella, espera a
# que coja UN job y termine, y lo destruye. El siguiente job empieza en un
# contenedor limpio: nada de lo que deje un job (ficheros, procesos, credenciales)
# llega al siguiente (docs/seguridad.md, R-08).
#
#   runner/supervisor.sh plan     # lo lanza systemd: runner/homelab-runner@.service
#
# Configuracion en /etc/homelab-runner/env (root:root 0600; docs/bootstrap.md §6):
#   GH_ORG=<organizacion>
#   GH_RUNNER_PAT=<PAT fine-grained del admin: org -> "Self-hosted runners: read and write">
#   GROUP_ID_plan=<id del grupo homelab-plan>   GROUP_ID_apply=<id del grupo homelab-apply>
set -euo pipefail
kind="${1:?plan|apply}"
case "$kind" in plan|apply) ;; *) echo "tipo desconocido: $kind" >&2; exit 2 ;; esac
# shellcheck source=/dev/null
. /etc/homelab-runner/env
group_var="GROUP_ID_$kind"; group="${!group_var:?falta $group_var en /etc/homelab-runner/env}"
: "${GH_ORG:?}" "${GH_RUNNER_PAT:?}"
IMAGE="${RUNNER_IMAGE:-homelab-runner:local}"
NET="homelab-$kind"   # red docker propia; el cortafuegos la limita (runner/README.md)

while true; do
  name="homelab-$kind-$(date +%s)-$RANDOM"
  body=$(jq -nc --arg n "$name" --argjson g "$group" --arg l "homelab-$kind" \
           '{name: $n, runner_group_id: $g, labels: ["self-hosted", "linux", "x64", $l], work_folder: "_work"}')
  if ! jit=$(curl -fsS -X POST -H "Authorization: Bearer $GH_RUNNER_PAT" -H "Accept: application/vnd.github+json" \
               "https://api.github.com/orgs/$GH_ORG/actions/runners/generate-jitconfig" -d "$body" | jq -r .encoded_jit_config); then
    echo "No pude pedir la configuracion JIT (¿PAT caducado? ¿red?). Reintento en 60 s." >&2
    sleep 60; continue
  fi
  echo "$(date -Is) $name esperando un job"
  # --rm: el contenedor desaparece al terminar. Sin docker.sock, sin privilegios.
  docker run --rm --name "$name" --network "$NET" --security-opt no-new-privileges \
    --memory 4g --pids-limit 2048 --tmpfs /tmp:exec \
    "$IMAGE" ./run.sh --jitconfig "$jit" || echo "$(date -Is) $name termino con error" >&2
  sleep 2
done
