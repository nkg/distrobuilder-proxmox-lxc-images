#!/usr/bin/env bash
# Build a single LXC image with distrobuilder.
#
# Usage: scripts/build-image.sh <image-name>
#
# Reads images/<image-name>/image.yaml, writes the resulting Proxmox-
# compatible vztmpl tarball to output/<image-name>/<image-name>.tar.xz.
#
# distrobuilder's `build-lxc` target produces two artefacts:
#   - rootfs.tar.xz : the root filesystem
#   - meta.tar.xz   : LXC metadata (config, templates, hooks)
#
# Proxmox vztmpl expects a single combined tarball where the metadata
# lives alongside the rootfs at the archive root. We merge them here.
#
# Requires: distrobuilder (run as root or via sudo — it needs to mount
# loop devices and chroot during the build).

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <image-name>" >&2
  echo "       <image-name> matches a directory under images/" >&2
  exit 2
fi

IMAGE="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT_DIR}/images/${IMAGE}/image.yaml"
OUT_DIR="${ROOT_DIR}/output/${IMAGE}"

if [[ ! -f "${SRC}" ]]; then
  echo "error: ${SRC} not found" >&2
  exit 1
fi

if ! command -v distrobuilder >/dev/null 2>&1; then
  echo "error: distrobuilder not installed. See README for install steps." >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
echo ">>> Building ${IMAGE} into ${OUT_DIR}"

# distrobuilder must run as root.
if [[ $EUID -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

# build-lxc emits rootfs.tar.xz + meta.tar.xz alongside each other.
distrobuilder build-lxc "${SRC}" "${OUT_DIR}" --compression xz

# Combine into a single Proxmox-compatible tarball. The convention
# Proxmox uses for its own template downloads is a single tarball
# containing both `templates/` (LXC metadata) and the rootfs files at
# the archive root.
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

tar -xf "${OUT_DIR}/rootfs.tar.xz" -C "${WORK}"
tar -xf "${OUT_DIR}/meta.tar.xz"   -C "${WORK}"
tar -caf "${OUT_DIR}/${IMAGE}.tar.xz" -C "${WORK}" .

# Drop the intermediate tarballs; the combined one is what Proxmox
# wants in `local:vztmpl/`.
rm -f "${OUT_DIR}/rootfs.tar.xz" "${OUT_DIR}/meta.tar.xz"

echo ">>> Done: ${OUT_DIR}/${IMAGE}.tar.xz"
echo
echo "Upload to a Proxmox host with:"
echo "  scripts/upload-to-proxmox.sh ${IMAGE} <pve-host>"
