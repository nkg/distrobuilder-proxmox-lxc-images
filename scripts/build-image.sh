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

# distrobuilder must run as root. Re-exec before creating anything —
# doing the mkdir first left output/ owned by the invoking user while
# everything inside it came out root-owned.
if [[ $EUID -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

mkdir -p "${OUT_DIR}"
echo ">>> Building ${IMAGE} into ${OUT_DIR}"

# build-lxc emits rootfs.tar.xz + meta.tar.xz alongside each other.
distrobuilder build-lxc "${SRC}" "${OUT_DIR}" --compression xz

# Combine into a single Proxmox-compatible tarball. The convention
# Proxmox uses for its own template downloads is a single tarball
# containing both `templates/` (LXC metadata) and the rootfs files at
# the archive root.
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# GNU tar does NOT preserve extended attributes by default, on either
# extract or create. Without these flags the unpack/repack cycle
# silently strips file capabilities from the rootfs — so binaries that
# rely on them rather than setuid (ping's cap_net_raw being the classic
# case) come out of the merge broken, in a way nothing in the build
# reports. --numeric-owner keeps uid/gid as-is instead of remapping
# through the build host's passwd database.
TAR_XATTR_OPTS=(--xattrs --xattrs-include='*' --acls --numeric-owner)

tar -xf "${OUT_DIR}/rootfs.tar.xz" -C "${WORK}" "${TAR_XATTR_OPTS[@]}"
tar -xf "${OUT_DIR}/meta.tar.xz"   -C "${WORK}" "${TAR_XATTR_OPTS[@]}"
tar -caf "${OUT_DIR}/${IMAGE}.tar.xz" -C "${WORK}" "${TAR_XATTR_OPTS[@]}" .

# Drop the intermediate tarballs; the combined one is what Proxmox
# wants in `local:vztmpl/`.
rm -f "${OUT_DIR}/rootfs.tar.xz" "${OUT_DIR}/meta.tar.xz"

# Hand the artefacts back to whoever invoked us, so `make clean` and
# scp-ing the tarball don't need root of their own.
if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
  chown -R "${SUDO_UID}:${SUDO_GID}" "${ROOT_DIR}/output"
fi

echo ">>> Done: ${OUT_DIR}/${IMAGE}.tar.xz"
echo
echo "Upload to a Proxmox host with:"
echo "  scripts/upload-to-proxmox.sh ${IMAGE} <pve-host>"
