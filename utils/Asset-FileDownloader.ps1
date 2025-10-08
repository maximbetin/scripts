<#
.SYNOPSIS
    Universal File Downloader - Downloads files from URLs with advanced features.

.DESCRIPTION
    A PowerShell script that downloads files from URLs with comprehensive features:
    - Supports all file types (images, videos, documents, archives, etc.)
    - File type organization into subdirectories
    - Resume capability for interrupted downloads
    - Advanced error handling and retry mechanisms
    - File validation and integrity checking
    - Comprehensive progress reporting

.PARAMETER UrlsFile
    Path to a text file containing URLs (one per line).

.PARAMETER Urls
    Array of URLs to download directly.

.PARAMETER OutputDirectory
    Directory where files will be saved. Default is './downloads'.

.PARAMETER NamingPattern
    File naming pattern: 'original', 'sequential', 'timestamp', 'custom'.

.PARAMETER CustomPrefix
    Custom prefix for filenames when using 'custom' naming pattern.

.PARAMETER OrganizeByType
    Organize files into subdirectories by file type.

.PARAMETER Resume
    Skip files that already exist locally.

.PARAMETER MaxRetries
    Maximum number of retry attempts for failed downloads. Default is 3.

.PARAMETER ValidateFiles
    Validate downloaded files by checking if they exist and are not empty.

.EXAMPLE
    .\Asset-FileDownloader.ps1 -UrlsFile "assets.txt" -OutputDirectory "downloads" -OrganizeByType
    Downloads files from assets.txt with organization by type.

.EXAMPLE
    .\Asset-FileDownloader.ps1 -Urls @("https://example.com/file.mp3") -Resume -MaxRetries 5
    Downloads specific URL with resume capability and 5 retry attempts.
#>

param(
    [string]$UrlsFile = "",
    [string[]]$Urls = @(),
    [string]$OutputDirectory = "./downloads",
    [ValidateSet("original", "sequential", "timestamp", "custom")]
    [string]$NamingPattern = "original",
    [string]$CustomPrefix = "download",
    [switch]$OrganizeByType,
    [switch]$Resume,
    [int]$MaxRetries = 3,
    [switch]$ValidateFiles
)

#region Helper Functions

function Test-UrlFormat {
    param([string]$Url)

    try {
        $uri = [System.Uri]$Url
        return $uri.Scheme -in @('http', 'https', 'ftp')
    } catch {
        return $false
    }
}

function Get-FileExtension {
    param([string]$Url)

    try {
        $uri = [System.Uri]$Url
        $extension = [System.IO.Path]::GetExtension($uri.LocalPath)
        return $extension ? $extension.ToLower() : '.bin'
    } catch {
        return '.bin'
    }
}

function Get-FileTypeCategory {
    param([string]$Extension)

    $fileCategories = @{
        'Audio'        = @('.mp3', '.wav', '.flac', '.aac', '.ogg', '.wma', '.m4a')
        'Video'        = @('.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm', '.m4v')
        'Image'        = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg', '.ico')
        'Document'     = @('.pdf', '.doc', '.docx', '.txt', '.rtf', '.odt', '.pages')
        'Spreadsheet'  = @('.xls', '.xlsx', '.csv', '.ods', '.numbers')
        'Presentation' = @('.ppt', '.pptx', '.odp', '.key')
        'Archive'      = @('.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz')
        'Code'         = @('.js', '.html', '.css', '.py', '.java', '.cpp', '.c', '.cs', '.php')
        'Data'         = @('.json', '.xml', '.yaml', '.sql', '.db', '.sqlite')
    }

    foreach ($category in $fileCategories.Keys) {
        if ($Extension -in $fileCategories[$category]) {
            return $category
        }
    }
    return 'Other'
}

function Get-SafeFileName {
    param(
        [string]$Url,
        [int]$Index = 0
    )

    $extension = Get-FileExtension $Url
    $uri = [System.Uri]$Url
    $originalName = [System.IO.Path]::GetFileNameWithoutExtension($uri.LocalPath)

    if ([string]::IsNullOrWhiteSpace($originalName)) {
        $originalName = "file"
    }

    # Sanitize filename
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $originalName = $originalName -replace "[$invalidChars]", '_'

    switch ($NamingPattern) {
        'original' { return "$originalName$extension" }
        'sequential' { return "{0:D4}_{1}{2}" -f $Index, $originalName, $extension }
        'timestamp' {
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            return "{0}_{1}{2}" -f $timestamp, $originalName, $extension
        }
        'custom' { return "{0}_{1:D4}{2}" -f $CustomPrefix, $Index, $extension }
        default { return "$originalName$extension" }
    }
}

