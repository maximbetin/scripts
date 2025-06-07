# Requires: FFmpeg installed and its 'bin' directory added to your system's PATH.

# --- Script Parameters ---
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param(
    [Parameter(Mandatory=$false, Position=0, HelpMessage="The source directory to process. Defaults to the current directory.")]
    [string]$SourcePath = ".",

    [Parameter(Mandatory=$false, Position=1, HelpMessage="Optional: The destination directory for converted files. If omitted, files are converted/renamed in their original directories.")]
    [string]$DestinationPath,

    [Parameter(Mandatory=$false, HelpMessage="Path to the FFmpeg executable. Defaults to 'ffmpeg.exe' (assumes it's in PATH).")]
    [string]$FFmpegPath = "ffmpeg.exe",

    [Parameter(Mandatory=$false, HelpMessage="JPEG quality for image conversion (1=best, 31=worst).")]
    [int]$ImageQuality = 2,

    [Parameter(Mandatory=$false, HelpMessage="Video encoding preset for MP4 conversion (e.g., 'medium', 'fast', 'slow').")]
    [string]$VideoPreset = "medium",

    [Parameter(Mandatory=$false, HelpMessage="Constant Rate Factor for video encoding (lower=higher quality, larger file).")]
    [int]$VideoCRF = 23,

    [Parameter(Mandatory=$false, HelpMessage="Audio bitrate for video conversion (e.g., '128k', '192k').")]
    [string]$AudioBitrate = "128k",

    [Parameter(Mandatory=$false, HelpMessage="If specified, original files are moved to a 'Processed_Originals' subfolder instead of being deleted.")]
    [switch]$MoveOriginals,

    [Parameter(Mandatory=$false, HelpMessage="Path to a log file for detailed script execution records.")]
    [string]$LogFile
)

# --- Global Variables ---
# Use script: scope for variables intended to be accessible across functions
$script:LogBuffer = [System.Collections.ArrayList]::new() # Buffer for log entries before writing to file
$script:LogFileStream = $null                               # Stream object for writing to log file

# Define supported file extensions for discovery (case-insensitive on Windows)
$imageExtensions = "*.jpg", "*.jpeg", "*.png"
$videoExtensions = "*.3gp", "*.mkv", "*.mp4", "*.avi"

# --- Helper Functions ---

