#!/usr/bin/env bash
# Purpose: DevOps + Python workstation on Ubuntu/Xubuntu 24.04 LTS (works well in VirtualBox).
# Core: Docker (group or rootless), kubectl, Helm, kind, Terraform, Brave Browser, Cursor, Zsh aliases + completions.
# Optional: Python toolchain, PowerShell Core, Azure PS modules, Cloud CLIs.
# Interactive menu: run all / next / specific steps. Idempotent. Hardened downloads and complete deps.

set -Eeuo pipefail
trap 'echo "[X] Error on line $LINENO" >&2' ERR

# ----- Feature toggles (defaults; change via "Toggle features" in the menu) -----
ENABLE_PYTHON=1
ENABLE_POWERSHELL=1
ENABLE_AZ_PWSH_MODULES=1
FULL_AZ_MODULE_ROLLUP=0
ENABLE_CLOUD_CLIS=0
ENABLE_ROOTLESS_DOCKER=0   # 0: group mode; 1: rootless

# ----- Derived config -----
export DEBIAN_FRONTEND=noninteractive
USER_NAME="${SUDO_USER:-$USER}"
USER_HOME="$(eval echo ~"$USER_NAME")"
ARCH_DEB="$(dpkg --print-architecture)"   # amd64/arm64
case "$ARCH_DEB" in amd64) ARCH_BIN=amd64 ;; arm64) ARCH_BIN=arm64 ;; *) echo "[!] Unsupported arch: $ARCH_DEB"; exit 1 ;; esac
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"  # noble for 24.04
LOCAL_BIN="$USER_HOME/.local/bin"

# Curl defaults (robust)
CURL="curl -fsSL --retry 5 --retry-delay 2 --fail"

echo "[i] User=$USER_NAME Home=$USER_HOME Arch=$ARCH_DEB/$ARCH_BIN Codename=$CODENAME"

need_root() { [[ $EUID -eq 0 ]] || { echo "[!] Run as root: sudo $0"; exit 1; }; }

ensure_dirs() {
  install -d -m 0755 "$LOCAL_BIN"
  chown -R "$USER_NAME:$USER_NAME" "$LOCAL_BIN"
  install -d -m 0755 /etc/apt/keyrings
}

ensure_apt_prereqs() {
  # Minimal tools required before adding apt repos/keys (safe to re-run)
  apt-get update -y || true
  apt-get install -y ca-certificates gnupg curl || true
  install -d -m 0755 /etc/apt/keyrings
}

require_network() {
  # Allow bypass for airgapped installs
  if [[ "${NO_NET_CHECK:-0}" == "1" ]]; then
    echo "[i] Skipping network check (NO_NET_CHECK=1)"
    return 0
  fi
  # Prefer Ubuntu infra; fall back to a generic fast site
  if $CURL https://mirrors.ubuntu.com/mirrors.txt >/dev/null 2>&1; then
    return 0
  fi
  if $CURL https://www.google.com/generate_204 >/dev/null 2>&1; then
    return 0
  fi
  echo "[!] Network check failed. Ensure internet connectivity and DNS are working." >&2
  exit 1
}

apt_base() {
  apt-get update -y
  apt-get -o Dpkg::Use-Pty=0 upgrade -y
  apt-get install -y \
    apt-transport-https ca-certificates curl gnupg lsb-release \
    software-properties-common build-essential unzip jq htop net-tools \
    zsh git wget gpg pkg-config bash-completion xdg-utils
}

is_virtualbox() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    [[ "$(systemd-detect-virt)" == "oracle" ]]
  else
    grep -qi virtualbox /sys/class/dmi/id/product_name 2>/dev/null
  fi
}

install_vbox_guest() {
  echo "[i] Installing VirtualBox Guest Additions"
  apt-get install -y "linux-headers-$(uname -r)" || apt-get install -y linux-headers-generic || true
  apt-get install -y virtualbox-guest-dkms virtualbox-guest-utils virtualbox-guest-x11 || true
}

