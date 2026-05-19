#!/usr/bin/env bash
# Upload a built image to a Proxmox host's vztmpl storage.
#
# Usage: scripts/upload-to-proxmox.sh <image-name> <pve-host> [datastore]
#
# Defaults:
#   datastore = local
#
# Assumes SSH access as root to the Proxmox host (or your $USER can
# write to /var/lib/vz/template/cache via sudo).

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <image-name> <pve-host> [datastore]" >&2
  exit 2
fi

IMAGE="$1"
HOST="$2"
DATASTORE="${3:-local}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARBALL="${ROOT_DIR}/output/${IMAGE}/${IMAGE}.tar.xz"

if [[ ! -f "${TARBALL}" ]]; then
  echo "error: ${TARBALL} not found. Run scripts/build-image.sh ${IMAGE} first." >&2
  exit 1
fi

# Proxmox stores vztmpl under /var/lib/vz/template/cache for `local`,
# or /mnt/pve/<storage>/template/cache for others.
case "${DATASTORE}" in
  local) REMOTE_DIR="/var/lib/vz/template/cache" ;;
  *)     REMOTE_DIR="/mnt/pve/${DATASTORE}/template/cache" ;;
esac

REMOTE_PATH="${REMOTE_DIR}/${IMAGE}.tar.xz"

echo ">>> Uploading ${TARBALL} to ${HOST}:${REMOTE_PATH}"
scp "${TARBALL}" "root@${HOST}:${REMOTE_PATH}"

echo
echo ">>> Reference from Terraform / pct as:"
echo "    ${DATASTORE}:vztmpl/${IMAGE}.tar.xz"
