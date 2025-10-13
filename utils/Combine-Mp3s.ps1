# Combine-Mp3.ps1
# Combines multiple MP3 files into a single file and optionally embeds cover art.
# If Art.jpg or Art.png exists in the input folder, it will be embedded as album art.
# Requires ffmpeg to be installed and available in PATH for cover art embedding.
# Usage: .\Combine-Mp3.ps1 -InputFolder "C:\Music" -OutputFile "C:\Combined\output.mp3"

param (
    [Parameter(Mandatory = $true)]
    [string]$InputFolder,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile
)

# Validate input folder
if (-not (Test-Path $InputFolder)) {
    Write-Error "Input folder not found: $InputFolder"
    exit 1
}

# Get all MP3 files sorted alphabetically
$mp3Files = Get-ChildItem -Path $InputFolder -Filter *.mp3 | Sort-Object Name
if ($mp3Files.Count -eq 0) {
    Write-Error "No MP3 files found in $InputFolder"
    exit 1
}

# Prepare output directory
$outDir = Split-Path $OutputFile -Parent
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}

# Combine using binary stream (for pure concatenation)
Write-Host "Combining $($mp3Files.Count) files into $OutputFile..."

$fsOut = [System.IO.File]::Create($OutputFile)
foreach ($file in $mp3Files) {
    Write-Host "Adding: $($file.Name)"
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $fsOut.Write($bytes, 0, $bytes.Length)
}
$fsOut.Close()

# Check for cover art in the input folder
$coverArt = $null
$artJpg = Join-Path $InputFolder "Art.jpg"
$artPng = Join-Path $InputFolder "Art.png"

if (Test-Path $artJpg) {
    $coverArt = $artJpg
    Write-Host "Found cover art: Art.jpg"
} elseif (Test-Path $artPng) {
    $coverArt = $artPng
    Write-Host "Found cover art: Art.png"
}

# Add cover art if found
if ($coverArt) {
    Write-Host "Embedding cover art into MP3..."
    $tempFile = "$OutputFile.temp.mp3"

    # Use ffmpeg to add cover art and metadata
    $ffmpegArgs = @(
        "-i", $OutputFile,
        "-i", $coverArt,
        "-map", "0:a",
        "-map", "1:0",
        "-c", "copy",
        "-id3v2_version", "3",
        "-metadata", "artist=Maxim",
        "-metadata", "album_artist=Maxim",
        "-metadata", "composer=Maxim",
        "-metadata", "performer=Maxim",
        "-metadata:s:v", "title=Album cover",
        "-metadata:s:v", "comment=Cover (front)",
        "-y",
        $tempFile
    )

    $process = Start-Process -FilePath "ffmpeg" -ArgumentList $ffmpegArgs -NoNewWindow -Wait -PassThru

    if ($process.ExitCode -eq 0) {
        # Replace original with the one that has cover art
        Remove-Item $OutputFile
        Move-Item $tempFile $OutputFile
        Write-Host "Cover art embedded successfully."
    } else {
        Write-Warning "Failed to embed cover art. ffmpeg returned exit code $($process.ExitCode)"
        if (Test-Path $tempFile) {
            Remove-Item $tempFile
        }
    }
}

Write-Host "Done. Combined file created at: $OutputFile"