# ----- Brave Browser -----
install_brave() {
  if command -v brave-browser >/dev/null 2>&1; then
    echo "[=] Brave Browser present"
  else
    echo "[i] Installing Brave Browser"
    ensure_apt_prereqs
    # Brave provides a pre-dearmored keyring; save directly
    $CURL -o /usr/share/keyrings/brave-browser-archive-keyring.gpg \
      https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
    chmod 644 /usr/share/keyrings/brave-browser-archive-keyring.gpg

    local list=/etc/apt/sources.list.d/brave-browser-release.list
    local line="deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main"
    if [[ ! -f "$list" ]] || ! grep -Fxq "$line" "$list"; then
      echo "$line" | tee "$list" >/dev/null
    fi

    apt-get update -y
    apt-get install -y brave-browser
  fi

  # Optionally set as default browser if a desktop session is present
  if command -v xdg-settings >/dev/null 2>&1; then
    if [[ -n "${DISPLAY:-}" || -n "${XDG_CURRENT_DESKTOP:-}" ]]; then
      if ! xdg-settings check default-web-browser brave-browser.desktop >/dev/null 2>&1; then
        sudo -u "$USER_NAME" xdg-settings set default-web-browser brave-browser.desktop || true
        echo "[i] Set Brave as default browser (best-effort)."
      fi
    fi
  fi
}

# ----- Docker (choose one mode) -----
install_docker_group_mode() {
  if [[ "$ENABLE_ROOTLESS_DOCKER" == "1" ]]; then
    echo "[!] Rootless mode selected; skipping group-mode Docker"
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    echo "[=] Docker present (group mode)"
    return 0
  fi
  echo "[i] Installing Docker (group mode)"
  ensure_apt_prereqs
  apt-get remove -y docker docker-engine docker.io containerd runc || true
  $CURL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod 644 /etc/apt/keyrings/docker.gpg
  echo "deb [arch=${ARCH_DEB} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    | tee /etc/apt/sources.list.d/docker.list >/dev/null
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  usermod -aG docker "$USER_NAME"
  echo "[i] Re-login required for docker group membership."
}

install_docker_rootless_mode() {
  if groups "$USER_NAME" | grep -q '\bdocker\b'; then
    echo "[!] User is in 'docker' group (group-mode active). Remove from group or skip rootless."
    return 1
  fi
  echo "[i] Installing Docker (rootless mode)"
  ensure_apt_prereqs
  $CURL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod 644 /etc/apt/keyrings/docker.gpg
  echo "deb [arch=${ARCH_DEB} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    | tee /etc/apt/sources.list.d/docker.list >/dev/null
  apt-get update -y
  apt-get install -y docker-ce-cli docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras uidmap dbus-user-session slirp4netns fuse-overlayfs
  if ! sudo -u "$USER_NAME" command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1; then
    echo "[!] dockerd-rootless-setuptool.sh not found; check docker-ce-rootless-extras package"
  fi
  sudo -u "$USER_NAME" env XDG_RUNTIME_DIR="/run/user/$(id -u "$USER_NAME")" dockerd-rootless-setuptool.sh install || true
  for rc in "$USER_HOME/.bashrc" "$USER_HOME/.zshrc"; do
    touch "$rc"
    if ! grep -q "DOCKER_HOST=unix:///run/user" "$rc"; then
      echo 'export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock' >> "$rc"
      chown "$USER_NAME:$USER_NAME" "$rc"
    fi
  done
  loginctl enable-linger "$USER_NAME" || true
  sudo -u "$USER_NAME" systemctl --user enable docker.service || true
  sudo -u "$USER_NAME" systemctl --user start docker.service || true
  echo "[i] Rootless Docker set. Open a new shell for DOCKER_HOST."
}

