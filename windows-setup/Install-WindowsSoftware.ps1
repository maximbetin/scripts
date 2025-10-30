#Requires -RunAsAdministrator

param(
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Assert-WingetAvailability {
  if (Get-Command winget -ErrorAction SilentlyContinue) { return }
  throw 'winget is not available. Install App Installer from the Microsoft Store before continuing.'
}

function Install-WingetPackage {
  param(
    [Parameter(Mandatory = $true)] [string]$Name,
    [Parameter(Mandatory = $true)] [string]$Id
  )

  $wingetArgs = @(
    'install', '--id', $Id,
    '--exact', '--accept-package-agreements', '--accept-source-agreements',
    '--disable-interactivity', '--force'
  )
  $cmd = 'winget ' + ($wingetArgs -join ' ')

  if ($DryRun) { Write-Host "DRY-RUN: $cmd" -ForegroundColor Yellow; return }

  Write-Host "Installing $Name" -ForegroundColor Cyan
  & winget @wingetArgs
  if ($LASTEXITCODE -ne 0) { throw "winget install for $Id exited with code $LASTEXITCODE" }
}

function Invoke-WingetUpgrade {
  $upgradeArgs = @(
    'upgrade', '--all', '--force',
    '--accept-package-agreements', '--accept-source-agreements',
    '--disable-interactivity'
  )
  $cmd = 'winget ' + ($upgradeArgs -join ' ')

  if ($DryRun) {
    Write-Host "DRY-RUN: $cmd" -ForegroundColor Yellow
    return
  }

  Write-Host 'Running winget upgrade (all packages)' -ForegroundColor Cyan
  & winget @upgradeArgs
  if ($LASTEXITCODE -ne 0) { throw "winget upgrade exited with code $LASTEXITCODE" }
}

Assert-WingetAvailability

# Order: core shell/tooling → system utilities → network/cloud → dev tools → media/utilities
$packages = @(
  # Core shell/tooling
  @{ Name = 'PowerShell 7 (x64)'; Id = 'Microsoft.PowerShell' },
  @{ Name = 'Windows Terminal'; Id = 'Microsoft.WindowsTerminal' },
  @{ Name = 'Git'; Id = 'Git.Git' },
  @{ Name = '7-Zip'; Id = '7zip.7zip' },

  # System utilities and tweaks
  @{ Name = 'PowerToys'; Id = 'Microsoft.PowerToys' },
  @{ Name = 'Wintoys'; Id = '9P8LTPGCBZXD' },
  @{ Name = 'Nilesoft Shell'; Id = 'Nilesoft.Shell' },
  @{ Name = 'Bulk Crap Uninstaller'; Id = 'Klocman.BulkCrapUninstaller' },
  @{ Name = 'Vibe'; Id = 'Thewh1teagle.vibe' },
  @{ Name = 'DirectX End-User Runtimes'; Id = 'Microsoft.DirectX' },

  # Network / cloud
  @{ Name = 'Cloudflare WARP'; Id = 'Cloudflare.Warp' },
  @{ Name = 'Google Drive'; Id = 'Google.GoogleDrive' },
  @{ Name = 'Telegram Desktop'; Id = 'Telegram.TelegramDesktop' },
  @{ Name = 'WhatsApp'; Id = 'WhatsApp.WhatsApp' },

  # Dev tools
  @{ Name = 'Python 3.13'; Id = 'Python.Python.3.13' },
  @{ Name = 'Node.js LTS'; Id = 'OpenJS.NodeJS' },
  @{ Name = 'Windsurf'; Id = 'Codeium.Windsurf' },
  @{ Name = 'Comet'; Id = 'Perplexity.Comet' },

  # Media / general utilities
  @{ Name = 'Lightshot'; Id = 'Skillbrains.Lightshot' },
  @{ Name = 'Mp3tag'; Id = 'FlorianHeidenreich.Mp3tag' },
  @{ Name = 'qBittorrent Enhanced Edition'; Id = 'c0re100.qBittorrent-Enhanced-Edition' },
  @{ Name = 'VLC media player'; Id = 'VideoLAN.VLC' }
)

Write-Host "Processing $($packages.Count) packages..." -ForegroundColor Green
foreach ($p in $packages) { Install-WingetPackage -Name $p.Name -Id $p.Id }
Write-Host 'All packages processed.' -ForegroundColor Green

Invoke-WingetUpgrade
