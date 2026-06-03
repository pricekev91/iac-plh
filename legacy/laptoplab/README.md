Automated, modular, versioned provisioning system for building a complete LLM development environment on Ubuntu inside WSL2.
This repository uses a branch-per-feature workflow and modular Bash scripts to keep the system clean, debuggable, and easy to maintain.

🧱 Repository Layout
iac-laptoplab-wsl/
│
├── bootstrap.sh
├── README.md
│
├── scripts/
│   ├── 00-detect-gpu.sh
│   ├── 10-install-ollama.sh
│   ├── 11-install-llama-cpp.sh
│   ├── 20-install-openwebui.sh
│   ├── 30-config-openwebui.sh
│   └── 40-post-setup.sh
│
└── wsl-provision.ps1

🌿 Branch Workflow (Feature Branches)

Each module/script lives in its own feature branch:

Branch	Purpose	Script
feature/detect-gpu	GPU detection & CUDA compatibility	00-detect-gpu.sh
feature/ollama	Install Ollama + Nvidia CUDA support	10-install-ollama.sh
feature/llm_engine	llama.cpp installation	11-install-llama-cpp.sh
feature/openwebui-install	Install OpenWebUI	20-install-openwebui.sh
feature/openwebui-config	OpenWebUI config	30-config-openwebui.sh
feature/post-setup	Finalization, validation, cleanup	40-post-setup.sh
main	Stable release	All scripts merged after validation
🚀 Running the Provisioner (Windows PowerShell)

WSL cannot be provisioned using restricted PowerShell execution policies.
To safely run the WSL provisioning script without permanently lowering security, use:

powershell -ExecutionPolicy Bypass -File "C:\Users\price\iac-laptoplab-wsl\wsl-provision.ps1"


This does not change your system’s global policy—only for this single run.
This is required because Windows defaults to not allowing unsigned scripts, and that is the correct security posture.

🐧 Running the Linux Bootstrap (Inside WSL Ubuntu)

After the Windows-side provisioning, WSL will launch Ubuntu.
Then run:

chmod +x bootstrap.sh
./bootstrap.sh


The bootstrap script will automatically:

Detect GPU and check for CUDA

Install Ollama (Nvidia-enabled)

Install llama.cpp

Install OpenWebUI

Configure OpenWebUI

Run post-setup validation

Each step pauses so you can confirm progress and check logs.

🧩 Script Execution Order

Bootstrap runs everything in this order:

scripts/00-detect-gpu.sh
scripts/10-install-ollama.sh
scripts/11-install-llama-cpp.sh
scripts/20-install-openwebui.sh
scripts/30-config-openwebui.sh
scripts/40-post-setup.sh


Each script is independently testable and lives in a Git feature branch.

🪵 Logs

All logs are written under:

/var/log/laptoplab/


Each script writes its own log for easy debugging.

🔧 Requirements

Windows 10/11 with WSL2 enabled

Nvidia GPU + drivers (optional but recommended)

Ubuntu WSL instance

At least 16 GB RAM recommended for LLMs

📌 Notes

All installers are from official sources (Ollama, llama.cpp, OpenWebUI)

No dependencies are downloaded from HuggingFace unless explicitly configured

Branch-based workflow keeps each feature tested and isolated
