#!/usr/bin/env bash

# ============================================================
# Nextcloud AIO installation behind Virtualmin Apache
#
# Uses ONLY Virtualmin's native APIs for Apache configuration:
#   - create-proxy
#   - modify-web
#
# No manual VirtualHost reconstruction.
# No save_directive_struct().
#
# Architecture:
#
#   Internet
#      |
#      v
#   Virtualmin Apache :80 / :443
#      |
#      v
#   Virtualmin create-proxy
#      |
#      v
#   127.0.0.1:11222
#      |
#      v
#   Nextcloud AIO Apache
#
# AIO management interface:
#   http://SERVER-IP:8080
#
# ============================================================

set -Eeuo pipefail

SCRIPT_NAME="install-nextcloud-aio.sh"

LOG_FILE="/var/log/nextcloud-aio-install.log"
STATE_FILE="/root/.nextcloud-aio-install.state"

AIO_COMPOSE_DIR="/root/nextcloud-aio"
AIO_COMPOSE_FILE="${AIO_COMPOSE_DIR}/docker-compose.yaml"

AIO_DATA_DIR="/mnt/ncdata"

AIO_IMAGE="ghcr.io/nextcloud-releases/all-in-one:latest"

AIO_ADMIN_PORT="8080"
AIO_WEB_PORT="11222"

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo
    echo "============================================================"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "============================================================"
}

die() {
    echo
    echo "❌ ============================================================"
    echo "❌ ERROR"
    echo "❌ ============================================================"
    echo
    echo "❌ $*"
    echo
    echo "❌ Full log:"
    echo "❌ $LOG_FILE"
    echo
    exit 1
}

run_cmd() {
    echo
    echo "+ $*"
    "$@"
}

on_error() {
    local exit_code=$?

    echo
    echo "❌ ============================================================"
    echo "❌ INSTALLATION FAILED"
    echo "❌ ============================================================"
    echo
    echo "Exit code: $exit_code"
    echo "Line: ${BASH_LINENO[0]:-unknown}"
    echo "Command: ${BASH_COMMAND:-unknown}"
    echo
    echo "Full log:"
    echo "  $LOG_FILE"
    echo

    exit "$exit_code"
}

trap on_error ERR

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

[[ "$EUID" -eq 0 ]] || die "This script must be run as root."

log "Starting Nextcloud AIO installation"

# ------------------------------------------------------------
# Required commands
# ------------------------------------------------------------

for command in docker virtualmin apache2ctl curl openssl; do

    if ! command -v "$command" >/dev/null 2>&1; then
        die "Required command not found: $command"
    fi

done

# ------------------------------------------------------------
# System information
# ------------------------------------------------------------

log "System information"

if [[ -r /etc/os-release ]]; then
    . /etc/os-release

    echo "OS:"
    echo "  ${PRETTY_NAME:-unknown}"
fi

echo
echo "Architecture:"
uname -m

echo
echo "Virtualmin:"
virtualmin version || true

echo
echo "Apache:"
apache2ctl -v | head -n 1 || true

echo
echo "Docker:"
docker --version || true

echo
echo "Docker Compose:"
docker compose version || true

# ------------------------------------------------------------
# Administrator username
# ------------------------------------------------------------

ADMIN_USER="${1:-}"

if [[ -z "$ADMIN_USER" ]]; then

    read -r -p "Virtualmin administrator username [root]: " ADMIN_USER

    ADMIN_USER="${ADMIN_USER:-root}"

fi

log "Virtualmin administrator: $ADMIN_USER"

# ------------------------------------------------------------
# Ask for domain
# ------------------------------------------------------------

echo
echo "============================================================"
echo "Nextcloud AIO domain"
echo "============================================================"
echo
echo "Enter the independent domain/subdomain that will be used"
echo "for Nextcloud."
echo
echo "Example:"
echo
echo "  cloud.example.com"
echo

read -r -p "Nextcloud domain: " AIO_DOMAIN

AIO_DOMAIN="${AIO_DOMAIN,,}"

[[ -n "$AIO_DOMAIN" ]] || die "No domain was supplied."

