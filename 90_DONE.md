# DONE

This is what is already implemented and verified in this repository.

## Host Bootstrap

- `bootstrap/bootstrap-laptop-cachyos.sh`: CachyOS Arch Linux host bootstrap
  - Installs LXD and initializes the LXD daemon
  - Configures network bridge and storage pool
  - Sets up user group permissions for LXD access
  - Configures NVIDIA driver for RTX 2060M passthrough
  - Installs system packages (timeshift, grub-btrfs, steam, libreoffice)
  - AUR packages via paru (Edge, Chrome, OneDrive, Mission Center)

- `bootstrap/arch-cachyos.bash`: OS-specific bootstrap entrypoint
- `bootstrap/arch-lxd-bootstrap.sh`: LXD initialization script
- `bootstrap/arch-lxd-bootstrap.fish`: Fish shell variant
- `bootstrap-cachyos.sh`: Combined CachyOS bootstrap wrapper
- `bootstrap-lxd-host.sh`: LXD host preparation script

## Apply Runner

- `apply.bash` (1493 lines): Inventory-driven LXD reconciliation runner
  - Validates inventory YAML and platform configuration
  - Ensures LXD host prerequisites (subid ranges, storage pools, network)
  - Creates LXD projects and applies LXD profiles
  - Reconciles containers from platform YAML definitions
  - Handles GPU device mapping via vendor-specific profiles
  - Manages storage mount configuration
  - Configures port bindings with local-only or LAN exposure
  - Detects current engine backend (llama-cpp vs ollama)
  - Supports `--plan` mode for dry-run reconciliation
  - Handles legacy project cleanup after migrations
  - Supports host auto-bootstrap when LXD prerequisites are missing

## Platform Definitions

- `platforms/engine.yaml`: Main AI engine platform
  - Ubuntu 24.04 LXC container
  - LocalAI + llama.cpp backend on port 8080
  - NVIDIA RTX 2060M GPU passthrough via LXD profile
  - Host model directory mounted read-only
  - Model: Qwopus3.6-35B-A3B-v1-Q4_K_M.gguf
  - Context size: 32768, GPU layers: 60, Threads: 8

- `platforms/llama-direct.yaml`: Standalone llama-server platform
  - Ubuntu 24.04 LXC container
  - llama.cpp server with CUDA support (GPU layers: 0)
  - Model: Ministral-3-3B-Instruct-2512-Q5_K_M.gguf
  - Port 8090 on host
  - Host `/usr/lib` mounted to `/opt/host-lib` for CUDA libs

## Inventory

- `inventory/alienware-m17r2.yaml`: Main production config (engine platform)
- `inventory/alienware-m17r2-llama.yaml`: Alternative config (llama-direct platform)

## GPU Profiles

- `profiles/gpu-nvidia.yaml`: NVIDIA GPU passthrough (vendorid: 10de)
- `profiles/gpu-amd.yaml`: AMD GPU passthrough template
- `profiles/gpu-intel.yaml`: Intel GPU passthrough template

## Provisioning Scripts

- `scripts/provision-ai-appliance.bash`: LocalAI binary install + systemd service
  - Downloads LocalAI latest release for x86_64/arm64
  - Installs nginx as reverse proxy
  - Configures systemd unit for ai-engine-localai service
  - Idempotent: skips if binary already present

- `scripts/provision-llama-direct.bash`: Standalone llama-server provisioning
  - Clones and builds llama.cpp from source with CUDA support
  - Installs and configures llama-server systemd service
  - Idempotent: skips if binary already built

- `scripts/provision-ollama.bash`: Ollama runtime provisioning
- `scripts/provision-crewai.bash`: CrewAI agent provisioning
- `scripts/provision-n8n.bash`: n8n orchestrator provisioning
- `scripts/provision-openwebui.bash`: Open WebUI provisioning

## Documentation

- `docs/architecture.md`: Comprehensive 13-section architecture document
  - Executive intent, technology stack, IaC structure
  - Inventory and platform YAML schemas
  - Apply runner contract and execution flow
  - Bootstrap lifecycle, snapshot/rollback flow
  - Current state vs target state, roadmap
  - Security model, automation goals, risks

- `docs/projects/lego-project-charter.md`: Lego project charter
- `docs/projects/lego-project-projections.md`: Lego project projections

## Repository Layout

```text
iac-plh/
├── apply.bash                  # Inventory-driven LXD reconciliation runner (1493 lines)
├── bootstrap/                  # Host bootstrap scripts (5 scripts)
├── inventory/                  # Host-specific YAML configs (2 files)
├── platforms/                  # Declarative LXC definitions (2 active)
├── profiles/                   # LXD GPU profiles (3 vendor profiles)
├── scripts/                    # Runtime provisioning scripts (7 scripts)
├── docs/                       # Architecture and project docs
│   ├── architecture.md
│   └── projects/
├── legacy/                     # Legacy laptoplab codebase
├── SESSION_STATE.md
├── package.json                # npm dependency: ai-engine-client
└── README.md                   # (empty, to be populated)
```
