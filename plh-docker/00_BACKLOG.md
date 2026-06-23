# BACKLOG

Items for future implementation. These are human-entered ideas not yet reflected
in the codebase.

## Container Host

- Add LXC snapshot before major Docker version updates.
- Add LXC health check endpoint in configure script.
- Add automatic LXC restart on crash (systemd watchdog).
- Add resource quota enforcement (CPU, memory, I/O limits).
- Add ZFS dataset creation for new app data volumes.

## Docker Services

- Deploy Uptime Kuma as monitoring service (mentioned in iac-hlh services/).
- Add Docker Compose stack for service grouping.
- Add Docker network creation for per-app segmentation.
- Implement VLAN-aware networking (ADR-003 placeholder).

## Dockhand

- Add Dockhand backup/restore procedure.
- Add Dockhand configuration export/import.
- Monitor Dockhand container health (currently done via Ansible assert).

## Ansible Improvements

- Add ansible-lint to CI workflow.
- Split configure role into multiple Ansible roles (docker, dockhand, lazydocker already separated).
- Add idempotency tests for ansible playbook.
- Add ansible-galaxy role packaging for reuse.

## OpenTofu

- Add tofu variables for VLAN tag (currently hardcoded to 0).
- Add tofu output for container IP address.
- Add tofu state locking for multi-operator safety.
- Add tofu data source for Proxmox node validation.

## Networking

- Add VLAN-aware bridge configuration per ADR-001.
- Add per-application IP assignment via VLAN tagging.
- Add Docker network isolation for multi-app deployments.

## Observability

- Add Docker metrics endpoint for container health.
- Add structured logging for Dockhand.
- Add health check endpoint for orchestration.
- Add container resource usage monitoring.

## Deployment

- Add pre-flight checks for Docker compatibility on host.
- Add dry-run / plan mode for deploy script (already exists).
- Add rollback procedure for failed deployments.
- Add CI checks for shell scripts (shellcheck).
- Add SemVer tagging for release history (see backlog: "Adopt SemVer tagging across all repos for rollback safety").
