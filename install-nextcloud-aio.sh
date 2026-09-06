#!/bin/bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ============================================================================
# Configuration
# ============================================================================

LOG_FILE="/var/log/nextcloud-aio-install.log"
STATE_FILE="/root/.nextcloud_aio_state"
DOMAIN_FILE="/root/.nextcloud_aio_domain"

AIO_DIR="/root/nextcloud-aio"
AIO_COMPOSE="$AIO_DIR/docker-compose.yaml"

AIO_APACHE_PORT="11222"
AIO_APACHE_BINDING="127.0.0.1"

AIO_IMAGE="ghcr.io/nextcloud-releases/all-in-one:latest"

mkdir -p /var/log

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

log_warning() {
    echo "⚠️  $1" | tee -a "$LOG_FILE" >&2
}

log_error() {
    echo "❌ $1" | tee -a "$LOG_FILE" >&2
}

log_info() {
    echo "   $1" | tee -a "$LOG_FILE"
}

step_done() {
    grep -qxF "$1" "$STATE_FILE" 2>/dev/null
}

mark_done() {
    grep -qxF "$1" "$STATE_FILE" 2>/dev/null || \
        echo "$1" >> "$STATE_FILE"
}

# ============================================================================
# Run a command and capture ALL output.
#
# We intentionally don't simply pipe everything through tee because with
# "set -euo pipefail" that can make diagnosis unnecessarily difficult.
# ============================================================================

run_logged() {

    local description="$1"
    shift

    local output_file
    local exit_code

    output_file="$(mktemp)"

    echo "+ $*" | tee -a "$LOG_FILE"

    set +e

    "$@" >"$output_file" 2>&1

    exit_code=$?

    set -e

    cat "$output_file" | tee -a "$LOG_FILE"

    if [[ "$exit_code" -ne 0 ]]; then
        log_error "$description failed."
        log_error "Exit code: $exit_code"
        log_error "Command output was recorded above."
        rm -f "$output_file"
        return "$exit_code"
    fi

    rm -f "$output_file"

    return 0
}

# ============================================================================
# Error handling
# ============================================================================

handle_error() {

    local exit_code=$?
    local line_number="$1"

    echo

    log_error "Nextcloud AIO installation failed."
    log_error "Line: $line_number"
    log_error "Exit code: $exit_code"
    log_error "Full log: $LOG_FILE"

    echo

    exit "$exit_code"
}

trap 'handle_error $LINENO' ERR

# ============================================================================
# Root check
# ============================================================================

if [[ "$EUID" -ne 0 ]]; then
    log_error "This script must be run as root."
    exit 1
fi

# ============================================================================
# Detect operating system
# ============================================================================

if [[ ! -f /etc/os-release ]]; then
    log_error "Cannot determine operating system."
    exit 1
fi

. /etc/os-release

OS_ID="${ID:-}"
OS_VERSION_ID="${VERSION_ID:-}"
ARCH="$(dpkg --print-architecture)"

log_step "Checking operating system"

case "$OS_ID" in

    debian)

        case "$OS_VERSION_ID" in

            12|13)
                log_success "Supported Debian version: $OS_VERSION_ID"
                ;;

            *)
                log_error "Unsupported Debian version: $OS_VERSION_ID"
                log_error "Supported versions: Debian 12 and Debian 13"
                exit 1
                ;;

        esac

        ;;

    ubuntu)

        case "$OS_VERSION_ID" in

            22.04|24.04)
                log_success "Supported Ubuntu version: $OS_VERSION_ID"
                ;;

            *)
                log_error "Unsupported Ubuntu version: $OS_VERSION_ID"
                log_error "Supported versions: Ubuntu 22.04 and 24.04"
                exit 1
                ;;

        esac

        ;;

    *)

        log_error "Unsupported operating system: $OS_ID"
        exit 1

        ;;

esac

# ============================================================================
# Architecture
# ============================================================================

