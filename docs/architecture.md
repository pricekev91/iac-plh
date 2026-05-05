# Architecture

## 1. Project Vision

### 1.1 Purpose

Build a self-hosted, vendor-agnostic AI appliance that provides local LLM inference, UI access, agentic access, future orchestration, and supporting tooling across multiple machines using reproducible Infrastructure-as-Code.

### 1.2 Requirements

The system must:

- Operate fully offline during real-world use after an online build, update, and preload phase
- Avoid paid AI services
- Be hardware-agnostic across supported CPU and GPU combinations
- Be reproducible, auditable, and long-lived
- Support snapshots and rollback as first-class lifecycle operations
- Require idempotent bootstrap and apply workflows, or explicit prerequisite failures when idempotency cannot be achieved automatically

### 1.3 Long-Term Objective

A portable, deterministic AI platform that can:

- Bootstrap on any compatible host
- Migrate across hardware generations
- Extend with new models, UIs, and tooling
- Maintain stability with minimal drift

## 2. High-Level Architecture

### 2.1 Logical Layers

- Host Layer: Minimal OS plus LXD substrate
- Platform Layer: LXD project `prod` today, with optional future `dev`
- Service Layer: Containers providing inference, presentation, orchestration, and agentic services
- Client Layer: Editors, browsers, and CLI tools consuming API and UI endpoints

### 2.2 Physical Layout

Initial host:

- Alienware M17 R2 running CachyOS or another Arch-family distribution

Future hosts:

- MINISFORUM N5 Pro running Proxmox or Debian-family Linux
- Additional compatible hosts

Each host runs:

- Arch-family Linux or Debian/Proxmox
- LXD daemon
- IaC-driven configuration

### 2.3 Component Relationships

- Host OS -> LXD
- LXD -> Projects
- Projects -> Containers
- Containers -> Shared model storage
- Clients -> API and UI endpoints

### 2.4 Data Flow

1. Client sends prompt.
2. API container loads the configured model.
3. GPU or CPU performs inference.
4. Response is returned to the client.

## 3. Technology Stack

### 3.1 Host OS

- Arch Linux or CachyOS
- Debian or Proxmox 9.x

### 3.2 Virtualization

- LXD system containers
- LXD projects for isolation

### 3.3 AI Stack

- `llama.cpp` now
- `CrewAI` for agent workflows
- `n8n` for orchestration workflows
- Additional VLM or multimodal runtimes later after architecture review
- GGUF model format today
- Shared host model directory mounted read-only into the engine and presentation containers when the selected backend needs it

### 3.4 UI Stack

- The built-in `llama.cpp` WebUI served by the engine container
- Open WebUI in a separate `presentation` container when the selected backend is `ollama`
- Editor integrations via HTTP API

### 3.5 IaC Stack

- Git-tracked Infrastructure-as-Code
- Bash scripts
- YAML inventory and platform definitions
- Deterministic apply runner
- Modular bootstrap scripts behind a single top-level operator workflow

### 3.6 Networking

- LXD bridge networking
- Local-only by default
- Explicit opt-in for LAN exposure

## 4. IaC Structure and Contracts

### 4.1 Repository Layout

```text
iac-plh/
├── bootstrap/          # Host bootstrap scripts
├── inventory/          # Host-specific YAML configs
├── platforms/          # Declarative container definitions
├── profiles/           # LXD profile definitions
├── scripts/            # Runtime provisioning scripts executed inside containers
├── docs/
│   └── architecture.md
├── apply.bash          # Inventory-driven apply runner
└── README.md
```

### 4.2 Inventory Schema

Example: `inventory/alienware-m17r2.yaml`

```yaml
host:
  id: alienware-m17r2
  os: arch
  gpu: nvidia
  cpu: intel
  ram_gb: 32
  storage_root: /srv
  model_dir: /srv/models
  ai_engine_model: DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf

projects:
  - prod

project_migrations:
  - from: ai-infra
    to: prod
  - from: ai-dev
    to: prod
  - from: dev
    to: prod

platforms:
  - engine
  - orchestrator
  - agents

network:
  expose_ui: false
```

