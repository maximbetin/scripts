# Maxim Scripts

A collection of personal scripts and configurations for development environment setup, automation, and DevOps tasks.

## Contents

### Utils
Contains utility scripts and VS Code configurations:
- `Get-AllInstalledSoftware.ps1`: PowerShell script to get all installed software on the system
- `Install-WindowsSoftware`: Script for installing Windows software
- `Set-WindowsSettings.ps1`: PowerShell script to configure Windows settings
- `vscode_extensions.json`: VS Code extensions list for installation
- `vscode_settings.json`: Personal VS Code settings

### Kubernetes
Collection of Kubernetes management scripts:
- `k-drain-nodes.sh`: Script to drain Kubernetes nodes
- `k-get-all-yaml.sh`: Export all Kubernetes resources as YAML
- `k-del-pods-error.sh`: Delete pods in error state
- `k-del-pods-evicted.sh`: Delete evicted pods
- `k-clean.sh`: Cleanup script for Kubernetes resources

### Networking
Network-related utilities:
- `uptime.sh`: Script to check system uptime

### CI/CD
Continuous Integration and Deployment scripts:
- `jenkins-jobs.groovy`: Jenkins job definitions
- `gitlab-cicdvars-migrate.sh`: Script to migrate GitLab CI/CD variables

## Usage
Each script contains its own documentation and usage instructions. Refer to the individual script files for specific usage details.

## Requirements
- Windows 10 or later (for PowerShell scripts)
- PowerShell 5.1 or later (for PowerShell scripts)
- Bash shell (for shell scripts)

## License
This repository is for personal use. Feel free to use these scripts as a reference for your own setup.
