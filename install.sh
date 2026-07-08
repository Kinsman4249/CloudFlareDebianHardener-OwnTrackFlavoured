#!/usr/bin/env bash
# =============================================================================
# cf-owntracks installer (Debian 12) — v2.2.2
#
# (New to the bash idioms used here? See the guide at the top of
#  lib/common.sh — every trick used below is explained there.)
#
# DEFAULT IS TEST MODE: everything installs and runs live (daemon, timer,
# nginx vhost, firewall rules) but NOTHING ENFORCES. Would-block decisions are
# recorded in an NDJSON log so you can observe before you commit.
# Pass --deploy to enforce.
#
# Settings are remembered: an existing /etc/cf-owntracks/config provides the
# defaults for every prompt and is never clobbered.
#
# Reading order:
#   1. usage + argument parsing
#   2. small prompt helpers
#   3. --uninstall early exit
#   4. load existing config as defaults, detect 1.x installs
#   5. server-name auto-detection (OwnTracks config -> nginx -> reverse DNS)
#   6. interactive prompts
#   7. validation
#   8. diagnostics implementation (also used by --diagnostics)
#   9. cf_auto_cert (automatic Cloudflare origin certificate)
#  10. pre-flight checks (backend detection, SSH info, conflicts)
#  11. --dry-run early exit
#  12. snapshot + install files
#  13. bootstrap refresh + enable timer + diagnostics + summary
# =============================================================================

# Strict mode — see the note at the top of bin/cf-owntracks-refresh.
set -Eeuo pipefail

# Directory this script lives in, so relative paths (lib/, nginx/, systemd/)
# work no matter where the user runs it from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
cf-owntracks installer (v2.2.2)

USAGE
    sudo ./install.sh [options]

MODE
    (default)                 TEST mode: install + observe, enforce nothing.
                              Decision log: /var/log/cf-owntracks/decisions.ndjson
    --deploy                  DEPLOY mode: full enforcement (firewall drops,
                              nginx 403s, mTLS verification).

CORE SETTINGS (prompted interactively when omitted; existing config = defaults)
    --server-name <host>      Public FQDN of the OwnTracks vhost.
                              Auto-detected when omitted, in order: OwnTracks
                              recorder config (/etc/default/ot-recorder),
                              nginx server_name directives, reverse DNS of
                              the public IP.
    --cert <path>             TLS certificate (fullchain)
    --key <path>              TLS private key
    --owntracks-port <port>   Local recorder port (default: 8083)

EXISTING VHOST (recommended when this host already has its own nginx config)
    --attach-vhost <file>     Layer protection into an EXISTING vhost instead
                              of generating a standalone one: injects the
                              three cf-owntracks include lines into each
                              server block of <file> (marker-delimited,
                              idempotent, reverted on --uninstall). Your auth,
                              locations, and routing stay untouched. The path
                              persists in config — future runs reuse it and
                              never create a competing vhost.
    --force-own-vhost         Generate our own vhost even though another vhost
                              already claims the server name (NOT recommended:
                              nginx ignores duplicate server names, which
                              silently disables one of the two)

AUTOMATIC ORIGIN CERTIFICATE (Cloudflare Origin CA)
    --cf-auto-cert            Provision a 15-year origin certificate for the
                              server name via the Cloudflare API instead of
                              supplying --cert/--key. Reuses a still-valid
                              existing cert. Credentials via environment
                              (preferred: invisible to `ps`):
                                  CF_ORIGIN_CA_KEY   Origin CA key ("v1.0-...")
                                  CF_API_TOKEN       API token with
                                                     Zone > SSL and Certificates > Edit
    --cf-origin-ca-key <k>    Origin CA key on the command line
    --cf-api-token <t>        API token on the command line

ACCESS CONTROL
    --allow <ip-or-cidr>      Always-allow this source on the managed ports
                              (repeatable; persisted to /etc/cf-owntracks/allowlist)
    --no-mtls                 Disable Authenticated Origin Pulls
    --no-asn-failsafe         Disable the Cloudflare ASN prefix failsafe
    --asns "<a> <b>"          Cloudflare ASNs for the failsafe (default: 13335)

PORTS
    Managed ports are discovered from the managed nginx vhosts' listen
    directives on every refresh. SSH ports are ALWAYS excluded.
    --manage-port <port>      Also manage this nginx port (repeatable, opt-in)

MISC
    --global-http-redirect    Install a default_server on :80 redirecting all
                              unmatched hosts to https (default: off)
    --refresh-interval <v>    6h (default) | 3h | 12h | daily | hourly
    --test-log-max-mb <n>     Decision log cap in MB (default: 15)
    --force <backend>         Override firewall detection (nftables|ufw|iptables)
    --yes                     Non-interactive; accept defaults, skip prompts
    --dry-run                 Render everything to ./cf-owntracks-rendered/, change nothing
    --diagnostics             Run the post-install diagnostics against the
                              current installation and exit
    --uninstall               Remove the daemon and managed rules, then exit
    -h | --help               This help
EOF
}

# ---- Argument parsing ----------------------------------------------------------
# Every flag lands in an ARG_* variable (empty string = "not given"), so that
# later we can layer: flag > existing config > built-in default.
ARG_SERVER_NAME=""; ARG_CERT=""; ARG_KEY=""; ARG_PORT=""
ARG_MODE=""; ARG_MTLS=""; ARG_REDIRECT=""; ARG_ASN_FAILSAFE=""; ARG_ASNS=""
ARG_INTERVAL=""; ARG_LOG_MAX=""; ARG_FORCE=""
declare -a ARG_ALLOW=() ARG_MANAGE_PORTS=()       # repeatable flags -> arrays
ASSUME_YES=0; DRY_RUN=0; DO_UNINSTALL=0; DO_DIAGNOSTICS=0
AUTO_CERT=0
ARG_ATTACH_VHOST=""; FORCE_OWN_VHOST=0
# Environment credentials are honored as-is; flags below can override them.
CF_ORIGIN_CA_KEY="${CF_ORIGIN_CA_KEY:-}"
CF_API_TOKEN="${CF_API_TOKEN:-}"

# Classic manual argument loop: look at $1, consume it (and its value, when it
# has one) with `shift`/`shift 2`, repeat until nothing is left.
while (( $# )); do
    case "$1" in
        --server-name)          ARG_SERVER_NAME="$2"; shift 2 ;;
        --cert)                 ARG_CERT="$2"; shift 2 ;;
        --key)                  ARG_KEY="$2"; shift 2 ;;
        --cf-auto-cert)         AUTO_CERT=1; shift ;;
        --cf-origin-ca-key)     CF_ORIGIN_CA_KEY="$2"; AUTO_CERT=1; shift 2 ;;
        --cf-api-token)         CF_API_TOKEN="$2"; AUTO_CERT=1; shift 2 ;;
        --owntracks-port)       ARG_PORT="$2"; shift 2 ;;
        --attach-vhost)         ARG_ATTACH_VHOST="$2"; shift 2 ;;
        --force-own-vhost)      FORCE_OWN_VHOST=1; shift ;;
        --deploy)               ARG_MODE="deploy"; shift ;;
        --test)                 ARG_MODE="test"; shift ;;
        --allow)                ARG_ALLOW+=("$2"); shift 2 ;;
        --manage-port)          ARG_MANAGE_PORTS+=("$2"); shift 2 ;;
        --no-mtls)              ARG_MTLS=0; shift ;;
        --mtls)                 ARG_MTLS=1; shift ;;
        --no-asn-failsafe)      ARG_ASN_FAILSAFE=0; shift ;;
        --asn-failsafe)         ARG_ASN_FAILSAFE=1; shift ;;
        --asns)                 ARG_ASNS="$2"; shift 2 ;;
        --global-http-redirect) ARG_REDIRECT=1; shift ;;
        --refresh-interval)     ARG_INTERVAL="$2"; shift 2 ;;
        --test-log-max-mb)      ARG_LOG_MAX="$2"; shift 2 ;;
        --force)                ARG_FORCE="$2"; shift 2 ;;
        --yes|-y)               ASSUME_YES=1; shift ;;
        --dry-run)              DRY_RUN=1; shift ;;
        --diagnostics)          DO_DIAGNOSTICS=1; shift ;;
        --uninstall)            DO_UNINSTALL=1; shift ;;
        -h|--help)              usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

