# iac-plh

Infrastructure-as-Code for the PLH (Personal Lab Hardware) laptop environment.
Brings the same IaC patterns from iac-hlh to a CachyOS laptop with LXD.

## Executive Summary

`iac-plh` provides reproducible AI inference infrastructure on a laptop using
LXD containers. It mirrors the `iac-hlh` architecture but targets a mobile
workstation with an NVIDIA RTX 2060M GPU.

- Host: Alienware M17 R2, CachyOS (Arch Linux)
- Virtualization: LXD system containers
- GPU: NVIDIA RTX 2060M (CUDA passthrough)
- AI Stack: LocalAI + llama.cpp with GGUF models

## Architecture Overview

```mermaid
graph TD
    subgraph HOST["CachyOS Laptop (Alienware M17 R2)"]
        OPS[apply.bash]
        subgraph LXC["LXD Containers"]
            ENG[engine LXC<br/>LocalAI + llama.cpp<br/>Port 8080]
            LLAMA[llama-direct LXC<br/>llama-server + CUDA<br/>Port 8090]
        end
        OPS --> ENG
        OPS --> LLAMA
        MODELS[/srv/ai/models<br/>GGUF Models/]
        MODELS -->|read-only mount| ENG
    end

    subgraph GPU["NVIDIA RTX 2060M"]
        CUDA[CUDA / libnvidia]
        GPU_DEV[/dev/nvidia*]
    end

    ENG --> GPU
```

## Quick Start

```bash
# 1. Bootstrap the CachyOS host
./bootstrap/bootstrap-laptop-cachyos.sh

# 2. Apply the inventory configuration
./apply.bash inventory/alienware-m17r2.yaml

# Plan-only (dry run)
./apply.bash --plan inventory/alienware-m17r2.yaml
```

## Repository Boundary

**Owns:**
- LXD host bootstrap (LXD daemon, network, storage pool, GPU drivers)
- LXD container reconciliation from YAML platform definitions
- AI inference runtime (LocalAI, llama.cpp, llama-server)
- GPU passthrough configuration (NVIDIA, AMD, Intel profiles)
- Model management and deployment

**Does not own:**
- Application business logic (TrashPanda, BrickCipher, VoxChimera)
- Proxmox infrastructure (that is `iac-hlh`)
- Docker host management (that is `hlh-docker`)

## Key Artifacts

| Artifact | Purpose |
|----------|---------|
| `apply.bash` | Inventory-driven LXD reconciliation runner |
| `bootstrap/` | Host bootstrap scripts (CachyOS, LXD init) |
| `inventory/` | Host-specific YAML configs |
| `platforms/` | Declarative LXC container definitions |
| `profiles/` | LXD GPU passthrough profiles (NVIDIA, AMD, Intel) |
| `scripts/` | Runtime provisioning scripts (LocalAI, llama.cpp, n8n) |
| `docs/architecture.md` | Full architecture documentation |

## Inventory

Two host configurations are available:

- `inventory/alienware-m17r2.yaml` — Production engine (LocalAI + llama.cpp)
- `inventory/alienware-m17r2-llama.yaml` — llama-direct (llama-server + CUDA)

## Endpoints

| Service | Port | Description |
|---------|------|-------------|
| LocalAI API/UI | 8080 | OpenAI-compatible API + llama.cpp WebUI |
| llama-server | 8090 | Standalone llama.cpp HTTP server |