case "$ARCH" in

    amd64)
        log_success "Architecture: amd64"
        ;;

    arm64)
        log_success "Architecture: arm64"
        echo
        log_warning "Virtualmin does not officially support ARM64."
        log_warning "Nextcloud AIO and Docker do support ARM64."
        echo
        ;;

    *)
        log_error "Unsupported architecture: $ARCH"
        log_error "Supported architectures: amd64 and arm64"
        exit 1
        ;;

esac

# ============================================================================
# Required commands
# ============================================================================

log_step "Checking required software"

for command in \
    docker \
    virtualmin \
    apache2ctl \
    a2enmod \
    curl \
    openssl
do

    if ! command -v "$command" >/dev/null 2>&1; then

        log_error "Required command not found: $command"

        exit 1

    fi

done

if ! docker compose version >/dev/null 2>&1; then

    log_error "Docker Compose plugin is not available."

    exit 1

fi

if ! systemctl is-active --quiet docker; then

    log_error "Docker is not running."

    exit 1

fi

log_success "Required software is available."

# ============================================================================
# Virtualmin API availability
#
# We deliberately test the actual installed command instead of assuming
# anything about the installed Virtualmin version.
# ============================================================================

log_step "Checking Virtualmin native proxy API"

CREATE_PROXY_HELP_FILE="$(mktemp)"

set +e

virtualmin help create-proxy \
    >"$CREATE_PROXY_HELP_FILE" 2>&1

CREATE_PROXY_HELP_EXIT=$?

set -e

cat "$CREATE_PROXY_HELP_FILE" | tee -a "$LOG_FILE"

if [[ "$CREATE_PROXY_HELP_EXIT" -ne 0 ]]; then

    log_error ""
    log_error "============================================================"
    log_error " Virtualmin native Proxy Paths are NOT available"
    log_error "============================================================"
    log_error ""
    log_error "The installed Virtualmin does not provide the"
    log_error "'create-proxy' API."
    log_error ""
    log_error "This installer intentionally does NOT fall back to"
    log_error "direct Apache VirtualHost manipulation."
    log_error ""
    log_error "Current Virtualmin GPL includes Proxy Paths."
    log_error "Therefore this normally indicates that the installed"
    log_error "Virtualmin version is old or incomplete."
    log_error ""
    log_error "Exact Virtualmin response:"
    cat "$CREATE_PROXY_HELP_FILE" |
        sed 's/^/  /' |
        tee -a "$LOG_FILE"
    log_error ""
    log_error "Log: $LOG_FILE"

    rm -f "$CREATE_PROXY_HELP_FILE"

    exit 1

fi

rm -f "$CREATE_PROXY_HELP_FILE"

log_success "Virtualmin create-proxy API is available."

# ============================================================================
# Verify modify-web directive API
# ============================================================================

log_step "Checking Virtualmin native Apache directive API"

MODIFY_WEB_HELP_FILE="$(mktemp)"

set +e

virtualmin help modify-web \
    >"$MODIFY_WEB_HELP_FILE" 2>&1

MODIFY_WEB_HELP_EXIT=$?

set -e

cat "$MODIFY_WEB_HELP_FILE" | tee -a "$LOG_FILE"

if [[ "$MODIFY_WEB_HELP_EXIT" -ne 0 ]] ||
   ! grep -q -- "--add-directive" "$MODIFY_WEB_HELP_FILE"
then

    log_error ""
    log_error "============================================================"
    log_error " Virtualmin --add-directive API is NOT available"
    log_error "============================================================"
    log_error ""
    log_error "This installer requires Virtualmin's native"
    log_error "--add-directive API."
    log_error ""
    log_error "It will NOT modify Apache configuration directly."
    log_error ""
    log_error "Log: $LOG_FILE"

    rm -f "$MODIFY_WEB_HELP_FILE"

    exit 1

fi

rm -f "$MODIFY_WEB_HELP_FILE"

log_success "Virtualmin --add-directive API is available."

# ============================================================================
# Domain
# ============================================================================

if [[ -f "$DOMAIN_FILE" ]]; then

    aio_domain="$(cat "$DOMAIN_FILE")"

    echo
    echo "Existing Nextcloud AIO domain:"
    echo "  $aio_domain"
    echo

    read -rp "Use this domain? (Y/n): " reuse_domain

    reuse_domain="${reuse_domain:-y}"
    reuse_domain="$(echo "$reuse_domain" | tr '[:upper:]' '[:lower:]')"

    if [[ "$reuse_domain" != "y" ]]; then
        rm -f "$DOMAIN_FILE"
    fi

