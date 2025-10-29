[CmdletBinding()]
param(
  [switch]$SkipWinget,
  [switch]$SkipChocolatey,
  [switch]$SkipAppx,
  [Alias('ExportJsonPath')]
  [string]$InventoryPath = "$PSScriptRoot/installed-software.json",
  [string]$ReportPath = "$PSScriptRoot/installed-software.txt",
  [switch]$Quiet
)

$ErrorActionPreference = "Stop"

function Convert-SourceInfoToLabel {
  param([array]$SourceInfo)

  if (-not $SourceInfo) {
    return ''
  }

  $labels = @()
  foreach ($info in $SourceInfo) {
    if (-not $info) { continue }
    switch ($info.Type) {
      'Winget' {
        if ($info.Source) {
          $labels += "winget:$($info.Source)"
        } else {
          $labels += 'winget'
        }
      }
      'Chocolatey' { $labels += 'Chocolatey' }
      'Appx' { $labels += 'Appx' }
      'Registry' { $labels += 'Registry' }
      default {
        $labels += $info.Type
      }
    }
  }

  return ($labels | Where-Object { $_ } | Select-Object -Unique) -join ', '
}

function Update-SourceInfoList {
  param(
    [array]$Existing,
    [array]$Incoming
  )

  $result = @()
  if ($Existing) {
    $result += $Existing | Where-Object { $_ }
  }

  if ($Incoming) {
    foreach ($info in $Incoming) {
      if (-not $info) { continue }
      $duplicate = $false
      foreach ($current in $result) {
        if ($current.Type -eq $info.Type -and
          $current.Identifier -eq $info.Identifier -and
          $current.Source -eq $info.Source) {
          $duplicate = $true
          break
        }
      }

      if (-not $duplicate) {
        $result += $info
      }
    }
  }

  return $result
}

function Get-RegistrySoftware {
  $paths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )

  foreach ($path in $paths) {
    Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and $_.DisplayName.Trim() } |
    ForEach-Object {
      $sourceInfo = @([PSCustomObject]@{
          Type       = 'Registry'
          Identifier = $_.PSChildName
        })

      [PSCustomObject]@{
        Name       = $_.DisplayName.Trim()
        Version    = $_.DisplayVersion
        Publisher  = $_.Publisher
        SourceInfo = $sourceInfo
        Source     = Convert-SourceInfoToLabel $sourceInfo
        Identifier = $_.PSChildName
        Notes      = $_.InstallLocation
      }
    }
  }
}

function Get-WingetPackages {
  if ($SkipWinget) { return @() }
  $winget = Get-Command winget -ErrorAction SilentlyContinue
  if (-not $winget) { return @() }

  $sources = @('winget', 'msstore')
  $packages = @()

  foreach ($source in $sources) {
    try {
      $raw = winget list --source $source --accept-source-agreements --output json 2>$null
      if (-not $raw) { continue }
      $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
      if (-not $parsed.Sources) { continue }

      foreach ($src in $parsed.Sources) {
        foreach ($pkg in $src.Packages) {
          $sourceInfo = @([PSCustomObject]@{
              Type       = 'Winget'
              Identifier = $pkg.PackageIdentifier
              Source     = $src.Name
            })

          $packages += [PSCustomObject]@{
            Name       = if ($pkg.PackageName) { $pkg.PackageName } else { $pkg.Name }
            Version    = $pkg.InstalledVersion
            Publisher  = $pkg.Publisher
            SourceInfo = $sourceInfo
            Source     = Convert-SourceInfoToLabel $sourceInfo
            Identifier = $pkg.PackageIdentifier
            Notes      = $pkg.PackageFamilyName
          }
        }
      }
    } catch {
      Write-Verbose "winget list for source '$source' failed: $_"
    }
  }

  return $packages
}