Contract:

- `host.*` drives bootstrap selection, package logic, and GPU profile mapping
- `host.model_dir` is the canonical shared GGUF storage root for the engine workload in `prod`
- `host.ai_engine_model` selects the model filename mounted into the engine runtime
- `./apply.bash inventory/<host>.yaml <llama-cpp|ollama>` selects which engine backend is reconciled into `prod/engine`
- selecting `ollama` also injects the `presentation` platform so Open WebUI is reconciled alongside the engine
- `projects` defines required LXD projects
- `project_migrations` declares legacy projects to clean up after containers are moved into the current project layout
- `platforms` defines which platform YAMLs to apply
- `network.expose_ui` controls localhost-only versus LAN binding policy

### 4.3 Platform Definition Schema

Example: `platforms/engine.yaml`

```yaml
name: engine
project: prod
variant:
  default: cpu
  supported:
    - cpu
    - nvidia
    - amd
  select_from: host.gpu

container:
  name: engine
  image: images:ubuntu/24.04
  profiles:
    - default
    - gpu
  mounts:
    - host: "{{ host.model_dir }}"
      container: /models
      readonly: true
  env:
    AI_ENGINE_HOST: 0.0.0.0
    AI_ENGINE_PORT: 8080
    AI_ENGINE_ADMIN_HOST: 0.0.0.0
    AI_ENGINE_ADMIN_PORT: 18080
    AI_ENGINE_MODEL: /models/default.gguf
    OLLAMA_DEFAULT_MODEL: qwen2.5-coder:7b
  command: >
    /usr/local/bin/ai-engine

runtime:
  service_name: ai-engine
  install_script: scripts/provision-ai-engine.bash
  install_script_by_backend:
    llama-cpp: scripts/provision-ai-engine.bash
    ollama: scripts/provision-ollama.bash

migration:
  legacy_project: ai-infra
  legacy_container_name: llama

ports:
  - host: 8080
    container: 8080
    bind_local_only: true
```

Example: `platforms/orchestrator.yaml`

```yaml
name: orchestrator
project: prod

container:
  name: orchestrator
  image: ubuntu:24.04
  profiles:
    - default
  env:
    N8N_HOST: 0.0.0.0
    N8N_PORT: 5678
    OPENAI_API_BASE_URL: http://engine:8080/v1
    OPENAI_API_KEY: local-engine
    LLM_BASE_URL: http://engine:8080/v1
  command: >
    /usr/local/bin/ai-orchestrator start

runtime:
  service_name: ai-orchestrator
  install_script: scripts/provision-n8n.bash
```

The orchestrator runtime consumes the local engine endpoint directly.

Example: `platforms/presentation.yaml`

```yaml
name: presentation
project: prod

container:
  name: presentation
  image: ubuntu:24.04
  profiles:
    - default
  mounts:
    - host: "{{ host.model_dir }}"
      container: /models
      readonly: true
  env:
    OLLAMA_BASE_URL: http://engine:8080
    AI_PRESENTATION_HOST: 0.0.0.0
    AI_PRESENTATION_PORT: "3000"
    WEBUI_AUTH: "False"
  command: >
    /usr/local/bin/ai-presentation serve --host ${AI_PRESENTATION_HOST:-0.0.0.0} --port ${AI_PRESENTATION_PORT:-3000}

runtime:
  service_name: ai-presentation
  install_script: scripts/provision-openwebui.bash

migration:
  legacy_project: dev
  legacy_container_name: openwebui

ports:
  - host: 3000
    container: 3000
    bind_local_only: true
```

Example: `platforms/agents.yaml`

```yaml
name: agents
project: prod

container:
  name: agents
  image: ubuntu:24.04
  profiles:
    - default
  env:
    AI_AGENTS_HOST: 0.0.0.0
    AI_AGENTS_PORT: 7788
  command: >
    /usr/local/bin/ai-agents

runtime:
  service_name: ai-agents
  install_script: scripts/provision-crewai.bash
```

### 4.4 Current Prod Endpoint Inventory

