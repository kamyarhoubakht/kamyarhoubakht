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

for command in docker docker-compose virtualmin apache2ctl curl; do
    if ! command -v "$command" >/dev/null 2>&1; then

        # docker compose is a plugin, so docker-compose itself may not exist.
        if [[ "$command" == "docker-compose" ]] &&
           docker compose version >/dev/null 2>&1; then
            continue
        fi

        log_error "Required command not found: $command"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Check Virtualmin
# ---------------------------------------------------------------------------

if ! command -v virtualmin >/dev/null 2>&1; then
    log_error "Virtualmin command not found."
    exit 1
fi

# ---------------------------------------------------------------------------
# Check Apache
# ---------------------------------------------------------------------------

if ! command -v apache2ctl >/dev/null 2>&1; then
    log_error "Apache is not installed."
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
# This is deliberately a TOP-LEVEL Virtualmin domain.
#
# It does NOT need to belong to another Virtualmin parent domain.
# DNS can remain completely external.
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
    echo "Enter the complete domain that will point to this server."
    echo
    echo "Example:"
    echo "  cloud.example.com"
    echo
    echo "DNS for this domain must point to this server's public IP."
    echo "It does NOT need to exist as a parent domain in Virtualmin."
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
            echo "Invalid domain:"
            echo "  $aio_domain"
            echo
            echo "Please enter a complete domain such as:"
            echo "  cloud.example.com"
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
# Check whether Virtualmin domain already exists
# ---------------------------------------------------------------------------

if virtualmin list-domains --name-only 2>/dev/null \
    | grep -Fxq "$aio_domain"; then

    log_success "Virtualmin domain already exists: $aio_domain"

else

    # -----------------------------------------------------------------------
    # Create independent TOP-LEVEL Virtualmin domain.
    #
    # Deliberately enabled:
    #   --unix
    #   --dir
    #   --web
    #   --ssl
    #
    # Deliberately NOT enabled:
    #   --mail
    #   --dns
    #   --webmin
    #   --mysql
    #   --postgres
    #   --ftp
    #
    # No parent domain is specified.
    # -----------------------------------------------------------------------

    log_step "Creating independent Virtualmin Apache domain"

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
# Verify that Apache web support exists
# ---------------------------------------------------------------------------

if ! virtualmin list-domains --name-only 2>/dev/null \
    | grep -Fxq "$aio_domain"; then

    log_error "Virtualmin failed to create/find $aio_domain."
    exit 1

fi

# ---------------------------------------------------------------------------
# Enable required Apache modules
# ---------------------------------------------------------------------------

log_step "Enabling Apache proxy modules"

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
# AIO data directory
# ---------------------------------------------------------------------------

if ! step_done "aio_data"; then

    log_step "Creating Nextcloud AIO data directory"

    mkdir -p /mnt/ncdata

    chmod 750 /mnt/ncdata

    mark_done "aio_data"

    log_success "Nextcloud data directory ready."

else

    log_success "Nextcloud data directory already exists."

fi

# ---------------------------------------------------------------------------
# Nextcloud AIO Docker configuration
# ---------------------------------------------------------------------------

AIO_DIR="/root/nextcloud-aio"

mkdir -p "$AIO_DIR"

AIO_COMPOSE="$AIO_DIR/docker-compose.yaml"

if ! step_done "aio_container"; then

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
      - "127.0.0.1:8080:8080"
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

    log_success "AIO Docker Compose file created."

    mark_done "aio_container"

else

    log_success "AIO Docker configuration already exists."

fi

# ---------------------------------------------------------------------------
# Start Nextcloud AIO
# ---------------------------------------------------------------------------

log_step "Starting Nextcloud AIO"

(
    cd "$AIO_DIR"
    docker compose up -d
)

log_success "Nextcloud AIO container started."

# ---------------------------------------------------------------------------
# Wait for AIO Apache
# ---------------------------------------------------------------------------

log_step "Waiting for AIO Apache on 127.0.0.1:11222"

aio_ready=false

for i in {1..90}; do

    if curl \
        --silent \
        --show-error \
        --fail \
        --max-time 3 \
        http://127.0.0.1:11222/ \
        >/dev/null 2>&1; then

        aio_ready=true
        break

    fi

    sleep 2

done

if [[ "$aio_ready" != true ]]; then

    log_error "AIO Apache did not become available."

    echo
    echo "Docker container status:"
    docker ps -a --filter "name=nextcloud-aio-mastercontainer"

    echo
    echo "Recent AIO logs:"
    docker logs --tail 100 nextcloud-aio-mastercontainer || true

    exit 1

fi

log_success "AIO Apache is running on 127.0.0.1:11222."

# ---------------------------------------------------------------------------
# Create Apache proxy configuration
#
# We use a Virtualmin-managed custom Apache include for this domain.
# The configuration is kept in /etc/apache2/conf-available so it is easy
# to inspect and manage independently from Virtualmin-generated files.
# ---------------------------------------------------------------------------

log_step "Creating Apache reverse-proxy configuration"

PROXY_CONF="/etc/apache2/conf-available/nextcloud-aio-${aio_domain}.conf"

cat > "$PROXY_CONF" <<EOF
# ---------------------------------------------------------------------------
# Nextcloud AIO reverse proxy
# Domain: $aio_domain
#
# Managed by install-nextcloud-aio.sh
# Backend: http://127.0.0.1:11222/
# ---------------------------------------------------------------------------