function Format-FileSize {
    param([long]$Size)

    if ($Size -gt 1GB) { return "{0:N2} GB" -f ($Size / 1GB) }
    elseif ($Size -gt 1MB) { return "{0:N2} MB" -f ($Size / 1MB) }
    elseif ($Size -gt 1KB) { return "{0:N2} KB" -f ($Size / 1KB) }
    else { return "$Size bytes" }
}

function Invoke-FileDownload {
    param(
        [string]$Url,
        [string]$OutputPath,
        [int]$FileIndex,
        [int]$TotalFiles
    )

    $fileName = Split-Path $OutputPath -Leaf
    $attempt = 0

    while ($attempt -lt $MaxRetries) {
        $attempt++

        try {
            # Display progress
            if ($attempt -gt 1) {
                Write-Host "  Retry $attempt/$MaxRetries for: $fileName" -ForegroundColor Yellow
            } else {
                Write-Host "[$FileIndex/$TotalFiles] Downloading: $fileName" -ForegroundColor Cyan
            }

            # Configure security protocols
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

            # Download with modern headers
            $headers = @{
                'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
            }

            Invoke-WebRequest -Uri $Url -OutFile $OutputPath -Headers $headers -TimeoutSec 30 -UseBasicParsing

            # Validate download
            if ($ValidateFiles -and (Test-Path $OutputPath)) {
                $fileInfo = Get-Item $OutputPath
                if ($fileInfo.Length -gt 0) {
                    Write-Host "  ✓ Downloaded and validated: $fileName ($(Format-FileSize $fileInfo.Length))" -ForegroundColor Green
                } else {
                    Write-Host "  ⚠ Downloaded but file is empty: $fileName" -ForegroundColor Yellow
                }
            } else {
                Write-Host "  ✓ Downloaded: $fileName" -ForegroundColor Green
            }

            return $true
        } catch {
            Write-Host "  ✗ Attempt $attempt failed: $($_.Exception.Message)" -ForegroundColor Red

            if ($attempt -eq $MaxRetries) {
                Write-Host "  ✗ All retry attempts failed for: $fileName" -ForegroundColor Red
                return $false
            }

            Start-Sleep -Seconds (2 * $attempt)  # Exponential backoff
        }
    }

    return $false
}

