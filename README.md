# iac-plh

Infrastructure-as-Code repository for a portable, self-hosted AI appliance on a personal laptop using CachyOS + LXD.

This repository brings the design and operational patterns from `iac-hlh` (Proxmox-based HLH host) to a laptop environment, replacing Proxmox with LXD for container management and targeting local inference with NVIDIA GPU acceleration.

## Executive Summary

As of May 2026, `iac-plh` provides a **single shared AI runtime** on a CachyOS laptop:

- `engine` LXC (privileged container, DHCP/NAT networking)
- Native `LocalAI` service with `llama-cpp` backend
- `nginx` reverse proxy for LocalAI UI/API exposure on port `8080`
- Host-mounted model/state/scratch paths for persistent operation
- NVIDIA RTX 2060M GPU passthrough via LXD device mapping

This design preserves the same **end-user experience** as `iac-hlh` (LocalAI on 8080, no separate WebUIs), while adapting the control plane from Proxmox to LXD.

## Scope And Governance Boundary

`iac-plh` owns:

- CachyOS LXD initialization and setup
- LXC lifecycle reconciliation (launch/config/start/provision)
- Host storage and bind-mount contracts
- Network DHCP/NAT and port publishing policy
- shared AI appliance deployment and guardrails
- NVIDIA GPU device passthrough configuration

`iac-plh` does not own:

- application business logic or integration code
- product-specific prompts, schemas, or dashboards
- application-specific compose stacks

## Current State (Verified)

The active reconciliation path is:

1. `./apply.bash --plan inventory/alienware-m17r2.yaml`
2. `./apply.bash inventory/alienware-m17r2.yaml`

`apply.bash` currently reconciles only the shared `engine` stack using LXD and `lxc` CLI commands.

### Runtime Contract

- UI/API endpoint: `http://127.0.0.1:8080` (accessible on local network via host IP)
- Direct LocalAI endpoint: `http://127.0.0.1:8081`
- OpenAI-compatible API base: `http://127.0.0.1:8081/v1/`
- Model configs: `/srv/ai/models/*.yaml`
- Persistent host mounts:
  - `/srv/ai/models` -> `/srv/ai/models`
  - `/srv/ai/state` -> `/srv/ai/state`
  - `/srv/ai/scratch` -> `/srv/ai/scratch`

### Capacity Profile (Current Inventory)

- CPU: 12 cores
- memory: 48 GiB
- privileged LXC with nesting/keyctl enabled
- NVIDIA RTX 2060M GPU with 4 GiB VRAM
- GPU layers: 60 (optimized for 2060M)

## Layered Architecture (Text Diagram)

```text
Layer 5 - Client Applications / Browsers
  - ChromeBooks, laptops access LocalAI at port 8080
  - No direct ownership of host/LXC mechanics

Layer 4 - Shared Service Contract
  - Engine endpoint contract (8080/8081)
  - Model and inference tuning contract via YAML
  - Runtime health and readiness expectations

Layer 3 - Application Runtime (Inside engine LXC)
  - LocalAI binary + llama-cpp backend
  - CUDA-capable inference using RTX 2060M
  - nginx reverse proxy
  - systemd-managed services and readiness checks

Layer 2 - Infrastructure Reconciliation (CachyOS Host + LXD)
  - apply.bash parses platform + inventory YAML
  - lxc launch/config/start + mount/device orchestration
  - provisioning script push/exec and safety guardrails

Layer 1 - Physical/Host Foundation (Laptop)
  - CachyOS Arch Linux with LXD daemon
  - NVIDIA drivers and GPU binding
  - shared LXD storage and networking bridge
```

## Control And Data Flow (Text Diagram)

```text
Operator/User
  |
  |  ./apply.bash [--plan] inventory/alienware-m17r2.yaml
  v
CachyOS Host (with LXD daemon)
  |
  |-- lxc launch (LXC container creation)
  |-- lxc config set (CPU/memory limits)
  |-- lxc config device add (mounts + GPU)
  |-- lxc start (container boot)
  |-- lxc file push + lxc exec (provision-ai-appliance.bash)
  v
Engine LXC (DHCP-bridged, port 8080 published to host)
  |
  |-- local-ai service (port 8081, CUDA-accelerated)
  |-- nginx proxy (port 8080)
  |-- /srv/ai/models/*.yaml inference config
  v
Local Network / Client Browsers / ChromeBooks
  |
  |-- HTTP requests to 192.168.x.y:8080 (host IP)
  |-- OpenAI-compatible requests -> /v1/*
  |-- receive local GPU-accelerated inference responses
```