require_root

# Interactive = we may ask questions. Not interactive when --yes was given OR
# when stdin isn't a terminal ([[ -t 0 ]] tests exactly that), e.g. when the
# installer is run from a pipeline or automation.
INTERACTIVE=1
if (( ASSUME_YES == 1 )) || [[ ! -t 0 ]]; then
    INTERACTIVE=0
fi

# ---- Small prompt helpers --------------------------------------------------------
# All prompts read from /dev/tty (the terminal directly) instead of stdin, so
# they still work even if stdin is occupied.

prompt_val() {
    # prompt_val <question> <default> — echoes chosen value.
    # Non-interactive mode short-circuits to the default.
    local q="$1" def="$2" v
    if (( INTERACTIVE == 0 )); then
        printf '%s\n' "$def"
        return 0
    fi
    read -r -p "  ${q} [${def:-none}]: " v </dev/tty
    printf '%s\n' "${v:-$def}"          # empty answer = accept the default
}

prompt_bool() {
    # prompt_bool <question> <default-1-or-0> — echoes 1 or 0.
    local q="$1" def="$2" defstr v
    if (( INTERACTIVE == 0 )); then
        printf '%s\n' "$def"
        return 0
    fi
    # Show which answer Enter will pick: capital letter = the default.
    [[ "$def" == "1" ]] && defstr="Y/n" || defstr="y/N"
    read -r -p "  ${q} [${defstr}]: " v </dev/tty
    case "${v,,}" in
        y|yes) echo 1 ;;
        n|no)  echo 0 ;;
        "")    echo "$def" ;;
        *)     echo "$def" ;;
    esac
}

prompt_yn() {
    # Yes/no CONFIRMATION (as opposed to a value prompt): returns success for
    # yes, failure for no, and auto-confirms under --yes.
    local q="$1"
    if (( ASSUME_YES == 1 )); then
        log_info "[--yes] auto-confirming: $q"
        return 0
    fi
    local ans
    read -r -p "$q [y/N] " ans </dev/tty
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ---- Uninstall -------------------------------------------------------------------
do_uninstall() {
    log_info "uninstalling cf-owntracks"

    # Stop and remove the systemd units first so nothing re-fires mid-removal.
    systemctl disable --now cf-owntracks.timer 2>/dev/null || true
    systemctl stop cf-owntracks-retry.timer 2>/dev/null || true
    systemctl disable --now cf-owntracks.service 2>/dev/null || true
    rm -f /etc/systemd/system/cf-owntracks.service \
          /etc/systemd/system/cf-owntracks.timer \
          /etc/systemd/system/cf-owntracks-retry.timer
    systemctl daemon-reload

    # Remove our firewall rules using whichever backend the config recorded.
    if [[ -f "$CFO_CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CFO_CONFIG_FILE"
        case "${CFO_FW_BACKEND:-}" in
            nftables) source "${SCRIPT_DIR}/lib/nftables.sh"; nftables_restore /dev/null ;;
            ufw)      source "${SCRIPT_DIR}/lib/ufw.sh"; ufw_remove_all_tagged ;;
            iptables) source "${SCRIPT_DIR}/lib/iptables.sh"; iptables_restore /dev/null ;;
        esac
    fi
    rm -f /etc/nftables.d/cf-owntracks.conf 2>/dev/null || true

    # Attach mode: pull our include lines back out of the operator's vhost
    # (their file, their app — only our marker-delimited stanza goes).
    if [[ -n "${CFO_ATTACH_VHOST:-}" ]]; then
        detach_vhost_includes "$CFO_ATTACH_VHOST"
    fi

    # Remove every nginx piece we own, then reload if the config still parses.
    rm -f "$CFO_NGINX_VHOST" "$CFO_NGINX_VHOST_ENABLED" \
          "$CFO_NGINX_GLOBAL_REDIRECT" "$CFO_NGINX_GLOBAL_REDIRECT_ENABLED" \
          "$CFO_NGINX_MAPS_CONF" "$CFO_NGINX_REALIP_SNIPPET" \
          "$CFO_NGINX_ENFORCE_SNIPPET" "$CFO_NGINX_MTLS_SNIPPET" \
          "$CFO_NGINX_LEGACY_ALLOW_SNIPPET" \
          /etc/nginx/conf.d/cfo-upgrade-map.conf
    nginx -t >/dev/null 2>&1 && nginx -s reload || log_warn "nginx may need manual attention"

    # Remove the program itself + its config.
    rm -f /usr/local/sbin/cf-owntracks-refresh
    rm -rf /usr/local/lib/cf-owntracks /usr/local/share/cf-owntracks /etc/cf-owntracks

    log_info "uninstall complete."
    log_info "preserved for forensics: $CFO_STATE_DIR, $CFO_BACKUP_DIR, $CFO_LOG_DIR"
}

if (( DO_UNINSTALL == 1 )); then
    do_uninstall
    exit 0
fi

# ---- Load existing config as defaults + detect 1.x --------------------------------
# A prior install's config becomes the default for everything — this is what
# "settings are never clobbered" means in practice. A config WITHOUT the
# CFO_MODE key can only have been written by 1.x.
UPGRADE_FROM_V1=0
HAVE_EXISTING_CONFIG=0
if [[ -f "$CFO_CONFIG_FILE" ]]; then
    HAVE_EXISTING_CONFIG=1
    if ! grep -q '^CFO_MODE=' "$CFO_CONFIG_FILE"; then
        UPGRADE_FROM_V1=1
    fi
    # shellcheck disable=SC1090
    source "$CFO_CONFIG_FILE"
    log_info "existing configuration found — previous settings become defaults"
fi

