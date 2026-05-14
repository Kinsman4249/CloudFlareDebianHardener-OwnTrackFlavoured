#!/usr/bin/env bash
# cf-owntracks: common helpers sourced by installer and refresh daemon.
# This file is sourced, not executed; never put `set -e` here.

# Most CFO_* constants below are referenced from other files that source this
# one; shellcheck can't see those cross-file references.
# shellcheck disable=SC2034

# ---- Paths -------------------------------------------------------------------
CFO_LIB_DIR="${CFO_LIB_DIR:-/usr/local/lib/cf-owntracks}"
CFO_CONFIG_FILE="${CFO_CONFIG_FILE:-/etc/cf-owntracks/config}"
CFO_STATE_DIR="${CFO_STATE_DIR:-/var/lib/cf-owntracks}"
CFO_BACKUP_DIR="${CFO_BACKUP_DIR:-/var/backups/cf-owntracks}"
CFO_LOCK_FILE="${CFO_LOCK_FILE:-/run/cf-owntracks.lock}"

CFO_NGINX_REALIP_SNIPPET="/etc/nginx/snippets/cloudflare-realip.conf"
CFO_NGINX_ALLOW_SNIPPET="/etc/nginx/snippets/cloudflare-allow.conf"
CFO_NGINX_MTLS_SNIPPET="/etc/nginx/snippets/cloudflare-mtls.conf"
CFO_NGINX_VHOST="/etc/nginx/sites-available/owntracks.conf"
CFO_NGINX_VHOST_ENABLED="/etc/nginx/sites-enabled/owntracks.conf"
CFO_NGINX_GLOBAL_REDIRECT="/etc/nginx/sites-available/00-cf-global-redirect.conf"
CFO_NGINX_GLOBAL_REDIRECT_ENABLED="/etc/nginx/sites-enabled/00-cf-global-redirect.conf"

CFO_AOP_CA_FILE="/etc/ssl/cloudflare/authenticated_origin_pull_ca.pem"
CFO_AOP_CA_HASH="${CFO_STATE_DIR}/origin-pull-ca.sha256"
CFO_AOP_CA_URL="https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem"

CFO_IPS_V4_URL="https://www.cloudflare.com/ips-v4"
CFO_IPS_V6_URL="https://www.cloudflare.com/ips-v6"
CFO_IPS_V4_FILE="${CFO_STATE_DIR}/ips-v4.last"
CFO_IPS_V6_FILE="${CFO_STATE_DIR}/ips-v6.last"

# Sanity thresholds: bail rather than apply suspicious changes.
CFO_MIN_V4_RANGES=5
CFO_MIN_V6_RANGES=3
CFO_MAX_DELTA_PCT=50

# ---- Logging -----------------------------------------------------------------
# Logs go to stderr AND systemd journal (when run under systemd).
_cfo_log() {
    local level="$1"; shift
    local msg="$*"
    local tag="cf-owntracks"
    # Always stderr for interactive visibility.
    printf '[%s] %s: %s\n' "$(date -u +%FT%TZ)" "$level" "$msg" >&2
    # logger sends to journald if present (silently no-ops otherwise).
    if command -v logger >/dev/null 2>&1; then
        logger -t "$tag" -p "user.${level,,}" -- "$msg" 2>/dev/null || true
    fi
}
log_info()  { _cfo_log "INFO"  "$@"; }
log_warn()  { _cfo_log "WARN"  "$@"; }
log_error() { _cfo_log "ERR"   "$@"; }
die()       { _cfo_log "ERR"   "$@"; exit 1; }

# ---- Privilege ---------------------------------------------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "must run as root (got uid $EUID)"
    fi
}

# ---- CIDR validation ---------------------------------------------------------
# Strict regex-based validation; refuses anything that isn't a textbook CIDR.
is_valid_cidr_v4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
    local ip="${1%/*}" mask="${1#*/}"
    (( mask >= 0 && mask <= 32 )) || return 1
    local IFS=.
    # shellcheck disable=SC2206
    local parts=($ip)
    local p
    for p in "${parts[@]}"; do
        (( p >= 0 && p <= 255 )) || return 1
    done
    return 0
}