function Write-Log {
    <#
    .SYNOPSIS
        Writes a message to the console and, optionally, to a log file.
    .DESCRIPTION
        Formats a log entry with a timestamp and level, then adds it to an in-memory buffer.
        If a log file is configured, entries are also written to the file.
        Messages are printed to the console based on their level.
    .PARAMETER Message
        The log message string.
    .PARAMETER Level
        The logging level (e.g., "INFO", "WARNING", "ERROR", "DEBUG").
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR", "DEBUG")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp][$Level] $Message"
    $script:LogBuffer.Add($logEntry) | Out-Null # Add to buffer

    # Output to host based on level
    switch ($Level) {
        "ERROR" { Write-Error $Message }
        "WARNING" { Write-Warning $Message }
        "INFO" { Write-Host $Message }
        "DEBUG" { Write-Verbose $Message } # Requires -Verbose when running script
    }

    # Write to file if stream is open
    if ($script:LogFileStream) {
        try {
            $script:LogFileStream.WriteLine($logEntry)
        } catch {
            # Catch file write errors, e.g., disk full, permissions
            Write-Host "WARNING: Failed to write to log file: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Test-FFmpegAccessibility {
    <#
    .SYNOPSIS
        Checks if the FFmpeg executable is accessible.
    .DESCRIPTION
        Attempts to run 'ffmpeg -version' and checks its exit code. If successful,
        FFmpeg is deemed accessible and ready for use. Logs detailed messages.
    .PARAMETER FFMpegExePath
        The path to the FFmpeg executable.
    .OUTPUTS
        [boolean] True if FFmpeg is accessible, False otherwise.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$FFMpegExePath
    )
    Write-Log "Attempting to verify FFmpeg accessibility at '$FFMpegExePath'..." "DEBUG"
    try {
        & $FFMpegExePath -version | Out-Null
        Write-Log "FFmpeg is accessible." "INFO"
        return $true
    }
    catch {
        Write-Log "ERROR: FFmpeg executable not found or not accessible. Please ensure FFmpeg is correctly installed and its 'bin' directory is added to your system's PATH, or provide the full path using the -FFmpegPath parameter." "ERROR"
        return $false
    }
}

function Get-UniqueTimestampFileName {
    <#
    .SYNOPSIS
        Generates a unique, timestamp-based filename with a specified prefix.
    .DESCRIPTION
        Constructs a new filename using the LastWriteTime of the original file
        (e.g., 'PREFIX_YYYYMMDD_HHMMSS_FFF.ext'). If a file with this name
        already exists in the target directory, a counter is appended to ensure uniqueness.
    .PARAMETER OriginalFile
        The FileInfo object (from Get-ChildItem) of the original file.
    .PARAMETER TargetExtension
        The desired new file extension (e.g., ".jpg", ".mp4").
    .PARAMETER Prefix
        The desired prefix for the new file name (e.g., "IMG", "VID").
    .PARAMETER OutputDirectory
        The directory where the new file will be saved.
    .OUTPUTS
        [string] The full, unique path for the new file.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [System.IO.FileInfo]$OriginalFile,
        [Parameter(Mandatory=$true)]
        [string]$TargetExtension,
        [Parameter(Mandatory=$true)]
        [string]$Prefix,
        [Parameter(Mandatory=$true)]
        [string]$OutputDirectory
    )
    $timestamp = $OriginalFile.LastWriteTime.ToString("yyyyMMdd_HHmmss_fff")
    $baseName = "${Prefix}_$timestamp"
    $proposedName = "$baseName$TargetExtension"
    $newPath = Join-Path $OutputDirectory $proposedName

    $counter = 1
    # Check for name collisions and append a counter if necessary
    while (Test-Path $newPath) {
        $proposedName = "$baseName" + "_$counter" + $TargetExtension
        $newPath = Join-Path $OutputDirectory $proposedName
        $counter++
    }
    return $newPath
}

