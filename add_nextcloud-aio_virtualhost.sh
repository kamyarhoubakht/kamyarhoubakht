#!/bin/bash
set -Eeuo pipefail
[[ "${DEBUG:-}" == "true" ]] && set -x
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/add_virtualhost.log"

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

trap 'handle_error $LINENO' ERR

if [[ "$EUID" -ne 0 ]]; then
    log_error "This script must be run as root."
    exit 1
fi

for command in virtualmin apache2ctl openssl; do
    command -v "$command" >/dev/null 2>&1 || {
        log_error "Required command not found: $command"
        exit 1
    }
done

echo
echo "============================================================"
echo " Add Second Virtual Host for Nextcloud AIO"
echo "============================================================"
echo

read -r -p "Enter the new domain/subdomain for Nextcloud: " AIO_DOMAIN
AIO_DOMAIN="${AIO_DOMAIN,,}"

[[ -n "$AIO_DOMAIN" ]] || {
    log_error "No domain was supplied."
    exit 1
}

if ! [[ "$AIO_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    log_error "Invalid domain name: $AIO_DOMAIN"
    exit 1
fi

log_step "Nextcloud domain: $AIO_DOMAIN"

read -rp "Enter the existing Nextcloud AIO Apache backend port (default: 11222): " AIO_WEB_PORT
AIO_WEB_PORT="${AIO_WEB_PORT:-11222}"

log_step "Generating password for the Virtualmin domain"
DOMAIN_PASSWORD="$(openssl rand -hex 16)"

[[ -n "$DOMAIN_PASSWORD" ]] || {
    log_error "Failed to generate Virtualmin domain password."
    exit 1
}

log_step "Creating Virtualmin domain '$AIO_DOMAIN' using 'Reverse Proxy' template and plan"
virtualmin create-domain \
    --domain "$AIO_DOMAIN" \
    --pass "$DOMAIN_PASSWORD" \
    --template "Reverse Proxy" \
    --plan "Reverse Proxy" \
    --features-from-plan \
    --limits-from-plan \
    --skip-warnings \
    || {
        log_error "Virtualmin failed to create $AIO_DOMAIN."
        exit 1
    }

log_success "Virtualmin domain '$AIO_DOMAIN' created successfully."

log_step "Disabling mail feature for $AIO_DOMAIN"
virtualmin disable-feature \
    --domain "$AIO_DOMAIN" \
    --mail \
    || {
        log_error "Could not disable the mail feature for $AIO_DOMAIN."
        exit 1
    }

log_step "Enabling required Apache modules"
for module in proxy proxy_http proxy_wstunnel rewrite headers ssl http2; do
    a2enmod "$module" >/dev/null 2>&1 || true
done

log_step "Creating Virtualmin reverse proxy: / -> http://127.0.0.1:${AIO_WEB_PORT}/"
PROXY_OUTPUT="$(mktemp)"
set +e
virtualmin create-proxy \
    --domain "$AIO_DOMAIN" \
    --path "/" \
    --url "http://127.0.0.1:${AIO_WEB_PORT}/" \
    >"$PROXY_OUTPUT" 2>&1
PROXY_EXIT_CODE=$?
set -e

cat "$PROXY_OUTPUT"
rm -f "$PROXY_OUTPUT"

if [[ "$PROXY_EXIT_CODE" -ne 0 ]]; then
    log_error "Virtualmin create-proxy failed."
    exit 1
fi

log_success "Native Virtualmin reverse proxy created."

log_step "Configuring HTTP protocols"
virtualmin modify-web \
    --domain "$AIO_DOMAIN" \
    --protocols "http/1.1 h2" \
    || {
        log_error "Virtualmin protocol configuration failed."
        exit 1
    }

log_step "Adding Nextcloud AIO Apache directives"
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
    log_step "Setting Apache directive: $directive"
    virtualmin modify-web \
        --domain "$AIO_DOMAIN" \
        --remove-directive "$directive" \
        >/dev/null 2>&1 || true

    virtualmin modify-web \
        --domain "$AIO_DOMAIN" \
        --add-directive "$directive" \
        || {
            log_error "Failed to add Apache directive: $directive"
            exit 1
        }
done

log_step "Validating Apache configuration"
if ! apache2ctl configtest; then
    log_error "Apache configuration is invalid. Apache was not reloaded."
    exit 1
fi

log_step "Reloading Apache"
systemctl reload apache2

echo
echo "============================================================"
echo "✓ SECOND VIRTUAL HOST CONFIGURATION COMPLETE"
echo "============================================================"
echo "Nextcloud domain : https://${AIO_DOMAIN}"
echo "Apache backend   : 127.0.0.1:${AIO_WEB_PORT}"
echo "Log file         : ${LOG_FILE}"
echo "============================================================"
