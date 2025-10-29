param(
  [string]$WingetManifestPath = "$PSScriptRoot/winget-packages.json",
  [string]$ChocoPackageListPath = "$PSScriptRoot/choco-packages.txt",
  [string]$ManualInstallerManifestPath = "$PSScriptRoot/manual-installers.json",
  [string]$InventoryPath = "$PSScriptRoot/installed-software.json",
  [string]$ManualStepsPath = "$PSScriptRoot/manual-steps.md"
)

$ErrorActionPreference = "Stop"

function Assert-Administrator {
  $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell session."
  }
}

function Assert-WingetAvailability {
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    return
  }
  throw "winget is not available. Install App Installer from the Microsoft Store before continuing."
}

function Install-Chocolatey {
  if (Get-Command choco -ErrorAction SilentlyContinue) {
    return
  }
  Write-Host "Installing Chocolatey package manager..." -ForegroundColor Cyan
  $installCommand = "Set-ExecutionPolicy Bypass -Scope Process -Force; " +
  "[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; " +
  "Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
  Invoke-Expression $installCommand
}

function Install-ChocolateyPackages {
  param([string]$ListPath)
  if (-not (Test-Path $ListPath)) {
    Write-Host "No Chocolatey package list found at $ListPath. Skipping." -ForegroundColor Yellow
    return
  }
  $packages = Get-Content $ListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
  if (-not $packages) {
    Write-Host "Chocolatey package list is empty." -ForegroundColor Yellow
    return
  }
  Install-Chocolatey
  foreach ($package in $packages) {
    Write-Host "Installing Chocolatey package $package" -ForegroundColor Cyan
    choco upgrade $package -y
  }
}

function Import-WingetPackages {
  param([string]$ManifestPath)
  if (-not (Test-Path $ManifestPath)) {
    Write-Warning "No winget manifest found at $ManifestPath. Skipping package import."
    return
  }
  Write-Host "Installing packages defined in $(Resolve-Path $ManifestPath)." -ForegroundColor Cyan
  & winget import --input "$ManifestPath" --accept-package-agreements --accept-source-agreements
}

function Install-WingetPackage {
  param(
    [string]$Identifier,
    [string]$Name,
    [string]$Source
  )
  if (-not $Identifier) {
    return $false
  }
  $display = if ($Name) { "$Name ($Identifier)" } else { $Identifier }
  if ($Source) {
    Write-Host "Installing via winget [$Source]: $display" -ForegroundColor Cyan
  } else {
    Write-Host "Installing via winget: $display" -ForegroundColor Cyan
  }
  $arguments = @('install', '--id', $Identifier, '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
  if ($Source) {
    $arguments += @('--source', $Source)
  }
  try {
    & winget @arguments
    if ($LASTEXITCODE -eq 0) {
      return $true
    }
    Write-Warning "winget install for $Identifier exited with code $LASTEXITCODE"
  } catch {
    Write-Warning "winget install for $Identifier failed: $_"
  }
  return $false
}

function Install-ChocolateyPackageFromInventory {
  param(
    [string]$Identifier,
    [string]$Name
  )
  if (-not $Identifier) {
    return $false
  }
  Install-Chocolatey
  $display = if ($Name) { "$Name ($Identifier)" } else { $Identifier }
  Write-Host "Installing via Chocolatey: $display" -ForegroundColor Cyan
  try {
    choco upgrade $Identifier -y
    if ($LASTEXITCODE -eq 0) {
      return $true
    }
    Write-Warning "Chocolatey upgrade for $Identifier exited with code $LASTEXITCODE"
  } catch {
    Write-Warning "Chocolatey upgrade for $Identifier failed: $_"
  }
  return $false
}

function Install-InventorySoftware {
  param([string]$InventoryPath)
  if (-not (Test-Path $InventoryPath)) {
    Write-Host "No inventory file found at $InventoryPath. Skipping inventory-driven installs." -ForegroundColor Yellow
    return @()
  }
  try {
    $raw = Get-Content $InventoryPath -Raw
    if (-not $raw) {
      Write-Host "Inventory file $InventoryPath is empty." -ForegroundColor Yellow
      return @()
    }
    $entries = $raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-Warning "Failed to parse inventory file ${InventoryPath}: $_"
    return @()
  }
  if (-not $entries) {
    Write-Host "Inventory file contains no entries." -ForegroundColor Yellow
    return @()
  }
  $manualFollowUp = @()
  $wingetSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $chocoSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in $entries) {
    $sourceInfos = @()
    if ($entry.SourceInfo) {
      $sourceInfos = @($entry.SourceInfo) | Where-Object { $_ }
    }
    $handled = $false
    $wingetInfos = $sourceInfos | Where-Object { $_.Type -eq 'Winget' -and $_.Identifier }
    foreach ($info in $wingetInfos) {
      $key = "Winget|$($info.Identifier)"
      if ($wingetSeen.Contains($key)) {
        continue
      }
      if (Install-WingetPackage -Identifier $info.Identifier -Name $entry.Name -Source $info.Source) {
        $wingetSeen.Add($key) | Out-Null
        $handled = $true
        break
      }
    }
    if ($handled) {
      continue
    }
    $chocoInfos = $sourceInfos | Where-Object { $_.Type -eq 'Chocolatey' -and $_.Identifier }
    foreach ($info in $chocoInfos) {
      $key = "Chocolatey|$($info.Identifier)"
      if ($chocoSeen.Contains($key)) {
        continue
      }
      if (Install-ChocolateyPackageFromInventory -Identifier $info.Identifier -Name $entry.Name) {
        $chocoSeen.Add($key) | Out-Null
        $handled = $true
        break
      }
    }
    if ($handled) {
      continue
    }
    $appxInfos = $sourceInfos | Where-Object { $_.Type -eq 'Appx' }
    if ($appxInfos) {
      $manualFollowUp += [PSCustomObject]@{
        Name   = $entry.Name
        Reason = 'Appx/Microsoft Store package. Reinstall via Microsoft Store or OEM channel.'
      }
      continue
    }
    $manualFollowUp += [PSCustomObject]@{
      Name   = $entry.Name
      Reason = 'No install source detected. Reinstall manually.'
    }
  }
  return $manualFollowUp
}

