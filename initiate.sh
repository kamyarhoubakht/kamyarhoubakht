#!/bin/bash
set -euo pipefail

[[ "${DEBUG:-}" == "true" ]] && set -x
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/setup_script.log"
STATE_FILE="/root/.setup_state"

touch "$STATE_FILE"
chmod 600 "$STATE_FILE"

handle_error() {
    local exit_code=$?
    local line_number=$1
    echo "❌ Error occurred at line $line_number. Exit code: $exit_code" | tee -a "$LOG_FILE"
    exit "$exit_code"
}

cleanup() {
    :
}

trap 'handle_error $LINENO' ERR
trap cleanup EXIT

log_step() {
    echo "🔄 $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo "✅ $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "❌ $1" | tee -a "$LOG_FILE" >&2
}

step_done() {
    grep -qxF "$1" "$STATE_FILE" 2>/dev/null
}

mark_done() {
    grep -qxF "$1" "$STATE_FILE" 2>/dev/null || echo "$1" >> "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    log_error "This script must be run as root."
    exit 1
fi

# ---------------------------------------------------------------------------
# Detect OS
# ---------------------------------------------------------------------------

if [[ ! -f /etc/os-release ]]; then
    log_error "Cannot determine operating system."
    exit 1
fi

. /etc/os-release

OS_ID="${ID:-}"
OS_VERSION_ID="${VERSION_ID:-}"
OS_CODENAME="${VERSION_CODENAME:-}"

log_step "Detected operating system: ${PRETTY_NAME:-unknown}"

if [[ "$OS_ID" != "debian" ]]; then
    log_error "This script is intended for Debian. Detected: ${OS_ID:-unknown}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Architecture check
# ---------------------------------------------------------------------------

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
    amd64|arm64|armhf)
        log_success "Supported architecture detected: $ARCH"
        ;;
    *)
        log_error "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Backup important configuration
# ---------------------------------------------------------------------------

if ! step_done "backup"; then
    log_step "Creating backup of important configuration files"

    BACKUP_DIR="/root/pre_install_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    for file in \
        /etc/passwd \
        /etc/shadow \
        /etc/group \
        /etc/gshadow \
        /etc/sudoers \
        /etc/sudoers.d \
        /root/.ssh
    do
        if [[ -e "$file" ]]; then
            cp -a "$file" "$BACKUP_DIR/"
        else
            echo "Skipping $file" | tee -a "$LOG_FILE"
        fi
    done

    log_success "Backup created at $BACKUP_DIR"
    mark_done "backup"
else
    log_success "Backup already done, skipping"
fi

# ---------------------------------------------------------------------------
# Verify root SSH keys
#
# We use the existing root authorized_keys to give the new administrator
# account SSH-key access. No password is created or requested.
# ---------------------------------------------------------------------------

ROOT_AUTH_KEYS="/root/.ssh/authorized_keys"

if [[ ! -s "$ROOT_AUTH_KEYS" ]]; then
    log_error "No /root/.ssh/authorized_keys found."
    log_error "The script will not create a password-based administrator."
    log_error "Install your SSH key for root first, then run this script again."
    exit 1
fi

log_success "Root SSH authorized_keys found."

# ---------------------------------------------------------------------------
# Step 1: Create administrator user
# ---------------------------------------------------------------------------