fi

if [[ ! -f "$DOMAIN_FILE" ]]; then

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
    echo "The domain should point to this server."
    echo

    while true; do

        read -rp "Nextcloud AIO domain: " aio_domain

        aio_domain="$(
            echo "$aio_domain" |
            tr '[:upper:]' '[:lower:]' |
            xargs
        )"

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

    echo "$aio_domain" > "$DOMAIN_FILE"
    chmod 600 "$DOMAIN_FILE"

fi

log_success "Nextcloud AIO domain: $aio_domain"

# ============================================================================
# Create Virtualmin domain
# ============================================================================

if virtualmin list-domains --name-only 2>/dev/null |
    grep -Fxq "$aio_domain"
then

    log_success "Virtualmin domain already exists: $aio_domain"

else

    log_step "Creating Virtualmin domain"

    DOMAIN_PASSWORD="$(openssl rand -base64 48)"

    if ! run_logged \
        "Virtualmin domain creation" \
        virtualmin create-domain \
        --domain "$aio_domain" \
        --pass "$DOMAIN_PASSWORD" \
        --unix \
        --dir \
        --web \
        --ssl \
        --skip-warnings
    then

        unset DOMAIN_PASSWORD

        log_error "Virtualmin failed to create $aio_domain."

        exit 1

    fi

    unset DOMAIN_PASSWORD

    log_success "Virtualmin domain created."

fi

# ============================================================================
# Verify domain
# ============================================================================

if ! virtualmin list-domains \
    --name-only \
    2>/dev/null |
    grep -Fxq "$aio_domain"
then

    log_error "Could not verify Virtualmin domain: $aio_domain"

    exit 1

fi

log_success "Virtualmin domain verified."

# ============================================================================
# Required Apache modules
# ============================================================================

log_step "Enabling Apache modules"

a2enmod \
    proxy \
    proxy_http \
    proxy_wstunnel \
    rewrite \
    headers \
    http2 \
    ssl \
    >/dev/null

if ! apache2ctl configtest >/dev/null 2>&1; then

    log_error "Apache configuration is already invalid."
    log_error "The proxy has NOT been configured."

    apache2ctl configtest 2>&1 |
        tee -a "$LOG_FILE"

    exit 1

fi

systemctl reload apache2

log_success "Apache modules enabled."

# ============================================================================
# Nextcloud data directory
# ============================================================================

if ! step_done "aio_data"; then

    log_step "Creating Nextcloud data directory"

    mkdir -p /mnt/ncdata

    chmod 750 /mnt/ncdata

    mark_done "aio_data"

    log_success "Nextcloud data directory created."

else

    log_success "Nextcloud data directory already exists."

fi

# ============================================================================
# Docker Compose
# ============================================================================

mkdir -p "$AIO_DIR"

if ! step_done "aio_compose"; then

    log_step "Creating Nextcloud AIO Docker Compose configuration"

    cat > "$AIO_COMPOSE" <<EOF
services:

  nextcloud-aio-mastercontainer:

    image: $AIO_IMAGE

    init: true

    restart: always

    container_name: nextcloud-aio-mastercontainer

    volumes:
      - nextcloud_aio_mastercontainer:/mnt/docker-aio-config
      - /var/run/docker.sock:/var/run/docker.sock:ro

    ports:
      - "8080:8080"
      - "$AIO_APACHE_BINDING:$AIO_APACHE_PORT:$AIO_APACHE_PORT"

    environment:
      APACHE_PORT: $AIO_APACHE_PORT
      APACHE_IP_BINDING: $AIO_APACHE_BINDING
      SKIP_DOMAIN_VALIDATION: "true"
      NEXTCLOUD_DATADIR: /mnt/ncdata
      NEXTCLOUD_MOUNT: /mnt/
      NEXTCLOUD_STARTUP_APPS: twofactor_totp calendar contacts files_external
      NEXTCLOUD_ENABLE_DRI_DEVICE: "false"