if [[ ! "$AIO_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    die "Invalid domain name: $AIO_DOMAIN"
fi

log "Nextcloud domain: $AIO_DOMAIN"

# ------------------------------------------------------------
# Save state
# ------------------------------------------------------------

cat > "$STATE_FILE" <<EOF
AIO_DOMAIN='$AIO_DOMAIN'
AIO_ADMIN_PORT='$AIO_ADMIN_PORT'
AIO_WEB_PORT='$AIO_WEB_PORT'
AIO_DATA_DIR='$AIO_DATA_DIR'
AIO_COMPOSE_FILE='$AIO_COMPOSE_FILE'
EOF

# ------------------------------------------------------------
# Create Virtualmin domain
# ------------------------------------------------------------

log "Checking Virtualmin domain"

if virtualmin list-domains --name-only 2>/dev/null \
    | grep -Fxq "$AIO_DOMAIN"; then

    echo "Virtualmin domain already exists:"
    echo "  $AIO_DOMAIN"

else

    log "Creating Virtualmin domain: $AIO_DOMAIN"

    virtualmin create-domain \
        --domain "$AIO_DOMAIN" \
        --unix \
        --dir \
        --web \
        --ssl \
        --skip-warnings \
        || die "Virtualmin failed to create $AIO_DOMAIN."

fi

# ------------------------------------------------------------
# Apache modules
# ------------------------------------------------------------

log "Enabling required Apache modules"

REQUIRED_MODULES=(
    proxy
    proxy_http
    proxy_wstunnel
    rewrite
    headers
    ssl
    http2
)

if command -v a2enmod >/dev/null 2>&1; then

    for module in "${REQUIRED_MODULES[@]}"; do

        echo "Enabling Apache module: $module"

        a2enmod "$module" || true

    done

fi

# ------------------------------------------------------------
# Create Nextcloud data directory
# ------------------------------------------------------------

log "Creating Nextcloud data directory"

mkdir -p "$AIO_DATA_DIR"

chmod 755 "$AIO_DATA_DIR"

# ------------------------------------------------------------
# Docker Compose directory
# ------------------------------------------------------------

mkdir -p "$AIO_COMPOSE_DIR"

# ------------------------------------------------------------
# Create Docker Compose file
# ------------------------------------------------------------

log "Creating Nextcloud AIO Docker Compose configuration"

cat > "$AIO_COMPOSE_FILE" <<EOF
services:

  nextcloud-aio-mastercontainer:

    image: ${AIO_IMAGE}

    container_name: nextcloud-aio-mastercontainer

    restart: always

    ports:
      - "${AIO_ADMIN_PORT}:8080"
      - "127.0.0.1:${AIO_WEB_PORT}:11222"

    volumes:
      - nextcloud_aio_mastercontainer:/mnt/docker-aio-config
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${AIO_DATA_DIR}:/mnt/ncdata

    environment:

      APACHE_PORT: 11222

      APACHE_IP_BINDING: 127.0.0.1

      SKIP_DOMAIN_VALIDATION: true

      NEXTCLOUD_DATADIR: /mnt/ncdata

      NEXTCLOUD_MOUNT: /mnt/

      NEXTCLOUD_STARTUP_APPS: twofactor_totp calendar contacts files_external

      NEXTCLOUD_ENABLE_DRI_DEVICE: false

volumes:

  nextcloud_aio_mastercontainer:

    name: nextcloud_aio_mastercontainer
EOF

# ------------------------------------------------------------
# Validate Docker Compose
# ------------------------------------------------------------

log "Validating Docker Compose configuration"

docker compose \
    -f "$AIO_COMPOSE_FILE" \
    config >/dev/null \
    || die "Docker Compose configuration is invalid."

# ------------------------------------------------------------
# Start AIO
# ------------------------------------------------------------

log "Starting Nextcloud AIO"

docker compose \
    -f "$AIO_COMPOSE_FILE" \
    up -d \
    || die "Failed to start Nextcloud AIO."

# ------------------------------------------------------------
# Wait for AIO admin interface
# ------------------------------------------------------------

log "Waiting for Nextcloud AIO administration interface"

AIO_READY=0

for i in $(seq 1 90); do

    if curl \
        --silent \
        --show-error \
        --max-time 3 \
        "http://127.0.0.1:${AIO_ADMIN_PORT}/" \
        >/dev/null 2>&1; then

        AIO_READY=1
        break

    fi

    printf "."

    sleep 2

done

echo

[[ "$AIO_READY" -eq 1 ]] \
    || die "Nextcloud AIO did not become available on port ${AIO_ADMIN_PORT}."

echo
echo "Nextcloud AIO administration interface is available."

# ============================================================
# VIRTUALMIN NATIVE API
# ============================================================

log "Testing Virtualmin native --add-directive API"

# ------------------------------------------------------------
# IMPORTANT
#
# Do NOT test this using:
#
#   virtualmin help modify-web
#
# The help output is not a reliable capability test across
# Virtualmin versions.
#
# Instead, perform the same real operation that we need,
# using a harmless temporary directive.
# ------------------------------------------------------------

TEST_DIRECTIVE="LimitRequestBody 0"

TEST_OUTPUT="$(mktemp)"

set +e

virtualmin modify-web \
    --domain "$AIO_DOMAIN" \
    --add-directive "$TEST_DIRECTIVE" \
    >"$TEST_OUTPUT" 2>&1

TEST_EXIT_CODE=$?

set -e

cat "$TEST_OUTPUT"

if [[ "$TEST_EXIT_CODE" -ne 0 ]]; then

    rm -f "$TEST_OUTPUT"

    die "Virtualmin --add-directive API is NOT available.

The actual command failed:

  virtualmin modify-web \\
      --domain $AIO_DOMAIN \\
      --add-directive \"$TEST_DIRECTIVE\"

This installation cannot continue using the native Virtualmin
directive API."

fi

rm -f "$TEST_OUTPUT"

echo
echo "✓ Virtualmin --add-directive API works."

# ------------------------------------------------------------
# Remove temporary test directive
# ------------------------------------------------------------

log "Removing temporary API test directive"

virtualmin modify-web \
    --domain "$AIO_DOMAIN" \
    --remove-directive "$TEST_DIRECTIVE" \
    || die "Could not remove temporary test directive."

echo "✓ Temporary directive removed."

# ============================================================
# CREATE NATIVE VIRTUALMIN PROXY
# ============================================================

log "Creating Virtualmin native reverse proxy"

# ------------------------------------------------------------
# Remove an old proxy if this installation was previously
# attempted.
#
# Failure is harmless because a new installation normally has
# no proxy yet.
# ------------------------------------------------------------

echo "Checking for an existing proxy..."

set +e

virtualmin delete-proxy \
    --domain "$AIO_DOMAIN" \
    --path "/" \
    >/tmp/nextcloud-aio-delete-proxy.log 2>&1

DELETE_EXIT=$?

set -e

if [[ "$DELETE_EXIT" -eq 0 ]]; then

    echo "Existing proxy removed."

else

    echo "No existing proxy found."

fi

# ------------------------------------------------------------
# create-proxy
#
# This is the important part.
#
# Virtualmin itself creates:
#
#   ProxyPass
#   ProxyPassReverse
#   websocket handling
#   X-Forwarded-Proto handling
#
# without manually modifying the VirtualHost structure.
# ------------------------------------------------------------

log "Creating proxy: / -> http://127.0.0.1:${AIO_WEB_PORT}/"

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

if [[ "$PROXY_EXIT_CODE" -ne 0 ]]; then

    rm -f "$PROXY_OUTPUT"

    die "Virtualmin create-proxy failed."

fi

rm -f "$PROXY_OUTPUT"

echo
echo "✓ Native Virtualmin reverse proxy created."

# ============================================================
# PROXY HOST
# ============================================================

log "Enabling Virtualmin proxy-host handling"

virtualmin modify-web \
    --domain "$AIO_DOMAIN" \
    --proxy-host \
    || die "Virtualmin --proxy-host configuration failed."

echo
echo "✓ Proxy host configured."

# ============================================================
# HTTP PROTOCOLS
# ============================================================

log "Configuring HTTP protocols"

# Use the dedicated --protocols API rather than --add-directive
# because Protocols accepts multiple values.

virtualmin modify-web \
    --domain "$AIO_DOMAIN" \
    --protocols "http/1.1 h2" \
    || die "Virtualmin protocol configuration failed."

echo
echo "✓ HTTP/2 and HTTP/1.1 configured."

# ============================================================
# NEXTCLOUD AIO APACHE DIRECTIVES
# ============================================================

log "Adding Nextcloud AIO Apache directives"

# ------------------------------------------------------------
# IMPORTANT:
#
# Current Virtualmin --add-directive parsing accepts:
#
#     DIRECTIVE VALUE
#
# with VALUE being one whitespace-separated token.
#
# Therefore these directives are deliberately limited to
# directives whose value is a single token.
#
# We DO NOT attempt:
#
#   RequestHeader set X-Real-IP %{REMOTE_ADDR}s
#
# because that requires multiple value tokens and cannot safely
# be represented through the current --add-directive interface.
#
# X-Forwarded-Proto is already handled by Virtualmin's native
# proxy implementation.
# ------------------------------------------------------------

NATIVE_DIRECTIVES=(
    "AllowEncodedSlashes NoDecode"
    "H2WindowSize 5242880"
    "TraceEnable off"
    "LimitRequestBody 0"
    "Timeout 3610"
    "ProxyTimeout 3610"
)

for directive in "${NATIVE_DIRECTIVES[@]}"; do

    log "Adding Apache directive: $directive"

    virtualmin modify-web \
        --domain "$AIO_DOMAIN" \
        --add-directive "$directive" \
        || die "Failed to add Apache directive: $directive"

done

echo
echo "✓ Nextcloud AIO Apache directives added."

# ============================================================
# APACHE CONFIGURATION TEST
# ============================================================

log "Validating Apache configuration"

if ! apache2ctl configtest; then

    echo
    echo "❌ Apache configuration test FAILED."
    echo
    echo "The configuration has NOT been reloaded."
    echo
    echo "Review:"
    echo
    echo "  $LOG_FILE"
    echo

    die "Apache configuration is invalid."

fi

echo
echo "✓ Apache configuration is valid."

# ============================================================
# RELOAD APACHE
# ============================================================

log "Reloading Apache"

if command -v systemctl >/dev/null 2>&1; then

    systemctl reload apache2

else

    service apache2 reload

fi

echo
echo "✓ Apache reloaded successfully."

# ============================================================
# VERIFY PORTS
# ============================================================

log "Checking Nextcloud AIO ports"

echo

ss -lntp 2>/dev/null \
    | grep -E ":(${AIO_ADMIN_PORT}|${AIO_WEB_PORT})\b" \
    || true

# ============================================================
# VERIFY CONTAINERS
# ============================================================

log "Checking Nextcloud AIO containers"

docker ps \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' \
    | grep -E 'nextcloud-aio|NAMES' \
    || true

# ============================================================
# FINAL
# ============================================================

echo
echo
echo "============================================================"
echo "✓ NEXTCLOUD AIO INSTALLATION COMPLETE"
echo "============================================================"
echo
echo "Nextcloud domain:"
echo
echo "  https://${AIO_DOMAIN}"
echo
echo "AIO administration interface:"
echo
echo "  http://SERVER-IP:${AIO_ADMIN_PORT}"
echo
echo "AIO internal Apache:"
echo
echo "  127.0.0.1:${AIO_WEB_PORT}"
echo
echo "Nextcloud data:"
echo
echo "  ${AIO_DATA_DIR}"
echo
echo "Docker Compose:"
echo
echo "  ${AIO_COMPOSE_FILE}"
echo
echo "Installation log:"
echo
echo "  ${LOG_FILE}"
echo
echo "State:"
echo
echo "  ${STATE_FILE}"
echo
echo "============================================================"
echo
echo "NEXT STEPS"
echo "============================================================"
echo
echo "1. Point DNS for ${AIO_DOMAIN} to this server."
echo
echo "2. Open:"
echo
echo "     https://${AIO_DOMAIN}"
echo
echo "3. Open the AIO administration interface:"
echo
echo "     http://SERVER-IP:${AIO_ADMIN_PORT}"
echo
echo "4. Complete the AIO setup."
echo
echo "============================================================"