# Merge precedence, one variable at a time: flag > existing config > builtin.
# "${A:-${B:-c}}" reads as: use A if set, else B if set, else the literal c.
SERVER_NAME="${ARG_SERVER_NAME:-${CFO_SERVER_NAME:-}}"
TLS_CERT="${ARG_CERT:-${CFO_TLS_CERT:-}}"
TLS_KEY="${ARG_KEY:-${CFO_TLS_KEY:-}}"
OWNTRACKS_PORT="${ARG_PORT:-${CFO_OWNTRACKS_PORT:-8083}}"
MODE="${ARG_MODE:-test}"   # NOTE: mode is NOT inherited — default is always test
MTLS_ENABLED="${ARG_MTLS:-${CFO_MTLS_ENABLED:-1}}"
GLOBAL_REDIRECT="${ARG_REDIRECT:-${CFO_GLOBAL_REDIRECT:-0}}"
ASN_FAILSAFE="${ARG_ASN_FAILSAFE:-${CFO_ASN_FAILSAFE:-1}}"
CF_ASNS="${ARG_ASNS:-${CFO_CF_ASNS:-13335}}"
TEST_LOG_MAX_MB="${ARG_LOG_MAX:-${CFO_TEST_LOG_MAX_MB:-15}}"
REFRESH_INTERVAL="${ARG_INTERVAL:-6h}"
ATTACH_VHOST="${ARG_ATTACH_VHOST:-${CFO_ATTACH_VHOST:-}}"
EXTRA_PORTS="${CFO_EXTRA_PORTS:-}"
if (( ${#ARG_MANAGE_PORTS[@]} > 0 )); then
    # Merge config extras with --manage-port flags: numbers only, dedupe,
    # back to one space-separated line. ($EXTRA_PORTS is deliberately
    # unquoted so its ports split into separate printf arguments.)
    EXTRA_PORTS="$(printf '%s\n' $EXTRA_PORTS "${ARG_MANAGE_PORTS[@]}" | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ')"
    EXTRA_PORTS="${EXTRA_PORTS% }"
fi

# ---- Server-name auto-detection (when not provided by flag or prior config) --------
# Chain: OwnTracks recorder config -> nginx server_name directives -> reverse
# DNS of the public IP. The recorder's own config is checked first — it knows
# the public URL it serves under, which beats inferring from nginx.
# Whatever is found only becomes the PROMPT DEFAULT; nothing is applied
# silently.
if [[ -z "$SERVER_NAME" ]] && (( DO_UNINSTALL == 0 )) && (( DO_DIAGNOSTICS == 0 )); then
    OT_TMP="$(mktemp)"
    discover_owntracks_hostname > "$OT_TMP" 2>/dev/null || true
    OT_COUNT=$(grep -c . "$OT_TMP" || true)
    if (( OT_COUNT >= 1 )); then
        SERVER_NAME="$(head -1 "$OT_TMP")"
        if (( OT_COUNT > 1 )); then
            log_info "OwnTracks recorder config mentions ${OT_COUNT} hostnames:"
            sed 's/^/          /' "$OT_TMP" >&2
            log_info "auto-selected: ${SERVER_NAME} (change at the prompt or with --server-name)"
        else
            log_info "auto-detected server name from OwnTracks recorder config: ${SERVER_NAME}"
        fi
    fi
    rm -f "$OT_TMP"
fi
if [[ -z "$SERVER_NAME" ]] && (( DO_UNINSTALL == 0 )) && (( DO_DIAGNOSTICS == 0 )); then
    HN_TMP="$(mktemp)"
    discover_nginx_hostnames > "$HN_TMP" 2>/dev/null || true
    HN_COUNT=$(grep -c . "$HN_TMP" || true)
    if (( HN_COUNT >= 1 )); then
        SERVER_NAME="$(head -1 "$HN_TMP")"
        if (( HN_COUNT > 1 )); then
            log_info "nginx serves ${HN_COUNT} hostnames:"
            sed 's/^/          /' "$HN_TMP" >&2
            log_info "auto-selected: ${SERVER_NAME} (change at the prompt or with --server-name)"
        else
            log_info "auto-detected server name from nginx: ${SERVER_NAME}"
        fi
    else
        # Last resort: ask the internet what our public IP is, then look up
        # its PTR (reverse DNS) record.
        PUB_IP="$(detect_public_ip || true)"
        if [[ -n "$PUB_IP" ]]; then
            PTR_NAME="$(reverse_dns "$PUB_IP" || true)"
            if [[ -n "$PTR_NAME" ]]; then
                SERVER_NAME="$PTR_NAME"
                log_info "auto-detected server name via reverse DNS: ${SERVER_NAME} (public IP ${PUB_IP})"
                log_warn "PTR names are often generic (ISP/host default) — confirm this is the hostname Cloudflare fronts"
            else
                log_warn "no nginx server_name found and no PTR record for ${PUB_IP} — provide --server-name or answer the prompt"
            fi
        else
            log_warn "no nginx server_name found and public IP undetectable — provide --server-name or answer the prompt"
        fi
    fi
    rm -f "$HN_TMP"
fi

# The 1.x upgrade notice — loud on purpose, because upgrading FLIPS an
# enforcing system back to observe-only until --deploy is run again.
if (( UPGRADE_FROM_V1 == 1 )); then
    echo
    echo "=============================================================================="
    echo "  1.x INSTALLATION DETECTED"
    echo "------------------------------------------------------------------------------"
    if [[ "$MODE" == "deploy" ]]; then
        echo "  --deploy given: enforcement will remain ACTIVE after this upgrade."
    else
        echo "  v2 defaults to TEST mode. This system is being SWITCHED BACK TO TEST"
        echo "  MODE: enforcement will be turned OFF and traffic will only be observed."
        echo
        echo "  Your 1.x settings (server name, cert paths, port, mTLS choice) are"
        echo "  preserved. To restore enforcement after reviewing the decision log:"
        echo
        echo "      sudo $0 --deploy --yes"
    fi
    echo "=============================================================================="
    echo
fi

# ---- Interactive configuration -----------------------------------------------------
if (( DO_DIAGNOSTICS == 0 )); then
    echo "cf-owntracks v${CFO_VERSION} installer — mode: ${MODE^^}"   # ^^ = UPPERCASE
    if [[ "$MODE" == "test" ]]; then
        echo "  (TEST mode: observe only, nothing enforces. Use --deploy to enforce.)"
    fi
    echo
    if (( INTERACTIVE == 1 )); then
        echo "Configuration (Enter accepts the [default]):"
        SERVER_NAME="$(prompt_val "Public FQDN for OwnTracks" "$SERVER_NAME")"
        # Offer automatic origin-cert provisioning when no usable cert is configured.
        if (( AUTO_CERT == 0 )) && { [[ -z "$TLS_CERT" ]] || [[ ! -r "$TLS_CERT" ]]; }; then
            if [[ "$(prompt_bool "Fetch an origin certificate from Cloudflare automatically?" 1)" == "1" ]]; then
                AUTO_CERT=1
            fi
        fi
        if (( AUTO_CERT == 1 )); then
            if [[ -z "$CF_ORIGIN_CA_KEY" && -z "$CF_API_TOKEN" ]]; then
                # read -s = silent (no echo to the screen) — it's a secret.
                read -rs -p "  Cloudflare Origin CA key (v1.0-...) or API token [input hidden]: " _cfsecret </dev/tty
                echo
                # Origin CA keys always start with "v1.0-"; use that to pick
                # the right auth header later.
                if [[ "$_cfsecret" == v1.0-* ]]; then
                    CF_ORIGIN_CA_KEY="$_cfsecret"
                else
                    CF_API_TOKEN="$_cfsecret"
                fi
                unset _cfsecret
            fi
        else
            TLS_CERT="$(prompt_val "TLS certificate path (fullchain)" "$TLS_CERT")"
            TLS_KEY="$(prompt_val "TLS private key path" "$TLS_KEY")"
        fi
        OWNTRACKS_PORT="$(prompt_val "OwnTracks recorder port (127.0.0.1)" "$OWNTRACKS_PORT")"
        MTLS_ENABLED="$(prompt_bool "Enforce Authenticated Origin Pulls (mTLS)?" "$MTLS_ENABLED")"
        GLOBAL_REDIRECT="$(prompt_bool "Global 80->443 redirect for ALL sites?" "$GLOBAL_REDIRECT")"
        ASN_FAILSAFE="$(prompt_bool "Enable Cloudflare ASN prefix failsafe?" "$ASN_FAILSAFE")"
        REFRESH_INTERVAL="$(prompt_val "Refresh interval (6h/3h/12h/daily/hourly)" "$REFRESH_INTERVAL")"
        TEST_LOG_MAX_MB="$(prompt_val "Decision log cap in MB (test mode)" "$TEST_LOG_MAX_MB")"
        extra_allow="$(prompt_val "Extra always-allow IPs/CIDRs (space-separated, empty for none)" "")"
        if [[ -n "$extra_allow" ]]; then
            # Split the answer on spaces into an array, append to --allow list.
            read -r -a extra_arr <<<"$extra_allow"
            ARG_ALLOW+=("${extra_arr[@]}")
        fi
        echo
    fi
fi

# ---- Validation ---------------------------------------------------------------------
[[ "$OWNTRACKS_PORT" =~ ^[0-9]+$ ]] || die "recorder port must be numeric: $OWNTRACKS_PORT"
[[ "$TEST_LOG_MAX_MB" =~ ^[0-9]+$ ]] || die "log cap must be numeric MB: $TEST_LOG_MAX_MB"
case "$REFRESH_INTERVAL" in
    6h|3h|12h|daily|hourly) : ;;
    *) die "unsupported --refresh-interval: $REFRESH_INTERVAL (use 6h/3h/12h/daily/hourly)" ;;
esac
# Every --allow entry must be a valid address/CIDR of one family or the other.
for a in "${ARG_ALLOW[@]}"; do
    n="$(normalize_cidr "$a")"
    if [[ "$n" == *:* ]]; then
        is_valid_cidr_v6 "$n" || die "invalid --allow entry: $a"
    else
        is_valid_cidr_v4 "$n" || die "invalid --allow entry: $a"
    fi
done

# ---- Diagnostics implementation ------------------------------------------------------
# PASS/WARN/FAIL counters + printers used by run_diagnostics below.
DIAG_PASS=0; DIAG_WARN=0; DIAG_FAIL=0
d_pass() { printf '  PASS  %s\n' "$1"; DIAG_PASS=$((DIAG_PASS+1)); }
d_warn() { printf '  WARN  %s\n' "$1"; DIAG_WARN=$((DIAG_WARN+1)); }
d_fail() { printf '  FAIL  %s\n' "$1"; DIAG_FAIL=$((DIAG_FAIL+1)); }

# One HTTP reachability probe: PASS on any 2xx answer.
# curl -w '%{http_code} %{time_total}s' appends "200 0.13s"-style stats.
diag_endpoint() {
    local label="$1" url="$2" code t
    t="$(mktemp)"
    code=$(curl -sS -o /dev/null -w '%{http_code} %{time_total}s' --max-time 15 "$url" 2>"$t" || echo "000 -")
    if [[ "$code" == 2* ]]; then
        d_pass "endpoint ${label}: HTTP ${code}"
    else
        d_fail "endpoint ${label}: ${code} $(head -c 80 "$t" 2>/dev/null || true)"
    fi
    rm -f "$t"
}

run_diagnostics() {
    echo
    echo "== DIAGNOSTICS ==============================================================="
    # Re-read the installed config so --diagnostics reflects reality, not the
    # variables of the current installer invocation.
    if [[ -f "$CFO_CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CFO_CONFIG_FILE"
    fi
    local mode="${CFO_MODE:-$MODE}"
    if [[ "$mode" == "deploy" ]]; then
        echo "  MODE: DEPLOY — ENFORCEMENT ACTIVE"
    else
        echo "  MODE: TEST — ENFORCEMENT OFF (observe only)"
    fi

    # 1. Can we reach every API this tool depends on?
    diag_endpoint "cloudflare.com/ips-v4" "$CFO_IPS_V4_URL"
    diag_endpoint "cloudflare.com/ips-v6" "$CFO_IPS_V6_URL"
    if [[ "${CFO_MTLS_ENABLED:-1}" == "1" ]]; then
        diag_endpoint "origin-pull CA" "$CFO_AOP_CA_URL"
    fi
    if [[ "${CFO_ASN_FAILSAFE:-1}" == "1" ]]; then
        local first_asn
        first_asn="$(echo "${CFO_CF_ASNS:-13335}" | tr ' ' '\n' | head -1)"
        diag_endpoint "RIPEstat AS${first_asn}" "${CFO_RIPESTAT_URL}${first_asn}"
    fi

    # 2. journald round-trip: write a unique token, read it back.
    local token
    token="cfo-diag-$$-$(date +%s)"
    logger -t cf-owntracks -- "$token" 2>/dev/null || true
    sleep 1
    if command -v journalctl >/dev/null 2>&1; then
        if journalctl -t cf-owntracks --since "2 minutes ago" 2>/dev/null | grep -qF "$token"; then
            d_pass "journald write + read back"
        else
            d_warn "journald: test token not found (log access may be restricted)"
        fi
    else
        d_warn "journalctl not available"
    fi

    # 3. Does the whole nginx config parse? Capture the output too: nginx
    # emits WARNINGS here (e.g. "conflicting server name") that mean another
    # vhost is shadowing ours — the #1 reason the decision log stays empty.
    local ngx_out
    if ngx_out="$(nginx -t 2>&1)"; then
        d_pass "nginx -t"
    else
        d_fail "nginx -t: $(printf '%s' "$ngx_out" | tail -2 | tr '\n' ' ')"
    fi
    if grep -q 'conflicting server name' <<<"$ngx_out"; then
        d_fail "nginx: CONFLICTING SERVER NAME — another vhost claims the same host:port, so the cf-owntracks vhost is IGNORED (no decision log, no enforcement at nginx level). Find it: grep -RIl '${CFO_SERVER_NAME:-<your-server-name>}' /etc/nginx/sites-enabled/ — then rerun the installer with --attach-vhost <that-file>."
    fi

    # Attach mode: our protection lives inside the operator's vhost — verify
    # the marker-delimited includes are actually present.
    if [[ -n "${CFO_ATTACH_VHOST:-}" ]]; then
        if grep -qF 'cf-owntracks includes (managed)' "$CFO_ATTACH_VHOST" 2>/dev/null; then
            d_pass "attach mode: includes present in ${CFO_ATTACH_VHOST}"
        else
            d_fail "attach mode: includes MISSING from ${CFO_ATTACH_VHOST} — rerun the installer"
        fi
    fi

    # 4. Ports: managed / ssh / other — and the SSH-exclusion proof.
    local ssh_ports managed other p
    ssh_ports="$(detect_ssh_ports | tr '\n' ' ')"
    if [[ -s "$CFO_PORTS_FILE" ]]; then
        managed="$(tr '\n' ' ' < "$CFO_PORTS_FILE")"
    else
        managed="$(discover_managed_ports)"
    fi
    echo "  ----------------------------------------------------------------------------"
    echo "  managed ports:      ${managed% }"
    echo "  ssh ports excluded: ${ssh_ports% }"
    other="$(discover_all_nginx_ports 2>/dev/null | tr '\n' ' ' || true)"
    echo "  all nginx ports:    ${other% } (non-managed ones are untouched; opt in via --manage-port)"
    local clash=0
    for p in ${managed}; do
        # grep -qw = match the port as a whole word inside the SSH list.
        if grep -qw "$p" <<<"$ssh_ports"; then clash=1; fi
    done
    if (( clash == 0 )); then
        d_pass "SSH GUARD: no managed port overlaps an SSH port"
    else
        d_fail "SSH GUARD: managed set overlaps an SSH port — this should be impossible; do not deploy"
    fi

    # Is something actually listening on each managed port?
    for p in ${managed}; do
        if ss -ltn "( sport = :${p} )" 2>/dev/null | grep -q LISTEN; then
            d_pass "listener on :${p}"
        else
            d_warn "nothing listening on :${p}"
        fi
    done

    # 5. Firewall state per backend.
    case "${CFO_FW_BACKEND:-unknown}" in
        nftables)
            if nft list table inet cf_owntracks >/dev/null 2>&1; then
                local el
                el=$(nft list table inet cf_owntracks 2>/dev/null | grep -cE '^\s+(ip|ip6) saddr' || true)
                d_pass "nftables table inet cf_owntracks present (${el} match rules)"
            else
                d_fail "nftables table inet cf_owntracks missing"
            fi
            ;;
        ufw)
            local c
            c=$(ufw status numbered 2>/dev/null | grep -cF 'cf-owntracks' || true)
            if (( c > 0 )); then d_pass "ufw carries ${c} cf-owntracks rules"; else d_fail "no tagged ufw rules"; fi
            ;;
        iptables)
            if iptables -S CF-OWNTRACKS >/dev/null 2>&1 && ip6tables -S CF-OWNTRACKS6 >/dev/null 2>&1; then
                d_pass "iptables chains CF-OWNTRACKS / CF-OWNTRACKS6 present"
            else
                d_fail "iptables chains missing"
            fi
            ;;
        *) d_warn "firewall backend unknown (config missing?)" ;;
    esac

    # 6. State + logs: directories writable, caches populated, log sane.
    [[ -w "$CFO_STATE_DIR" ]] && d_pass "state dir writable ($CFO_STATE_DIR)" || d_fail "state dir not writable"
    if [[ "$mode" == "test" ]]; then
        if [[ -d "$CFO_LOG_DIR" && -w "$CFO_LOG_DIR" ]]; then
            d_pass "decision log dir writable ($CFO_LOG_DIR)"
        else
            d_fail "decision log dir missing/not writable ($CFO_LOG_DIR)"
        fi
        if [[ -s "$CFO_DECISION_LOG" ]]; then
            d_pass "decision log has entries — sample: $(tail -1 "$CFO_DECISION_LOG" | head -c 160)"
        else
            d_warn "decision log empty (no traffic seen yet) — $CFO_DECISION_LOG"
        fi
    fi
    [[ -s "$CFO_IPS_V4_FILE" ]] && d_pass "published v4 cache: $(grep -c . "$CFO_IPS_V4_FILE") ranges" || d_warn "no v4 cache yet"
    [[ -s "$CFO_IPS_V6_FILE" ]] && d_pass "published v6 cache: $(grep -c . "$CFO_IPS_V6_FILE") ranges" || d_warn "no v6 cache yet"
    if [[ "${CFO_ASN_FAILSAFE:-1}" == "1" ]]; then
        local a4 a6
        a4=$(grep -c . "$CFO_ASN_V4_FILE" 2>/dev/null || echo 0)
        a6=$(grep -c . "$CFO_ASN_V6_FILE" 2>/dev/null || echo 0)
        d_pass "ASN failsafe cache: ${a4} novel v4 + ${a6} novel v6 prefixes"
    fi

    # 7. Is the refresh timer alive, and when does it fire next?
    if systemctl is-active cf-owntracks.timer >/dev/null 2>&1; then
        d_pass "refresh timer active ($(systemctl show cf-owntracks.timer -p NextElapseUSecRealtime --value 2>/dev/null | head -1))"
    else
        d_fail "refresh timer not active"
    fi

    echo "  ----------------------------------------------------------------------------"
    printf '  %d PASS / %d WARN / %d FAIL\n' "$DIAG_PASS" "$DIAG_WARN" "$DIAG_FAIL"
    echo "=============================================================================="
    (( DIAG_FAIL == 0 ))
}

