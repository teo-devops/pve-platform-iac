#!/usr/bin/env bash
# ca-bundle.sh — imprime la ruta de un bundle de CA = las del sistema + la CA del
# cluster Proxmox (terraform/certs/pve-root-ca.pem).
#
# Para que sirve: el provider de Proxmox valida TLS (insecure = false) y es Go, que
# lee las CA de SSL_CERT_FILE. Si SSL_CERT_FILE apuntara SOLO a la CA de Proxmox,
# dejaria de validar HCP Terraform y GitHub; por eso se concatenan.
#
#   export SSL_CERT_FILE="$(scripts/ca-bundle.sh)"
#
# Lo usan los workflows (.github/workflows/*) y `scripts/iac plan/apply/preflight`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CA="$ROOT/terraform/certs/pve-root-ca.pem"
[ -s "$CA" ] && grep -q "BEGIN CERTIFICATE" "$CA" || {
  echo "Falta $CA: copia /etc/pve/pve-root-ca.pem de un nodo (docs/bootstrap.md §3)." >&2; exit 1; }

SYS=""
for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
  [ -s "$f" ] && { SYS="$f"; break; }
done
[ -n "$SYS" ] || { echo "No encuentro el bundle de CA del sistema (¿falta el paquete ca-certificates?)." >&2; exit 1; }

OUT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pve-platform-iac-ca-bundle.pem"
cat "$SYS" "$CA" > "$OUT"
echo "$OUT"