function Invoke-ManualInstallers {
  param([string]$ManifestPath)
  if (-not (Test-Path $ManifestPath)) {
    Write-Host "No manual installer manifest found at $ManifestPath. Skipping." -ForegroundColor Yellow
    return
  }
  $entries = Get-Content $ManifestPath | ConvertFrom-Json
  if (-not $entries) {
    Write-Host "Manual installer manifest is empty." -ForegroundColor Yellow
    return
  }
  foreach ($entry in $entries) {
    $name = $entry.Name
    $relativePath = $entry.Path
    $arguments = $entry.Arguments
    $run = [bool]$entry.Run
    $notes = $entry.Notes
    Write-Host "Manual installer: $name" -ForegroundColor Cyan
    if ($notes) {
      Write-Host "  Notes: $notes"
    }
    if (-not $relativePath) {
      continue
    }
    $installerPath = Join-Path $PSScriptRoot $relativePath
    if (-not (Test-Path $installerPath)) {
      Write-Warning "  Installer file not found at $installerPath"
      continue
    }
    Write-Host "  Located at: $installerPath"
    if (-not $run) {
      continue
    }
    Write-Host "  Running installer..." -ForegroundColor Green
    if ($arguments) {
      Start-Process -FilePath $installerPath -ArgumentList $arguments -Wait
    } else {
      Start-Process -FilePath $installerPath -Wait
    }
  }
}

function Show-ManualSteps {
  param([string]$StepsPath)
  if (-not (Test-Path $StepsPath)) {
    Write-Host "No manual steps file found." -ForegroundColor Yellow
    return
  }
  Write-Host "Review manual steps in $(Resolve-Path $StepsPath)." -ForegroundColor Cyan
}

function Write-ManualFollowUps {
  param([array]$Items)
  if (-not $Items -or $Items.Count -eq 0) {
    Write-Host "No additional manual reinstall actions detected from inventory." -ForegroundColor Green
    return
  }
  Write-Host "Manual follow-up required for the following entries:" -ForegroundColor Yellow
  $Items | Sort-Object Name | Format-Table Name, Reason -AutoSize | Out-String | ForEach-Object { $_.TrimEnd() } | ForEach-Object { Write-Host $_ }
}

Assert-Administrator
Assert-WingetAvailability
Import-WingetPackages -ManifestPath $WingetManifestPath
Install-ChocolateyPackages -ListPath $ChocoPackageListPath
$manualFollowUps = Install-InventorySoftware -InventoryPath $InventoryPath
Invoke-ManualInstallers -ManifestPath $ManualInstallerManifestPath
Show-ManualSteps -StepsPath $ManualStepsPath
Write-ManualFollowUps -Items $manualFollowUps
Write-Host "Setup script completed." -ForegroundColor Cyan
