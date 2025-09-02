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

    [Parameter(HelpMessage = "Enable renaming of files to timestamp format (disabled by default).")]
    [switch]$EnableRename,

    [Parameter(HelpMessage = "Log file path.")]
    [string]$LogFile,

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

# --- Global Variables ---
$script:logBuffer = [System.Collections.ArrayList]::new()
$script:logFileStream = $null

$imageExtensions = "*.jpg", "*.jpeg", "*.png", "*.webp", "*.heic", "*.heif"
$videoExtensions = "*.3gp", "*.mkv", "*.mp4", "*.avi", "*.webm"
$audioExtensions = "*.m4a", "*.wav", "*.flac", "*.aac", "*.ogg", "*.wma", "*.mp3"

# --- Helper Functions ---
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR", "DEBUG")][string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp][$Level] $Message"
    $script:logBuffer.Add($logEntry) | Out-Null
    
    switch ($Level) {
        "ERROR" { Write-Error $Message }
        "WARNING" { Write-Warning $Message }
        "INFO" { Write-Host $Message }
        "DEBUG" { Write-Verbose $Message }
    }
    
    if ($script:logFileStream) {
        try {
            $script:logFileStream.WriteLine($logEntry)
        } catch {
            Write-Host "WARNING: Failed to write to log file: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Test-FFmpegAccessibility {
    param([Parameter(Mandatory)][string]$FFmpegExePath)
    
    Write-Log "Checking FFmpeg at '$FFmpegExePath'..." "DEBUG"
    try {
        & $FFmpegExePath -version | Out-Null
        Write-Log "FFmpeg is accessible." "INFO"
        return $true
    } catch {
        Write-Log "ERROR: FFmpeg not found or inaccessible. Ensure it's installed and on PATH, or pass -FFmpegPath." "ERROR"
        return $false
    }
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
    
    $counter = 1
    while (Test-Path $newPath) {
        $proposedName = "$baseName" + "_$counter" + $TargetExtension
        $newPath = Join-Path $OutputDirectory $proposedName
        $counter++
    }
    
    return $newPath
}

function Invoke-FFmpegConversion {
    param(
        [Parameter(Mandatory)][string]$FFmpegExePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$OriginalFilePath
    )
    
    Write-Log "  FFmpeg: `"$FFmpegExePath`" $($Arguments -join ' ')" "DEBUG"
    $tempErrorFile = [System.IO.Path]::GetTempFileName()
    $result = @{ Success = $false; FFmpegOutput = ""; ExitCode = -1 }
    
    try {
        $process = Start-Process -FilePath $FFmpegExePath -ArgumentList $Arguments -NoNewWindow -PassThru -Wait -RedirectStandardError $tempErrorFile
        $result.FFmpegOutput = (Get-Content $tempErrorFile | Out-String).Trim()
        $result.ExitCode = $process.ExitCode
        $result.Success = ($result.ExitCode -eq 0)
    } catch {
        Write-Log "ERROR: Start-Process failed for '$OriginalFilePath': $($_.Exception.Message)" "ERROR"
        $result.FFmpegOutput = "PowerShell Start-Process Error: $($_.Exception.Message)"
    } finally {
        Remove-Item $tempErrorFile -ErrorAction SilentlyContinue
    }
    
    return $result
}

function Remove-OriginalFile {
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
        try {
            New-Item -ItemType Directory -Path $archiveDir -ErrorAction SilentlyContinue | Out-Null
            Move-Item -Path $OriginalFilePath -Destination $archivePath -Force -ErrorAction Stop
            Write-Log "  Original moved." "INFO"
            return $true
        } catch {
            Write-Log "WARNING: Failed to move original '$OriginalFilePath': $($_.Exception.Message)" "WARNING"
            return $false
        }
    } else {
        Write-Log "  Removing original: $OriginalFilePath" "INFO"
        try {
            Remove-Item -Path $OriginalFilePath -Force -ErrorAction Stop
            Write-Log "  Original removed." "INFO"
            return $true
        } catch {
            Write-Log "WARNING: Failed to remove original '$OriginalFilePath': $($_.Exception.Message)" "WARNING"
            return $false
        }
    }
}

function Get-MediaFileAction {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [Parameter(Mandatory)][string[]]$Extensions,
        [Parameter(Mandatory)][string]$TargetExtension,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$ActionType,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [switch]$EnableRename,
        [switch]$RenameOnly
    )
    
    $extension = $File.Extension.ToLower()
    $newPath = Get-UniqueTimestampFileName -OriginalFile $File -TargetExtension $TargetExtension -Prefix $Prefix -OutputDirectory $OutputDirectory
    $pathsSame = ($File.FullName.ToLower() -eq $newPath.ToLower())
    
    if ($extension -eq $TargetExtension -and $pathsSame) {
        Write-Log "    Skipped (already $($TargetExtension.ToUpper()) and correctly named)." "DEBUG"
        return @{ Type = "Skipped"; OriginalPath = $File.FullName; NewPath = $newPath; ActionType = $ActionType }
    } elseif ($extension -eq $TargetExtension -and $EnableRename) {
        Write-Log "    Plan: Rename $ActionType." "DEBUG"
        return @{ Type = "${ActionType}Rename"; OriginalPath = $File.FullName; NewPath = $newPath; ActionType = $ActionType }
    } elseif ($extension -eq $TargetExtension -and -not $EnableRename) {
        Write-Log "    Skipped ($($TargetExtension.ToUpper()) but renaming disabled)." "DEBUG"
        return @{ Type = "Skipped"; OriginalPath = $File.FullName; NewPath = $File.FullName; ActionType = $ActionType }
    } elseif (-not $RenameOnly) {
        Write-Log "    Plan: Convert $ActionType to $($TargetExtension.ToUpper())." "DEBUG"
        return @{ Type = "${ActionType}Conversion"; OriginalPath = $File.FullName; NewPath = $newPath; ActionType = $ActionType }
    } else {
        Write-Log "    Skipped (RenameOnly set but conversion needed)." "DEBUG"
        return $null
    }
}

function Confirm-Actions {
    param([Parameter(Mandatory)][array]$PendingActions)
    
    if ($PendingActions.Count -eq 0) {
        Write-Log "No files require conversion or renaming." "INFO"
        return $false
    }
    
    Write-Host "`n--- Proposed Actions ---" -ForegroundColor Cyan
    Write-Host "The following files will be processed:"
    $currentLocation = (Get-Location).Path
    
    for ($i = 0; $i -lt $PendingActions.Count; $i++) {
        $action = $PendingActions[$i]
        $actionType = switch ($action.Type) {
            "ImageConversion" { "Convert Image" }
            "VideoConversion" { "Convert Video" }
            "AudioConversion" { "Convert Audio" }
            "ImageRename" { "Rename Image" }
            "VideoRename" { "Rename Video" }
            "AudioRename" { "Rename Audio" }
            default { "Unknown Action" }
        }
        
        $displayOriginalPath = $action.OriginalPath
        $displayNewPath = $action.NewPath
        
        if ($displayOriginalPath.StartsWith($currentLocation, [System.StringComparison]::OrdinalIgnoreCase)) {
            $displayOriginalPath = "." + $displayOriginalPath.Substring($currentLocation.Length)
        }
        if ($displayNewPath.StartsWith($currentLocation, [System.StringComparison]::OrdinalIgnoreCase)) {
            $displayNewPath = "." + $displayNewPath.Substring($currentLocation.Length)
        }
        
        $displayOriginalPath = $displayOriginalPath.TrimStart("\", "/")
        $displayNewPath = $displayNewPath.TrimStart("\", "/")
        
        Write-Host "  $($i + 1). ${actionType}: $displayOriginalPath -> $displayNewPath"
    }
    
    if ($Force.IsPresent) {
        return $true
    }
    
    Write-Host "`nProceed? (Y/N)" -ForegroundColor Green
    $response = Read-Host
    return ($response -match '^(y|yes)$')
}

function Get-VideoStreamInfo {
    param(
        [Parameter(Mandatory)][string]$FFmpegExePath,
        [Parameter(Mandatory)][string]$InputPath
    )
    
    $ffprobe = ($FFmpegExePath -replace 'ffmpeg(\.exe)?$', 'ffprobe$1')
    if (-not (Get-Command $ffprobe -ErrorAction SilentlyContinue)) {
        $ffprobe = "ffprobe.exe"
    }
    
    $ffprobeArgs = @(
        "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=codec_name,pix_fmt,color_space,color_transfer,color_primaries",
        "-of", "json",
        "`"$InputPath`""
    )
    
    try {
        $json = & $ffprobe $ffprobeArgs 2>$null
        if (-not $json) {
            return $null
        }
        return ($json | ConvertFrom-Json).streams[0]
    } catch {
        return $null
    }
}

function Test-IsHDR {
    param([object]$StreamInfo)
    
    if (-not $StreamInfo) {
        return $false
    }
    
    $pix10Bit = ($StreamInfo.pix_fmt -match '10|12')
    $bt2020Primaries = ($StreamInfo.color_primaries -match '2020')
    $hdrTransfer = ($StreamInfo.color_transfer -match 'arib-std-b67|smpte2084|pq')
    
    return ($pix10Bit -and ($bt2020Primaries -or $hdrTransfer))
}

function Get-VideoFilters {
    param(
        [int]$UpscaleWidth,
        [switch]$Sharpen
    )
    
    $filters = @()
    
    if ($UpscaleWidth -gt 0) {
        $filters += "scale=w=$UpscaleWidth:h=-2:flags=lanczos"
    }
    
    if ($Sharpen) {
        $filters += "unsharp=5:5:0.8:5:5:0.0"
    }
    
    return $filters
}

function Get-HDRTonemapFilter {
    param(
        [object]$VideoInfo,
        [string[]]$AdditionalFilters
    )
    
    $baseFilter = "zscale=transferin=arib-std-b67:primariesin=bt2020:matrixin=bt2020nc," +
    "zscale=transfer=linear,tonemap=hable," +
    "zscale=transfer=bt709:primaries=bt709:matrix=bt709,format=yuv420p"
    
    if ($VideoInfo.color_transfer -match 'smpte2084|pq') {
        $baseFilter = $baseFilter -replace 'arib-std-b67', 'smpte2084'
    }
    
    if ($AdditionalFilters.Count -gt 0) {
        $baseFilter = "$baseFilter," + ($AdditionalFilters -join ',')
    }
    
    return $baseFilter
}

function Get-EffectiveQuality {
    param(
        [string]$QualityPreset,
        [int]$VideoCRF,
        [string]$VideoPreset,
        [string]$AudioBitrate,
        [int]$ImageQuality
    )
    
    $effectiveQuality = [ordered]@{
        VideoCRF     = $VideoCRF
        VideoPreset  = $VideoPreset
        AudioBitrate = $AudioBitrate
        ImageQuality = $ImageQuality
    }
    
    switch ($QualityPreset) {
        "Low" {
            $effectiveQuality.VideoCRF = 28
            $effectiveQuality.VideoPreset = "fast"
            $effectiveQuality.AudioBitrate = "128k"
            $effectiveQuality.ImageQuality = 8
        }
        "Medium" {
            $effectiveQuality.VideoCRF = 18
            $effectiveQuality.VideoPreset = "medium"
            $effectiveQuality.AudioBitrate = "192k"
            $effectiveQuality.ImageQuality = [Math]::Min($ImageQuality, 2)
        }
        "High" {
            $effectiveQuality.VideoCRF = 14
            $effectiveQuality.VideoPreset = "slow"
            $effectiveQuality.AudioBitrate = "256k"
            $effectiveQuality.ImageQuality = 1
        }
    }
    
    return $effectiveQuality
}

function Invoke-MediaConversion {
    param(
        [Parameter(Mandatory)][hashtable]$Action,
        [Parameter(Mandatory)][hashtable]$QualitySettings,
        [Parameter(Mandatory)][string]$FFmpegPath,
        [int]$UpscaleWidth,
        [switch]$Sharpen,
        [switch]$KeepHDR
    )
    
    $conversionSuccessful = $false
    
    try {
        switch ($Action.ActionType) {
            "Image" {
                if ($Action.Type -eq "ImageConversion") {
                    $imageFilters = Get-VideoFilters -UpscaleWidth $UpscaleWidth -Sharpen:$Sharpen
                    $videoFilterArgs = @()
                    
                    if ($imageFilters.Count -gt 0) {
                        $videoFilterArgs = @("-vf", "`"$($imageFilters -join ',')`"")
                    }
                    
                    $ffmpegArgs = @("-i", "`"$($Action.OriginalPath)`"") + $videoFilterArgs + @(
                        "-q:v", "$($QualitySettings.ImageQuality)",
                        "-y", "`"$($Action.NewPath)`""
                    )
                    
                    $result = Invoke-FFmpegConversion -FFmpegExePath $FFmpegPath -Arguments $ffmpegArgs -OriginalFilePath $Action.OriginalPath
                    $conversionSuccessful = $result.Success
                    
                    if ($conversionSuccessful) {
                        Write-Log "  Image conversion completed." "INFO"
                    } else {
                        Write-Log "ERROR: Image conversion failed. Exit $($result.ExitCode)" "ERROR"
                        Write-Log "FFmpeg Output: $($result.FFmpegOutput)" "ERROR"
                    }
                }
            }
            
            "Video" {
                if ($Action.Type -eq "VideoConversion") {
                    $videoInfo = Get-VideoStreamInfo -FFmpegExePath $FFmpegPath -InputPath $Action.OriginalPath
                    $isHDR = Test-IsHDR -StreamInfo $videoInfo
                    $inputExtension = [IO.Path]::GetExtension($Action.OriginalPath).ToLowerInvariant()
                    
                    # Handle different video conversion scenarios
                    if ($inputExtension -eq ".mp4" -and $isHDR -and $KeepHDR) {
                        # Re-mux existing MP4 HEVC
                        $ffmpegArgs = @("-i", "`"$($Action.OriginalPath)`"", "-c", "copy", "-y", "`"$($Action.NewPath)`"")
                    } elseif ($isHDR -and $KeepHDR) {
                        # Keep HDR: HEVC 10-bit
                        $videoFilters = Get-VideoFilters -UpscaleWidth $UpscaleWidth -Sharpen:$Sharpen
                        $ffmpegArgs = @("-i", "`"$($Action.OriginalPath)`"")
                        
                        if ($videoFilters.Count -gt 0) {
                            $ffmpegArgs += @("-vf", "`"$($videoFilters -join ',')`"")
                        }
                        
                        $ffmpegArgs += @(
                            "-c:v", "libx265",
                            "-pix_fmt", "yuv420p10le",
                            "-tag:v", "hvc1",
                            "-crf", "$($QualitySettings.VideoCRF)",
                            "-preset", "$($QualitySettings.VideoPreset)",
                            "-c:a", "copy",
                            "-y", "`"$($Action.NewPath)`""
                        )
                    } elseif ($isHDR) {
                        # HDR -> SDR conversion
                        $videoFilters = Get-VideoFilters -UpscaleWidth $UpscaleWidth -Sharpen:$Sharpen
                        $tonemapFilter = Get-HDRTonemapFilter -VideoInfo $videoInfo -AdditionalFilters $videoFilters
                        
                        $ffmpegArgs = @(
                            "-i", "`"$($Action.OriginalPath)`"",
                            "-vf", "`"$tonemapFilter`"",
                            "-c:v", "libx264",
                            "-crf", "$($QualitySettings.VideoCRF)",
                            "-preset", "$($QualitySettings.VideoPreset)",
                            "-pix_fmt", "yuv420p",
                            "-colorspace", "bt709",
                            "-color_primaries", "bt709",
                            "-color_trc", "bt709",
                            "-c:a", "aac",
                            "-b:a", "$($QualitySettings.AudioBitrate)",
                            "-y", "`"$($Action.NewPath)`""
                        )
                    } else {
                        # Standard SDR conversion
                        $videoFilters = Get-VideoFilters -UpscaleWidth $UpscaleWidth -Sharpen:$Sharpen
                        $ffmpegArgs = @("-i", "`"$($Action.OriginalPath)`"")
                        
                        if ($videoFilters.Count -gt 0) {
                            $ffmpegArgs += @("-vf", "`"$($videoFilters -join ',')`"")
                        }
                        
                        $ffmpegArgs += @(
                            "-c:v", "libx264",
                            "-crf", "$($QualitySettings.VideoCRF)",
                            "-preset", "$($QualitySettings.VideoPreset)",
                            "-c:a", "aac",
                            "-b:a", "$($QualitySettings.AudioBitrate)",
                            "-y", "`"$($Action.NewPath)`""
                        )
                    }
                    
                    $result = Invoke-FFmpegConversion -FFmpegExePath $FFmpegPath -Arguments $ffmpegArgs -OriginalFilePath $Action.OriginalPath
                    $conversionSuccessful = $result.Success
                    
                    if ($conversionSuccessful) {
                        Write-Log "  Video conversion completed." "INFO"
                    } else {
                        Write-Log "ERROR: Video conversion failed. Exit $($result.ExitCode)" "ERROR"
                        Write-Log "FFmpeg Output: $($result.FFmpegOutput)" "ERROR"
                    }
                }
            }
            
            "Audio" {
                if ($Action.Type -eq "AudioConversion") {
                    $ffmpegArgs = @(
                        "-i", "`"$($Action.OriginalPath)`"",
                        "-c:a", "libmp3lame",
                        "-b:a", "$($QualitySettings.AudioBitrate)",
                        "-y", "`"$($Action.NewPath)`""
                    )
                    
                    $result = Invoke-FFmpegConversion -FFmpegExePath $FFmpegPath -Arguments $ffmpegArgs -OriginalFilePath $Action.OriginalPath
                    $conversionSuccessful = $result.Success
                    
                    if ($conversionSuccessful) {
                        Write-Log "  Audio conversion completed." "INFO"
                    } else {
                        Write-Log "ERROR: Audio conversion failed. Exit $($result.ExitCode)" "ERROR"
                        Write-Log "FFmpeg Output: $($result.FFmpegOutput)" "ERROR"
                    }
                }
            }
        }
    } catch {
        Write-Log "CRITICAL ERROR during '$($Action.OriginalPath)': $($_.Exception.Message)" "ERROR"
        $conversionSuccessful = $false
    }
    
    return $conversionSuccessful
}

function Invoke-FileRename {
    param(
        [Parameter(Mandatory)][hashtable]$Action
    )
    
    try {
        Move-Item -LiteralPath $Action.OriginalPath -Destination $Action.NewPath -Force
        Write-Log "  $($Action.ActionType) renamed (no re-encode)." "INFO"
        return $true
    } catch {
        Write-Log "ERROR: $($Action.ActionType) rename failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# --- Main Script Execution ---
Write-Log "--- Script Start ---" "INFO"
Write-Log "Started at $(Get-Date)" "INFO"

# Validate and resolve source path
$SourcePath = (Resolve-Path $SourcePath).Path
if (-not (Test-Path $SourcePath -PathType Container)) {
    Write-Log "ERROR: SourcePath '$SourcePath' is not a valid directory." "ERROR"
    return
}
Write-Log "Source Directory: '$SourcePath'" "INFO"

# Setup destination path
$absoluteDestinationRoot = $null
if ($DestinationPath) {
    try {
        if (-not (Test-Path $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -ErrorAction Stop | Out-Null
        }
        $DestinationPath = (Resolve-Path $DestinationPath -ErrorAction Stop).Path
        $absoluteDestinationRoot = $DestinationPath
        Write-Log "Destination Directory: '$absoluteDestinationRoot' (preserving structure)" "INFO"
    } catch {
        Write-Log "ERROR: Could not set up DestinationPath '$DestinationPath'. $($_.Exception.Message)" "ERROR"
        return
    }
} else {
    Write-Log "No DestinationPath provided. Output next to originals." "INFO"
}

# Log original file handling strategy
if ($MoveOriginals) {
    Write-Log "Originals will be moved to 'Processed_Originals' next to source root." "INFO"
} else {
    Write-Log "Originals will be deleted after successful processing." "INFO"
}

# Setup logging
if ($LogFile) {
    try {
        $logFileDir = Split-Path $LogFile
        if ($logFileDir -and -not (Test-Path $logFileDir -PathType Container)) {
            New-Item -ItemType Directory -Path $logFileDir -ErrorAction Stop | Out-Null
        }
        $script:logFileStream = [System.IO.StreamWriter]::new($LogFile, $true)
        Write-Log "Logging to: '$LogFile'" "INFO"
        
        foreach ($entry in $script:logBuffer) {
            $script:logFileStream.WriteLine($entry)
        }
        $script:logBuffer.Clear()
    } catch {
        Write-Log "WARNING: Could not open log file '$LogFile': $($_.Exception.Message). Console-only logging." "WARNING"
        $LogFile = $null
    }
}

# Validate FFmpeg accessibility
if (-not (Test-FFmpegAccessibility -FFmpegExePath $FFmpegPath)) {
    return
}

# Resolve quality settings
$qualitySettings = Get-EffectiveQuality -QualityPreset $QualityPreset -VideoCRF $VideoCRF -VideoPreset $VideoPreset -AudioBitrate $AudioBitrate -ImageQuality $ImageQuality

# Discover files
Write-Log "`n--- Discovering Files ---" "INFO"
Write-Log "Scanning '$SourcePath' recursively..." "INFO"
$pendingActions = @()
$allSourceFiles = Get-ChildItem -Path (Join-Path $SourcePath "*") -File -Include ($imageExtensions + $videoExtensions + $audioExtensions) -Recurse -ErrorAction SilentlyContinue

foreach ($file in $allSourceFiles) {
    Write-Log "  Examining: $($file.FullName)" "DEBUG"
    $extension = $file.Extension.ToLower()
    
    $targetOutputDirectory = if ($absoluteDestinationRoot) {
        $relativePath = $file.Directory.FullName.Substring($SourcePath.Length).TrimStart("\", "/")
        $directory = Join-Path $absoluteDestinationRoot $relativePath
        New-Item -ItemType Directory -Path $directory -ErrorAction SilentlyContinue | Out-Null
        $directory
    } else {
        $file.DirectoryName
    }
    
    $action = $null
    
    if ($imageExtensions -contains "*$extension") {
        $action = Get-MediaFileAction -File $file -Extensions $imageExtensions -TargetExtension ".jpg" -Prefix "IMG" -ActionType "Image" -OutputDirectory $targetOutputDirectory -EnableRename:$EnableRename -RenameOnly:$RenameOnly
    } elseif ($videoExtensions -contains "*$extension") {
        $action = Get-MediaFileAction -File $file -Extensions $videoExtensions -TargetExtension ".mp4" -Prefix "VID" -ActionType "Video" -OutputDirectory $targetOutputDirectory -EnableRename:$EnableRename -RenameOnly:$RenameOnly
    } elseif ($audioExtensions -contains "*$extension") {
        $action = Get-MediaFileAction -File $file -Extensions $audioExtensions -TargetExtension ".mp3" -Prefix "AUD" -ActionType "Audio" -OutputDirectory $targetOutputDirectory -EnableRename:$EnableRename -RenameOnly:$RenameOnly
    } else {
        Write-Log "    Skipping unknown file type." "DEBUG"
    }
    
    if ($action) {
        $pendingActions += $action
    }
}

$actualPendingActions = $pendingActions | Where-Object { $_.Type -ne "Skipped" }

# Confirm and execute actions
if ($PSCmdlet.ShouldProcess("process media files recursively in '$SourcePath'", "Perform Conversion/Rename")) {
    if ($actualPendingActions.Count -eq 0) {
        Write-Log "`nNo actionable items. Exiting." "INFO"
        return
    }
    
    if (-not (Confirm-Actions -PendingActions $actualPendingActions)) {
        Write-Log "`nCancelled by user." "INFO"
        return
    }
    
    Write-Log "`n--- Executing Actions ---" "INFO"
    $convertedCount = 0
    $renamedCount = 0
    $skippedCount = 0
    $errorCount = 0
    $totalActions = $pendingActions.Count
    
    for ($i = 0; $i -lt $totalActions; $i++) {
        $action = $pendingActions[$i]
        Write-Progress -Activity "Processing Media Files" -Status "($($i + 1)/$totalActions) $($action.OriginalPath | Split-Path -Leaf)" -PercentComplete (($i + 1) / $totalActions * 100) -Id 1
        
        Write-Log "`n--- Processing File: $($action.OriginalPath | Split-Path -Leaf) ---" "INFO"
        Write-Log "  Planned Action: $($action.Type)" "INFO"
        Write-Log "  Original Path: $($action.OriginalPath)" "INFO"
        Write-Log "  New Path: $($action.NewPath)" "INFO"
        
        if ($action.Type -eq "Skipped") {
            Write-Log "  Skipped (no action needed)." "INFO"
            $skippedCount++
            continue
        }
        
        $success = $false
        
        # Handle rename operations
        if ($action.Type -match "Rename$") {
            $success = Invoke-FileRename -Action $action
            if ($success) {
                $renamedCount++
            } else {
                $errorCount++
            }
        }
        # Handle conversion operations
        elseif ($action.Type -match "Conversion$") {
            if ($RenameOnly) {
                Write-Log "  Skipped: RenameOnly mode." "INFO"
                $skippedCount++
                continue
            }
            
            $success = Invoke-MediaConversion -Action $action -QualitySettings $qualitySettings -FFmpegPath $FFmpegPath -UpscaleWidth $UpscaleWidth -Sharpen:$Sharpen -KeepHDR:$KeepHDR
            
            if ($success) {
                $convertedCount++
                
                # Manage original file only after successful conversion and when paths differ
                if ($action.OriginalPath.ToLower() -ne $action.NewPath.ToLower()) {
                    Remove-OriginalFile -OriginalFilePath $action.OriginalPath -MoveOriginals:$MoveOriginals -SourceBaseDir $SourcePath | Out-Null
                } else {
                    Write-Log "  Original equals target; nothing to remove/move." "INFO"
                }
            } else {
                $errorCount++
            }
        }
    }
    
    Write-Progress -Activity "Processing Media Files" -Completed -Status "All files processed." -Id 1
}

# Summary and cleanup
Write-Log "`n--- Script Execution Summary ---" "INFO"
Write-Log "Total Files Examined: $($pendingActions.Count)" "INFO"
Write-Log "Files Converted: $convertedCount" "INFO"
Write-Log "Files Renamed: $renamedCount" "INFO"
Write-Log "Files Skipped: $skippedCount" "INFO"
Write-Log "Files with Errors: $errorCount" "INFO"
Write-Log "------------------------------" "INFO"
Write-Log "Finished at $(Get-Date)." "INFO"

if ($script:logFileStream) {
    try {
        $script:logFileStream.Close()
        $script:logFileStream.Dispose()
        $script:logFileStream = $null
        Write-Host "Log saved to '$LogFile'." -ForegroundColor Green
    } catch {
        Write-Host "WARNING: Error closing log file: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
