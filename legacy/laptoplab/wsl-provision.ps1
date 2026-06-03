<# 
    WSL-Provision.ps1 — Version 0.5
    --------------------------------
    Author: Kevin Price
    Purpose:
        Automates provisioning of a WSL distribution from a .tar or .gz image.
        If the instance already exists, it can be safely unregistered and rebuilt.

    Changelog:
        v0.5 - Added versioning, optional logging, strict mode, and better structure.
#>

# -----------------------------
# Script Configuration
# -----------------------------

# Enable strict mode for safer scripting
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Version tag
$ScriptVersion = "0.5"

# Variables (customize as needed)
$DistroName      = "Ubuntu-MKI"
$DistroFile      = "C:\wsl\distro\ubuntu-24.04.3-wsl-amd64.gz"
$InstallLocation = "C:\wsl\instances\$DistroName"
$EnableLogging   = $false
$LogFile         = "C:\wsl\logs\wsl-provision.log"

# -----------------------------
# Helper Functions
# -----------------------------

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    Write-Host $logEntry

    if ($EnableLogging) {
        if (-not (Test-Path (Split-Path $LogFile))) {
            New-Item -ItemType Directory -Path (Split-Path $LogFile) | Out-Null
        }
        Add-Content -Path $LogFile -Value $logEntry
    }
}

# -----------------------------
# Begin Execution
# -----------------------------

Write-Log "Starting WSL Provisioning Script (v$ScriptVersion)"
Write-Log "Distro: $DistroName"
Write-Log "Image:  $DistroFile"
Write-Log "Target: $InstallLocation"

# Check if the distro is already registered
$existingDistros = wsl --list --quiet
if ($existingDistros -contains $DistroName) {
    Write-Log "WSL instance '$DistroName' is already registered." "WARN"
    Write-Log "This will unregister and delete the existing instance at: $InstallLocation" "WARN"

    $confirmation = Read-Host "Type 'CONTINUE' to proceed with deletion and reinstallation"
    if ($confirmation -ne "CONTINUE") {
        Write-Log "Operation aborted by user." "CANCELLED"
        exit
    }

    # Unregister the existing instance
    Write-Log "Unregistering existing WSL instance..." "ACTION"
    wsl --unregister $DistroName

    # Remove the install directory if it exists
    if (Test-Path $InstallLocation) {
        Write-Log "Removing existing install directory..." "ACTION"
        Remove-Item -Recurse -Force $InstallLocation
    }
}

# Create the install directory
if (-Not (Test-Path $InstallLocation)) {
    Write-Log "Creating install directory..." "ACTION"
    New-Item -ItemType Directory -Path $InstallLocation | Out-Null
}

# Import the WSL instance
Write-Log "Importing WSL instance '$DistroName'..." "ACTION"
wsl --import $DistroName $InstallLocation $DistroFile --version 2

# Set as default
wsl --set-default $DistroName
Write-Log "WSL instance '$DistroName' has been registered and set as default." "SUCCESS"

Write-Log "Provisioning complete (v$ScriptVersion)" "DONE"