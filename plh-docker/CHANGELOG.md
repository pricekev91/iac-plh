# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Fix dockhand container port mapping: host 80 maps to container 3000 (dockhand listens on 3000, not 8080)

## [0.2.2] - 2026-06

### Fixed

- Flatten repository layout to repo root (8ca58d9)

## [0.2.1] - 2026-05

### Fixed

- Remove fuse feature flag - requires root@pam for unprivileged LXC (6cecc14)
- Remove --strip-components=1 from unarchive (66922b7)
- Use pinned URL with v0.25.2 for lazydocker, remove invalid check_mode (622afd7)
- Use port 80 for dockhand, fix lazydocker checksum param (245d7a1)
- Remove existing container before docker run and remove broken failed_when conditional (5a72798)
- Fix Jinja escaping in dockhand status check (632f28c)

## [0.2.0] - 2026-05

### Changed

- Switch OpenTofu provider from telmate/proxmox to bpg/proxmox (54b7aec)
- Simplify hlh-docker workflow to two scripts (d618cab)

### Fixed

- Fix offline boolean handling in ansible flow (e634eab)
- Set ANSIBLE_ROLES_PATH for local hlh-docker roles (dba3ace)
- Bootstrap LXC SSH auth in configure flow (869ebaa)

### Added

- Add API token auth path and Proxmox auth preflight (a5a5e5f)
- Add ask-pass mode for ansible SSH auth (c090f58)
- Auto-refresh SSH host keys before ansible run (c1ec799)
- Install ansible via apt not pip (9efc8a8)
- Auto-install ansible if missing (2eea1a1)

## [0.1.0] - 2026-04

### Added

- Initial Docker LXC scaffolding
- OpenTofu module for Proxmox LXC provisioning (telmate/proxmox)
- Ansible roles: docker-engine, dockhand, lazydocker
- deploy-hlh-docker.sh: LXC creation + Ansible configuration
- configure-hlh-docker.sh: in-container Ansible configuration
- ADR-001: Container host architecture for HLH
