function Remove-GitBranch {
  <#
    .SYNOPSIS
    Deletes a specified Git branch locally and remotely with minimal interaction.

    .DESCRIPTION
    This function quickly deletes a Git branch from your local repository
    and the 'origin' remote. It's designed for speed, assuming you know
    which branch you want to delete.

    .PARAMETER BranchName
    The name of the Git branch to delete. This parameter is mandatory.

    .EXAMPLE
    gdel feature/old-task

    .EXAMPLE
    gdel bugfix/temp-fix

    .NOTES
    - YOU MUST BE ON A DIFFERENT BRANCH than the one you are deleting.
    - This version provides no confirmation. Use with care.
    - The remote is assumed to be 'origin'.
    #>
  [CmdletBinding()]
  param (
    [Parameter(Mandatory = $true)]
    [string]$BranchName
  )

  # Basic check if Git is available
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error "Git is not installed or not in your PATH."
    return
  }

  # Get current branch for safety check
  $currentBranch = (git rev-parse --abbrev-ref HEAD 2>$null).Trim()
  if ($LASTEXITCODE -ne 0) {
    Write-Error "Not in a Git repository."
    return
  }

  # Prevent deleting the current branch
  if ($currentBranch -eq $BranchName) {
    Write-Error "Error: You cannot delete the branch you are currently on. Please checkout another branch first (e.g., 'git checkout main')."
    return
  }

  Write-Host "Attempting to delete local and remote branch: $BranchName" -ForegroundColor Cyan

  # Delete Local Branch
  $localDeleteResult = git branch -D $BranchName 2>&1
  if ($LASTEXITCODE -eq 0) {
    Write-Host "Local branch '$BranchName' deleted successfully." -ForegroundColor Green
  } else {
    Write-Error "Failed to delete local branch '$BranchName'. Error: $localDeleteResult. $($Error[0].Exception.Message)."
    return # Stop if local deletion fails
  }

  # Delete Remote Branch
  $remoteDeleteResult = git push origin --delete $BranchName 2>&1
  if ($LASTEXITCODE -eq 0) {
    Write-Host "Remote branch 'origin/$BranchName' deleted successfully." -ForegroundColor Green
  } else {
    Write-Error "Failed to delete remote branch 'origin/$BranchName'. Error: $remoteDeleteResult. $($Error[0].Exception.Message). You might need to delete it manually on GitHub."
    # Don't return here, proceed to prune even if remote deletion fails
  }

  # Prune remote-tracking branches
  git fetch --prune origin >$null 2>&1 # Suppress output for simplicity
  Write-Host "Remote-tracking branches pruned." -ForegroundColor DarkGreen

  Write-Host "Branch deletion process completed." -ForegroundColor Green
}

# --- Git Aliases ---
function g { git }
function gadd { git add }
function gps { git push }
function gpu { git pull }
function gcl { git clone }
function gb { git branch }
function gdiff { git diff }
function gst { git status }
function gdel { Remove-GitBranch $args[0] }
function gcm { git commit -m $args[0] }
function greset { git reset --hard HEAD }
function guser { git config --global user.name }
function gmail { git config --global user.email }
function gprune { git fetch --prune origin }

# --- Docker Aliases ---
function d { docker }
function dps { docker ps }
function drm { docker rm }
function dl { docker logs }
function drmi { docker rmi }
function dstop { docker stop }
function dpsa { docker ps -a }
function db { docker build . }
function dimg { docker images }
function dcup { docker-compose up -d }
function dcdown { docker-compose down }
function dexec { docker exec -it $args }
function dprune { docker system prune -f }

# --- Kubernetes Aliases ---
function k { kubectl }
function kg { kubectl get }
function kl { kubectl logs }
function kv { kubectl version }
function kdel { kubectl delete }
function kd { kubectl describe }
function kpo { kubectl get pods }
function ksvc { kubectl get services }
function ka { kubectl apply -f $args[0] }
function kdep { kubectl get deployments }
function kexec { kubectl exec -it $args }
function kns { kubectl config set-context --current --namespace $args[0] }

# --- General Utility Aliases ---
function c { Clear-Host }
function us { [char]0x262D }
function grep { Select-String }
function ls { Get-ChildItem -Force }
function ping { Test-Connection -Count 4 }
function pkill { Stop-Process -Name $args[0] }
function ll { Get-ChildItem -Force | Format-List }