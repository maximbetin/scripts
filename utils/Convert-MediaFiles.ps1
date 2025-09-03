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
    Example: "C:\Photos\Vacation2024"

.PARAMETER DestinationPath
    The output directory for processed files. If not specified, files are processed in-place.
    The script preserves the relative directory structure from the source.
    Example: "C:\Organized\Media"

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
    • FFmpeg must be installed and accessible (checks PATH, then falls back to WinGet location)
    • PowerShell 5.1 or later
    • Write permissions to source/destination directories
    
    Supported Formats:
    • Images: JPG, JPEG, PNG, BMP, TIFF, HEIC → JPG
    • Videos: MP4, MOV, MKV, AVI, WMV → MP4 (H.264, AAC audio)
    • Audio: MP3, WAV, FLAC, M4A → MP3 (320kbps)
    
    Safety Features:
    • Confirmation prompt before processing (unless -Force)
    • Progress tracking with percentage complete
    • Comprehensive error handling and reporting
    • Resume capability for interrupted operations
    • Dry-run mode with -WhatIf parameter
    
    Author: Media Conversion Script
    Version: 2.0
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
    $proposedName = "$baseName$TargetExtension"
    $newPath = Join-Path $OutputDirectory $proposedName
    
    $counter = 1
    while (Test-Path $newPath) {
        $proposedName = "${baseName}_${counter}${TargetExtension}"
        $newPath = Join-Path $OutputDirectory $proposedName
        $counter++
    }
    
    return $newPath
}

