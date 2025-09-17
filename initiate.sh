#!/bin/bash
set -euo pipefail
[[ "${DEBUG:-}" == "true" ]] && set -x

LOG_FILE="/var/log/setup_script.log"

handle_error() {
  local exit_code=$?
  local line_number=$1
  echo "❌ Error occurred at line $line_number. Exit code: $exit_code" | tee -a "$LOG_FILE"
  exit $exit_code
}
cleanup() {
  rm -f virtualmin-install.sh
}
trap 'handle_error $LINENO; cleanup' ERR
trap cleanup EXIT

log_step() { echo "🔄 $1" | tee -a "$LOG_FILE"; }
log_success() { echo "✅ $1" | tee -a "$LOG_FILE"; }
log_error() { echo "❌ $1" | tee -a "$LOG_FILE" >&2; return 1; }

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

if [[ "$EUID" -ne 0 ]]; then log_error "This script must be run as root."; exit 1; fi

# Backups
log_step "Creating backup of important configuration files"
BACKUP_DIR="/root/pre_install_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
for file in /etc/passwd /etc/shadow /etc/group /etc/sudoers /etc/sudoers.d; do
  [[ -e "$file" ]] && cp -r "$file" "$BACKUP_DIR" || echo "Skipping $file" | tee -a "$LOG_FILE"
done
log_success "Backup created at $BACKUP_DIR"

# Step 1: Prompt for sudo username
read -rp "Enter a sudo username (default: goodmin): " sudo_user
sudo_user=${sudo_user:-goodmin}
log_step "Creating new sudo user '$sudo_user'"
if id -u "$sudo_user" &>/dev/null; then
  log_success "User '$sudo_user' already exists."
else
  useradd -m -s /bin/bash "$sudo_user" || log_error "Failed to create user '$sudo_user'."
  echo "$sudo_user ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$sudo_user"
  chmod 0440 "/etc/sudoers.d/$sudo_user"

  while true; do
    read -s -p "Enter password for '$sudo_user': " password; echo
    if ! validate_password "$password"; then continue; fi
    read -s -p "Confirm password: " password_confirm; echo
    [[ "$password" == "$password_confirm" ]] && { echo "$sudo_user:$password" | chpasswd; log_success "Password set."; break; } || echo "Mismatch. Try again."
  done
fi

# Step 2: System update
log_step "Updating system"
apt-get update -y && apt-get upgrade -y
apt-get install -y curl btop tmux ca-certificates gnupg lsb-release gcc wget
log_success "System updated"

# Step 3: Select stack
while true; do
  read -rp "Install LAMP (Apache) or LEMP (Nginx)? (LAMP/LEMP): " stack_choice
  stack_choice=$(echo "$stack_choice" | tr '[:lower:]' '[:upper:]')
  [[ "$stack_choice" == "LAMP" || "$stack_choice" == "LEMP" ]] && break || echo "Enter LAMP or LEMP."
done

# Step 4: Hostname
read -rp "Enter hostname (default: debian-server): " hostname
hostname=${hostname:-debian-server}
hostnamectl set-hostname "$hostname"
log_success "Hostname set to $hostname"

# Step 5: Virtualmin install
log_step "Installing Virtualmin ($stack_choice)"
export VIRTUALMIN_NONINTERACTIVE=1
curl -fsSL https://software.virtualmin.com/gpl/scripts/virtualmin-install.sh -o virtualmin-install.sh
chmod +x virtualmin-install.sh
./virtualmin-install.sh --force --bundle "$stack_choice" --hostname "$hostname"
log_success "Virtualmin installed"

# Step 5.1: Fix Virtualmin repo "arch=all"
sed -i 's|deb \[signed-by|deb [arch=all signed-by|' /etc/apt/sources.list.d/virtualmin.list
log_success "Fixed Virtualmin repo arch setting"