if (( DO_DIAGNOSTICS == 1 )); then
    [[ -f "$CFO_CONFIG_FILE" ]] || die "no installation found ($CFO_CONFIG_FILE missing)"
    run_diagnostics
    exit $?
fi

# ---- Automatic origin certificate (Cloudflare Origin CA) --------------------------------
# Provisions a 15-year origin cert for $SERVER_NAME via the Cloudflare API.
# Reuses the existing cert when it still covers the hostname with >30 days left.
cf_auto_cert() {
    local cert_out="/etc/ssl/cloudflare/origin.pem"
    local key_out="/etc/ssl/cloudflare/origin.key"

    # Reuse check: cert + key exist, cert is valid for at least another 30
    # days (-checkend takes SECONDS: 2592000 = 30*24*3600), and its SAN list
    # includes our hostname. If all true — done, nothing to issue.
    if [[ -s "$cert_out" && -s "$key_out" ]] && \
       openssl x509 -in "$cert_out" -noout -checkend 2592000 >/dev/null 2>&1 && \
       openssl x509 -in "$cert_out" -noout -text 2>/dev/null | grep -qF "DNS:${SERVER_NAME}"; then
        log_info "cf-auto-cert: existing origin cert covers ${SERVER_NAME} and is valid — reusing"
        TLS_CERT="$cert_out"
        TLS_KEY="$key_out"
        return 0
    fi

    if [[ -z "$CF_ORIGIN_CA_KEY" && -z "$CF_API_TOKEN" ]]; then
        die "cf-auto-cert: no credentials. Set CF_ORIGIN_CA_KEY (dashboard: My Profile -> API Tokens -> API Keys -> Origin CA Key) or CF_API_TOKEN (custom token: Zone > SSL and Certificates > Edit, scoped to this zone), or pass --cf-origin-ca-key / --cf-api-token"
    fi

    log_info "cf-auto-cert: requesting a 15-year origin certificate for ${SERVER_NAME}"
    local work
    work="$(mktemp -d)"

    # Generate the private key + CSR locally — the key never leaves this box.
    # umask 077 makes the key file unreadable to anyone but root the moment
    # it is created; the ( ) subshell keeps that umask from leaking out.
    if ! ( umask 077; openssl req -new -newkey rsa:2048 -nodes \
            -keyout "${work}/origin.key" \
            -subj "/CN=${SERVER_NAME}" \
            -out "${work}/origin.csr" >/dev/null 2>&1 ); then
        rm -rf "$work"
        die "cf-auto-cert: CSR generation failed"
    fi

    # JSON strings cannot contain real newlines, so convert the PEM's line
    # breaks into the two characters "\n" (awk's ORS = output record separator).
    local csr_esc
    csr_esc="$(awk 'BEGIN{ORS="\\n"} {print}' "${work}/origin.csr")"

    # requested_validity is in DAYS: 5475 = 15 years (Cloudflare's maximum).
    printf '{"hostnames":["%s"],"requested_validity":5475,"request_type":"origin-rsa","csr":"%s"}' \
        "$SERVER_NAME" "$csr_esc" > "${work}/payload.json"

    # The credential goes into a curl CONFIG FILE (-K) rather than a -H
    # argument, so it never appears in `ps` output where other users could
    # read it. Origin CA keys and API tokens use different auth headers.
    if [[ -n "$CF_ORIGIN_CA_KEY" ]]; then
        printf 'header = "X-Auth-User-Service-Key: %s"\n' "$CF_ORIGIN_CA_KEY" > "${work}/auth.cfg"
    else
        printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" > "${work}/auth.cfg"
    fi
    chmod 600 "${work}/auth.cfg"

    local resp
    if ! resp="$(curl -sS --max-time 30 -K "${work}/auth.cfg" \
            -H 'Content-Type: application/json' \
            --data @"${work}/payload.json" \
            https://api.cloudflare.com/client/v4/certificates 2>&1)"; then
        rm -rf "$work"
        die "cf-auto-cert: API request failed: ${resp:0:200}"
    fi

    # Cloudflare's JSON always carries "success":true/false; on failure, pull
    # the first human-readable "message" out for the error.
    if ! grep -q '"success":[[:space:]]*true' <<<"$resp"; then
        local apierr
        apierr="$(grep -o '"message":"[^"]*"' <<<"$resp" | head -1 | sed 's/^"message":"//;s/"$//')"
        rm -rf "$work"
        die "cf-auto-cert: Cloudflare API error: ${apierr:-unrecognized response (check credential type/permissions)}"
    fi

    # Extract the "certificate" JSON string and turn its "\n" escapes back
    # into real newlines to reconstruct the PEM.
    grep -o '"certificate":"[^"]*"' <<<"$resp" | head -1 \
        | sed 's/^"certificate":"//;s/"$//' \
        | sed 's/\\n/\n/g' > "${work}/origin.pem"

    if ! openssl x509 -in "${work}/origin.pem" -noout >/dev/null 2>&1; then
        rm -rf "$work"
        die "cf-auto-cert: API returned an unparseable certificate"
    fi

    # Move into place: key readable by root only (0600), cert world-readable.
    install -d -m 0755 /etc/ssl/cloudflare
    install -m 0600 "${work}/origin.key" "$key_out"
    install -m 0644 "${work}/origin.pem" "$cert_out"
    rm -rf "$work"

    TLS_CERT="$cert_out"
    TLS_KEY="$key_out"
    log_info "cf-auto-cert: installed ${cert_out} — expires $(openssl x509 -in "$cert_out" -noout -enddate 2>/dev/null | cut -d= -f2)"
    log_info "cf-auto-cert: note — Origin CA certs are only trusted by Cloudflare, not by browsers connecting directly"
}

# ---- Pre-flight ------------------------------------------------------------------------
[[ -n "$SERVER_NAME" ]] || die "--server-name required (auto-detection found nothing; pass the flag or answer the prompt)"

# Non-interactive convenience: no cert configured but CF credentials are in the
# environment -> provision automatically.
if (( AUTO_CERT == 0 )) && [[ -z "$TLS_CERT" ]] && [[ -n "$CF_ORIGIN_CA_KEY" || -n "$CF_API_TOKEN" ]]; then
    log_info "no cert configured but Cloudflare credentials found in environment — enabling --cf-auto-cert"
    AUTO_CERT=1
fi

if (( AUTO_CERT == 1 )); then
    if (( DRY_RUN == 1 )); then
        # A dry run must not create anything — just show what would happen
        # and assume the canonical paths for the render preview.
        log_info "[--dry-run] would fetch a Cloudflare origin certificate for ${SERVER_NAME}"
        TLS_CERT="${TLS_CERT:-/etc/ssl/cloudflare/origin.pem}"
        TLS_KEY="${TLS_KEY:-/etc/ssl/cloudflare/origin.key}"
    else
        cf_auto_cert
    fi
fi

[[ -n "$TLS_CERT" ]] || die "--cert required (or use --cf-auto-cert, or answer the prompt)"
[[ -n "$TLS_KEY"  ]] || die "--key required (or use --cf-auto-cert, or answer the prompt)"
if (( DRY_RUN == 1 )); then
    # Dry runs tolerate missing files (they may not be provisioned yet).
    [[ -r "$TLS_CERT" ]] || log_warn "[--dry-run] TLS cert not present yet: $TLS_CERT"
    [[ -r "$TLS_KEY"  ]] || log_warn "[--dry-run] TLS key not present yet: $TLS_KEY"
else
    [[ -r "$TLS_CERT" ]] || die "TLS cert not readable: $TLS_CERT"
    [[ -r "$TLS_KEY"  ]] || die "TLS key not readable: $TLS_KEY"
fi

# OS check: warn (don't abort) off-target — the tool may still work.
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "debian" ]]; then
        log_warn "OS is ${ID:-unknown}; built for Debian 12 (bookworm)"
    elif [[ "${VERSION_ID:-}" != "12" ]]; then
        log_warn "Debian ${VERSION_ID:-?}; tested on 12 (bookworm)"
    fi
