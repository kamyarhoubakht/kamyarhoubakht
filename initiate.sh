#!/usr/bin/env bash

# ============================================================
# Nextcloud AIO installation behind a Virtualmin Apache domain
#
# Requirements:
#   - Run as root
#   - Virtualmin GPL installed
#   - Docker installed
#   - Apache installed
#
# Architecture:
#   Internet
#      |
#   Virtualmin Apache :80/:443
#      |
#   Virtualmin native create-proxy
#      |
#   Nextcloud AIO Apache :11222 (127.0.0.1)
#
# AIO admin interface:
#   http://SERVER:8080
#
# Nextcloud traffic:
#   https://AIO_DOMAIN -> 127.0.0.1:11222
# ============================================================

set -Eeuo pipefail

SCRIPT_NAME="install-nextcloud-aio.sh"
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/nextcloud-aio-install.log"
STATE_FILE="/root/.nextcloud-aio-install.state"

AIO_COMPOSE_DIR="/root/nextcloud-aio"
AIO_COMPOSE_FILE="${AIO_COMPOSE_DIR}/docker-compose.yaml"
AIO_DATA_DIR="/mnt/ncdata"

AIO_IMAGE="ghcr.io/nextcloud-releases/all-in-one:latest"
AIO_WEB_PORT="11222"
AIO_ADMIN_PORT="8080"

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    echo
    echo "============================================================"
    echo "ERROR"
    echo "============================================================"
    echo "$*"
    echo
    echo "Full log:"
    echo "  $LOG_FILE"
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
    echo "============================================================"
    echo "INSTALLATION FAILED"
    echo "============================================================"
    echo "Exit code: $exit_code"
    echo "Line: ${BASH_LINENO[0]:-unknown}"
    echo "Command: ${BASH_COMMAND:-unknown}"
    echo
    echo "Log file:"
    echo "  $LOG_FILE"
    echo
    exit "$exit_code"
}

trap on_error ERR

# ------------------------------------------------------------
# Basic checks
# ------------------------------------------------------------

[[ "$EUID" -eq 0 ]] || die "This script must be run as root."

command -v docker >/dev/null 2>&1 \
    || die "Docker was not found."

command -v virtualmin >/dev/null 2>&1 \
    || die "Virtualmin command was not found."

command -v apache2ctl >/dev/null 2>&1 \
    || die "apache2ctl was not found."

command -v curl >/dev/null 2>&1 \
    || die "curl was not found."

command -v openssl >/dev/null 2>&1 \
    || die "openssl was not found."

log "Nextcloud AIO + Virtualmin installation started."

# ------------------------------------------------------------
# Detect Virtualmin / OS
# ------------------------------------------------------------

log "System information"

echo "OS:"
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "  ${PRETTY_NAME:-unknown}"
fi

echo "Architecture:"
uname -m

echo "Virtualmin:"
virtualmin version || true

echo "Apache:"
apache2ctl -v | head -n 1 || true

echo "Docker:"
docker --version || true

# ------------------------------------------------------------
# Determine administrator username
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
echo "Enter the independent top-level domain/subdomain that will"
echo "be used for Nextcloud."
echo
echo "Example:"
echo "  cloud.example.com"
echo

read -r -p "Nextcloud domain: " AIO_DOMAIN

AIO_DOMAIN="${AIO_DOMAIN,,}"

[[ -n "$AIO_DOMAIN" ]] \
    || die "No domain was supplied."

