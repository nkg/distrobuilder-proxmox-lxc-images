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
| `nomad-client`  | `service-base` shape + Nomad agent binary (pinned) + nomad user + systemd unit | Nomad worker nodes — each runs podman containers for CI jobs at runtime    |

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

## Upload to a Proxmox host

```bash
make upload-service-base PVE_HOST=vaterland.local
# scp's the tarball to /var/lib/vz/template/cache/service-base.tar.xz
```

Override the datastore if vztmpl lives elsewhere:

```bash
make upload-service-base PVE_HOST=vaterland.local PVE_STORAGE=nfs-templates
```

## Reference from Terraform

In a `terraform-proxmox-fleet` invocation:

```hcl
lxcs = {
  "registry" = {
    hostname         = "registry"
    vm_id            = 1202
    ip_address       = "172.16.0.132/24"
    template_file_id = "local:vztmpl/service-base.tar.xz"
    nesting          = true   # for podman
    keyctl           = true
    fuse             = true
    # ...
  }
}
```

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
