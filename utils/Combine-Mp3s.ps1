<#
.SYNOPSIS
    Concatenates multiple MP3 files into a single MP3 file in order by name.

.DESCRIPTION
    This script combines MP3 files from a specified directory into a single output file.
    Files are sorted naturally (1, 2, 3... 10, 11, etc.) before concatenation.
    Requires FFmpeg to be installed and available in PATH.

.PARAMETER InputPath
    Path to the directory containing MP3 files. Defaults to current directory.

.PARAMETER OutputFile
    Name of the output MP3 file. Defaults to "combined.mp3".

.PARAMETER Pattern
    File pattern to match. Defaults to "*.mp3".

.EXAMPLE
    .\Combine-Mp3s.ps1
    Combines all MP3 files in the current directory into "combined.mp3"

.EXAMPLE
    .\Combine-Mp3s.ps1 -InputPath "C:\Podcasts" -OutputFile "podcast-series.mp3"
    Combines all MP3 files from C:\Podcasts into "podcast-series.mp3"

.EXAMPLE
    .\Combine-Mp3s.ps1 -Pattern "episode*.mp3"
    Combines only MP3 files matching "episode*.mp3" pattern
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$InputPath = ".",

    [Parameter()]
    [string]$OutputFile = "combined.mp3",

    [Parameter()]
    [string]$Pattern = "*.mp3"
)

# Check if FFmpeg is available
try {
    $null = Get-Command ffmpeg -ErrorAction Stop
} catch {
    Write-Error "FFmpeg is not installed or not in PATH. Please install FFmpeg first."
    Write-Host "Download from: https://ffmpeg.org/download.html"
    exit 1
}

# Resolve input path
$InputPath = Resolve-Path $InputPath -ErrorAction Stop

# Get all MP3 files matching the pattern
$mp3Files = Get-ChildItem -Path $InputPath -Filter $Pattern -File |
Where-Object { $_.Name -ne $OutputFile }

if ($mp3Files.Count -eq 0) {
    Write-Error "No MP3 files found matching pattern '$Pattern' in '$InputPath'"
    exit 1
}

# Sort files naturally (handles numeric sorting correctly: 1, 2, 3... 10, 11, etc.)
$sortedFiles = $mp3Files | Sort-Object {
    [regex]::Replace($_.Name, '\d+', { $args[0].Value.PadLeft(20, '0') })
}

Write-Host "Found $($sortedFiles.Count) MP3 files to combine:" -ForegroundColor Green
$sortedFiles | ForEach-Object { Write-Host "  - $($_.Name)" }

# Create temporary file list for FFmpeg concat demuxer
$tempListFile = Join-Path $env:TEMP "ffmpeg_concat_$(Get-Random).txt"

try {
    # Write file list in FFmpeg concat format
    $sortedFiles | ForEach-Object {
        $escapedPath = $_.FullName -replace "'", "'\\''"
        "file '$escapedPath'" | Out-File -FilePath $tempListFile -Encoding utf8 -Append
    }

    # Build output path
    $outputPath = if ([System.IO.Path]::IsPathRooted($OutputFile)) {
        $OutputFile
    } else {
        Join-Path $InputPath $OutputFile
    }

    # Check if output file already exists
    if (Test-Path $outputPath) {
        $response = Read-Host "Output file '$outputPath' already exists. Overwrite? (y/n)"
        if ($response -ne 'y') {
            Write-Host "Operation cancelled."
            exit 0
        }
        Remove-Item $outputPath -Force
    }

    Write-Host "`nCombining MP3 files..." -ForegroundColor Cyan

    # Use FFmpeg concat demuxer to combine files
    $ffmpegArgs = @(
        '-f', 'concat',
        '-safe', '0',
        '-i', $tempListFile,
        '-c:a', 'libmp3lame',
        '-b:a', '128k',
        $outputPath
    )

    $process = Start-Process -FilePath "ffmpeg" -ArgumentList $ffmpegArgs -NoNewWindow -Wait -PassThru

    if ($process.ExitCode -eq 0) {
        $outputInfo = Get-Item $outputPath
        Write-Host "`nSuccess! Combined MP3 created:" -ForegroundColor Green
        Write-Host "  File: $($outputInfo.FullName)" -ForegroundColor Green
        Write-Host "  Size: $([math]::Round($outputInfo.Length / 1MB, 2)) MB" -ForegroundColor Green
    } else {
        Write-Error "FFmpeg failed with exit code $($process.ExitCode)"
        exit 1
    }

} finally {
    # Clean up temporary file
    if (Test-Path $tempListFile) {
        Remove-Item $tempListFile -Force
    }
}