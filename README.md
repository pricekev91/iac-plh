# iac-plh

Infrastructure-as-Code repository for a self-hosted, vendor-agnostic AI appliance built on Linux hosts, LXD system containers, and local model serving.

The previous Windows 11 and WSL-focused implementation has been archived in git and is intentionally not carried forward on `main`.

## Goal

Build toward an LXD-based deployment model where the AI stack is split into separate containers by responsibility:

- LLM engine container for GPU-backed `llama.cpp` inference, API serving, and built-in WebUI access
- Orchestrator container for workflow automation
- Agent container for editor and automation-facing workflows

The intended direction is to keep these services loosely coupled, inventory-driven, and replaceable independently during rollout.

Current naming contract:

- projects represent environments; today the inventory targets only `prod`
- platform and container names represent service roles: `engine`, `orchestrator`, `agents`

Operationally, the end-state should feel like one command from a fresh host, while still being implemented as modular scripts underneath:

- `bootstrap/<os>.bash` prepares a clean host, installs and initializes LXD, and establishes the host prerequisites
- `apply.bash` validates the host state, invokes the OS bootstrap path when first-run LXD prerequisites are missing, and then reconciles the LXD projects, profiles, containers, mounts, and service wiring
- the top-level workflow should be safe to rerun, with bootstrap handling first-time host preparation and apply handling ongoing reconciliation

Idempotency is a design requirement for both layers:

- bootstrap must be safe to rerun on a partially prepared host and either converge cleanly or fail with an explicit prerequisite error
- apply must be safe to rerun against an already bootstrapped host and converge the declared LXD state without hidden one-time assumptions
- runtime provisioning inside containers must reuse installed packages, source trees, and built artifacts whenever the declared inputs have not changed

## Current Scope

- Linux host bootstrap for Arch-family and Debian-family systems
- LXD projects with a single active `prod` environment and optional future expansion
- Declarative platform definitions for engine, orchestrator, and agent services
- Inventory-driven provisioning with deterministic, auditable state
- Idempotent bootstrap and apply behavior as a first-class requirement
- Offline-first operation, with explicit handling for mirrored artifacts and model storage

## Rerun Contract

Normal reruns should be fast and boring:

- unchanged projects, profiles, devices, environment, and proxy bindings are left in place
- unchanged containers are not replaced
- unchanged runtime installers are not supposed to redownload packages or source archives
- unchanged services are not supposed to be rebuilt or restarted just because `apply.bash` ran again

Network-heavy work is expected only when one of these inputs changes:

- the platform definition changes in a way that alters desired container state
- the runtime install script changes
- the runtime service is missing, failed, or otherwise unhealthy and must be repaired
- the target container has never completed its first successful provisioning run

## Repository Layout

```text
iac-plh/
├── bootstrap/
├── docs/
│   └── architecture.md
├── inventory/
├── platforms/
├── profiles/
├── scripts/
├── apply.bash
└── README.md
```

## Starting Point

The architectural baseline lives in `docs/architecture.md`.

The current prod endpoint inventory, including canonical host URLs and observed live container addresses, lives in `docs/architecture.md#44-current-prod-endpoint-inventory`.

Current local service URLs:

- Open WebUI: `http://127.0.0.1:3000` when the engine backend is `ollama`
- AI Engine appliance UI and API: `http://127.0.0.1:8080`
- n8n: `http://127.0.0.1:5678`
- Agents: `http://127.0.0.1:7788`

Current architecture direction as of 2026-04-29:

- `engine` is the primary local AI appliance surface and can be reconciled as either `llama.cpp` or `ollama` behind the same container and host port contract
- when the selected engine backend is `ollama`, apply also reconciles a separate `presentation` container running Open WebUI on host port `3000`
- `orchestrator` talks directly to the engine OpenAI-compatible endpoint
- `agents` remains a separate automation-facing service

Seed files included now:

- `bootstrap/arch-cachyos.bash`
- `inventory/alienware-m17r2.yaml`
- `platforms/engine.yaml`
- `platforms/presentation.yaml`
- `platforms/orchestrator.yaml`
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
