# hlh-docker

Infrastructure-as-Code for the HLH Docker container host. Deploys an unprivileged
LXC running Docker, Dockhand, and LazyDocker on Proxmox.

## Executive Summary

This repository deploys and configures the **Docker LXC** on the HLH Proxmox host.
The Docker host provides a secure, reproducible container runtime for application
service stacks (Dockhand, LazyDocker).

- LXC 102, hostname `hlh-docker`, IP `192.168.1.13`
- Unprivileged LXC with nesting + keyctl
- Docker Engine + Dockhand (GUI) + LazyDocker (TUI)
- 4 vCPU, 4GB RAM, 32GB rootfs on `RaidZ1-6TB` ZFS pool

## Repository Boundary

**Owns:**
- Unprivileged Docker LXC lifecycle (create, configure, start) on Proxmox
- Docker Engine installation and configuration
- Dockhand and LazyDocker deployment
- ZFS storage mount wiring for persistent data

**Does not own:**
- Proxmox host configuration (that is `iac-hlh`)
- Docker container application logic (that is the service repos)
- AI engine deployment (that is `hlh-ai-engine`)

## Quick Start

Deploy the Docker LXC:

```bash
./deploy-hlh-docker.sh --apply
```

Plan only:

```bash
./deploy-hlh-docker.sh --plan
```

Configure an existing LXC (no OpenTofu):

```bash
./deploy-hlh-docker.sh --config-only
```

## Deployment Model

Deployment and configuration are separate phases:

1. **Provisioning**: `deploy-hlh-docker.sh` runs OpenTofu to create the unprivileged LXC
   with Docker-ready configuration (nesting, keyctl, VLAN support).
2. **Configuration**: Ansible roles install Docker Engine, Dockhand, and LazyDocker.

## ADR

See `ADR-001.md` for the full architecture decision: unprivileged LXC, Docker + Dockhand
+ LazyDocker, ZFS storage, VLAN-aware networking.

## Runtime Contract

| Item | Value |
|------|-------|
| Host IP | `192.168.1.13` |
| Dockhand GUI | `http://192.168.1.13:80` |
| Docker socket | `/var/run/docker.sock` (inside LXC) |
| Dockhand data | `/srv/dockhand` (host mount) |
| Rootfs | 32GB on `RaidZ1-6TB` ZFS pool |
| OS | Ubuntu 26.04 LTS |

## Repository Layout

```
hlh-docker/
├── deploy-hlh-docker.sh             # OpenTofu + Ansible two-stage deploy
├── configure-hlh-docker.sh          # Ansible-only configuration
├── ansible/
│   ├── inventories/hlh-docker.yml
│   ├── playbooks/hlh-docker.yml
│   ├── requirements.yml
│   └── roles/
│       ├── docker-engine/tasks/main.yml
│       ├── dockhand/tasks/main.yml
│       └── lazydocker/tasks/main.yml
├── opentofu/
│   ├── main.tf
│   └── variables.tf
├── ADR-001.md
├── 00_BACKLOG.md
├── 10_ACTIVE.md
├── 90_DONE.md
├── CHANGELOG.md
└── 98_README.md
```

## Governance

This repo is a component of `iac-hlh`. Deployments use pinned commits for deterministic
results. See the HLH Agile Design Handbook for the full architecture and dependency map.
