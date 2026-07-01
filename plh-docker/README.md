# plh-docker

Infrastructure-as-Code for the PLH Docker container host. Deploys an unprivileged LXD container running Docker, Dockhand, and LazyDocker on LXD — pure bash.

## Executive Summary

This repository deploys and configures the **Docker LXC** on the PLH host using LXD. The Docker host provides a secure, reproducible container runtime for application service stacks (Dockhand, LazyDocker).

- LXC container `plh-docker` managed by LXD 6.9
- Unprivileged container with Docker-in-LXC support
- Docker Engine + Dockhand (GUI) + LazyDocker (TUI)
- ZFS-backed storage (LXD default)

## Repository Boundary

**Owns:**
- Unprivileged Docker container lifecycle (create, configure, start) on LXD
- Docker Engine installation and configuration
- Dockhand and LazyDocker deployment

**Does not own:**
- LXD host configuration (OS-level setup)
- Docker container application logic (that is the service repos)
- AI engine deployment (that is `hlh-ai-engine`)

## Quick Start

Deploy the Docker container (requires `lxc` and `docker` installed on the host):

```bash
cd ~/git/iac-plh/plh-docker
./deploy-plh-docker.sh --apply
```

Plan only (dry-run):

```bash
./deploy-plh-docker.sh --plan
```

Configure an existing container without recreating it:

```bash
./deploy-plh-docker.sh --config-only
```

Destroy and rebuild from scratch:

```bash
./deploy-plh-docker.sh --nuke --apply
```

## Deployment Model

Everything is handled via LXD's native CLI (`lxc`).

1. **Container creation**: `lxc launch ubuntu:latest plh-docker`
2. **Bootstrap**: Container is started, SSH key deployed, bind mounts wired
3. **Software install**: Docker Engine, Dockhand, and LazyDocker installed via `lxc exec`

## Configuration

All settings are configurable via environment variables:

| Variable | Default | Description |
|--------|---------|-----------|
| `PLH_LXC_NAME` | plh-docker | Container name |
| `PLH_LXC_IMAGE` | ubuntu:latest | Ubuntu image to use |
| `PLH_LXD_REMOTE` | ubuntu: | LXD image remote |
| `PLH_NESTING` | 1 | Enable nesting for Docker |
| `PLH_SSH_KEY` | ~/.ssh/id_ed25519.pub | SSH public key for bootstrap |

## Runtime Contract

| Item | Value |
|------|-------|
| Container name | plh-docker |
| Dockhand GUI | http://<container-ip>:80 |
| Docker socket | /var/run/docker.sock (bind-mounted into container) |
| Dockhand data | /srv/dockhand/data (host ZFS mount) |
| Docker data | /var/lib/docker (host ZFS mount) |
| OS | Ubuntu (from LXD image remote) |

## Repository Layout

```
plh-docker/
├── deploy-plh-docker.sh        # Pure-bash deploy: LXC + Docker + Dockhand
├── configure-hlh-docker.sh     # Configuration helper (legacy, keep for compat)
├── ADR-001.md                  # Architecture Decision Record
├── 00_BACKLOG.md               # Backlog / ideas
├── 10_ACTIVE.md                # Active work items
├── 90_DONE.md                  # Completed items
├── 98_README.md                # Working notes
├── CHANGELOG.md                # Version history
└── README.md                   # This file
```

## Governance

This repo is a component of `iac-plh`. Deployments use pinned commits for deterministic results.
