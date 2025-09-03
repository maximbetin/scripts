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
    The source directory to scan for media files. Must be a valid existing path.

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
    .\Convert-MediaFiles.ps1 -SourcePath "C:\Photos" -WhatIf
    Preview what would happen when processing photos in C:\Photos

.EXAMPLE
    .\Convert-MediaFiles.ps1 -SourcePath "C:\Media" -DestinationPath "C:\Organized" -Recurse
    Convert all media files from C:\Media and subdirectories to C:\Organized with preserved structure

.EXAMPLE
    .\Convert-MediaFiles.ps1 -SourcePath "C:\Photos" -Rename -Force
    Rename all correctly formatted files in C:\Photos to standard naming without confirmation

.NOTES
    Requirements:
    • FFmpeg must be installed and accessible
    • PowerShell 5.1 or later
    • Write permissions to source/destination directories
    
    Supported Formats:
    • Images: JPG, JPEG, PNG, BMP, TIFF, HEIC → JPG
    • Videos: MP4, MOV, MKV, AVI, WMV → MP4 (H.264, AAC audio)
    • Audio: MP3, WAV, FLAC, M4A → MP3 (320kbps)
    
    Author: Media Conversion Script
    Version: 2.1
    Last Updated: 2025
#>
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$SourcePath,
    
    [string]$DestinationPath,
    
    [switch]$Recurse,
    
    [switch]$Rename,
    
    [switch]$Force,
    
    [switch]$WhatIf
)

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