fi

# Everything this project shells out to must actually exist.
for cmd in curl openssl flock nginx ip ss sha256sum awk grep sed install systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command missing: $cmd"
done

# Firewall backend: --force > existing config > detection.
if [[ -n "$ARG_FORCE" ]]; then
    case "$ARG_FORCE" in
        nftables|ufw|iptables) BACKEND="$ARG_FORCE" ;;
        *) die "--force must be nftables|ufw|iptables" ;;
    esac
    log_info "using forced backend: $BACKEND"
elif (( HAVE_EXISTING_CONFIG == 1 )) && [[ -n "${CFO_FW_BACKEND:-}" ]]; then
    # Reusing the recorded backend avoids detection drift on reinstalls.
    BACKEND="$CFO_FW_BACKEND"
    log_info "reusing configured backend: $BACKEND"
else
    # detect_firewall exits non-zero when the answer is ambiguous, and `set -e`
    # would kill us mid-detection — so suspend -e around the call.
    set +e
    BACKEND="$(detect_firewall)"
    rc=$?
    set -e
    (( rc != 0 )) && die "firewall detection ambiguous; rerun with --force <backend>"
    if [[ "$BACKEND" == "none" ]]; then
        log_warn "no active firewall detected"
        if prompt_yn "enable nftables (Debian 12 default) and proceed?"; then
            apt-get install -y nftables >/dev/null || die "failed to install nftables"
            systemctl enable --now nftables.service
            BACKEND="nftables"
        else
            die "aborted: an active firewall backend is required"
        fi
    fi
    log_info "detected firewall backend: $BACKEND"
