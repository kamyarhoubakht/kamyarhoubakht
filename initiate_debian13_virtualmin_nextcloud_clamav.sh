#!/bin/bash
set -Eeuo pipefail
[[ "${DEBUG:-}" == "true" ]] && set -x
export DEBIAN_FRONTEND=noninteractive

# Use the universally available C locale until en_US.UTF-8 is verified below.
# SSH clients may otherwise pass LC_CTYPE=UTF-8, which Debian cannot use.
export LANG=C LC_ALL=C LC_CTYPE=C

LOG_FILE="/var/log/setup_script.log"
STATE_FILE="/root/.setup_state"
CURRENT_STAGE="Preflight"
INSTALL_COMPLETE=0
TEMP_DOCKER_NETWORK=""
AIO_SSL_STATUS="not checked (AIO installation skipped)"

# Capture command output in the installation log as well as the terminal.
# Keep it private because installation commands may print sensitive details.
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

touch "$STATE_FILE"
chmod 600 "$STATE_FILE"

log_step() { CURRENT_STAGE="$1"; echo "🔄 $1"; }
log_success() { echo "✅ $1"; }
log_error() { echo "❌ $1" >&2; }

handle_error() {
    local exit_code=$?
    local line_number=$1
    echo
    log_error "Error occurred at line $line_number. Exit code: $exit_code"
    log_error "Full log: $LOG_FILE"
    echo
    exit "$exit_code"
}

cleanup() {
    local exit_code=$?
    trap - EXIT

    # Clean up an interrupted temporary network test, if one was started.
    if [[ -n "${TEMP_DOCKER_NETWORK:-}" ]] && command -v docker >/dev/null 2>&1; then
        docker network rm "$TEMP_DOCKER_NETWORK" >/dev/null 2>&1 || true
    fi

    if [[ "$exit_code" -ne 0 ]]; then
        echo
        log_error "INSTALLATION FAILED during: $CURRENT_STAGE (exit $exit_code)"
        log_error "Review the log at $LOG_FILE and fix the error before re-running."
    elif [[ "${INSTALL_COMPLETE:-0}" -ne 1 ]]; then
        log_error "The installer exited without completing its final verification."
        exit_code=1
    fi
    exit "$exit_code"
}

trap 'handle_error $LINENO' ERR
trap cleanup EXIT

step_done() {
    grep -qxF "$1" "$STATE_FILE" 2>/dev/null
}

mark_done() {
    grep -qxF "$1" "$STATE_FILE" 2>/dev/null || echo "$1" >> "$STATE_FILE"
}

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
            12|13)
                log_success "Supported Debian version detected: $OS_VERSION_ID"
                ;;
            *)
                log_error "Unsupported Debian version: $OS_VERSION_ID"
                log_error "Supported Debian versions: 12, 13"
                exit 1
                ;;
        esac
        ;;
    ubuntu)
        case "$OS_VERSION_ID" in
            24.04|26.04)
                log_success "Supported Ubuntu version detected: $OS_VERSION_ID"
                ;;
            *)
                log_error "Unsupported Ubuntu version: $OS_VERSION_ID"
                log_error "Supported Ubuntu versions: 24.04, 26.04 LTS"
                exit 1
                ;;
        esac
        ;;
    *)
        log_error "Unsupported operating system."
        log_error "This script supports Debian 12/13 and Ubuntu 24.04/26.04 LTS."
        exit 1
        ;;
esac

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
    amd64|arm64)
        log_success "Supported architecture detected: $ARCH"
        ;;
    *)
        log_error "Unsupported architecture: $ARCH"
        log_error "Supported architectures: amd64, arm64"
        exit 1
        ;;
esac


# ---------------------------------------------------------------------------
# Collect all interactive answers BEFORE installation begins
# ---------------------------------------------------------------------------
log_step "Collecting all installation choices"

if step_done "admin_user"; then
    sudo_user="$(cat /root/.virtualmin_admin_user)"
