#!/usr/bin/env bash
# encrypt-plan.sh — cifra o descifra el plan de Terraform que pasa del job `plan`
# al job `apply` como artefacto de GitHub (docs/seguridad.md, R-09).
#
# Por que: los artefactos de un run los puede descargar CUALQUIERA con rol Read en
# el repo (los freelancers lo tienen), y un plan guardado puede contener valores
# sensibles (atributos de recursos, outputs). Cifrado con una clave que solo esta
# en el environment `production`, el artefacto no sirve de nada fuera del deploy.
#
#   PLAN_ENC_KEY=... encrypt-plan.sh encrypt terraform/tfplan  -> terraform/tfplan.gpg
#   PLAN_ENC_KEY=... encrypt-plan.sh decrypt terraform/tfplan.gpg -> terraform/tfplan
#
# AES256 simetrico con gpg; la clave va por un descriptor, nunca en la linea de
# comandos (se veria en `ps`).
set -euo pipefail
: "${PLAN_ENC_KEY:?Falta PLAN_ENC_KEY (secreto del environment production)}"
mode="${1:?encrypt|decrypt}"; in="${2:?fichero}"
case "$mode" in
  encrypt)
    gpg --batch --yes --quiet --symmetric --cipher-algo AES256 \
        --passphrase-fd 3 --pinentry-mode loopback -o "$in.gpg" "$in" 3<<<"$PLAN_ENC_KEY"
    echo "$in.gpg" ;;
  decrypt)
    out="${in%.gpg}"
    gpg --batch --yes --quiet --decrypt \
        --passphrase-fd 3 --pinentry-mode loopback -o "$out" "$in" 3<<<"$PLAN_ENC_KEY"
    echo "$out" ;;
  *) echo "uso: $0 encrypt|decrypt <fichero>" >&2; exit 2 ;;
esac
