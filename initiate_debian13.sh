#!/bin/bash
set -Eeuo pipefail
[[ "${DEBUG:-}" == "true" ]] && set -x
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/setup_script.log"
STATE_FILE="/root/.setup_state"

touch "$STATE_FILE"
chmod 600 "$STATE_FILE"

log_step() { echo "🔄 $1" | tee -a "$LOG_FILE"; }
log_success() { echo "✅ $1" | tee -a "$LOG_FILE"; }
log_error() { echo "❌ $1" | tee -a "$LOG_FILE" >&2; }

handle_error() {
    local exit_code=$?
    local line_number=$1
    echo
    log_error "Error occurred at line $line_number. Exit code: $exit_code"
    log_error "Full log: $LOG_FILE"
    echo
    exit "$exit_code"
}
cleanup() { :; }
trap 'handle_error $LINENO' ERR
trap cleanup EXIT

step_done() { grep -qxF "$1" "$STATE_FILE" 2>/dev/null; }
mark_done() { grep -qxF "$1" "$STATE_FILE" 2>/dev/null || echo "$1" >> "$STATE_FILE"; }

if [[ "$EUID" -ne 0 ]]; then
    log_error "This script must be run as root."
    exit 1
fi

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
            12|13) log_success "Supported Debian version detected: $OS_VERSION_ID" ;;
            *) log_error "Unsupported Debian version: $OS_VERSION_ID"; log_error "Supported Debian versions: 12, 13"; exit 1 ;;
        esac
        ;;
    ubuntu)
        case "$OS_VERSION_ID" in
            22.04|24.04) log_success "Supported Ubuntu version detected: $OS_VERSION_ID" ;;
            *) log_error "Unsupported Ubuntu version: $OS_VERSION_ID"; log_error "Supported Ubuntu versions: 22.04, 24.04 LTS"; exit 1 ;;
        esac
        ;;
    *) log_error "Unsupported operating system."; log_error "This script supports Debian 12/13 and Ubuntu 22.04/24.04 LTS."; exit 1 ;;
esac

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
    amd64|arm64) log_success "Supported architecture detected: $ARCH" ;;
    *) log_error "Unsupported architecture: $ARCH"; log_error "Supported architectures: amd64, arm64"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# System Locales Configuration
# ---------------------------------------------------------------------------
if ! step_done "locale_fix"; then
    log_step "Generating en_US.UTF-8 locale to prevent Perl warnings"
    apt-get update >/dev/null 2>&1 || true
    apt-get install -y locales >/dev/null 2>&1 || true
    sed -i 's/^[#[:space:]]*en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen en_US.UTF-8 >/dev/null 2>&1
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    log_success "System locale generated and set to en_US.UTF-8."
    mark_done "locale_fix"
else
    log_success "Locale already configured, skipping."
fi

