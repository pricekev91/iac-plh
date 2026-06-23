# DONE

This is what is already implemented and verified in this repository.

## ADRs

- ADR-001: Container host architecture for HLH (unprivileged LXC, Docker + Dockhand + LazyDocker, vmid 102)

### Fixed

- Fix dockhand container port mapping: map host port 80 to container port 3000 (dockhand listens on 3000, not 8080)

### Added

- Modular orchestrator skeleton under `infra/docker`, `infra/dockhand`, and `infra/k8s`.
- Shared module placeholders under `infra/modules/logging`, `infra/modules/storage`, and `infra/modules/networking`.
- Operator scripts `scripts/apply.sh`, `scripts/verify.sh`, and `scripts/destroy.sh`.
- Configuration defaults file `config/defaults.yaml`.
- Task tracking docs `TODO.md` and `BACKLOG.md`.

## LXC Deployment

- Unprivileged LXC 102 on Proxmox via OpenTofu (bpg/proxmox provider >= 0.66.0)
- Hostname: `hlh-docker`
- IP: `192.168.1.13/24`
- Resources: 4 vCPU, 4096 MB RAM, 1024 MB swap, 32GB rootfs on `RaidZ1-6TB`
- Features: nesting + keyctl (required for Docker inside LXC)
- OS: Ubuntu 26.04 LTS (zst template)
- VLAN-aware networking (tag reserved for future per-app segmentation)

## OpenTofu Module

- Proxmox provider: `bpg/proxmox >= 0.66.0`
- API token or username/password auth
- Variables for endpoint, credentials, node, ostemplate, cores, memory, network tag
- Outputs: lxc_vmid, lxc_hostname

## Ansible Roles

### docker-engine
- Docker GPG key installation and repository setup
- Installs: docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin, docker-compose-plugin
- Ensures Docker service is enabled and running

### dockhand
- Pulls `fnsys/dockhand:latest` from Docker Hub
- Deploys as container with `/srv/dockhand` data persistence
- Exposes on port 80 (maps to container 3000)
- Verifies container is running after deployment

### lazydocker
- Downloads and installs v0.25.2 from GitHub releases
- Supports offline mode with pre-pinned binary
- Installs to `/usr/local/bin/lazydocker`

## Ansible Configuration

- Inventory: `ansible/inventories/hlh-docker.yml` (target: 192.168.1.13)
- Playbook: `ansible/playbooks/hlh-docker.yml`
- Requirements: `community.docker >= 3.4.0`
- SSH auth: key-based (`~/.ssh/id_ed25519`)
- Offline mode support: `hlh_offline` variable

## Configuration Scripts

### deploy-hlh-docker.sh
- Two-stage workflow: OpenTofu provisioning + Ansible configuration
- Modes: `--plan`, `--apply`, `--tf-only`, `--config-only`, `--offline`
- API auth: supports both API tokens and username/password
- Auto-probes Proxmox API for credential validation
- Host override for Ansible stage via `--host`

### configure-hlh-docker.sh
- Standalone Ansible configuration stage
- Offline mode support
- SSH key or password auth options

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
