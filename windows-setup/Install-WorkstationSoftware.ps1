#Requires -RunAsAdministrator

param(
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Assert-WingetAvailability {
  if (Get-Command winget -ErrorAction SilentlyContinue) { return }
  throw 'winget is not available. Install App Installer from the Microsoft Store before continuing.'
}

function Test-WingetPackageInstalled {
  param([Parameter(Mandatory = $true)] [string]$Id)
  $output = winget list --id $Id --exact --accept-source-agreements 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $output) { return $false }
  foreach ($line in $output) { if ($line -match "\b$([regex]::Escape($Id))\b") { return $true } }
  return $false
}

function Install-WingetPackage {
  param(
    [Parameter(Mandatory = $true)] [string]$Name,
    [Parameter(Mandatory = $true)] [string]$Id,
    [string]$Source = $null
  )

  if (Test-WingetPackageInstalled -Id $Id) {
    Write-Host "Skipping ${Name}: already installed." -ForegroundColor Yellow
    return
  }

  $wingetArgs = @(
    'install', '--id', $Id,
    '--exact', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
  )
  if ($Source) { $wingetArgs += @('--source', $Source) }
  $cmd = "winget " + ($wingetArgs -join ' ')

  if ($DryRun) { Write-Host "DRY-RUN: $cmd" -ForegroundColor Yellow; return }

  Write-Host "Installing $Name" -ForegroundColor Cyan
  & winget @wingetArgs
  if ($LASTEXITCODE -ne 0) { throw "winget install for $Id exited with code $LASTEXITCODE" }
}

Assert-WingetAvailability

# Order: core shell/tooling → system utilities → network/browser/cloud → dev tools → media/utilities
$packages = @(
  # Core shell/tooling
  @{ Name = 'PowerShell 7 (x64)'; Id = 'Microsoft.PowerShell' },
  @{ Name = 'Windows Terminal'; Id = 'Microsoft.WindowsTerminal'; Source = 'msstore' },
  @{ Name = 'Git'; Id = 'Git.Git' },
  @{ Name = '7-Zip'; Id = '7zip.7zip' },

  # Common runtimes and dependencies
  @{ Name = 'VC++ 2015-2022 Redistributable (x64)'; Id = 'Microsoft.VCRedist.2015+.x64' },
  @{ Name = 'VC++ 2015-2022 Redistributable (x86)'; Id = 'Microsoft.VCRedist.2015+.x86' },
  @{ Name = '.NET Desktop Runtime 8 (x64)'; Id = 'Microsoft.DotNet.DesktopRuntime.8' },
  @{ Name = 'DirectX End-User Runtimes'; Id = 'Microsoft.DirectX' },
  @{ Name = 'Microsoft Edge WebView2 Runtime'; Id = 'Microsoft.EdgeWebView2Runtime' },

  # System utilities and tweaks
  @{ Name = 'PowerToys'; Id = 'Microsoft.PowerToys' },
  @{ Name = 'Nilesoft Shell'; Id = 'Nilesoft.Shell' },
  @{ Name = 'Wintoys'; Id = '9P8LTPGCBZXD'; Source = 'msstore' },
  @{ Name = 'Dynamic Theme'; Id = 't1m0thyj.WinDynamicDesktop' },

  # Network / browser / cloud
  @{ Name = 'Cloudflare WARP'; Id = 'Cloudflare.Warp' },
  @{ Name = 'Brave Browser'; Id = 'Brave.Brave' },
  @{ Name = 'Google Drive'; Id = 'Google.GoogleDrive' },

  # Dev tools
  @{ Name = 'Python 3.13'; Id = 'Python.Python.3.13' },
  @{ Name = 'Windsurf'; Id = 'Codeium.Windsurf' },
  @{ Name = 'Comet'; Id = 'Perplexity.Comet' },

  # Media / general utilities
  @{ Name = 'qBittorrent'; Id = 'qBittorrent.qBittorrent' },
  @{ Name = 'VLC media player'; Id = 'VideoLAN.VLC' },
  @{ Name = 'Lightshot'; Id = 'Skillbrains.Lightshot' },
  @{ Name = 'Mp3tag'; Id = 'FlorianHeidenreich.Mp3tag' },
  @{ Name = 'Bulk Crap Uninstaller'; Id = 'Klocman.BulkCrapUninstaller' }
)

Write-Host "Processing $($packages.Count) packages..." -ForegroundColor Green
foreach ($p in $packages) { Install-WingetPackage -Name $p.Name -Id $p.Id -Source $p.Source }
Write-Host 'All packages processed.' -ForegroundColor Green
