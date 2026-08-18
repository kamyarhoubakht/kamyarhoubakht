#!/bin/bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ============================================================================
# Nextcloud AIO installation
#
# Called by initiate.sh as:
#
#   /root/install-nextcloud-aio.sh "$sudo_user"
#
# The administrator user is used for the project/Compose files.
#
# AIO itself remains a system Docker service.
#
# ============================================================================

LOG_FILE="/var/log/nextcloud-aio-install.log"
STATE_FILE="/root/.nextcloud_aio_state"
DOMAIN_FILE="/root/.nextcloud_aio_domain"

mkdir -p "$(dirname "$LOG_FILE")"

touch "$LOG_FILE"
touch "$STATE_FILE"

chmod 600 "$LOG_FILE"
chmod 600 "$STATE_FILE"

# ============================================================================
# Logging
# ============================================================================

log_step() {
    echo
    echo "🔄 $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo "✅ $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "❌ $1" | tee -a "$LOG_FILE" >&2
}

# ============================================================================
# Error handling
# ============================================================================

handle_error() {
    local exit_code=$?
    local line_number=$1

    echo
    log_error "Nextcloud AIO installation failed."
    log_error "Line: $line_number"
    log_error "Exit code: $exit_code"
    log_error "Log file: $LOG_FILE"
    echo

    exit "$exit_code"
}

trap 'handle_error $LINENO' ERR

# ============================================================================
# State helpers
# ============================================================================

step_done() {
    grep -qxF "$1" "$STATE_FILE" 2>/dev/null
}

mark_done() {
    grep -qxF "$1" "$STATE_FILE" 2>/dev/null || \
        echo "$1" >> "$STATE_FILE"
}

# ============================================================================
# Root check
# ============================================================================

if [[ "$EUID" -ne 0 ]]; then
    log_error "This script must be run as root."
    exit 1
fi

# ============================================================================
# Administrator user
# ============================================================================

