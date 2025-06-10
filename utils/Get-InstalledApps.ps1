Function Get-InstalledApps {
  [CmdletBinding()]
  Param(
    [Parameter(Mandatory = $false)]
    [string]$OutputFile = "InstalledSoftware.txt"
  )

  $softwareList = New-Object System.Collections.Generic.List[PSObject]

  # 1. Get-Package (for traditional and managed packages)
  try {
    Get-Package | ForEach-Object {
      $softwareList.Add([PSCustomObject]@{
          Name        = $_.Name
          Version     = $_.Version
          Publisher   = $_.ProviderName # Using ProviderName as a stand-in for Publisher here
          InstallDate = $null
          Source      = "Get-Package"
        })
    }
  } catch {
    Write-Warning "Could not retrieve packages using Get-Package: $($_.Exception.Message)"
  }

  # 2. Registry (32-bit and 64-bit applications)
  $registryPaths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
  )

  foreach ($path in $registryPaths) {
    try {
      Get-ItemProperty $path | Where-Object { $null -ne $_.DisplayName } | ForEach-Object {
        $softwareList.Add([PSCustomObject]@{
            Name        = $_.DisplayName
            Version     = $_.DisplayVersion
            Publisher   = $_.Publisher
            InstallDate = $_.InstallDate
            Source      = "Registry ($path)"
          })
      }
    } catch {
      Write-Warning "Could not retrieve software from registry path '$path': $($_.Exception.Message)"
    }
  }

  # 3. UWP/Microsoft Store Apps
  try {
    Get-AppxPackage | ForEach-Object {
      $softwareList.Add([PSCustomObject]@{
          Name        = $_.Name
          Version     = $_.Version
          Publisher   = $_.Publisher # UWP apps often have a Publisher property
          InstallDate = $null
          Source      = "UWP/AppX"
        })
    }
  } catch {
    Write-Warning "Could not retrieve UWP/AppX packages: $($_.Exception.Message)"
  }

  # Filter out duplicates and format
  $results = $softwareList | Sort-Object Name | Select-Object -Unique Name

  # Output to console (simple list format)
  $results | ForEach-Object { $_.Name }

  # Output to file
  try {
    $results | ForEach-Object { $_.Name } | Out-File -FilePath $OutputFile -Encoding UTF8
    Write-Host "Results have been written to: $OutputFile" -ForegroundColor Green
  } catch {
    Write-Warning "Could not write to output file '$OutputFile': $($_.Exception.Message)"
  }
}