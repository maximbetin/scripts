# Requires: FFmpeg/FFprobe installed and on PATH (or pass -FFmpegPath). Build must include --enable-libzimg for zscale.

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Position = 0, HelpMessage = "Source directory to process. Defaults to current directory.")]
    [string]$SourcePath = ".",

    [Parameter(Position = 1, HelpMessage = "Optional: Destination directory. If omitted, outputs next to originals.")]
    [string]$DestinationPath,

    [Parameter(HelpMessage = "Path to ffmpeg executable (defaults to ffmpeg.exe in PATH).")]
    [string]$FFmpegPath = "ffmpeg.exe",

    [Parameter(HelpMessage = "JPEG quality (1=best, 31=worst).")]
    [int]$ImageQuality = 1,

    [Parameter(HelpMessage = "x264/x265 preset (e.g., medium, fast, slow).")]
    [string]$VideoPreset = "medium",

    [Parameter(HelpMessage = "Video CRF (lower=higher quality).")]
    [int]$VideoCRF = 18,

    [Parameter(HelpMessage = "Audio bitrate, e.g., 128k, 192k.")]
    [string]$AudioBitrate = "192k",

    [Parameter(HelpMessage = "If specified, originals are moved to a Processed_Originals folder.")]
    [switch]$MoveOriginals,

    [Parameter(HelpMessage = "Only rename files (no conversion).")]
    [switch]$RenameOnly,

    [Parameter(HelpMessage = "Log file path.")]
    [string]$LogFile,

    # New features
    [Parameter(HelpMessage = "Quality preset: Default keeps your flags; Low smaller; Medium balanced; High larger/better.")]
    [ValidateSet("Default", "Low", "Medium", "High")]
    [string]$QualityPreset = "Default",

    [Parameter(HelpMessage = "Optional upscale target width for images/videos (keeps aspect). 0 = none.")]
    [int]$UpscaleWidth = 0,

    [Parameter(HelpMessage = "Apply mild sharpening after scale/tonemap.")]
    [switch]$Sharpen,

    [Parameter(HelpMessage = "Keep HDR videos in HEVC 10-bit (copy/encode) instead of tonemapping to SDR/H.264.")]
    [switch]$KeepHDR,

    [Parameter(HelpMessage = "Force without interactive confirmation.")]
    [switch]$Force
)

# --- Globals ---
$script:LogBuffer = [System.Collections.ArrayList]::new()
$script:LogFileStream = $null

$imageExtensions = "*.jpg", "*.jpeg", "*.png", "*.webp", "*.heic", "*.heif"
$videoExtensions = "*.3gp", "*.mkv", "*.mp4", "*.avi", "*.webm"