fi

# The chosen backend's tools must be present.
case "$BACKEND" in
    nftables) command -v nft >/dev/null || die "nft not installed" ;;
    ufw)      command -v ufw >/dev/null || die "ufw not installed" ;;
    iptables)
        for c in iptables ip6tables iptables-restore ip6tables-restore; do
            command -v "$c" >/dev/null || die "$c not installed"
        done
        ;;
esac

# SSH visibility note (informational — we never touch SSH ports either way).
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/${BACKEND}.sh"
SSH_PORTS_DETECTED="$(detect_ssh_ports | tr '\n' ' ')"
log_info "SSH ports detected (always excluded from management): ${SSH_PORTS_DETECTED% }"
if ! check_ssh_reachable "$BACKEND"; then
    log_warn "SSH does not appear explicitly allowed in the current ${BACKEND} rules."
    log_warn "cf-owntracks never touches SSH ports, but verify your own firewall policy."
fi

# Attach mode validation + the conflicting-vhost guard.
if [[ -n "$ATTACH_VHOST" ]]; then
    [[ -f "$ATTACH_VHOST" ]] || die "--attach-vhost: file not found: $ATTACH_VHOST"
    grep -qE '^[[:space:]]*server[[:space:]{]' "$ATTACH_VHOST" \
        || die "--attach-vhost: no server block found in $ATTACH_VHOST"
    log_info "attach mode: protection will be layered into ${ATTACH_VHOST}"
