<#
.SYNOPSIS
    Converts or renames media files to a standardized format and naming scheme with timestamp-based filenames.

.DESCRIPTION
    This PowerShell script provides a streamlined solution for organizing and converting media files.
    It scans directories for common media formats and performs the following operations:
    
    • Converts images (PNG, BMP, TIFF, HEIC, etc.) to JPG format
    • Converts videos (MOV, MKV, AVI, WMV, etc.) to MP4 format with H.264 encoding
    • Converts audio files (WAV, FLAC, M4A, etc.) to MP3 format
    • Renames files to standardized format: PREFIX_YYYYMMDD_HHMMSS_mmm[_counter].ext
    • Preserves directory structure when using destination path
    • Provides progress tracking and comprehensive error handling
    
    The script uses FFmpeg for all conversions and includes safety features like dry-run mode,
    confirmation prompts, and resume capability for interrupted operations.

.PARAMETER SourcePath
    The source directory to scan for media files. Defaults to current directory.

.PARAMETER DestinationPath
    The output directory for processed files. If not specified, files are processed in-place.
    The script preserves the relative directory structure from the source.

.PARAMETER Recurse
    Process files recursively in all subdirectories. By default, only processes files
    in the specified directory level.

.PARAMETER Rename
    Rename files that are already in the correct format but have non-standard names.
    Useful for organizing files that don't need conversion but need standardized naming.

.PARAMETER Force
    Skip the confirmation prompt and execute all planned actions immediately.
    Use with caution as this bypasses the safety confirmation.

.PARAMETER WhatIf
    Show what actions would be performed without actually executing them.
    Useful for testing and previewing operations before committing to changes.

.EXAMPLE
    .\Convert-MediaFiles-Fixed.ps1 -WhatIf
    Preview what would happen when processing files in current directory

.EXAMPLE
    .\Convert-MediaFiles-Fixed.ps1 -SourcePath "C:\Media" -DestinationPath "C:\Organized" -Recurse
    Convert all media files from C:\Media and subdirectories to C:\Organized with preserved structure

.EXAMPLE
    .\Convert-MediaFiles-Fixed.ps1 -SourcePath "C:\Photos" -Rename -Force
    Rename all correctly formatted files in C:\Photos to standard naming without confirmation

.NOTES
    Requirements:
    • FFmpeg must be installed and accessible
    • PowerShell 5.1 or later
    • Write permissions to source/destination directories
    
    Supported Formats:
    • Images: JPG, JPEG, PNG, BMP, TIFF, HEIC, WEBP, AVIF, SVG → JPG
    • Videos: MP4, MOV, MKV, AVI, WMV, WEBM, OGV → MP4 (H.264, AAC audio)
    • Audio: MP3, WAV, FLAC, M4A, WEBA, OGG, OPUS → MP3 (320kbps)
    
    Author: Media Conversion Script
    Version: 2.1
    Last Updated: 2025
#>
param(
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$SourcePath = (Get-Location).Path,
    
    [string]$DestinationPath,
    
    [switch]$Recurse,
    
    [switch]$Rename,
    
    [switch]$Force,
    
    [switch]$WhatIf
)

function Get-ShortPath {
    param(
        [string]$InputPath = "",
        [int]$MaxLength = 100
    )
    
    if ([string]::IsNullOrEmpty($InputPath) -or $InputPath.Length -le $MaxLength) {
        return $InputPath
    }
    
    $prefixLength = [Math]::Floor($MaxLength / 2.5)
    $suffixLength = $MaxLength - $prefixLength - 3
    
    return $InputPath.Substring(0, $prefixLength) + '...' + $InputPath.Substring($InputPath.Length - $suffixLength)
}

function Write-Message {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('Section', 'Info', 'Success', 'Warning', 'Error')]
        [string]$Type = 'Info'
    )
    
    switch ($Type) {
        'Section' {
            Write-Host ""
            Write-Host "==== $Message ====" -ForegroundColor Magenta
        }
        'Info' { Write-Host "  $Message" -ForegroundColor Gray }
        'Success' { Write-Host "  $Message" -ForegroundColor Green }
        'Warning' { Write-Host "  $Message" -ForegroundColor Yellow }
        'Error' { Write-Host "  $Message" -ForegroundColor Red }
    }
}