install_kubernetes_tooling() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "[i] Installing kubectl (stable)"
    tmp=$(mktemp -d); pushd "$tmp" >/dev/null
    KREL="$($CURL https://dl.k8s.io/release/stable.txt)"
    $CURL -o kubectl "https://dl.k8s.io/release/${KREL}/bin/linux/${ARCH_BIN}/kubectl"
    install -m 0755 kubectl /usr/local/bin/kubectl
    popd >/dev/null; rm -rf "$tmp"
  else
    echo "[=] kubectl present"
  fi
  if ! command -v helm >/dev/null 2>&1; then
    echo "[i] Installing Helm"
    $CURL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  else
    echo "[=] Helm present"
  fi
  if ! command -v kind >/dev/null 2>&1; then
    echo "[i] Installing kind"
    $CURL -o /usr/local/bin/kind "https://kind.sigs.k8s.io/dl/latest/kind-linux-${ARCH_BIN}"
    chmod +x /usr/local/bin/kind
  else
    echo "[=] kind present"
  fi
}

install_terraform() {
  if command -v terraform >/dev/null 2>&1; then
    echo "[=] Terraform present"
    return 0
  fi
  echo "[i] Installing Terraform"
  ensure_apt_prereqs
  $CURL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  chmod 644 /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${CODENAME} main" \
    | tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  apt-get update -y
  apt-get install -y terraform
}

install_cursor() {
  if command -v cursor >/dev/null 2>&1 || command -v code >/dev/null 2>&1; then
    echo "[=] Cursor/VS Code present"
    return 0
  fi
  echo "[i] Installing Cursor"
  # Electron / VS Code runtime deps
  apt-get install -y \
    libnss3 libxss1 libgtk-3-0 libasound2 libx11-xcb1 libxcb-dri3-0 \
    libxkbfile1 libsecret-1-0 libgbm1
  tmp=$(mktemp -d); pushd "$tmp" >/dev/null
  $CURL -o cursor.deb "https://downloader.cursor.sh/linux/app.deb"
  apt-get install -y ./cursor.deb
  popd >/dev/null; rm -rf "$tmp"
}

shell_setup() {
  for rc in "$USER_HOME/.bashrc" "$USER_HOME/.zshrc"; do
    touch "$rc"
    if ! grep -q "# DevOps aliases (autogen)" "$rc"; then
      cat >>"$rc" <<'EOF'

# DevOps aliases (autogen)
alias k='kubectl'
alias kgp='kubectl get pods -o wide'
alias kga='kubectl get all'
alias dk='docker'
alias dps="docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
EOF
      chown "$USER_NAME:$USER_NAME" "$rc"
    fi
  done
  # Enable completions (bash/zsh) for kubectl/helm when present
  if command -v kubectl >/dev/null 2>&1; then
    kubectl completion bash >/etc/bash_completion.d/kubectl || true
    install -d /usr/share/zsh/vendor-completions || true
    kubectl completion zsh  >/usr/share/zsh/vendor-completions/_kubectl || true
  fi
  if command -v helm >/dev/null 2>&1; then
    helm completion bash >/etc/bash_completion.d/helm || true
    install -d /usr/share/zsh/vendor-completions || true
    helm completion zsh  >/usr/share/zsh/vendor-completions/_helm || true
  fi
  if command -v zsh >/dev/null 2>&1; then
    cur_shell="$(getent passwd "$USER_NAME" | cut -d: -f7)"
    zsh_path="$(command -v zsh)"
    [[ "$cur_shell" == "$zsh_path" ]] || { echo "[i] Default shell -> zsh"; chsh -s "$zsh_path" "$USER_NAME" || true; }
  fi
}