# Export for the current running script to silence warnings immediately
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# ---------------------------------------------------------------------------
# Backup important configuration
# ---------------------------------------------------------------------------
if ! step_done "backup"; then
    log_step "Creating backup of important configuration files"
    BACKUP_DIR="/root/pre_install_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    for file in /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/sudoers /etc/sudoers.d /root/.ssh; do
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
        log_error "Invalid username: $sudo_user"; exit 1
    fi
    if [[ "$sudo_user" == "root" ]]; then
        log_error "The administrator username cannot be root."; exit 1
    fi

    echo "$sudo_user" > /root/.virtualmin_admin_user
    chmod 600 /root/.virtualmin_admin_user

    if id -u "$sudo_user" &>/dev/null; then
        log_success "User '$sudo_user' already exists."
    else
        log_step "Creating administrator user '$sudo_user'"
        useradd --create-home --shell /bin/bash "$sudo_user"
        log_success "User '$sudo_user' created."
    fi

    echo
    echo "============================================================"
    echo " Administrator password"
    echo "============================================================"
    echo
    echo "Create a password for '$sudo_user'."
    echo

    while true; do
        read -rsp "Password: " sudo_user_password; echo
        if [[ ${#sudo_user_password} -lt 12 ]]; then
            echo "Password must contain at least 12 characters."; continue
        fi
        read -rsp "Confirm password: " sudo_user_password_confirm; echo
        if [[ "$sudo_user_password" != "$sudo_user_password_confirm" ]]; then
            echo "Passwords do not match. Please try again."; continue
        fi
        break
    done

    printf '%s:%s\n' "$sudo_user" "$sudo_user_password" | chpasswd
    unset sudo_user_password sudo_user_password_confirm
    log_success "Password created for '$sudo_user'."

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

    cp -a "$SSH_CONFIG" "${SSH_CONFIG}.pre-virtualmin-$(date +%Y%m%d_%H%M%S)"
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
        read -rp "Install LAMP (Apache) or LEMP (Nginx)? (LAMP/LEMP): " stack_choice
        stack_choice="$(echo "$stack_choice" | tr '[:lower:]' '[:upper:]')"
        if [[ "$stack_choice" == "LAMP" || "$stack_choice" == "LEMP" ]]; then break; fi
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
# Step 2b: Nextcloud AIO decision (asked early, so an incompatible choice
# fails fast instead of after Virtualmin/Docker/Portainer are already set up)
# ---------------------------------------------------------------------------
if [[ -f /root/.nextcloud_choice ]]; then
    install_nc="$(cat /root/.nextcloud_choice)"
else
    read -rp "Do you want to install NextCloud-AIO? (y/n): " install_nc
    install_nc="$(echo "$install_nc" | tr '[:upper:]' '[:lower:]')"
    echo "$install_nc" > /root/.nextcloud_choice
fi

if [[ "$install_nc" =~ ^y$ ]]; then
    if [[ "$stack_choice" != "LAMP" ]]; then
        log_error "Nextcloud AIO integration requires the LAMP/Apache Virtualmin stack."
        log_error "Re-run this bootstrap and choose LAMP if you want the integrated AIO reverse proxy,"
        log_error "or answer 'n' to the Nextcloud AIO question if you want to keep LEMP."
        exit 1
    fi
    log_success "Nextcloud AIO selected; will be installed after Docker/Portainer are ready."
else
    log_success "NextCloud-AIO not selected."
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
    apt-get install -y tmux btop wget
    log_success "Administrator tools installed."
    mark_done "admin_tools"
else
    log_success "Administrator tools already installed, skipping."
fi

# ---------------------------------------------------------------------------
# Step 6: Docker installation
# ---------------------------------------------------------------------------
OS_ID="$(. /etc/os-release && echo "$ID")"
OS_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
DOCKER_ARCH="$(dpkg --print-architecture)"

case "$OS_ID" in debian|ubuntu) ;; *) log_error "Unsupported operating system for Docker repository: $OS_ID"; exit 1 ;; esac
case "$DOCKER_ARCH" in amd64|arm64) ;; *) log_error "Unsupported Docker architecture: $DOCKER_ARCH"; exit 1 ;; esac

if ! step_done "docker"; then
    log_step "Installing Docker from the official Docker repository"

    apt-get remove -y docker.io docker-compose docker-doc podman-docker containerd runc 2>/dev/null || true
    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" -o /etc/apt/keyrings/docker.asc
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
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
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