else
    # Not attaching — creating our own vhost. If ANOTHER enabled vhost already
    # claims this server name, nginx will ignore one of the two ("conflicting
    # server name") and the loser silently serves nothing. This exact
    # foot-gun shipped once; now it is a hard stop.
    CONFLICT_FILE="$(grep -RIl -E "server_name[^;]*[[:space:]]${SERVER_NAME//./\\.}" \
        /etc/nginx/sites-enabled/ 2>/dev/null | grep -v '/owntracks.conf$' | head -1 || true)"
    if [[ -n "$CONFLICT_FILE" ]] && (( FORCE_OWN_VHOST == 0 )); then
        log_error "another enabled vhost already serves ${SERVER_NAME}: ${CONFLICT_FILE}"
        log_error "creating our own vhost would conflict (nginx ignores duplicate server names)."
        log_error "either:"
        log_error "  RECOMMENDED: rerun with  --attach-vhost ${CONFLICT_FILE}"
        log_error "  or disable that vhost first, or pass --force-own-vhost to override"
        die "aborting to avoid a conflicting server name"
    fi
fi

# nginx allows only ONE default_server per listen port — refuse to fight an
# existing one rather than break the reload later.
if [[ "$GLOBAL_REDIRECT" == "1" ]]; then
    if grep -RIn --include='*.conf' -E 'listen[[:space:]]+(\[::\]:)?80[[:space:]]+default_server' \
            /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null \
            | grep -v '00-cf-global-redirect.conf' | grep -q .; then
        die "--global-http-redirect: another default_server on :80 already exists. Resolve that first."
    fi
fi

# Deploying with mTLS while the Cloudflare-side toggle is off would 403 every
# request — make the operator confirm the dashboard is ready first.
if [[ "$MODE" == "deploy" ]] && [[ "$MTLS_ENABLED" == "1" ]]; then
    log_info "DEPLOY + mTLS: the zone-level toggle MUST already be on:"
    log_info "  Cloudflare dashboard -> SSL/TLS -> Origin Server -> Authenticated Origin Pulls"
    if ! prompt_yn "confirm Authenticated Origin Pulls is enabled in the Cloudflare dashboard?"; then
        die "aborted: enable AOP first, or rerun with --no-mtls / without --deploy"
    fi
fi

# ---- Dry run ------------------------------------------------------------------------------
# Fill the vhost template: each sed expression replaces one __PLACEHOLDER__.
render_vhost() {
    sed \
        -e "s|__SERVER_NAME__|${SERVER_NAME}|g" \
        -e "s|__OWNTRACKS_PORT__|${OWNTRACKS_PORT}|g" \
        -e "s|__TLS_CERT__|${TLS_CERT}|g" \
        -e "s|__TLS_KEY__|${TLS_KEY}|g" \
        "${SCRIPT_DIR}/nginx/owntracks.conf.template"
}

# Emit the config file content from the final merged settings.
render_config() {
    cat <<EOF
# cf-owntracks daemon config — managed by installer (v${CFO_VERSION})
# Edit + run \`systemctl start cf-owntracks.service\` to apply changes.
CFO_VERSION="${CFO_VERSION}"
CFO_MODE="${MODE}"
CFO_SERVER_NAME="${SERVER_NAME}"
CFO_OWNTRACKS_PORT="${OWNTRACKS_PORT}"
CFO_FW_BACKEND="${BACKEND}"
CFO_TLS_CERT="${TLS_CERT}"
CFO_TLS_KEY="${TLS_KEY}"
CFO_MTLS_ENABLED=${MTLS_ENABLED}
CFO_GLOBAL_REDIRECT=${GLOBAL_REDIRECT}
CFO_ASN_FAILSAFE=${ASN_FAILSAFE}
CFO_CF_ASNS="${CF_ASNS}"
CFO_EXTRA_PORTS="${EXTRA_PORTS}"
CFO_TEST_LOG_MAX_MB=${TEST_LOG_MAX_MB}
CFO_ATTACH_VHOST="${ATTACH_VHOST}"
EOF
}

if (( DRY_RUN == 1 )); then
    STAGE="./cf-owntracks-rendered"
    mkdir -p "$STAGE"
    render_vhost  > "${STAGE}/owntracks.conf"
    render_config > "${STAGE}/config"
    log_info "[--dry-run] rendered vhost + config to ${STAGE}/ — nothing changed"
    log_info "[--dry-run] would install mode=${MODE} backend=${BACKEND} ssh_excluded=[${SSH_PORTS_DETECTED% }]"
    exit 0
fi

# ---- Snapshot --------------------------------------------------------------------------------
# Record the pre-install state of the firewall + nginx (+ old config) into a
# timestamped directory, so there is always something to compare/restore from.
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
    tar czf "${snap_dir}/nginx.before.tar.gz" -C / etc/nginx 2>/dev/null || true
    [[ -f "$CFO_CONFIG_FILE" ]] && cp -p "$CFO_CONFIG_FILE" "${snap_dir}/config.before"
    echo "$snap_dir" > "${CFO_BACKUP_DIR}/.latest"
}

# ---- Install ----------------------------------------------------------------------------------
install_files() {
    # `install` = copy + set permissions/dirs in one step (-d makes dirs,
    # -m sets the mode).
    log_info "installing libraries to /usr/local/lib/cf-owntracks/"
    install -d -m 0755 /usr/local/lib/cf-owntracks /usr/local/share/cf-owntracks
    install -m 0644 "${SCRIPT_DIR}/lib/common.sh"   /usr/local/lib/cf-owntracks/
    install -m 0644 "${SCRIPT_DIR}/lib/nftables.sh" /usr/local/lib/cf-owntracks/
    install -m 0644 "${SCRIPT_DIR}/lib/ufw.sh"      /usr/local/lib/cf-owntracks/
    install -m 0644 "${SCRIPT_DIR}/lib/iptables.sh" /usr/local/lib/cf-owntracks/
    [[ -f "${SCRIPT_DIR}/README.md" ]] && install -m 0644 "${SCRIPT_DIR}/README.md" /usr/local/share/cf-owntracks/

    log_info "installing refresh daemon"
    install -m 0755 "${SCRIPT_DIR}/bin/cf-owntracks-refresh" /usr/local/sbin/cf-owntracks-refresh

    log_info "installing systemd units"
    install -m 0644 "${SCRIPT_DIR}/systemd/cf-owntracks.service"     /etc/systemd/system/
    install -m 0644 "${SCRIPT_DIR}/systemd/cf-owntracks.timer"       /etc/systemd/system/
    install -m 0644 "${SCRIPT_DIR}/systemd/cf-owntracks-retry.timer" /etc/systemd/system/
    # The shipped timer fires every 6 hours; patch its OnCalendar line in
    # place when the operator picked something else.
    case "$REFRESH_INTERVAL" in
        6h)     : ;;  # shipped default
        3h)     sed -i 's|^OnCalendar=.*|OnCalendar=*-*-* 00/3:00:00|' /etc/systemd/system/cf-owntracks.timer ;;
        12h)    sed -i 's|^OnCalendar=.*|OnCalendar=*-*-* 00/12:00:00|' /etc/systemd/system/cf-owntracks.timer ;;
        daily)  sed -i 's|^OnCalendar=.*|OnCalendar=daily|' /etc/systemd/system/cf-owntracks.timer ;;
        hourly) sed -i 's|^OnCalendar=.*|OnCalendar=hourly|' /etc/systemd/system/cf-owntracks.timer ;;
    esac
    systemctl daemon-reload

    log_info "installing nginx pieces"
    install -m 0644 "${SCRIPT_DIR}/nginx/cfo-upgrade-map.conf" /etc/nginx/conf.d/cfo-upgrade-map.conf
    install -d -m 0755 /etc/nginx/snippets

    # Mode-aware placeholders — replaced by the first refresh. They exist so the
    # vhost parses even if the bootstrap refresh fails.
    cat > "$CFO_NGINX_REALIP_SNIPPET" <<'EOF'
