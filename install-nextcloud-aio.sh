#!/bin/bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/nextcloud-aio-install.log"
STATE_FILE="/root/.nextcloud_aio_state"
DOMAIN_FILE="/root/.nextcloud_aio_domain"

AIO_PORT="11222"
AIO_BINDING="127.0.0.1"

mkdir -p /var/log

touch "$LOG_FILE" "$STATE_FILE"
chmod 600 "$LOG_FILE" "$STATE_FILE"

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
    log_error "Installation failed."
    log_error "Line: $line_number"
    log_error "Exit code: $exit_code"
    log_error "Log: $LOG_FILE"
    echo

    exit "$exit_code"
}

trap 'handle_error $LINENO' ERR

# ============================================================================
# Root
# ============================================================================

if [[ "$EUID" -ne 0 ]]; then
    log_error "This script must be run as root."
    exit 1
fi

# ============================================================================
# Operating system
# ============================================================================

if [[ ! -f /etc/os-release ]]; then
    log_error "Cannot determine operating system."
    exit 1
fi

. /etc/os-release

OS_ID="${ID:-}"
OS_VERSION_ID="${VERSION_ID:-}"
ARCH="$(dpkg --print-architecture)"

case "$OS_ID" in

    debian)
        case "$OS_VERSION_ID" in
            12|13)
                ;;
            *)
                log_error "Unsupported Debian version: $OS_VERSION_ID"
                exit 1
                ;;
        esac
        ;;

    ubuntu)
        case "$OS_VERSION_ID" in
            22.04|24.04)
                ;;
            *)
                log_error "Unsupported Ubuntu version: $OS_VERSION_ID"
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
        AIO_IMAGE="ghcr.io/nextcloud-releases/all-in-one:latest"
        ;;

    arm64)
        AIO_IMAGE="ghcr.io/nextcloud-releases/all-in-one:latest-arm64"
        ;;

    *)
        log_error "Unsupported architecture: $ARCH"
        log_error "Supported architectures: amd64 and arm64"
        exit 1
        ;;

esac

log_success "Operating system: ${PRETTY_NAME:-unknown}"
log_success "Architecture: $ARCH"
log_success "AIO image: $AIO_IMAGE"

# ============================================================================
# Administrator
# ============================================================================