volumes:

  nextcloud_aio_mastercontainer:
    name: nextcloud_aio_mastercontainer
EOF

    chmod 640 "$AIO_COMPOSE"

    mark_done "aio_compose"

    log_success "AIO Docker Compose file created."

else

    log_success "AIO Docker Compose file already exists."

fi

# ============================================================================
# Start AIO mastercontainer
# ============================================================================

log_step "Starting Nextcloud AIO mastercontainer"

if ! (
    cd "$AIO_DIR"
    docker compose up -d
); then

    log_error "Failed to start the Nextcloud AIO mastercontainer."

    docker ps -a --filter "name=nextcloud-aio-mastercontainer" |
        tee -a "$LOG_FILE"

    docker logs \
        --tail 100 \
        nextcloud-aio-mastercontainer \
        2>&1 |
        tee -a "$LOG_FILE" || true

    exit 1

fi

log_success "Nextcloud AIO mastercontainer started."

# ============================================================================
# Verify container
# ============================================================================

if ! docker ps --format '{{.Names}}' |
    grep -qx "nextcloud-aio-mastercontainer"
then

    log_error "AIO mastercontainer is not running."

    docker logs \
        --tail 100 \
        nextcloud-aio-mastercontainer \
        2>&1 |
        tee -a "$LOG_FILE" || true

    exit 1

fi

# ============================================================================
# Wait for AIO setup interface
# ============================================================================

log_step "Waiting for Nextcloud AIO setup interface on port 8080"

aio_ready=false

for i in {1..60}; do

    if curl \
        --silent \
        --show-error \
        --max-time 3 \
        http://127.0.0.1:8080/ \
        >/dev/null 2>&1
    then

        aio_ready=true
        break

    fi

    sleep 2

done

if [[ "$aio_ready" != true ]]; then

    log_error "Nextcloud AIO setup interface did not become available."

    echo
    echo "Container status:"
    docker ps -a --filter "name=nextcloud-aio-mastercontainer" |
        tee -a "$LOG_FILE"

    echo
    echo "Recent AIO logs:"
    docker logs \
        --tail 100 \
        nextcloud-aio-mastercontainer \
        2>&1 |
        tee -a "$LOG_FILE" || true

    exit 1

fi

log_success "Nextcloud AIO setup interface is available."

# ============================================================================
# Native Virtualmin reverse proxy
#
# IMPORTANT:
#
# Do NOT manually construct ProxyPass or ProxyPassReverse.
#
# Virtualmin's create-proxy API creates these and, with --websockets,
# creates the required WebSocket rewrite configuration as well.
# ============================================================================

if ! step_done "aio_proxy"; then

    log_step "Creating native Virtualmin reverse proxy"

    PROXY_OUTPUT="$(mktemp)"

    set +e

    virtualmin create-proxy \
        --domain "$aio_domain" \
        --path "/" \
        --url "http://$AIO_APACHE_BINDING:$AIO_APACHE_PORT/" \
        --websockets \
        >"$PROXY_OUTPUT" 2>&1

    PROXY_EXIT_CODE=$?

    set -e

    cat "$PROXY_OUTPUT" |
        tee -a "$LOG_FILE"

    if [[ "$PROXY_EXIT_CODE" -ne 0 ]]; then

        log_error ""
        log_error "============================================================"
        log_error " Virtualmin reverse proxy creation FAILED"
        log_error "============================================================"
        log_error ""
        log_error "Exit code: $PROXY_EXIT_CODE"
        log_error ""
        log_error "Virtualmin's exact response:"
        cat "$PROXY_OUTPUT" |
            sed 's/^/  /' |
            tee -a "$LOG_FILE"
        log_error ""
        log_error "This is NOT being replaced by direct Apache editing."
        log_error ""
        log_error "If the response says:"
        log_error ""
        log_error "  Proxies cannot be configured for this virtual server"
        log_error ""
        log_error "then Virtualmin is refusing Proxy Paths for this domain."
        log_error "On a current Virtualmin GPL installation this is unexpected."
        log_error ""
        log_error "If the response says:"
        log_error ""
        log_error "  A ProxyPass for / already exists"
        log_error ""
        log_error "then this domain already has a root proxy."
        log_error ""
        log_error "Full installer log:"
        log_error "  $LOG_FILE"

        rm -f "$PROXY_OUTPUT"

        exit 1

    fi

    rm -f "$PROXY_OUTPUT"

    mark_done "aio_proxy"

    log_success "Native Virtualmin reverse proxy created."

