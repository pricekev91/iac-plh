This repository provisions a WSL2 Ubuntu environment on Windows and bootstraps GPU-enabled tooling (future target: local LLM stacks and OpenWebUI).

**How to get productive**
- **Host vs guest:** Primary flows happen in two places: on Windows (PowerShell) and inside the WSL Ubuntu distro (Bash). See `wsl-provision.ps1` and the `bootstrap-*.sh` scripts.
- **Quick start commands:**
  - Clone repo: `git clone https://github.com/pricekev/iac-laptoplab-wsl.git && cd iac-laptoplab-wsl`
  - Provision WSL (Windows PowerShell): `.\wsl-provision.ps1`
  - Enter the distro and run the appropriate bootstrap (inside WSL): `wsl -d Ubuntu-MKI` then `bash bootstrap-llama.cpp-openwebui.sh` (or `bash bootstrap-ollama-openwebui.sh`).

**Big-picture architecture (what code you should read first)**
- `wsl-provision.ps1` (Windows host): imports an Ubuntu rootfs, names the distro `Ubuntu-MKI`, and sets it as default. This is the starting point for environment creation.
- `bootstrap-*.sh` (WSL guest): perform in-guest setup — system updates, CUDA / NVIDIA CLI installation, installing auxiliary packages (e.g., `fastfetch`), adding login hooks, and logging to `~/bootstrap.log`.
- Future components (not yet installed by default) are LLaMA runtimes and OpenWebUI — the repo contains specialized bootstrap scripts named to indicate the target runtime (`llama.cpp` vs `ollama`) and the OpenWebUI integration.

**Developer workflows & debugging**
- To validate provisioning succeeded: `wsl -l -v` shows the `Ubuntu-MKI` instance and its state.
- Inside WSL, verify GPU access with `nvidia-smi`. If missing, inspect `/var/log/` and `~/bootstrap.log` (the bootstrap scripts append output there).
- If a provisioning step fails, re-run the bootstrap inside the distro; scripts are intended to be re-run but may not be fully idempotent — inspect the script before re-running.
- Common quick checks: `cat ~/bootstrap.log`, `journalctl` (if systemd is enabled in this distro), and `bash -x ./bootstrap-*.sh` for verbose tracing.

**Project-specific conventions & patterns**
- Script naming: `bootstrap-<runtime>-openwebui.sh` — indicates which LLM runtime is being prepared and that OpenWebUI will be integrated.
- Distro naming: the PowerShell script creates/uses `Ubuntu-MKI`; other tooling assumes that name — prefer using it unless intentionally changing the distro name (then update README and scripts).
- Logging: bootstrap scripts append progress and errors to `~/bootstrap.log` in the guest. Inspect this file for troubleshooting.

**Integration points & external dependencies**
- NVIDIA drivers / CUDA: the scripts install CUDA runtime pieces and rely on host GPU drivers. Verify host driver compatibility before debugging guest CUDA problems.
- External package sources: scripts add apt PPAs and use Ubuntu package repos (note the README references Ubuntu 22.04-based CUDA packages). Be cautious when adjusting apt sources.

**Concrete examples to include in PRs or edits**
- When modifying a bootstrap script, add a short top-of-file comment that explains expected distro name and required host preconditions (Windows driver, WSL2 enabled).
- If adding a new runtime script, follow the `bootstrap-<name>-openwebui.sh` naming pattern and include `echo` lines that write status to `~/bootstrap.log` so CI/debuggers can follow progress.

**What the AI agent should do when making edits**
- Prefer minimal, focused changes: update README or one bootstrap script at a time.
- Run local verification steps in this order: lint shell changes, run `wsl -l -v` to confirm distro name, launch WSL and run the modified script with `bash -x` and check `~/bootstrap.log`.
- When adding new external dependencies, update the README with exact install and verification commands.

If anything here is unclear or you'd like more detail on a particular script (for example, the exact bootstrap steps in `bootstrap-llama.cpp-openwebui.sh`), tell me which file and I'll expand this guidance with exact examples and quick debugging commands.
