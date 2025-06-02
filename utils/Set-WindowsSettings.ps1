function Set-WindowsSettings {
  [CmdletBinding()]
  Param (
    [switch]$DryRun
  )

  # Ensure script is run as Administrator
  If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
        [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "Please run this script as Administrator."
    Exit
  }

  function Set-RegistryValue {
    param (
      [string]$Path,
      [string]$Name,
      [object]$Value,
      [string]$Type = "DWord"
    )
    if ($DryRun) {
      Write-Host "DRY RUN: Would set $Path\$Name to '$Value' [$Type]" -ForegroundColor Gray
    } else {
      Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction SilentlyContinue
    }
  }

  Write-Host "Configuring File Explorer and UAC..." -ForegroundColor Cyan

  Set-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -Value 0
  Set-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Hidden" -Value 1
  Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -Value 0

  Write-Host "Disabling Ads and Telemetry..." -ForegroundColor Cyan

  Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableConsumerFeatures" -Value 1
  Set-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SystemPaneSuggestionsEnabled" -Value 0
  Set-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-338389Enabled" -Value 0
  Set-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" -Name "TailoredExperiencesWithDiagnosticDataEnabled" -Value 0
  Set-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowSyncProviderNotifications" -Value 0
  Set-RegistryValue -Path "HKCU:\Software\Microsoft\Siuf\Rules" -Name "NumberOfSIUFInPeriod" -Value 0

  Write-Host "Disabling Background Apps..." -ForegroundColor Cyan
  Get-AppxPackage | ForEach-Object {
    $capability = $_.PackageFamilyName
    if ($DryRun) {
      Write-Host "DRY RUN: Would disable background access for $capability" -ForegroundColor Gray
    } else {
      try {
        Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppxManifest.xml" -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications\$capability" -Name "Disabled" -Type DWord -Value 1 -ErrorAction SilentlyContinue
      } catch {}
    }
  }

  Write-Host "Disabling Telemetry..." -ForegroundColor Cyan
  Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Value 0

  Write-Host "Disabling SmartScreen..." -ForegroundColor Cyan
  if ($DryRun) {
    Write-Host "DRY RUN: Would set SmartScreenEnabled to 'Off'" -ForegroundColor Gray
  } else {
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" -Name "SmartScreenEnabled" -Value "Off"
  }

  Write-Host "Disabling Cortana..." -ForegroundColor Cyan
  Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCortana" -Value 0

  if (-not $DryRun) {
    Write-Host "`nAll tasks completed. Reboot required to apply UAC and some privacy settings." -ForegroundColor Green
    $restart = Read-Host "Restart now? (Y/N)"
    if ($restart -eq "Y") {
      Restart-Computer
    }
  } else {
    Write-Host "`nDry run complete. No changes were made." -ForegroundColor Cyan
  }
}

Set-WindowsSettings -DryRun    # Show what would be done
# Set-WindowsSettings            # Apply actual changes
