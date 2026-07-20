#!/bin/bash
set -euo pipefail
[[ "${DEBUG:-}" == "true" ]] && set -x
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/setup_script.log"
STATE_FILE="/root/.setup_state"
touch "$STATE_FILE"

handle_error() {
  local exit_code=$?
  local line_number=$1
  echo "❌ Error occurred at line $line_number. Exit code: $exit_code" | tee -a "$LOG_FILE"
  exit $exit_code
}
cleanup() {
  :
}
trap 'handle_error $LINENO' ERR
trap cleanup EXIT

log_step() { echo "🔄 $1" | tee -a "$LOG_FILE"; }
log_success() { echo "✅ $1" | tee -a "$LOG_FILE"; }
log_error() { echo "❌ $1" | tee -a "$LOG_FILE" >&2; }
run_cmd() { echo "   ▶ $*" | tee -a "$LOG_FILE"; eval "$@"; }

# --- idempotency helpers ---
step_done() { grep -qx "$1" "$STATE_FILE" 2>/dev/null; }
mark_done() { echo "$1" >> "$STATE_FILE"; }

validate_password() {
  local password=$1
  if [[ ${#password} -lt 8 ]]; then
    echo "Password must be at least 8 characters long."; return 1
  fi
  if ! [[ $password =~ [A-Za-z] && $password =~ [0-9] ]]; then
    echo "Password must contain both letters and numbers."; return 1
  fi
  return 0
}

if [[ "$EUID" -ne 0 ]]; then
  log_error "This script must be run as root."
  exit 1
fi

# Backups (always safe to re-run, but skip if already done)
if ! step_done "backup"; then
  log_step "Creating backup of important configuration files"
  BACKUP_DIR="/root/pre_install_backup_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  for file in /etc/passwd /etc/shadow /etc/group /etc/sudoers /etc/sudoers.d; do
    [[ -e "$file" ]] && cp -r "$file" "$BACKUP_DIR" || echo "Skipping $file" | tee -a "$LOG_FILE"
  done
  log_success "Backup created at $BACKUP_DIR"
  mark_done "backup"
else
  log_success "Backup already done, skipping"
fi

# Step 1: Prompt for sudo username (reuse if exists, create if not)
read -rp "Enter a sudo username (default: goodmin): " sudo_user
sudo_user=${sudo_user:-goodmin}

if id -u "$sudo_user" &>/dev/null; then
  log_success "User '$sudo_user' already exists. Using existing user."
else
  log_step "Creating new sudo user '$sudo_user'"
  run_cmd useradd -m -s /bin/bash "$sudo_user" || { log_error "Failed to create user '$sudo_user'."; exit 1; }
  echo "$sudo_user ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/$sudo_user"
  chmod 0440 "/etc/sudoers.d/$sudo_user"

  while true; do
    read -s -p "Enter password for '$sudo_user': " password; echo
    if ! validate_password "$password"; then continue; fi
    read -s -p "Confirm password: " password_confirm; echo
    [[ "$password" == "$password_confirm" ]] && {
      echo "$sudo_user:$password" | chpasswd
      log_success "Password set."
      unset password password_confirm
      break
    } || echo "Mismatch. Try again."
  done
fi

# Step 2: System update
if ! step_done "system_update"; then
  log_step "Updating system"
  run_cmd apt-get update -y
  run_cmd apt-get upgrade -y
  run_cmd apt-get install -y curl btop tmux ca-certificates gnupg lsb-release gcc wget
  log_success "System updated"
  mark_done "system_update"
else
  log_success "System already updated, skipping"
fi

# Step 3: Select stack
while true; do
  read -rp "Install LAMP (Apache) or LEMP (Nginx)? (LAMP/LEMP): " stack_choice
  stack_choice=$(echo "$stack_choice" | tr '[:lower:]' '[:upper:]')
  [[ "$stack_choice" == "LAMP" || "$stack_choice" == "LEMP" ]] && break || echo "Enter LAMP or LEMP."
done

# Step 4: Hostname
read -rp "Enter hostname (default: debian-server): " hostname
hostname=${hostname:-debian-server}
if ! [[ "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
  log_error "Invalid hostname '$hostname'. Must be a valid DNS label."
  exit 1
fi
run_cmd hostnamectl set-hostname "$hostname"
log_success "Hostname set to $hostname"

# Step 5: Virtualmin install
if ! step_done "virtualmin"; then
  log_step "Installing Virtualmin ($stack_choice)"
  export VIRTUALMIN_NONINTERACTIVE=1
  run_cmd "curl -fsSL https://download.virtualmin.com/virtualmin-install | sh -s -- --force --bundle \"$stack_choice\" --hostname \"$hostname\""
  log_success "Virtualmin installed"
  mark_done "virtualmin"
else
  log_success "Virtualmin already installed, skipping"
fi

# Step 5.1: Fix Virtualmin repo "arch=all" (ARM only)
if [[ "$(uname -m)" == "aarch64" ]] && ! step_done "virtualmin_arch_fix"; then
  log_step "Fixing Virtualmin repo arch setting (ARM)"
  sed -i 's|deb \[signed-by|deb [arch=all signed-by|' /etc/apt/sources.list.d/virtualmin.list
  log_success "Fixed Virtualmin repo arch setting for ARM"
  mark_done "virtualmin_arch_fix"
fi

# Step 5.2: ARM postfix fix
if [[ "$(uname -m)" == "aarch64" ]] && ! step_done "arm_postfix_fix"; then
  log_step "Applying Virtualmin ARM postfix fix"
  pushd /root >/dev/null
  wget -q https://software.virtualmin.com/lib/procmail-wrapper.c
  gcc procmail-wrapper.c -o procmail-wrapper
  [[ -f /usr/bin/procmail-wrapper ]] && mv /usr/bin/procmail-wrapper /usr/bin/procmail-wrapper.backup
  cp procmail-wrapper /usr/bin/procmail-wrapper
  chmod 4755 /usr/bin/procmail-wrapper
  popd >/dev/null
  log_success "ARM postfix fix applied"
  mark_done "arm_postfix_fix"
fi

# Step 6: Docker install (rootless, running as $sudo_user)
if ! step_done "docker"; then
  log_step "Installing rootless Docker for user '$sudo_user'"

  run_cmd apt-get install -y uidmap dbus-user-session slirp4netns

  # Enable lingering so the user's Docker daemon survives logout/reboot
  run_cmd loginctl enable-linger "$sudo_user"

  # Allow binding privileged ports (80/443) without root
  run_cmd sysctl -w net.ipv4.ip_unprivileged_port_start=80
  grep -q "^net.ipv4.ip_unprivileged_port_start" /etc/sysctl.conf 2>/dev/null || \
    echo "net.ipv4.ip_unprivileged_port_start=80" >> /etc/sysctl.conf

  run_cmd "su - \"$sudo_user\" -c \"curl -fsSL https://get.docker.com/rootless | sh\""

  UID_SUDO="$(id -u "$sudo_user")"
  RUNTIME_DIR="/run/user/$UID_SUDO"
  cat >> "/home/$sudo_user/.bashrc" << EOF

# Rootless Docker
export PATH=/home/$sudo_user/bin:\$PATH
export DOCKER_HOST=unix://$RUNTIME_DIR/docker.sock
EOF

  # Wait for the user's systemd/dbus session (created by enable-linger) to be ready
  # before asking systemctl --user to do anything, to avoid a "failed to connect to bus" race.
  log_step "Waiting for user session for '$sudo_user' to initialize"
  session_ready=false
  for i in $(seq 1 15); do
    if [[ -d "$RUNTIME_DIR" ]] && su - "$sudo_user" -c "XDG_RUNTIME_DIR=$RUNTIME_DIR systemctl --user status" &>/dev/null; then
      session_ready=true
      break
    fi
    sleep 1
  done
  if [[ "$session_ready" != true ]]; then
    log_error "User session for '$sudo_user' did not become ready after 15s; retrying enable-linger once."
    loginctl enable-linger "$sudo_user"
    sleep 3
  fi

  run_cmd "su - \"$sudo_user\" -c \"XDG_RUNTIME_DIR=$RUNTIME_DIR systemctl --user enable --now docker\""

  # Verify docker compose plugin is available; some rootless installs don't bundle it.
  log_step "Verifying docker compose plugin for '$sudo_user'"
  if su - "$sudo_user" -c "XDG_RUNTIME_DIR=$RUNTIME_DIR DOCKER_HOST=unix://$RUNTIME_DIR/docker.sock docker compose version" &>/dev/null; then
    log_success "docker compose plugin already available"
  else
    log_step "docker compose plugin missing, installing it for '$sudo_user'"
    ARCH="$(dpkg --print-architecture)"
    case "$ARCH" in
      amd64) COMPOSE_ARCH="x86_64" ;;
      arm64) COMPOSE_ARCH="aarch64" ;;
      *) COMPOSE_ARCH="$ARCH" ;;
    esac
    su - "$sudo_user" -c "mkdir -p ~/.docker/cli-plugins"
    run_cmd "su - \"$sudo_user\" -c \"curl -fsSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$COMPOSE_ARCH -o ~/.docker/cli-plugins/docker-compose\""
    su - "$sudo_user" -c "chmod +x ~/.docker/cli-plugins/docker-compose"
    if su - "$sudo_user" -c "XDG_RUNTIME_DIR=$RUNTIME_DIR DOCKER_HOST=unix://$RUNTIME_DIR/docker.sock docker compose version" &>/dev/null; then
      log_success "docker compose plugin installed successfully"
    else
      log_error "Failed to install docker compose plugin for '$sudo_user'."
      exit 1
    fi
  fi

  log_success "Rootless Docker installed for '$sudo_user'"
  mark_done "docker"
else
  log_success "Docker already installed, skipping"
fi

DOCKER_SOCK="/run/user/$(id -u "$sudo_user")/docker.sock"
run_as_user() {
  su - "$sudo_user" -c "export DOCKER_HOST=unix://$DOCKER_SOCK; export PATH=/home/$sudo_user/bin:\$PATH; $1"
}

# Step 7: Install Portainer
if ! step_done "portainer"; then
  log_step "Installing Portainer"
  (
    run_as_user "docker volume create portainer_data" || { log_error "Failed to create Portainer data volume."; exit 1; }
    log_success "Created Portainer data volume."

    su - "$sudo_user" -c "mkdir -p ~/portainer" || { log_error "Failed to create Portainer directory."; exit 1; }

    cat > "/home/$sudo_user/portainer/docker-compose.yaml" << EOF
name: Portainer
services:
  portainer-ce:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: always
    ports:
      - 127.0.0.1:8000:8000
      - 127.0.0.1:9443:9443
    volumes:
      - $DOCKER_SOCK:/var/run/docker.sock:ro
      - portainer_data:/data
volumes:
  portainer_data:
    external: true
    name: portainer_data
EOF

    chown "$sudo_user:$sudo_user" "/home/$sudo_user/portainer/docker-compose.yaml"

    log_step "Starting Portainer (docker compose up -d)"
    if ! run_as_user "cd ~/portainer && docker compose up -d"; then
      log_error "Failed to start Portainer."
      exit 1
    else
      log_success "Portainer started successfully."
    fi
  ) && mark_done "portainer"
else
  log_success "Portainer already installed, skipping"
fi

# Step 8: Prompt + Install NextCloud-AIO
read -rp "Do you want to install NextCloud-AIO? (y/n): " install_nc
if [[ "$install_nc" =~ ^[Yy]$ ]] && ! step_done "nextcloud"; then
  log_step "Installing NextCloud-AIO"

  su - "$sudo_user" -c "mkdir -p ~/nextcloud-aio"

  # NC data uses a Docker-managed named volume (nextcloud_aio_nextcloud_data,
  # created automatically by the mastercontainer) instead of a host bind mount.
  # This avoids rootless Docker's UID remapping breaking permissions on a host path.
  cat > "/home/$sudo_user/nextcloud-aio/docker-compose.yaml" << EOF
services:
  nextcloud-aio-mastercontainer:
    image: ghcr.io/nextcloud-releases/all-in-one:latest
    init: true
    restart: always
    container_name: nextcloud-aio-mastercontainer
    volumes:
      - nextcloud_aio_mastercontainer:/mnt/docker-aio-config
      - $DOCKER_SOCK:/var/run/docker.sock:ro
    ports:
      - 8080:8080
    environment:
      - APACHE_PORT=11222
      - APACHE_IP_BINDING=127.0.0.1
      - SKIP_DOMAIN_VALIDATION=true
      - NEXTCLOUD_STARTUP_APPS=twofactor_totp calendar contacts files_external
      - NEXTCLOUD_ENABLE_DRI_DEVICE=false
      - WATCHTOWER_DOCKER_SOCKET_PATH=$DOCKER_SOCK
volumes:
  nextcloud_aio_mastercontainer:
    name: nextcloud_aio_mastercontainer
EOF

  chown "$sudo_user:$sudo_user" "/home/$sudo_user/nextcloud-aio/docker-compose.yaml"
  log_step "Starting NextCloud AIO (docker compose up -d)"
  run_as_user "cd ~/nextcloud-aio && docker compose up -d"
  log_success "NextCloud AIO started successfully."
  mark_done "nextcloud"
elif [[ "$install_nc" =~ ^[Yy]$ ]]; then
  log_success "NextCloud-AIO already installed, skipping"
fi

# Cleanup apt cache
apt-get autoremove -y && apt-get clean

# Final Step: Display summary
log_step "Installation complete!"
echo "-----------------------------" | tee -a "$LOG_FILE"
echo "Software    | Purpose" | tee -a "$LOG_FILE"
echo "------------|-------------------------------------" | tee -a "$LOG_FILE"
echo "Virtualmin  | Web hosting control panel" | tee -a "$LOG_FILE"
echo "Docker      | Containerization platform" | tee -a "$LOG_FILE"
echo "Portainer   | Docker management UI" | tee -a "$LOG_FILE"
[[ "$install_nc" =~ ^[Yy]$ ]] && echo "NextCloud   | File sync & collaboration" | tee -a "$LOG_FILE"
echo "-----------------------------" | tee -a "$LOG_FILE"
echo ""
echo "Access URLs:" | tee -a "$LOG_FILE"
echo "Virtualmin: https://$hostname:10000" | tee -a "$LOG_FILE"
echo "Portainer: https://127.0.0.1:9443 (loopback only — use SSH tunnel or reverse proxy for remote access)" | tee -a "$LOG_FILE"
[[ "$install_nc" =~ ^[Yy]$ ]] && echo "NextCloud AIO: https://$hostname:8080" | tee -a "$LOG_FILE"
echo "Installation completed successfully!" | tee -a "$LOG_FILE"