if [[ ! "$AIO_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    die "Invalid domain name: $AIO_DOMAIN"
fi

log "Nextcloud domain: $AIO_DOMAIN"

# ------------------------------------------------------------
# State
# ------------------------------------------------------------

cat > "$STATE_FILE" <<EOF
AIO_DOMAIN='$AIO_DOMAIN'
AIO_WEB_PORT='$AIO_WEB_PORT'
AIO_ADMIN_PORT='$AIO_ADMIN_PORT'
AIO_DATA_DIR='$AIO_DATA_DIR'
AIO_COMPOSE_FILE='$AIO_COMPOSE_FILE'
EOF

# ------------------------------------------------------------
# Check whether domain already exists
# ------------------------------------------------------------

log "Checking Virtualmin domain"

if virtualmin list-domains --name-only 2>/dev/null \
    | grep -Fxq "$AIO_DOMAIN"; then

    log "Virtualmin domain already exists: $AIO_DOMAIN"

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

for module in "${REQUIRED_MODULES[@]}"; do
    if command -v a2enmod >/dev/null 2>&1; then
        run_cmd a2enmod "$module" || true
    fi
done

# ------------------------------------------------------------
# Create AIO data directory
# ------------------------------------------------------------

log "Creating Nextcloud AIO data directory"

mkdir -p "$AIO_DATA_DIR"

chmod 755 "$AIO_DATA_DIR"

# ------------------------------------------------------------
# Create compose directory
# ------------------------------------------------------------

mkdir -p "$AIO_COMPOSE_DIR"

# ------------------------------------------------------------
# Docker Compose
# ------------------------------------------------------------

log "Writing Nextcloud AIO Docker Compose configuration"

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
# Validate compose
# ------------------------------------------------------------

log "Validating Docker Compose configuration"

if docker compose version >/dev/null 2>&1; then

    run_cmd docker compose \
        -f "$AIO_COMPOSE_FILE" \
        config >/dev/null

else
    die "Docker Compose plugin is not available."
fi

# ------------------------------------------------------------
# Start AIO
# ------------------------------------------------------------

log "Starting Nextcloud AIO"

run_cmd docker compose \
    -f "$AIO_COMPOSE_FILE" \
    up -d

# ------------------------------------------------------------
# Wait for AIO administration interface
# ------------------------------------------------------------

log "Waiting for Nextcloud AIO administration interface on port ${AIO_ADMIN_PORT}"

AIO_READY=0

for i in $(seq 1 60); do

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

log "Nextcloud AIO administration interface is available."

# ------------------------------------------------------------
# IMPORTANT:
# Test the ACTUAL installed Virtualmin API.
#
# Do not use:
#   virtualmin help modify-web | grep ...
#
# The help output is not a reliable capability test across
# Virtualmin versions.
#
# We use a harmless directive and immediately remove it.
# ------------------------------------------------------------

log "Testing Virtualmin native --add-directive API"

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

    die "The installed Virtualmin does not accept --add-directive.

The current Virtualmin GPL source supports this API, but this
installation appears to be using an older/different version.

The test command was:

  virtualmin modify-web --domain $AIO_DOMAIN --add-directive \"LimitRequestBody 0\"

Update Virtualmin and run this script again."

fi

rm -f "$TEST_OUTPUT"

log "Virtualmin --add-directive API is available."

# ------------------------------------------------------------
# Remove test directive
# ------------------------------------------------------------

log "Removing temporary API test directive"

virtualmin modify-web \
    --domain "$AIO_DOMAIN" \
    --remove-directive "$TEST_DIRECTIVE" \
    || die "Could not remove the temporary API test directive."

# ------------------------------------------------------------
# Configure Virtualmin native reverse proxy
# ------------------------------------------------------------

log "Creating Virtualmin native reverse proxy"

# Remove an existing proxy first if the installation was previously
# interrupted. Ignore failure because no proxy may exist.

set +e
virtualmin delete-proxy \
    --domain "$AIO_DOMAIN" \
    --path "/" \
    >/tmp/nextcloud-aio-delete-proxy.log 2>&1
DELETE_PROXY_EXIT=$?
set -e

if [[ "$DELETE_PROXY_EXIT" -ne 0 ]]; then
    echo "No existing proxy was removed (normal for a new installation)."
fi

# ------------------------------------------------------------
# create-proxy
#
# --websockets is supported by the current Virtualmin GPL source.
#
# It creates the native ProxyPass / ProxyPassReverse configuration
# and websocket handling without reconstructing the VirtualHost.
# ------------------------------------------------------------

log "Adding native proxy for / -> http://127.0.0.1:${AIO_WEB_PORT}/"

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

# ------------------------------------------------------------
# Preserve original Host header
# ------------------------------------------------------------

log "Configuring Virtualmin proxy-host handling"

virtualmin modify-web \
    --domain "$AIO_DOMAIN" \
    --proxy-host \
    || die "Virtualmin --proxy-host configuration failed."

# ------------------------------------------------------------
# Native HTTP protocol configuration
#
# --protocols is preferable to --add-directive here because
# Protocols has multiple values and modify-web supports it
# natively.
# ------------------------------------------------------------

log "Configuring HTTP/2 / HTTP/1.1 protocols"

virtualmin modify-web \
    --domain "$AIO_DOMAIN" \
    --protocols "http/1.1 h2" \
    || die "Virtualmin protocol configuration failed."

# ------------------------------------------------------------
# Nextcloud AIO / Apache directives
#
# IMPORTANT:
# Virtualmin's current --add-directive parser accepts:
#
#     DIRECTIVE VALUE
#
# where VALUE is one whitespace-separated token.
#
# Therefore we deliberately only add directives whose values
# consist of a single token.
#
# X-Forwarded-Proto is already handled by Virtualmin's native
# proxy implementation.
#
# X-Real-IP is NOT added here because:
#
#     RequestHeader set X-Real-IP %{REMOTE_ADDR}s
#
# cannot safely be passed through the current --add-directive
# parser.
# ------------------------------------------------------------

log "Adding Nextcloud AIO Apache directives"

NATIVE_DIRECTIVES=(
    "AllowEncodedSlashes NoDecode"
    "H2WindowSize 5242880"
    "TraceEnable off"
    "LimitRequestBody 0"
    "Timeout 3610"
    "ProxyTimeout 3610"
)

for directive in "${NATIVE_DIRECTIVES[@]}"; do

    log "Adding directive: $directive"

    virtualmin modify-web \
        --domain "$AIO_DOMAIN" \
        --add-directive "$directive" \
        || die "Failed to add Apache directive: $directive"

done

# ------------------------------------------------------------
# Apache configuration validation
# ------------------------------------------------------------

log "Validating Apache configuration"

if ! apache2ctl configtest; then

    echo
    echo "Apache configuration is INVALID."
    echo
    echo "The Virtualmin changes have been made, but Apache"
    echo "must not be reloaded until the configuration is fixed."
    echo
    echo "Inspect:"
    echo "  $LOG_FILE"
    echo

    die "Apache configtest failed."

fi

log "Apache configuration is valid."

# ------------------------------------------------------------
# Reload Apache
# ------------------------------------------------------------

log "Reloading Apache"

if command -v systemctl >/dev/null 2>&1; then
    run_cmd systemctl reload apache2
else
    run_cmd service apache2 reload
fi

# ------------------------------------------------------------
# Verify ports
# ------------------------------------------------------------

log "Checking AIO ports"

echo
ss -lntp 2>/dev/null | grep -E ":(${AIO_ADMIN_PORT}|${AIO_WEB_PORT})\b" || true

# ------------------------------------------------------------
# Verify Docker containers
# ------------------------------------------------------------

log "Checking Nextcloud AIO containers"

docker ps \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' \
    | grep -E 'nextcloud-aio|NAMES' \
    || true

# ------------------------------------------------------------
# Final information
# ------------------------------------------------------------

echo
echo "============================================================"
echo "NEXTCLOUD AIO INSTALLATION COMPLETE"
echo "============================================================"
echo
echo "Nextcloud domain:"
echo "  https://${AIO_DOMAIN}"
echo
echo "AIO administration interface:"
echo "  http://SERVER-IP:${AIO_ADMIN_PORT}"
echo
echo "AIO internal Apache:"
echo "  127.0.0.1:${AIO_WEB_PORT}"
echo
echo "Data directory:"
echo "  ${AIO_DATA_DIR}"
echo
echo "Docker Compose:"
echo "  ${AIO_COMPOSE_FILE}"
echo
echo "Installation log:"
echo "  ${LOG_FILE}"
echo
echo "State file:"
echo "  ${STATE_FILE}"
echo
echo "============================================================"
echo
echo "IMPORTANT:"
echo
echo "1. Point DNS for ${AIO_DOMAIN} to this server."
echo
echo "2. Open:"
echo "     https://${AIO_DOMAIN}"
echo
echo "3. The AIO administration interface remains available at:"
echo "     http://SERVER-IP:${AIO_ADMIN_PORT}"
echo
echo "4. Complete the Nextcloud AIO setup from that interface."
echo
echo "5. The reverse proxy is managed by Virtualmin's native"
echo "   create-proxy / modify-web APIs."
echo
echo "============================================================"