else

    log_success "Native Virtualmin reverse proxy already configured."

fi

# ============================================================================
# Preserve original Host header
#
# Equivalent to:
#
#   ProxyPreserveHost On
#
# but handled by Virtualmin itself.
# ============================================================================

log_step "Enabling native Virtualmin proxy host preservation"

PROXY_HOST_OUTPUT="$(mktemp)"

set +e

virtualmin modify-web \
    --domain "$aio_domain" \
    --proxy-host \
    >"$PROXY_HOST_OUTPUT" 2>&1

PROXY_HOST_EXIT_CODE=$?

set -e

cat "$PROXY_HOST_OUTPUT" |
    tee -a "$LOG_FILE"

if [[ "$PROXY_HOST_EXIT_CODE" -ne 0 ]]; then

    log_error ""
    log_error "Virtualmin failed to enable proxy host preservation."
    log_error ""
    log_error "Exact response:"
    cat "$PROXY_HOST_OUTPUT" |
        sed 's/^/  /' |
        tee -a "$LOG_FILE"
    log_error ""
    log_error "The reverse proxy itself was created, but"
    log_error "ProxyPreserveHost could not be enabled."

    rm -f "$PROXY_HOST_OUTPUT"

    exit 1

fi

rm -f "$PROXY_HOST_OUTPUT"

log_success "Proxy host preservation enabled."

# ============================================================================
# Nextcloud AIO Apache directives
#
# Virtualmin's native --add-directive API applies these to both the HTTP and
# SSL VirtualHosts for the domain.
#
# We deliberately do NOT add:
#
#   ProxyPass
#   ProxyPassReverse
#   RewriteRule WebSocket rules
#   RewriteCond WebSocket rules
#   X-Forwarded-Proto
#   ProxyPreserveHost
#
# because Virtualmin's native proxy implementation already manages those.
# ============================================================================

log_step "Applying Nextcloud AIO Apache directives through Virtualmin"

# ---------------------------------------------------------------------------
# Remove exact directives first.
#
# This makes repeated executions safe and prevents duplicate directives.
# ---------------------------------------------------------------------------

AIO_DIRECTIVES=(
    "AllowEncodedSlashes NoDecode"
    "Protocols h2 h2c http/1.1"
    "H2WindowSize 5242880"
    "LimitRequestBody 0"
    "Timeout 3610"
    "ProxyTimeout 3610"
    "TraceEnable off"
    'RequestHeader set X-Real-IP %{REMOTE_ADDR}s'
)

for directive in "${AIO_DIRECTIVES[@]}"; do

    REMOVE_OUTPUT="$(mktemp)"

    set +e

    virtualmin modify-web \
        --domain "$aio_domain" \
        --remove-directive "$directive" \
        >"$REMOVE_OUTPUT" 2>&1

    REMOVE_EXIT_CODE=$?

    set -e

    cat "$REMOVE_OUTPUT" |
        tee -a "$LOG_FILE"

    if [[ "$REMOVE_EXIT_CODE" -ne 0 ]]; then

        log_error ""
        log_error "Virtualmin failed while removing an existing directive:"
        log_error "  $directive"
        log_error ""
        log_error "Exact response:"
        cat "$REMOVE_OUTPUT" |
            sed 's/^/  /' |
            tee -a "$LOG_FILE"

        rm -f "$REMOVE_OUTPUT"

        exit 1

    fi

    rm -f "$REMOVE_OUTPUT"

done

log_success "Previous AIO directives cleaned up."

# ---------------------------------------------------------------------------
# Add directives.
# ---------------------------------------------------------------------------

