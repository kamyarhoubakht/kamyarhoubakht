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

if [[ "$OS_ID" != "debian" ]]; then
    log_error "This script is intended for Debian."
    log_error "Detected: ${OS_ID:-unknown}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Architecture check
#
# This installation is intended for x86_64/AMD64.
# ---------------------------------------------------------------------------

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
    amd64)
        log_success "Supported architecture detected: $ARCH"
        ;;
    *)
        log_error "This installation requires AMD64/x86_64."
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
#
# The administrator account receives the same SSH public keys as root.
# Password authentication over SSH will subsequently be disabled.
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

    # Save username so it can be recovered on later runs.
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

    # -----------------------------------------------------------------------
    # Administrator password
    #
    # This password is NOT used for SSH.
    #
    # SSH remains key-based.
    #
    # The password is required so the administrator account has a normal
    # system password for Virtualmin/Webmin/local authentication.
    # -----------------------------------------------------------------------

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
#
# SSH remains key-only.
# The password created above is NOT used for SSH.
# ---------------------------------------------------------------------------

if ! step_done "ssh_hardening"; then

    log_step "Configuring SSH for key-based authentication"

    SSH_CONFIG="/etc/ssh/sshd_config"

    cp -a "$SSH_CONFIG" "${SSH_CONFIG}.pre-virtualmin-$(date +%Y%m%d_%H%M%S)"

    # Remove previous settings so we don't create conflicting directives.
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
# Step 2: Minimal system preparation
#
# Do NOT run apt upgrade before Virtualmin.
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
        lsb-release \
        openssl

    log_success "System preparation complete."

    mark_done "system_prepare"

else

    log_success "System preparation already completed, skipping."

fi

# ---------------------------------------------------------------------------
# Step 3: Debian 13 cloud-init handling
#
# Debian 13 cloud-init conflicts with the Firewalld setup required by the
# current Virtualmin environment.
#
# Only perform this on Debian 13.
# ---------------------------------------------------------------------------

if [[ "$OS_ID" == "debian" && "$OS_VERSION_ID" == "13" ]]; then

    if ! step_done "debian13_cloudinit"; then

        if dpkg-query -W -f='${Status}' cloud-init 2>/dev/null \
            | grep -q "install ok installed"; then

            log_step "Debian 13 detected: disabling cloud-init"

            systemctl stop \
                cloud-init.service \
                cloud-init-local.service \
                cloud-config.service \
                cloud-final.service \
                2>/dev/null || true

            systemctl disable \
                cloud-init.service \
                cloud-init-local.service \
                cloud-config.service \
                cloud-final.service \
                2>/dev/null || true

            systemctl mask \
                cloud-init.service \
                cloud-init-local.service \
                cloud-config.service \
                cloud-final.service \
                2>/dev/null || true

            log_step "Removing cloud-init"

            apt-get purge -y cloud-init
            apt-get autoremove -y

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
# Step 5: Hostname
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
# Step 6: Virtualmin installation
#
# Official current Virtualmin installer.
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
# Step 6b: Ensure Firewalld and Fail2ban are fully installed
#
# Virtualmin normally installs/configures these, but we explicitly verify
# and enable them so the final server has the services we expect.
# ---------------------------------------------------------------------------

if ! step_done "security_services"; then

    log_step "Ensuring Firewalld and Fail2ban are installed"

    apt-get update

    apt-get install -y \
        firewalld \
        fail2ban

    systemctl enable --now firewalld
    systemctl enable --now fail2ban

    if ! systemctl is-active --quiet firewalld; then
        log_error "Firewalld is not running."
        exit 1
    fi

    if ! systemctl is-active --quiet fail2ban; then
        log_error "Fail2ban is not running."
        exit 1
    fi

    log_success "Firewalld installed and running."
    log_success "Fail2ban installed and running."

    mark_done "security_services"

else

    log_success "Firewalld and Fail2ban already configured, skipping."

fi

# ---------------------------------------------------------------------------
# Step 7: Docker installation
#
# Official Docker Debian repository.
# ---------------------------------------------------------------------------

OS_ID="$(. /etc/os-release && echo "$ID")"
OS_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
DOCKER_ARCH="$(dpkg --print-architecture)"

if ! step_done "docker"; then

    log_step "Installing Docker from the official Docker repository"

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

    chown -R "$sudo_user:$USER_GROUP" "$PORTAINER_DIR"

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

    # Pass the administrator username so the AIO project is created under
    # /home/$sudo_user rather than /root.
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
echo "Virtualmin stack : $stack_choice"
echo "Administrator    : $sudo_user"
echo "SSH authentication: SSH key only"
echo "Sudo             : NOPASSWD"
echo "Docker           : installed"
echo "Portainer        : installed"
echo "Fail2ban         : installed"
echo "Firewalld        : installed"
echo "NextCloud-AIO    : $([[ "$install_nc" =~ ^y$ ]] && echo "installed" || echo "not installed")"
echo "============================================================"
echo

echo "Access:"
echo "Virtualmin/Webmin: https://$hostname:10000"
echo "Portainer        : https://127.0.0.1:9443"

if [[ "$install_nc" =~ ^y$ ]]; then

    echo
    echo "NextCloud AIO:"
    echo "AIO setup interface: http://SERVER-IP:8080"
    echo
    echo "Complete the AIO setup before configuring the Apache"
    echo "reverse proxy to port 11222."

fi

echo
echo "SSH:"
echo "  Password authentication: disabled"
echo "  Root login: SSH key only"
echo "  Administrator login: SSH key"
echo
echo "Setup log:"
echo "  $LOG_FILE"
echo
echo "State file:"
echo "  $STATE_FILE"
echo
echo "Installation completed successfully."