The stable URLs to document are the host-side LXD proxy bindings, not the container bridge IPs.

Reason:

- every platform declares `bind_local_only: true`
- the active inventory sets `network.expose_ui: false`
- the apply runner therefore resolves the host listen address to `127.0.0.1` for each declared port

Current canonical host URLs:

| Role | Container | Service | Host port | Canonical URL |
| --- | --- | --- | --- | --- |
| AI UI and API | `engine` | llama.cpp server | `8080` | `http://127.0.0.1:8080` |
| Web UI | `presentation` | Open WebUI | `3000` | `http://127.0.0.1:3000` when the backend is `ollama` |
| Workflow UI | `orchestrator` | n8n | `5678` | `http://127.0.0.1:5678` |
| Agent API | `agents` | CrewAI / FastAPI | `7788` | `http://127.0.0.1:7788` |

Observed container bridge endpoints on the current host as of 2026-04-28:

| Container | Current state | Observed container URL | Notes |
| --- | --- | --- | --- |
| `engine` | running | `http://10.126.64.107:8080` | llama.cpp direct container address observed from `lxc list --all-projects`; serves both API and built-in WebUI |
| `presentation` | conditional | `http://127.0.0.1:3000` | Open WebUI is reconciled as a separate container when the selected backend is `ollama` |
| `orchestrator` | running | `http://10.126.64.78:5678` | n8n direct container address observed from `lxc list --all-projects` |
| `agents` | running | unavailable | The container is running and the host proxy URL `http://127.0.0.1:7788` responds successfully, but `lxc list --all-projects` is not currently reporting a bridge IPv4 address |

Use the host URLs above in operator-facing documentation because container bridge IPs are runtime details and may change after rebuild, restart, or migration.

### 4.5 LXD Profiles

Profiles live under `profiles/`:

- `gpu-nvidia.yaml`
- `gpu-amd.yaml`
- `gpu-intel.yaml`

Contract:

- Inventory selects the effective GPU profile
- Containers requiring GPU include the generic `gpu` role, which the apply runner resolves to the concrete vendor profile
- Variant selection remains in the platform definition, while GPU passthrough remains in the resolved LXD profile layer

### 4.6 Apply Runner Contract

`apply.bash` performs deterministic, idempotent provisioning.

End-state workflow:

1. A fresh compatible host runs the OS-specific bootstrap path to install and initialize LXD.
2. `apply.bash` validates that host prerequisites are present and may dispatch the OS-specific bootstrap path when they are absent or unready.
3. `apply.bash` reconciles LXD projects, profiles, containers, storage mounts, environment, and service exposure.

Operator experience target:

- One command from the operator point of view
- Multiple focused scripts under the hood for bootstrap, validation, and reconciliation
- Safe reruns after the first successful bootstrap
- Explicit idempotency guarantees for both bootstrap and apply stages

Execution flow:

1. Load inventory.
2. Ensure LXD is installed and initialized.
3. Create LXD projects.
4. Apply LXD profiles.
5. For each platform:
6. Create or update container.
7. Apply profiles, mounts, environment, and command.
8. Configure port bindings.
9. Replace containers when platform changes require a clean rollout, then start the replacement deterministically.
10. Create LXD snapshots before destructive mutation.

Properties:

- Idempotent
- Deterministic
- Inventory-driven
- Auditable through file-defined desired state

## 5. Bootstrap and Lifecycle

### 5.1 Provisioning Flow

1. Fresh OS install.
2. Clone repo.
3. Run host bootstrap script.
4. Log out and back in if required by group or driver changes.
5. Run `./apply.bash inventory/<host>.yaml <llama-cpp|ollama>`.

### 5.2 Build Flow

- Containers are created from declarative YAML definitions
- Models are mounted, not baked into images
- GPU access is passed through via profiles
- Build and update operations are allowed to use the network; field operation is expected to be offline

### 5.2.1 Idempotent Rerun Contract

The operator contract is that a normal rerun of `./apply.bash inventory/<host>.yaml <llama-cpp|ollama>` should converge quickly when nothing material has changed.

