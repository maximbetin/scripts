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
    [Parameter(Mandatory = $true, Position = 0)]
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

function Show-OurAlias {
  [char]0x262D
}

# --- Git Aliases ---
Set-Alias g       'git'
Set-Alias gadd    'git add'
Set-Alias gpus    'git push'
Set-Alias gpull   'git pull'
Set-Alias gdiff   'git diff'
Set-Alias gcl     'git clone'
Set-Alias gst     'git status'
Set-Alias gb      'git branch'
Set-Alias gco     'git checkout'
Set-Alias gcmt    'git commit -m'
Set-Alias gstp    'git stash pop'
Set-Alias gsta    'git stash save'
Set-Alias gstl    'git stash list'
Set-Alias gdel    'Remove-GitBranch'
Set-Alias grh     'git reset --hard HEAD'
Set-Alias guser   'git config --global user.name'
Set-Alias gemail  'git config --global user.email'

# --- Docker Aliases ---
Set-Alias d       'docker'
Set-Alias dps     'docker ps'
Set-Alias drm     'docker rm'
Set-Alias drmi    'docker rmi'
Set-Alias dlog    'docker logs'
Set-Alias dstop   'docker stop'
Set-Alias dpsa    'docker ps -a'
Set-Alias dil     'docker images'
Set-Alias dbd     'docker build .'
Set-Alias dexec   'docker exec -it'
Set-Alias dcdown  'docker-compose down'
Set-Alias dcup    'docker-compose up -d'
Set-Alias dcln    'docker system prune -f'

# --- Kubernetes Aliases ---
Set-Alias k       'kubectl'
Set-Alias kget    'kubectl get'
Set-Alias klogs   'kubectl logs'
Set-Alias kdel    'kubectl delete'
Set-Alias kver    'kubectl version'
Set-Alias kpo     'kubectl get pods'
Set-Alias kappl   'kubectl apply -f'
Set-Alias kexec   'kubectl exec -it'
Set-Alias kdesc   'kubectl describe'
Set-Alias ksvc    'kubectl get services'
Set-Alias kdep    'kubectl get deployments'
Set-Alias kns     'kubectl config set-context --current --namespace'

# --- General Utility Aliases ---
Set-Alias cat     'Get-Content'
Set-Alias source  ". `$PROFILE"
Set-Alias h       'Get-History'
Set-Alias grep    'Select-String'
Set-Alias pkill   'Stop-Process -Name'
Set-Alias ls      'Get-ChildItem -Force'
Set-Alias ping    'Test-Connection -Count 4'
Set-Alias ll      'Get-ChildItem -Force | Format-List'
Set-Alias us      'Show-OurAlias'