# Step 5.2: ARM postfix fix
if [[ "$(uname -m)" == "aarch64" ]]; then
  log_step "Applying Virtualmin ARM postfix fix"
  pushd /root >/dev/null
  wget -q https://software.virtualmin.com/lib/procmail-wrapper.c
  gcc procmail-wrapper.c -o procmail-wrapper
  mv /usr/bin/procmail-wrapper /usr/bin/procmail-wrapper.backup
  cp procmail-wrapper /usr/bin/procmail-wrapper
  chmod 4755 /usr/bin/procmail-wrapper
  popd >/dev/null
  log_success "ARM postfix fix applied"
fi

# Step 6: Docker install
log_step "Installing Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
log_success "Docker installed"

# Add user to docker group
usermod -aG docker "$sudo_user"
log_success "User '$sudo_user' added to docker group"

# Step 7: Install Portainer
log_step "Installing Portainer"
(
  docker volume create portainer_data || { log_error "Failed to create Portainer data volume."; exit 1; }
  log_success "Created Portainer data volume."

  su - "$sudo_user" -c "mkdir -p ~/portainer" || { log_error "Failed to create Portainer directory."; exit 1; }

  cat > "/home/$sudo_user/portainer/docker-compose.yaml" << 'EOF'
name: Portainer
services:
  portainer-ce:
    image: portainer/portainer-ce:lts
    container_name: portainer
    restart: always
    ports:
      - 127.0.0.1:8000:8000
      - 127.0.0.1:9443:9443
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
volumes:
  portainer_data:
    external: true
    name: portainer_data
EOF

  chown "$sudo_user:$sudo_user" "/home/$sudo_user/portainer/docker-compose.yaml" || { log_error "Failed to set ownership of Portainer docker-compose file."; exit 1; }
  if ! su - "$sudo_user" -c "cd ~/portainer && docker compose up -d"; then
    log_error "Failed to start Portainer. Continuing to next step."
  else
    log_success "Portainer started successfully."
  fi
) || true

# Step 8: Prompt + Install NextCloud-AIO
read -rp "Do you want to install NextCloud-AIO? (y/n): " install_nc
if [[ "$install_nc" =~ ^[Yy]$ ]]; then
  log_step "Installing NextCloud-AIO"

  mkdir -p /mnt/ncdata
  chown "$sudo_user:$sudo_user" /mnt/ncdata
  chmod 750 /mnt/ncdata
  log_success "Created NextCloud data directory with proper permissions."

  su - "$sudo_user" -c "mkdir -p ~/nextcloud-aio"

  cat > "/home/$sudo_user/nextcloud-aio/docker-compose.yaml" << 'EOF'
services:
  nextcloud-aio-mastercontainer:
    image: nextcloud/all-in-one:latest
    init: true
    restart: always
    container_name: nextcloud-aio-mastercontainer
    volumes:
      - nextcloud_aio_mastercontainer:/mnt/docker-aio-config
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports:
      - 127.0.0.1:8080:8080
    environment:
      - APACHE_PORT=11222
      - APACHE_IP_BINDING=127.0.0.1
      - SKIP_DOMAIN_VALIDATION=true
      - NEXTCLOUD_DATADIR=/mnt/ncdata
      - NEXTCLOUD_MOUNT=/mnt/
      - NEXTCLOUD_STARTUP_APPS=twofactor_totp calendar contacts files_external
      - NEXTCLOUD_ENABLE_DRI_DEVICE=false
volumes:
  nextcloud_aio_mastercontainer:
    name: nextcloud_aio_mastercontainer
EOF

  chown "$sudo_user:$sudo_user" "/home/$sudo_user/nextcloud-aio/docker-compose.yaml"

  su - "$sudo_user" -c "cd ~/nextcloud-aio && docker compose up -d"
  log_success "NextCloud AIO started successfully."
fi

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
echo "Portainer: https://127.0.0.1:9443" | tee -a "$LOG_FILE"
[[ "$install_nc" =~ ^[Yy]$ ]] && echo "NextCloud AIO: http://127.0.0.1:8080" | tee -a "$LOG_FILE"
echo "Installation completed successfully!" | tee -a "$LOG_FILE"
