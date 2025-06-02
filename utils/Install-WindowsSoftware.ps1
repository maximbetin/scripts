function Install-WindowsSoftware {
  param (
    [string[]]$Apps = @(
      "Git.Git", "7zip.7zip", "Python.Python.3", "ALCPU.CoreTemp",
      "builtbybel.Wintoys", "MedalB.V.Medal", "Google.Chrome",
      "Microsoft.AzureCLI", "Notepad++.Notepad++", "Microsoft.PowerToys",
      "VideoLAN.VLC", "Microsoft.Winget.Source", "Skillbrains.Lightshot",
      "Microsoft.PowerShell", "Chocolatey.Chocolatey", "Anysphere.Cursor",
      "WhatsApp.WhatsApp", "qBittorrent.qBittorrent", "RafaelRivera.DynamicTheme",
      "Microsoft.WindowsTerminal", "Microsoft.VisualStudioCode"
    ),
    [switch]$DryRun
  )

  # Install Chocolatey if missing
  if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Chocolatey..." -ForegroundColor Cyan
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
  }

  # Install Winget via App Installer if missing
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Winget (App Installer) from Microsoft Store..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri "https://aka.ms/getwinget" -OutFile "$env:TEMP\AppInstaller.msixbundle"
    Add-AppxPackage -Path "$env:TEMP\AppInstaller.msixbundle"
  }

  # Loop through apps
  foreach ($appId in $Apps) {
    if ($DryRun) {
      Write-Host "🔍 Checking $appId..." -ForegroundColor Gray
      $found = winget search --id $appId -e | Select-String $appId
      if ($found) {
        Write-Host "✔ Found in Winget: $appId" -ForegroundColor Green
      } else {
        Write-Warning "$appId NOT found in Winget. Will check Chocolatey..."
        $chocoName = ($appId -split '\.')[-1]
        $chocoResult = choco list $chocoName -e | Select-String $chocoName
        if ($chocoResult) {
          Write-Host "✔ Found in Chocolatey: $chocoName" -ForegroundColor DarkGreen
        } else {
          Write-Error "✖ $appId NOT found in either Winget or Chocolatey."
        }
      }
    } else {
      Write-Host "Installing $appId..." -ForegroundColor Yellow
      try {
        winget install --id $appId --silent --accept-package-agreements --accept-source-agreements -e
      } catch {
        Write-Warning "$appId failed with Winget. Trying Chocolatey..."
        try {
          $chocoName = ($appId -split '\.')[-1]
          choco install $chocoName -y --ignore-checksums
        } catch {
          Write-Error "Failed to install $appId via both Winget and Chocolatey."
        }
      }
    }
  }

  if (-not $DryRun) {
    Write-Host "`nAll install attempts finished." -ForegroundColor Green
  } else {
    Write-Host "`nDry run complete." -ForegroundColor Cyan
  }
}

Install-WindowsSoftware -DryRun    # Test availability only
# Install-WindowsSoftware            # Perform actual installs