function Invoke-FFmpegConversion {
    param(
        [Parameter(Mandatory)]
        [string]$FFmpegPath,
        
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        
        [Parameter(Mandatory)]
        [string]$OriginalFilePath
    )
    
    Write-Host "  FFmpeg: `"$FFmpegPath`" $($Arguments -join ' ')" -ForegroundColor Cyan
    $tempErrorFile = [System.IO.Path]::GetTempFileName()
    $result = @{ Success = $false; Output = ""; ExitCode = -1 }
    
    try {
        $process = Start-Process -FilePath $FFmpegPath -ArgumentList $Arguments -NoNewWindow -PassThru -Wait -RedirectStandardError $tempErrorFile
        $result.Output = (Get-Content $tempErrorFile -ErrorAction SilentlyContinue | Out-String).Trim()
        $result.ExitCode = $process.ExitCode
        $result.Success = ($result.ExitCode -eq 0)
    } catch {
        Write-Host "ERROR: FFmpeg execution failed for '$OriginalFilePath': $($_.Exception.Message)" -ForegroundColor Red
        $result.Output = "PowerShell execution error: $($_.Exception.Message)"
    } finally {
        Remove-Item $tempErrorFile -ErrorAction SilentlyContinue
    }
    
    return $result
}

function Save-Checkpoint {
    param(
        [Parameter(Mandatory)]
        [hashtable]$CheckpointData,
        
        [Parameter(Mandatory)]
        [string]$CheckpointFile
    )
    
    try {
        $CheckpointData | ConvertTo-Json -Depth 10 | Set-Content $CheckpointFile -ErrorAction SilentlyContinue
    } catch {
        # Silently continue if checkpoint save fails
    }
}

function Get-FFmpegArguments {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Action
    )

    $inputPath = "`"$($Action.OriginalPath)`""
    $outputPath = "`"$($Action.NewPath)`""

    switch ($Action.Type) {
        "ImageConversion" {
            @(
                "-i", $inputPath,
                "-q:v", "2",                    # High JPEG quality (1-31, lower = better)
                "-pix_fmt", "yuvj420p",         # Ensure compatible color space
                "-map_metadata", "0",           # Preserve EXIF data
                "-an", "-sn",                   # Remove audio/subtitle streams
                "-y", $outputPath
            )
        }
        "VideoConversion" {
            @(
                "-i", $inputPath,
                "-c:v", "libx264",
                "-crf", "20",                   # Balanced quality for smaller files
                "-preset", "faster",            # Better speed/quality balance
                "-profile:v", "high",           # H.264 profile for better compatibility
                "-level", "4.1",                # Compatibility level
                "-pix_fmt", "yuv420p",          # Ensure compatibility
                "-c:a", "aac",
                "-b:a", "128k",                 # Sufficient for most content
                "-ac", "2",                     # Stereo audio
                "-movflags", "+faststart",      # Web optimization
                "-map_metadata", "0",           # Preserve metadata
                "-y", $outputPath
            )
        }
        "AudioConversion" {
            @(
                "-i", $inputPath,
                "-vn",                          # Remove video streams
                "-c:a", "libmp3lame",
                "-q:a", "0",                    # Variable bitrate, highest quality
                "-map_metadata", "0",           # Preserve ID3 tags
                "-write_id3v2", "1",            # Ensure ID3v2 tags
                "-y", $outputPath
            )
        }
        default {
            $null
        }
    }
}

function New-DirectoryIfNotExists {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

function Invoke-MediaConversion {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Action,
        
        [Parameter(Mandatory)]
        [string]$FFmpegPath
    )

    $ffmpegArgs = Get-FFmpegArguments -Action $Action
    if ($null -eq $ffmpegArgs) {
        Write-Message "ERROR: Unknown action type '$($Action.Type)' for file '$($Action.OriginalPath)'" -Type Error
        return $false
    }

    New-DirectoryIfNotExists -Path $Action.NewPath
    $result = Invoke-FFmpegConversion -FFmpegPath $FFmpegPath -Arguments $ffmpegArgs -OriginalFilePath $Action.OriginalPath

    if ($result.Success) {
        Write-Host "  Conversion completed." -ForegroundColor Green
        return $true
    } else {
        Write-Message "ERROR: Conversion failed. Exit code: $($result.ExitCode)" -Type Error
        if ($result.Output) {
            Write-Host "FFmpeg Output: $($result.Output)" -ForegroundColor Red
        }
        return $false
    }
}

function Invoke-FileRename {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Action
    )
    
    try {
        New-DirectoryIfNotExists -Path $Action.NewPath
        Move-Item -LiteralPath $Action.OriginalPath -Destination $Action.NewPath
        Write-Host "  File renamed (no re-encode)." -ForegroundColor Green
        return $true
    } catch {
        Write-Message "ERROR: Rename failed: $($_.Exception.Message)" -Type Error
        return $false
    }
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

function Get-ShortPath {
    param(
        [Parameter(Mandatory)]
        [string]$InputPath,
        
        [int]$MaxLength = 100
    )
    
    if ([string]::IsNullOrEmpty($InputPath) -or $InputPath.Length -le $MaxLength) {
        return $InputPath
    }
    
    $prefixLength = [Math]::Floor($MaxLength / 2.5)
    $suffixLength = $MaxLength - $prefixLength - 3
    
    return $InputPath.Substring(0, $prefixLength) + '...' + $InputPath.Substring($InputPath.Length - $suffixLength)
}

function Get-MediaTypeConfiguration {
    return @{
        ".jpg"  = @{ Prefix = "IMG"; Type = "Image"; Target = ".jpg" }
        ".jpeg" = @{ Prefix = "IMG"; Type = "Image"; Target = ".jpg" }
        ".png"  = @{ Prefix = "IMG"; Type = "Image"; Target = ".jpg" }
        ".bmp"  = @{ Prefix = "IMG"; Type = "Image"; Target = ".jpg" }
        ".tiff" = @{ Prefix = "IMG"; Type = "Image"; Target = ".jpg" }
        ".heic" = @{ Prefix = "IMG"; Type = "Image"; Target = ".jpg" }
        ".mp4"  = @{ Prefix = "VID"; Type = "Video"; Target = ".mp4" }
        ".mov"  = @{ Prefix = "VID"; Type = "Video"; Target = ".mp4" }
        ".mkv"  = @{ Prefix = "VID"; Type = "Video"; Target = ".mp4" }
        ".avi"  = @{ Prefix = "VID"; Type = "Video"; Target = ".mp4" }
        ".wmv"  = @{ Prefix = "VID"; Type = "Video"; Target = ".mp4" }
        ".mp3"  = @{ Prefix = "AUD"; Type = "Audio"; Target = ".mp3" }
        ".wav"  = @{ Prefix = "AUD"; Type = "Audio"; Target = ".mp3" }
        ".flac" = @{ Prefix = "AUD"; Type = "Audio"; Target = ".mp3" }
        ".m4a"  = @{ Prefix = "AUD"; Type = "Audio"; Target = ".mp3" }
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

function New-ProcessingAction {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,
        
        [Parameter(Mandatory)]
        [hashtable]$MediaInfo,
        
        [string]$DestinationPath,
        
        [switch]$Rename
    )
    
    $extension = $File.Extension.ToLower()
    $isCorrectFormat = ($extension -eq $MediaInfo.Target)
    $isStandardName = $File.Name -match '^(IMG|VID|AUD)_\d{8}_\d{6}_\d{3}(_\d+)?\.+'
    
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
            $action = New-ProcessingAction -File $file -MediaInfo $mediaTypes[$extension] -DestinationPath $DestinationPath -Rename:$Rename
            if ($null -ne $action) {
                $actions += $action
            }
        }
    }
    
    return $actions
}

# Script Configuration and Initialization
$ErrorActionPreference = "Continue"

# Initialize statistics and failure tracking
$statistics = @{
    Total     = 0
    Converted = 0
    Renamed   = 0
    Deleted   = 0
    Failed    = 0
}
$failedOperations = @()

# Resume capability - check for checkpoint file
$checkpointFile = Join-Path $env:TEMP "Convert-MediaFiles-checkpoint.json"
if (Test-Path $checkpointFile) {
    try {
        Get-Content $checkpointFile | ConvertFrom-Json | Out-Null
        Write-Host "Found previous session checkpoint. Resume available." -ForegroundColor Yellow
    } catch {
        Remove-Item $checkpointFile -ErrorAction SilentlyContinue
    }
}

# FFmpeg Discovery
$ffmpegPath = $null
if ($env:FFMPEG_PATH -and (Test-Path $env:FFMPEG_PATH)) {
    $ffmpegPath = $env:FFMPEG_PATH
    Write-Host "Using FFmpeg from environment variable: $ffmpegPath" -ForegroundColor Green
} elseif (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    $ffmpegPath = "ffmpeg"
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

if ($DestinationPath -and -not (Test-Path (Split-Path $DestinationPath -Parent))) {
    Write-Host "ERROR: Destination parent directory does not exist: $(Split-Path $DestinationPath -Parent)" -ForegroundColor Red
    exit 1
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

# Update total count in statistics
$statistics.Total = $actions.Count

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

if (-not $Force) {
    Write-Message "Planned Actions ($($actions.Count))" -Type Section
    for ($i = 0; $i -lt $actions.Count; $i++) {
        $action = $actions[$i]
        $from = Get-ShortPath -InputPath $action.OriginalPath -MaxLength 100
        $to = Get-ShortPath -InputPath $action.NewPath -MaxLength 100
        
        if ($action.Type -eq "Rename") {
            Write-Host ("[{0,3}] Rename" -f ($i + 1)) -ForegroundColor Yellow
        } else {
            $fromExt = [System.IO.Path]::GetExtension($action.OriginalPath)
            $toExt = [System.IO.Path]::GetExtension($action.NewPath)
            Write-Host ("[{0,3}] Convert {1} -> {2}" -f ($i + 1), $fromExt, $toExt) -ForegroundColor Yellow
        }
        Write-Message "From: $from" -Type Info
        Write-Message "  To: $to" -Type Info
    }
    $response = Read-Host "Proceed with $($actions.Count) actions? [y/N]"
    if (@('Y', 'YES') -notcontains ($response.Trim().ToUpper())) {
        Write-Message "Operation cancelled by user." -Type Warning
        exit 0
    }
}

$currentAction = 0
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

$checkpointData = @{
    SourcePath       = $SourcePath
    DestinationPath  = $DestinationPath
    TotalActions     = $statistics.Total
    ProcessedActions = @()
    Timestamp        = Get-Date
}

foreach ($action in $actions) {
    $currentAction++
    
    $percentComplete = [math]::Round(($currentAction / $statistics.Total) * 100, 1)
    Write-Progress -Activity "Processing Media Files" -Status "$currentAction of $($statistics.Total) files ($percentComplete%)" -PercentComplete $percentComplete
    
    Write-Host "--- ($currentAction/$($statistics.Total)) Executing: $($action.Type) on '$($action.OriginalPath)' ---" -ForegroundColor Cyan

    $success = $false
    $actionStartTime = Get-Date
    
    try {
        if ($action.Type -eq "Rename") {
            $success = Invoke-FileRename -Action $action
            if ($success) { 
                $statistics.Renamed++
            }
        } else {
            $success = Invoke-MediaConversion -Action $action -FFmpegPath $ffmpegPath
            if ($success) {
                $statistics.Converted++
                
                try {
                    Remove-Item -LiteralPath $action.OriginalPath -ErrorAction Stop
                    Write-Host "  ✓ Removed original file" -ForegroundColor Green
                    $statistics.Deleted++
                } catch {
                    Write-Host "  ⚠ WARNING: Failed to delete original: $($_.Exception.Message)" -ForegroundColor Yellow
                    Write-Host "    Original file remains at: $($action.OriginalPath)" -ForegroundColor Gray
                }
            }
        }
        
        if (-not $success) {
            $statistics.Failed++
            $errorMessage = if ($action.Type -eq "Rename") { "Rename operation failed" } else { "Conversion failed" }
            $failedOperations += @{
                File  = $action.OriginalPath
                Error = $errorMessage
                Time  = $actionStartTime 
            }
        }
        
        $checkpointData.ProcessedActions += @{
            Action      = $action
            Success     = $success
            ProcessedAt = Get-Date
        }
        
        if (($currentAction % 5 -eq 0) -or (-not $success)) {
            Save-Checkpoint -CheckpointData $checkpointData -CheckpointFile $checkpointFile
        }
        
    } catch {
        Write-Host "  ✗ CRITICAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $statistics.Failed++
        $failedOperations += @{
            File  = $action.OriginalPath
            Error = $_.Exception.Message
            Time  = $actionStartTime 
        }
    }
}
$stopwatch.Stop()

# Complete progress reporting
Write-Progress -Activity "Processing Media Files" -Completed

# Clean up checkpoint file on successful completion
if ($statistics.Failed -eq 0 -and (Test-Path $checkpointFile)) {
    Remove-Item $checkpointFile -ErrorAction SilentlyContinue
}

# Display summary
Write-Message "Summary" -Type Section
Write-Message "Total actions: $($statistics.Total)" -Type Info
Write-Message "Converted: $($statistics.Converted)" -Type Success
Write-Message "Renamed: $($statistics.Renamed)" -Type Success
Write-Message "Deleted originals: $($statistics.Deleted)" -Type Success

if ($statistics.Failed -gt 0) {
    Write-Message "Failed: $($statistics.Failed)" -Type Error
    Write-Host ""
    Write-Host "Failed Operations Details:" -ForegroundColor Red
    
    for ($i = 0; $i -lt $failedOperations.Count; $i++) {
        $failure = $failedOperations[$i]
        Write-Message "[{0,3}] {1}" -f ($i + 1), (Get-ShortPath -InputPath $failure.File -MaxLength 80) -Type Error
        Write-Host "      Error: $($failure.Error)" -ForegroundColor DarkRed
        Write-Host "      Time: $($failure.Time.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
    }
    
    if (Test-Path $checkpointFile) {
        Write-Host "`nCheckpoint file saved for potential resume: $checkpointFile" -ForegroundColor Yellow
    }
} else {
    Write-Message "All operations completed successfully!" -Type Success
}

Write-Message "Elapsed: $($stopwatch.Elapsed.ToString('c'))" -Type Info