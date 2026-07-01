# IAC-PLH LXD Engine Setup

## Session Status
- **Goal**: Replace the current `iac-plh` container setup (which had `presentation`, `agents`, `orchestrator`, and `engine`) with a single combined `engine` container that mirrors the `iac-hlh` homelab setup, but using LXD instead of Proxmox LXC.
- **Current State**:
  - Removed `iac-plh/platforms/presentation.yaml`
  - Removed `iac-plh/platforms/agents.yaml`
  - Removed `iac-plh/platforms/orchestrator.yaml`
  - Updated `iac-plh/inventory/alienware-m17r2.yaml` to only include `engine` under platforms.
  - Updated `iac-plh/platforms/engine.yaml` to combine the WebUI (8080), LocalAI (8081), and Llama.cpp WebGUI (8082) into a single LXD container definition.