if [[ $# -ne 1 ]]; then
    log_error "Usage:"
    log_error "  $0 <sudo_admin_username>"
    exit 1
fi

sudo_user="$1"

if ! id -u "$sudo_user" >/dev/null 2>&1; then
    log_error "Administrator user '$sudo_user' does not exist."
    exit 1
fi

USER_HOME="$(getent passwd "$sudo_user" | cut -d: -f6)"
USER_GROUP="$(id -gn "$sudo_user")"

if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
    log_error "Could not determine home directory for '$sudo_user'."
    exit 1
fi

log_success "Administrator user: $sudo_user"
log_success "Administrator home: $USER_HOME"

# ============================================================================
# Required commands
# ============================================================================

for command in docker curl virtualmin apache2ctl openssl; do
    if ! command -v "$command" >/dev/null 2>&1; then
        log_error "Required command not found: $command"
        exit 1
    fi
done

if ! docker compose version >/dev/null 2>&1; then
    log_error "Docker Compose plugin is not available."
    exit 1
fi

# ============================================================================
# Docker service
# ============================================================================

if ! systemctl is-active --quiet docker; then
    log_error "Docker is installed but is not running."
    exit 1
fi

log_success "Docker is running."

# ============================================================================
# Ask for AIO domain
#
# This is a completely independent top-level Virtualmin domain.
#
# It does NOT require:
#   - a parent Virtualmin domain
#   - a parent server
#   - mail
#   - www
#   - admin
#   - FTP
#   - DNS management by Virtualmin
#
# It exists only so Apache can serve as the reverse proxy.
# ============================================================================

if [[ -f "$DOMAIN_FILE" ]]; then

    aio_domain="$(cat "$DOMAIN_FILE")"

    if [[ -n "$aio_domain" ]]; then

        echo
        echo "Existing Nextcloud AIO domain:"
        echo
        echo "  $aio_domain"
        echo

        read -rp "Use this domain? (Y/n): " reuse_domain

        reuse_domain="${reuse_domain:-y}"
        reuse_domain="$(echo "$reuse_domain" | tr '[:upper:]' '[:lower:]')"

        if [[ "$reuse_domain" != "y" ]]; then
            rm -f "$DOMAIN_FILE"
        fi

    fi
fi

if [[ ! -f "$DOMAIN_FILE" ]]; then

    echo
    echo "============================================================"
    echo " Nextcloud AIO domain"
    echo "============================================================"
    echo
    echo "Enter the complete hostname that will be used for Nextcloud."
    echo
    echo "Example:"
    echo
    echo "  cloud.example.com"
    echo
    echo "This will be created as an independent Virtualmin domain."
    echo "It does not need a parent Virtualmin domain."
    echo

    while true; do

        read -rp "Nextcloud AIO domain: " aio_domain

        aio_domain="$(echo "$aio_domain" | tr '[:upper:]' '[:lower:]' | xargs)"

        if [[ -z "$aio_domain" ]]; then
            echo "Domain cannot be empty."
            continue
        fi

        if ! [[ "$aio_domain" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
            echo
            echo "Invalid domain: $aio_domain"
            echo "Example: cloud.example.com"
            echo
            continue
        fi

        break
    done

    printf '%s\n' "$aio_domain" > "$DOMAIN_FILE"
    chmod 600 "$DOMAIN_FILE"

fi

log_success "Nextcloud AIO domain: $aio_domain"

# ============================================================================
# Virtualmin domain
#
# Create a minimal independent domain.
#
# Apache/web functionality is required.
# Mail, DNS, FTP and other Virtualmin services are not required.
# ============================================================================

if virtualmin list-domains --name-only 2>/dev/null \
    | grep -Fxq "$aio_domain"; then

    log_success "Virtualmin domain already exists: $aio_domain"

else

    log_step "Creating independent Virtualmin domain"

    DOMAIN_PASSWORD="$(openssl rand -base64 48)"

    virtualmin create-domain \
        --domain "$aio_domain" \
        --pass "$DOMAIN_PASSWORD" \
        --unix \
        --dir \
        --web \
        --ssl \
        --skip-warnings

    unset DOMAIN_PASSWORD

    log_success "Virtualmin domain created."

fi

# ============================================================================
# Apache modules
# ============================================================================

log_step "Enabling Apache modules required for the AIO reverse proxy"

a2enmod \
    proxy \
    proxy_http \
    proxy_wstunnel \
    rewrite \
    headers \
    http2 \
    ssl \
    >/dev/null

log_success "Required Apache modules enabled."

# ============================================================================
# Reload Apache
# ============================================================================

apache2ctl configtest

systemctl reload apache2

log_success "Apache configuration is valid."

# ============================================================================
# AIO project directory
#
# IMPORTANT:
#
# This is deliberately NOT:
#
#   /root/nextcloud-aio
#
# It belongs to the administrator account.
# ============================================================================

AIO_DIR="$USER_HOME/nextcloud-aio"
AIO_COMPOSE="$AIO_DIR/docker-compose.yaml"

if [[ ! -d "$AIO_DIR" ]]; then

    log_step "Creating AIO project directory"

    mkdir -p "$AIO_DIR"

fi

chown "$sudo_user:$USER_GROUP" "$AIO_DIR"
chmod 750 "$AIO_DIR"

log_success "AIO project directory: $AIO_DIR"

# ============================================================================
# Docker Compose
#
# This follows the official AIO reverse-proxy architecture:
#
#   public:
#       8080 -> AIO mastercontainer interface
#
#   localhost only:
#       11222 -> AIO Apache
#
# Apache on the host will eventually proxy:
#
#       HTTPS 443
#           ↓
#       127.0.0.1:11222
#
# We deliberately do NOT configure that Apache proxy here.
# ============================================================================

if [[ -f "$AIO_COMPOSE" ]]; then

    log_success "Existing AIO Compose file found."

else

    log_step "Creating Nextcloud AIO Docker Compose file"

    cat > "$AIO_COMPOSE" <<'EOF'
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

      # AIO setup/management interface.
      #
      # This is intentionally publicly reachable because the initial AIO
      # configuration is performed through this interface.
      - "8080:8080"

      # AIO's internal Apache.
      #
      # MUST remain localhost-only because the host Apache reverse proxy
      # connects to it.
      - "127.0.0.1:11222:11222"

    environment:

      # AIO Apache port used by the external Apache reverse proxy.
      - APACHE_PORT=11222

      # The reverse proxy is on this same server.
      # Therefore Apache only needs to be reachable through localhost.
      - APACHE_IP_BINDING=127.0.0.1

volumes:

  nextcloud_aio_mastercontainer:
    name: nextcloud_aio_mastercontainer
EOF

    chown "$sudo_user:$USER_GROUP" "$AIO_COMPOSE"
    chmod 640 "$AIO_COMPOSE"

    log_success "AIO Compose file created."

fi

# ============================================================================
# Ensure ownership is correct even if the Compose file already existed
# ============================================================================

chown -R "$sudo_user:$USER_GROUP" "$AIO_DIR"

chmod 750 "$AIO_DIR"
chmod 640 "$AIO_COMPOSE"

# ============================================================================
# Validate Compose
# ============================================================================

log_step "Validating Docker Compose configuration"

(
    cd "$AIO_DIR"
    docker compose config >/dev/null
)

log_success "Docker Compose configuration is valid."

# ============================================================================
# Firewalld
#
# Port 8080 is intentionally opened because the user needs direct access
# to the AIO interface.
#
# Port 11222 is NOT opened.
#
# It is bound to 127.0.0.1 anyway.
# ============================================================================

if command -v firewall-cmd >/dev/null 2>&1; then

    if systemctl is-active --quiet firewalld; then

        log_step "Opening AIO port 8080 in Firewalld"

        if ! firewall-cmd --permanent --query-port=8080/tcp >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port=8080/tcp
        fi

        firewall-cmd --reload

        log_success "Firewalld allows TCP port 8080."

    else

        log_error "Firewalld is installed but not running."
        exit 1

    fi

else

    log_error "firewall-cmd was not found."
    exit 1

fi

# ============================================================================
# Start / recreate AIO mastercontainer
#
# IMPORTANT:
#
# We only wait for port 8080.
#
# We DO NOT wait for 11222.
#
# AIO's Apache container is created/started as part of the AIO setup process.
# ============================================================================

log_step "Starting Nextcloud AIO mastercontainer"

(
    cd "$AIO_DIR"
    docker compose up -d
)

log_success "AIO mastercontainer started."

# ============================================================================
# Wait for AIO interface on 8080 only
# ============================================================================

log_step "Waiting for AIO interface on port 8080"

aio_ready=false

for i in {1..60}; do

    if curl \
        --silent \
        --show-error \
        --insecure \
        --max-time 3 \
        https://127.0.0.1:8080/ \
        >/dev/null 2>&1; then

        aio_ready=true
        break

    fi

    sleep 2

done

if [[ "$aio_ready" != true ]]; then

    log_error "AIO interface did not become available on port 8080."

    echo
    echo "============================================================"
    echo " Docker container status"
    echo "============================================================"

    docker ps -a \
        --filter "name=nextcloud-aio-mastercontainer"

    echo
    echo "============================================================"
    echo " Recent AIO logs"
    echo "============================================================"

    docker logs \
        --tail 150 \
        nextcloud-aio-mastercontainer || true

    exit 1

fi

log_success "AIO interface is available on port 8080."

# ============================================================================
# Verify port 11222 is NOT publicly bound
#
# We do not require it to be listening yet.
# We only check that Docker has not accidentally published it on 0.0.0.0.
# ============================================================================

if docker port nextcloud-aio-mastercontainer 11222/tcp 2>/dev/null \
    | grep -qE '0\.0\.0\.0:11222|\[::\]:11222'; then

    log_error "SECURITY ERROR: port 11222 is publicly exposed."
    log_error "It must remain bound to 127.0.0.1."

    exit 1

fi

log_success "AIO Apache port 11222 is not publicly exposed."

# ============================================================================
# Determine server IP
# ============================================================================

SERVER_IP="$(hostname -I | awk '{print $1}')"

if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
fi

SERVER_IP="${SERVER_IP:-SERVER-IP}"

# ============================================================================
# Final state
# ============================================================================

mark_done "aio_compose"
mark_done "aio_virtualmin_domain"
mark_done "aio_firewall"
mark_done "aio_mastercontainer"
mark_done "aio_setup_ready"

# ============================================================================
# Final output
# ============================================================================

echo
echo "============================================================"
echo " Nextcloud AIO installation prepared"
echo "============================================================"
echo
echo "Administrator:"
echo
echo "  $sudo_user"
echo
echo "AIO project:"
echo
echo "  $AIO_DIR"
echo
echo "Compose file:"
echo
echo "  $AIO_COMPOSE"
echo
echo "Nextcloud domain:"
echo
echo "  $aio_domain"
echo
echo "AIO interface:"
echo
echo "  https://$SERVER_IP:8080"
echo
echo "AIO Apache backend:"
echo
echo "  127.0.0.1:11222"
echo
echo "Firewall:"
echo
echo "  8080/tcp  OPEN"
echo "  11222/tcp NOT OPEN"
echo
echo "============================================================"
echo " IMPORTANT"
echo "============================================================"
echo
echo "Open the AIO interface using the SERVER IP:"
echo
echo "  https://$SERVER_IP:8080"
echo
echo "Accept the self-signed certificate warning."
echo
echo "Complete the AIO installation there."
echo
echo "DO NOT configure the Apache reverse proxy yet."
echo
echo "The separate AIO proxy configuration script should be"
echo "run AFTER the AIO installation has been completed."
echo
echo "The AIO Apache service on port 11222 is NOT required"
echo "to be available at this stage."
echo
echo "Log:"
echo
echo "  $LOG_FILE"
echo
echo "============================================================"
echo

log_success "Nextcloud AIO preparation completed successfully."
