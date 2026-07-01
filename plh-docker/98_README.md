# PLH-Docker

Infrastructure-as-Code for the PLH Docker container host. Deploys an unprivileged
LXD container running Docker, Dockhand, and LazyDocker on CachyOS.

## Executive Summary

This repository deploys and configures the **Docker LXC** on the PLH CachyOS host
using LXD. The Docker host provides a secure, reproducible container runtime for
application service stacks (Dockhand, LazyDocker).

- LXC container `plh-docker`, hostname `plh-docker`, managed by LXD 6.9
- Unprivileged container with nesting (`security.nesting=true`)
- Docker Engine + Dockhand (GUI) + LazyDocker (TUI)
- 4 vCPU, 4GB RAM, 32GB rootfs on ZFS-backed storage

## Repository Boundary

**Owns:**
- Unprivileged Docker container lifecycle (create, configure, start) on LXD
- Docker Engine installation and configuration
- Dockhand and LazyDocker deployment
- ZFS bind-mount wiring for persistent data

**Does not own:**
- CachyOS host configuration (OS-level setup)
- Docker container application logic (that is the service repos)
- AI engine deployment (that is `hlh-ai-engine`)

## Quick Start

Deploy the Docker container on CachyOS:

```bash
cd ~/git/iac-plh/plh-docker
./deploy-plh-docker.sh --apply
```

Plan only:

```bash
./deploy-plh-docker.sh --plan
```

Configure an existing container (no OpenTofu, no Ansible — pure bash):

```bash
./deploy-plh-docker.sh --config-only
```

## Deployment Model

Deployment and configuration are handled in a single pure-bash script. No OpenTofu, no Ansible, no Terraform.

1. **Provisioning**: `lxc launch ubuntu:latest plh-docker` with nesting + resource limits
2. **Configuration**: Docker Engine, Dockhand, and LazyDocker installed via `lxc exec` inside the running container
3. **Verification**: Docker daemon, Dockhand container, and LazyDocker binary checked

## ADR

See `ADR-001.md` for the full architecture decision: unprivileged LXC, Docker + Dockhand
+ LazyDocker, ZFS bind-mounts, CachyOS + LXD platform.

## Runtime Contract

| Item | Value |
|------|-------|
| Container name | `plh-docker` |
| Dockhand GUI | `http://<container-ip>:80` |
| Docker socket | `/var/run/docker.sock` (bind-mounted into container) |
| Dockhand data | `/srv/data/dockhand/data` (host bind-mount) |
| Docker data | `/srv/data/docker` (host bind-mount) |
| Rootfs | 32GB on ZFS-backed LXD storage |
| OS | Ubuntu (from LXD image remote) |

## Repository Layout

```
plh-docker/
├── deploy-plh-docker.sh             # Pure-bash deploy: LXC + Docker + Dockhand
├── configure-hlh-docker.sh          # Configuration helper
├── ADR-001.md                       # Architecture Decision Record
├── 00_BACKLOG.md                    # Backlog / ideas
├── 10_ACTIVE.md                     # Active work items
├── 90_DONE.md                       # Completed items
├── CHANGELOG.md                     # Version history
└── 98_README.md                     # This file
```

## Governance

This repo is a component of `iac-plh`. Deployments use pinned commits for deterministic
results. See the PLH Agile Design Handbook for the full architecture and dependency map.