python_stack() {
  echo "[i] Installing Python toolchain"
  apt-get install -y python3 python3-dev python3-venv python3-pip python3-full || true
  apt-get install -y pipx
  sudo -u "$USER_NAME" pipx ensurepath || true
  # uv (fast package/venv manager) + common dev tools
  if ! sudo -u "$USER_NAME" pipx list 2>/dev/null | grep -q '^package uv '; then
    sudo -u "$USER_NAME" pipx install uv
  fi
  for pkg in ruff mypy pytest pyright; do
    if ! sudo -u "$USER_NAME" pipx list 2>/dev/null | grep -q "^package ${pkg} "; then
      sudo -u "$USER_NAME" pipx install "$pkg"
    fi
  done
  for rc in "$USER_HOME/.bashrc" "$USER_HOME/.zshrc"; do
    touch "$rc"
    if ! grep -q "# Python env (autogen)" "$rc"; then
      cat >>"$rc" <<'EOF'

# Python env (autogen)
export PATH="$HOME/.local/bin:$PATH"
alias venv='python3 -m venv .venv && . .venv/bin/activate'
EOF
      chown "$USER_NAME:$USER_NAME" "$rc"
    fi
  done
}

powershell_core() {
  if command -v pwsh >/dev/null 2>&1; then
    echo "[=] PowerShell present"
    return 0
  fi
  echo "[i] Installing PowerShell Core"
  ensure_apt_prereqs
  $CURL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg
  chmod 644 /usr/share/keyrings/microsoft.gpg
  echo "deb [arch=${ARCH_DEB} signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/${CODENAME}/prod ${CODENAME} main" \
    | tee /etc/apt/sources.list.d/microsoft-prod.list >/dev/null
  apt-get update -y
  apt-get install -y powershell
}

install_pwsh_az_modules() {
  echo "[i] Installing Azure PowerShell modules (user scope)"
  sudo -u "$USER_NAME" pwsh -NoLogo -NoProfile -Command "Set-PSRepository -Name PSGallery -InstallationPolicy Trusted" || true
  if [[ "$FULL_AZ_MODULE_ROLLUP" == "1" ]]; then
    sudo -u "$USER_NAME" pwsh -NoLogo -NoProfile -Command \
      "Install-Module Az -Scope CurrentUser -Force -AllowClobber"
  else
    sudo -u "$USER_NAME" pwsh -NoLogo -NoProfile -Command '
      $mods = @(
        "Az.Accounts","Az.Resources","Az.Storage","Az.KeyVault",
        "Az.Network","Az.Compute","Az.ContainerRegistry","Az.Aks","Az.Websites"
      )
      foreach ($m in $mods) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
          Install-Module $m -Scope CurrentUser -Force -AllowClobber
        }
      }
    '
  fi
}

cloud_clis() {
  ensure_apt_prereqs
  if ! command -v aws >/dev/null 2>&1; then
    echo "[i] Installing AWS CLI v2"
    tmp=$(mktemp -d); pushd "$tmp" >/dev/null
    $CURL -o awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH_BIN}.zip"
    unzip -q awscliv2.zip
    ./aws/install -i /usr/local/aws -b /usr/local/bin || ./aws/install --bin-dir /usr/local/bin || true
    popd >/dev/null; rm -rf "$tmp"
  else
    echo "[=] AWS CLI present"
  fi
  if ! command -v az >/dev/null 2>&1; then
    echo "[i] Installing Azure CLI"
    $CURL https://aka.ms/InstallAzureCLIDeb | bash
  else
    echo "[=] Azure CLI present"
  fi
  if ! command -v gcloud >/dev/null 2>&1; then
    echo "[i] Installing Google Cloud SDK"
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
      | tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
    $CURL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
    chmod 644 /usr/share/keyrings/cloud.google.gpg
    apt-get update -y
    apt-get install -y google-cloud-cli
  else
    echo "[=] gcloud present"
  fi
}

final_cleanup() { apt-get autoremove -y; apt-get clean; }

