#!/usr/bin/env bash
# cf-owntracks installer (Debian 12)
#
# Installs a daemon that keeps nginx and the firewall in sync with Cloudflare's
# published IP ranges, restricting access to an OwnTracks vhost to CF only.
# Authenticated Origin Pulls (mTLS) enforced by default.
#
# Usage:
#   sudo ./install.sh \
#       --server-name owntracks.example.com \
#       --cert /etc/ssl/cloudflare/origin.pem \
#       --key  /etc/ssl/cloudflare/origin.key
#
# Options:
#   --server-name <host>        Public FQDN (required)
#   --cert <path>               TLS certificate (fullchain) — required
#   --key  <path>               TLS private key — required
#   --owntracks-port <port>     OwnTracks recorder port on 127.0.0.1 (default: 8083)
#   --no-mtls                   Disable Authenticated Origin Pulls enforcement
#   --global-http-redirect      Install a default_server on :80 that 301s all to https
#   --force <backend>           Override firewall detection (nftables|ufw|iptables)
#   --refresh-interval <unit>   Timer cadence: daily (default) | hourly
#   --dry-run                   Render everything, apply nothing
#   --yes                       Skip interactive confirmations (for unattended installs)
#   --uninstall                 Remove daemon + restore snapshots, then exit
#   -h | --help                 Show this help

set -Eeuo pipefail

# ---- Defaults / arg parsing -------------------------------------------------
SERVER_NAME=""
TLS_CERT=""
TLS_KEY=""
OWNTRACKS_PORT="8083"
MTLS_ENABLED=1
GLOBAL_REDIRECT=0
FORCE_BACKEND=""
REFRESH_INTERVAL="daily"
DRY_RUN=0
ASSUME_YES=0
DO_UNINSTALL=0

usage() { sed -n '2,26p' "$0"; }

while (( $# )); do
    case "$1" in
        --server-name)         SERVER_NAME="$2"; shift 2 ;;
        --cert)                TLS_CERT="$2"; shift 2 ;;
        --key)                 TLS_KEY="$2"; shift 2 ;;
        --owntracks-port)      OWNTRACKS_PORT="$2"; shift 2 ;;
        --no-mtls)             MTLS_ENABLED=0; shift ;;
        --global-http-redirect) GLOBAL_REDIRECT=1; shift ;;
        --force)               FORCE_BACKEND="$2"; shift 2 ;;
        --refresh-interval)    REFRESH_INTERVAL="$2"; shift 2 ;;
        --dry-run)             DRY_RUN=1; shift ;;
        --yes|-y)              ASSUME_YES=1; shift ;;
        --uninstall)           DO_UNINSTALL=1; shift ;;
        -h|--help)             usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_root

prompt_yn() {
    local q="$1"
    if (( ASSUME_YES == 1 )); then
        log_info "[--yes] auto-confirming: $q"
        return 0
    fi
    local ans
    read -r -p "$q [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ---- Uninstall path (early exit) --------------------------------------------
do_uninstall() {
    log_info "uninstalling cf-owntracks"

    systemctl disable --now cf-owntracks.timer 2>/dev/null || true
    systemctl disable --now cf-owntracks.service 2>/dev/null || true
    rm -f /etc/systemd/system/cf-owntracks.service /etc/systemd/system/cf-owntracks.timer
    systemctl daemon-reload

    # Remove firewall rules
    if [[ -f "$CFO_CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CFO_CONFIG_FILE"
        case "${CFO_FW_BACKEND:-}" in
            nftables) source "${SCRIPT_DIR}/lib/nftables.sh"; nftables_restore /dev/null ;;
            ufw)      source "${SCRIPT_DIR}/lib/ufw.sh"; ufw_remove_all_tagged ;;
            iptables) source "${SCRIPT_DIR}/lib/iptables.sh"; iptables_restore /dev/null ;;
        esac
    fi

    # Remove nginx artifacts
    rm -f "$CFO_NGINX_VHOST" "$CFO_NGINX_VHOST_ENABLED" \
          "$CFO_NGINX_GLOBAL_REDIRECT" "$CFO_NGINX_GLOBAL_REDIRECT_ENABLED" \
          "$CFO_NGINX_REALIP_SNIPPET" "$CFO_NGINX_ALLOW_SNIPPET" "$CFO_NGINX_MTLS_SNIPPET" \
          /etc/nginx/conf.d/cfo-upgrade-map.conf
    nginx -t >/dev/null 2>&1 && nginx -s reload || log_warn "nginx may need manual attention"

    # Remove daemon files
    rm -f /usr/local/sbin/cf-owntracks-refresh
    rm -rf /usr/local/lib/cf-owntracks /etc/cf-owntracks
    # Keep /var/lib/cf-owntracks and /var/backups/cf-owntracks for forensic purposes

    log_info "uninstall complete. State preserved in $CFO_STATE_DIR and $CFO_BACKUP_DIR"
    log_info "remove those manually if you really want a clean wipe"
}

