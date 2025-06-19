# Maxim Scripts

A collection of personal scripts and configurations for development environment setup, automation, and DevOps tasks.

## Contents

### Utils
Contains utility scripts and VS Code configurations:
- `vscode_settings.json`: Personal VS Code settings
- `vscode_extensions.txt`: VS Code extensions list for installation
- `Convert-WavToMp3.ps1`: PowerShell script to convert WAV files to MP3
- `Get-InstalledApps.ps1`: PowerShell script to get all installed apps on the system
- `Convert-MediaFiles.ps1`: PowerShell script to convert media files to the desired format (e.g. video, image, etc.)
- `Profile.ps1`: Personal PowerShell profile with settings, aliases, functions, etc.
  - If you are using PowerShell Core, rename it to `Microsoft.PowerShell_profile.ps1` and place it in the `%USERPROFILE%\Documents\PowerShell\` directory.
  - If you are using VSCode PowerShell Extension, rename it to `Microsoft.VSCode_profile.ps1` and place it in the `%USERPROFILE%\Documents\PowerShell\` directory.
  - If you are using PowerShell ISE, rename it to `Microsoft.PowerShell_profile.ps1` and place it in the `%USERPROFILE%\Documents\WindowsPowerShell\` directory.
  - If you are using Windows PowerShell, rename it to `Microsoft.PowerShell_profile.ps1` and place it in the `%USERPROFILE%\Documents\WindowsPowerShell\` directory.

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
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