for directive in "${AIO_DIRECTIVES[@]}"; do

    ADD_OUTPUT="$(mktemp)"

    log_info "Adding: $directive"

    set +e

    virtualmin modify-web \
        --domain "$aio_domain" \
        --add-directive "$directive" \
        >"$ADD_OUTPUT" 2>&1

    ADD_EXIT_CODE=$?

    set -e

    cat "$ADD_OUTPUT" |
        tee -a "$LOG_FILE"

    if [[ "$ADD_EXIT_CODE" -ne 0 ]]; then

        log_error ""
        log_error "============================================================"
        log_error " Virtualmin failed to add an Apache directive"
        log_error "============================================================"
        log_error ""
        log_error "Directive:"
        log_error "  $directive"
        log_error ""
        log_error "Exit code:"
        log_error "  $ADD_EXIT_CODE"
        log_error ""
        log_error "Virtualmin response:"
        cat "$ADD_OUTPUT" |
            sed 's/^/  /' |
            tee -a "$LOG_FILE"
        log_error ""
        log_error "No direct Apache configuration was used."
        log_error ""
        log_error "Full log:"
        log_error "  $LOG_FILE"

        rm -f "$ADD_OUTPUT"

        exit 1

    fi

    rm -f "$ADD_OUTPUT"

done

log_success "Nextcloud AIO Apache directives added through Virtualmin."

# ============================================================================
# Apache configuration validation
# ============================================================================

log_step "Validating Apache configuration"

APACHE_TEST_OUTPUT="$(mktemp)"

set +e

apache2ctl configtest \
    >"$APACHE_TEST_OUTPUT" 2>&1

APACHE_TEST_EXIT_CODE=$?

set -e

cat "$APACHE_TEST_OUTPUT" |
    tee -a "$LOG_FILE"

if [[ "$APACHE_TEST_EXIT_CODE" -ne 0 ]]; then

    log_error ""
    log_error "============================================================"
    log_error " APACHE CONFIGURATION TEST FAILED"
    log_error "============================================================"
    log_error ""
    log_error "Apache has NOT been reloaded."
    log_error ""
    log_error "Exact Apache response:"
    cat "$APACHE_TEST_OUTPUT" |
        sed 's/^/  /' |
        tee -a "$LOG_FILE"
    log_error ""
    log_error "This usually means one of the directives generated by"
    log_error "Virtualmin is incompatible with the installed Apache."
    log_error ""
    log_error "The installer deliberately stops here rather than"
    log_error "reloading a broken Apache configuration."
    log_error ""
    log_error "Full log:"
    log_error "  $LOG_FILE"

    rm -f "$APACHE_TEST_OUTPUT"

    exit 1

fi

rm -f "$APACHE_TEST_OUTPUT"

log_success "Apache configuration test passed."

# ============================================================================
# Inspect the generated VirtualHosts
#
# This is diagnostic only. We do not modify the files.
# ============================================================================

log_step "Verifying generated Apache proxy configuration"

APACHE_VHOST_OUTPUT="$(mktemp)"

apache2ctl -S \
    >"$APACHE_VHOST_OUTPUT" 2>&1 || true

cat "$APACHE_VHOST_OUTPUT" |
    tee -a "$LOG_FILE"

rm -f "$APACHE_VHOST_OUTPUT"

# ---------------------------------------------------------------------------
# Look for expected proxy directives in Apache's active configuration.
# ---------------------------------------------------------------------------

APACHE_DUMP_OUTPUT="$(mktemp)"

set +e

apache2ctl -t -D DUMP_VHOSTS \
    >"$APACHE_DUMP_OUTPUT" 2>&1

DUMP_EXIT_CODE=$?

set -e

cat "$APACHE_DUMP_OUTPUT" |
    tee -a "$LOG_FILE"

rm -f "$APACHE_DUMP_OUTPUT"

if [[ "$DUMP_EXIT_CODE" -ne 0 ]]; then

    log_warning "Apache DUMP_VHOSTS could not be completed."

else

    log_success "Apache VirtualHost configuration can be parsed."

fi

# ============================================================================
# Reload Apache
# ============================================================================