<IfModule mod_proxy.c>

    ProxyPreserveHost On

    AllowEncodedSlashes NoDecode

    RequestHeader set X-Real-IP %{REMOTE_ADDR}s

    ProxyPass / http://127.0.0.1:11222/ nocanon
    ProxyPassReverse / http://127.0.0.1:11222/

    <IfModule mod_rewrite.c>

        RewriteEngine On

        RewriteCond %{HTTP:Upgrade} websocket [NC]
        RewriteCond %{HTTP:Connection} upgrade [NC]
        RewriteCond %{THE_REQUEST} "^[a-zA-Z]+ /(.*) HTTP/\\d+(\\.\\d+)?$"
        RewriteRule .? "ws://127.0.0.1:11222/%1" [P,L,UnsafeAllow3F]

    </IfModule>

</IfModule>

# Solves slow upload speeds caused by HTTP/2
H2WindowSize 5242880

# Disable HTTP TRACE method.
TraceEnable off

<Files ".ht*">
    Require all denied
</Files>

# Support big file uploads
LimitRequestBody 0

Timeout 86400
ProxyTimeout 86400
EOF

chmod 644 "$PROXY_CONF"

# ---------------------------------------------------------------------------
# Enable the configuration
# ---------------------------------------------------------------------------

a2enconf "nextcloud-aio-${aio_domain}" >/dev/null

log_success "Apache reverse-proxy configuration enabled."

# ---------------------------------------------------------------------------
# IMPORTANT:
#
# The proxy directives above are global Apache directives. They must only
# apply to the AIO domain. Therefore we add the configuration directly to
# the Virtualmin-generated VirtualHost using an include.
#
# Find the SSL VirtualHost generated by Virtualmin and add the include
# inside it if it is not already present.
# ---------------------------------------------------------------------------

log_step "Attaching proxy configuration to the Virtualmin virtual host"

APACHE_SITE="$(find /etc/apache2/sites-enabled \
    -maxdepth 1 \
    -type f \
    \( -name "*${aio_domain}*.conf" -o -name "*.conf" \) \
    -print 2>/dev/null \
    | while read -r file; do
        if grep -q "ServerName[[:space:]]\+$aio_domain" "$file" 2>/dev/null; then
            echo "$file"
            break
        fi
    done
)"

if [[ -z "$APACHE_SITE" ]]; then
    log_error "Could not locate the Apache VirtualHost for $aio_domain."
    exit 1
fi

log_success "Virtualmin Apache configuration found: $APACHE_SITE"

# ---------------------------------------------------------------------------
# Add the Include only once.
# ---------------------------------------------------------------------------

if ! grep -Fq "$PROXY_CONF" "$APACHE_SITE"; then

    cp -a "$APACHE_SITE" "${APACHE_SITE}.nextcloud-aio-backup"

    # Insert the include immediately before the closing VirtualHost.
    sed -i \
        "\#</VirtualHost>#i IncludeOptional $PROXY_CONF" \
        "$APACHE_SITE"

    log_success "Proxy configuration attached to $aio_domain."

else

    log_success "Proxy configuration already attached."

fi

# ---------------------------------------------------------------------------
# Test Apache configuration
# ---------------------------------------------------------------------------

log_step "Testing Apache configuration"

if ! apache2ctl configtest; then

    log_error "Apache configuration test failed."

    echo
    echo "The previous Virtualmin configuration was backed up to:"
    echo "  ${APACHE_SITE}.nextcloud-aio-backup"
    echo

    exit 1

fi

log_success "Apache configuration is valid."

systemctl reload apache2

log_success "Apache reloaded."

# ---------------------------------------------------------------------------
# Request Let's Encrypt certificate
#
# DNS must already point aio_domain to this server.
# ---------------------------------------------------------------------------

log_step "Requesting Let's Encrypt certificate for $aio_domain"

if virtualmin list-domains --domain "$aio_domain" --multiline 2>/dev/null \
    | grep -qi "SSL.*yes"; then

    virtualmin generate-letsencrypt-cert \
        --domain "$aio_domain" \
        --web \
        --renew

else

    log_step "Enabling SSL and requesting Let's Encrypt certificate"

    virtualmin modify-web \
        --domain "$aio_domain" \
        --ssl \
        --letsencrypt-renew

    virtualmin generate-letsencrypt-cert \
        --domain "$aio_domain" \
        --web \
        --renew

fi

log_success "Let's Encrypt certificate configured."

# ---------------------------------------------------------------------------
# Final Apache test and reload
# ---------------------------------------------------------------------------

log_step "Performing final Apache configuration test"

apache2ctl configtest

systemctl reload apache2

log_success "Apache final reload completed."

# ---------------------------------------------------------------------------
# Verify proxy locally
# ---------------------------------------------------------------------------

log_step "Checking AIO backend"

if curl \
    --silent \
    --show-error \
    --fail \
    --max-time 10 \
    http://127.0.0.1:11222/ \
    >/dev/null 2>&1; then

    log_success "AIO backend responds correctly."

else

    log_error "AIO backend did not respond."
    exit 1

fi

# ---------------------------------------------------------------------------
# Save state
# ---------------------------------------------------------------------------

mark_done "complete"

# ---------------------------------------------------------------------------
# Final information
# ---------------------------------------------------------------------------

echo
echo "============================================================"
echo " Nextcloud AIO installation completed"
echo "============================================================"
echo
echo "Nextcloud:"
echo "  https://$aio_domain"
echo
echo "AIO management:"
echo "  http://127.0.0.1:8080"
echo
echo "AIO Apache backend:"
echo "  http://127.0.0.1:11222"
echo
echo "Data directory:"
echo "  /mnt/ncdata"
echo
echo "AIO directory:"
echo "  $AIO_DIR"
echo
echo "Apache proxy configuration:"
echo "  $PROXY_CONF"
echo
echo "Virtualmin domain:"
echo "  $aio_domain"
echo
echo "Installation log:"
echo "  $LOG_FILE"
echo
echo "Installation state:"
echo "  $STATE_FILE"
echo
echo "============================================================"
