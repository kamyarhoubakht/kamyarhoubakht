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

if [[ "$EUID" -ne 0 ]]; then
  log_error "This script must be run as root."
  exit 1
fi

# --------------------------------------------------
# SELinux: set permissive (best balance for Docker)
# --------------------------------------------------
log_step "Setting SELinux to permissive mode"
if command -v getenforce &>/dev/null; then
  setenforce 0 || true
  sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
  log_success "SELinux set to permissive"
else
  log_step "SELinux not present, skipping"
fi

# --------------------------------------------------
# Backups
# --------------------------------------------------
log_step "Creating backup of important configuration files"
BACKUP_DIR="/root/pre_install_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
for file in /etc/passwd /etc/shadow /etc/group /etc/sudoers /etc/sudoers.d; do
  [[ -e "$file" ]] && cp -r "$file" "$BACKUP_DIR" || echo "Skipping $file" | tee -a "$LOG_FILE"
done
log_success "Backup created at $BACKUP_DIR"

# --------------------------------------------------
# Step 1: Sudo user
# --------------------------------------------------
read -rp "Enter a sudo username (default: goodmin): " sudo_user
sudo_user=${sudo_user:-goodmin}

if id -u "$sudo_user" &>/dev/null; then
  log_success "User '$sudo_user' already exists. Using existing user."
else
  log_step "Creating new sudo user '$sudo_user'"
  useradd -m -s /bin/bash "$sudo_user"
  echo "$sudo_user ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$sudo_user"
  chmod 0440 "/etc/sudoers.d/$sudo_user"

  while true; do
    read -s -p "Enter password for '$sudo_user': " password; echo
    validate_password "$password" || continue
    read -s -p "Confirm password: " password_confirm; echo
    [[ "$password" == "$password_confirm" ]] && {
      echo "$sudo_user:$password" | chpasswd
      log_success "Password set."
      break
    } || echo "Mismatch. Try again."
  done
fi

# --------------------------------------------------
# Step 2: System update (Rocky Linux)
# --------------------------------------------------
log_step "Updating system"
dnf -y update
dnf -y install epel-release
dnf -y install curl wget tmux btop ca-certificates gnupg2 gcc policycoreutils-python-utils
log_success "System updated"

# --------------------------------------------------
# Step 3: Stack selection
# --------------------------------------------------
while true; do
  read -rp "Install LAMP (Apache) or LEMP (Nginx)? (LAMP/LEMP): " stack_choice
  stack_choice=$(echo "$stack_choice" | tr '[:lower:]' '[:upper:]')
  [[ "$stack_choice" == "LAMP" || "$stack_choice" == "LEMP" ]] && break || echo "Enter LAMP or LEMP."
done

# --------------------------------------------------
# Step 4: Hostname
# --------------------------------------------------
read -rp "Enter hostname (default: rocky-server): " hostname
hostname=${hostname:-rocky-server}
hostnamectl set-hostname "$hostname"
log_success "Hostname set to $hostname"

# --------------------------------------------------
# Step 5: Virtualmin
# --------------------------------------------------
log_step "Installing Virtualmin ($stack_choice)"
export VIRTUALMIN_NONINTERACTIVE=1
curl -fsSL https://download.virtualmin.com/virtualmin-install.sh -o virtualmin-install.sh
chmod +x virtualmin-install.sh
./virtualmin-install.sh --force --bundle "$stack_choice" --hostname "$hostname"
log_success "Virtualmin installed"

# --------------------------------------------------
# Step 6: Docker CE (official repo)
# --------------------------------------------------
log_step "Installing Docker CE"

dnf -y remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine || true

dnf -y install dnf-plugins-core
dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo

dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker
log_success "Docker installed and started"

usermod -aG docker "$sudo_user"
log_success "User '$sudo_user' added to docker group"

# --------------------------------------------------
# Step 7: Portainer
# --------------------------------------------------
log_step "Installing Portainer"

docker volume create portainer_data

su - "$sudo_user" -c "mkdir -p ~/portainer"

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

chown "$sudo_user:$sudo_user" "/home/$sudo_user/portainer/docker-compose.yaml"
su - "$sudo_user" -c "cd ~/portainer && docker compose up -d" || true
log_success "Portainer started"

# --------------------------------------------------
# Step 8: Nextcloud AIO
# --------------------------------------------------
read -rp "Do you want to install NextCloud-AIO? (y/n): " install_nc
if [[ "$install_nc" =~ ^[Yy]$ ]]; then
  log_step "Installing NextCloud-AIO"

  mkdir -p /mnt/ncdata
  chown "$sudo_user:$sudo_user" /mnt/ncdata
  chmod 750 /mnt/ncdata

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
      - 8080:8080
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
  log_success "NextCloud AIO started"
fi

# --------------------------------------------------
# Summary
# --------------------------------------------------
log_step "Installation complete!"
echo "Virtualmin: https://$hostname:10000"
echo "Portainer: https://127.0.0.1:9443"
[[ "$install_nc" =~ ^[Yy]$ ]] && echo "NextCloud AIO: https://$hostname:8080"