is_valid_cidr_v6() {
    # Structural validation in pure bash (no `ip`/`ipcalc` dependency).
    # Rules enforced:
    #   - prefix length 0-128
    #   - 2-7 colons total (allows for `::` shortener but not pathological forms)
    #   - at most one occurrence of `::`
    #   - each colon-separated group is 0-4 hex chars (0 chars only valid with ::)
    [[ "$1" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]] || return 1
    local mask="${1#*/}"
    (( mask >= 0 && mask <= 128 )) || return 1
    local addr="${1%/*}"
    # Reject runs of three+ colons (e.g. `:::`) — these slip past the per-group
    # regex because the split treats them as empty groups.
    [[ "$addr" == *":::"* ]] && return 1
    # Colon count
    local colons="${addr//[^:]/}"
    (( ${#colons} >= 2 && ${#colons} <= 7 )) || return 1
    # At most one "::" (count substring occurrences)
    local rest="$addr" dcount=0
    while [[ "$rest" == *"::"* ]]; do
        dcount=$((dcount + 1))
        rest="${rest#*::}"
    done
    (( dcount <= 1 )) || return 1
    # Each group: 0-4 hex chars
    local IFS=:
    # shellcheck disable=SC2206
    local groups=($addr)
    local g
    for g in "${groups[@]}"; do
        [[ "$g" =~ ^[0-9a-fA-F]{0,4}$ ]] || return 1
    done
    return 0
}

# Read CIDRs from a file (one per line), trim, drop comments and blanks.
read_cidr_file() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$f" | grep -v '^$' || true
}

# Validate a list (passed via stdin) of CIDRs against the given family.
# Echoes valid lines; non-zero exit if any invalid line found.
validate_cidr_list() {
    local family="$1"  # v4 or v6
    local validator
    case "$family" in
        v4) validator=is_valid_cidr_v4 ;;
        v6) validator=is_valid_cidr_v6 ;;
        *) die "validate_cidr_list: bad family $family" ;;
    esac
    local line bad=0 ok=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if "$validator" "$line"; then
            printf '%s\n' "$line"
            ok=$((ok + 1))
        else
            log_warn "rejected invalid ${family} CIDR: $line"
            bad=$((bad + 1))
        fi
    done
    if (( bad > 0 )); then
        log_error "validate_cidr_list: $bad invalid entries (${family})"
        return 1
    fi
    if (( ok == 0 )); then
        log_error "validate_cidr_list: no valid ${family} entries"
        return 1
    fi
    return 0
}

# ---- Cloudflare IP fetch -----------------------------------------------------
# Fetch with retries. Writes to $2 on success, returns non-zero on failure.
fetch_with_retry() {
    local url="$1" dest="$2" attempt
    for attempt in 1 2 3; do
        if curl --fail --silent --show-error --location \
                --max-time 20 --connect-timeout 10 \
                "$url" -o "$dest"; then
            if [[ -s "$dest" ]]; then
                return 0
            fi
            log_warn "fetch ${url}: empty response (attempt ${attempt})"
        else
            log_warn "fetch ${url}: curl failed (attempt ${attempt})"
        fi
        sleep $(( attempt * 2 ))
    done
    return 1
}

# Compare new vs last-known-good list. Returns 0 if delta acceptable, 1 if not.
# Delta = (added + removed) / max(old_count, new_count) * 100.
check_delta() {
    local new_file="$1" old_file="$2" family="$3"
    if [[ ! -f "$old_file" ]]; then
        log_info "no prior ${family} list; accepting new list"
        return 0
    fi
    local old_count new_count added removed total max_count delta_pct
    old_count=$(grep -c . "$old_file" || true)
    new_count=$(grep -c . "$new_file" || true)
    added=$(comm -23 <(sort -u "$new_file") <(sort -u "$old_file") | wc -l)
    removed=$(comm -13 <(sort -u "$new_file") <(sort -u "$old_file") | wc -l)
    total=$(( added + removed ))
    max_count=$(( old_count > new_count ? old_count : new_count ))
    if (( max_count == 0 )); then
        log_error "check_delta: both lists empty (${family})"
        return 1
    fi
    delta_pct=$(( total * 100 / max_count ))
    log_info "${family} delta: +${added} -${removed} (${delta_pct}% of max ${max_count})"
    if (( delta_pct > CFO_MAX_DELTA_PCT )); then
        log_error "${family} delta ${delta_pct}% exceeds ${CFO_MAX_DELTA_PCT}% threshold"
        return 1
    fi
    return 0
}

# ---- Config ------------------------------------------------------------------
# Source the config file. Sets:
#   CFO_SERVER_NAME, CFO_OWNTRACKS_PORT, CFO_MTLS_ENABLED, CFO_FW_BACKEND,
#   CFO_TLS_CERT, CFO_TLS_KEY, CFO_GLOBAL_REDIRECT
load_config() {
    [[ -f "$CFO_CONFIG_FILE" ]] || die "config not found: $CFO_CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CFO_CONFIG_FILE"
    : "${CFO_SERVER_NAME:?CFO_SERVER_NAME missing from config}"
    : "${CFO_OWNTRACKS_PORT:=8083}"
    : "${CFO_MTLS_ENABLED:=1}"
    : "${CFO_FW_BACKEND:?CFO_FW_BACKEND missing from config}"
    : "${CFO_TLS_CERT:?CFO_TLS_CERT missing from config}"
    : "${CFO_TLS_KEY:?CFO_TLS_KEY missing from config}"
    : "${CFO_GLOBAL_REDIRECT:=0}"
}