if (( DO_UNINSTALL == 1 )); then
    do_uninstall
    exit 0
fi

# ---- Pre-flight validation --------------------------------------------------
[[ -n "$SERVER_NAME" ]] || die "--server-name is required"
[[ -n "$TLS_CERT" ]] || die "--cert is required"
[[ -n "$TLS_KEY"  ]] || die "--key is required"
[[ -r "$TLS_CERT" ]] || die "TLS cert not readable: $TLS_CERT"
[[ -r "$TLS_KEY"  ]] || die "TLS key not readable: $TLS_KEY"

# Verify Debian (warn only — daemon may work elsewhere)
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "debian" ]]; then
        log_warn "OS is ${ID:-unknown}; this installer was built for Debian 12 (bookworm)"
    elif [[ "${VERSION_ID:-}" != "12" ]]; then
        log_warn "Debian version is ${VERSION_ID:-?}; this installer was tested on 12 (bookworm)"
    fi
fi

# Required commands
for cmd in curl openssl flock nginx ip sha256sum awk grep sed install systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command missing: $cmd"
done

# Firewall backend detection
if [[ -n "$FORCE_BACKEND" ]]; then
    case "$FORCE_BACKEND" in
        nftables|ufw|iptables) BACKEND="$FORCE_BACKEND" ;;
        *) die "--force must be one of: nftables, ufw, iptables (got: $FORCE_BACKEND)" ;;
    esac
    log_info "using forced backend: $BACKEND"
else
    set +e
    BACKEND="$(detect_firewall)"
    rc=$?
    set -e
    if (( rc != 0 )); then
        die "firewall detection ambiguous; rerun with --force <ufw|nftables|iptables>"
    fi
    if [[ "$BACKEND" == "none" ]]; then
        log_warn "no active firewall detected"
        if prompt_yn "enable nftables (Debian 12 default) and proceed?"; then
            apt-get install -y nftables >/dev/null || die "failed to install nftables"
            systemctl enable --now nftables.service
            BACKEND="nftables"
        else
            die "aborted: cf-owntracks requires an active firewall backend"
        fi
    fi
    log_info "detected firewall backend: $BACKEND"
fi

# Verify the chosen backend has the right binaries
case "$BACKEND" in
    nftables) command -v nft >/dev/null  || die "nft not installed" ;;
    ufw)      command -v ufw >/dev/null  || die "ufw not installed" ;;
    iptables)
        command -v iptables  >/dev/null || die "iptables not installed"
        command -v ip6tables >/dev/null || die "ip6tables not installed"
        command -v iptables-restore  >/dev/null || die "iptables-restore not installed"
        command -v ip6tables-restore >/dev/null || die "ip6tables-restore not installed"
        ;;
esac

# SSH reachability sanity check
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/${BACKEND}.sh"
if ! check_ssh_reachable "$BACKEND"; then
    log_warn "SSH does not appear to be explicitly allowed in the current ${BACKEND} ruleset"
    log_warn "This installer only manages ports 80/443, so SSH should be unaffected."
    log_warn "But if you lose your SSH session, you may have trouble reconnecting."
    prompt_yn "continue anyway?" || die "aborted by user"
fi

# Global redirect safety check
if (( GLOBAL_REDIRECT == 1 )); then
    if grep -RIn --include='*.conf' -E 'listen[[:space:]]+(\[::\]:)?80[[:space:]]+default_server' \
            /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null | grep -v "^${CFO_NGINX_GLOBAL_REDIRECT}:" | grep -q .; then
        die "--global-http-redirect requested but another default_server on :80 is already declared. Resolve that first."
    fi
    # Warn about port-80 vhosts without explicit server_name (they'll be shadowed by our default_server only if they were RELYING on being default).
    if grep -RIln --include='*.conf' -E 'listen[[:space:]]+(\[::\]:)?80[[:space:]]*;' /etc/nginx/sites-enabled 2>/dev/null | while read -r f; do
            awk '/^server[[:space:]]*{/,/^}/' "$f" | grep -q 'server_name' || echo "$f"
       done | grep -q .; then
        log_warn "some :80 server blocks have no server_name; --global-http-redirect may shadow them as the new default"
        prompt_yn "continue?" || die "aborted by user"
    fi
fi