## Repository Layout

```text
iac-plh/
├── apply.bash                        # LXD reconciliation operator
├── inventory/
│   └── alienware-m17r2.yaml          # Laptop-specific desired state
├── platforms/
│   └── engine.yaml                   # Shared AI runtime baseline
├── scripts/
│   └── provision-ai-appliance.bash   # In-container provisioning
├── bootstrap/
│   └── arch-cachyos.bash             # Initial CachyOS LXD setup
└── docs/
    ├── architecture.md
    └── README.md
```

## Operational Notes For Leadership

- **Current maturity**: production-capable single-engine LXC with NVIDIA acceleration and reconciliation.
- **Portability**: same operator workflow and end-user contract as `iac-hlh`, but adapted to LXD/CachyOS.
- **GPU acceleration**: optimized for NVIDIA RTX 2060M with tunable GPU layer count and inference parameters.
- **Network accessibility**: container exposed via DHCP/NAT with port publishing, making the service accessible from other devices on the local network.
- **Governance model**: strict separation between host infrastructure ownership (`iac-plh`) and application repository ownership.

For detailed architecture, operating model, and risk posture, see `docs/architecture.md`.
- `platforms/agents.yaml`
- `scripts/provision-ai-engine.bash`
- `scripts/provision-openwebui.bash`
- `scripts/provision-ollama.bash`
- `scripts/provision-n8n.bash`
- `scripts/provision-crewai.bash`
- `profiles/gpu-nvidia.yaml`
- `profiles/gpu-amd.yaml`
- `profiles/gpu-intel.yaml`
- `apply.bash`

`apply.bash` is the main operator entrypoint. In apply mode it can bootstrap an Arch/CachyOS host into a usable LXD baseline before reconciling the declared container state.

Current operator commands:

- `./apply.bash` prints the currently detected engine backend for `prod/engine` and the supported engine options.
- `./apply.bash inventory/<host>.yaml llama-cpp` reconciles the engine container as the `llama.cpp` appliance backend.
- `./apply.bash inventory/<host>.yaml ollama` reconciles the engine container as the `ollama` appliance backend and restores the `presentation` Open WebUI layer on host port `3000`.
- switching the requested engine backend replaces `prod/engine` so the runtime stays consistent instead of mutating in place.

## Engine Operator Workflow

Use the engine as the main operator-facing API and UI surface.

List the currently loaded model metadata through the appliance API:

```bash
curl -fsS http://127.0.0.1:8080/v1/models | jq
```

Open the engine UI in a browser:

```text
http://127.0.0.1:8080
```

Check the engine health endpoint:

```bash
curl -fsS http://127.0.0.1:8080/health | jq
```

Check the local engine manager status endpoint:

```bash
curl -fsS http://127.0.0.1:18080/engine/status | jq
```

When the engine backend is `ollama`, apply provisions `qwen2.5-coder:7b` as the default pulled model unless you change `OLLAMA_DEFAULT_MODEL` in the engine platform definition.

Point OpenAI-compatible local clients at the engine endpoint:

```text
OPENAI_API_BASE_URL=http://127.0.0.1:8080/v1
OPENAI_API_KEY=local-engine
```

## Archived Legacy State

The previous repo state was preserved locally as:

- branch: `archive/windows-wsl-legacy`
- tag: `archive-windows-wsl-2026-04-22`

## Next Build Targets

1. Harden the new `orchestrator` and `agents` services beyond baseline package install and startup.
2. Add monitoring and promotion workflows.
3. Add mirrored artifact and package cache support for stricter offline rebuild behavior.
4. Reintroduce a separate `dev` environment only when there is a concrete need for it.
5. Refine Intel GPU profile once Intel hardware is available.
