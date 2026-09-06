#!/usr/bin/env bash

# ============================================================
# Nextcloud AIO installation behind Virtualmin Apache
#
# Host-level responsibilities:
#   root
#     - Virtualmin
#     - Apache
#     - filesystem/system configuration
#
# Docker responsibilities:
#   administrator user
#     - docker
#     - docker compose
#     - AIO compose project
#
# Virtualmin APIs used:
#   - create-domain
#   - create-proxy
#   - delete-proxy
#   - modify-web
# ============================================================

set -Eeuo pipefail

LOG_FILE="/var/log/nextcloud-aio-install.log"
STATE_FILE="/root/.nextcloud-aio-install.state"

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

for command in \
    docker \
    virtualmin \
    apache2ctl \
    curl \
    openssl \
    runuser \
    ss
do
    command -v "$command" >/dev/null 2>&1 \
        || die "Required command not found: $command"
done

# ------------------------------------------------------------
# Administrator username
# ------------------------------------------------------------

ADMIN_USER="${1:-}"

if [[ -z "$ADMIN_USER" ]]; then
    die "Administrator username must be supplied as the first argument."
fi

if [[ "$ADMIN_USER" == "root" ]]; then
    die "The Nextcloud AIO Docker administrator cannot be root."
fi

if ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
    die "Administrator user does not exist: $ADMIN_USER"
fi

ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"

[[ -n "$ADMIN_HOME" ]] \
    || die "Could not determine home directory for $ADMIN_USER."

if ! id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx "docker"; then
    die "User '$ADMIN_USER' is not a member of the docker group."
fi

AIO_COMPOSE_DIR="${ADMIN_HOME}/nextcloud-aio"
AIO_COMPOSE_FILE="${AIO_COMPOSE_DIR}/docker-compose.yaml"

log "Virtualmin administrator: $ADMIN_USER"
log "Administrator home: $ADMIN_HOME"
log "AIO Compose directory: $AIO_COMPOSE_DIR"

# ------------------------------------------------------------
# Run Docker commands as administrator
# ------------------------------------------------------------

run_as_admin() {
    runuser -u "$ADMIN_USER" -- "$@"
}

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
run_as_admin docker --version || true

echo
echo "Docker Compose:"
run_as_admin docker compose version || true

# ------------------------------------------------------------
# Domain
# ------------------------------------------------------------

AIO_DOMAIN="${AIO_DOMAIN:-}"

if [[ -z "$AIO_DOMAIN" ]]; then

    read -r -p "Enter Nextcloud AIO domain: " AIO_DOMAIN

fi

AIO_DOMAIN="$(echo "$AIO_DOMAIN" | tr '[:upper:]' '[:lower:]')"

