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

### Windows setup snapshot

`windows-setup` bundles winget / Chocolatey manifests, optional offline installers, inventory, and manual follow-up notes. Run the scripts in that
folder from an elevated PowerShell session when rebuilding a machine, updating the manifests as your toolkit evolves.

#### Streamlined rebuild flow

1. Export inventory from an existing machine:

   ```powershell
   # Produces installed-software.json and a human-readable table
   .\windows-setup\Get-InstalledSoftware.ps1 -InventoryPath .\windows-setup\installed-software.json -ReportPath .\windows-setup\installed-software.txt
   ```

2. On a fresh Windows install, place `windows-setup` in a folder and run the setup:

   ```powershell
   # Installs based on inventory (winget/chocolatey where available)
   .\windows-setup\Setup-Windows.ps1

   # Optionally also apply curated manifests in addition to inventory
   .\windows-setup\Setup-Windows.ps1 -UsePackageManifests
   ```

3. Review any manual steps and follow-ups printed at the end.

#### Exporter options

`Get-InstalledSoftware.ps1` supports toggling sources when building inventory:

- `-SkipWinget` – exclude winget/msstore data.
- `-SkipChocolatey` – exclude Chocolatey packages.
- `-SkipAppx` – exclude Microsoft Store (Appx) packages.
- `-Quiet` – return the inventory as an object and suppress table output.

#### Behavior details

- `Setup-Windows.ps1` installs from inventory first. For each item:
  - Tries winget by identifier if present (and preferred source if available).
  - If not installed and not Appx-only, falls back to exact-name winget install (tries preferred source, then winget/msstore/auto).
  - If Chocolatey identifier is present, tries Chocolatey.
  - Appx-only packages are listed as manual follow-ups.
- Manual follow-up output includes a Suggested command to try in PowerShell (winget or choco) to speed up manual recovery.