# ---- Firewall backend detection ---------------------------------------------
# Echoes one of: ufw, nftables, iptables, none.
# Non-zero exit if ambiguous (multiple appear active).
#
# Detection is heuristic because on Debian 12 the `iptables` CLI is an alias
# for `iptables-nft`, which means iptables-managed rules also appear in
# `nft list ruleset` (under the standard `ip filter` / `ip6 filter` tables).
# Conversely, nft-managed rules can appear in the iptables wrapper view.
#
# Priority order:
#   1. ufw active (it manages its own tables in nft underneath but
#      `ufw status` is authoritative)
#   2. nft has a table in the `inet` family or in a non-standard ip/ip6 family
#      table name → user is using nft directly
#   3. iptables -S shows non-default rules → user is using iptables CLI
#   4. None of the above → none
detect_firewall() {
    local active=()

    # 1. ufw
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        active+=("ufw")
    fi

    # 2. nftables (only count if not already counted as ufw)
    if [[ ! " ${active[*]} " =~ " ufw " ]] && command -v nft >/dev/null 2>&1; then
        # List tables (just the "table FAMILY NAME" header lines).
        local nft_tables
        nft_tables=$(nft list tables 2>/dev/null || true)
        # Strip ufw's tables (always named ufw-*) and the standard iptables-compat
        # tables (which are populated by iptables CLI too). What remains is
        # nft-native usage.
        local nft_native
        nft_native=$(grep -vE '^table[[:space:]]+(ip|ip6)[[:space:]]+ufw(-|$)|^table[[:space:]]+(ip|ip6)[[:space:]]+(filter|nat|mangle|raw|security)$' <<<"$nft_tables" || true)
        if [[ -n "$nft_native" ]]; then
            active+=("nftables")
        fi
    fi

    # 3. iptables (only count if neither ufw nor nft-native already counted)
    if [[ ! " ${active[*]} " =~ " ufw " ]] && [[ ! " ${active[*]} " =~ " nftables " ]] && \
       command -v iptables >/dev/null 2>&1; then
        local ipt_rules
        ipt_rules=$(iptables -S 2>/dev/null | grep -vE '^-P (INPUT|OUTPUT|FORWARD) ACCEPT$' || true)
        if [[ -n "$ipt_rules" ]]; then
            active+=("iptables")
        fi
    fi

    case "${#active[@]}" in
        0) echo "none"; return 0 ;;
        1) echo "${active[0]}"; return 0 ;;
        *) log_error "multiple firewall backends appear active: ${active[*]}"; return 2 ;;
    esac
}

# ---- nginx helpers -----------------------------------------------------------
nginx_test_or_die() {
    if ! nginx -t 2>&1; then
        die "nginx -t failed; refusing to reload"
    fi
}

nginx_reload() {
    log_info "reloading nginx"
    nginx -s reload || die "nginx reload failed"
}

# ---- Atomic file swap --------------------------------------------------------
# write_atomic <dest> < source-on-stdin
write_atomic() {
    local dest="$1"
    local tmp="${dest}.tmp.$$"
    cat > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$dest"
}

# ---- SSH reachability check --------------------------------------------------
# Best-effort: confirms port 22 (or $SSH_PORT) isn't dropped by the current rules.
# Returns 0 if SSH appears reachable, 1 otherwise.
check_ssh_reachable() {
    local port="${SSH_PORT:-22}"
    local backend="$1"
    case "$backend" in
        ufw)
            ufw status numbered | grep -qE "^\[.*\].*${port}/tcp.*ALLOW" && return 0
            return 1
            ;;
        nftables)
            local rs
            rs=$(nft list ruleset 2>/dev/null) || return 1
            # Bare-port form: "tcp dport 22 accept"
            if grep -qE "tcp dport ${port}[^0-9].*accept" <<<"$rs"; then
                return 0
            fi
            # Set form: "tcp dport { 22, 80, 443 } accept" — match port as a token inside braces
            if grep -qE "tcp dport \{[^}]*\b${port}\b[^}]*\}.*accept" <<<"$rs"; then
                return 0
            fi
            # Default-accept policy on the input hook
            if grep -qE 'hook input.*policy accept' <<<"$rs"; then
                return 0
            fi
            return 1
            ;;
        iptables)
            iptables -S INPUT 2>/dev/null | grep -qE "dport ${port}.*ACCEPT" && return 0
            iptables -S 2>/dev/null | grep -qE '^-P INPUT ACCEPT$' && return 0
            return 1
            ;;
        none)
            return 0  # no firewall, SSH is fine
            ;;
    esac
    return 1
}