if [[ $# -ne 1 ]]; then
    log_error "Usage:"
    log_error "$0 <administrator-username>"
    exit 1
fi

sudo_user="$1"

if ! id -u "$sudo_user" >/dev/null 2>&1; then
    log_error "Administrator user '$sudo_user' does not exist."
    exit 1
fi

USER_HOME="$(getent passwd "$sudo_user" | cut -d: -f6)"
USER_GROUP="$(id -gn "$sudo_user")"

# ============================================================================
# Required software
# ============================================================================

for command in docker curl openssl virtualmin apache2ctl; do
    if ! command -v "$command" >/dev/null 2>&1; then
        log_error "Required command not found: $command"
        exit 1
    fi
done

if ! docker compose version >/dev/null 2>&1; then
    log_error "Docker Compose plugin not found."
    exit 1
fi

if ! systemctl is-active --quiet docker; then
    log_error "Docker is not running."
    exit 1
fi

# ============================================================================
# Domain
# ============================================================================

if [[ -f "$DOMAIN_FILE" ]]; then

    aio_domain="$(cat "$DOMAIN_FILE")"

else

    echo
    echo "============================================================"
    echo " Nextcloud AIO domain"
    echo "============================================================"
    echo

    while true; do

        read -rp "Nextcloud AIO domain: " aio_domain

        aio_domain="$(echo "$aio_domain" | tr '[:upper:]' '[:lower:]' | xargs)"

        if [[ -z "$aio_domain" ]]; then
            echo "Domain cannot be empty."
            continue
        fi

        if ! [[ "$aio_domain" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
            echo "Invalid domain."
            continue
        fi

        break

    done

    printf '%s\n' "$aio_domain" > "$DOMAIN_FILE"
    chmod 600 "$DOMAIN_FILE"

fi

log_success "Nextcloud domain: $aio_domain"

# ============================================================================
# Create Virtualmin domain
# ============================================================================

if virtualmin list-domains --name-only 2>/dev/null \
    | grep -Fxq "$aio_domain"; then

    log_success "Virtualmin domain already exists."

else

    log_step "Creating Virtualmin domain"

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

apache2ctl configtest

systemctl reload apache2

log_success "Apache modules enabled."

# ============================================================================
# AIO directory
# ============================================================================

AIO_DIR="$USER_HOME/nextcloud-aio"
AIO_COMPOSE="$AIO_DIR/docker-compose.yaml"

mkdir -p "$AIO_DIR"

chown "$sudo_user:$USER_GROUP" "$AIO_DIR"
chmod 750 "$AIO_DIR"

# ============================================================================
# Docker Compose
# ============================================================================

log_step "Creating AIO Docker Compose configuration"

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
      - "$AIO_BINDING:$AIO_PORT:$AIO_PORT"

    environment:
      APACHE_PORT: $AIO_PORT
      APACHE_IP_BINDING: $AIO_BINDING

volumes:

  nextcloud_aio_mastercontainer:
    name: nextcloud_aio_mastercontainer
EOF

chown "$sudo_user:$USER_GROUP" "$AIO_COMPOSE"
chmod 640 "$AIO_COMPOSE"

# ============================================================================
# Pull image
# ============================================================================

log_step "Pulling Nextcloud AIO image"

docker pull "$AIO_IMAGE"

# ============================================================================
# Start AIO
# ============================================================================

log_step "Starting Nextcloud AIO"

(
    cd "$AIO_DIR"

    docker compose pull
    docker compose up -d --force-recreate
)

sleep 5

if ! docker ps --format '{{.Names}}' \
    | grep -qx "nextcloud-aio-mastercontainer"; then

    log_error "AIO mastercontainer did not start."

    docker logs \
        --tail 100 \
        nextcloud-aio-mastercontainer || true

    exit 1

fi

log_success "AIO mastercontainer running."

# ============================================================================
# Verify image
# ============================================================================

RUNNING_IMAGE="$(
    docker inspect \
        --format '{{.Config.Image}}' \
        nextcloud-aio-mastercontainer
)"

if [[ "$RUNNING_IMAGE" != "$AIO_IMAGE" ]]; then

    log_error "Wrong AIO image is running."
    log_error "Expected: $AIO_IMAGE"
    log_error "Running: $RUNNING_IMAGE"

    exit 1

fi

log_success "Correct AIO image confirmed."

# ============================================================================
# Locate Virtualmin's virtual-server library
# ============================================================================

VIRTUAL_SERVER_LIB=""

for candidate in \
    /usr/share/webmin/virtual-server/virtual-server-lib.pl \
    /usr/libexec/webmin/virtual-server/virtual-server-lib.pl
do

    if [[ -f "$candidate" ]]; then
        VIRTUAL_SERVER_LIB="$candidate"
        break
    fi

done

if [[ -z "$VIRTUAL_SERVER_LIB" ]]; then
    log_error "Virtualmin virtual-server-lib.pl could not be found."
    exit 1
fi

log_success "Virtualmin library:"
echo "  $VIRTUAL_SERVER_LIB"

# ============================================================================
# Add AIO directives to SSL VirtualHost through Virtualmin's own API
#
# IMPORTANT:
#
# We intentionally DO NOT use:
#
#   virtualmin modify-web --add-directive
#
# because Virtualmin's modify-web implementation applies those directives
# to both the HTTP and HTTPS VirtualHosts.
#
# Instead we use:
#
#   get_apache_virtual(domain, ssl_port)
#   apache::save_directive(...)
#
# directly against the SSL VirtualHost.
# ============================================================================

log_step "Adding AIO directives to the Virtualmin SSL VirtualHost"

perl - "$VIRTUAL_SERVER_LIB" "$aio_domain" "$AIO_BINDING" "$AIO_PORT" <<'PERL'
use strict;
use warnings;

my ($lib, $domain_name, $binding, $port) = @ARGV;

$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";

my $libdir = $lib;
$libdir =~ s{/virtual-server-lib\.pl$}{};

chdir($libdir)
    or die "Cannot change to Virtualmin library directory: $!\n";

require "./virtual-server-lib.pl";

$< == 0
    or die "This operation must run as root\n";

&require_apache();

my $domain = &get_domain_by("dom", $domain_name);

$domain
    or die "Virtualmin domain '$domain_name' does not exist\n";

$domain->{'ssl'}
    or die "Virtualmin domain '$domain_name' does not have SSL enabled\n";

my $ssl_port = $domain->{'web_sslport'} || 443;

my ($virt, $vconf, $conf) =
    &get_apache_virtual($domain_name, $ssl_port);

$virt
    or die "Could not locate SSL VirtualHost for $domain_name on port $ssl_port\n";

$vconf
    or die "Could not read SSL VirtualHost configuration for $domain_name\n";

# --------------------------------------------------------------------------
# Helper
# --------------------------------------------------------------------------

sub set_directive {
    my ($name, $value) = @_;

    my @existing =
        &apache::find_directive($name, $vconf);

    # Do not create duplicates.
    @existing =
        grep { $_ ne $value } @existing;

    push @existing, $value;

    &apache::save_directive(
        $name,
        \@existing,
        $vconf,
        $conf
    );
}

sub remove_directive {
    my ($name, $match) = @_;

    my @existing =
        &apache::find_directive($name, $vconf);

    if (defined($match)) {
        @existing =
            grep { $_ ne $match } @existing;
    }
    else {
        @existing = ();
    }

    &apache::save_directive(
        $name,
        \@existing,
        $vconf,
        $conf
    );
}

# --------------------------------------------------------------------------
# Remove old AIO directives if this script is being run again.
# --------------------------------------------------------------------------

remove_directive(
    "ProxyPreserveHost"
);

remove_directive(
    "RequestHeader",
    'set X-Real-IP %{REMOTE_ADDR}s'
);

remove_directive(
    "RequestHeader",
    'set X-Forwarded-Proto "https"'
);

remove_directive(
    "AllowEncodedSlashes"
);

remove_directive(
    "ProxyPass",
    " / http://$binding:$port/ nocanon"
);

remove_directive(
    "ProxyPassReverse",
    " / http://$binding:$port/"
);

remove_directive(
    "Protocols"
);

remove_directive(
    "H2WindowSize"
);

remove_directive(
    "LimitRequestBody"
);

remove_directive(
    "Timeout"
);

remove_directive(
    "ProxyTimeout"
);

# --------------------------------------------------------------------------
# Add the AIO directives.
# --------------------------------------------------------------------------

set_directive(
    "ProxyPreserveHost",
    "On"
);

set_directive(
    "RequestHeader",
    'set X-Real-IP %{REMOTE_ADDR}s'
);

set_directive(
    "RequestHeader",
    'set X-Forwarded-Proto "https"'
);

set_directive(
    "AllowEncodedSlashes",
    "NoDecode"
);

set_directive(
    "ProxyPass",
    "/ http://$binding:$port/ nocanon"
);

set_directive(
    "ProxyPassReverse",
    "/ http://$binding:$port/"
);

set_directive(
    "Protocols",
    "h2 h2c http/1.1"
);

set_directive(
    "H2WindowSize",
    "5242880"
);

set_directive(
    "LimitRequestBody",
    "0"
);

set_directive(
    "Timeout",
    "86400"
);

set_directive(
    "ProxyTimeout",
    "86400"
);

# --------------------------------------------------------------------------
# WebSocket directives.
#
# These need to be represented as RewriteCond/RewriteRule directives.
# Virtualmin's Apache directive structure supports these as individual
# directives.
# --------------------------------------------------------------------------

set_directive(
    "RewriteCond",
    '%{HTTP:Upgrade} websocket [NC]'
);

set_directive(
    "RewriteCond",
    '%{HTTP:Connection} upgrade [NC]'
);

set_directive(
    "RewriteRule",
    '.? ws://127.0.0.1:' . $port . '/%1 [P,L,UnsafeAllow3F]'
);

# --------------------------------------------------------------------------
# Save and flush the exact Virtualmin-managed SSL vhost.
# --------------------------------------------------------------------------

&flush_file_lines($virt->{'file'});

print "SSL VirtualHost updated successfully\n";
print "Domain: $domain_name\n";
print "SSL port: $ssl_port\n";
print "Configuration file managed by Virtualmin: $virt->{'file'}\n";

exit 0;

PERL

log_success "AIO directives written through Virtualmin's SSL VirtualHost API."

# ============================================================================
# Verify through Virtualmin's Apache configuration structure
# ============================================================================

log_step "Verifying AIO directives in the SSL VirtualHost"

perl - "$VIRTUAL_SERVER_LIB" "$aio_domain" "$AIO_BINDING" "$AIO_PORT" <<'PERL'
use strict;
use warnings;

my ($lib, $domain_name, $binding, $port) = @ARGV;

$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";

my $libdir = $lib;
$libdir =~ s{/virtual-server-lib\.pl$}{};

chdir($libdir)
    or die "Cannot change directory: $!\n";

require "./virtual-server-lib.pl";

&require_apache();

my $domain = &get_domain_by("dom", $domain_name);

$domain
    or die "Domain not found\n";

my $ssl_port = $domain->{'web_sslport'} || 443;

my ($virt, $vconf, $conf) =
    &get_apache_virtual($domain_name, $ssl_port);

$virt
    or die "SSL VirtualHost not found\n";

my @required = (

    [ "ProxyPreserveHost", "On" ],

    [
        "RequestHeader",
        'set X-Real-IP %{REMOTE_ADDR}s'
    ],

    [
        "RequestHeader",
        'set X-Forwarded-Proto "https"'
    ],

    [
        "AllowEncodedSlashes",
        "NoDecode"
    ],

    [
        "ProxyPass",
        "/ http://127.0.0.1:" . $port . "/ nocanon"
    ],

    [
        "ProxyPassReverse",
        "/ http://127.0.0.1:" . $port . "/"
    ],

    [
        "Protocols",
        "h2 h2c http/1.1"
    ],

    [
        "H2WindowSize",
        "5242880"
    ],

    [
        "LimitRequestBody",
        "0"
    ],

    [
        "Timeout",
        "86400"
    ],

    [
        "ProxyTimeout",
        "86400"
    ],

    [
        "RewriteCond",
        '%{HTTP:Upgrade} websocket [NC]'
    ],

    [
        "RewriteCond",
        '%{HTTP:Connection} upgrade [NC]'
    ],

    [
        "RewriteRule",
        '.? ws://127.0.0.1:' . $port . '/%1 [P,L,UnsafeAllow3F]'
    ],

);

my @missing;

foreach my $r (@required) {

    my ($name, $value) = @$r;

    my @found =
        &apache::find_directive($name, $vconf);

    my $ok = grep {
        $_ eq $value
    } @found;

    push @missing, "$name $value"
        unless $ok;
}

if (@missing) {

    print STDERR "Missing directives:\n";

    print STDERR "  $_\n"
        foreach @missing;

    die "SSL VirtualHost verification failed\n";
}

print "All required AIO directives are present in the SSL VirtualHost\n";
print "Domain: $domain_name\n";
print "SSL port: $ssl_port\n";

PERL

log_success "Virtualmin confirms all AIO directives are in the SSL VirtualHost."

# ============================================================================
# Apache configuration test
# ============================================================================

log_step "Testing Apache configuration"

if ! apache2ctl configtest; then

    log_error "Apache configuration test FAILED."

    exit 1

fi

log_success "Apache configuration is valid."

# ============================================================================
# Reload Apache
# ============================================================================

log_step "Reloading Apache"

systemctl reload apache2

log_success "Apache reloaded."

# ============================================================================
# Firewall
# ============================================================================

if command -v firewall-cmd >/dev/null 2>&1; then

    if systemctl is-active --quiet firewalld; then

        if ! firewall-cmd \
            --permanent \
            --query-port=8080/tcp >/dev/null 2>&1; then

            firewall-cmd \
                --permanent \
                --add-port=8080/tcp

        fi

        firewall-cmd --reload

        log_success "Firewall port 8080 opened."

    fi

fi

# ============================================================================
# Verify AIO interface
# ============================================================================

log_step "Checking AIO interface"

AIO_READY=false

for i in {1..60}; do

    if curl \
        --silent \
        --show-error \
        --insecure \
        --max-time 3 \
        "https://127.0.0.1:8080/" \
        >/dev/null 2>&1; then

        AIO_READY=true
        break

    fi

    sleep 2

done

if [[ "$AIO_READY" != true ]]; then

    log_error "AIO interface is not responding on port 8080."

    docker logs \
        --tail 100 \
        nextcloud-aio-mastercontainer || true

    exit 1

fi

log_success "AIO interface is available."

# ============================================================================
# Final state
# ============================================================================

echo "aio_mastercontainer" >> "$STATE_FILE"
echo "aio_ssl_virtualhost" >> "$STATE_FILE"
echo "aio_apache" >> "$STATE_FILE"

SERVER_IP="$(hostname -I | awk '{print $1}')"

echo
echo "============================================================"
echo " Nextcloud AIO installation prepared"
echo "============================================================"
echo
echo "Domain:"
echo "  $aio_domain"
echo
echo "Architecture:"
echo "  $ARCH"
echo
echo "AIO image:"
echo "  $AIO_IMAGE"
echo
echo "AIO internal Apache:"
echo "  $AIO_BINDING:$AIO_PORT"
echo
echo "AIO management interface:"
echo
echo "  https://$SERVER_IP:8080"
echo
echo "============================================================"
echo " SSL VIRTUALHOST"
echo "============================================================"
echo
echo "AIO reverse-proxy directives have been added through"
echo "Virtualmin's own SSL VirtualHost configuration."
echo
echo "They are NOT added to the HTTP VirtualHost."
echo
echo "Virtualmin SSL directives can be viewed at:"
echo
echo "  Services → Configure SSL Website → Edit Directives"
echo
echo "for:"
echo
echo "  $aio_domain"
echo
echo "============================================================"
echo
