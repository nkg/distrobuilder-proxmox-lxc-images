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

The Nomad service in `nomad-client` is installed but **not enabled**.
[`ansible-nomad-cluster`](https://github.com/nkg/ansible-nomad-cluster)
renders `/etc/nomad.d/nomad.hcl` and enables it at bootstrap. The
template deliberately ships no config fragment of its own — the role
owns `data_dir` and `plugin_dir`, and two files setting them is a trap
that surfaces as a client with no podman driver.

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
| `SHA256SUMS.bundle` | cosign keyless Sigstore bundle (signature + certificate + inclusion proof) |
| `<image>.spdx.json` | SPDX SBOM of the rootfs package set |

Plus SLSA build provenance recorded against the repository.

```bash
TAG=v0.2.0
BASE=https://github.com/nkg/distrobuilder-proxmox-lxc-images/releases/download/${TAG}
curl -fsSLO ${BASE}/service-base.tar.xz
curl -fsSLO ${BASE}/SHA256SUMS
curl -fsSLO ${BASE}/SHA256SUMS.bundle

# 1. Verify the checksum file was signed by this repo's release workflow.
cosign verify-blob SHA256SUMS \
  --bundle SHA256SUMS.bundle \
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
| `nomad-driver-podman` | **0.6.5** | `/opt/nomad/plugins/` |

**The podman task driver is a separate plugin** — the Nomad binary
doesn't bundle it. Every job this platform runs uses
`driver = "podman"`, and a client missing the plugin comes up looking
perfectly healthy while placing nothing: allocations sit pending with
a "missing drivers" constraint failure.

#### These versions are not independent

Both must match the defaults in
[`ansible-nomad-cluster`](https://github.com/nkg/ansible-nomad-cluster)
(`nomad_version`, `nomad_driver_podman_version`, `nomad_plugin_dir`).
That role is the authority: it version-checks what the template baked
and reinstalls on a mismatch — and because the check is a string
comparison rather than a floor, a *lower* role default silently
downgrades the pre-baked binary on every converge. Bumping here alone
doesn't ship a new version; it gets undone at bootstrap.

Baking them at the role's paths is the point. The role no-ops when the
versions already match, which is what makes the pre-baked template
worth having; it already documents that arrangement for the Nomad
binary itself.

Bumping means changing **four** values in
`images/nomad-client/image.yaml` — a version and a checksum for each
component — *and* the corresponding role defaults:

```bash
curl -s https://releases.hashicorp.com/nomad/<VERSION>/nomad_<VERSION>_SHA256SUMS \
  | grep linux_amd64
curl -s https://releases.hashicorp.com/nomad-driver-podman/<VERSION>/nomad-driver-podman_<VERSION>_SHA256SUMS \
  | grep linux_amd64
```

### Nomad 2.x and the podman driver

**Why 2.x:** 1.11.3 was the last community-edition 1.x release.
`1.11.4`–`1.11.9` ship as `+ent` only, so 1.x is not merely frozen —
it is **already unpatched**. Nomad 2.0.1 (2026-05-12) fixed two CVEs
that 1.11.3 (2026-03-11) predates, with no community release to
backport them into:

| CVE | Fix |
|---|---|
| **CVE-2026-6959** | logging FIFO symlink-swap attacks |
| **CVE-2026-7474** | dynamic host volumes: code execution outside the plugin directory |

2.0.x is the maintained community line.

**The caveat:** `nomad-driver-podman` 0.6.5 pins
`github.com/hashicorp/nomad v1.11.3` and declares no Nomad 2.0 support.
It shipped two months *after* Nomad 2.0.1, so 2.0 was available and
not targeted. Since the podman driver is the execution substrate for
every runner, this pairing is a deliberate bet rather than a supported
combination.

Source analysis says the bet is sound:

- the plugin handshake (`ProtocolVersion`, magic cookie) is
  byte-identical between 1.11.3 and 2.0.5
- `driver.proto` changed only additively between 1.11.3 and 2.0.5 — no
  removals, no renumbering, no type changes
- 2.0.5 tolerates older drivers deliberately: its new `Init` and
  `Shutdown` RPCs are optional, and the client ignores
  `codes.Unimplemented`

That establishes *interface* compatibility. It does not establish
runtime behaviour, and one known 2.0.x change is worth watching:

> **The alloc-logs bind mount.** Nomad 2.0.1 made the allocation logs
> directory read-only for task drivers that support filesystem
> isolation. The podman driver does. If anything in the runner path
> writes into that directory, it breaks — and it would break at job
> runtime, not at driver load.
>
> That mount *is* the CVE-2026-6959 mitigation. If it bites, the fix is
> to stop writing there; rolling back to 1.11.3 reinstates the
> vulnerability rather than avoiding a mere inconvenience.

**Validate before trusting it with real jobs.** The procedure is
written up in the fleet repo:
[`Sproncy/GitHub-runners` → `docs/runbooks/nomad-2-spike.md`](https://github.com/sproncy/GitHub-runners/blob/main/docs/runbooks/nomad-2-spike.md)
— boot a throwaway client, confirm the full runner lifecycle (register
→ run → `--ephemeral --once` exit → dealloc), and check `nomad alloc
logs` returns output. Since this template now bakes 2.0.5, the baked
binary is the subject of that spike rather than its baseline; the
runbook covers hand-installing 1.11.3 for the baseline leg.

**Also relevant for servers:** Nomad 2.0 can migrate the Raft log
store from BoltDB to WAL, and that migration is effectively one-way —
reverting needs a snapshot taken beforehand. Not exercised by a `-dev`
agent, but it matters the first time real servers come up.

Whenever the version moves again: Nomad requires **servers upgraded
before clients** and does not support skipping minor versions. Since
this template is what every runner node boots from, getting that order
wrong takes the whole runner pool offline at once.

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
