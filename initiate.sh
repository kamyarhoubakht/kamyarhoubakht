#!/bin/bash

set -euo pipefail

[[ "${DEBUG:-}" == "true" ]] && set -x

export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/setup_script.log"
STATE_FILE="/root/.setup_state"

touch "$STATE_FILE"
chmod 600 "$STATE_FILE"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_step() {
    echo "🔄 $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo "✅ $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "❌ $1" | tee -a "$LOG_FILE" >&2
}

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

handle_error() {
    local exit_code=$?
    local line_number=$1

    echo
    log_error "Error occurred at line $line_number. Exit code: $exit_code"
    log_error "Full log: $LOG_FILE"
    echo

    exit "$exit_code"
}

cleanup() {
    :
}

trap 'handle_error $LINENO' ERR
trap cleanup EXIT

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

step_done() {
    grep -qxF "$1" "$STATE_FILE" 2>/dev/null
}

mark_done() {
    grep -qxF "$1" "$STATE_FILE" 2>/dev/null || \
        echo "$1" >> "$STATE_FILE"
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

case "$OS_ID" in
    debian)
        case "$OS_VERSION_ID" in
            12|13)
                log_success "Supported Debian version detected: $OS_VERSION_ID"
                ;;
            *)
                log_error "Unsupported Debian version: $OS_VERSION_ID"
                log_error "Supported Debian versions: 12, 13"
                exit 1
                ;;
        esac
        ;;
    ubuntu)
        case "$OS_VERSION_ID" in
            22.04|24.04)
                log_success "Supported Ubuntu version detected: $OS_VERSION_ID"
                ;;
            *)
                log_error "Unsupported Ubuntu version: $OS_VERSION_ID"
                log_error "Supported Ubuntu versions: 22.04, 24.04 LTS"
                exit 1
                ;;
        esac
        ;;
    *)
        log_error "Unsupported operating system."
        log_error "This script supports Debian 12/13 and Ubuntu 22.04/24.04 LTS."
        log_error "Detected: ${OS_ID:-unknown} ${OS_VERSION_ID:-unknown}"
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Architecture check
# ---------------------------------------------------------------------------

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
    amd64|arm64)
        log_success "Supported architecture detected: $ARCH"
        ;;
    *)
        log_error "Unsupported architecture."
        log_error "Supported architectures: amd64, arm64"
        log_error "Detected architecture: $ARCH"
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

    log_success "Backup already done, skipping."

fi

# ---------------------------------------------------------------------------
# Verify root SSH keys
# ---------------------------------------------------------------------------

ROOT_AUTH_KEYS="/root/.ssh/authorized_keys"