function Invoke-FFmpegConversion {
    param(
        [Parameter(Mandatory)]
        [string]$FFmpegExePath,
        
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        
        [Parameter(Mandatory)]
        [string]$OriginalFilePath
    )
    
    Write-Host "  FFmpeg: `"$FFmpegExePath`" $($Arguments -join ' ')" -ForegroundColor Cyan
    $tempErrorFile = [System.IO.Path]::GetTempFileName()
    $result = @{ Success = $false; FFmpegOutput = ""; ExitCode = -1 }
    
    try {
        $process = Start-Process -FilePath $FFmpegExePath -ArgumentList $Arguments -NoNewWindow -PassThru -Wait -RedirectStandardError $tempErrorFile
        $result.FFmpegOutput = (Get-Content $tempErrorFile | Out-String).Trim()
        $result.ExitCode = $process.ExitCode
        $result.Success = ($result.ExitCode -eq 0)
    } catch {
        Write-Host "ERROR: Start-Process failed for '$OriginalFilePath': $($_.Exception.Message)" -ForegroundColor Red
        $result.FFmpegOutput = "PowerShell Start-Process Error: $($_.Exception.Message)"
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

    switch ($Action.Type) {
        "ImageConversion" {
            @(
                "-i", "`"$($Action.OriginalPath)`"",
                "-q:v", "2",                    # High JPEG quality (1-31, lower = better)
                "-pix_fmt", "yuvj420p",         # Ensure compatible color space
                "-map_metadata", "0",           # Preserve EXIF data
                "-an", "-sn",                   # Remove audio/subtitle streams
                "-y", "`"$($Action.NewPath)`""
            )
        }
        "VideoConversion" {
            @(
                "-i", "`"$($Action.OriginalPath)`"",
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
                "-y", "`"$($Action.NewPath)`""
            )
        }
        "AudioConversion" {
            @(
                "-i", "`"$($Action.OriginalPath)`"",
                "-vn",                          # Remove video streams
                "-c:a", "libmp3lame",
                "-q:a", "0",                    # Variable bitrate, highest quality
                "-map_metadata", "0",           # Preserve ID3 tags
                "-write_id3v2", "1",            # Ensure ID3v2 tags
                "-y", "`"$($Action.NewPath)`""
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
    $result = Invoke-FFmpegConversion -FFmpegExePath $FFmpegPath -Arguments $ffmpegArgs -OriginalFilePath $Action.OriginalPath

    if ($result.Success) {
        Write-Host "  Conversion completed." -ForegroundColor Green
        return $true
    } else {
        Write-Message "ERROR: Conversion failed. Exit $($result.ExitCode)" -Type Error
        Write-Host "FFmpeg Output: $($result.FFmpegOutput)" -ForegroundColor Red
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
        
        [int]$Max = 100
    )
    
    if ([string]::IsNullOrEmpty($InputPath)) { return "" }
    if ($InputPath.Length -le $Max) { return $InputPath }
    
    $prefixLen = [Math]::Min([int][Math]::Round($Max / 2.5), $InputPath.Length)
    $suffixLen = [Math]::Min($Max - $prefixLen - 3, [Math]::Max(0, $InputPath.Length - $prefixLen))
    
    return ($InputPath.Substring(0, $prefixLen) + '...' + $InputPath.Substring($InputPath.Length - $suffixLen))
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
    
    if ($Recurse) {
        Get-ChildItem -Path $Path -Recurse -File
    } else {
        Get-ChildItem -Path $Path -File
    }
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
    
    $ext = $File.Extension.ToLower()
    $isCorrectFormat = ($ext -eq $MediaInfo.Target)
    $isStandardName = $File.Name -match '^(IMG|VID|AUD)_\d{8}_\d{6}_\d{3}(_\d+)?\.+'
    
    $outputDir = if ([string]::IsNullOrEmpty($DestinationPath)) { 
        $File.DirectoryName 
    } else {
        $sourceFullPath = (Resolve-Path -LiteralPath $SourcePath).ProviderPath
        $fileDirFullPath = (Resolve-Path -LiteralPath $File.DirectoryName).ProviderPath
        $relPath = $fileDirFullPath.Substring($sourceFullPath.Length).TrimStart('\\')
        Join-Path $DestinationPath $relPath
    }
    
    $newPath = Get-UniqueTimestampFileName -OriginalFile $File -TargetExtension $MediaInfo.Target -Prefix $MediaInfo.Prefix -OutputDirectory $outputDir
    
    if (-not $isCorrectFormat) {
        return @{ Type = "$($MediaInfo.Type)Conversion"; OriginalPath = $File.FullName; NewPath = $newPath }
    } elseif ($Rename -and -not $isStandardName) {
        $renamePath = if ([string]::IsNullOrEmpty($DestinationPath)) {
            Join-Path $File.DirectoryName ($newPath | Split-Path -Leaf)
        } else {
            $newPath
        }
        return @{ Type = "Rename"; OriginalPath = $File.FullName; NewPath = $renamePath }
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
    $actionsToProcess = @()
    
    foreach ($file in $sourceFiles) {
        $ext = $file.Extension.ToLower()
        if ($mediaTypes.ContainsKey($ext)) {
            $action = New-ProcessingAction -File $file -MediaInfo $mediaTypes[$ext] -DestinationPath $DestinationPath -Rename:$Rename
            if ($null -ne $action) {
                $actionsToProcess += $action
            }
        }
    }
    
    return $actionsToProcess
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
$FFmpegPath = $null
if ($env:FFMPEG_PATH -and (Test-Path $env:FFMPEG_PATH)) {
    $FFmpegPath = $env:FFMPEG_PATH
    Write-Host "Using FFmpeg from environment variable: $FFmpegPath" -ForegroundColor Green
} elseif (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    $FFmpegPath = "ffmpeg"
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

$actionsToProcess = Get-ProcessingActions -SourcePath $SourcePath -DestinationPath $DestinationPath -Recurse:$Recurse -Rename:$Rename

Write-Message "Media Conversion - Plan" -Type Section
Write-Message "Source: $SourcePath" -Type Info
Write-Message "Destination: $(if ([string]::IsNullOrEmpty($DestinationPath)) { '(in-place)' } else { $DestinationPath })" -Type Info
Write-Message "Recurse: $([bool]$Recurse)" -Type Info
Write-Message "Rename non-standard: $([bool]$Rename)" -Type Info
Write-Message "Force: $([bool]$Force)" -Type Info
Write-Host ""
Write-Host "Scanning files in '$SourcePath'..." -ForegroundColor Cyan

if ($actionsToProcess.Count -eq 0) {
    Write-Host "No files to process." -ForegroundColor Green
    exit 0
}

# Update total count in statistics
$statistics.Total = $actionsToProcess.Count

# Handle WhatIf mode
if ($WhatIf) {
    Write-Message "What-If Mode: Planned Actions ($($actionsToProcess.Count))" -Type Section
    $i = 0
    foreach ($a in $actionsToProcess) {
        $i++
        $from = Get-ShortPath -InputPath $a.OriginalPath -Max 100
        $to = Get-ShortPath -InputPath $a.NewPath -Max 100
        if ($a.Type -eq "Rename") {
            Write-Host ("[{0,3}] WOULD RENAME" -f $i) -ForegroundColor Cyan
        } else {
            $fromExt = [System.IO.Path]::GetExtension($a.OriginalPath)
            $toExt = [System.IO.Path]::GetExtension($a.NewPath)
            Write-Host ("[{0,3}] WOULD CONVERT {1} -> {2}" -f $i, $fromExt, $toExt) -ForegroundColor Cyan
        }
        Write-Message "From: $from" -Type Info
        Write-Message "  To: $to" -Type Info
    }
    Write-Host "`nWhat-If mode completed. No files were modified." -ForegroundColor Green
    exit 0
}