verify() {
  echo
  echo "=== Versions ==="
  command -v brave-browser >/dev/null 2>&1 && brave-browser --version || echo "brave-browser: not installed"
  command -v docker   >/dev/null 2>&1 && docker --version || echo "docker: not found"
  command -v kubectl  >/dev/null 2>&1 && kubectl version --client=true || echo "kubectl: not found"
  command -v helm     >/dev/null 2>&1 && helm version || echo "helm: not found"
  command -v kind     >/dev/null 2>&1 && kind version || echo "kind: not found"
  command -v terraform>/dev/null 2>&1 && terraform -version || echo "terraform: not found"
  command -v cursor   >/dev/null 2>&1 && echo "cursor: installed" || echo "cursor: not found"
  command -v python3  >/dev/null 2>&1 && python3 --version || echo "python3: not found"
  command -v pipx     >/dev/null 2>&1 && pipx --version || echo "pipx: not found"
  command -v uv       >/dev/null 2>&1 && uv --version || echo "uv: not found"
  command -v ruff     >/dev/null 2>&1 && ruff --version || echo "ruff: not found"
  command -v mypy     >/dev/null 2>&1 && mypy --version || echo "mypy: not found"
  command -v pytest   >/dev/null 2>&1 && pytest --version || echo "pytest: not found"
  command -v pyright  >/dev/null 2>&1 && pyright --version || echo "pyright: not found"
  command -v pwsh     >/dev/null 2>&1 && pwsh --version || echo "pwsh: not installed"
  command -v az       >/dev/null 2>&1 && az version >/dev/null 2>&1 && echo "az: installed" || echo "az: not installed"
  command -v aws      >/dev/null 2>&1 && aws --version || echo "aws: not installed"
  command -v gcloud   >/dev/null 2>&1 && gcloud --version || echo "gcloud: not installed"
  echo "================"
}

# ----- Step registry -----
declare -A STEPS=(
  [1]="Base system + VirtualBox"
  [2]="Docker (group mode)"
  [3]="Docker (rootless mode)"
  [4]="Kubernetes tooling (kubectl/helm/kind)"
  [5]="Terraform"
  [6]="Python toolchain"
  [7]="PowerShell Core"
  [8]="Azure PowerShell modules"
  [9]="Cloud CLIs (AWS/Azure/gcloud)"
  [10]="Brave Browser"
  [11]="Cursor IDE"
  [12]="Shell aliases + completions + zsh default"
  [13]="Verify versions"
)
ORDER=(1 2 4 5 6 7 8 9 10 11 12 13) # Default order (group-mode Docker). Rootless is explicit.

declare -A DONE=()
NEXT_IDX=0

run_step() {
  case "$1" in
    1) ensure_dirs; require_network; apt_base; is_virtualbox && install_vbox_guest || echo "[i] Not VirtualBox; skipping guest additions" ;;
    2) ENABLE_ROOTLESS_DOCKER=0; install_docker_group_mode ;;
    3) ENABLE_ROOTLESS_DOCKER=1; install_docker_rootless_mode ;;
    4) install_kubernetes_tooling ;;
    5) install_terraform ;;
    6) [[ "$ENABLE_PYTHON" == "1" ]] && python_stack || echo "[i] Python disabled; skipping" ;;
    7) [[ "$ENABLE_POWERSHELL" == "1" ]] && powershell_core || echo "[i] PowerShell disabled; skipping" ;;
    8) if [[ "$ENABLE_POWERSHELL" == "1" && "$ENABLE_AZ_PWSH_MODULES" == "1" ]]; then install_pwsh_az_modules; else echo "[i] Az modules disabled or pwsh disabled; skipping"; fi ;;
    9) [[ "$ENABLE_CLOUD_CLIS" == "1" ]] && cloud_clis || echo "[i] Cloud CLIs disabled; skipping" ;;
    10) install_brave ;;
    11) install_cursor ;;
    12) shell_setup ;;
    13) verify ;;
    *) echo "[!] Unknown step: $1"; return 1 ;;
  esac
  DONE["$1"]=1
}

print_features() {
  echo "Features: PY=$ENABLE_PYTHON | PS=$ENABLE_POWERSHELL | AZ=$ENABLE_AZ_PWSH_MODULES (rollup=$FULL_AZ_MODULE_ROLLUP) | CLOUD=$ENABLE_CLOUD_CLIS | DOCKER_ROOTLESS=$ENABLE_ROOTLESS_DOCKER"
}