log_step "Reloading Apache"

RELOAD_OUTPUT="$(mktemp)"

set +e

systemctl reload apache2 \
    >"$RELOAD_OUTPUT" 2>&1

RELOAD_EXIT_CODE=$?

set -e

cat "$RELOAD_OUTPUT" |
    tee -a "$LOG_FILE"

if [[ "$RELOAD_EXIT_CODE" -ne 0 ]]; then

    log_error "Apache reload failed."

    systemctl status apache2 \
        --no-pager \
        -l \
        2>&1 |
        tee -a "$LOG_FILE" || true

    rm -f "$RELOAD_OUTPUT"

    exit 1

fi

rm -f "$RELOAD_OUTPUT"

log_success "Apache reloaded successfully."

# ============================================================================
# Verify Apache service
# ============================================================================

if ! systemctl is-active --quiet apache2; then

    log_error "Apache is not running after reload."

    systemctl status apache2 \
        --no-pager \
        -l \
        2>&1 |
        tee -a "$LOG_FILE" || true

    exit 1

fi

log_success "Apache service is running."

# ============================================================================
# Verify backend listener
#
# IMPORTANT:
#
# AIO's Apache backend may not listen on 11222 until the AIO installation
# has been completed through port 8080.
# ============================================================================

log_step "Checking Nextcloud AIO backend port"

if timeout 5 bash -c \
    "</dev/tcp/$AIO_APACHE_BINDING/$AIO_APACHE_PORT"
then

    log_success "AIO backend is listening on $AIO_APACHE_BINDING:$AIO_APACHE_PORT."

else

    log_warning "AIO backend is not listening on $AIO_APACHE_BINDING:$AIO_APACHE_PORT yet."

    log_warning "This is expected if the AIO setup has not yet been completed."

fi

# ============================================================================
# Verify Docker
# ============================================================================

if docker ps --format '{{.Names}}' |
    grep -qx "nextcloud-aio-mastercontainer"
then

    log_success "AIO mastercontainer is running."

else

    log_error "AIO mastercontainer is not running."

    docker ps -a \
        --filter "name=nextcloud-aio-mastercontainer" |
        tee -a "$LOG_FILE"

    exit 1

fi

# ============================================================================
# Mark completed
# ============================================================================

mark_done "aio_proxy"
mark_done "aio_proxy_host"
mark_done "aio_directives"
mark_done "aio_apache_validated"

# ============================================================================
# Server IP
# ============================================================================

SERVER_IP="$(hostname -I | awk '{print $1}')"

# ============================================================================
# Final report
# ============================================================================

echo
echo "============================================================"
echo " Nextcloud AIO installation/configuration complete"
echo "============================================================"
echo

echo "Nextcloud domain:"
echo "  https://$aio_domain"
echo

echo "Virtualmin:"
echo "  Native Proxy Paths"
echo

echo "Reverse proxy:"
echo "  $aio_domain/"
echo "      ↓"
echo "  http://$AIO_APACHE_BINDING:$AIO_APACHE_PORT/"
echo

echo "WebSockets:"
echo "  Native Virtualmin create-proxy --websockets"
echo

echo "Host header:"
echo "  Native Virtualmin --proxy-host"
echo

echo "AIO-specific Apache directives:"
echo "  Native Virtualmin --add-directive"
echo

echo "Apache:"
echo "  Configuration test: PASSED"
echo "  Reload:              PASSED"
echo

echo "AIO management interface:"
echo
echo "  https://$SERVER_IP:8080"
echo

echo "IMPORTANT:"
echo
echo "If AIO has not yet been initialized:"
echo
echo "  1. Open the AIO management interface above."
echo "  2. Complete the AIO setup."
echo "  3. Use $aio_domain as the Nextcloud domain."
echo "  4. The AIO Apache backend will then become available"
echo "     on 127.0.0.1:$AIO_APACHE_PORT."
echo

echo "Installation log:"
echo "  $LOG_FILE"
echo

echo "State file:"
echo "  $STATE_FILE"
echo

echo "============================================================"
echo

mark_done "setup_ready"
