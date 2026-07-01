# BACKLOG

Items for future implementation. These are human-entered ideas not yet reflected
in the codebase.

## Container Host

- Add LXD snapshot before major Docker version updates.
- Add container health check endpoint in configure script.
- Add automatic container restart on crash (LXD boot.autostart + systemd watchdog).
- Add resource quota enforcement (CPU, memory, I/O limits via `lxc config set`).
- Add ZFS dataset creation for new app data volumes on CachyOS host.

## Docker Services

- Deploy Uptime Kuma as monitoring service (mentioned in service repos).
- Add Docker Compose stack for service grouping.
- Implement Docker network creation for per-app segmentation.
- Add LXD network bridge for per-app IP assignment.

## Dockhand

- Add Dockhand backup/restore procedure.
- Add Dockhand configuration export/import.
- Monitor Dockhand container health (currently done via deploy script verify).

## Bash Script Improvements

- Add shellcheck CI to CI workflow.
- Add idempotency tests for deploy script.
- Add `--verbose` flag for detailed logging.
- Add error handling with rollback on failure.

## LXD Improvements

- Add LXD profile for reusable configuration templates.
- Add LXD snapshot management before major upgrades.
- Add LXD backup/restore for the entire container.
- Add LXD image creation for cached Docker + Dockhand setup.

## Networking

- Add LXD managed network configuration.
- Add per-application networking via LXD networks.
- Add Docker network isolation for multi-app deployments.

## Observability

- Add Docker metrics endpoint for container health.
- Add structured logging for Dockhand.
- Add health check endpoint for orchestration.
- Add container resource usage monitoring.

## Deployment

- Add pre-flight checks for Docker compatibility on host.
- Add rollback procedure for failed deployments.
- Add CI checks for shell scripts (shellcheck).
- Add SemVer tagging for release history.