function Invoke-FFmpegConversion {
    <#
    .SYNOPSIS
        Executes an FFmpeg conversion command.
    .DESCRIPTION
        Runs FFmpeg with the given arguments in a new, hidden process.
        It captures FFmpeg's standard error output and exit code for detailed logging.
    .PARAMETER FFMpegExePath
        The path to the FFmpeg executable.
    .PARAMETER Arguments
        An array of arguments to pass directly to FFmpeg.
    .PARAMETER OriginalFilePath
        The full path of the original input file (used for logging context).
    .OUTPUTS
        [hashtable] A hashtable containing:
            - Success (boolean): True if FFmpeg exited with code 0.
            - FFMpegOutput (string): Captured output from FFmpeg's standard error.
            - ExitCode (int): FFmpeg's exit code.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$FFMpegExePath,
        [Parameter(Mandatory=$true)]
        [string[]]$Arguments,
        [Parameter(Mandatory=$true)]
        [string]$OriginalFilePath
    )
    Write-Log "  Executing FFmpeg command: `"$FFMpegExePath`" $($Arguments -join ' ')" "DEBUG"

    $tempErrorFile = [System.IO.Path]::GetTempFileName()
    $result = @{
        Success = $false
        FFMpegOutput = ""
        ExitCode = -1
    }

    try {
        # Start FFmpeg process, wait for it, and redirect its error output to a temp file
        $process = Start-Process -FilePath $FFMpegExePath -ArgumentList $Arguments -NoNewWindow -PassThru -Wait -RedirectStandardError $tempErrorFile
        $result.FFMpegOutput = (Get-Content $tempErrorFile | Out-String).Trim()
        $result.ExitCode = $process.ExitCode
        $result.Success = ($result.ExitCode -eq 0)
    }
    catch {
        Write-Log "ERROR: Failed to invoke Start-Process for '$OriginalFilePath': $($_.Exception.Message)" "ERROR"
        $result.FFMpegOutput = "PowerShell Start-Process Error: $($_.Exception.Message)"
    }
    finally {
        # Clean up the temporary error file
        Remove-Item $tempErrorFile -ErrorAction SilentlyContinue
    }
    return $result
}

function Handle-OriginalFile {
    <#
    .SYNOPSIS
        Manages the original file after successful processing (delete or move).
    .DESCRIPTION
        If the 'MoveOriginals' switch is present, the original file is moved
        to a 'Processed_Originals' subfolder, preserving its relative directory structure.
        Otherwise, the original file is deleted. Logs success or failure.
    .PARAMETER OriginalFilePath
        The full path to the original file to be managed.
    .PARAMETER MoveOriginals
        Switch to indicate if original files should be moved instead of deleted.
    .PARAMETER SourceBaseDir
        The absolute base source directory, crucial for calculating relative paths for moving.
    .OUTPUTS
        [boolean] True if the operation was successful, False otherwise.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$OriginalFilePath,
        [Parameter(Mandatory=$false)]
        [switch]$MoveOriginals,
        [Parameter(Mandatory=$true)] # Mandatory if MoveOriginals is specified
        [string]$SourceBaseDir
    )
    
    if ($MoveOriginals) {
        # Calculate relative path from SourceBaseDir to the original file's directory
        $relativeDir = (Get-Item $OriginalFilePath).Directory.FullName.Substring($SourceBaseDir.Length)
        $relativeDir = $relativeDir.TrimStart("\", "/") # Remove leading slashes

        # Construct the full path in the archive location
        # Archive root is a 'Processed_Originals' folder parallel to the SourceBaseDir
        $archiveRoot = Join-Path (Split-Path $SourceBaseDir) "Processed_Originals"
        $archiveDir = Join-Path $archiveRoot $relativeDir
        $archivePath = Join-Path $archiveDir (Split-Path $OriginalFilePath -Leaf)

        Write-Log "  Moving original file to archive: '$OriginalFilePath' -> '$archivePath'" "INFO"
        try {
            # Ensure the archive directory structure exists
            New-Item -ItemType Directory -Path $archiveDir -ErrorAction SilentlyContinue | Out-Null
            Move-Item -Path $OriginalFilePath -Destination $archivePath -Force -ErrorAction Stop
            Write-Log "  Original file successfully moved." "INFO"
            return $true
        }
        catch {
            Write-Log "WARNING: Failed to move original file '$OriginalFilePath': $($_.Exception.Message)" "WARNING"
            return $false
        }
    } else {
        Write-Log "  Removing original file: $($OriginalFilePath)" "INFO"
        try {
            Remove-Item -Path $OriginalFilePath -Force -ErrorAction Stop
            Write-Log "  Original file successfully removed." "INFO"
            return $true
        }
        catch {
            Write-Log "WARNING: Failed to remove original file '$OriginalFilePath': $($_.Exception.Message)" "WARNING"
            return $false
        }
    }
}

function Prompt-ForConfirmation {
    <#
    .SYNOPSIS
        Displays a list of proposed actions and asks for user confirmation.
    .DESCRIPTION
        Presents a formatted list of all planned conversions and renames
        (excluding skipped items). Prompts the user to confirm whether to proceed.
    .PARAMETER PendingActions
        An array of hashtables, where each hashtable describes a pending action
        (as prepared by the main script logic).
    .OUTPUTS
        [boolean] True if the user confirms, False otherwise.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [array]$PendingActions
    )

    if ($PendingActions.Count -eq 0) {
        Write-Log "No files found requiring conversion or renaming." "INFO"
        return $false
    }

    Write-Host "`n--- Proposed Actions ---" -ForegroundColor Cyan
    Write-Host "The following files will be processed:"

    # Get the current working directory for relative path calculations
    $currentLocation = (Get-Location).Path

    $i = 1
    foreach ($action in $PendingActions) {
        $actionType = switch ($action.Type) {
            "ImageConversion" { "Convert Image" }
            "VideoConversion" { "Convert Video" }
            "ImageRename"     { "Rename Image" }
            "VideoRename"     { "Rename Video" }
            default           { "Unknown Action" }
        }

        # --- MODIFIED: Manual relative path calculation for broader compatibility ---
        $displayOriginalPath = $action.OriginalPath
        $displayNewPath = $action.NewPath

        # Attempt to make paths relative to the current working directory if possible
        if ($displayOriginalPath.StartsWith($currentLocation, [System.StringComparison]::OrdinalIgnoreCase)) {
            $displayOriginalPath = "." + $displayOriginalPath.Substring($currentLocation.Length)
        }
        if ($displayNewPath.StartsWith($currentLocation, [System.StringComparison]::OrdinalIgnoreCase)) {
            $displayNewPath = "." + $displayNewPath.Substring($currentLocation.Length)
        }
        $displayOriginalPath = $displayOriginalPath.TrimStart("\", "/") # Clean up leading slashes if any
        $displayNewPath = $displayNewPath.TrimStart("\", "/")

        # --- END MODIFIED SECTION ---

        Write-Host "  $i. $($actionType): $displayOriginalPath -> $displayNewPath"
        $i++
    }

    Write-Host "`nDo you want to proceed with these actions? (Y/N)" -ForegroundColor Green
    $response = Read-Host
    if ($response -match "^y$" -or $response -match "^yes$" -or $response -match "^Y$" -or $response -match "^YES$") {
        return $true
    }
    return $false
}

# --- Script Execution Logic ---

#region Script Start and Initialization
Write-Log "--- Script Start ---" "INFO"
Write-Log "Started at $(Get-Date)" "INFO"

# Resolve and normalize SourcePath to an absolute path
$SourcePath = (Resolve-Path $SourcePath).Path
if (-not (Test-Path $SourcePath -PathType Container)) {
    Write-Log "ERROR: SourcePath '$SourcePath' is not a valid directory or does not exist." "ERROR"
    return # Exit function
}
Write-Log "Source Directory: '$SourcePath'" "INFO"

# Setup DestinationPath
$AbsoluteDestinationRoot = $null # Flag to indicate if a central destination is used

if ($DestinationPath) {
    # Resolve DestinationPath to an absolute path, create it if it doesn't exist
    try {
        $DestinationPath = (Resolve-Path $DestinationPath -ErrorAction Stop).Path # Resolve to absolute
        New-Item -ItemType Directory -Path $DestinationPath -ErrorAction SilentlyContinue | Out-Null
        $AbsoluteDestinationRoot = $DestinationPath
        Write-Log "Destination Directory: '$AbsoluteDestinationRoot' (preserving relative structure)" "INFO"
    } catch {
        Write-Log "ERROR: Could not set up DestinationPath '$DestinationPath'. $($_.Exception.Message)" "ERROR"
        return # Exit function
    }
} else {
    Write-Log "No specific DestinationPath provided. Files will be converted/renamed in their original directories." "INFO"
}

# Log original file handling preference
if ($MoveOriginals.IsPresent) {
    Write-Log "Original files will be moved to a 'Processed_Originals' subfolder within the source's parent." "INFO"
} else {
    Write-Log "Original files will be deleted after successful conversion/rename." "INFO"
}

# Setup log file stream
if ($LogFile) {
    try {
        # Ensure log file directory exists
        $LogFileDir = Split-Path $LogFile
        if (-not (Test-Path $LogFileDir -PathType Container)) {
            New-Item -ItemType Directory -Path $LogFileDir -ErrorAction Stop | Out-Null
        }
        $script:LogFileStream = [System.IO.StreamWriter]::new($LogFile, $true) # Append mode
        Write-Log "Logging details to file: '$LogFile'" "INFO"
        # Dump existing buffer to file, then clear buffer
        foreach ($entry in $script:LogBuffer) {
            $script:LogFileStream.WriteLine($entry)
        }
        $script:LogBuffer.Clear()
    }
    catch {
        Write-Log "WARNING: Could not open log file '$LogFile': $($_.Exception.Message). Logging will only be to console." "WARNING"
        $LogFile = $null # Disable file logging if creation fails
    }
}

# Validate FFmpeg accessibility before starting discovery
if (-not (Test-FFmpegAccessibility -FFmpegExePath $FFmpegPath)) {
    return # Exit function if FFmpeg isn't found
}

#endregion

#region Discover Files and Plan Actions
Write-Log "`n--- Discovering Files ---" "INFO"
Write-Log "Scanning '$SourcePath' recursively for images and videos..." "INFO"
$pendingActions = @()

# Use Get-ChildItem with -Recurse to find files in subdirectories
# ErrorAction SilentlyContinue is used to prevent PowerShell from stopping on permission errors
# However, individual file processing will have its own try-catch for more robust error handling
$allSourceFiles = Get-ChildItem -Path (Join-Path $SourcePath "*") -File -Include ($imageExtensions + $videoExtensions) -Recurse -ErrorAction SilentlyContinue

foreach ($file in $allSourceFiles) {
    Write-Log "  Examining file: $($file.FullName)" "DEBUG"
    $originalExtension = $file.Extension.ToLower()

    # Determine the target output directory for this specific file, maintaining structure
    $targetOutputDirectory = $null
    if ($AbsoluteDestinationRoot) {
        # Calculate relative path from SourcePath to the file's directory
        $relativePath = $file.Directory.FullName.Substring($SourcePath.Length)
        $relativePath = $relativePath.TrimStart("\", "/")

        $targetOutputDirectory = Join-Path $AbsoluteDestinationRoot $relativePath
        # Ensure the target directory structure exists in the destination
        New-Item -ItemType Directory -Path $targetOutputDirectory -ErrorAction SilentlyContinue | Out-Null
        Write-Log "    Output directory for this file: '$targetOutputDirectory'" "DEBUG"
    } else {
        # If no central destination, output to original file's directory
        $targetOutputDirectory = $file.DirectoryName
        Write-Log "    Output directory for this file: '$targetOutputDirectory' (original location)" "DEBUG"
    }

    # Handle Image Files
    if ($imageExtensions -contains "*$originalExtension") { # Check if it's an image extension
        $newPath = Get-UniqueTimestampFileName -OriginalFile $file -TargetExtension ".jpg" -Prefix "IMG" -OutputDirectory $targetOutputDirectory

        # Compare original and new paths (case-insensitive) to decide action
        $pathsAreIdentical = ($file.FullName.ToLower() -eq $newPath.ToLower())

        if ($originalExtension -eq ".jpg" -and $pathsAreIdentical) {
            $pendingActions += @{
                Type = "Skipped"
                OriginalPath = $file.FullName
                NewPath = $newPath
                ActionType = "Image"
            }
            Write-Log "    Action: Skipped (already JPG with correct name/case)." "DEBUG"
        } elseif ($originalExtension -eq ".jpg") { # It's a JPG, but needs renaming (case or unique name)
            $pendingActions += @{
                Type = "ImageRename"
                OriginalPath = $file.FullName
                NewPath = $newPath
                ActionType = "Image"
            }
            Write-Log "    Action: Rename Image (JPG, but needs new name/case)." "DEBUG"
        } else { # It's a non-JPG image, needs conversion
            $pendingActions += @{
                Type = "ImageConversion"
                OriginalPath = $file.FullName
                NewPath = $newPath
                ActionType = "Image"
            }
            Write-Log "    Action: Convert Image (non-JPG to JPG)." "DEBUG"
        }
    }
    # Handle Video Files
    elseif ($videoExtensions -contains "*$originalExtension") { # Check if it's a video extension
        $newPath = Get-UniqueTimestampFileName -OriginalFile $file -TargetExtension ".mp4" -Prefix "VID" -OutputDirectory $targetOutputDirectory

        # Compare original and new paths (case-insensitive) to decide action
        $pathsAreIdentical = ($file.FullName.ToLower() -eq $newPath.ToLower())

        if ($originalExtension -eq ".mp4" -and $pathsAreIdentical) {
            $pendingActions += @{
                Type = "Skipped"
                OriginalPath = $file.FullName
                NewPath = $newPath
                ActionType = "Video"
            }
            Write-Log "    Action: Skipped (already MP4 with correct name/case)." "DEBUG"
        } elseif ($originalExtension -eq ".mp4") { # It's an MP4, but needs renaming
            $pendingActions += @{
                Type = "VideoRename"
                OriginalPath = $file.FullName
                NewPath = $newPath
                ActionType = "Video"
            }
            Write-Log "    Action: Rename Video (MP4, but needs new name/case)." "DEBUG"
        } else { # It's a non-MP4 video, needs conversion
            $pendingActions += @{
                Type = "VideoConversion"
                OriginalPath = $file.FullName
                NewPath = $newPath
                ActionType = "Video"
            }
            Write-Log "    Action: Convert Video (non-MP4 to MP4)." "DEBUG"
        }
    }
    else {
        Write-Log "    Skipping unknown file type: $($file.FullName)" "DEBUG"
    }
}

# Filter out explicitly skipped items for the confirmation prompt, but keep them for final stats
$actualPendingActions = $pendingActions | Where-Object { $_.Type -ne "Skipped" }

#endregion

#region Confirmation and Execution
# Use ShouldProcess for -WhatIf and -Confirm functionality
if ($PSCmdlet.ShouldProcess("process media files recursively in '$SourcePath'", "Perform Conversion/Rename")) {

    # If -Force is not used and there are actual actions to perform, prompt the user
    if (-not $Force.IsPresent -and ($actualPendingActions.Count -gt 0)) {
        if (-not (Prompt-ForConfirmation -PendingActions $actualPendingActions)) {
            Write-Log "`nOperation cancelled by user at confirmation prompt. Exiting." "INFO"
            return # Exit the function
        }
    } elseif ($actualPendingActions.Count -eq 0) {
        Write-Log "`nNo files found requiring conversion or renaming after planning. Exiting." "INFO"
        return
    } elseif ($Force.IsPresent) {
        Write-Log "`nForce option enabled. Proceeding without interactive confirmation." "INFO"
    }

    Write-Log "`n--- Executing Actions ---" "INFO"
    $convertedCount = 0
    $renamedCount = 0
    $skippedCount = 0 # Counter for items actually skipped during execution
    $errorCount = 0

    $totalActions = $pendingActions.Count
    $currentActionIndex = 0

    foreach ($action in $pendingActions) {
        $currentActionIndex++
        # Update progress bar for long-running operations
        Write-Progress -Activity "Processing Media Files" -Status "($currentActionIndex/$totalActions) $($action.OriginalPath | Split-Path -Leaf)" -PercentComplete ($currentActionIndex / $totalActions * 100) -Id 1

        Write-Log "`n--- Processing File: $($action.OriginalPath | Split-Path -Leaf) ---" "INFO"
        Write-Log "  Planned Action: $($action.Type)" "INFO"
        Write-Log "  Original Path: $($action.OriginalPath)" "INFO"
        Write-Log "  New Path: $($action.NewPath)" "INFO"

        if ($action.Type -eq "Skipped") {
            Write-Log "  Skipped: File already in desired format and name." "INFO"
            $skippedCount++
            continue # Move to the next action
        }

        $ffmpegArgs = @()
        $conversionSuccessful = $false

        try {
            if ($action.ActionType -eq "Image") {
                $ffmpegArgs = @(
                    "-i", "`"$($action.OriginalPath)`"",
                    "-q:v", "$ImageQuality",
                    "-y", # Overwrite output file without asking
                    "`"$($action.NewPath)`""
                )
                $conversionResult = Invoke-FFmpegConversion -FFMpegExePath $FFmpegPath -Arguments $ffmpegArgs -OriginalFilePath $action.OriginalPath
                $conversionSuccessful = $conversionResult.Success
                if ($conversionSuccessful) {
                    Write-Log "  Image conversion/rename completed successfully." "INFO"
                    if ($action.Type -eq "ImageConversion") { $convertedCount++ }
                    else { $renamedCount++ }
                } else {
                    Write-Log "ERROR: Image conversion failed for '$($action.OriginalPath)'. FFmpeg Exit Code: $($conversionResult.ExitCode)." "ERROR"
                    Write-Log "FFmpeg Output: $($conversionResult.FFMpegOutput)" "ERROR"
                    $errorCount++
                }
            } elseif ($action.ActionType -eq "Video") {
                $ffmpegArgs = @(
                    "-i", "`"$($action.OriginalPath)`"",
                    "-c:v", "libx264", # Use libx264 for H.264 video encoding
                    "-preset", "$VideoPreset",
                    "-crf", "$VideoCRF",
                    "-c:a", "aac",    # Use aac for AAC audio encoding
                    "-b:a", "$AudioBitrate",
                    "-y",
                    "`"$($action.NewPath)`""
                )
                $conversionResult = Invoke-FFmpegConversion -FFMpegExePath $FFmpegPath -Arguments $ffmpegArgs -OriginalFilePath $action.OriginalPath
                $conversionSuccessful = $conversionResult.Success
                if ($conversionSuccessful) {
                    Write-Log "  Video conversion/rename completed successfully." "INFO"
                    if ($action.Type -eq "VideoConversion") { $convertedCount++ }
                    else { $renamedCount++ }
                } else {
                    Write-Log "ERROR: Video conversion failed for '$($action.OriginalPath)'. FFmpeg Exit Code: $($conversionResult.ExitCode)." "ERROR"
                    Write-Log "FFmpeg Output: $($conversionResult.FFMpegOutput)" "ERROR"
                    $errorCount++
                }
            }
        }
        catch {
            Write-Log "CRITICAL ERROR during processing '$($action.OriginalPath)': $($_.Exception.Message)" "ERROR"
            $errorCount++
            $conversionSuccessful = $false # Ensure flag is false on critical error
        }

        # Handle original file (delete or move) only if conversion was successful
        # and the original path is different from the new path (case-insensitive)
        if ($conversionSuccessful -and ($action.OriginalPath.ToLower() -ne $action.NewPath.ToLower())) {
            Handle-OriginalFile -OriginalFilePath $action.OriginalPath -MoveOriginals:$MoveOriginals -SourceBaseDir $SourcePath
        } elseif ($conversionSuccessful -and ($action.OriginalPath.ToLower() -eq $action.NewPath.ToLower())) {
            Write-Log "  Original file was already the target path/name; no deletion or moving needed." "INFO"
        }
    }
    # Clear the progress bar when done
    Write-Progress -Activity "Processing Media Files" -Completed -Status "All files processed." -Id 1

} # End ShouldProcess

#endregion

#region Script End and Cleanup
Write-Log "`n--- Script Execution Summary ---" "INFO"
Write-Log "Total Files Examined: $($pendingActions.Count)" "INFO"
Write-Log "Files Converted (from other formats): $($convertedCount)" "INFO"
Write-Log "Files Renamed (same format, new name/case): $($renamedCount)" "INFO"
Write-Log "Files Skipped (already in desired format and name): $($skippedCount)" "INFO"
Write-Log "Files with Errors: $($errorCount)" "INFO"
Write-Log "------------------------------" "INFO"
Write-Log "Script finished at $(Get-Date)." "INFO"

# Close log file stream if it was opened
if ($script:LogFileStream) {
    try {
        $script:LogFileStream.Close()
        $script:LogFileStream.Dispose()
        $script:LogFileStream = $null
        Write-Host "Log saved to '$LogFile'." -ForegroundColor Green
    }
    catch {
        Write-Host "WARNING: Error closing log file: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
#endregion