toggle_features() {
  echo
  echo "Toggle features (current):"; print_features
  read -rp "Toggle Python? (y/N): " a; [[ "${a,,}" == "y" ]] && ENABLE_PYTHON=$((1-ENABLE_PYTHON))
  read -rp "Toggle PowerShell? (y/N): " a; [[ "${a,,}" == "y" ]] && ENABLE_POWERSHELL=$((1-ENABLE_POWERSHELL))
  read -rp "Toggle Azure PS modules? (y/N): " a; [[ "${a,,}" == "y" ]] && ENABLE_AZ_PWSH_MODULES=$((1-ENABLE_AZ_PWSH_MODULES))
  read -rp "Use full Az roll-up (all modules)? (y/N): " a; [[ "${a,,}" == "y" ]] && FULL_AZ_MODULE_ROLLUP=1 || FULL_AZ_MODULE_ROLLUP=0
  read -rp "Toggle Cloud CLIs? (y/N): " a; [[ "${a,,}" == "y" ]] && ENABLE_CLOUD_CLIS=$((1-ENABLE_CLOUD_CLIS))
  read -rp "Use Docker rootless instead of group mode? (y/N): " a; [[ "${a,,}" == "y" ]] && ENABLE_ROOTLESS_DOCKER=1 || ENABLE_ROOTLESS_DOCKER=0
  echo "Updated:"; print_features
}

run_all() {
  ensure_dirs; require_network; apt_base; is_virtualbox && install_vbox_guest || true
  if [[ "$ENABLE_ROOTLESS_DOCKER" == "1" ]]; then run_step 3; else run_step 2; fi
  run_step 4; run_step 5; run_step 6; run_step 7; run_step 8; run_step 9; run_step 10; run_step 11; run_step 12; run_step 13
}

run_next() {
  while [[ $NEXT_IDX -lt ${#ORDER[@]} ]]; do
    local s="${ORDER[$NEXT_IDX]}"
    if [[ "$s" == "2" && "$ENABLE_ROOTLESS_DOCKER" == "1" ]]; then
      run_step 3; ((NEXT_IDX++)); return
    fi
    if [[ -z "${DONE[$s]:-}" ]]; then run_step "$s"; ((NEXT_IDX++)); return; fi
    ((NEXT_IDX++))
  done
  echo "[i] All default steps done."
}

show_menu() {
  echo
  print_features
  echo
  echo "Select:"
  for i in "${!STEPS[@]}"; do printf " %2s) %s\n" "$i" "${STEPS[$i]}"; done | sort -n
  cat <<'EOF'
  a) Run ALL (respecting toggles)
  n) Run NEXT step in default order
  t) Toggle features
  s) Show status/versions
  q) Quit
EOF
  echo
}

# ===== Main =====
need_root

while true; do
  show_menu
  read -rp "Choice: " choice
  case "${choice,,}" in
    a) run_all ;;
    n) run_next ;;
    t) toggle_features ;;
    s) verify ;;
    q) break ;;
    ''|*[!0-9]*) 
       if [[ "${choice,,}" != "a" && "${choice,,}" != "n" && "${choice,,}" != "t" && "${choice,,}" != "s" && "${choice,,}" != "q" ]]; then
         echo "[!] Unknown choice"
       fi
       ;;
    *)
       if [[ -n "${STEPS[$choice]:-}" ]]; then run_step "$choice"; else echo "[!] Invalid step number"; fi
       ;;
  esac
done

final_cleanup
echo
echo "[✓] Done."
if [[ "$ENABLE_ROOTLESS_DOCKER" == "1" ]]; then
  echo "- Rootless Docker enabled. Open a NEW shell so DOCKER_HOST is exported. Test: 'docker info'."
else
  echo "- If Docker was just installed, re-login so '$USER_NAME' can run docker without sudo."
fi
echo "- Smoke tests: 'docker run --rm hello-world' and 'kind create cluster'."
