# distrobuilder-proxmox-lxc-images

[Distrobuilder](https://github.com/lxc/distrobuilder) recipes for
unprivileged Proxmox LXC templates. Each recipe builds a `.tar.xz`
tarball uploadable to a Proxmox host's `vztmpl` storage and
consumable by [terraform-proxmox-fleet](https://github.com/nkg/terraform-proxmox-fleet)
as `template_file_id`.

Distrobuilder is the closest LXC equivalent of Packer for VM
images — declare the OS, packages, files, and post-install actions in
YAML, get back a Proxmox-ready container template.

## Images

| Image           | Description                                                         | Used by                                                                       |
|-----------------|---------------------------------------------------------------------|-------------------------------------------------------------------------------|
| `service-base`  | Debian 13 (trixie) + podman + buildah + skopeo + fuse-overlayfs + cloud-init | Long-lived service LXCs (token-server, registry, dispatcher) in the fleet |
| `nomad-client`  | `service-base` shape + Nomad agent (2.0.5) + `nomad-driver-podman` (0.6.5), both checksum-verified, + nomad user + systemd unit | Nomad worker nodes — each runs podman containers for CI jobs at runtime    |

The Nomad service in `nomad-client` is installed but **not enabled**
— operator drops a config at `/etc/nomad.d/nomad.hcl` then
`systemctl enable --now nomad` (via cloud-init / Ansible).

## Build

Distrobuilder must run as root (it mounts loop devices and chroots
during the build). Install on Debian/Ubuntu (distrobuilder ships
via snap; debootstrap stays in apt):

```bash
sudo apt-get install -y debootstrap
sudo snap install distrobuilder --classic
```

Then:

```bash
make service-base
# → output/service-base/service-base.tar.xz
```

CI builds every image on push / PR and attaches the tarballs as
workflow artifacts (14-day retention) — easiest path to a built
image without a local Linux box.

### Stable downloads via tagged releases

Pushing a `v<x>.<y>.<z>` tag triggers
[`.github/workflows/release.yml`](.github/workflows/release.yml),
which rebuilds every image fresh and creates a GitHub Release with
the tarballs attached as stable download assets. Operators consume
those URLs from automation:

```bash
TAG=v0.2.0
wget https://github.com/nkg/distrobuilder-proxmox-lxc-images/releases/download/${TAG}/service-base.tar.xz
wget https://github.com/nkg/distrobuilder-proxmox-lxc-images/releases/download/${TAG}/nomad-client.tar.xz
```

Release notes are auto-generated from PRs merged since the previous
tag. Tag bumps are the moment a recipe's behaviour visibly changes
to consumers — pin to a specific tag in any consuming automation.

## Upload to a Proxmox host

```bash
make upload-service-base PVE_HOST=pve-01.local
# scp's the tarball to /var/lib/vz/template/cache/service-base.tar.xz
```

Override the datastore if vztmpl lives elsewhere:

```bash
make upload-service-base PVE_HOST=pve-01.local PVE_STORAGE=nfs-templates
```

## Reference from Terraform

In a `terraform-proxmox-fleet` invocation:

```hcl
lxcs = {
  "registry" = {
    hostname         = "registry"
    vm_id            = 1202
    ip_address       = "192.168.1.132/24"
    template_file_id = "local:vztmpl/service-base.tar.xz"
    nesting          = true   # for podman
    keyctl           = true
    fuse             = true
    # ...
  }
}
```

## Verifying a release

Each release ships, alongside the two tarballs:

| Asset | What it is |
|---|---|
| `SHA256SUMS` | checksums for both tarballs |
| `SHA256SUMS.sig` / `.pem` | cosign keyless signature + certificate |
| `<image>.spdx.json` | SPDX SBOM of the rootfs package set |

Plus SLSA build provenance recorded against the repository.

```bash
TAG=v0.3.0
BASE=https://github.com/nkg/distrobuilder-proxmox-lxc-images/releases/download/${TAG}
curl -fsSLO ${BASE}/service-base.tar.xz
curl -fsSLO ${BASE}/SHA256SUMS
curl -fsSLO ${BASE}/SHA256SUMS.sig
curl -fsSLO ${BASE}/SHA256SUMS.pem

# 1. Verify the checksum file was signed by this repo's release workflow.
cosign verify-blob SHA256SUMS \
  --signature SHA256SUMS.sig \
  --certificate SHA256SUMS.pem \
  --certificate-identity-regexp '^https://github.com/nkg/distrobuilder-proxmox-lxc-images/' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'

# 2. Then check the tarball against it.
sha256sum --ignore-missing -c SHA256SUMS

# 3. Optionally, confirm the build provenance.
gh attestation verify service-base.tar.xz \
  --repo nkg/distrobuilder-proxmox-lxc-images
```

The signature covers `SHA256SUMS` rather than each tarball
individually: verifying one signature and then the hashes covers every
asset, and leaves one thing to check instead of one per file.

Step 1 is the one that matters. `sha256sum -c` on its own only proves
the file matches a checksum you also downloaded from the same place —
the signature is what ties both to a build of this repository.

## Design notes

### One distro family, multiple recipes

Every recipe builds on Debian 13. Mixing distro families across LXCs
in the same fleet is operationally noisy (different package managers,
different systemd quirks, different security-update cadences). Pick
one and stick to it; if you genuinely need Alpine or Ubuntu for a
specific service, add a recipe and accept the operational cost
deliberately.

### Unprivileged by design

All recipes target unprivileged LXC. That's the security default
upstream Proxmox recommends for anything running container workloads
(podman inside a privileged LXC is essentially root-on-host, which
defeats the point). The recipes set up storage and capabilities so
podman works rootless / nested inside an unprivileged LXC without
post-install tinkering.

### Cloud-init for per-instance config

Hostname, network, SSH keys, and any per-instance runcmd come from
Proxmox's cloud-init facility at clone time — not baked into the
image. This keeps the templates small, reproducible, and
org-agnostic.

### Pinned to a specific Debian release

`trixie` (Debian 13) is hard-coded in the recipe. Bumping a release is
a deliberate change (`feat: bump service-base to <next>`) — not a
moving target via `latest`.

### Pinned, checksum-verified Nomad + podman driver

`nomad-client` installs two pinned binaries, each fetched from
`releases.hashicorp.com` and verified against the SHA256 HashiCorp
publishes for that release. An unexpected hash fails the build rather
than baking unverified bits into the template every CI runner in the
fleet boots from.

| Component | Version | Installed to |
|---|---|---|
| Nomad agent | **2.0.5** | `/usr/local/bin/nomad` |
| `nomad-driver-podman` | **0.6.5** | `/var/lib/nomad/plugins/` |

**The podman task driver is a separate plugin** — the Nomad binary
doesn't bundle it. Every job this platform runs uses
`driver = "podman"`, and a client missing the plugin comes up looking
perfectly healthy while placing nothing: allocations just sit pending
with a "missing drivers" constraint failure. It's baked in so that
can't happen.

`/etc/nomad.d/00-base.hcl` sets `data_dir` and `plugin_dir`. Nomad
merges every `*.hcl` in that directory, so the operator's `nomad.hcl`
layers client config on top without restating the paths. Leave the
base file in place — `plugin_dir` is what makes the driver findable.

Bumping means changing **four** values in
`images/nomad-client/image.yaml` — a version and a checksum for each
component:

```bash
curl -s https://releases.hashicorp.com/nomad/<VERSION>/nomad_<VERSION>_SHA256SUMS \
  | grep linux_amd64
curl -s https://releases.hashicorp.com/nomad-driver-podman/<VERSION>/nomad-driver-podman_<VERSION>_SHA256SUMS \
  | grep linux_amd64
```

### Upgrading Nomad

Nomad requires **servers to be upgraded before clients**, and does not
support skipping minor versions. Since this template is what every CI
runner node boots from, getting that order wrong takes the whole
runner pool offline at once.

Before bumping `NOMAD_VERSION`:

1. Check what the fleet's Nomad **servers** run: `nomad server members`.
2. If they're behind, upgrade them first, one minor at a time, letting
   each settle.
3. Only then bump `NOMAD_VERSION` + `NOMAD_SHA256` here, rebuild, and
   roll the client LXCs.

This is a non-issue on a greenfield fleet — deploy servers at the same
2.x version the template carries and there's nothing to sequence.

### CI builds the artefacts

Every push / PR runs distrobuilder against each recipe and uploads
the result as a workflow artifact. This catches recipe regressions
before they hit a real Proxmox host. Eventually a tagged release will
promote artifacts to a GitHub Release for stable consumption.

## Requirements

| Tool           | Version |
|----------------|---------|
| distrobuilder  | ≥ 3.0   |
| debootstrap    | Recent enough to know `trixie` |
| Proxmox VE     | 8.x+    |

## License

MIT.