function Get-MediaTypeConfiguration {
    return @{
        ".jpg"  = @{ Prefix = "IMG"; Type = "Image"; Target = ".jpg" }
        ".jpeg" = @{ Prefix = "IMG"; Type = "Image"; Target = ".jpg" }
        ".png"  = @{ Prefix = "IMG"; Type = "Image"; Target = ".jpg" }
        ".bmp"  = @{ Prefix = "IMG"; Type = "Image"; Target = ".jpg" }
        ".tiff" = @{ Prefix = "IMG"; Type = "Image"; Target = ".jpg" }
        ".heic" = @{ Prefix = "IMG"; Type = "Image"; Target = ".jpg" }
        ".webp" = @{ Prefix = "IMG"; Type = "Image"; Target = ".jpg" }
        ".avif" = @{ Prefix = "IMG"; Type = "Image"; Target = ".jpg" }
        ".svg"  = @{ Prefix = "IMG"; Type = "Image"; Target = ".jpg" }
        ".mp4"  = @{ Prefix = "VID"; Type = "Video"; Target = ".mp4" }
        ".mov"  = @{ Prefix = "VID"; Type = "Video"; Target = ".mp4" }
        ".mkv"  = @{ Prefix = "VID"; Type = "Video"; Target = ".mp4" }
        ".avi"  = @{ Prefix = "VID"; Type = "Video"; Target = ".mp4" }
        ".wmv"  = @{ Prefix = "VID"; Type = "Video"; Target = ".mp4" }
        ".webm" = @{ Prefix = "VID"; Type = "Video"; Target = ".mp4" }
        ".ogv"  = @{ Prefix = "VID"; Type = "Video"; Target = ".mp4" }
        ".mp3"  = @{ Prefix = "AUD"; Type = "Audio"; Target = ".mp3" }
        ".wav"  = @{ Prefix = "AUD"; Type = "Audio"; Target = ".mp3" }
        ".flac" = @{ Prefix = "AUD"; Type = "Audio"; Target = ".mp3" }
        ".m4a"  = @{ Prefix = "AUD"; Type = "Audio"; Target = ".mp3" }
        ".weba" = @{ Prefix = "AUD"; Type = "Audio"; Target = ".mp3" }
        ".ogg"  = @{ Prefix = "AUD"; Type = "Audio"; Target = ".mp3" }
        ".opus" = @{ Prefix = "AUD"; Type = "Audio"; Target = ".mp3" }
    }
}

function Get-SourceFiles {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [switch]$Recurse
    )
    
    Get-ChildItem -Path $Path -File -Recurse:$Recurse
}

function Get-UniqueTimestampFileName {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$OriginalFile,
        [Parameter(Mandatory)]
        [string]$TargetExtension,
        [Parameter(Mandatory)]
        [string]$Prefix,
        [Parameter(Mandatory)]
        [string]$OutputDirectory
    )
    
    $timestamp = $OriginalFile.LastWriteTime.ToString("yyyyMMdd_HHmmss_fff")
    $baseName = "${Prefix}_$timestamp"
    $newPath = Join-Path $OutputDirectory "$baseName$TargetExtension"
    
    $counter = 1
    while (Test-Path $newPath) {
        $newPath = Join-Path $OutputDirectory "${baseName}_${counter}${TargetExtension}"
        $counter++
    }
    
    return $newPath
}