function Get-ChocolateyPackages {
  if ($SkipChocolatey) { return @() }
  $choco = Get-Command choco -ErrorAction SilentlyContinue
  if (-not $choco) { return @() }

  $root = $env:ChocolateyInstall
  if (-not $root) { return @() }

  $libPath = Join-Path $root 'lib'
  if (-not (Test-Path $libPath)) { return @() }

  $packageFolders = Get-ChildItem -Path $libPath -Directory -ErrorAction SilentlyContinue
  $results = @()

  foreach ($folder in $packageFolders) {
    $nuspec = Get-ChildItem -Path $folder.FullName -Filter *.nuspec -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

    if ($nuspec) {
      try {
        $xml = [xml](Get-Content -Path $nuspec.FullName -Raw)
        $metadata = $xml.package.metadata
        $sourceInfo = @([PSCustomObject]@{
            Type       = 'Chocolatey'
            Identifier = $metadata.id
          })

        $results += [PSCustomObject]@{
          Name       = $metadata.id
          Version    = $metadata.version
          Publisher  = $metadata.authors
          SourceInfo = $sourceInfo
          Source     = Convert-SourceInfoToLabel $sourceInfo
          Identifier = $metadata.id
          Notes      = $metadata.projectUrl
        }
        continue
      } catch {
        Write-Verbose "Failed to parse nuspec for $($folder.Name): $_"
      }
    }

    $sourceInfo = @([PSCustomObject]@{
        Type       = 'Chocolatey'
        Identifier = $folder.Name
      })

    $results += [PSCustomObject]@{
      Name       = $folder.Name
      Version    = $null
      Publisher  = $null
      SourceInfo = $sourceInfo
      Source     = Convert-SourceInfoToLabel $sourceInfo
      Identifier = $folder.Name
      Notes      = $null
    }
  }

  return $results
}

function Get-AppxSoftware {
  if ($SkipAppx) { return @() }

  try {
    $packages = Get-AppxPackage -ErrorAction Stop | Where-Object { -not $_.IsFramework }
    return $packages | ForEach-Object {
      $sourceInfo = @([PSCustomObject]@{
          Type       = 'Appx'
          Identifier = $_.PackageFullName
        })

      [PSCustomObject]@{
        Name       = $_.Name
        Version    = $_.Version.ToString()
        Publisher  = $_.PublisherDisplayName
        SourceInfo = $sourceInfo
        Source     = Convert-SourceInfoToLabel $sourceInfo
        Identifier = $_.PackageFullName
        Notes      = $_.InstallLocation
      }
    }
  } catch {
    Write-Verbose "Get-AppxPackage failed: $_"
    return @()
  }
}

function Merge-Inventory {
  param(
    [array]$Items
  )

  $map = @{}

  foreach ($item in $Items) {
    if (-not $item.Name) { continue }
    $versionKey = if ($item.Version) { $item.Version.ToString().ToLowerInvariant() } else { '' }
    $key = "{0}|{1}" -f ($item.Name.ToLowerInvariant()), $versionKey

    if ($map.ContainsKey($key)) {
      $existing = $map[$key]
      $existing.SourceInfo = Update-SourceInfoList -Existing $existing.SourceInfo -Incoming $item.SourceInfo
      $existing.Source = Convert-SourceInfoToLabel $existing.SourceInfo
      if (-not $existing.Publisher -and $item.Publisher) {
        $existing.Publisher = $item.Publisher
      }
      if (-not $existing.Identifier -and $item.Identifier) {
        $existing.Identifier = $item.Identifier
      }
      if (-not $existing.Notes -and $item.Notes) {
        $existing.Notes = $item.Notes
      }
    } else {
      $sourceInfo = Update-SourceInfoList -Incoming $item.SourceInfo
      $map[$key] = [PSCustomObject]@{
        Name       = $item.Name
        Version    = $item.Version
        Publisher  = $item.Publisher
        SourceInfo = $sourceInfo
        Source     = Convert-SourceInfoToLabel $sourceInfo
        Identifier = $item.Identifier
        Notes      = $item.Notes
      }
    }
  }

  return $map.Values | Sort-Object Name, Version
}

$inventory = Merge-Inventory -Items @(
  Get-RegistrySoftware
  Get-WingetPackages
  Get-ChocolateyPackages
  Get-AppxSoftware
)

if (-not [string]::IsNullOrWhiteSpace($InventoryPath)) {
  $inventory | ConvertTo-Json -Depth 6 | Set-Content -Path $InventoryPath -Encoding UTF8
}

$tableString = ($inventory | Format-Table Name, Version, Source, Publisher -AutoSize | Out-String).Trim()

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
  $tableString | Set-Content -Path $ReportPath -Encoding UTF8
}

if ($Quiet) {
  return $inventory
}

$tableString