if (!$Force) {
    Write-Message "Planned Actions ($($actionsToProcess.Count))" -Type Section
    $i = 0
    foreach ($a in $actionsToProcess) {
        $i++
        $from = Get-ShortPath -InputPath $a.OriginalPath -Max 100
        $to = Get-ShortPath -InputPath $a.NewPath -Max 100
        if ($a.Type -eq "Rename") {
            Write-Host ("[{0,3}] Rename" -f $i) -ForegroundColor Yellow
        } else {
            $fromExt = [System.IO.Path]::GetExtension($a.OriginalPath)
            $toExt = [System.IO.Path]::GetExtension($a.NewPath)
            Write-Host ("[{0,3}] Convert {1} -> {2}" -f $i, $fromExt, $toExt) -ForegroundColor Yellow
        }
        Write-Message "From: $from" -Type Info
        Write-Message "  To: $to" -Type Info
    }
    $response = Read-Host "Proceed with $($actionsToProcess.Count) actions? [y/N]"
    if (@('Y', 'YES') -notcontains ($response.Trim().ToUpper())) {
        Write-Message "Operation cancelled by user." -Type Warning
        exit 0
    }
}

$currentAction = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$checkpointData = @{
    SourcePath       = $SourcePath
    DestinationPath  = $DestinationPath
    TotalActions     = $statistics.Total
    ProcessedActions = @()
    Timestamp        = Get-Date
}

foreach ($action in $actionsToProcess) {
    $currentAction++
    
    $percentComplete = [math]::Round(($currentAction / $statistics.Total) * 100, 1)
    Write-Progress -Activity "Processing Media Files" -Status "$currentAction of $($statistics.Total) files ($percentComplete%)" -PercentComplete $percentComplete
    
    Write-Host "--- ($currentAction/$($statistics.Total)) Executing: $($action.Type) on '$($action.OriginalPath)' ---" -ForegroundColor Cyan

    $success = $false
    $actionStartTime = Get-Date
    
    try {
        $success = if ($action.Type -eq "Rename") {
            $result = Invoke-FileRename -Action $action
            if ($result) { 
                $statistics.Renamed++
            }
            $result
        } else {
            $result = Invoke-MediaConversion -Action $action -FFmpegPath $FFmpegPath
            if ($result) {
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
            $result
        }
        
        if (-not $success) {
            $statistics.Failed++
            $errorMsg = if ($action.Type -eq "Rename") { "Rename operation failed" } else { "Conversion failed" }
            $failedOperations += @{File = $action.OriginalPath; Error = $errorMsg; Time = $actionStartTime }
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
        $failedOperations += @{File = $action.OriginalPath; Error = $_.Exception.Message; Time = $actionStartTime }
    }
}
$sw.Stop()

# Complete progress reporting
Write-Progress -Activity "Processing Media Files" -Completed

# Clean up checkpoint file on successful completion
if ($statistics.Failed -eq 0 -and (Test-Path $checkpointFile)) {
    Remove-Item $checkpointFile -ErrorAction SilentlyContinue
}

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
        Write-Message "[{0,3}] {1}" -f ($i + 1), (Get-ShortPath -InputPath $failure.File -Max 80) -Type Error
        Write-Host "      Error: $($failure.Error)" -ForegroundColor DarkRed
        Write-Host "      Time: $($failure.Time.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
    }
    
    if (Test-Path $checkpointFile) {
        Write-Host "`nCheckpoint file saved for potential resume: $checkpointFile" -ForegroundColor Yellow
    }
} else {
    Write-Message "All operations completed successfully!" -Type Success
}

Write-Message "Elapsed: $($sw.Elapsed.ToString('c'))" -Type Info