else
    read -rp "Enter administrator username (default: goodmin): " sudo_user
    sudo_user="${sudo_user:-goodmin}"

    if ! [[ "$sudo_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || [[ "$sudo_user" == "root" ]]; then
        log_error "Invalid administrator username: $sudo_user"
        exit 1
    fi

    echo
    echo "============================================================"
    echo " Administrator password"
    echo "============================================================"
    echo
    while true; do
        read -rsp "Password: " sudo_user_password
        echo
        if [[ ${#sudo_user_password} -lt 12 ]]; then
            echo "Password must contain at least 12 characters."
            continue
        fi
        read -rsp "Confirm password: " sudo_user_password_confirm
        echo
        if [[ "$sudo_user_password" != "$sudo_user_password_confirm" ]]; then
            echo "Passwords do not match. Please try again."
            continue
        fi
        break
    done
    unset sudo_user_password_confirm
fi

# ---------------------------------------------------------------------------
# Step 2: Select Virtualmin stack
# ---------------------------------------------------------------------------

if ! step_done "stack_selected"; then

    while true; do

        read -rp \
            "Install LAMP (Apache) or LEMP (Nginx)? (LAMP/LEMP): " \
            stack_choice

        stack_choice="$(echo "$stack_choice" | tr '[:lower:]' '[:upper:]')"

        if [[ "$stack_choice" == "LAMP" || "$stack_choice" == "LEMP" ]]; then
            break
        fi

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
# Step 2b: Nextcloud AIO decision
# ---------------------------------------------------------------------------

if [[ -f /root/.nextcloud_choice ]]; then

    install_nc="$(cat /root/.nextcloud_choice)"

else

    while true; do
        read -rp "Do you want to install NextCloud-AIO? (y/n): " install_nc
        install_nc="$(echo "$install_nc" | tr '[:upper:]' '[:lower:]')"
        if [[ "$install_nc" == "y" && "$stack_choice" == "LEMP" ]]; then
            echo "Nextcloud AIO requires LAMP. Choose n with LEMP."
            continue
        fi
        [[ "$install_nc" == "y" || "$install_nc" == "n" ]] && break
        echo "Please enter y or n."
    done

    echo "$install_nc" > /root/.nextcloud_choice

fi


if [[ "$install_nc" =~ ^y$ ]]; then

    if [[ "$stack_choice" != "LAMP" ]]; then

        log_error \
            "Nextcloud AIO integration requires the LAMP/Apache Virtualmin stack."

        log_error \
            "Re-run this bootstrap and choose LAMP if you want the integrated AIO reverse proxy,"

        log_error \
            "or answer 'n' to the Nextcloud AIO question if you want to keep LEMP."

        exit 1
    fi

    log_success \
        "Nextcloud AIO selected; will be installed after Docker/Portainer are ready."

else

    log_success "NextCloud-AIO not selected."

fi


# Do not silently treat an invalid answer as 'no'.
if [[ "$install_nc" != "y" && "$install_nc" != "n" ]]; then
    log_error "Invalid saved Nextcloud selection '$install_nc'; expected y or n."
    exit 1
fi

# ---------------------------------------------------------------------------
# Nextcloud domain is collected now, not during Step 8.
# ---------------------------------------------------------------------------
valid_domain() {
    local name="$1" part
    local -a labels
    [[ ${#name} -le 253 && "$name" == *.* && "$name" != *..* ]] || return 1
    [[ "$name" =~ ^[a-z0-9.-]+$ && "$name" != .* && "$name" != *. ]] || return 1
    IFS='.' read -r -a labels <<< "$name"
    for part in "${labels[@]}"; do
        [[ "$part" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
    done
}

if [[ "$install_nc" == "y" ]]; then
    if [[ -s /root/.nextcloud_domain ]]; then
        AIO_DOMAIN="$(cat /root/.nextcloud_domain)"
    else
        echo
        echo "Enter the independent Nextcloud domain/subdomain."
        echo "DNS must point to this server before completing AIO setup."
        read -rp "Nextcloud domain: " AIO_DOMAIN
        AIO_DOMAIN="${AIO_DOMAIN,,}"
        valid_domain "$AIO_DOMAIN" || { log_error "Invalid Nextcloud domain: $AIO_DOMAIN"; exit 1; }
        printf '%s\n' "$AIO_DOMAIN" > /root/.nextcloud_domain
        chmod 600 /root/.nextcloud_domain
    fi
    valid_domain "$AIO_DOMAIN" || { log_error "Invalid stored Nextcloud domain: $AIO_DOMAIN"; exit 1; }
else
    AIO_DOMAIN=""
fi

# ---------------------------------------------------------------------------
# Step 3: Hostname (ask now, apply after administrator setup)
# ---------------------------------------------------------------------------
if step_done "hostname" || [[ -s /root/.virtualmin_hostname ]]; then
    hostname="$(cat /root/.virtualmin_hostname)"
    log_success "Using selected hostname: $hostname"
else
    CURRENT_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
    echo
    echo "Virtualmin requires a proper fully qualified hostname."
    echo "Example: server.example.com"
    echo
    read -rp "Enter hostname [$CURRENT_HOSTNAME]: " hostname
    hostname="${hostname:-$CURRENT_HOSTNAME}"
    hostname="$(echo "$hostname" | tr '[:upper:]' '[:lower:]')"
    valid_domain "$hostname" || { log_error "Invalid hostname: $hostname"; exit 1; }
    printf '%s\n' "$hostname" > /root/.virtualmin_hostname
    chmod 600 /root/.virtualmin_hostname
fi
valid_domain "$hostname" || { log_error "Invalid stored hostname: $hostname"; exit 1; }
if [[ "$install_nc" == "y" && "$AIO_DOMAIN" == "$hostname" ]]; then
    log_error "Nextcloud domain must differ from the server hostname."
    exit 1
fi

log_success "Initial choices collected. Continuing without further prompts."

# ---------------------------------------------------------------------------
# System Locales Configuration
# ---------------------------------------------------------------------------

if ! step_done "locale_fix" || ! locale -a | grep -qi '^en_US\.utf8$'; then
    log_step "Generating en_US.UTF-8 locale to prevent Perl warnings"

    apt-get update
    apt-get install -y locales

    sed -i \
        's/^[#[:space:]]*en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' \
        /etc/locale.gen

    if ! grep -qxF 'en_US.UTF-8 UTF-8' /etc/locale.gen; then
        echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
    fi

    locale-gen en_US.UTF-8 >/dev/null 2>&1
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

    if ! locale -a | grep -qi '^en_US\.utf8$'; then
        log_error "en_US.UTF-8 is still unavailable after locale generation."
        exit 1
    fi

    log_success "System locale generated and set to en_US.UTF-8."
    mark_done "locale_fix"
else
    log_success "Locale already configured, skipping."
fi

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export LC_CTYPE="en_US.UTF-8"


# ---------------------------------------------------------------------------
# Backup important configuration
# ---------------------------------------------------------------------------

if ! step_done "backup"; then
    log_step "Creating backup of important configuration files"

    BACKUP_DIR="/root/pre_install_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    for file in \
        /etc/passwd \
        /etc/shadow \
        /etc/group \
        /etc/gshadow \
        /etc/sudoers \
        /etc/sudoers.d \
        /root/.ssh
    do
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

    log_success "Using administrator username selected at startup: $sudo_user"

    echo "$sudo_user" > /root/.virtualmin_admin_user
    chmod 600 /root/.virtualmin_admin_user

    if id -u "$sudo_user" &>/dev/null; then
        log_success "User '$sudo_user' already exists."
    else
        log_step "Creating administrator user '$sudo_user'"
        useradd --create-home --shell /bin/bash "$sudo_user"
        log_success "User '$sudo_user' created."
    fi

    # Password was entered once, during initial configuration.
    [[ -n "${sudo_user_password:-}" ]] || {
        log_error "Missing administrator password from initial configuration."
        exit 1
    }

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

    cp "$ROOT_AUTH_KEYS" \
        "$USER_HOME/.ssh/authorized_keys"

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
        log_error "Administrator username state is missing; re-run the installer."
        exit 1
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

    cp -a "$SSH_CONFIG" \
        "${SSH_CONFIG}.pre-virtualmin-$(date +%Y%m%d_%H%M%S)"

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
# Step 2/3: Values were collected before installation began.
# ---------------------------------------------------------------------------
if ! step_done "hostname"; then
    log_step "Applying the selected server hostname"
    hostnamectl set-hostname "$hostname"
    mark_done "hostname"
else
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
        --yes \
        --bundle "$stack_choice" \
        --hostname "$hostname"

    log_success "Virtualmin installed successfully."

    mark_done "virtualmin"

else

    log_success "Virtualmin already installed, skipping."

fi

# ---------------------------------------------------------------------------
# Step 4a: Tune default Virtualmin PHP-FPM template
# ---------------------------------------------------------------------------
#
# Use PHP-FPM ondemand for newly-created virtual servers. This prevents
# dozens of independent PHP-FPM pools from permanently retaining idle
# workers on multi-site hosting servers.
#
# Leave web_phpchildren unchanged/disabled so Virtualmin continues to
# calculate pm.max_children automatically.
#
# Additional PHP-FPM pool options are stored internally by Virtualmin as
# tab-separated values. modify-template --value-file converts newlines
# to tabs automatically.
# ---------------------------------------------------------------------------

if ! step_done "virtualmin_php_fpm_defaults"; then

    log_step "Configuring Virtualmin Default Settings PHP-FPM defaults"

    PHP_FPM_OPTIONS_FILE="$(mktemp)"

    cat > "$PHP_FPM_OPTIONS_FILE" <<'EOF'
pm.process_idle_timeout = 10s
pm.max_requests = 500
EOF

    if virtualmin modify-template \
        --name "Default Settings" \
        --setting php_fpmtype --value "ondemand" \
        --setting php_fpm --value-file "$PHP_FPM_OPTIONS_FILE"
    then
        rm -f "$PHP_FPM_OPTIONS_FILE"
    else
        rm -f "$PHP_FPM_OPTIONS_FILE"
        log_error "Failed to configure PHP-FPM defaults in Virtualmin Default Settings template."
        exit 1
    fi

    log_success "Virtualmin Default Settings configured for PHP-FPM ondemand."

    mark_done "virtualmin_php_fpm_defaults"

else

    log_success "Virtualmin PHP-FPM defaults already configured, skipping."

fi


# ---------------------------------------------------------------------------
# Step 4b: Webmin nftables — default-deny public Docker bridge forwarding
# ---------------------------------------------------------------------------
# Recheck on every run, including installs with the older state marker.
# Only explicitly listed published host ports are allowed from outside.
# Host INPUT ports and public Docker FORWARD ports use separate sets.
# The embedded repair keeps Docker/Fail2ban tables intact during reloads.
log_step "Configuring and verifying Docker forwarding allowlists and firewall lifecycle"
(
# Repair Webmin firewall lifecycle and restrict public Docker bridge ingress.
# Run as root. Existing Docker containers are not restarted.
# Initial allowlists contain Talk's 3478 TCP/UDP. Set either variable to an
# empty string before the first run to create an empty allowlist instead.
# Existing allowlists are always preserved; edit their sets in nftables.conf.
set -Eeuo pipefail
export LC_ALL=C

[[ $EUID -eq 0 ]] || { echo 'Run this script as root.' >&2; exit 1; }
for command in nft systemctl awk curl; do
    command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
[[ -s /etc/nftables.conf ]] || { echo 'Missing /etc/nftables.conf' >&2; exit 1; }

repair_tmp=$(mktemp -d)
trap 'rm -rf "$repair_tmp"' EXIT

# Render a complete atomic transaction for only Webmin-owned host tables.
# The renderer rejects includes, arbitrary commands and externally owned tables.
cat > "$repair_tmp/virtualmin-nftables-host" <<'HOST_HELPER'
#!/bin/bash
set -Eeuo pipefail
export LC_ALL=C
mode=${1:-apply}
case "$mode" in render|check|apply|stop) ;; *) echo 'Use render, check, apply or stop.' >&2; exit 2 ;; esac
conf=${2:-/etc/nftables.conf}
[[ -s "$conf" ]] || { echo "Missing $conf" >&2; exit 1; }
tmp=$(mktemp -d /run/virtualmin-nftables-XXXXXXXX)
trap 'rm -rf "$tmp"' EXIT

awk -v stop_mode="$([[ $mode == stop ]] && echo 1 || echo 0)" '
    function fail(message) { print message > "/dev/stderr"; bad=1; exit 1 }
    function owned(family, name) {
        return family == "inet" && (name == "filter" || name ~ /^webmin_profile_[A-Za-z0-9_]+$/)
    }
    {
        original=$0
        code=$0
        # Strip quoted strings before counting braces or finding comments.
        gsub(/"([^"\\]|\\.)*"/, "\"\"", code)
        sub(/#.*/, "", code)
        if (code ~ /^[[:space:]]*$/) {
            if (original !~ /^#!/ && original !~ /^# Managed host-only nftables transaction/ && nbody > 0)
                body[++nbody]=original
            next
        }
        if (depth == 0) {
            if (code ~ /^[[:space:]]*flush[[:space:]]+ruleset[[:space:]]*;?[[:space:]]*$/) next
            if (code ~ /^[[:space:]]*(add|delete)[[:space:]]+table[[:space:]]+inet[[:space:]]+[A-Za-z0-9_]+[[:space:]]*;?[[:space:]]*$/) {
                name=$4; sub(/;$/, "", name)
                if (!owned($3,name)) fail("Refusing to modify a non-Webmin table: " original)
                next
            }
            if (code !~ /^[[:space:]]*table[[:space:]]+inet[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\{[[:space:]]*$/)
                fail("Unsupported top-level firewall syntax; no rules applied: " original)
            if (!owned($2,$3)) fail("Externally managed table in saved host configuration: " $3)
            if (seen[$3]++) fail("Duplicate saved table: " $3)
            names[++ntables]=$3
            if ($3 ~ /^webmin_profile_/) profiles++
        }
        if (code ~ /^[[:space:]]*include[[:space:]]/)
            fail("Included firewall files require a separate review; no rules applied.")
        body[++nbody]=original
        opens=gsub(/\{/, "{", code); closes=gsub(/\}/, "}", code)
        depth+=opens-closes
        if (depth < 0) fail("Unbalanced firewall configuration.")
    }
    END {
        if (bad) exit 1
        if (depth != 0 || ntables == 0 || profiles == 0) fail("Expected complete Webmin host profile tables.")
        print "#!/usr/sbin/nft -f"
        print "# Managed host-only nftables transaction (virtualmin-docker)"
        for (i=1; i<=ntables; i++) {
            # add is idempotent; delete then removes old chains AND set elements.
            # All commands are committed in one nft transaction.
            print "add table inet " names[i]
            print "delete table inet " names[i]
        }
        if (!stop_mode) for (i=1; i<=nbody; i++) print body[i]
    }
' "$conf" > "$tmp/rules.nft"

if [[ $mode == render ]]; then
    cat "$tmp/rules.nft"
    exit 0
fi
/usr/sbin/nft -c -f "$tmp/rules.nft"
if [[ $mode != check ]]; then
    /usr/sbin/nft -f "$tmp/rules.nft"
fi
HOST_HELPER
chmod 700 "$repair_tmp/virtualmin-nftables-host"

echo 'Validating a host-only firewall transaction...'
"$repair_tmp/virtualmin-nftables-host" render > "$repair_tmp/host-original.nft"

# These defaults seed NEW sets only. Repeat runs retain all manual changes,
# including empty allowlists. Do not copy the broad hosting/FTP port ranges.
docker_tcp_ports=${DOCKER_PUBLIC_TCP_PORTS-3478}
docker_udp_ports=${DOCKER_PUBLIC_UDP_PORTS-3478}
for ports in "$docker_tcp_ports" "$docker_udp_ports"; do
    if [[ -n "$ports" ]] && ! awk -v ports="$ports" 'BEGIN {
        n=split(ports,a,",")
        for (i=1;i<=n;i++) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[i])
            if (a[i] !~ /^[0-9]+$/ || a[i]+0 < 1 || a[i]+0 > 65535) exit 1
        }
    }'; then
        echo 'Initial Docker port lists must be comma-separated numbers from 1 to 65535.' >&2
        exit 1
    fi
done

# Docker performs DNAT before FORWARD. Match the original HOST port.
# The explicit DNAT drops precede the established rule, so removing a public
# port from an allowlist also blocks existing inbound connections to that port.
cat > "$repair_tmp/forward-rules" <<'FORWARD_RULES'
ct state invalid drop
iifname "docker0" accept
iifname "br-*" accept
oifname "docker0" ct status dnat meta l4proto tcp ct original proto-dst @docker_public_tcp_ports accept
oifname "br-*" ct status dnat meta l4proto tcp ct original proto-dst @docker_public_tcp_ports accept
oifname "docker0" ct status dnat meta l4proto udp ct original proto-dst @docker_public_udp_ports accept
oifname "br-*" ct status dnat meta l4proto udp ct original proto-dst @docker_public_udp_ports accept
oifname "docker0" ct status dnat ct state related meta l4proto { icmp, ipv6-icmp } accept
oifname "br-*" ct status dnat ct state related meta l4proto { icmp, ipv6-icmp } accept
oifname "docker0" ct status dnat counter drop
oifname "br-*" ct status dnat counter drop
ct state established,related accept
FORWARD_RULES

# Replace only a recognized empty, legacy or already-managed forward chain.
# Unknown forwarding rules stop the migration rather than being discarded.
awk -v rules_file="$repair_tmp/forward-rules" \
    -v tcp_ports="$docker_tcp_ports" -v udp_ports="$docker_udp_ports" '
    function fail(message) { print message > "/dev/stderr"; bad=1; exit 1 }
    function trim(s) {
        sub(/^[[:space:]]+/, "", s); sub(/[[:space:];]+$/, "", s)
        gsub(/[[:space:]]+/, " ", s); return s
    }
    function port_set(name, ports) {
        print "    set " name " {"
        print "        type inet_service;"
        print "        flags interval;"
        if (ports != "") print "        elements = { " ports " };"
        print "    }"
    }
    BEGIN {
        while ((getline line < rules_file) > 0) { rules[++nrules]=line; known[trim(line)]=1 }
        close(rules_file)
        legacy["iifname \"docker0\" accept"]=1
        legacy["iifname \"br-*\" accept"]=1
        legacy["oifname \"docker0\" accept"]=1
        legacy["oifname \"br-*\" accept"]=1
    }
    {
        source[NR]=$0
        code=$0; gsub(/"([^"\\]|\\.)*"/, "\"\"", code); sub(/#.*/, "", code)
        if (depth == 0 && code ~ /^[[:space:]]*table[[:space:]]+inet[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\{/) {
            table_name=$3
        }
        if (depth == 1 && table_name ~ /^webmin_profile_/ &&
            code ~ /^[[:space:]]*chain[[:space:]]+forward[[:space:]]*\{/) {
            count++; chosen_table=table_name; first=NR; in_forward=1
        }
        if (in_forward && index($0, "# Docker public forwarding allowlist (virtualmin-docker)")) managed=1
        if (depth == 1 && table_name ~ /^webmin_profile_/ &&
            code ~ /^[[:space:]]*set[[:space:]]+docker_public_(tcp|udp)_ports[[:space:]]*\{/) {
            if ($2 == "docker_public_tcp_ports") tcp_sets++
            else udp_sets++
            set_table=table_name
        }
        opens=gsub(/\{/, "{", code); closes=gsub(/\}/, "}", code)
        depth+=opens-closes
        if (in_forward && depth == 1 && closes) { last=NR; in_forward=0 }
    }
    END {
        if (bad) exit 1
        if (count != 1 || !last) fail("Expected one Webmin forward chain; no changes made.")
        if ((tcp_sets || udp_sets) &&
            (tcp_sets != 1 || udp_sets != 1 || set_table != chosen_table || !managed))
            fail("Unrecognized Docker allowlist sets; no changes made.")
        for (i=first+1; i<last; i++) {
            line=source[i]; sub(/#.*/, "", line); line=trim(line)
            if (line == "") continue
            if (line ~ /^type filter hook forward priority (0|filter); policy drop$/) { hooks++; continue }
            if (managed) {
                if (!known[line] || seen[line]++) fail("Unexpected managed forwarding rule: " line)
                managed_rules++
            }
            else {
                if (!legacy[line] || seen[line]++) fail("Custom forwarding rules require review: " line)
                legacy_rules++
            }
        }
        if (hooks != 1 || (managed && (managed_rules != nrules || tcp_sets != 1 || udp_sets != 1)) ||
            (!managed && legacy_rules != 0 && legacy_rules != 4))
            fail("Incomplete or unsupported forwarding policy; no changes made.")
        for (i=1;i<=NR;i++) {
            if (i == first) {
                if (!tcp_sets) {
                    port_set("docker_public_tcp_ports", tcp_ports)
                    port_set("docker_public_udp_ports", udp_ports)
                }
                print "    chain forward {"
                print "        type filter hook forward priority 0; policy drop;"
                print "        # Docker public forwarding allowlist (virtualmin-docker)"
                for (j=1;j<=nrules;j++) print "        " rules[j]
                print "    }"
            }
            if (i < first || i > last) print source[i]
        }
    }
' "$repair_tmp/host-original.nft" > "$repair_tmp/nftables.conf"
nft -c -f "$repair_tmp/nftables.conf"

# Retain handles of existing externally owned tables; reload must preserve them.
nft -a list tables > "$repair_tmp/tables.before"
awk '$3 ~ /^(docker|f2b)/ {print}' "$repair_tmp/tables.before" > "$repair_tmp/external.before"

repair_backup="/root/firewall-repair-backup-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -m 700 "$repair_backup"
cp -a /etc/nftables.conf "$repair_backup/"
for file in /etc/systemd/system/nftables.service.d/90-virtualmin-docker.conf \
            /etc/systemd/system/docker.service.d/90-host-firewall.conf \
            /usr/local/sbin/virtualmin-nftables-host; do
    if [[ -e "$file" ]]; then cp -a --parents "$file" "$repair_backup/"; fi
done
echo "Configuration backup: $repair_backup"

install -m 755 "$repair_tmp/virtualmin-nftables-host" /usr/local/sbin/virtualmin-nftables-host

# Keep the saved file safe even when loaded directly with nft -f.
# Webmin keeps the original gaps around table definitions when editing them.
repair_candidate=$(mktemp /etc/.nftables-host-XXXXXXXX)
cp "$repair_tmp/nftables.conf" "$repair_candidate"
chmod --reference=/etc/nftables.conf "$repair_candidate"
chown --reference=/etc/nftables.conf "$repair_candidate"
mv "$repair_candidate" /etc/nftables.conf

mkdir -p /etc/systemd/system/nftables.service.d /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/nftables.service.d/90-virtualmin-docker.conf <<'NFT_SERVICE'
[Service]
ExecStart=
ExecStart=/usr/local/sbin/virtualmin-nftables-host apply
ExecReload=
ExecReload=/usr/local/sbin/virtualmin-nftables-host apply
ExecStop=
ExecStop=/usr/local/sbin/virtualmin-nftables-host stop
NFT_SERVICE
cat > /etc/systemd/system/docker.service.d/90-host-firewall.conf <<'DOCKER_ORDER'
[Unit]
Wants=nftables.service
After=nftables.service
DOCKER_ORDER
systemctl daemon-reload

for property in ExecStart ExecReload ExecStop; do
    systemctl show nftables -p "$property" --value | grep -Fq '/usr/local/sbin/virtualmin-nftables-host' || {
        echo "Another systemd override conflicts with $property. Firewall was not started." >&2
        exit 1
    }
done
systemctl enable nftables
if systemctl is-active --quiet nftables; then
    systemctl reload nftables
else
    systemctl start nftables
fi
# Test a second load too: it must be safe and must not duplicate old rules.
systemctl reload nftables
systemctl is-active --quiet nftables
systemctl is-enabled --quiet nftables

nft -a list tables > "$repair_tmp/tables.after"
while IFS= read -r table; do
    grep -Fxq "$table" "$repair_tmp/tables.after" || {
        echo "An existing Docker/Fail2ban table changed during firewall activation: $table" >&2
        exit 1
    }
done < "$repair_tmp/external.before"

profile=$(awk '$1 == "table" && $2 == "inet" && $3 ~ /^webmin_profile_/ {print $3; exit}' /etc/nftables.conf)
nft list chain inet "$profile" input | grep -Eq 'policy[[:space:]]+drop'
nft list chain inet "$profile" forward | grep -Eq 'policy[[:space:]]+drop'

if command -v docker >/dev/null && systemctl is-active --quiet docker; then
    for mapping in 'portainer 9443' 'nextcloud-aio-mastercontainer 8080'; do
        read -r container port <<< "$mapping"
        if [[ $(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true) == true ]]; then
            curl -kfsS --connect-timeout 5 --max-time 15 -o /dev/null "https://127.0.0.1:$port/"
            echo "$container: local HTTPS passed with the firewall active."
        fi
    done
    if [[ $(docker inspect --format '{{.State.Running}}' nextcloud-aio-nextcloud 2>/dev/null || true) == true ]]; then
        docker exec nextcloud-aio-nextcloud curl -fsS --connect-timeout 5 --max-time 20 \
            -o /dev/null https://download.nextcloud.com/
        echo 'Nextcloud container: DNS and outbound HTTPS passed.'
    fi
fi
echo 'Host firewall active and enabled; reload preserved existing Docker/Fail2ban tables.'
echo 'Public Docker bridge ports require membership in docker_public_tcp_ports / docker_public_udp_ports.'
nft list set inet "$profile" docker_public_tcp_ports
nft list set inet "$profile" docker_public_udp_ports
)
mark_done "firewall_docker_forward"

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

case "$OS_ID" in
    debian|ubuntu)
        ;;
    *)
        log_error \
            "Unsupported operating system for Docker repository: $OS_ID"
        exit 1
        ;;
esac

case "$DOCKER_ARCH" in
    amd64|arm64)
        ;;
    *)
        log_error \
            "Unsupported Docker architecture: $DOCKER_ARCH"
        exit 1
        ;;
esac


if ! step_done "docker"; then

    log_step "Installing Docker from the official Docker repository"

    apt-get remove -y \
        docker.io \
        docker-compose \
        docker-doc \
        podman-docker \
        containerd \
        runc \
        2>/dev/null || true

    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL \
        "https://download.docker.com/linux/$OS_ID/gpg" \
        -o /etc/apt/keyrings/docker.asc

    chmod a+r /etc/apt/keyrings/docker.asc

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$OS_ID
Suites: $OS_CODENAME
Components: stable
Architectures: $DOCKER_ARCH
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    # -----------------------------------------------------------------------
    # Docker native nftables firewall backend
    #
    # Configure Docker BEFORE installing the Docker packages. This ensures
    # that if the Docker package starts dockerd during installation, it
    # already uses the native nftables firewall backend.
    # -----------------------------------------------------------------------

    log_step "Configuring Docker to use the native nftables firewall backend"

    mkdir -p /etc/docker

    cat > /etc/docker/daemon.json <<'EOF'
{
    "firewall-backend": "nftables"
}
EOF

    log_success "Docker native nftables firewall backend configured."

    # -----------------------------------------------------------------------
    # IP forwarding
    #
    # Docker's native nftables backend does not enable IP forwarding itself.
    # Enable it persistently for both IPv4 and IPv6.
    # -----------------------------------------------------------------------

    log_step "Enabling IP forwarding for Docker"

    cat > /etc/sysctl.d/99-docker-forwarding.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF

    sysctl --system >/dev/null

    if [[ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]]; then
        log_error "IPv4 forwarding could not be enabled."
        exit 1
    fi

    if [[ "$(sysctl -n net.ipv6.conf.all.forwarding)" != "1" ]]; then
        log_error "IPv6 forwarding could not be enabled."
        exit 1
    fi

    log_success "IPv4 and IPv6 forwarding enabled."

    # -----------------------------------------------------------------------
    # Install Docker
    # -----------------------------------------------------------------------

    apt-get update

    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    # Native nftables requires Docker Engine 29 or newer.
    DOCKER_VERSION="$(docker --version | awk '{print $3}' | tr -d ',')"
    if ! dpkg --compare-versions "$DOCKER_VERSION" ge "29.0.0"; then
        log_error "Docker Engine $DOCKER_VERSION does not support native nftables (requires 29+)."
        exit 1
    fi

    systemctl enable --now docker

    if ! systemctl is-active --quiet docker; then
        log_error "Docker service is not running."
        exit 1
    fi

    log_success "Docker installed and running with native nftables firewall backend."

    mark_done "docker"

else

    log_success "Docker already installed, skipping."

fi


# ---------------------------------------------------------------------------
# Functional networking tests: default and user-created Docker bridge.
# The HTTPS request exercises DNS, forwarding, and NAT together.
# ---------------------------------------------------------------------------
test_docker_networking() {
    log_step "Testing Docker DNS and HTTPS through both bridge networks"
    local test_image="curlimages/curl:latest"
    local network_name="initiate-docker-test-$$"

    docker pull "$test_image" >/dev/null
    docker run --rm --network bridge "$test_image" \
        --fail --silent --show-error --location --retry 2 \
        --max-time 30 https://example.com/ >/dev/null
    log_success "Docker default bridge: DNS and HTTPS passed."

    docker network create --driver bridge "$network_name" >/dev/null
    TEMP_DOCKER_NETWORK="$network_name"
    docker run --rm --network "$network_name" "$test_image" \
        --fail --silent --show-error --location --retry 2 \
        --max-time 30 https://example.com/ >/dev/null
    docker network rm "$network_name" >/dev/null
    TEMP_DOCKER_NETWORK=""
    log_success "Docker user-created bridge: DNS and HTTPS passed."
}

test_docker_networking

# ---------------------------------------------------------------------------
# Add administrator to Docker group
# ---------------------------------------------------------------------------

if ! id -nG "$sudo_user" | tr ' ' '\n' | grep -qx "docker"; then

    usermod -aG docker "$sudo_user"

    log_success "User '$sudo_user' added to the Docker group."

else

    log_success "User '$sudo_user' is already a member of the Docker group."

fi


# ---------------------------------------------------------------------------
# Run a command as administrator
# ---------------------------------------------------------------------------

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

    log_step \
        "Validating Portainer Compose configuration as $sudo_user"

    run_as_admin "$PORTAINER_DIR" \
        docker compose -f docker-compose.yaml config >/dev/null

    log_step "Starting Portainer as $sudo_user"

    run_as_admin "$PORTAINER_DIR" \
        docker compose -f docker-compose.yaml up -d

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
# ---------------------------------------------------------------------------

if [[ "$install_nc" =~ ^y$ ]]; then

    if ! step_done "nextcloud_aio"; then

        # -------------------------------------------------------------------
        # Nextcloud AIO configuration
        # -------------------------------------------------------------------

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
            echo "============================================================" \
                | tee -a "$AIO_LOG_FILE"

            echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" \
                | tee -a "$AIO_LOG_FILE"

            echo "============================================================" \
                | tee -a "$AIO_LOG_FILE"
        }


        aio_die() {

            log_error "$1"
            log_error "Nextcloud AIO log: $AIO_LOG_FILE"

            exit 1
        }


        aio_warn() {

            echo "⚠ $1" | tee -a "$AIO_LOG_FILE"
        }


        touch "$AIO_LOG_FILE" "$AIO_STATE_FILE"
        chmod 600 "$AIO_STATE_FILE"


        for command in \
            virtualmin \
            apache2ctl \
            curl \
            openssl \
            runuser
        do

            command -v "$command" >/dev/null 2>&1 || \
                aio_die "Required command not found: $command"

        done


        aio_log "Starting Nextcloud AIO installation"


        # Domain was collected and validated before installation began.
        [[ -n "$AIO_DOMAIN" ]] || aio_die "Missing Nextcloud domain from startup configuration."

        aio_log "Nextcloud domain: $AIO_DOMAIN"


        # -------------------------------------------------------------------
        # Generate Virtualmin domain password
        # -------------------------------------------------------------------

        aio_log "Generating password for the Virtualmin domain"

        DOMAIN_PASSWORD="$(openssl rand -hex 16)"

        [[ -n "$DOMAIN_PASSWORD" ]] || \
            aio_die "Failed to generate Virtualmin domain password."


        # -------------------------------------------------------------------
        # Save AIO state
        # -------------------------------------------------------------------

        cat > "$AIO_STATE_FILE" <<EOF
AIO_DOMAIN='$AIO_DOMAIN'
AIO_ADMIN_PORT='$AIO_ADMIN_PORT'
AIO_WEB_PORT='$AIO_WEB_PORT'
AIO_DATA_DIR='$AIO_DATA_DIR'
AIO_COMPOSE_FILE='$AIO_COMPOSE_FILE'
ADMIN_USER='$sudo_user'
VIRTUALMIN_DOMAIN_PASSWORD='$DOMAIN_PASSWORD'
EOF

        chmod 600 "$AIO_STATE_FILE"


        # -------------------------------------------------------------------
        # Create Virtualmin Reverse Proxy Server Template
        #
        # This is intentionally NOT idempotent.
        # This installation is intended for a fresh server.
        # -------------------------------------------------------------------

        aio_log "Creating Virtualmin 'Reverse Proxy' Server Template"

        virtualmin create-template \
            --name "Reverse Proxy" \
            --clone "Default Settings" \
            || aio_die \
                "Failed to create Virtualmin 'Reverse Proxy' template."


        aio_log "Configuring Virtualmin 'Reverse Proxy' Server Template"

        # Preserve the cloned Apache directives except these two host aliases.
        RP_APACHE_TEMPLATE_FILE="$(mktemp)"

        if ! virtualmin get-template \
            --name "Reverse Proxy" \
            --inherited \
            --setting web \
            | tr '\t' '\n' \
            | awk '
                $1 == "ServerAlias" &&
                ($2 == "www.${DOM}" || $2 == "mail.${DOM}") &&
                NF == 2 { next }
                { print }
            ' > "$RP_APACHE_TEMPLATE_FILE"
        then
            rm -f "$RP_APACHE_TEMPLATE_FILE"
            aio_die "Failed to read the Reverse Proxy Apache template directives."
        fi

        virtualmin modify-template \
            --name "Reverse Proxy" \
            --setting mysql_mkdb --value 0 \
            --setting skel --value "" \
            --setting ushell --value "/dev/null" \
            --setting web_admin --value 0 \
            --setting web_cgimode --value "none" \
            --setting web_php_suexec --value 4 \
            --setting web --value-file "$RP_APACHE_TEMPLATE_FILE" \
            --setting web_webmail --value 0 \
            --setting web_sslredirect --value 1 \
            --setting ssl_auto_letsencrypt --value 0 \
            --setting mail_subject --value "" \
            || {
                rm -f "$RP_APACHE_TEMPLATE_FILE"
                aio_die "Failed to configure Virtualmin 'Reverse Proxy' template."
            }

        rm -f "$RP_APACHE_TEMPLATE_FILE"

        log_success \
            "Virtualmin 'Reverse Proxy' Server Template created and configured."


        # -------------------------------------------------------------------
        # Create Reverse Proxy Account Plan
        #
        # This is intentionally NOT idempotent.
        # -------------------------------------------------------------------

        aio_log "Creating Virtualmin 'Reverse Proxy' Account Plan"

        virtualmin create-plan \
            --name "Reverse Proxy" \
            --quota 5242880 \
            --admin-quota 5242880 \
            --max-mailbox 1 \
            --max-alias 0 \
            --max-dbs 0 \
            --max-doms 0 \
            --max-aliasdoms 0 \
            --max-realdoms 0 \
            --features "unix dir web ssl logrotate dns" \
            --capabilities "domain users aliases" \
            || aio_die \
                "Failed to create Virtualmin 'Reverse Proxy' account plan."


        log_success \
            "Virtualmin 'Reverse Proxy' Account Plan created."


        # -------------------------------------------------------------------
        # Create the Nextcloud Virtualmin domain
        #
        # IMPORTANT:
        # The Reverse Proxy template and plan are deliberately applied here.
        # -------------------------------------------------------------------

        aio_log \
            "Creating Virtualmin domain '$AIO_DOMAIN' using Reverse Proxy template and plan"

        virtualmin create-domain \
            --domain "$AIO_DOMAIN" \
            --pass "$DOMAIN_PASSWORD" \
            --template "Reverse Proxy" \
            --plan "Reverse Proxy" \
            --features-from-plan \
            --limits-from-plan \
            --skip-warnings \
            || aio_die \
                "Virtualmin failed to create $AIO_DOMAIN."


        log_success \
            "Virtualmin domain '$AIO_DOMAIN' created from Reverse Proxy template and plan."


        # -------------------------------------------------------------------
        # Disable mail for the Nextcloud domain
        # -------------------------------------------------------------------

        aio_log "Disabling mail feature for $AIO_DOMAIN"

        virtualmin disable-feature \
            --domain "$AIO_DOMAIN" \
            --mail \
            || aio_die \
                "Could not disable the mail feature for $AIO_DOMAIN."


        # -------------------------------------------------------------------
        # Keep only the Nextcloud hostname, then request its SSL certificate
        #
        # The Reverse Proxy template disables automatic certificate requests
        # during creation. Remove ALL ServerAlias directives from both the
        # HTTP and HTTPS virtual hosts using Virtualmin's native API. This
        # includes www, mail, admin and webmail names that have no DNS records.
        # ServerName remains the selected AIO_DOMAIN.
        # -------------------------------------------------------------------

        aio_log "Removing extra Apache hostnames for $AIO_DOMAIN"

        virtualmin modify-web \
            --domain "$AIO_DOMAIN" \
            --remove-directive "ServerAlias" \
            || aio_die "Failed to remove extra Apache hostnames for $AIO_DOMAIN."

        aio_log "Validating and reloading Apache before requesting SSL"

        apache2ctl configtest \
            || aio_die "Apache configuration is invalid before the SSL request."

        systemctl reload apache2 \
            || aio_die "Failed to reload Apache before the SSL request."

        aio_log "Requesting Let's Encrypt SSL for $AIO_DOMAIN only"

        # Explicit --host also stores this single hostname for renewal.
        # Virtualmin handles the HTTP challenge and temporarily bypasses
        # redirects that would otherwise prevent validation.
        if virtualmin generate-letsencrypt-cert \
            --domain "$AIO_DOMAIN" \
            --host "$AIO_DOMAIN" \
            --renew \
            --web
        then
            AIO_SSL_STATUS="Let's Encrypt installed; automatic renewal enabled"
            log_success "Let's Encrypt certificate installed for $AIO_DOMAIN only; automatic renewal enabled."
        else
            # A failed challenge does not replace the initial certificate.
            # Continue installing AIO with the certificate created by Virtualmin.
            AIO_SSL_STATUS="WARNING: Let's Encrypt failed; initial self-signed certificate retained"
            aio_warn "SSL request failed for $AIO_DOMAIN; continuing with the initial self-signed certificate."
            aio_warn "Check public DNS and inbound TCP port 80, then retry SSL in Virtualmin."
            aio_warn "Certificate failure details: $AIO_LOG_FILE and /var/log/letsencrypt/letsencrypt.log"
        fi


        # -------------------------------------------------------------------
        # Enable required Apache modules
        # -------------------------------------------------------------------

        aio_log "Enabling required Apache modules"

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
            a2enmod "$module" >/dev/null 2>&1 || true
        done


        # -------------------------------------------------------------------
        # Create Nextcloud data directory
        # -------------------------------------------------------------------

        aio_log "Creating Nextcloud data directory"

        mkdir -p "$AIO_DATA_DIR"
        chmod 755 "$AIO_DATA_DIR"


        # -------------------------------------------------------------------
        # Create administrator-owned AIO Compose directory
        # -------------------------------------------------------------------

        aio_log "Creating administrator-owned AIO Compose directory"

        mkdir -p "$AIO_COMPOSE_DIR"

        chown "$sudo_user:$USER_GROUP" "$AIO_COMPOSE_DIR"

        chmod 750 "$AIO_COMPOSE_DIR"


        # -------------------------------------------------------------------
        # Create Nextcloud AIO Docker Compose configuration
        # -------------------------------------------------------------------

        aio_log "Creating Nextcloud AIO Docker Compose configuration"

        cat > "$AIO_COMPOSE_FILE" <<EOF
services:

  nextcloud-aio-mastercontainer:
    image: ${AIO_IMAGE}
    container_name: nextcloud-aio-mastercontainer
    init: true
    restart: always

    ports:
      - "127.0.0.1:${AIO_ADMIN_PORT}:8080"

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


        # -------------------------------------------------------------------
        # Validate and start AIO
        # -------------------------------------------------------------------

        aio_log \
            "Validating AIO Compose configuration as $sudo_user"

        run_as_admin "$AIO_COMPOSE_DIR" \
            docker compose -f docker-compose.yaml config >/dev/null \
            || aio_die \
                "Nextcloud AIO Docker Compose configuration is invalid."


        aio_log "Starting Nextcloud AIO as $sudo_user"

        run_as_admin "$AIO_COMPOSE_DIR" \
            docker compose -f docker-compose.yaml up -d \
            || aio_die \
                "Failed to start Nextcloud AIO."


        # -------------------------------------------------------------------
        # Check AIO administration interface
        # -------------------------------------------------------------------

        aio_log "Checking AIO administration interface (10 seconds)"

        AIO_READY=0

        for i in $(seq 1 10); do

            if curl \
                --silent \
                --show-error \
                --insecure \
                --max-time 1 \
                "https://127.0.0.1:${AIO_ADMIN_PORT}/" \
                >/dev/null 2>&1
            then

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


        # -------------------------------------------------------------------
        # Create native Virtualmin reverse proxy
        # -------------------------------------------------------------------

        aio_log \
            "Creating Virtualmin reverse proxy: / -> http://127.0.0.1:${AIO_WEB_PORT}/"

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


        # -------------------------------------------------------------------
        # Nextcloud AIO Apache directives and HTTP protocols
        #
        # Configure the newly created host in one Virtualmin call. Repeated
        # --add-directive arguments apply to both HTTP and HTTPS virtual hosts.
        # Route Nextcloud discovery URLs around Virtualmin's local
        # /.well-known exception for Let's Encrypt. The redirect targets are
        # outside that exception and reach AIO through the existing / proxy.
        # ACME challenge files retain their existing local handling.
        # -------------------------------------------------------------------

        aio_log "Configuring Nextcloud Apache directives and discovery redirects"

        virtualmin modify-web \
            --domain "$AIO_DOMAIN" \
            --protocols "http/1.1 h2" \
            --add-directive "ProxyPreserveHost On" \
            --add-directive "AllowEncodedSlashes NoDecode" \
            --add-directive "H2WindowSize 5242880" \
            --add-directive "TraceEnable off" \
            --add-directive "LimitRequestBody 0" \
            --add-directive "Timeout 3610" \
            --add-directive "ProxyTimeout 3610" \
            --add-directive "RewriteEngine On" \
            --add-directive 'RewriteRule ^/\.well-known/webfinger/?$ /index.php/.well-known/webfinger [R=301,L]' \
            --add-directive 'RewriteRule ^/\.well-known/nodeinfo/?$ /index.php/.well-known/nodeinfo [R=301,L]' \
            --add-directive 'RewriteRule ^/\.well-known/caldav/?$ /remote.php/dav/ [R=301,L]' \
            --add-directive 'RewriteRule ^/\.well-known/carddav/?$ /remote.php/dav/ [R=301,L]' \
            || aio_die "Failed to configure Nextcloud Apache directives and discovery redirects."


        # -------------------------------------------------------------------
        # Apache syntax test and reload
        # -------------------------------------------------------------------

        aio_log "Validating Apache configuration"

        if ! apache2ctl configtest; then
            aio_die \
                "Apache configuration is invalid. Apache was not reloaded."
        fi

        echo "✓ Apache configuration is valid."

        aio_log "Reloading Apache"

        systemctl reload apache2

        echo "✓ Apache reloaded successfully."


        # -------------------------------------------------------------------
        # Completion
        # -------------------------------------------------------------------

        echo
        echo "============================================================"
        echo "✓ NEXTCLOUD AIO INSTALLATION COMPLETE"
        echo "============================================================"
        echo

        echo "Nextcloud domain:"
        echo "  https://${AIO_DOMAIN}"

        echo

        echo "AIO administration interface:"
        echo "  https://127.0.0.1:${AIO_ADMIN_PORT} (via SSH tunnel)"

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
# Final Docker networking initialization
# ---------------------------------------------------------------------------

log_step "Restarting Docker to finalize nftables networking"

systemctl restart docker

if ! systemctl is-active --quiet docker; then
    log_error "Docker service failed after final restart."
    exit 1
fi

DOCKER_FIREWALL_BACKEND="$(docker info --format '{{.FirewallBackend.Driver}}' 2>/dev/null || true)"

if [[ "$DOCKER_FIREWALL_BACKEND" != "nftables" ]]; then
    log_error "Docker firewall backend after final restart is '$DOCKER_FIREWALL_BACKEND', expected 'nftables'."
    exit 1
fi

log_success "Docker restarted and nftables networking finalized."

# Reproduce the original failure condition: reload AFTER Docker is running.
# No Docker restart follows this reload, so connectivity cannot mask lost NAT.
log_step "Verifying Docker connectivity after a host firewall reload"
systemctl reload nftables
systemctl is-active --quiet nftables
systemctl is-enabled --quiet nftables
log_success "Host firewall active and enabled at boot."

test_docker_networking

# Check the locally bound administrator services. Allow for container startup.
log_step "Verifying local administration services"
for i in $(seq 1 30); do
    if curl -kfsS --max-time 3 https://127.0.0.1:9443/ >/dev/null 2>&1; then
        break
    fi
    if [[ "$i" -eq 30 ]]; then
        log_error "Portainer HTTPS interface is not responding on localhost:9443."
        exit 1
    fi
    sleep 2
done
log_success "Portainer local HTTPS interface responds."

if [[ "$install_nc" == "y" ]]; then
    for i in $(seq 1 30); do
        if curl -kfsS --max-time 3 https://127.0.0.1:8080/ >/dev/null 2>&1; then
            break
        fi
        if [[ "$i" -eq 30 ]]; then
            log_error "Nextcloud AIO admin interface is not responding on localhost:8080."
            exit 1
        fi
        sleep 2
    done
    log_success "Nextcloud AIO local HTTPS interface responds (web setup still required)."
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

log_step "Finalizing installation"

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
echo "Host firewall    : active, enabled; Docker connectivity passed after reload"
echo "Docker ingress   : only ports in docker_public_tcp_ports / docker_public_udp_ports"
echo "                   Edit those sets in /etc/nftables.conf to allow or close public container ports."
echo "Portainer        : installed"

echo "NextCloud-AIO    : $([[ "$install_nc" =~ ^y$ ]] && echo "installed" || echo "not installed")"

echo "============================================================"

echo

echo "Access:"

echo "Virtualmin/Webmin: https://$hostname:10000"

echo "Portainer        : https://127.0.0.1:9443"

echo "  (bound to localhost - reach it via an SSH tunnel, e.g.:"

echo "   ssh -N -L 9443:127.0.0.1:9443 -L 8080:127.0.0.1:8080 $sudo_user@$hostname)"

if [[ "$install_nc" =~ ^y$ ]]; then

    echo
    echo "NextCloud AIO:"
    echo "AIO setup interface: https://127.0.0.1:8080 (SSH tunnel)"
    echo "Nextcloud: https://$AIO_DOMAIN"
    echo "Nextcloud SSL: $AIO_SSL_STATUS"

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

INSTALL_COMPLETE=1
if [[ "$AIO_SSL_STATUS" == WARNING:* ]]; then
    echo "Installation completed with an SSL warning; required local connectivity tests passed."
    echo "$AIO_SSL_STATUS"
else
    echo "Installation completed successfully; required local connectivity tests passed."
fi
echo "Nextcloud AIO, if selected, still needs to be completed in its admin interface."
