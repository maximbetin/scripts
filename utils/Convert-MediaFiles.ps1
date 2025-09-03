<#
.SYNOPSIS
    Converts or renames media files to a standardized format and naming scheme.
.DESCRIPTION
    This script scans a source directory for media files and converts them to standard formats (JPG, MP4, MP3),
    renaming them based on a timestamp. Originals are deleted by default.
.PARAMETER SourcePath
    The directory to scan for media files.
.PARAMETER DestinationPath
    (Optional) The output directory for processed files. If not provided, files are processed in-place.
.PARAMETER Recurse
    (Optional) Process files recursively in subdirectories. By default, only the specified directory level is processed.
.PARAMETER Rename
    (Optional) Rename files that are already in the correct format but have non-standard names.
.PARAMETER Force
    (Optional) Skip the confirmation prompt and execute all actions.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $false)]
    [string]$DestinationPath,

    [Parameter(Mandatory = $false)]
    [switch]$Recurse,

    [Parameter(Mandatory = $false)]
    [switch]$Rename,

    [Parameter(Mandatory = $false)]
    [switch]$Force
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
        $proposedName = "${baseName}_$counter$TargetExtension"
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
    
    Write-Host "  FFmpeg: `"$FFmpegExePath`" $($Arguments -join ' ') " -ForegroundColor Cyan
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

function Get-FFmpegArguments {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Action
    )

    switch ($Action.Type) {
        "ImageConversion" {
            @("-i", "`"$($Action.OriginalPath)`"", "-an", "-sn", "-y", "`"$($Action.NewPath)`"")
        }
        "VideoConversion" {
            @(
                "-i", "`"$($Action.OriginalPath)`"",
                "-c:v", "libx264", "-crf", "18", "-preset", "medium",
                "-c:a", "aac", "-b:a", "192k",
                "-y", "`"$($Action.NewPath)`""
            )
        }
        "AudioConversion" {
            @("-i", "`"$($Action.OriginalPath)`"", "-vn", "-c:a", "libmp3lame", "-b:a", "320k", "-y", "`"$($Action.NewPath)`"")
        }
        default {
            $null
        }
    }
}

function Invoke-MediaConversion {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Action,
        [Parameter(Mandatory = $true)]
        [string]$FFmpegPath
    )

    $ffmpegArgs = Get-FFmpegArguments -Action $Action

    if ($null -eq $ffmpegArgs) {
        Write-Host "ERROR: Unknown action type '$($Action.Type)' for file '$($Action.OriginalPath)'" -ForegroundColor Red
        return $false
    }

    # Ensure destination directory exists before running ffmpeg
    $destDir = Split-Path -Path $Action.NewPath -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }

    $result = Invoke-FFmpegConversion -FFmpegExePath $FFmpegPath -Arguments $ffmpegArgs -OriginalFilePath $Action.OriginalPath

    if ($result.Success) {
        Write-Host "  Conversion completed." -ForegroundColor Green
        return $true
    } else {
        Write-Host "ERROR: Conversion failed. Exit $($result.ExitCode)" -ForegroundColor Red
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
        $destDir = Split-Path -Path $Action.NewPath -Parent
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir | Out-Null
        }
        Move-Item -LiteralPath $Action.OriginalPath -Destination $Action.NewPath
        Write-Host "  File renamed (no re-encode)." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "ERROR: Rename failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}
function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host "";
    Write-Host ("==== $Title ====") -ForegroundColor Magenta
}
function Write-Info {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("  " + $Message) -ForegroundColor Gray
}
function Write-Success {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("  " + $Message) -ForegroundColor Green
}
function Write-WarnMsg {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("  " + $Message) -ForegroundColor Yellow
}
function Write-ErrorMsg {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("  " + $Message) -ForegroundColor Red
}
function Get-ShortPath {
    param([Parameter(Mandatory)][string]$InputPath, [int]$Max = 100)
    if ([string]::IsNullOrEmpty($InputPath)) { return "" }
    if ($InputPath.Length -le $Max) { return $InputPath }
    $prefixLen = [Math]::Min([int][Math]::Round($Max / 2.5), $InputPath.Length)
    $suffixLen = [Math]::Min($Max - $prefixLen - 3, [Math]::Max(0, $InputPath.Length - $prefixLen))
    return ($InputPath.Substring(0, $prefixLen) + '...' + $InputPath.Substring($InputPath.Length - $suffixLen))
}
$ErrorActionPreference = "Continue"
$FFmpegPath = "C:\Users\Maxim\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe"

if (-not (Test-Path $FFmpegPath)) {
    Write-Host "FATAL: FFmpeg executable not found at the hardcoded path: $FFmpegPath" -ForegroundColor Red
    exit 1
}

$sourceFiles = if ($Recurse) {
    Get-ChildItem -Path $SourcePath -Recurse -File
} else {
    Get-ChildItem -Path $SourcePath -File
}

$actionsToProcess = @()

