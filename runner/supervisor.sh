#!/usr/bin/env bash
# supervisor.sh — mantiene UN runner efimero de un tipo (plan | apply) siempre listo.
#
# Bucle: pide a GitHub una configuracion JIT (un runner de un solo uso, ya asignado
# a su grupo y con sus etiquetas), arranca un contenedor nuevo con ella, espera a
# que coja UN job y termine, y lo destruye. El siguiente job empieza en un
# contenedor limpio: nada de lo que deje un job (ficheros, procesos, credenciales)
# llega al siguiente (docs/seguridad.md, R-08).
#
#   runner/supervisor.sh plan     # lo lanza systemd: runner/platform-runner@.service
#
# Configuracion en /etc/platform-runner/env (root:root 0600; docs/bootstrap.md §6).
# Uno de los dos modos:
#   Organizacion (recomendado: grupos restringidos a workflows concretos)
#     GH_ORG=<organizacion>
#     GH_RUNNER_PAT=<PAT fine-grained: org -> "Self-hosted runners: read and write">
#     GROUP_ID_plan=<id del grupo platform-plan>   GROUP_ID_apply=<id del grupo platform-apply>
#   Repo de una cuenta personal (sin grupos: runners del repo)
#     GH_REPO=<usuario>/<repo>
#     GH_RUNNER_PAT=<PAT fine-grained: solo ese repo -> "Administration: read and write">
set -euo pipefail
kind="${1:?plan|apply}"
case "$kind" in plan|apply) ;; *) echo "tipo desconocido: $kind" >&2; exit 2 ;; esac
# shellcheck source=/dev/null
. /etc/platform-runner/env
: "${GH_RUNNER_PAT:?falta GH_RUNNER_PAT en /etc/platform-runner/env}"
if [ -n "${GH_REPO:-}" ]; then
  # Los runners de un repo solo tienen el grupo por defecto (id 1).
  api="https://api.github.com/repos/$GH_REPO/actions/runners/generate-jitconfig"; group=1
else
  : "${GH_ORG:?falta GH_ORG o GH_REPO en /etc/platform-runner/env}"
  api="https://api.github.com/orgs/$GH_ORG/actions/runners/generate-jitconfig"
  group_var="GROUP_ID_$kind"; group="${!group_var:?falta $group_var en /etc/platform-runner/env}"
fi
IMAGE="${RUNNER_IMAGE:-platform-runner:local}"
NET="platform-$kind"   # red docker propia; el cortafuegos la limita (runner/README.md)

while true; do
  name="platform-$kind-$(date +%s)-$RANDOM"
  body=$(jq -nc --arg n "$name" --argjson g "$group" --arg l "platform-$kind" \
           '{name: $n, runner_group_id: $g, labels: ["self-hosted", "linux", "x64", $l], work_folder: "_work"}')
  if ! jit=$(curl -fsS -X POST -H "Authorization: Bearer $GH_RUNNER_PAT" -H "Accept: application/vnd.github+json" \
               "$api" -d "$body" | jq -r .encoded_jit_config); then
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