# mTLS prerequisite check
if (( MTLS_ENABLED == 1 )); then
    log_info "Authenticated Origin Pulls (mTLS) will be enforced."
    log_info "BEFORE the installer enables enforcement, you MUST toggle on:"
    log_info "  Cloudflare dashboard -> SSL/TLS -> Origin Server -> Authenticated Origin Pulls"
    log_info "  (zone-level toggle for ${SERVER_NAME%%.*}.* zone)"
    log_info "If this is off, every request will fail with: 400 No required SSL certificate was sent"
    if ! prompt_yn "have you enabled Authenticated Origin Pulls in the Cloudflare dashboard?"; then
        die "aborted: enable AOP in the CF dashboard first, then rerun (or rerun with --no-mtls)"
    fi
fi

if (( DRY_RUN == 1 )); then
    log_info "[--dry-run] passing all pre-flight checks; not applying changes"
fi

# ---- Install files ----------------------------------------------------------
install_files() {
    log_info "installing libraries to /usr/local/lib/cf-owntracks/"
    install -d -m 0755 /usr/local/lib/cf-owntracks
    install -m 0644 "${SCRIPT_DIR}/lib/common.sh"   /usr/local/lib/cf-owntracks/
    install -m 0644 "${SCRIPT_DIR}/lib/nftables.sh" /usr/local/lib/cf-owntracks/
    install -m 0644 "${SCRIPT_DIR}/lib/ufw.sh"      /usr/local/lib/cf-owntracks/
    install -m 0644 "${SCRIPT_DIR}/lib/iptables.sh" /usr/local/lib/cf-owntracks/

    log_info "installing refresh daemon to /usr/local/sbin/cf-owntracks-refresh"
    install -m 0755 "${SCRIPT_DIR}/bin/cf-owntracks-refresh" /usr/local/sbin/cf-owntracks-refresh

    log_info "installing systemd units"
    install -m 0644 "${SCRIPT_DIR}/systemd/cf-owntracks.service" /etc/systemd/system/
    install -m 0644 "${SCRIPT_DIR}/systemd/cf-owntracks.timer"   /etc/systemd/system/
    # Patch timer cadence if requested
    if [[ "$REFRESH_INTERVAL" != "daily" ]]; then
        sed -i "s|^OnCalendar=daily|OnCalendar=${REFRESH_INTERVAL}|" /etc/systemd/system/cf-owntracks.timer
    fi
    systemctl daemon-reload

    log_info "installing nginx WebSocket upgrade map"
    install -m 0644 "${SCRIPT_DIR}/nginx/cfo-upgrade-map.conf" /etc/nginx/conf.d/cfo-upgrade-map.conf

    log_info "creating placeholder snippets (will be overwritten on first refresh)"
    install -d -m 0755 /etc/nginx/snippets
    # These placeholders make the vhost parse even if a future refresh rolls
    # back to a state where snippets don't exist (first-run rollback edge case).
    # Each one is a no-op: comment header + a single safe directive.
    cat > "$CFO_NGINX_REALIP_SNIPPET" <<'EOF'
# cf-owntracks placeholder — overwritten by the daemon on first refresh.
# Until that runs successfully, the vhost has no Cloudflare real-ip handling.
EOF
    cat > "$CFO_NGINX_ALLOW_SNIPPET" <<'EOF'
# cf-owntracks placeholder — overwritten by the daemon on first refresh.
# Fail closed: deny all until real allowlist is populated.
deny all;
EOF
    if (( MTLS_ENABLED == 1 )); then
        # If mTLS is enabled but the CA cert isn't yet on disk, ssl_verify_client
        # would fail to load. Start with `off` and let the refresh enable it.
        cat > "$CFO_NGINX_MTLS_SNIPPET" <<'EOF'
# cf-owntracks placeholder — overwritten by the daemon on first refresh
# once the Cloudflare origin-pull CA is fetched and validated.
ssl_verify_client off;
EOF
    fi

    log_info "rendering OwnTracks vhost"
    local mtls_line=""
    if (( MTLS_ENABLED == 1 )); then
        mtls_line="include /etc/nginx/snippets/cloudflare-mtls.conf;"
    else
        mtls_line="# mTLS disabled at install time (--no-mtls)"
    fi
    sed \
        -e "s|__SERVER_NAME__|${SERVER_NAME}|g" \
        -e "s|__OWNTRACKS_PORT__|${OWNTRACKS_PORT}|g" \
        -e "s|__TLS_CERT__|${TLS_CERT}|g" \
        -e "s|__TLS_KEY__|${TLS_KEY}|g" \
        -e "s|__MTLS_INCLUDE__|${mtls_line}|g" \
        "${SCRIPT_DIR}/nginx/owntracks.conf.template" > "$CFO_NGINX_VHOST"
    chmod 0644 "$CFO_NGINX_VHOST"
    ln -sf "$CFO_NGINX_VHOST" "$CFO_NGINX_VHOST_ENABLED"

    if (( GLOBAL_REDIRECT == 1 )); then
        log_info "installing global :80 -> :443 redirect"
        install -m 0644 "${SCRIPT_DIR}/nginx/global-redirect.conf" "$CFO_NGINX_GLOBAL_REDIRECT"
        ln -sf "$CFO_NGINX_GLOBAL_REDIRECT" "$CFO_NGINX_GLOBAL_REDIRECT_ENABLED"
    fi

    log_info "writing config to $CFO_CONFIG_FILE"
    install -d -m 0755 "$(dirname "$CFO_CONFIG_FILE")"
    cat > "$CFO_CONFIG_FILE" <<EOF
# cf-owntracks daemon config — managed by installer
# Edit + run \`systemctl start cf-owntracks.service\` to apply changes.
CFO_SERVER_NAME="${SERVER_NAME}"
CFO_OWNTRACKS_PORT="${OWNTRACKS_PORT}"
CFO_FW_BACKEND="${BACKEND}"
CFO_TLS_CERT="${TLS_CERT}"
CFO_TLS_KEY="${TLS_KEY}"
CFO_MTLS_ENABLED=${MTLS_ENABLED}
CFO_GLOBAL_REDIRECT=${GLOBAL_REDIRECT}
EOF
    chmod 0640 "$CFO_CONFIG_FILE"

    install -d -m 0755 "$CFO_STATE_DIR" "$CFO_BACKUP_DIR" /etc/ssl/cloudflare
}