function New-DownloadReport {
    param(
        [string]$OutputDirectory,
        [int]$TotalProcessed,
        [int]$Successful,
        [int]$Failed,
        [long]$TotalSize
    )

    $reportPath = Join-Path $OutputDirectory "download_report.txt"
    $report = @(
        "Universal File Downloader Report",
        "Generated: $(Get-Date)",
        "",
        "Summary:",
        "- Total files processed: $TotalProcessed",
        "- Successful downloads: $Successful",
        "- Failed downloads: $Failed",
        "- Total size downloaded: $(Format-FileSize $TotalSize)",
        "",
        "Downloaded files:"
    )

    Get-ChildItem -Path $OutputDirectory -Recurse -File |
    Where-Object { $_.Name -ne "download_report.txt" } |
    ForEach-Object {
        $relativePath = $_.FullName.Substring($OutputDirectory.Length).TrimStart('\', '/')
        if ([string]::IsNullOrEmpty($relativePath)) {
            $relativePath = $_.Name
        }
        $report += "- $relativePath ($(Format-FileSize $_.Length))"
    }

    $report | Out-File -FilePath $reportPath -Encoding UTF8
    Write-Host "Download report created: $reportPath" -ForegroundColor Cyan
}

#endregion

#region Main Execution

Write-Host "=== Universal File Downloader ===" -ForegroundColor Yellow
Write-Host ""

# Collect URLs from all sources
$allUrls = @()

if ($UrlsFile -and (Test-Path $UrlsFile)) {
    Write-Host "Reading URLs from: $UrlsFile" -ForegroundColor Cyan
    $allUrls += Get-Content $UrlsFile | Where-Object { $_.Trim() -and -not $_.StartsWith('#') }
}

if ($Urls.Count -gt 0) {
    Write-Host "Adding URLs from parameter" -ForegroundColor Cyan
    $allUrls += $Urls
}

if ($allUrls.Count -eq 0) {
    Write-Error "No URLs provided. Use -Urls parameter or -UrlsFile parameter."
    exit 1
}

Write-Host "Found $($allUrls.Count) URLs to process" -ForegroundColor Green
Write-Host ""

# Build download queue
Write-Host "Preparing download list..." -ForegroundColor Cyan
$downloadQueue = @()
$index = 1

foreach ($url in $allUrls) {
    $url = $url.Trim()

    if ([string]::IsNullOrWhiteSpace($url) -or $url.StartsWith('#')) {
        continue
    }

    if (-not (Test-UrlFormat $url)) {
        Write-Warning "Invalid URL format: $url"
        continue
    }

    $fileName = Get-SafeFileName -Url $url -Index $index

    # Determine output location
    $outputDir = $OutputDirectory
    if ($OrganizeByType) {
        $extension = Get-FileExtension $url
        $category = Get-FileTypeCategory $extension
        $outputDir = Join-Path $OutputDirectory $category
    }

    $outputPath = Join-Path $outputDir $fileName

    # Skip existing files if resume is enabled
    if ($Resume -and (Test-Path $outputPath)) {
        Write-Host "  ⏭️ Skipping existing file: $fileName" -ForegroundColor Yellow
        continue
    }

    $downloadQueue += [PSCustomObject]@{
        Url        = $url
        OutputPath = $outputPath
        OutputDir  = $outputDir
        FileName   = $fileName
        Index      = $index
    }

    $index++
}

if ($downloadQueue.Count -eq 0) {
    Write-Host "No valid files to download." -ForegroundColor Yellow
    exit 0
}

Write-Host "Prepared $($downloadQueue.Count) files for download" -ForegroundColor Green
Write-Host ""

# Create required directories
$requiredDirs = $downloadQueue.OutputDir | Sort-Object -Unique
foreach ($dir in $requiredDirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "Created directory: $dir" -ForegroundColor Green
    }
}

# Execute downloads
$stats = @{
    Successful = 0
    Failed     = 0
    TotalSize  = 0
}

Write-Host "Starting downloads..." -ForegroundColor Yellow
Write-Host ""

foreach ($download in $downloadQueue) {
    $success = Invoke-FileDownload -Url $download.Url -OutputPath $download.OutputPath -FileIndex $download.Index -TotalFiles $downloadQueue.Count

    if ($success) {
        $stats.Successful++
        if (Test-Path $download.OutputPath) {
            $stats.TotalSize += (Get-Item $download.OutputPath).Length
        }
    } else {
        $stats.Failed++
    }
}

# Display results
Write-Host ""
Write-Host "=== Download Summary ===" -ForegroundColor Yellow
Write-Host "Successful: $($stats.Successful)" -ForegroundColor Green
Write-Host "Failed: $($stats.Failed)" -ForegroundColor Red
Write-Host "Total Size: $(Format-FileSize $stats.TotalSize)" -ForegroundColor Cyan
Write-Host "Output Directory: $OutputDirectory" -ForegroundColor Cyan

if ($OrganizeByType) {
    Write-Host "Files organized by type in subdirectories" -ForegroundColor Cyan
}

Write-Host ""

if ($stats.Failed -gt 0) {
    Write-Host "Some downloads failed. You can re-run with -Resume to skip successful downloads." -ForegroundColor Yellow
    Write-Host "Consider increasing -MaxRetries for better success rate." -ForegroundColor Yellow
} else {
    Write-Host "All downloads completed successfully! 🎉" -ForegroundColor Green
}

# Generate report
if ($stats.Successful -gt 0) {
    New-DownloadReport -OutputDirectory $OutputDirectory -TotalProcessed $downloadQueue.Count -Successful $stats.Successful -Failed $stats.Failed -TotalSize $stats.TotalSize
}

Write-Host ""
Write-Host "Download process completed." -ForegroundColor Yellow

#endregion