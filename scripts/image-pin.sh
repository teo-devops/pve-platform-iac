#!/usr/bin/env bash
# image-pin.sh — fija la imagen base (bloque `image:` de platform.yaml) a una release
# FECHADA de Ubuntu 24.04, con su sha256 verificado por la firma GPG de Canonical.
#
#   scripts/image-pin.sh             # la ultima release
#   scripts/image-pin.sh 20260926    # una concreta
#
# Pasos: baja SHA256SUMS y SHA256SUMS.gpg de la release, verifica la firma con la
# clave de imagenes de Ubuntu (huella fijada abajo; si la clave cambia, este script
# falla y hay que revisar el cambio a mano), saca el sha256 de la imagen y
# reescribe platform.yaml. El cambio se sube por PR como cualquier otro.
#
# Cambiar la imagen NO recrea las VMs existentes (ignore_changes en modules/vm):
# solo las nuevas arrancan de la nueva. Detalle: docs/operador.md -> "Subir la imagen base".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE=https://cloud-images.ubuntu.com/releases/noble
IMG=ubuntu-24.04-server-cloudimg-amd64.img
# UEC Image Automatic Signing Key <cdimage@ubuntu.com>
FPR=D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81

for t in curl gpg python3; do command -v "$t" >/dev/null || { echo "Falta $t" >&2; exit 1; }; done

REL="${1:-}"
if [ -z "$REL" ]; then
  REL=$(curl -fsS "$BASE/" | grep -o 'release-[0-9]\{8\}/' | sort -u | tail -1 | tr -dc '0-9')
fi
[[ "$REL" =~ ^[0-9]{8}$ ]] || { echo "Release no valida: '$REL' (formato AAAAMMDD)" >&2; exit 1; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export GNUPGHOME="$W/gnupg"; mkdir -m 700 "$GNUPGHOME"
curl -fsS -o "$W/SHA256SUMS" "$BASE/release-$REL/SHA256SUMS"
curl -fsS -o "$W/SHA256SUMS.gpg" "$BASE/release-$REL/SHA256SUMS.gpg"
gpg --batch --quiet --keyserver hkps://keyserver.ubuntu.com --recv-keys "$FPR"
# --status-fd: se comprueba la HUELLA de quien firma, no solo "Good signature".
gpg --batch --status-fd 1 --verify "$W/SHA256SUMS.gpg" "$W/SHA256SUMS" 2>/dev/null | grep -q "VALIDSIG $FPR" \
  || { echo "La firma de SHA256SUMS de release-$REL NO es valida con la clave $FPR. No se cambia nada." >&2; exit 1; }
SHA=$(awk -v f="*$IMG" '$2 == f {print $1}' "$W/SHA256SUMS")
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "No encuentro $IMG en SHA256SUMS de release-$REL" >&2; exit 1; }

python3 - "$ROOT/platform.yaml" "$REL" "$BASE/release-$REL/$IMG" "$SHA" "$FPR" <<'PY'
import re, sys, datetime
path, rel, url, sha, fpr = sys.argv[1:]
s = open(path).read()
block = (f'image:\n  release: "{rel}"\n  url: {url}\n  sha256: {sha}\n'
         f'  # Verificado el {datetime.date.today():%d-%m-%Y}: firma GPG correcta de SHA256SUMS con la clave\n'
         f'  # {fpr} (UEC Image Automatic Signing Key).\n')
new, n = re.subn(r"(?ms)^image:\n(?:  .*\n)+", block, s)
if n != 1:
    sys.exit("No encuentro el bloque image: de platform.yaml")
open(path, "w").write(new)
PY
echo "platform.yaml -> release-$REL  sha256 $SHA  (firma verificada con $FPR)"
echo "Siguiente: PR con el cambio. El plan debe reemplazar SOLO proxmox_download_file.base_image."