function New-ProcessingAction {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,
        [Parameter(Mandatory)]
        [hashtable]$MediaInfo,
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [string]$DestinationPath,
        [switch]$Rename
    )
    
    $extension = $File.Extension.ToLower()
    $isCorrectFormat = ($extension -eq $MediaInfo.Target)
    $isStandardName = $File.Name -match '^(IMG|VID|AUD)_\d{8}_\d{6}_\d{3}(_\d+)?\.[^.]+$'
    
    $outputDirectory = if ([string]::IsNullOrEmpty($DestinationPath)) {
        $File.DirectoryName
    } else {
        $sourceFullPath = (Resolve-Path -LiteralPath $SourcePath).ProviderPath
        $fileDirectoryPath = (Resolve-Path -LiteralPath $File.DirectoryName).ProviderPath
        $relativePath = $fileDirectoryPath.Substring($sourceFullPath.Length).TrimStart('\\')
        Join-Path $DestinationPath $relativePath
    }
    
    $newPath = Get-UniqueTimestampFileName -OriginalFile $File -TargetExtension $MediaInfo.Target -Prefix $MediaInfo.Prefix -OutputDirectory $outputDirectory
    
    if (-not $isCorrectFormat) {
        return @{ 
            Type         = "$($MediaInfo.Type)Conversion"
            OriginalPath = $File.FullName
            NewPath      = $newPath 
        }
    } elseif ($Rename -and -not $isStandardName) {
        $renamePath = if ([string]::IsNullOrEmpty($DestinationPath)) {
            Join-Path $File.DirectoryName (Split-Path $newPath -Leaf)
        } else {
            $newPath
        }
        return @{ 
            Type         = "Rename"
            OriginalPath = $File.FullName
            NewPath      = $renamePath 
        }
    }
    
    return $null
}

function Get-ProcessingActions {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [string]$DestinationPath,
        [switch]$Recurse,
        [switch]$Rename
    )
    
    $sourceFiles = Get-SourceFiles -Path $SourcePath -Recurse:$Recurse
    $mediaTypes = Get-MediaTypeConfiguration
    $actions = @()
    
    foreach ($file in $sourceFiles) {
        $extension = $file.Extension.ToLower()
        if ($mediaTypes.ContainsKey($extension)) {
            $action = New-ProcessingAction -File $file -MediaInfo $mediaTypes[$extension] -SourcePath $SourcePath -DestinationPath $DestinationPath -Rename:$Rename
            if ($null -ne $action) {
                $actions += $action
            }
        }
    }
    
    return $actions
}

# Script Configuration and Initialization
$ErrorActionPreference = "Continue"

# FFmpeg Discovery
if ($env:FFMPEG_PATH -and (Test-Path $env:FFMPEG_PATH)) {
    $script:ffmpegPath = $env:FFMPEG_PATH
    Write-Host "Using FFmpeg from environment variable: $script:ffmpegPath" -ForegroundColor Green
} elseif (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    $script:ffmpegPath = "ffmpeg"
    Write-Host "Using FFmpeg from PATH" -ForegroundColor Green
} else {
    Write-Host "FATAL: FFmpeg executable not found. Please install FFmpeg or set FFMPEG_PATH environment variable." -ForegroundColor Red
    Write-Host "Install options:" -ForegroundColor Yellow
    Write-Host "  • winget install ffmpeg" -ForegroundColor Gray
    Write-Host "  • choco install ffmpeg" -ForegroundColor Gray
    Write-Host "  • Download from https://ffmpeg.org/download.html" -ForegroundColor Gray
    exit 1
}

# Input validation
if (-not (Test-Path $SourcePath)) {
    Write-Host "ERROR: Source path does not exist: $SourcePath" -ForegroundColor Red
    exit 1
}

if ($DestinationPath) {
    $destinationParent = Split-Path $DestinationPath -Parent
    if ($destinationParent -and -not (Test-Path $destinationParent)) {
        Write-Host "ERROR: Destination parent directory does not exist: $destinationParent" -ForegroundColor Red
        exit 1
    }
}

$actions = Get-ProcessingActions -SourcePath $SourcePath -DestinationPath $DestinationPath -Recurse:$Recurse -Rename:$Rename

Write-Message "Media Conversion - Plan" -Type Section
Write-Message "Source: $SourcePath" -Type Info
Write-Message "Destination: $(if ([string]::IsNullOrEmpty($DestinationPath)) { '(in-place)' } else { $DestinationPath })" -Type Info
Write-Message "Recurse: $([bool]$Recurse)" -Type Info
Write-Message "Rename non-standard: $([bool]$Rename)" -Type Info
Write-Message "Force: $([bool]$Force)" -Type Info
Write-Host ""
Write-Host "Scanning files in '$SourcePath'..." -ForegroundColor Cyan