# --- Helpers ---
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR", "DEBUG")][string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp][$Level] $Message"
    $script:LogBuffer.Add($logEntry) | Out-Null
    switch ($Level) {
        "ERROR" { Write-Error $Message }
        "WARNING" { Write-Warning $Message }
        "INFO" { Write-Host $Message }
        "DEBUG" { Write-Verbose $Message }
    }
    if ($script:LogFileStream) {
        try { $script:LogFileStream.WriteLine($logEntry) } catch {
            Write-Host "WARNING: Failed to write to log file: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Test-FFmpegAccessibility {
    param([Parameter(Mandatory)][string]$FFMpegExePath)
    Write-Log "Checking FFmpeg at '$FFMpegExePath'..." "DEBUG"
    try { & $FFMpegExePath -version | Out-Null; Write-Log "FFmpeg is accessible." "INFO"; return $true }
    catch { Write-Log "ERROR: FFmpeg not found or inaccessible. Ensure it's installed and on PATH, or pass -FFmpegPath." "ERROR"; return $false }
}

function Get-UniqueTimestampFileName {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$OriginalFile,
        [Parameter(Mandatory)][string]$TargetExtension,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    $timestamp = $OriginalFile.LastWriteTime.ToString("yyyyMMdd_HHmmss_fff")
    $baseName = "${Prefix}_$timestamp"
    $proposedName = "$baseName$TargetExtension"
    $newPath = Join-Path $OutputDirectory $proposedName
    $i = 1
    while (Test-Path $newPath) {
        $proposedName = "$baseName" + "_$i" + $TargetExtension
        $newPath = Join-Path $OutputDirectory $proposedName
        $i++
    }
    return $newPath
}

function Invoke-FFmpegConversion {
    param(
        [Parameter(Mandatory)][string]$FFMpegExePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$OriginalFilePath
    )
    Write-Log "  FFmpeg: `"$FFMpegExePath`" $($Arguments -join ' ')" "DEBUG"
    $tempErrorFile = [System.IO.Path]::GetTempFileName()
    $r = @{ Success = $false; FFMpegOutput = ""; ExitCode = -1 }
    try {
        $p = Start-Process -FilePath $FFMpegExePath -ArgumentList $Arguments -NoNewWindow -PassThru -Wait -RedirectStandardError $tempErrorFile
        $r.FFMpegOutput = (Get-Content $tempErrorFile | Out-String).Trim()
        $r.ExitCode = $p.ExitCode
        $r.Success = ($r.ExitCode -eq 0)
    } catch {
        Write-Log "ERROR: Start-Process failed for '$OriginalFilePath': $($_.Exception.Message)" "ERROR"
        $r.FFMpegOutput = "PowerShell Start-Process Error: $($_.Exception.Message)"
    } finally { Remove-Item $tempErrorFile -ErrorAction SilentlyContinue }
    return $r
}

function Read-OriginalFile {
    param(
        [Parameter(Mandatory)][string]$OriginalFilePath,
        [switch]$MoveOriginals,
        [Parameter(Mandatory)][string]$SourceBaseDir
    )
    if ($MoveOriginals) {
        $relativeDir = (Get-Item $OriginalFilePath).Directory.FullName.Substring($SourceBaseDir.Length).TrimStart("\", "/")
        $archiveRoot = Join-Path (Split-Path $SourceBaseDir) "Processed_Originals"
        $archiveDir = Join-Path $archiveRoot $relativeDir
        $archivePath = Join-Path $archiveDir (Split-Path $OriginalFilePath -Leaf)
        Write-Log "  Moving original to archive: '$OriginalFilePath' -> '$archivePath'" "INFO"
        try { New-Item -ItemType Directory -Path $archiveDir -ErrorAction SilentlyContinue | Out-Null; Move-Item -Path $OriginalFilePath -Destination $archivePath -Force -ErrorAction Stop; Write-Log "  Original moved." "INFO"; return $true }
        catch { Write-Log "WARNING: Failed to move original '$OriginalFilePath': $($_.Exception.Message)" "WARNING"; return $false }
    } else {
        Write-Log "  Removing original: $OriginalFilePath" "INFO"
        try { Remove-Item -Path $OriginalFilePath -Force -ErrorAction Stop; Write-Log "  Original removed." "INFO"; return $true }
        catch { Write-Log "WARNING: Failed to remove original '$OriginalFilePath': $($_.Exception.Message)" "WARNING"; return $false }
    }
}

function Confirm-Actions {
    param([Parameter(Mandatory)][array]$PendingActions)
    if ($PendingActions.Count -eq 0) { Write-Log "No files require conversion or renaming." "INFO"; return $false }
    Write-Host "`n--- Proposed Actions ---" -ForegroundColor Cyan
    Write-Host "The following files will be processed:"
    $currentLocation = (Get-Location).Path
    $i = 1
    foreach ($action in $PendingActions) {
        $actionType = switch ($action.Type) {
            "ImageConversion" { "Convert Image" }
            "VideoConversion" { "Convert Video" }
            "ImageRename" { "Rename Image" }
            "VideoRename" { "Rename Video" }
            default { "Unknown Action" }
        }
        $displayOriginalPath = $action.OriginalPath
        $displayNewPath = $action.NewPath
        if ($displayOriginalPath.StartsWith($currentLocation, [System.StringComparison]::OrdinalIgnoreCase)) { $displayOriginalPath = "." + $displayOriginalPath.Substring($currentLocation.Length) }
        if ($displayNewPath.StartsWith($currentLocation, [System.StringComparison]::OrdinalIgnoreCase)) { $displayNewPath = "." + $displayNewPath.Substring($currentLocation.Length) }
        $displayOriginalPath = $displayOriginalPath.TrimStart("\", "/")
        $displayNewPath = $displayNewPath.TrimStart("\", "/")
        Write-Host "  $i. ${actionType}: $displayOriginalPath -> $displayNewPath"
        $i++
    }
    if ($Force.IsPresent) { return $true }
    Write-Host "`nProceed? (Y/N)" -ForegroundColor Green
    $response = Read-Host
    return ($response -match '^(y|yes)$')
}

# --- New: ffprobe/HDR helpers ---
function Get-VideoStreamInfo {
    param([Parameter(Mandatory)][string]$FFMpegExePath, [Parameter(Mandatory)][string]$InputPath)
    $ffprobe = ($FFMpegExePath -replace 'ffmpeg(\.exe)?$', 'ffprobe$1')
    if (-not (Get-Command $ffprobe -ErrorAction SilentlyContinue)) { $ffprobe = "ffprobe.exe" }
    $ffprobeArgs = @("-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,pix_fmt,color_space,color_transfer,color_primaries", "-of", "json", "`"$InputPath`"")
    try { $json = & $ffprobe $ffprobeArgs 2>$null; if (-not $json) { return $null }; ($json | ConvertFrom-Json).streams[0] } catch { return $null }
}
function Test-IsHDR {
    param([object]$s)
    if (-not $s) { return $false }
    $pix10 = ($s.pix_fmt -match '10|12')
    $p2020 = ($s.color_primaries -match '2020')
    $trcHDR = ($s.color_transfer -match 'arib-std-b67|smpte2084|pq')
    return ($pix10 -and ($p2020 -or $trcHDR))
}

# --- New: Quality resolver ---
function Get-EffectiveQuality {
    param(
        [string]$QualityPreset, [int]$VideoCRF, [string]$VideoPreset, [string]$AudioBitrate, [int]$ImageQuality
    )
    $eff = [ordered]@{
        VideoCRF     = $VideoCRF
        VideoPreset  = $VideoPreset
        AudioBitrate = $AudioBitrate
        ImageQuality = $ImageQuality
    }
    switch ($QualityPreset) {
        "Low" { $eff.VideoCRF = 28; $eff.VideoPreset = "fast"; $eff.AudioBitrate = "128k"; $eff.ImageQuality = 8 }
        "Medium" { $eff.VideoCRF = 18; $eff.VideoPreset = "medium"; $eff.AudioBitrate = "192k"; $eff.ImageQuality = [Math]::Min($ImageQuality, 2) }
        "High" { $eff.VideoCRF = 14; $eff.VideoPreset = "slow"; $eff.AudioBitrate = "256k"; $eff.ImageQuality = 1 }
        default { }
    }
    return $eff
}

# --- Start ---
Write-Log "--- Script Start ---" "INFO"
Write-Log "Started at $(Get-Date)" "INFO"

$SourcePath = (Resolve-Path $SourcePath).Path
if (-not (Test-Path $SourcePath -PathType Container)) { Write-Log "ERROR: SourcePath '$SourcePath' is not a valid directory." "ERROR"; return }
Write-Log "Source Directory: '$SourcePath'" "INFO"

$AbsoluteDestinationRoot = $null
if ($DestinationPath) {
    try {
        if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -ErrorAction Stop | Out-Null }
        $DestinationPath = (Resolve-Path $DestinationPath -ErrorAction Stop).Path
        $AbsoluteDestinationRoot = $DestinationPath
        Write-Log "Destination Directory: '$AbsoluteDestinationRoot' (preserving structure)" "INFO"
    } catch {
        Write-Log "ERROR: Could not set up DestinationPath '$DestinationPath'. $($_.Exception.Message)" "ERROR"; return
    }
} else { Write-Log "No DestinationPath provided. Output next to originals." "INFO" }

if ($MoveOriginals) { Write-Log "Originals will be moved to 'Processed_Originals' next to source root." "INFO" }
else { Write-Log "Originals will be deleted after successful processing." "INFO" }

if ($LogFile) {
    try {
        $LogFileDir = Split-Path $LogFile
        if ($LogFileDir -and -not (Test-Path $LogFileDir -PathType Container)) { New-Item -ItemType Directory -Path $LogFileDir -ErrorAction Stop | Out-Null }
        $script:LogFileStream = [System.IO.StreamWriter]::new($LogFile, $true)
        Write-Log "Logging to: '$LogFile'" "INFO"
        foreach ($entry in $script:LogBuffer) { $script:LogFileStream.WriteLine($entry) }
        $script:LogBuffer.Clear()
    } catch { Write-Log "WARNING: Could not open log file '$LogFile': $($_.Exception.Message). Console-only logging." "WARNING"; $LogFile = $null }
}

if (-not (Test-FFmpegAccessibility -FFMpegExePath $FFmpegPath)) { return }

# Resolve quality now
$Q = Get-EffectiveQuality -QualityPreset $QualityPreset -VideoCRF $VideoCRF -VideoPreset $VideoPreset -AudioBitrate $AudioBitrate -ImageQuality $ImageQuality

# Discover
Write-Log "`n--- Discovering Files ---" "INFO"
Write-Log "Scanning '$SourcePath' recursively..." "INFO"
$pendingActions = @()
$allSourceFiles = Get-ChildItem -Path (Join-Path $SourcePath "*") -File -Include ($imageExtensions + $videoExtensions) -Recurse -ErrorAction SilentlyContinue

foreach ($file in $allSourceFiles) {
    Write-Log "  Examining: $($file.FullName)" "DEBUG"
    $ext = $file.Extension.ToLower()
    $targetOutputDirectory = if ($AbsoluteDestinationRoot) {
        $relativePath = $file.Directory.FullName.Substring($SourcePath.Length).TrimStart("\", "/")
        $dir = Join-Path $AbsoluteDestinationRoot $relativePath
        New-Item -ItemType Directory -Path $dir -ErrorAction SilentlyContinue | Out-Null
        $dir
    } else { $file.DirectoryName }

    if ($imageExtensions -contains "*$ext") {
        $newPath = Get-UniqueTimestampFileName -OriginalFile $file -TargetExtension ".jpg" -Prefix "IMG" -OutputDirectory $targetOutputDirectory
        $pathsSame = ($file.FullName.ToLower() -eq $newPath.ToLower())
        if ($ext -eq ".jpg" -and $pathsSame) {
            $pendingActions += @{ Type = "Skipped"; OriginalPath = $file.FullName; NewPath = $newPath; ActionType = "Image" }
            Write-Log "    Skipped (already JPG and correctly named)." "DEBUG"
        } elseif ($ext -eq ".jpg") {
            $pendingActions += @{ Type = "ImageRename"; OriginalPath = $file.FullName; NewPath = $newPath; ActionType = "Image" }
            Write-Log "    Plan: Rename Image." "DEBUG"
        } elseif (-not $RenameOnly) {
            $pendingActions += @{ Type = "ImageConversion"; OriginalPath = $file.FullName; NewPath = $newPath; ActionType = "Image" }
            Write-Log "    Plan: Convert Image to JPG." "DEBUG"
        } else { Write-Log "    Skipped (RenameOnly set but conversion needed)." "DEBUG" }
    } elseif ($videoExtensions -contains "*$ext") {
        $newPath = Get-UniqueTimestampFileName -OriginalFile $file -TargetExtension ".mp4" -Prefix "VID" -OutputDirectory $targetOutputDirectory
        $pathsSame = ($file.FullName.ToLower() -eq $newPath.ToLower())
        if ($ext -eq ".mp4" -and $pathsSame) {
            $pendingActions += @{ Type = "Skipped"; OriginalPath = $file.FullName; NewPath = $newPath; ActionType = "Video" }
            Write-Log "    Skipped (already MP4 and correctly named)." "DEBUG"
        } elseif ($ext -eq ".mp4") {
            $pendingActions += @{ Type = "VideoRename"; OriginalPath = $file.FullName; NewPath = $newPath; ActionType = "Video" }
            Write-Log "    Plan: Rename Video." "DEBUG"
        } elseif (-not $RenameOnly) {
            $pendingActions += @{ Type = "VideoConversion"; OriginalPath = $file.FullName; NewPath = $newPath; ActionType = "Video" }
            Write-Log "    Plan: Convert Video to MP4." "DEBUG"
        } else { Write-Log "    Skipped (RenameOnly set but conversion needed)." "DEBUG" }
    } else { Write-Log "    Skipping unknown type." "DEBUG" }
}

$actualPending = $pendingActions | Where-Object { $_.Type -ne "Skipped" }

# Confirm & Execute
if ($PSCmdlet.ShouldProcess("process media files recursively in '$SourcePath'", "Perform Conversion/Rename")) {
    if ($actualPending.Count -eq 0) { Write-Log "`nNo actionable items. Exiting." "INFO"; return }
    if (-not (Confirm-Actions -PendingActions $actualPending)) { Write-Log "`nCancelled by user." "INFO"; return }

    Write-Log "`n--- Executing Actions ---" "INFO"
    $convertedCount = 0; $renamedCount = 0; $skippedCount = 0; $errorCount = 0
    $total = $pendingActions.Count; $i = 0

    foreach ($action in $pendingActions) {
        $i++
        Write-Progress -Activity "Processing Media Files" -Status "($i/$total) $($action.OriginalPath | Split-Path -Leaf)" -PercentComplete ($i / $total * 100) -Id 1
        Write-Log "`n--- Processing File: $($action.OriginalPath | Split-Path -Leaf) ---" "INFO"
        Write-Log "  Planned Action: $($action.Type)" "INFO"
        Write-Log "  Original Path: $($action.OriginalPath)" "INFO"
        Write-Log "  New Path: $($action.NewPath)" "INFO"

        if ($action.Type -eq "Skipped") { Write-Log "  Skipped (no action needed)." "INFO"; $skippedCount++; continue }

        # Pure renames -> filesystem only
        if ($action.Type -eq "ImageRename") {
            try { Move-Item -LiteralPath $action.OriginalPath -Destination $action.NewPath -Force; Write-Log "  Image renamed (no re-encode)." "INFO"; $renamedCount++ }
            catch { Write-Log "ERROR: Image rename failed: $($_.Exception.Message)" "ERROR"; $errorCount++ }
            continue
        }
        if ($action.Type -eq "VideoRename") {
            try { Move-Item -LiteralPath $action.OriginalPath -Destination $action.NewPath -Force; Write-Log "  Video renamed (no re-encode)." "INFO"; $renamedCount++ }
            catch { Write-Log "ERROR: Video rename failed: $($_.Exception.Message)" "ERROR"; $errorCount++ }
            continue
        }

        if ($RenameOnly -and ($action.Type -match "Conversion")) {
            Write-Log "  Skipped: RenameOnly mode." "INFO"; $skippedCount++; continue
        }

        $conversionSuccessful = $false

        try {
            if ($action.ActionType -eq "Image" -and ($action.Type -eq "ImageConversion")) {
                $imgFilters = @()
                if ($UpscaleWidth -gt 0) { $imgFilters += "scale=w=$UpscaleWidth:h=-2:flags=lanczos" }
                if ($Sharpen) { $imgFilters += "unsharp=5:5:0.8:5:5:0.0" }
                $vfArgs = @(); if ($imgFilters.Count -gt 0) { $vfArgs = @("-vf", "`"$($imgFilters -join ',')`"") }

                $ffmpegArgs = @("-i", "`"$($action.OriginalPath)`"") + $vfArgs + @(
                    "-q:v", "$($Q.ImageQuality)",
                    "-y", "`"$($action.NewPath)`""
                )
                $res = Invoke-FFmpegConversion -FFMpegExePath $FFmpegPath -Arguments $ffmpegArgs -OriginalFilePath $action.OriginalPath
                $conversionSuccessful = $res.Success
                if ($conversionSuccessful) { Write-Log "  Image conversion completed." "INFO"; $convertedCount++ }
                else { Write-Log "ERROR: Image conversion failed. Exit $($res.ExitCode)" "ERROR"; Write-Log "FFmpeg Output: $($res.FFMpegOutput)" "ERROR"; $errorCount++ }
            } elseif ($action.ActionType -eq "Video" -and ($action.Type -eq "VideoConversion")) {
                $vinfo = Get-VideoStreamInfo -FFMpegExePath $FFmpegPath -InputPath $action.OriginalPath
                $isHDR = Test-IsHDR -s $vinfo

                # Optional re-mux if keeping HDR and input is already MP4 HEVC
                $extIn = [IO.Path]::GetExtension($action.OriginalPath).ToLowerInvariant()
                if ($extIn -eq ".mp4" -and $isHDR -and $KeepHDR) {
                    $ffmpegArgs = @("-i", "`"$($action.OriginalPath)`"", "-c", "copy", "-y", "`"$($action.NewPath)`"")
                } elseif ($isHDR -and $KeepHDR) {
                    # Keep HDR: HEVC 10-bit
                    $extra = @()
                    if ($UpscaleWidth -gt 0) { $extra += "scale=w=$UpscaleWidth:h=-2:flags=lanczos" }
                    if ($Sharpen) { $extra += "unsharp=5:5:0.8:5:5:0.0" }
                    $ffmpegArgs = @("-i", "`"$($action.OriginalPath)`"")
                    if ($extra.Count -gt 0) { $ffmpegArgs += @("-vf", "`"$($extra -join ',')`"") }
                    $ffmpegArgs += @(
                        "-c:v", "libx265",
                        "-pix_fmt", "yuv420p10le",
                        "-tag:v", "hvc1",
                        "-crf", "$($Q.VideoCRF)",
                        "-preset", "$($Q.VideoPreset)",
                        "-c:a", "copy",
                        "-y", "`"$($action.NewPath)`""
                    )
                } elseif ($isHDR) {
                    # HDR -> SDR BT.709 for x264
                    $vf = "zscale=transferin=arib-std-b67:primariesin=bt2020:matrixin=bt2020nc," +
                    "zscale=transfer=linear,tonemap=hable," +
                    "zscale=transfer=bt709:primaries=bt709:matrix=bt709,format=yuv420p"
                    if ($vinfo.color_transfer -match 'smpte2084|pq') { $vf = $vf -replace 'arib-std-b67', 'smpte2084' }
                    $extras = @()
                    if ($UpscaleWidth -gt 0) { $extras += "scale=w=$UpscaleWidth:h=-2:flags=lanczos" }
                    if ($Sharpen) { $extras += "unsharp=5:5:0.8:5:5:0.0" }
                    if ($extras.Count -gt 0) { $vf = "$vf," + ($extras -join ',') }

                    $ffmpegArgs = @(
                        "-i", "`"$($action.OriginalPath)`"",
                        "-vf", "`"$vf`"",
                        "-c:v", "libx264", "-crf", "$($Q.VideoCRF)", "-preset", "$($Q.VideoPreset)",
                        "-pix_fmt", "yuv420p",
                        "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
                        "-c:a", "aac", "-b:a", "$($Q.AudioBitrate)",
                        "-y", "`"$($action.NewPath)`""
                    )
                } else {
                    # SDR -> plain H.264
                    $extra = @()
                    if ($UpscaleWidth -gt 0) { $extra += "scale=w=$UpscaleWidth:h=-2:flags=lanczos" }
                    if ($Sharpen) { $extra += "unsharp=5:5:0.8:5:5:0.0" }
                    $ffmpegArgs = @("-i", "`"$($action.OriginalPath)`"")
                    if ($extra.Count -gt 0) { $ffmpegArgs += @("-vf", "`"$($extra -join ',')`"") }
                    $ffmpegArgs += @(
                        "-c:v", "libx264", "-crf", "$($Q.VideoCRF)", "-preset", "$($Q.VideoPreset)",
                        "-c:a", "aac", "-b:a", "$($Q.AudioBitrate)",
                        "-y", "`"$($action.NewPath)`""
                    )
                }

                $res = Invoke-FFmpegConversion -FFMpegExePath $FFmpegPath -Arguments $ffmpegArgs -OriginalFilePath $action.OriginalPath
                $conversionSuccessful = $res.Success
                if ($conversionSuccessful) { Write-Log "  Video conversion completed." "INFO"; $convertedCount++ }
                else { Write-Log "ERROR: Video conversion failed. Exit $($res.ExitCode)" "ERROR"; Write-Log "FFmpeg Output: $($res.FFMpegOutput)" "ERROR"; $errorCount++ }
            }
        } catch {
            Write-Log "CRITICAL ERROR during '$($action.OriginalPath)': $($_.Exception.Message)" "ERROR"; $errorCount++; $conversionSuccessful = $false
        }

        # Manage original only after successful conversion and when path differs
        if ($conversionSuccessful -and ($action.OriginalPath.ToLower() -ne $action.NewPath.ToLower())) {
            Read-OriginalFile -OriginalFilePath $action.OriginalPath -MoveOriginals:$MoveOriginals -SourceBaseDir $SourcePath | Out-Null
        } elseif ($conversionSuccessful) {
            Write-Log "  Original equals target; nothing to remove/move." "INFO"
        }
    }

    Write-Progress -Activity "Processing Media Files" -Completed -Status "All files processed." -Id 1
}

# Summary & cleanup
Write-Log "`n--- Script Execution Summary ---" "INFO"
Write-Log "Total Files Examined: $($pendingActions.Count)" "INFO"
Write-Log "Files Converted: $convertedCount" "INFO"
Write-Log "Files Renamed: $renamedCount" "INFO"
Write-Log "Files Skipped: $skippedCount" "INFO"
Write-Log "Files with Errors: $errorCount" "INFO"
Write-Log "------------------------------" "INFO"
Write-Log "Finished at $(Get-Date)." "INFO"

if ($script:LogFileStream) {
    try { $script:LogFileStream.Close(); $script:LogFileStream.Dispose(); $script:LogFileStream = $null; Write-Host "Log saved to '$LogFile'." -ForegroundColor Green }
    catch { Write-Host "WARNING: Error closing log file: $($_.Exception.Message)" -ForegroundColor Yellow }
}