if [[ ! -s "$ROOT_AUTH_KEYS" ]]; then
    log_error "No /root/.ssh/authorized_keys found."
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

    echo "$sudo_user" > /root/.virtualmin_admin_user
    chmod 600 /root/.virtualmin_admin_user

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

    echo
    echo "============================================================"
    echo " Administrator password"
    echo "============================================================"
    echo

    echo "Create a password for '$sudo_user'."
    echo
    echo "This password is separate from SSH authentication."
    echo "SSH will use your SSH key."
    echo

    while true; do

        read -rsp "Password: " sudo_user_password
        echo

        if [[ ${#sudo_user_password} -lt 12 ]]; then
            echo "Password must contain at least 12 characters."
            continue
        fi

        read -rsp "Confirm password: " sudo_user_password_confirm
        echo

        if [[ "$sudo_user_password" != "$sudo_user_password_confirm" ]]; then
            echo "Passwords do not match. Please try again."
            continue
        fi

        break

    done

    printf '%s:%s\n' "$sudo_user" "$sudo_user_password" | chpasswd

    unset sudo_user_password
    unset sudo_user_password_confirm

    log_success "Password created for '$sudo_user'."

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

    mark_done "admin_user"

else

    log_success "Administrator user already configured, skipping."

fi

# ---------------------------------------------------------------------------
# Recover administrator username when re-running
# ---------------------------------------------------------------------------

if [[ -z "${sudo_user:-}" ]]; then

    if [[ -f /root/.virtualmin_admin_user ]]; then
        sudo_user="$(cat /root/.virtualmin_admin_user)"
    else
        read -rp "Enter administrator username (default: goodmin): " sudo_user
        sudo_user="${sudo_user:-goodmin}"
    fi

fi

if ! id -u "$sudo_user" &>/dev/null; then
    log_error "Administrator user '$sudo_user' does not exist."
    exit 1
fi

USER_HOME="$(getent passwd "$sudo_user" | cut -d: -f6)"
USER_GROUP="$(id -gn "$sudo_user")"

# ---------------------------------------------------------------------------
# Step 1b: SSH hardening
# ---------------------------------------------------------------------------

if ! step_done "ssh_hardening"; then

    log_step "Configuring SSH for key-based authentication"

    SSH_CONFIG="/etc/ssh/sshd_config"

    cp -a "$SSH_CONFIG" \
        "${SSH_CONFIG}.pre-virtualmin-$(date +%Y%m%d_%H%M%S)"

    sed -i \
        -e '/^[[:space:]]*PasswordAuthentication[[:space:]]/d' \
        -e '/^[[:space:]]*KbdInteractiveAuthentication[[:space:]]/d' \
        -e '/^[[:space:]]*ChallengeResponseAuthentication[[:space:]]/d' \
        -e '/^[[:space:]]*PermitRootLogin[[:space:]]/d' \
        "$SSH_CONFIG"

    cat >> "$SSH_CONFIG" <<'EOF'
# Managed by initiate.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
EOF

    sshd -t
    systemctl restart ssh

    log_success "SSH configured for key-based authentication."

    mark_done "ssh_hardening"

else

    log_success "SSH hardening already completed, skipping."

fi

# ---------------------------------------------------------------------------
# Step 2: Select Virtualmin stack
# ---------------------------------------------------------------------------

if ! step_done "stack_selected"; then

    while true; do

        read -rp \
            "Install LAMP (Apache) or LEMP (Nginx)? (LAMP/LEMP): " \
            stack_choice

        stack_choice="$(echo "$stack_choice" | tr '[:lower:]' '[:upper:]')"

        if [[ "$stack_choice" == "LAMP" ||
              "$stack_choice" == "LEMP" ]]; then
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
# Step 3: Hostname
# ---------------------------------------------------------------------------

if ! step_done "hostname"; then

    CURRENT_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"

    echo
    echo "Virtualmin requires a proper fully qualified hostname."
    echo "Example: server.example.com"
    echo

    read -rp "Enter hostname [$CURRENT_HOSTNAME]: " hostname

    hostname="${hostname:-$CURRENT_HOSTNAME}"
    hostname="$(echo "$hostname" | tr '[:upper:]' '[:lower:]')"

    if ! [[ "$hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
        log_error "Invalid hostname: $hostname"
        log_error "Use a fully qualified hostname such as server.example.com"
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
# Step 4: Virtualmin installation
# ---------------------------------------------------------------------------

if ! step_done "virtualmin"; then

    # Do NOT apt update or install packages before Virtualmin.
    # Virtualmin expects a clean minimal supported OS.

    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required to download the Virtualmin installer."
        log_error "This script intentionally does not install packages before Virtualmin."
        log_error "Use a minimal OS image that already provides curl."
        exit 1
    fi

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
# Step 5: Administrator tools
# ---------------------------------------------------------------------------

if ! step_done "admin_tools"; then

    log_step "Installing administrator tools after Virtualmin"

    apt-get update

    apt-get install -y \
        tmux \
        btop \
        wget

    log_success "Administrator tools installed."

    mark_done "admin_tools"

else

    log_success "Administrator tools already installed, skipping."

fi

# ---------------------------------------------------------------------------
# Step 6: Docker
# ---------------------------------------------------------------------------

if ! step_done "docker"; then

    log_step "Installing Docker Engine"

    case "$ARCH" in
        amd64)
            DOCKER_ARCH="amd64"
            ;;
        arm64)
            DOCKER_ARCH="arm64"
            ;;
        *)
            log_error "Unsupported Docker architecture: $ARCH"
            exit 1
            ;;
    esac

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
        "https://download.docker.com/linux/$OS_ID/gpg" \
        -o /etc/apt/keyrings/docker.asc

    chmod a+r /etc/apt/keyrings/docker.asc

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$OS_ID
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

if ! id -nG "$sudo_user" | tr ' ' '\n' | grep -qx "docker"; then

    usermod -aG docker "$sudo_user"

    log_success "User '$sudo_user' added to the Docker group."

else

    log_success "User '$sudo_user' is already a member of the Docker group."

fi

# ---------------------------------------------------------------------------
# Step 7: Portainer
# ---------------------------------------------------------------------------

if ! step_done "portainer"; then

    log_step "Installing Portainer"

    docker volume inspect portainer_data >/dev/null 2>&1 || \
        docker volume create portainer_data >/dev/null

    PORTAINER_DIR="$USER_HOME/portainer"

    mkdir -p "$PORTAINER_DIR"

    cat > "$PORTAINER_DIR/docker-compose.yaml" <<'EOF'
name: portainer

services:

  portainer:

    image: portainer/portainer-ce:latest

    container_name: portainer

    restart: always

    ports:
      - "8000:8000"
      - "9443:9443"

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data

volumes:

  portainer_data:
    external: true
EOF

    chown -R "$sudo_user:$USER_GROUP" "$PORTAINER_DIR"

    chmod 750 "$PORTAINER_DIR"
    chmod 640 "$PORTAINER_DIR/docker-compose.yaml"

    runuser -u "$sudo_user" -- \
        docker compose \
        -f "$PORTAINER_DIR/docker-compose.yaml" \
        up -d

    log_success "Portainer installed."

    mark_done "portainer"

else

    log_success "Portainer already installed, skipping."

fi

# ---------------------------------------------------------------------------
# Step 8: Optional Nextcloud AIO
# ---------------------------------------------------------------------------

install_nc="n"

if [[ -f /root/.nextcloud_choice ]]; then

    install_nc="$(cat /root/.nextcloud_choice)"

else

    read -rp "Do you want to install NextCloud-AIO? (y/n): " install_nc

    install_nc="$(echo "$install_nc" | tr '[:upper:]' '[:lower:]')"

    echo "$install_nc" > /root/.nextcloud_choice

fi

if [[ "$install_nc" =~ ^y$ ]]; then

    if [[ ! -x /root/install-nextcloud-aio.sh ]]; then

        log_step "Downloading Nextcloud AIO installation script"

        curl -fsSL \
            "https://raw.githubusercontent.com/kamyarhoubakht/kamyarhoubakht/refs/heads/main/install-nextcloud-aio.sh" \
            -o /root/install-nextcloud-aio.sh

        chmod 700 /root/install-nextcloud-aio.sh

        log_success "Nextcloud AIO installer downloaded."

    fi

    log_step "Starting Nextcloud AIO installation"

    /root/install-nextcloud-aio.sh "$sudo_user"

    log_success "Nextcloud AIO installation script completed."

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

if id -nG "$sudo_user" | tr ' ' '\n' | grep -qx "docker"; then
    log_success "Docker group: '$sudo_user' is a member"
else
    log_error "Docker group: '$sudo_user' is NOT a member"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

log_step "Installation complete!"

echo
echo "Administrator: $sudo_user"
echo "Virtualmin:    installed"
echo "Docker:        installed"
echo "Portainer:     installed"
echo "Nextcloud AIO: $install_nc"
echo