$mediaTypes = @{
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

Write-Section "Media Conversion - Plan"
Write-Info ("Source: " + $SourcePath)
Write-Info ("Destination: " + (if ([string]::IsNullOrEmpty($DestinationPath)) { "(in-place)" } else { $DestinationPath }))
Write-Info ("Recurse: " + ([bool]$Recurse))
Write-Info ("Rename non-standard: " + ([bool]$Rename))
Write-Info ("Force: " + ([bool]$Force))
Write-Host ""
Write-Host ("Scanning files in '" + $SourcePath + "'...") -ForegroundColor Cyan

foreach ($file in $sourceFiles) {
    $ext = $file.Extension.ToLower()
    if ($mediaTypes.ContainsKey($ext)) {
        $mediaInfo = $mediaTypes[$ext]
        $isCorrectFormat = ($ext -eq $mediaInfo.Target)
        $isStandardName = $file.Name -match '^(IMG|VID|AUD)_\d{8}_\d{6}_\d{3}(_\d+)?\..+'

        $outputDir = if ([string]::IsNullOrEmpty($DestinationPath)) { $file.DirectoryName } else {
            # Ensure the base of the source path is correctly identified and removed from the file's directory path
            $sourceFullPath = (Resolve-Path -LiteralPath $SourcePath).ProviderPath
            $fileDirFullPath = (Resolve-Path -LiteralPath $file.DirectoryName).ProviderPath
            $relPath = $fileDirFullPath.Substring($sourceFullPath.Length)
            $relPath = $relPath.TrimStart('\\')
            Join-Path $DestinationPath $relPath
        }
        # NOTE: Do not create directories during planning to avoid side effects if user cancels

        $newPath = Get-UniqueTimestampFileName -OriginalFile $file -TargetExtension $mediaInfo.Target -Prefix $mediaInfo.Prefix -OutputDirectory $outputDir

        $action = $null
        if (-not $isCorrectFormat) {
            $action = @{ Type = "$($mediaInfo.Type)Conversion"; OriginalPath = $file.FullName; NewPath = $newPath }
        } elseif ($Rename -and -not $isStandardName) {
            # For Rename, the new path should be in the same directory if no DestinationPath is given
            $renamePath = if ([string]::IsNullOrEmpty($DestinationPath)) {
                Join-Path $file.DirectoryName ($newPath | Split-Path -Leaf)
            } else {
                $newPath
            }
            $action = @{ Type = "Rename"; OriginalPath = $file.FullName; NewPath = $renamePath }
        }

        if ($null -ne $action) {
            $actionsToProcess += $action
        }
    }
}

if ($actionsToProcess.Count -eq 0) {
    Write-Host "No files to process." -ForegroundColor Green
    exit 0
}

if (!$Force) {
    Write-Section "Planned Actions ($($actionsToProcess.Count))"
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
        Write-Info ("From: " + $from)
        Write-Info ("  To: " + $to)
    }
    $response = Read-Host "Proceed with $($actionsToProcess.Count) actions? [y/N]"
    if (@('Y', 'YES') -notcontains ($response.Trim().ToUpper())) {
        Write-WarnMsg "Operation cancelled by user."
        exit 0
    }
}

$total = $actionsToProcess.Count
$current = 0
# Start stopwatch for elapsed time tracking
$sw = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($action in $actionsToProcess) {
    $current++
    Write-Host "--- ($current/$total) Executing: $($action.Type) on '$($action.OriginalPath)' ---" -ForegroundColor Cyan

    $success = $false
    if ($action.Type -eq "Rename") {
        $success = Invoke-FileRename -Action $action
        if ($success) { $stats.Renamed++ } else { $stats.Failed++; $failures += $action.OriginalPath }
    } else {
        $success = Invoke-MediaConversion -Action $action -FFmpegPath $FFmpegPath
        if ($success) {
            # Count conversion success
            $stats.Converted++
            # Attempt to remove original file with error handling
            try {
                Remove-Item -LiteralPath $action.OriginalPath -ErrorAction Stop
                Write-Host "  Removed original file." -ForegroundColor Green
                $stats.Deleted++
            } catch {
                Write-Host ("  ERROR: Failed to delete original: " + $_.Exception.Message) -ForegroundColor Yellow
                $stats.Failed++
                $failures += $action.OriginalPath
            }
        } else { $stats.Failed++; $failures += $action.OriginalPath }
    }
}
$sw.Stop()
Write-Section "Summary"
Write-Info ("Total actions: {0}" -f $stats.Total)
Write-Success ("Converted: {0}" -f $stats.Converted)
Write-Success ("Renamed:   {0}" -f $stats.Renamed)
Write-Success ("Deleted originals: {0}" -f $stats.Deleted)
if ($stats.Failed -gt 0) {
    Write-Host ("Failed: {0}" -f $stats.Failed) -ForegroundColor Red
    $idx = 0
    foreach ($f in $failures) { $idx++; Write-ErrorMsg (("[{0,3}] " -f $idx) + (Get-ShortPath -InputPath $f -Max 100)) }
} else {
    Write-Info "Failed: 0"
}
Write-Info ("Elapsed: {0:c}" -f $sw.Elapsed)
Write-Host "`n--- All operations completed. ---" -ForegroundColor Green