Required behavior:

- unchanged project and container state must not trigger destructive replacement
- unchanged runtime install scripts must not trigger repeated package index downloads or source archive downloads
- unchanged runtime service definitions must not trigger unnecessary restarts
- failed or incomplete provisioning must be repairable by rerunning apply without manual cleanup

This means runtime provisioning inside containers must behave like a convergent repair step rather than a one-shot bootstrap step. Installers are expected to reuse prior package installs, extracted source trees, virtual environments, and built artifacts whenever their declared inputs are unchanged.

### 5.3 Deployment Flow

- Inventory selects the host profile and active service set
- Apply runner provisions projects, containers, mounts, and runtime settings
- Production containers are replaced rather than mutated in place when significant platform changes are applied
- Services start deterministically and are restarted only when their managed inputs change or when repair is required

### 5.4 Snapshot and Rollback Flow

- LXD snapshots are the primary rollback mechanism before mutation
- Model storage remains external to containers where possible
- Rollback procedures must restore both container state and matching configuration revision
- Host filesystem snapshots such as ZFS or Btrfs remain optional enhancements, not the primary contract

## 6. Current State vs Target State

### 6.1 Implemented

- First Arch/CachyOS bootstrap script
- LXD substrate selected
- Local GGUF models plus working `llama.cpp` validated manually

### 6.2 Partially Implemented

- Inventory directory
- Platform directory
- Architecture baseline
- First apply runner slice

### 6.3 Not Implemented Yet

- Debian/Proxmox bootstrap
- Full apply runner with replacement rollout and snapshot orchestration
- Multi-host orchestration
- Snapshot and rollback automation

## 7. Environment Assumptions

- x86-64 hardware
- NVIDIA RTX 2060 Mobile GPU today
- AMD 890M expected later
- Intel GPU support is possible but lower priority
- Local SSD storage
- Shared model directory defined by inventory
- LAN-first environment with local-only defaults

## 8. Security Model

- LXD container isolation
- Single active `prod` project today, with optional future expansion to separate environments
- Minimal host privileges
- GPU access only where required
- Local-only network exposure by default
- LAN exposure for production services is allowed when explicitly enabled and managed on the host

## 9. Automation Goals

Fully automated:

- Host bootstrap
- LXD project creation
- Container provisioning
- Model mounting
- Service startup

Manual:

- Base OS installation
- Initial bootstrap invocation
- Model downloads unless mirrored or preseeded internally
- Promotion judgment for production changes

## 10. Roadmap

### 10.1 Immediate

- Expand `apply.bash` with replacement rollout logic
- Add LXD snapshot orchestration before destructive mutation
- Add host-specific inventory files beyond `alienware-m17r2`

### 10.2 Short-Term

- Harden inference and UI containers
- Add basic monitoring

### 10.3 Long-Term

- Multi-host orchestration
- Snapshot and rollback strategy
- Hardware migration support
- Runtime abstraction for future support of LXD, Incus, or Podman-backed workflows

## 11. Risks

- GPU driver variability
- LXD passthrough edge cases
- VRAM limits
- Disk I/O contention
- Tooling churn
- Over-customization

## 12. Design Principles

- Reproducibility over speed
- Explicitness over convenience
- Long-term maintainability over short-term shortcuts
- YAML, Bash, and Git as the primary IaC control surface
- Layered, hardware-agnostic design

## 13. Architectural Notes

The architecture is sound, but these constraints should remain explicit as implementation starts:

- Fully offline operation applies to field use, not initial build; online build and preload are part of the intended lifecycle.
- `apply.bash` should remain the single canonical runner name; avoid alternating between `apply.sh` and `apply.bash`.
- GPU profile selection should resolve from inventory into concrete vendor profiles rather than requiring platform YAML to know hardware specifics.
- Snapshot and rollback need to be treated as part of normal lifecycle management, not a later add-on.
- A shared host model store under `/srv/models` is the canonical model source for both production and development environments.
- Development and production remain isolated; validated changes are promoted by replacement and rollback, not by direct cross-project coupling.