if ! [[ "$AIO_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
    die "Invalid domain: $AIO_DOMAIN"
fi

log "Nextcloud domain: $AIO_DOMAIN"

# ------------------------------------------------------------
# State
# ------------------------------------------------------------

touch "$STATE_FILE"
chmod 600 "$STATE_FILE"

# ------------------------------------------------------------
# Check whether domain already exists
# ------------------------------------------------------------

log "Checking Virtualmin domain"

if virtualmin list-domains --name-only 2>/dev/null \
    | grep -Fxq "$AIO_DOMAIN"; then

    echo
    echo "Virtualmin domain already exists:"
    echo "  $AIO_DOMAIN"

    DOMAIN_EXISTS=1

else

    DOMAIN_EXISTS=0

fi

# ------------------------------------------------------------
# Generate Virtualmin domain password
# ------------------------------------------------------------

if [[ "$DOMAIN_EXISTS" -eq 0 ]]; then

    log "Generating password for the Virtualmin domain"

    DOMAIN_PASSWORD="$(
        openssl rand -base64 36 |
        tr -dc 'A-Za-z0-9' |
        head -c 32
    )"

    [[ -n "$DOMAIN_PASSWORD" ]] \
        || die "Failed to generate Virtualmin domain password."

else

    DOMAIN_PASSWORD=""

fi

# ------------------------------------------------------------
# Save state
# ------------------------------------------------------------

cat > "$STATE_FILE" <<EOF
AIO_DOMAIN='$AIO_DOMAIN'
AIO_ADMIN_PORT='$AIO_ADMIN_PORT'
AIO_WEB_PORT='$AIO_WEB_PORT'
AIO_DATA_DIR='$AIO_DATA_DIR'
AIO_COMPOSE_FILE='$AIO_COMPOSE_FILE'
ADMIN_USER='$ADMIN_USER'
EOF

if [[ -n "$DOMAIN_PASSWORD" ]]; then

    cat >> "$STATE_FILE" <<EOF
VIRTUALMIN_DOMAIN_PASSWORD='$DOMAIN_PASSWORD'
EOF

fi

chmod 600 "$STATE_FILE"

# ------------------------------------------------------------
# Create Virtualmin domain
# ------------------------------------------------------------

if [[ "$DOMAIN_EXISTS" -eq 0 ]]; then

    log "Creating Virtualmin domain: $AIO_DOMAIN"

    virtualmin create-domain \
        --domain "$AIO_DOMAIN" \
        --pass "$DOMAIN_PASSWORD" \
        --unix \
        --dir \
        --web \
        --ssl \
        --skip-warnings \
        || die "Virtualmin failed to create $AIO_DOMAIN."

else

    log "Virtualmin domain already exists; not recreating it."

fi

# ------------------------------------------------------------
# Verify that Virtualmin can see the web domain
# ------------------------------------------------------------

log "Verifying Virtualmin domain"

virtualmin list-domains --name-only 2>/dev/null \
    | grep -Fxq "$AIO_DOMAIN" \
    || die "Virtualmin does not report the domain after creation."

# ------------------------------------------------------------
# Apache modules
# ------------------------------------------------------------

log "Enabling Apache proxy modules"

a2enmod proxy
a2enmod proxy_http
a2enmod proxy_wstunnel
a2enmod headers
a2enmod ssl
a2enmod http2

# ------------------------------------------------------------
# Create Nextcloud data directory
# ------------------------------------------------------------

log "Creating Nextcloud data directory"

mkdir -p "$AIO_DATA_DIR"

chmod 755 "$AIO_DATA_DIR"

# ------------------------------------------------------------
# Docker Compose directory
# ------------------------------------------------------------

log "Creating administrator-owned AIO Compose directory"

mkdir -p "$AIO_COMPOSE_DIR"

chown "$ADMIN_USER:$(id -gn "$ADMIN_USER")" "$AIO_COMPOSE_DIR"

chmod 750 "$AIO_COMPOSE_DIR"

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

chown "$ADMIN_USER:$(id -gn "$ADMIN_USER")" "$AIO_COMPOSE_FILE"
chmod 640 "$AIO_COMPOSE_FILE"

# ------------------------------------------------------------
# Validate Docker Compose
# ------------------------------------------------------------

log "Validating Docker Compose configuration as $ADMIN_USER"

run_as_admin \
    docker compose \
    -f "$AIO_COMPOSE_FILE" \
    config >/dev/null \
    || die "Docker Compose configuration is invalid."

# ------------------------------------------------------------
# Start AIO
# ------------------------------------------------------------

log "Starting Nextcloud AIO as $ADMIN_USER"

run_as_admin \
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
echo "✓ Nextcloud AIO administration interface is available."

# ============================================================
# VIRTUALMIN / APACHE CONFIGURATION
# ============================================================

# ------------------------------------------------------------
# Locate actual VirtualHost configuration files
# ------------------------------------------------------------

find_vhost_file() {

    local domain="$1"
    local ssl="$2"

    local candidates=()

    if [[ "$ssl" == "yes" ]]; then

        candidates=(
            "/etc/apache2/sites-enabled/${domain}.conf"
            "/etc/apache2/sites-available/${domain}.conf"
            "/etc/apache2/sites-enabled/${domain}-le-ssl.conf"
            "/etc/apache2/sites-available/${domain}-le-ssl.conf"
        )

    else

        candidates=(
            "/etc/apache2/sites-enabled/${domain}.conf"
            "/etc/apache2/sites-available/${domain}.conf"
        )

    fi

    local file

    for file in "${candidates[@]}"; do
        if [[ -f "$file" ]] &&
           grep -qi "<VirtualHost" "$file"; then
            echo "$file"
            return 0
        fi
    done

    return 1
}

HTTP_VHOST_FILE="$(find_vhost_file "$AIO_DOMAIN" no || true)"
HTTPS_VHOST_FILE="$(find_vhost_file "$AIO_DOMAIN" yes || true)"

echo
echo "Detected Apache configuration:"
echo "  HTTP : ${HTTP_VHOST_FILE:-NOT FOUND}"
echo "  HTTPS: ${HTTPS_VHOST_FILE:-NOT FOUND}"

[[ -n "$HTTP_VHOST_FILE" ]] \
    || die "Could not locate the Apache HTTP VirtualHost for $AIO_DOMAIN."

[[ -n "$HTTPS_VHOST_FILE" ]] \
    || die "Could not locate the Apache HTTPS VirtualHost for $AIO_DOMAIN."

# ------------------------------------------------------------
# Test Virtualmin directive API
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

    die "Virtualmin --add-directive API failed."

fi

rm -f "$TEST_OUTPUT"

# ------------------------------------------------------------
# Verify temporary directive actually reached Apache
# ------------------------------------------------------------

log "Verifying that Virtualmin actually wrote the directive"

if ! grep -Rqs \
    --include='*.conf' \
    -F "$TEST_DIRECTIVE" \
    /etc/apache2/sites-enabled \
    /etc/apache2/sites-available; then

    virtualmin modify-web \
        --domain "$AIO_DOMAIN" \
        --remove-directive "$TEST_DIRECTIVE" \
        >/dev/null 2>&1 || true

    die "Virtualmin reported success, but '$TEST_DIRECTIVE' was not written to Apache configuration."
fi

# ------------------------------------------------------------
# Remove temporary directive
# ------------------------------------------------------------

log "Removing temporary API test directive"

virtualmin modify-web \
    --domain "$AIO_DOMAIN" \
    --remove-directive "$TEST_DIRECTIVE" \
    || die "Could not remove temporary test directive."

# ============================================================
# CREATE NATIVE VIRTUALMIN PROXY
# ============================================================

log "Removing any existing Virtualmin proxy"

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
# Create proxy
# ------------------------------------------------------------

log "Creating Virtualmin reverse proxy"

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
# Verify actual proxy configuration
# ------------------------------------------------------------

log "Verifying actual Apache reverse-proxy configuration"

if ! grep -Rqs \
    --include='*.conf' \
    -E 'ProxyPass|ProxyPassReverse' \
    /etc/apache2/sites-enabled \
    /etc/apache2/sites-available; then

    die "Virtualmin reported successful proxy creation, but no ProxyPass/ProxyPassReverse directive was found in Apache configuration."
fi

if ! grep -Rqs \
    --include='*.conf' \
    "127.0.0.1:${AIO_WEB_PORT}" \
    /etc/apache2/sites-enabled \
    /etc/apache2/sites-available; then

    die "Reverse proxy was not written with the expected AIO backend 127.0.0.1:${AIO_WEB_PORT}."
fi

echo
echo "✓ Reverse proxy directives found in Apache configuration."

# ============================================================
# PROXY HOST
# ============================================================

log "Enabling Virtualmin proxy-host handling"

virtualmin modify-web \
    --domain "$AIO_DOMAIN" \
    --proxy-host \
    || die "Virtualmin --proxy-host configuration failed."

# ------------------------------------------------------------
# HTTP protocols
# ------------------------------------------------------------

log "Configuring HTTP protocols"

virtualmin modify-web \
    --domain "$AIO_DOMAIN" \
    --protocols "http/1.1 h2" \
    || die "Virtualmin protocol configuration failed."

# ============================================================
# NEXTCLOUD AIO APACHE DIRECTIVES
# ============================================================

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

    log "Adding Apache directive: $directive"

    virtualmin modify-web \
        --domain "$AIO_DOMAIN" \
        --add-directive "$directive" \
        || die "Failed to add Apache directive: $directive"

done

# ------------------------------------------------------------
# Verify all directives were actually written
# ------------------------------------------------------------

log "Verifying Nextcloud Apache directives"

for directive in "${NATIVE_DIRECTIVES[@]}"; do

    if ! grep -Rqs \
        --include='*.conf' \
        -F "$directive" \
        /etc/apache2/sites-enabled \
        /etc/apache2/sites-available; then

        die "Virtualmin reported success but Apache configuration does not contain: $directive"
    fi

done

echo
echo "✓ All Nextcloud Apache directives found in Apache configuration."

# ============================================================
# SHOW RESULTING VHOST CONFIGURATION
# ============================================================

log "Displaying resulting VirtualHost configuration"

echo
echo "---------------- HTTP VHOST ----------------"
sed -n '/<VirtualHost/,/<\/VirtualHost>/p' "$HTTP_VHOST_FILE" || true

echo
echo "---------------- HTTPS VHOST ----------------"
sed -n '/<VirtualHost/,/<\/VirtualHost>/p' "$HTTPS_VHOST_FILE" || true

echo
echo "------------------------------------------------------------"

# ============================================================
# APACHE CONFIGURATION TEST
# ============================================================

log "Validating Apache configuration"

if ! apache2ctl configtest; then

    echo
    echo "❌ Apache configuration test FAILED."
    echo
    echo "Apache has NOT been reloaded."
    echo
    echo "Review:"
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
# VERIFY LIVE APACHE CONFIGURATION
# ============================================================

log "Verifying live Apache configuration"

apache2ctl -S 2>&1 | grep -i "$AIO_DOMAIN" \
    || die "Apache does not report the Nextcloud VirtualHost."

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

log "Checking Nextcloud AIO containers as $ADMIN_USER"

run_as_admin docker ps \
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

echo "Docker administrator:"
echo
echo "  ${ADMIN_USER}"
echo

echo "Installation log:"
echo
echo "  ${LOG_FILE}"
echo

echo "Virtualmin state:"
echo
echo "  ${STATE_FILE}"
echo

echo "============================================================"