# Snapshot the current firewall + nginx state so --uninstall can roll back.
take_install_snapshot() {
    local snap_dir
    snap_dir="${CFO_BACKUP_DIR}/$(date -u +%Y%m%dT%H%M%SZ)"
    install -d -m 0755 "$snap_dir"
    log_info "snapshotting current state to $snap_dir"
    case "$BACKEND" in
        nftables) nft list ruleset > "${snap_dir}/nftables.before" 2>/dev/null || true ;;
        ufw)      ufw status numbered > "${snap_dir}/ufw.before" 2>/dev/null || true ;;
        iptables)
            iptables-save  > "${snap_dir}/iptables.before"  2>/dev/null || true
            ip6tables-save > "${snap_dir}/ip6tables.before" 2>/dev/null || true
            ;;
    esac
    tar czf "${snap_dir}/nginx.before.tar.gz" \
        -C / etc/nginx 2>/dev/null || true
    echo "$snap_dir" > "${CFO_BACKUP_DIR}/.latest"
}

if (( DRY_RUN == 0 )); then
    take_install_snapshot
    install_files
else
    log_info "[--dry-run] skipping file installation and snapshot"
fi

# ---- First-run bootstrap ----------------------------------------------------
if (( DRY_RUN == 0 )); then
    log_info "running initial refresh (synchronous bootstrap)"
    if ! /usr/local/sbin/cf-owntracks-refresh; then
        log_error "initial refresh failed; nginx config and firewall may be in inconsistent state"
        log_error "review logs (journalctl -t cf-owntracks) and consider --uninstall to roll back"
        exit 1
    fi

    log_info "enabling systemd timer"
    systemctl enable --now cf-owntracks.timer

    # Smoke test
    log_info "post-install self-test"
    if ! ss -ltn '( sport = :443 )' 2>/dev/null | grep -q LISTEN; then
        log_warn "nothing is listening on :443 (nginx may have failed to bind)"
    fi
    if (( MTLS_ENABLED == 1 )); then
        log_info "TIP: testing locally with 'curl https://${SERVER_NAME}' will fail with handshake error — that's expected (you're not a CF edge). Test through CF DNS."
    fi
fi

log_info ""
log_info "Done."
log_info "  Refresh manually:    systemctl start cf-owntracks.service"
log_info "  Watch logs:          journalctl -t cf-owntracks -f"
log_info "  Inspect firewall:    $([ "$BACKEND" = nftables ] && echo 'nft list table inet cf_owntracks' || ([ "$BACKEND" = ufw ] && echo 'ufw status numbered | grep cf-owntracks' || echo 'iptables -S CF-OWNTRACKS'))"
log_info "  Inspect allowlist:   cat /etc/nginx/snippets/cloudflare-allow.conf"
log_info "  Uninstall:           sudo $0 --uninstall"
