# Set current directory
$currentDirectory = Get-Location

# Get all .wav files in the current directory
$wavFiles = Get-ChildItem -Path $currentDirectory -Filter *.wav

# Loop through each WAV file and convert to MP3
foreach ($file in $wavFiles) {
    $fileNameWithoutExtension = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $outputMp3 = Join-Path $currentDirectory "$fileNameWithoutExtension.mp3"

    Write-Host "Converting '$($file.Name)' to '$($fileNameWithoutExtension).mp3'..."

    # ffmpeg command
    ffmpeg -i "$($file.FullName)" -vn -ab 320k -map_metadata 0 -id3v2_version 3 "$outputMp3"

    # Optional: Delete the original WAV file after successful conversion
    # Remove-Item -Path $file.FullName -Force

    Write-Host "Converted '$($file.Name)' successfully."
}