# cf-owntracks placeholder — overwritten by the daemon on first refresh.
EOF
    if [[ "$MODE" == "deploy" ]]; then
        # Deploy placeholder FAILS CLOSED: better to 403 everything for a
        # moment than to expose the service before the real rules land.
        cat > "$CFO_NGINX_ENFORCE_SNIPPET" <<'EOF'
# cf-owntracks placeholder — overwritten on first refresh.
# Fail closed until the real allowlist arrives (deploy mode).
return 403;
EOF
    else
        # Test placeholder does nothing: test mode must never block.
        cat > "$CFO_NGINX_ENFORCE_SNIPPET" <<'EOF'
# cf-owntracks placeholder — overwritten on first refresh.
# TEST MODE: nothing enforced, decision logging starts after first refresh.
EOF
    fi
    cat > "$CFO_NGINX_MTLS_SNIPPET" <<'EOF'
# cf-owntracks placeholder — overwritten by the daemon on first refresh.
EOF
    # Minimal but syntactically-complete maps so nginx -t passes before the
    # first refresh fills in the real classification data.
    cat > "$CFO_NGINX_MAPS_CONF" <<'EOF'
# cf-owntracks placeholder — overwritten by the daemon on first refresh.
geo $realip_remote_addr $cfo_src_class { default would_block; }
map $cfo_src_class $cfo_would_block { default 1; }
map $cfo_src_class $cfo_reason { default "bootstrap"; }
log_format cfo_ndjson escape=json '{"ts":"$time_iso8601","bootstrap":true}';
EOF

    # v1 leftover cleanup: the old allow snippet is no longer referenced.
    rm -f "$CFO_NGINX_LEGACY_ALLOW_SNIPPET"

    if [[ -n "$ATTACH_VHOST" ]]; then
        # Attach mode: the operator's vhost is the app; we only add our three
        # include lines to it. Any previously-generated standalone vhost is
        # removed so it can never shadow (or be shadowed by) the real one.
        log_info "attach mode: standing down any generated vhost"
        rm -f "$CFO_NGINX_VHOST" "$CFO_NGINX_VHOST_ENABLED"
        attach_vhost_includes "$ATTACH_VHOST"
    else
        log_info "rendering OwnTracks vhost"
        render_vhost > "$CFO_NGINX_VHOST"
        chmod 0644 "$CFO_NGINX_VHOST"
        # sites-enabled entries are symlinks into sites-available (Debian custom).
        ln -sf "$CFO_NGINX_VHOST" "$CFO_NGINX_VHOST_ENABLED"
    fi

    if [[ "$GLOBAL_REDIRECT" == "1" ]]; then
        log_info "installing global :80 -> :443 redirect"
        install -m 0644 "${SCRIPT_DIR}/nginx/global-redirect.conf" "$CFO_NGINX_GLOBAL_REDIRECT"
        ln -sf "$CFO_NGINX_GLOBAL_REDIRECT" "$CFO_NGINX_GLOBAL_REDIRECT_ENABLED"
    else
        rm -f "$CFO_NGINX_GLOBAL_REDIRECT" "$CFO_NGINX_GLOBAL_REDIRECT_ENABLED"
    fi

    log_info "writing config to $CFO_CONFIG_FILE"
    install -d -m 0755 "$(dirname "$CFO_CONFIG_FILE")"
    render_config > "$CFO_CONFIG_FILE"
    chmod 0640 "$CFO_CONFIG_FILE"

    # Allowlist: create if absent; append only NEW entries (never clobber).
    touch "$CFO_ALLOWLIST_FILE"
    chmod 0644 "$CFO_ALLOWLIST_FILE"
    local a n
    for a in "${ARG_ALLOW[@]}"; do
        n="$(normalize_cidr "$a")"
        # grep -qxF = exact whole-line match, no regex — "is it already there?"
        if ! grep -qxF "$n" "$CFO_ALLOWLIST_FILE" 2>/dev/null; then
            echo "$n" >> "$CFO_ALLOWLIST_FILE"
            log_info "allowlist: added $n"
        fi
    done

    install -d -m 0755 "$CFO_STATE_DIR" "$CFO_BACKUP_DIR" "$CFO_LOG_DIR" /etc/ssl/cloudflare
}

take_install_snapshot
install_files

# ---- Bootstrap + enable ---------------------------------------------------------------------------
# Run one refresh right now (synchronously) so the box is fully configured the
# moment the installer exits — no waiting for the first timer tick.
log_info "running initial refresh (synchronous bootstrap)"
if ! /usr/local/sbin/cf-owntracks-refresh; then
    log_error "initial refresh failed; review: journalctl -t cf-owntracks -n 50"
    log_error "the system is in a safe state (placeholders active); fix and rerun, or --uninstall"
    exit 1
fi

log_info "enabling refresh timer (${REFRESH_INTERVAL})"
systemctl enable --now cf-owntracks.timer

# ---- Diagnostics + summary -------------------------------------------------------------------------
# `|| true`: a WARN-level diagnostic outcome shouldn't abort a completed install.
run_diagnostics || true

echo
echo "== INSTALL SUMMARY ==========================================================="
if [[ "$MODE" == "deploy" ]]; then
    echo "  MODE: DEPLOY — ENFORCEMENT ACTIVE"
    echo "  Only Cloudflare, localhost, and allowlisted sources can reach the managed ports."
else
    echo "  MODE: TEST — ENFORCEMENT OFF (observe only)"
    echo "  The box is NOT protected yet. Watch what WOULD be blocked:"
    echo "      tail -f ${CFO_DECISION_LOG}"
    echo "      grep '\"would_block\":1' ${CFO_DECISION_LOG} | tail -20"
    echo
    echo "  When the log looks right, enforce with:"
    echo "      sudo $0 --deploy --yes"
fi
echo "  ----------------------------------------------------------------------------"
echo "  server:       https://${SERVER_NAME} (recorder on 127.0.0.1:${OWNTRACKS_PORT})"
echo "  backend:      ${BACKEND}    mTLS: ${MTLS_ENABLED}    ASN failsafe: ${ASN_FAILSAFE}"
if [[ -n "$ATTACH_VHOST" ]]; then
    echo "  vhost:        ATTACHED to ${ATTACH_VHOST} (your config; our includes are marker-delimited)"
fi
echo "  refresh:      every ${REFRESH_INTERVAL} + auto-retry ~30min after failures"
echo "  allowlist:    ${CFO_ALLOWLIST_FILE} (edit + wait for refresh, or: systemctl start cf-owntracks.service)"
echo "  config:       ${CFO_CONFIG_FILE} (settings are reused by future installer runs)"
echo "  logs:         journalctl -t cf-owntracks -f"
echo "  diagnostics:  sudo $0 --diagnostics"
echo "  uninstall:    sudo $0 --uninstall"
echo "=============================================================================="