if ! step_done "admin_user"; then

    read -rp "Enter administrator username (default: goodmin): " sudo_user
    sudo_user="${sudo_user:-goodmin}"

    if ! [[ "$sudo_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        log_error "Invalid username: $sudo_user"
        exit 1
    fi

    if [[ "$sudo_user" == "root" ]]; then
        log_error "The administrator username cannot be root."
        exit 1
    fi

    if id -u "$sudo_user" &>/dev/null; then
        log_success "User '$sudo_user' already exists."
    else
        log_step "Creating administrator user '$sudo_user'"

        useradd \
            --create-home \
            --shell /bin/bash \
            "$sudo_user"

        log_success "User '$sudo_user' created."
    fi

    # -----------------------------------------------------------------------
    # Passwordless sudo
    # -----------------------------------------------------------------------

    log_step "Configuring passwordless sudo for '$sudo_user'"

    cat > "/etc/sudoers.d/$sudo_user" <<EOF
$sudo_user ALL=(ALL:ALL) NOPASSWD:ALL
EOF

    chmod 0440 "/etc/sudoers.d/$sudo_user"

    if ! visudo -cf "/etc/sudoers.d/$sudo_user" >/dev/null; then
        log_error "Invalid sudoers configuration."
        rm -f "/etc/sudoers.d/$sudo_user"
        exit 1
    fi

    # -----------------------------------------------------------------------
    # Copy SSH authorized keys
    # -----------------------------------------------------------------------

    log_step "Installing SSH keys for '$sudo_user'"

    USER_HOME="$(getent passwd "$sudo_user" | cut -d: -f6)"
    USER_GROUP="$(id -gn "$sudo_user")"

    mkdir -p "$USER_HOME/.ssh"

    cp "$ROOT_AUTH_KEYS" "$USER_HOME/.ssh/authorized_keys"

    chown -R "$sudo_user:$USER_GROUP" "$USER_HOME/.ssh"

    chmod 700 "$USER_HOME/.ssh"
    chmod 600 "$USER_HOME/.ssh/authorized_keys"

    log_success "SSH keys copied to '$sudo_user'."

    # -----------------------------------------------------------------------
    # Add user to Docker group later if Docker is installed.
    # -----------------------------------------------------------------------

    mark_done "admin_user"

else
    log_success "Administrator user already configured, skipping."
fi

# ---------------------------------------------------------------------------
# Recover administrator username when re-running the script
# ---------------------------------------------------------------------------

if [[ -z "${sudo_user:-}" ]]; then
    read -rp "Enter administrator username (default: goodmin): " sudo_user
    sudo_user="${sudo_user:-goodmin}"
fi

if ! id -u "$sudo_user" &>/dev/null; then
    log_error "Administrator user '$sudo_user' does not exist."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Minimal system preparation
#
# Do NOT run apt upgrade before Virtualmin.
# Virtualmin expects a fresh supported OS and manages its own packages.
# ---------------------------------------------------------------------------

if ! step_done "system_prepare"; then

    log_step "Updating package lists"

    apt-get update

    log_step "Installing required bootstrap packages"

    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        btop \
        tmux \
        wget \
        lsb-release

    log_success "System preparation complete."

    mark_done "system_prepare"

else
    log_success "System preparation already completed, skipping."
fi

# ---------------------------------------------------------------------------
# Step 3: Debian 13 cloud-init handling
#
# Debian 13 currently declares cloud-init and firewalld as conflicting.
# Virtualmin needs Firewalld for its normal firewall/fail2ban setup.
#
# Only perform this removal on Debian 13.
# ---------------------------------------------------------------------------

if [[ "$OS_ID" == "debian" && "$OS_VERSION_ID" == "13" ]]; then

    if ! step_done "debian13_cloudinit"; then

        if dpkg-query -W -f='${Status}' cloud-init 2>/dev/null \
            | grep -q "install ok installed"; then

            log_step "Debian 13 detected: disabling cloud-init"

            # Stop any active cloud-init services.
            systemctl stop \
                cloud-init.service \
                cloud-init-local.service \
                cloud-config.service \
                cloud-final.service \
                2>/dev/null || true

            # Disable them if present.
            systemctl disable \
                cloud-init.service \
                cloud-init-local.service \
                cloud-config.service \
                cloud-final.service \
                2>/dev/null || true

            # Mask remaining units before removal.
            systemctl mask \
                cloud-init.service \
                cloud-init-local.service \
                cloud-config.service \
                cloud-final.service \
                2>/dev/null || true

            log_step "Removing cloud-init"

            apt-get purge -y cloud-init
            apt-get autoremove -y

            # Remove cloud-init state/configuration.
            rm -rf \
                /etc/cloud \
                /var/lib/cloud

            systemctl daemon-reload

            log_success "cloud-init removed from Debian 13."

        else
            log_success "cloud-init is not installed on Debian 13."
        fi

        mark_done "debian13_cloudinit"

    else
        log_success "Debian 13 cloud-init handling already completed, skipping."
    fi

else
    log_success "Not Debian 13 — cloud-init left untouched."
fi

# ---------------------------------------------------------------------------
# Step 4: Select Virtualmin stack
# ---------------------------------------------------------------------------

if ! step_done "stack_selected"; then

    while true; do
        read -rp "Install LAMP (Apache) or LEMP (Nginx)? (LAMP/LEMP): " stack_choice
        stack_choice="$(echo "$stack_choice" | tr '[:lower:]' '[:upper:]')"

        if [[ "$stack_choice" == "LAMP" || "$stack_choice" == "LEMP" ]]; then
            break
        fi

        echo "Please enter LAMP or LEMP."
    done

    echo "$stack_choice" > /root/.virtualmin_stack

    log_success "Selected Virtualmin stack: $stack_choice"

    mark_done "stack_selected"

else
    stack_choice="$(cat /root/.virtualmin_stack)"
    log_success "Using previously selected stack: $stack_choice"
fi

# ---------------------------------------------------------------------------
# Step 5: Hostname
#
# Virtualmin should use a fully qualified domain name.
# ---------------------------------------------------------------------------

if ! step_done "hostname"; then

    CURRENT_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"

    echo
    echo "Virtualmin requires a proper fully qualified hostname."
    echo "Example: server.example.com"
    echo

    read -rp "Enter hostname [$CURRENT_HOSTNAME]: " hostname
    hostname="${hostname:-$CURRENT_HOSTNAME}"

    # Lowercase hostname.
    hostname="$(echo "$hostname" | tr '[:upper:]' '[:lower:]')"

    # Validate FQDN.
    if ! [[ "$hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
        log_error "Invalid hostname: $hostname"
        log_error "Virtualmin requires a fully qualified domain name such as server.example.com"
        exit 1
    fi

    hostnamectl set-hostname "$hostname"

    echo "$hostname" > /root/.virtualmin_hostname

    log_success "Hostname set to $hostname"

    mark_done "hostname"

else
    hostname="$(cat /root/.virtualmin_hostname)"
    log_success "Using existing hostname: $hostname"
fi

# ---------------------------------------------------------------------------
# Step 6: Virtualmin installation
#
# Use the official current Virtualmin installer.
# No --force.
# No repository modifications.
# No ARM-specific workarounds.
# ---------------------------------------------------------------------------

if ! step_done "virtualmin"; then

    log_step "Installing current Virtualmin using official installer"

    export VIRTUALMIN_NONINTERACTIVE=1

    sh -c "$(curl -fsSL https://download.virtualmin.com/virtualmin-install)" \
        -- \
        --bundle "$stack_choice" \
        --hostname "$hostname"

    log_success "Virtualmin installed successfully."

    mark_done "virtualmin"

else
    log_success "Virtualmin already installed, skipping."
fi

# ---------------------------------------------------------------------------
# Step 7: Docker installation
#
# Use Docker's official Debian repository.
# Docker supports Debian 13/Trixie and multiple architectures.
# ---------------------------------------------------------------------------

OS_ID="$(. /etc/os-release && echo "$ID")"
OS_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
DOCKER_ARCH="$(dpkg --print-architecture)"

if ! step_done "docker"; then

    log_step "Installing Docker from the official Docker repository"

    # Remove conflicting distribution packages if present.
    apt-get remove -y \
        docker.io \
        docker-compose \
        docker-doc \
        podman-docker \
        containerd \
        runc \
        2>/dev/null || true

    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL \
        https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc

    chmod a+r /etc/apt/keyrings/docker.asc

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $OS_CODENAME
Components: stable
Architectures: $DOCKER_ARCH
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt-get update

    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker

    if ! systemctl is-active --quiet docker; then
        log_error "Docker service is not running."
        exit 1
    fi

    log_success "Docker installed and running."

    mark_done "docker"

else
    log_success "Docker already installed, skipping."
fi

# ---------------------------------------------------------------------------
# Add administrator to Docker group
# ---------------------------------------------------------------------------

usermod -aG docker "$sudo_user"

log_success "User '$sudo_user' added to the Docker group."

# ---------------------------------------------------------------------------
# Step 8: Portainer
#
# Use Portainer's multi-architecture LTS image.
# No architecture-specific image names are required.
# ---------------------------------------------------------------------------

if ! step_done "portainer"; then

    log_step "Installing Portainer"

    docker volume inspect portainer_data >/dev/null 2>&1 || \
        docker volume create portainer_data >/dev/null

    PORTAINER_DIR="/home/$sudo_user/portainer"

    mkdir -p "$PORTAINER_DIR"

    cat > "$PORTAINER_DIR/docker-compose.yaml" <<'EOF'
name: portainer

services:
  portainer-ce:
    image: portainer/portainer-ce:lts
    container_name: portainer
    restart: unless-stopped
    ports:
      - "127.0.0.1:8000:8000"
      - "127.0.0.1:9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - portainer_data:/data

volumes:
  portainer_data:
    external: true
    name: portainer_data
EOF

    chown -R "$sudo_user:$(id -gn "$sudo_user")" "$PORTAINER_DIR"

    (
        cd "$PORTAINER_DIR"
        docker compose up -d
    )

    if ! docker ps --format '{{.Names}}' | grep -qx "portainer"; then
        log_error "Portainer container failed to start."
        exit 1
    fi

    log_success "Portainer started successfully."

    mark_done "portainer"

else
    log_success "Portainer already installed, skipping."
fi

# ---------------------------------------------------------------------------
# Step 9: Optional Nextcloud AIO
# ---------------------------------------------------------------------------

install_nc="n"

if [[ -f /root/.nextcloud_choice ]]; then
    install_nc="$(cat /root/.nextcloud_choice)"
else
    read -rp "Do you want to install NextCloud-AIO? (y/n): " install_nc
    install_nc="$(echo "$install_nc" | tr '[:upper:]' '[:lower:]')"
    echo "$install_nc" > /root/.nextcloud_choice
fi

if [[ "$install_nc" =~ ^y$ ]] && ! step_done "nextcloud"; then

    log_step "Installing NextCloud-AIO"

    mkdir -p /mnt/ncdata

    chown "$sudo_user:$(id -gn "$sudo_user")" /mnt/ncdata
    chmod 750 /mnt/ncdata

    NEXTCLOUD_DIR="/home/$sudo_user/nextcloud-aio"

    mkdir -p "$NEXTCLOUD_DIR"

    cat > "$NEXTCLOUD_DIR/docker-compose.yaml" <<'EOF'
services:
  nextcloud-aio-mastercontainer:
    image: ghcr.io/nextcloud-releases/all-in-one:latest
    init: true
    restart: always
    container_name: nextcloud-aio-mastercontainer

    volumes:
      - nextcloud_aio_mastercontainer:/mnt/docker-aio-config
      - /var/run/docker.sock:/var/run/docker.sock:ro

    ports:
      - "8080:8080"

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

    chown -R "$sudo_user:$(id -gn "$sudo_user")" "$NEXTCLOUD_DIR"

    (
        cd "$NEXTCLOUD_DIR"
        docker compose up -d
    )

    log_success "NextCloud-AIO started successfully."

    mark_done "nextcloud"

elif [[ "$install_nc" =~ ^y$ ]]; then

    log_success "NextCloud-AIO already installed, skipping."

else

    log_success "NextCloud-AIO not selected."

fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

log_step "Cleaning package cache"

apt-get autoremove -y
apt-get clean

# ---------------------------------------------------------------------------
# Final verification
# ---------------------------------------------------------------------------

log_step "Running final verification"

if systemctl is-active --quiet docker; then
    log_success "Docker: running"
else
    log_error "Docker: NOT running"
fi

if systemctl is-active --quiet fail2ban; then
    log_success "Fail2ban: running"
else
    log_error "Fail2ban: NOT running"
fi

if systemctl is-active --quiet firewalld; then
    log_success "Firewalld: running"
else
    log_error "Firewalld: NOT running"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

log_step "Installation complete!"

echo
echo "============================================================"
echo " Installation Summary"
echo "============================================================"
echo "Operating System : ${PRETTY_NAME:-unknown}"
echo "Architecture     : $ARCH"
echo "Hostname         : $hostname"
echo "Virtualmin stack  : $stack_choice"
echo "Administrator    : $sudo_user"
echo "SSH authentication: SSH key"
echo "Sudo             : NOPASSWD"
echo "Docker           : installed"
echo "Portainer        : installed"
echo "NextCloud-AIO    : $([[ "$install_nc" =~ ^y$ ]] && echo "installed" || echo "not installed")"
echo "============================================================"
echo
echo "Access:"
echo "Virtualmin: https://$hostname:10000"
echo "Portainer : https://127.0.0.1:9443"
echo

if [[ "$install_nc" =~ ^y$ ]]; then
    echo "NextCloud AIO administration:"
    echo "https://$hostname:8080"
    echo
fi

echo "Portainer is bound to localhost."
echo "Use an SSH tunnel or configure a reverse proxy to access it remotely."
echo
echo "Setup log: $LOG_FILE"
echo "State file: $STATE_FILE"
echo
echo "Installation completed successfully."
