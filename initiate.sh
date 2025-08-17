#!/bin/bash
set -euo pipefail
[[ "${DEBUG:-}" == "true" ]] && set -x

LOG_FILE="/var/log/setup_script.log"

handle_error() { local ec=$?; local ln=$1; echo "❌ Error at line $ln, exit $ec" | tee -a "$LOG_FILE"; exit $ec; }
cleanup() { rm -f virtualmin-install.sh; }
trap 'handle_error $LINENO; cleanup' ERR
trap cleanup EXIT

log_step() { echo -e "\n🔄 $1" | tee -a "$LOG_FILE"; }
log_success() { echo "✅ $1" | tee -a "$LOG_FILE"; }
log_error() { echo "❌ $1" | tee -a "$LOG_FILE" >&2; return 1; }

validate_password() {
  [[ ${#1} -ge 8 && $1 =~ [A-Za-z] && $1 =~ [0-9] ]]
}

# Ensure root
[[ "$EUID" -ne 0 ]] && { log_error "Run as root."; exit 1; }

# === Backup configs ===
log_step "Backing up configs"
BACKUP_DIR="/root/pre_install_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
for f in /etc/passwd /etc/shadow /etc/group /etc/sudoers /etc/sudoers.d; do [[ -e "$f" ]] && cp -r "$f" "$BACKUP_DIR"; done
log_success "Backups stored in $BACKUP_DIR"

# === Prompt sudo user ===
read -rp "Enter a sudo username (default: goodmin): " sudo_user
sudo_user=${sudo_user:-goodmin}

log_step "Creating sudo user '$sudo_user'"
if id -u "$sudo_user" &>/dev/null; then
  log_success "User '$sudo_user' exists."
else
  useradd -m -s /bin/bash "$sudo_user"
  echo "$sudo_user ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$sudo_user"
  chmod 0440 "/etc/sudoers.d/$sudo_user"
  while true; do
    read -s -p "Enter password for '$sudo_user': " pw; echo
    validate_password "$pw" || { echo "❌ Weak password. Retry."; continue; }
    read -s -p "Confirm password: " pw2; echo
    [[ "$pw" == "$pw2" ]] && { echo "$sudo_user:$pw" | chpasswd; break; } || echo "❌ Mismatch. Retry."
  done
  log_success "User '$sudo_user' created."
fi

# === Update system ===
log_step "System update"
apt-get update -y && apt-get upgrade -y
apt-get install -y curl btop tmux ca-certificates gnupg lsb-release gcc
log_success "System updated"

# === Select stack ===
while true; do
  read -rp "Install LAMP (Apache) or LEMP (Nginx)? (LAMP/LEMP): " stack
  stack=$(echo "$stack" | tr '[:lower:]' '[:upper:]')
  [[ "$stack" =~ ^(LAMP|LEMP)$ ]] && break || echo "Enter LAMP or LEMP."
done

# === Hostname ===
read -rp "Enter hostname (default: debian-server): " hostname
hostname=${hostname:-debian-server}
hostnamectl set-hostname "$hostname"
log_success "Hostname set to $hostname"

# === Virtualmin ===
log_step "Installing Virtualmin ($stack)"
export VIRTUALMIN_NONINTERACTIVE=1
curl -fsSL https://software.virtualmin.com/gpl/scripts/virtualmin-install.sh -o virtualmin-install.sh
chmod +x virtualmin-install.sh
./virtualmin-install.sh --force --bundle "$stack" --hostname "$hostname"
log_success "Virtualmin installed"

# Fix Virtualmin repo line
sed -i 's|deb \[signed-by=/usr/share/keyrings/debian-virtualmin-7.gpg\]|deb [arch=all signed-by=/usr/share/keyrings/debian-virtualmin-7.gpg]|' /etc/apt/sources.list.d/virtualmin.list
log_success "Fixed Virtualmin repo arch"

# ARM postfix fix
if [[ "$(uname -m)" == "aarch64" ]]; then
  log_step "Applying ARM postfix fix"
  cwd=$(pwd)
  cd /root
  wget -q https://software.virtualmin.com/lib/procmail-wrapper.c
  gcc procmail-wrapper.c -o procmail-wrapper
  mv /usr/bin/procmail-wrapper /usr/bin/procmail-wrapper.backup
  cp procmail-wrapper /usr/bin/procmail-wrapper
  chmod 4755 /usr/bin/procmail-wrapper
  cd "$cwd"   # return to original directory
  log_success "ARM postfix fix applied"
fi

# === Docker ===
log_step "Installing Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker "$sudo_user"
log_success "Docker installed & user added to group"

# Detect arch for docker images
arch=$(uname -m)
case "$arch" in
  x86_64) portainer_img="portainer/portainer-ce:lts" ;;
  aarch64|arm64) portainer_img="portainer/portainer-ce:linux-arm64" ;;
  armv7l) portainer_img="portainer/portainer-ce:linux-arm" ;;
  *) portainer_img="portainer/portainer-ce:lts" ;;
esac
log_success "Docker images selected for $arch"

# === Portainer ===
log_step "Installing Portainer"
su - "$sudo_user" -c "mkdir -p ~/portainer"
cat > "/home/$sudo_user/portainer/docker-compose.yaml" << EOF
name: Portainer
services:
  portainer-ce:
    image: $portainer_img
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
su - "$sudo_user" -c "cd ~/portainer && docker compose up -d"
log_success "Portainer running"

# === NextCloud AIO (Optional) ===
read -rp "Do you want to install NextCloud AIO? (y/n): " install_nc
if [[ "$install_nc" =~ ^[Yy]$ ]]; then
  log_step "Installing NextCloud AIO"
  mkdir -p /mnt/ncdata
  chown "$sudo_user:$sudo_user" /mnt/ncdata
  chmod 750 /mnt/ncdata
  su - "$sudo_user" -c "mkdir -p ~/nextcloud-aio"
  cat > "/home/$sudo_user/nextcloud-aio/docker-compose.yaml" << EOF
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
  log_success "NextCloud AIO running"
else
  log_step "Skipping NextCloud installation"
fi

# === Final summary ===
echo -e "\n✅ Installation complete!"
echo "Virtualmin: https://$hostname:10000"
echo "Portainer:  https://127.0.0.1:9443"
[[ "$install_nc" =~ ^[Yy]$ ]] && echo "NextCloud:  http://127.0.0.1:8080"
echo "SSH:        Port 2022 (key-based only)"