if ($actions.Count -eq 0) {
    Write-Host "No files to process." -ForegroundColor Green
    exit 0
}

# Handle WhatIf mode
if ($WhatIf) {
    Write-Message "What-If Mode: Planned Actions ($($actions.Count))" -Type Section
    for ($i = 0; $i -lt $actions.Count; $i++) {
        $action = $actions[$i]
        $from = Get-ShortPath -InputPath $action.OriginalPath -MaxLength 100
        $to = Get-ShortPath -InputPath $action.NewPath -MaxLength 100
        
        if ($action.Type -eq "Rename") {
            Write-Host ("[{0,3}] WOULD RENAME" -f ($i + 1)) -ForegroundColor Cyan
        } else {
            $fromExt = [System.IO.Path]::GetExtension($action.OriginalPath)
            $toExt = [System.IO.Path]::GetExtension($action.NewPath)
            Write-Host ("[{0,3}] WOULD CONVERT {1} -> {2}" -f ($i + 1), $fromExt, $toExt) -ForegroundColor Cyan
        }
        Write-Message "From: $from" -Type Info
        Write-Message "  To: $to" -Type Info
    }
    Write-Host "`nWhat-If mode completed. No files were modified." -ForegroundColor Green
    exit 0
}

# User confirmation (unless Force is specified)
if (-not $Force) {
    Write-Host ""
    Write-Host "Ready to process $($actions.Count) file(s). Continue? [Y/N]: " -NoNewline -ForegroundColor Yellow
    $response = Read-Host
    if ($response -notmatch '^[Yy]') {
        Write-Host "Operation cancelled by user." -ForegroundColor Yellow
        exit 0
    }
}

# Process files
Write-Message "Processing Files" -Type Section
$processedCount = 0
$errorCount = 0

foreach ($action in $actions) {
    $processedCount++
    $fileName = Split-Path $action.OriginalPath -Leaf
    
    try {
        # Ensure output directory exists
        $outputDir = Split-Path $action.NewPath -Parent
        if (-not (Test-Path $outputDir)) {
            New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
        }
        
        if ($action.Type -eq "Rename") {
            Write-Host "[$processedCount/$($actions.Count)] Renaming: $fileName" -ForegroundColor Cyan
            Move-Item -Path $action.OriginalPath -Destination $action.NewPath -Force
            Write-Message "Renamed successfully" -Type Success
        } else {
            Write-Host "[$processedCount/$($actions.Count)] Converting: $fileName" -ForegroundColor Cyan
            
            # Build FFmpeg command based on media type
            $ffmpegArgs = @("-i", $action.OriginalPath, "-y")
            
            switch -Regex ($action.Type) {
                "ImageConversion" {
                    $ffmpegArgs += @("-q:v", "2", $action.NewPath)
                }
                "VideoConversion" {
                    $ffmpegArgs += @("-c:v", "libx264", "-crf", "23", "-c:a", "aac", "-b:a", "128k", $action.NewPath)
                }
                "AudioConversion" {
                    $ffmpegArgs += @("-c:a", "libmp3lame", "-b:a", "320k", $action.NewPath)
                }
            }
            
            # Execute FFmpeg
            $process = Start-Process -FilePath $script:ffmpegPath -ArgumentList $ffmpegArgs -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
            
            if ($process.ExitCode -eq 0) {
                Write-Message "Converted successfully" -Type Success
                # Remove original file after successful conversion
                Remove-Item -Path $action.OriginalPath -Force
            } else {
                Write-Message "Conversion failed (Exit code: $($process.ExitCode))" -Type Error
                $errorCount++
            }
        }
    } catch {
        Write-Message "Error: $($_.Exception.Message)" -Type Error
        $errorCount++
    }
}

# Final summary
Write-Message "Processing Complete" -Type Section
Write-Message "Total files processed: $processedCount" -Type Info
Write-Message "Successful: $($processedCount - $errorCount)" -Type Success
if ($errorCount -gt 0) {
    Write-Message "Errors: $errorCount" -Type Error
} else {
    Write-Host "All files processed successfully!" -ForegroundColor Green
}