# Run a command as the administrator from an administrator-accessible directory.
# This avoids Docker Compose inheriting /root as its current working directory.
run_as_admin() {
    local working_dir="$1"
    shift
    runuser -u "$sudo_user" -- \
        bash -c 'cd "$1" && shift && exec "$@"' \
        bash "$working_dir" "$@"
}

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
    chmod 750 "$PORTAINER_DIR"
    chmod 640 "$PORTAINER_DIR/docker-compose.yaml"

    log_step "Validating Portainer Compose configuration as $sudo_user"
    run_as_admin "$PORTAINER_DIR" docker compose -f docker-compose.yaml config >/dev/null

    log_step "Starting Portainer as $sudo_user"
    run_as_admin "$PORTAINER_DIR" docker compose -f docker-compose.yaml up -d

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
# Step 8: Optional Nextcloud AIO
# (Decision + LAMP compatibility check already happened in Step 2b.)
# ---------------------------------------------------------------------------
if [[ "$install_nc" =~ ^y$ ]]; then

  if ! step_done "nextcloud_aio"; then

    # -----------------------------------------------------------------------
    # Nextcloud AIO configuration
    # -----------------------------------------------------------------------
    AIO_LOG_FILE="/var/log/nextcloud-aio-install.log"
    AIO_STATE_FILE="/root/.nextcloud-aio-install.state"
    AIO_DATA_DIR="/mnt/ncdata"
    AIO_COMPOSE_DIR="$USER_HOME/nextcloud-aio"
    AIO_COMPOSE_FILE="$AIO_COMPOSE_DIR/docker-compose.yaml"
    AIO_IMAGE="ghcr.io/nextcloud-releases/all-in-one:latest"
    AIO_ADMIN_PORT="8080"
    AIO_WEB_PORT="11222"

    aio_log() {
        echo
        echo "============================================================" | tee -a "$AIO_LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$AIO_LOG_FILE"
        echo "============================================================" | tee -a "$AIO_LOG_FILE"
    }

    aio_die() {
        log_error "$1"
        log_error "Nextcloud AIO log: $AIO_LOG_FILE"
        exit 1
    }

    aio_warn() {
        echo "⚠ $1" | tee -a "$AIO_LOG_FILE"
    }

    # Best-effort: add the 'nocanon' flag to the ProxyPass line Virtualmin
    # generates. Virtualmin's create-proxy/modify-web CLI has no flag for
    # this, so we patch the generated vhost file directly. Nextcloud's
    # AllowEncodedSlashes NoDecode directive only has full effect if Apache
    # doesn't canonicalize the URL before proxying it (affects some WebDAV /
    # desktop-client requests with encoded slashes). This is optional
    # hardening: on any failure we revert and continue rather than aborting.
    patch_proxypass_nocanon() {
        local port="$1"
        local pattern="ProxyPass / http://127.0.0.1:${port}/"
        local vhost_file
        vhost_file="$(grep -rlF "$pattern" /etc/apache2/sites-enabled /etc/apache2/sites-available 2>/dev/null | head -n1 || true)"

        if [[ -z "$vhost_file" ]]; then
            aio_warn "Could not locate the generated ProxyPass line to add 'nocanon'; skipping this optional hardening step."
            return 0
        fi

        if grep -qF "${pattern} nocanon" "$vhost_file"; then
            aio_log "ProxyPass 'nocanon' flag already present in $vhost_file."
            return 0
        fi

        local backup="${vhost_file}.pre-nocanon-$(date +%Y%m%d_%H%M%S)"
        cp -a "$vhost_file" "$backup"

        if sed -i "s#${pattern}\$#${pattern} nocanon#" "$vhost_file" && apache2ctl configtest 2>/dev/null; then
            systemctl reload apache2
            aio_log "Added 'nocanon' to the ProxyPass directive in $vhost_file."
        else
            aio_warn "Adding 'nocanon' produced an invalid Apache config; reverting $vhost_file."
            cp -a "$backup" "$vhost_file"
            apache2ctl configtest >/dev/null 2>&1 || true
        fi
    }

    touch "$AIO_LOG_FILE" "$AIO_STATE_FILE"
    chmod 600 "$AIO_STATE_FILE"

    for command in virtualmin apache2ctl curl openssl runuser ss; do
        command -v "$command" >/dev/null 2>&1 || aio_die "Required command not found: $command"
    done

    aio_log "Starting Nextcloud AIO installation"

    echo
    echo "============================================================"
    echo "Nextcloud AIO domain"
    echo "============================================================"
    echo
    echo "Enter the independent domain/subdomain that will be used"
    echo "for Nextcloud. DNS for this domain must already point at this"
    echo "server's public IP before continuing."
    echo
    read -r -p "Nextcloud domain: " AIO_DOMAIN
    AIO_DOMAIN="${AIO_DOMAIN,,}"

    [[ -n "$AIO_DOMAIN" ]] || aio_die "No domain was supplied."

    if ! [[ "$AIO_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
        aio_die "Invalid domain name: $AIO_DOMAIN"
    fi

    aio_log "Nextcloud domain: $AIO_DOMAIN"

    if virtualmin list-domains --name-only 2>/dev/null | grep -Fxq "$AIO_DOMAIN"; then
        DOMAIN_EXISTS=1
        echo "Virtualmin domain already exists: $AIO_DOMAIN"
    else
        DOMAIN_EXISTS=0
    fi

    if [[ "$DOMAIN_EXISTS" -eq 0 ]]; then
        aio_log "Generating password for the Virtualmin domain"
        DOMAIN_PASSWORD="$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 32)"
        [[ -n "$DOMAIN_PASSWORD" ]] || aio_die "Failed to generate Virtualmin domain password."
    else
        DOMAIN_PASSWORD=""
    fi

    cat > "$AIO_STATE_FILE" <<EOF
AIO_DOMAIN='$AIO_DOMAIN'
AIO_ADMIN_PORT='$AIO_ADMIN_PORT'
AIO_WEB_PORT='$AIO_WEB_PORT'
AIO_DATA_DIR='$AIO_DATA_DIR'
AIO_COMPOSE_FILE='$AIO_COMPOSE_FILE'
ADMIN_USER='$sudo_user'
EOF

    if [[ -n "$DOMAIN_PASSWORD" ]]; then
        cat >> "$AIO_STATE_FILE" <<EOF
VIRTUALMIN_DOMAIN_PASSWORD='$DOMAIN_PASSWORD'
EOF
    fi
    chmod 600 "$AIO_STATE_FILE"

    if [[ "$DOMAIN_EXISTS" -eq 0 ]]; then
        aio_log "Creating Virtualmin domain: $AIO_DOMAIN"
        virtualmin create-domain \
            --domain "$AIO_DOMAIN" \
            --pass "$DOMAIN_PASSWORD" \
            --unix \
            --dir \
            --web \
            --ssl \
            --skip-warnings \
            || aio_die "Virtualmin failed to create $AIO_DOMAIN."
    else
        aio_log "Skipping Virtualmin domain creation because it already exists."
    fi

    aio_log "Enabling required Apache modules"
    REQUIRED_MODULES=(proxy proxy_http proxy_wstunnel rewrite headers ssl http2)
    for module in "${REQUIRED_MODULES[@]}"; do
        a2enmod "$module" >/dev/null 2>&1 || true
    done

    aio_log "Creating Nextcloud data directory"
    mkdir -p "$AIO_DATA_DIR"
    chmod 755 "$AIO_DATA_DIR"

    aio_log "Creating administrator-owned AIO Compose directory"
    mkdir -p "$AIO_COMPOSE_DIR"
    chown "$sudo_user:$USER_GROUP" "$AIO_COMPOSE_DIR"
    chmod 750 "$AIO_COMPOSE_DIR"

    aio_log "Creating Nextcloud AIO Docker Compose configuration"
    cat > "$AIO_COMPOSE_FILE" <<EOF
services:

  nextcloud-aio-mastercontainer:
    image: ${AIO_IMAGE}
    container_name: nextcloud-aio-mastercontainer
    init: true
    restart: always

    ports:
      - "${AIO_ADMIN_PORT}:8080"

    volumes:
      - nextcloud_aio_mastercontainer:/mnt/docker-aio-config
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${AIO_DATA_DIR}:/mnt/ncdata

    environment:
      APACHE_PORT: ${AIO_WEB_PORT}
      APACHE_IP_BINDING: 127.0.0.1
      SKIP_DOMAIN_VALIDATION: false
      NEXTCLOUD_DATADIR: /mnt/ncdata
      NEXTCLOUD_MOUNT: /mnt/
      NEXTCLOUD_STARTUP_APPS: twofactor_totp calendar contacts files_external

volumes:

  nextcloud_aio_mastercontainer:
    name: nextcloud_aio_mastercontainer
EOF

    chown "$sudo_user:$USER_GROUP" "$AIO_COMPOSE_FILE"
    chmod 640 "$AIO_COMPOSE_FILE"

    aio_log "Validating AIO Compose configuration as $sudo_user"
    run_as_admin "$AIO_COMPOSE_DIR" docker compose -f docker-compose.yaml config >/dev/null \
        || aio_die "Nextcloud AIO Docker Compose configuration is invalid."

    aio_log "Starting Nextcloud AIO as $sudo_user"
    run_as_admin "$AIO_COMPOSE_DIR" docker compose -f docker-compose.yaml up -d \
        || aio_die "Failed to start Nextcloud AIO."

    aio_log "Checking AIO administration interface (30 seconds)"
    AIO_READY=0
    for i in $(seq 1 30); do
        if curl --silent --show-error --insecure --max-time 1 \
            "https://127.0.0.1:${AIO_ADMIN_PORT}/" >/dev/null 2>&1; then
            AIO_READY=1
            break
        fi
        printf "."
        sleep 1
    done
    echo

    if [[ "$AIO_READY" -eq 1 ]]; then
        echo "✓ Nextcloud AIO administration interface is available."
    else
        echo "⚠ Nextcloud AIO administration interface is not available yet on port ${AIO_ADMIN_PORT}."
        echo "  Continuing with Virtualmin/Apache configuration; AIO may still be starting."
    fi

    # -----------------------------------------------------------------------
    # Test Virtualmin directive API
    # -----------------------------------------------------------------------
    aio_log "Testing Virtualmin native --add-directive API"
    TEST_DIRECTIVE="SetEnv VIRTUALMIN_AIO_TEST 1"
    TEST_OUTPUT="$(mktemp)"

    set +e
    virtualmin modify-web \
        --domain "$AIO_DOMAIN" \
        --add-directive "$TEST_DIRECTIVE" \
        >"$TEST_OUTPUT" 2>&1
    TEST_EXIT_CODE=$?
    set -e

    cat "$TEST_OUTPUT"
    rm -f "$TEST_OUTPUT"

    if [[ "$TEST_EXIT_CODE" -ne 0 ]]; then
        aio_die "Virtualmin --add-directive API failed."
    fi

    virtualmin modify-web \
        --domain "$AIO_DOMAIN" \
        --remove-directive "$TEST_DIRECTIVE" \
        || aio_die "Could not remove temporary test directive."

    echo "✓ Virtualmin --add-directive API works."

    # -----------------------------------------------------------------------
    # Create native Virtualmin proxy
    # -----------------------------------------------------------------------
    aio_log "Setting up Let's Encrypt ACME challenge exclusion"
    virtualmin modify-web \
        --domain "$AIO_DOMAIN" \
        --remove-directive "ProxyPass /.well-known !" \
        >/dev/null 2>&1 || true

    virtualmin modify-web \
        --domain "$AIO_DOMAIN" \
        --add-directive "ProxyPass /.well-known !" \
        || aio_die "Failed to add ACME proxy exclusion."

    aio_log "Creating Virtualmin reverse proxy: / -> http://127.0.0.1:${AIO_WEB_PORT}/"

    PROXY_OUTPUT="$(mktemp)"
    set +e
    virtualmin create-proxy \
        --domain "$AIO_DOMAIN" \
        --path "/" \
        --url "http://127.0.0.1:${AIO_WEB_PORT}/" \
        --websockets \
        >"$PROXY_OUTPUT" 2>&1
    PROXY_EXIT_CODE=$?
    set -e

    cat "$PROXY_OUTPUT"
    rm -f "$PROXY_OUTPUT"

    if [[ "$PROXY_EXIT_CODE" -ne 0 ]]; then
        aio_die "Virtualmin create-proxy failed."
    fi

    echo "✓ Native Virtualmin reverse proxy created."

    # -----------------------------------------------------------------------
    # HTTP protocols
    # -----------------------------------------------------------------------
    aio_log "Configuring HTTP protocols"
    virtualmin modify-web \
        --domain "$AIO_DOMAIN" \
        --protocols "http/1.1 h2" \
        || aio_die "Virtualmin protocol configuration failed."

    # -----------------------------------------------------------------------
    # Nextcloud AIO Apache directives
    #
    # ProxyPreserveHost On is added first: without it, the AIO Apache
    # container behind the proxy sees Host: 127.0.0.1:<port> instead of the
    # real domain, which breaks Nextcloud's own domain/redirect handling.
    # Each directive is removed before being (re-)added so this block stays
    # idempotent even if it's ever re-run outside the step_done guard above.
    # -----------------------------------------------------------------------
    aio_log "Adding Nextcloud AIO Apache directives"

    NATIVE_DIRECTIVES=(
        "ProxyPreserveHost On"
        "AllowEncodedSlashes NoDecode"
        "H2WindowSize 5242880"
        "TraceEnable off"
        "LimitRequestBody 0"
        "Timeout 3610"
        "ProxyTimeout 3610"
    )

    for directive in "${NATIVE_DIRECTIVES[@]}"; do
        aio_log "Setting Apache directive: $directive"
        virtualmin modify-web \
            --domain "$AIO_DOMAIN" \
            --remove-directive "$directive" \
            >/dev/null 2>&1 || true
        virtualmin modify-web \
            --domain "$AIO_DOMAIN" \
            --add-directive "$directive" \
            || aio_die "Failed to add Apache directive: $directive"
    done

    # Optional hardening Virtualmin's CLI has no flag for - see function def.
    patch_proxypass_nocanon "$AIO_WEB_PORT"

    # -----------------------------------------------------------------------
    # Verify the Virtualmin proxy through Virtualmin itself.
    # This is verification only; we never edit generated Apache files
    # (other than the best-effort nocanon patch above, which validates and
    # reverts itself on failure).
    # -----------------------------------------------------------------------
    aio_log "Verifying Virtualmin proxy configuration"

    if ! virtualmin list-proxies --domain "$AIO_DOMAIN" 2>/dev/null \
        | grep -Fq "127.0.0.1:${AIO_WEB_PORT}"; then
        aio_log "WARNING: Virtualmin did not return the expected backend in list-proxies output."
        aio_log "Raw proxy listing follows:"
        virtualmin list-proxies --domain "$AIO_DOMAIN" 2>&1 || true
        aio_die "Could not verify the Virtualmin reverse proxy."
    fi

    echo "✓ Virtualmin reports the expected reverse proxy."

    # -----------------------------------------------------------------------
    # Apache syntax test and reload
    # -----------------------------------------------------------------------
    aio_log "Validating Apache configuration"

    if ! apache2ctl configtest; then
        aio_die "Apache configuration is invalid. Apache was not reloaded."
    fi

    echo "✓ Apache configuration is valid."

    aio_log "Reloading Apache"
    systemctl reload apache2

    echo "✓ Apache reloaded successfully."

    # -----------------------------------------------------------------------
    # Verify Apache's loaded vhosts, but NEVER modify them directly.
    # -----------------------------------------------------------------------
    aio_log "Verifying Apache's loaded VirtualHost configuration"
    apache2ctl -S 2>&1 | grep -i "$AIO_DOMAIN" \
        || aio_die "Apache does not report the Nextcloud VirtualHost."

    # -----------------------------------------------------------------------
    # Ports and containers
    # -----------------------------------------------------------------------
    aio_log "Checking Nextcloud AIO ports"
    ss -lntp 2>/dev/null | grep -E ":(${AIO_ADMIN_PORT}|${AIO_WEB_PORT})\b" || true

    aio_log "Checking Nextcloud AIO containers as $sudo_user"
    run_as_admin "$AIO_COMPOSE_DIR" docker ps \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' \
        | grep -E 'nextcloud-aio|NAMES' || true

    echo
    echo "============================================================"
    echo "✓ NEXTCLOUD AIO INSTALLATION COMPLETE"
    echo "============================================================"
    echo
    echo "Nextcloud domain:"
    echo "  https://${AIO_DOMAIN}"
    echo
    echo "AIO administration interface:"
    echo "  https://SERVER-IP:${AIO_ADMIN_PORT}"
    echo "  (Reachable from the internet by design, per the Nextcloud AIO docs -"
    echo "   its own self-signed cert is expected. Firewall this port once initial"
    echo "   setup is done if you don't want it publicly reachable long-term.)"
    echo
    echo "AIO Apache backend:"
    echo "  127.0.0.1:${AIO_WEB_PORT}"
    echo
    echo "Nextcloud data:"
    echo "  ${AIO_DATA_DIR}"
    echo
    echo "Docker Compose:"
    echo "  ${AIO_COMPOSE_FILE}"
    echo
    echo "Installation log:"
    echo "  ${AIO_LOG_FILE}"
    echo
    echo "Complete the remaining AIO setup through the AIO interface."
    echo

    mark_done "nextcloud_aio"

  else
    log_success "Nextcloud AIO already installed, skipping."
  fi

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
echo "NextCloud-AIO    : $([[ "$install_nc" =~ ^y$ ]] && echo "installed" || echo "not installed")"
echo "============================================================"
echo
echo "Access:"
echo "Virtualmin/Webmin: https://$hostname:10000"
echo "Portainer        : https://127.0.0.1:9443"
echo "  (bound to localhost - reach it via an SSH tunnel, e.g.:"
echo "   ssh -L 9443:127.0.0.1:9443 $sudo_user@$hostname)"
if [[ "$install_nc" =~ ^y$ ]]; then
    echo
    echo "NextCloud AIO:"
    echo "AIO setup interface: https://SERVER-IP:8080"
    echo "Nextcloud: https://<your-AIO-domain>"
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
