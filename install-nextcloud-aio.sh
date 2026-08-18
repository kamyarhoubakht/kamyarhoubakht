#!/bin/bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/nextcloud-aio-install.log"
STATE_FILE="/root/.nextcloud_aio_state"

touch "$LOG_FILE"
touch "$STATE_FILE"

chmod 600 "$STATE_FILE"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

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

step_done() {
    grep -qxF "$1" "$STATE_FILE" 2>/dev/null
}

mark_done() {
    grep -qxF "$1" "$STATE_FILE" 2>/dev/null || \
        echo "$1" >> "$STATE_FILE"
}

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

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    log_error "This script must be run as root."
    exit 1
fi

# ---------------------------------------------------------------------------
# Required commands
# ---------------------------------------------------------------------------

for command in docker virtualmin apache2ctl curl openssl; do
    if ! command -v "$command" >/dev/null 2>&1; then
        log_error "Required command not found: $command"
        exit 1
    fi
done

if ! docker compose version >/dev/null 2>&1; then
    log_error "Docker Compose plugin is not available."
    exit 1
fi

# ---------------------------------------------------------------------------
# Check Virtualmin
# ---------------------------------------------------------------------------

if ! command -v virtualmin >/dev/null 2>&1; then
    log_error "Virtualmin command not found."
    exit 1
fi

# ---------------------------------------------------------------------------
# Check Docker
# ---------------------------------------------------------------------------

if ! systemctl is-active --quiet docker; then
    log_error "Docker is not running."
    exit 1
fi

# ---------------------------------------------------------------------------
# Ask for AIO domain
#
# This is an independent TOP-LEVEL Virtualmin domain.
#
# It does not require a parent domain to exist on this server.
# DNS can be managed elsewhere.
# ---------------------------------------------------------------------------

if [[ -f /root/.nextcloud_aio_domain ]]; then

    aio_domain="$(cat /root/.nextcloud_aio_domain)"

    echo
    echo "Existing Nextcloud AIO domain: $aio_domain"
    read -rp "Use this domain? (Y/n): " reuse_domain

    reuse_domain="${reuse_domain:-y}"
    reuse_domain="$(echo "$reuse_domain" | tr '[:upper:]' '[:lower:]')"

    if [[ "$reuse_domain" != "y" ]]; then
        rm -f /root/.nextcloud_aio_domain
    fi

fi

if [[ ! -f /root/.nextcloud_aio_domain ]]; then

    echo
    echo "============================================================"
    echo " Nextcloud AIO domain"
    echo "============================================================"
    echo
    echo "Enter the complete domain that will be used for Nextcloud."
    echo
    echo "Example:"
    echo "  cloud.example.com"
    echo
    echo "DNS for this domain must eventually point to this server."
    echo "The parent domain does NOT need to exist in Virtualmin."
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

    echo "$aio_domain" > /root/.nextcloud_aio_domain
    chmod 600 /root/.nextcloud_aio_domain

fi

log_success "Nextcloud AIO domain: $aio_domain"

# ---------------------------------------------------------------------------
# Create independent Virtualmin top-level domain
#
# This domain is used only as the future Apache reverse-proxy endpoint.
#
# No mail.
# No DNS.
# No databases.
# No FTP.
# No additional subdomains.
# ---------------------------------------------------------------------------

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

    log_success "Virtualmin domain created: $aio_domain"

fi

# ---------------------------------------------------------------------------
# Required Apache modules
#
# They are enabled now, although the proxy itself will be configured later.
# ---------------------------------------------------------------------------

log_step "Enabling required Apache modules"

a2enmod \
    proxy \
    proxy_http \
    proxy_wstunnel \
    rewrite \
    headers \
    http2 \
    ssl \
    >/dev/null

log_success "Apache proxy modules enabled."

# ---------------------------------------------------------------------------
# Nextcloud data directory
# ---------------------------------------------------------------------------

if ! step_done "aio_data"; then

    log_step "Creating Nextcloud AIO data directory"

    mkdir -p /mnt/ncdata

    chmod 750 /mnt/ncdata

    mark_done "aio_data"

    log_success "Nextcloud data directory created."

else

    log_success "Nextcloud data directory already exists."

fi

# ---------------------------------------------------------------------------
# Docker Compose
# ---------------------------------------------------------------------------

AIO_DIR="/root/nextcloud-aio"
AIO_COMPOSE="$AIO_DIR/docker-compose.yaml"

mkdir -p "$AIO_DIR"

if ! step_done "aio_compose"; then

    log_step "Creating Nextcloud AIO Docker Compose configuration"

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
      # AIO initial setup interface.
      # Intentionally publicly accessible.
      - "8080:8080"

      # Nextcloud Apache backend.
      # Must NEVER be exposed publicly.
      - "127.0.0.1:11222:11222"

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

    mark_done "aio_compose"

    log_success "AIO Docker Compose file created."

else

    log_success "AIO Docker Compose file already exists."

fi

# ---------------------------------------------------------------------------
# Start / recreate AIO mastercontainer
# ---------------------------------------------------------------------------

log_step "Starting Nextcloud AIO mastercontainer"

(
    cd "$AIO_DIR"
    docker compose up -d
)

log_success "Nextcloud AIO mastercontainer started."

# ---------------------------------------------------------------------------
# Wait only for AIO setup interface on port 8080
#
# IMPORTANT:
#
# Port 11222 is NOT checked here.
#
# The AIO Apache backend only becomes available after the AIO setup process
# has been completed through the 8080 interface.
# ---------------------------------------------------------------------------

log_step "Waiting for Nextcloud AIO setup interface on port 8080"

aio_ready=false

for i in {1..60}; do

    if curl \
        --silent \
        --show-error \
        --max-time 3 \
        http://127.0.0.1:8080/ \
        >/dev/null 2>&1; then

        aio_ready=true
        break

    fi

    sleep 2

done

if [[ "$aio_ready" != true ]]; then

    log_error "Nextcloud AIO setup interface did not become available."

    echo
    echo "Container status:"
    docker ps -a --filter "name=nextcloud-aio-mastercontainer"

    echo
    echo "Recent AIO logs:"
    docker logs --tail 100 nextcloud-aio-mastercontainer || true

    exit 1

fi

log_success "Nextcloud AIO setup interface is available."

# ---------------------------------------------------------------------------
# Detect server IP
# ---------------------------------------------------------------------------

SERVER_IP="$(hostname -I | awk '{print $1}')"

# ---------------------------------------------------------------------------
# Final message
# ---------------------------------------------------------------------------

echo
echo "============================================================"
echo " Nextcloud AIO is ready for initial configuration"
echo "============================================================"
echo
echo "AIO setup interface:"
echo
echo "  http://$SERVER_IP:8080"
echo
echo "AIO mastercontainer:"
echo "  $AIO_DIR"
echo
echo "AIO backend:"
echo "  127.0.0.1:11222"
echo
echo "Nextcloud domain:"
echo "  https://$aio_domain"
echo
echo "IMPORTANT:"
echo
echo "  Complete the Nextcloud AIO setup through port 8080 first."
echo
echo "  DO NOT configure the Apache reverse proxy yet."
echo "  Port 11222 will become available only after AIO setup."
echo
echo "After AIO setup is complete, run the separate proxy"
echo "configuration script."
echo
echo "Log:"
echo "  $LOG_FILE"
echo
echo "============================================================"
echo

mark_done "setup_ready"
