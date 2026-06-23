# hlh-docker

Infrastructure-as-Code for the HLH Docker container host. Deploys an unprivileged
LXC running Docker, Dockhand, and LazyDocker on Proxmox — pure bash, no Terraform,
no Ansible, no OpenTofu.

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

Deploy the Docker LXC (must run on the Proxmox host with `pct` available):

```bash
cd ~/git/iac-hlh/hlh-docker
./deploy-hlh-docker.sh --apply
```

Plan only (dry-run):

```bash
./deploy-hlh-docker.sh --plan
```

Configure an existing LXC without recreating it:

```bash
./deploy-hlh-docker.sh --config-only
```

Destroy and rebuild from scratch:

```bash
./deploy-hlh-docker.sh --nuke --apply
```

## Deployment Model

Everything is handled in a single pure-bash script. No Terraform, no Ansible,
no OpenTofu.

1. **LXC creation**: `pct create` from the Ubuntu 26.04 template
2. **Start & bootstrap**: Container is started, SSH key deployed, bind mounts
   wired
3. **Software install**: Docker Engine, Dockhand, and LazyDocker installed
   via `pct exec` inside the running container

## Configuration

All settings are configurable via environment variables:

| Variable | Default | Description |
|--------|---------|-----------|
| `HLH_LXC_VMID` | 102 | Container ID |
| `HLH_LXC_HOSTNAME` | hlh-docker | Container hostname |
| `HLH_LXC_IP` | 192.168.1.13 | Container IP address |
| `HLH_LXC_GW` | 192.168.1.1 | Gateway address |
| `HLH_LXC_NET` | vmbr0 | Bridge interface |
| `HLH_TARGET_NODE` | prox01 | Proxmox node name |
| `HLH_CORES` | 4 | vCPU count |
| `HLH_MEMORY` | 4096 | Memory in MB |
| `HLH_DISK` | 32 | Rootfs size in GB |
| `HLH_DISK_POOL` | RaidZ1-6TB | ZFS storage pool |
| `HLH_NESTING` | 1 | Enable nesting |
| `HLH_SSH_KEY` | ~/.ssh/id_ed25519.pub | SSH public key for bootstrap |

Example with custom IP:

```bash
HLH_LXC_IP=192.168.1.14 ./deploy-hlh-docker.sh --apply
```

## ADR

See `ADR-001.md` for the full architecture decision: unprivileged LXC, Docker +
Dockhand + LazyDocker, ZFS storage, VLAN-aware networking.

## Runtime Contract

| Item | Value |
|------|-------|
| Host IP | 192.168.1.13 |
| Dockhand GUI | http://192.168.1.13:80 |
| Docker socket | /var/run/docker.sock (bind-mounted into LXC) |
| Dockhand data | /srv/dockhand/data (host ZFS mount) |
| Docker data | /var/lib/docker (host ZFS mount) |
| Rootfs | 32GB on `RaidZ1-6TB` ZFS pool |
| OS | Ubuntu 26.04 LTS |

## Repository Layout

```
hlh-docker/
├── deploy-hlh-docker.sh          # Pure-bash deploy: LXC + Docker + Dockhand
├── configure-hlh-docker.sh       # Pure-bash configuration helper
├── ADR-001.md                    # Architecture Decision Record
├── ADR-002.md                    # Architecture Decision Record
├── 00_BACKLOG.md                 # Backlog / ideas
├── 10_ACTIVE.md              # Active work items
├── 90_DONE.md                    | Completed items
├── 98_README.md                  | Working notes
├── CHANGELOG.md                  | Version history
└── README.md                     | This file
```

## Governance

This repo is a component of `iac-hlh`. Deployments use pinned commits for
deterministic results. See the HLH Agile Design Handbook for the full
architecture and dependency map.