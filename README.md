# Scripts

Personal scripts and configuration helpers for day-to-day automation, environment setup, and DevOps tinkering. Expect things to change quickly and
random stuff get added.

## Structure

- **bash/** – small shell utilities (Kubernetes pod cleanup, GitLab helpers, uptime info, etc.).
- **pwsh/** – PowerShell scripts for media conversion and automation workflows.
- **windows-setup/** – manifests, installers, and scripts for rebuilding a Windows workstation.

## Usage

Scripts are meant to be invoked directly and self-document through inline help or comments. Review each script before running it and adapt paths,
credentials, or package lists to match your environment.

### Windows setup snapshot (this should probably be its own repository)

`windows-setup` bundles winget / Chocolatey manifests, optional offline installers, config files, and manual follow-up notes. Run the scripts in that
folder from an elevated PowerShell session when rebuilding a machine, updating the manifests as your toolkit evolves.
