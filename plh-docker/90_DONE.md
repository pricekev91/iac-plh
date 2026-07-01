# DONE

This is what is already implemented and verified in this repository.

## ADRs

- ADR-001: Container host architecture for PLH (unprivileged LXD container, Docker + Dockhand + LazyDocker, CachyOS)

### Fixed

- Fix dockhand container port mapping: map host port 80 to container port 3000 (dockhand listens on 3000, not 8080)

### Added

- Pure-bash deploy script `deploy-plh-docker.sh`: LXD container lifecycle + Docker + Dockhand + LazyDocker
- Pure-bash configure script `configure-hlh-docker.sh`: post-deploy configuration
- LXD-based container creation (`lxc launch ubuntu:latest plh-docker`)
- ZFS bind-mount wiring for `/srv/data` (Docker data + Dockhand data)
- Dockhand container deployment with data persistence
- LazyDocker binary installation from GitHub releases
- Plan mode (`--plan`) for dry-run deployment
- Nuke mode (`--nuke`) for clean rebuild
- Environment variable configuration (`PLH_CORES`, `PLH_MEMORY`, `PLH_DISK`, etc.)

## LXD Container Deployment

- Unprivileged LXC `plh-docker` on CachyOS via LXD 6.9
- Image: Ubuntu (from `ubuntu:latest` LXD remote)
- Resources: 4 vCPU, 4096 MB RAM, 32GB rootfs (ZFS-backed)
- Features: `security.nesting=true` (required for Docker inside LXC)
- Storage: LXD default pool (ZFS)
- Networking: NAT via lxdbr0, port 80 forwarded to Dockhand

## Deployment Scripts

### deploy-plh-docker.sh
- Three-stage workflow: LXD provision → software install → verification
- Modes: `--plan`, `--apply`, `--config-only`, `--nuke`
- Pure bash, no external IaC tools
- Auto-detects container state, avoids redundant operations
- Verifies Docker, Dockhand, and LazyDocker post-deployment

### configure-hlh-docker.sh
- Standalone configuration stage (post-deploy fixup)
- Configures Docker daemon, bind mounts, Dockhand container
- SSH key support via `--key` flag

## Repository Layout

```
plh-docker/
├── deploy-plh-docker.sh        # Pure-bash deploy: LXC + Docker + Dockhand
├── configure-hlh-docker.sh     # Configuration helper
├── ADR-001.md                  # Architecture Decision Record
├── 00_BACKLOG.md               # Backlog / ideas
├── 10_ACTIVE.md                # Active work items
├── 90_DONE.md                  # Completed items
├── 98_README.md                # Working notes
├── CHANGELOG.md                # Version history
└── README.md                   # This file
```
