# BACKLOG

Items for future implementation. These are human-entered ideas not yet reflected
in the codebase.

## Apply Runner

- Add snapshot orchestration before destructive container mutation
- Add replacement rollout logic for platform changes
- Add LXD project cleanup after legacy project migrations
- Add pre-flight validation for GPU availability before apply
- Add apply --dry-run mode that prints full reconciliation plan

## Bootstrap

- Add Debian/Proxmox bootstrap script path
- Add automated NVIDIA driver installation detection
- Add AMD GPU driver bootstrap (amdgpu + VFIO)
- Add LXD subid/subgid range auto-configuration for CachyOS

## Inventory

- Add inventory files for additional laptop hosts
- Add staging/development inventory environments
- Add project_migrations cleanup automation after apply

## Platform Expansion

- Restore orchestrator platform (n8n) when n8n provisioning is ready
- Restore agents platform (CrewAI) when CrewAI provisioning is ready
- Add presentation platform (Open WebUI) with ollama backend support
- Add multi-platform reconcile with inter-container networking

## LXD Profiles

- Add `gpu-intel.yaml` for Intel integrated GPU passthrough
- Add `gpu-amd.yaml` for AMD GPU passthrough (gfx1150/890M)
- Add network profile for container bridge isolation

## Services

- Add health check scripts for each service endpoint
- Add service startup ordering (engine before orchestrator/agents)
- Add graceful shutdown procedure for all services

## Observability

- Add LXD container resource usage monitoring
- Add inference performance benchmarking script
- Add GPU utilization monitoring dashboard
- Add service uptime logging

## Documentation

- Add runbook for common failure scenarios (GPU passthrough, LXD connectivity)
- Add disaster recovery procedure for host + LXD state
- Add architecture diagram update for single-engine consolidation
- Add inventory schema documentation

## Hardware Migration

- Add AMD GPU migration path (gfx1150/890M) from NVIDIA RTX 2060M
- Add ROCm compatibility testing for AMD GPUs
- Add hardware-agnostic platform definitions
