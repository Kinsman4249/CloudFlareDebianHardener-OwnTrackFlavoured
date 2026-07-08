#!/usr/bin/env bash
# cf-owntracks: common helpers sourced by installer and refresh daemon.
# This file is sourced, not executed; never put `set -e` here.
#
# v2.0.0 — mode model (test/deploy), dynamic port discovery, SSH guarantee,
# localhost + allowlist, ASN failsafe, NDJSON decision log.
#
# Most CFO_* constants below are referenced from other files that source this
# one; shellcheck can't see those cross-file references.
# shellcheck disable=SC2034

# ---- Version -------------------------------------------------------------------
CFO_VERSION="2.1.0"

# ---- Paths -------------------------------------------------------------------
CFO_LIB_DIR="${CFO_LIB_DIR:-/usr/local/lib/cf-owntracks}"
CFO_CONFIG_FILE="${CFO_CONFIG_FILE:-/etc/cf-owntracks/config}"
CFO_ALLOWLIST_FILE="${CFO_ALLOWLIST_FILE:-/etc/cf-owntracks/allowlist}"
CFO_STATE_DIR="${CFO_STATE_DIR:-/var/lib/cf-owntracks}"
CFO_BACKUP_DIR="${CFO_BACKUP_DIR:-/var/backups/cf-owntracks}"
CFO_LOCK_FILE="${CFO_LOCK_FILE:-/run/cf-owntracks.lock}"
CFO_LOG_DIR="${CFO_LOG_DIR:-/var/log/cf-owntracks}"
CFO_DECISION_LOG="${CFO_LOG_DIR}/decisions.ndjson"

CFO_NGINX_MAPS_CONF="/etc/nginx/conf.d/cf-owntracks-maps.conf"
CFO_NGINX_REALIP_SNIPPET="/etc/nginx/snippets/cloudflare-realip.conf"
CFO_NGINX_ENFORCE_SNIPPET="/etc/nginx/snippets/cloudflare-enforce.conf"
CFO_NGINX_MTLS_SNIPPET="/etc/nginx/snippets/cloudflare-mtls.conf"
CFO_NGINX_LEGACY_ALLOW_SNIPPET="/etc/nginx/snippets/cloudflare-allow.conf"  # v1 leftover
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
CFO_ASN_V4_FILE="${CFO_STATE_DIR}/asn-v4.last"
CFO_ASN_V6_FILE="${CFO_STATE_DIR}/asn-v6.last"
CFO_PORTS_FILE="${CFO_STATE_DIR}/ports.last"

CFO_RIPESTAT_URL="https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS"
CFO_BGPVIEW_URL="https://api.bgpview.io/asn/"

# Sanity thresholds: bail rather than apply suspicious changes.
CFO_MIN_V4_RANGES=5
CFO_MIN_V6_RANGES=3
CFO_MAX_DELTA_PCT=50
# ASN failsafe: cap the novel set so a poisoned source can't flood the ruleset.
# Reality check (2026-07): AS13335's real novel set is ~930 prefixes (761 v4 +
# 167 v6 beyond the published lists), so the cap needs comfortable headroom
# above that while still catching a poisoned source dumping tens of thousands.
CFO_MAX_ASN_NOVEL=2000
# ufw rule-count warning threshold.
CFO_UFW_RULE_WARN=200

# ---- Logging -----------------------------------------------------------------
_cfo_log() {
    local level="$1"; shift
    local msg="$*"
    local tag="cf-owntracks"
    printf '[%s] %s: %s\n' "$(date -u +%FT%TZ)" "$level" "$msg" >&2
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
    [[ "$1" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]] || return 1
    local mask="${1#*/}"
    (( mask >= 0 && mask <= 128 )) || return 1
    local addr="${1%/*}"
    [[ "$addr" == *":::"* ]] && return 1
    local colons="${addr//[^:]/}"
    (( ${#colons} >= 2 && ${#colons} <= 7 )) || return 1
    local rest="$addr" dcount=0
    while [[ "$rest" == *"::"* ]]; do
        dcount=$((dcount + 1))
        rest="${rest#*::}"
    done
    (( dcount <= 1 )) || return 1
    local IFS=:
    # shellcheck disable=SC2206
    local groups=($addr)
    local g
    for g in "${groups[@]}"; do
        [[ "$g" =~ ^[0-9a-fA-F]{0,4}$ ]] || return 1
    done
    return 0
}

# Accepts a bare address too (no /mask) and normalizes to a host CIDR.
normalize_cidr() {
    local c="$1"
    if [[ "$c" == */* ]]; then
        printf '%s\n' "$c"
    elif [[ "$c" == *:* ]]; then
        printf '%s/128\n' "$c"
    else
        printf '%s/32\n' "$c"
    fi
}

read_cidr_file() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$f" | grep -v '^$' || true
}

validate_cidr_list() {
    local family="$1"
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

# ---- Binary prefix expansion (containment math, both families) -----------------
# Convert an IPv4 address to a 32-char binary string.
ipv4_to_bin() {
    local ip="$1" out="" o b
    local IFS=.
    # shellcheck disable=SC2206
    local octets=($ip)
    for o in "${octets[@]}"; do
        for (( b=7; b>=0; b-- )); do
            out+=$(( (o >> b) & 1 ))
        done
    done
    printf '%s\n' "$out"
}

# Expand an IPv6 address (:: allowed) to 32 lowercase hex nibbles.
expand_ipv6_nibbles() {
    local addr="${1,,}" left right
    local -a lg=() rg=()
    if [[ "$addr" == *"::"* ]]; then
        left="${addr%%::*}"
        right="${addr##*::}"
        [[ -n "$left"  ]] && IFS=: read -r -a lg <<<"$left"
        [[ -n "$right" ]] && IFS=: read -r -a rg <<<"$right"
    else
        IFS=: read -r -a lg <<<"$addr"
    fi
    local total=$(( ${#lg[@]} + ${#rg[@]} ))
    local fill=$(( 8 - total ))
    local -a groups=()
    groups+=("${lg[@]}")
    local i
    for (( i=0; i<fill; i++ )); do groups+=("0"); done
    groups+=("${rg[@]}")
    local out="" g
    for g in "${groups[@]}"; do
        printf -v g '%04s' "$g"
        out+="${g// /0}"
    done
    printf '%s\n' "$out"
}

# Convert 32 hex nibbles to a 128-char binary string.
_nibbles_to_bin() {
    local nibbles="$1" out="" n
    local i
    for (( i=0; i<${#nibbles}; i++ )); do
        n="${nibbles:i:1}"
        case "$n" in
            0) out+="0000" ;; 1) out+="0001" ;; 2) out+="0010" ;; 3) out+="0011" ;;
            4) out+="0100" ;; 5) out+="0101" ;; 6) out+="0110" ;; 7) out+="0111" ;;
            8) out+="1000" ;; 9) out+="1001" ;; a) out+="1010" ;; b) out+="1011" ;;
            c) out+="1100" ;; d) out+="1101" ;; e) out+="1110" ;; f) out+="1111" ;;
            *) return 1 ;;
        esac
    done
    printf '%s\n' "$out"
}

# cidr_to_bin <cidr> → full binary string (32 or 128 chars) on stdout.
cidr_to_bin() {
    local cidr="$1" addr="${1%/*}"
    if [[ "$addr" == *:* ]]; then
        _nibbles_to_bin "$(expand_ipv6_nibbles "$addr")"
    else
        ipv4_to_bin "$addr"
    fi
}

# filter_novel_prefixes <candidates-file> <base-file>
# Echo candidates NOT contained in any base prefix (same family assumed).
# A candidate contained in a base range adds nothing — drop it.
filter_novel_prefixes() {
    local cand_file="$1" base_file="$2"
    # Plain temp files instead of process substitution: portable everywhere,
    # including minimal containers without a working /dev/fd.
    local base_tmp cand_tmp
    base_tmp="$(mktemp)"; cand_tmp="$(mktemp)"
    read_cidr_file "$base_file" > "$base_tmp" || true
    read_cidr_file "$cand_file" > "$cand_tmp" || true

    local -a base_lens=() base_bins=()
    local b blen bbin
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        blen="${b#*/}"
        bbin="$(cidr_to_bin "$b")" || continue
        base_lens+=("$blen")
        base_bins+=("$bbin")
    done < "$base_tmp"

    local c clen cbin i contained
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        clen="${c#*/}"
        cbin="$(cidr_to_bin "$c")" || continue
        contained=0
        for (( i=0; i<${#base_lens[@]}; i++ )); do
            if (( clen >= base_lens[i] )) && \
               [[ "${cbin:0:${base_lens[i]}}" == "${base_bins[i]:0:${base_lens[i]}}" ]]; then
                contained=1
                break
            fi
        done
        (( contained == 0 )) && printf '%s\n' "$c"
    done < "$cand_tmp"
    rm -f "$base_tmp" "$cand_tmp"
    return 0
}

# ---- Fetch helpers -------------------------------------------------------------
fetch_with_retry() {
    local url="$1" dest="$2" attempt
    for attempt in 1 2 3; do
        if curl --fail --silent --show-error --location \
                --max-time 25 --connect-timeout 10 \
                -A "cf-owntracks/${CFO_VERSION}" \
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

# ---- ASN failsafe ---------------------------------------------------------------
# Extract "prefix" values from RIPEstat / bgpview JSON without jq.
_extract_json_prefixes() {
    grep -oE '"prefix"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed 's/.*"\([^"]*\)"$/\1/'
}

# fetch_asn_prefixes <out-v4> <out-v6> <asn> [asn...]
# Union of announced prefixes for all ASNs. RIPEstat primary, bgpview fallback.
# Returns 0 if at least one source produced data for at least one ASN.
fetch_asn_prefixes() {
    local out_v4="$1" out_v6="$2"; shift 2
    local asn tmp got_any=0
    tmp="$(mktemp)"
    : > "$out_v4"
    : > "$out_v6"
    for asn in "$@"; do
        asn="${asn#AS}"
        [[ "$asn" =~ ^[0-9]+$ ]] || { log_warn "skipping invalid ASN: $asn"; continue; }
        local raw
        raw="$(mktemp)"
        if fetch_with_retry "${CFO_RIPESTAT_URL}${asn}" "$raw" && \
           grep -q '"prefix"' "$raw"; then
            log_info "ASN failsafe: AS${asn} prefixes via RIPEstat"
        elif fetch_with_retry "${CFO_BGPVIEW_URL}${asn}/prefixes" "$raw" && \
             grep -q '"prefix"' "$raw"; then
            log_info "ASN failsafe: AS${asn} prefixes via bgpview (fallback)"
        else
            log_warn "ASN failsafe: no source reachable for AS${asn}"
            rm -f "$raw"
            continue
        fi
        _extract_json_prefixes < "$raw" >> "$tmp"
        got_any=1
        rm -f "$raw"
    done
    if (( got_any == 0 )); then
        rm -f "$tmp"
        return 1
    fi
    # Split families, dedupe. Validation happens at the call site.
    grep -v ':' "$tmp" | sort -u > "$out_v4" || true
    grep ':'  "$tmp" | sort -u > "$out_v6" || true
    rm -f "$tmp"
    return 0
}

# ---- Config ------------------------------------------------------------------
# v2 keys (all persisted in $CFO_CONFIG_FILE):
#   CFO_MODE            test|deploy            (default test)
#   CFO_SERVER_NAME     public FQDN            (required)
#   CFO_OWNTRACKS_PORT  local recorder port    (default 8083)
#   CFO_FW_BACKEND      nftables|ufw|iptables  (required)
#   CFO_TLS_CERT/KEY    cert material          (required)
#   CFO_MTLS_ENABLED    1|0                    (default 1)
#   CFO_GLOBAL_REDIRECT 1|0                    (default 0)
#   CFO_ASN_FAILSAFE    1|0                    (default 1)
#   CFO_CF_ASNS         space-separated ASNs   (default "13335")
#   CFO_EXTRA_PORTS     space-separated ports  (default "")
#   CFO_TEST_LOG_MAX_MB decision log cap       (default 15)
load_config() {
    [[ -f "$CFO_CONFIG_FILE" ]] || die "config not found: $CFO_CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CFO_CONFIG_FILE"
    : "${CFO_SERVER_NAME:?CFO_SERVER_NAME missing from config}"
    : "${CFO_OWNTRACKS_PORT:=8083}"
    : "${CFO_MODE:=test}"
    : "${CFO_MTLS_ENABLED:=1}"
    : "${CFO_FW_BACKEND:?CFO_FW_BACKEND missing from config}"
    : "${CFO_TLS_CERT:?CFO_TLS_CERT missing from config}"
    : "${CFO_TLS_KEY:?CFO_TLS_KEY missing from config}"
    : "${CFO_GLOBAL_REDIRECT:=0}"
    : "${CFO_ASN_FAILSAFE:=1}"
    : "${CFO_CF_ASNS:=13335}"
    : "${CFO_EXTRA_PORTS:=}"
    : "${CFO_TEST_LOG_MAX_MB:=15}"
    case "$CFO_MODE" in
        test|deploy) : ;;
        *) die "invalid CFO_MODE in config: $CFO_MODE" ;;
    esac
}

# ---- Port discovery ------------------------------------------------------------
# Extract the port number from one nginx `listen` directive value.
_listen_to_port() {
    # Input examples: "80", "[::]:443 ssl http2", "0.0.0.0:8080", "443 ssl"
    local v="$1"
    v="${v%%;*}"
    # First whitespace-separated token is the address/port part.
    v="${v%% *}"
    if [[ "$v" == \[*\]:* ]]; then
        printf '%s\n' "${v##*:}"
    elif [[ "$v" == *.*.*.*:* ]]; then
        printf '%s\n' "${v##*:}"
    elif [[ "$v" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$v"
    fi
    # Bare-address forms (listen [::]; / listen 1.2.3.4;) default to 80 —
    # we don't emit those; our managed vhosts always specify a port.
}

# parse_managed_ports_from_dump <nginx-T-dump-file>
# Reads an `nginx -T` dump and emits the listen ports found in the config files
# this tool manages (owntracks vhost + optional global redirect), sorted unique.
parse_managed_ports_from_dump() {
    local dump="$1"
    local in_managed=0 line port
    while IFS= read -r line; do
        case "$line" in
            "# configuration file "*)
                if [[ "$line" == *"/owntracks.conf"* ]] || \
                   [[ "$line" == *"/00-cf-global-redirect.conf"* ]]; then
                    in_managed=1
                else
                    in_managed=0
                fi
                ;;
            *)
                if (( in_managed == 1 )) && [[ "$line" =~ ^[[:space:]]*listen[[:space:]]+(.+)$ ]]; then
                    port="$(_listen_to_port "${BASH_REMATCH[1]}")"
                    [[ -n "$port" ]] && printf '%s\n' "$port"
                fi
                ;;
        esac
    done < "$dump" | sort -un
}

# discover_managed_ports → space-separated port list on stdout.
# Falls back to cached ports, then to "80 443", warning on fallback.
discover_managed_ports() {
    local dump ports
    dump="$(mktemp)"
    if nginx -T > "$dump" 2>/dev/null; then
        ports="$(parse_managed_ports_from_dump "$dump" | tr '\n' ' ')"
        ports="${ports% }"
        rm -f "$dump"
        if [[ -n "$ports" ]]; then
            printf '%s\n' "$ports"
            return 0
        fi
        log_warn "nginx -T parsed but no managed vhost listen ports found"
    else
        rm -f "$dump"
        log_warn "nginx -T failed; falling back to cached/default ports"
    fi
    if [[ -s "$CFO_PORTS_FILE" ]]; then
        tr '\n' ' ' < "$CFO_PORTS_FILE" | sed 's/ $//'
        echo
        return 0
    fi
    printf '80 443\n'
}

# List ALL nginx listen ports (any vhost) — for the opt-in surface report.
discover_all_nginx_ports() {
    local dump line port
    dump="$(mktemp)"
    if ! nginx -T > "$dump" 2>/dev/null; then
        rm -f "$dump"
        return 1
    fi
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*listen[[:space:]]+(.+)$ ]]; then
            port="$(_listen_to_port "${BASH_REMATCH[1]}")"
            [[ -n "$port" ]] && printf '%s\n' "$port"
        fi
    done < "$dump" | sort -un
    rm -f "$dump"
}

# ---- Hostname discovery -----------------------------------------------------------
# Candidate hostnames from the OwnTracks recorder's own configuration — the
# best source, since the recorder knows the public URL it serves under.
# Priority inside each file: URL-shaped values (e.g. OTR_HTTPPREFIX) first,
# then FQDN-valued OTR_HOST (the MQTT broker — often the same domain).
# Bind addresses (localhost/127.x/0.0.0.0) are filtered out.
# Extra file arguments override the default search paths (for testing).
discover_owntracks_hostname() {
    local -a files=("$@")
    if (( ${#files[@]} == 0 )); then
        files=(/etc/default/ot-recorder /etc/ot-recorder/ot-recorder.conf /usr/local/etc/ot-recorder.conf)
    fi
    local f tmp
    tmp="$(mktemp)"
    for f in "${files[@]}"; do
        [[ -r "$f" ]] || continue
        # 1) hosts inside URL-shaped values (https://host/... or http://host:port)
        sed -n 's/.*https\?:\/\/\([A-Za-z0-9.-]*\).*/\1/p' "$f" >> "$tmp"
        # 2) bare hostname values of the interesting OTR_ variables
        sed -n "s/^[[:space:]]*OTR_\(HTTPPREFIX\|HOST\)[[:space:]]*=[[:space:]]*[\"']\?\([A-Za-z0-9.-]*\).*/\2/p" "$f" >> "$tmp"
    done
    # Order-preserving dedupe, keep only non-local FQDNs.
    awk '!seen[$0]++' "$tmp" \
        | grep -E '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' \
        | grep -viE '^(localhost|127\.|0\.0\.0\.0)' || true
    rm -f "$tmp"
    return 0
}

# All server_name values nginx knows about (any vhost), one per line, deduped.
# Filters out catch-alls (_, *, localhost, bare IPs) and non-FQDN tokens.
discover_nginx_hostnames() {
    local dump
    dump="$(mktemp)"
    if ! nginx -T > "$dump" 2>/dev/null; then
        rm -f "$dump"
        return 1
    fi
    sed -n 's/^[[:space:]]*server_name[[:space:]]\+\([^;]*\);.*/\1/p' "$dump" \
        | tr ' \t' '\n\n' \
        | grep -v '^$' \
        | grep -vE '^(_|\*|localhost)$' \
        | grep -vE '^[0-9.]+$' \
        | grep -E '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' \
        | sort -u
    rm -f "$dump"
    return 0
}

# Public IP of this box: Cloudflare's own trace endpoint, ipify fallback.
detect_public_ip() {
    local ip
    ip="$(curl -fsS --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
        | sed -n 's/^ip=//p' | head -1)"
    if [[ -z "$ip" ]]; then
        ip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    fi
    [[ -n "$ip" ]] || return 1
    printf '%s\n' "$ip"
}

# Reverse DNS (PTR) for an IP. Tries getent (NSS, always present), then
# host/dig if installed. Echoes the name without trailing dot, or fails.
reverse_dns() {
    local ip="$1" name=""
    name="$(getent hosts "$ip" 2>/dev/null | awk '{print $2}' | head -1)"
    if [[ -z "$name" ]] && command -v host >/dev/null 2>&1; then
        name="$(host "$ip" 2>/dev/null | sed -n 's/.*pointer \(.*\)\.$/\1/p' | head -1)"
    fi
    if [[ -z "$name" ]] && command -v dig >/dev/null 2>&1; then
        name="$(dig +short -x "$ip" 2>/dev/null | sed 's/\.$//' | head -1)"
    fi
    [[ -n "$name" ]] || return 1
    printf '%s\n' "$name"
}

# ---- SSH port detection ----------------------------------------------------------
# Union of sshd_config Port directives (+ conf.d includes) and live sshd listeners.
# Always emits at least "22".
detect_ssh_ports() {
    {
        local f
        for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
            [[ -r "$f" ]] || continue
            sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' "$f"
        done
        # Live sshd listeners (root can see process names).
        if command -v ss >/dev/null 2>&1; then
            ss -ltnpH 2>/dev/null | grep -F '"sshd"' | \
                sed -n 's/.*[]:.]\([0-9]\+\)[[:space:]].*users:.*/\1/p'
        fi
        echo 22
    } | grep -E '^[0-9]+$' | sort -un
}

# build_managed_ports <vhost-ports> <extra-ports> <ssh-ports>
# All args space-separated lists. Emits final managed set (ssh subtracted).
# Warns loudly when an SSH port had to be excluded.
build_managed_ports() {
    local vhost_ports="$1" extra_ports="$2" ssh_ports="$3"
    local -A ssh_set=()
    local p
    for p in $ssh_ports; do ssh_set["$p"]=1; done
    local out=()
    for p in $vhost_ports $extra_ports; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        if [[ -n "${ssh_set[$p]:-}" ]]; then
            log_warn "SSH GUARD: port $p is an SSH port — excluded from managed set (SSH always wins)"
            continue
        fi
        out+=("$p")
    done
    printf '%s\n' "${out[@]}" | sort -un | tr '\n' ' ' | sed 's/ $//'
    echo
}

# ---- Allowlist ---------------------------------------------------------------------
# Read the operator allowlist file; normalize bare IPs to host CIDRs; validate.
# read_allowlist <family> → validated CIDRs for that family on stdout.
read_allowlist() {
    local family="$1"
    [[ -f "$CFO_ALLOWLIST_FILE" ]] || return 0
    local tmp line norm
    tmp="$(mktemp)"
    read_cidr_file "$CFO_ALLOWLIST_FILE" > "$tmp" || true
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        norm="$(normalize_cidr "$line")"
        case "$family" in
            v4) [[ "$norm" != *:* ]] && is_valid_cidr_v4 "$norm" && printf '%s\n' "$norm" ;;
            v6) [[ "$norm" == *:* ]] && is_valid_cidr_v6 "$norm" && printf '%s\n' "$norm" ;;
        esac
    done < "$tmp"
    rm -f "$tmp"
    return 0
}

# ---- Decision log rotation ------------------------------------------------------
# rotate_decision_log <max-mb> — rotate when oversize; keep one archive.
rotate_decision_log() {
    local max_mb="$1"
    [[ -f "$CFO_DECISION_LOG" ]] || return 0
    local size max_bytes
    size="$(stat -c %s "$CFO_DECISION_LOG" 2>/dev/null || echo 0)"
    max_bytes=$(( max_mb * 1024 * 1024 ))
    if (( size > max_bytes )); then
        log_info "rotating decision log (${size} bytes > ${max_bytes})"
        mv -f "$CFO_DECISION_LOG" "${CFO_DECISION_LOG}.1"
        # Ask nginx to reopen log files so it writes to a fresh one.
        if command -v nginx >/dev/null 2>&1; then
            nginx -s reopen 2>/dev/null || true
        fi
    fi
    return 0
}

# ---- Firewall backend detection ---------------------------------------------
# Echoes one of: ufw, nftables, iptables, none.  Non-zero exit if ambiguous.
# Our own table (inet cf_owntracks) is excluded so re-detection after install
# doesn't report "nftables" on a ufw/iptables box.
detect_firewall() {
    local active=()

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        active+=("ufw")
    fi

    if [[ ! " ${active[*]} " =~ " ufw " ]] && command -v nft >/dev/null 2>&1; then
        local nft_tables nft_native
        nft_tables=$(nft list tables 2>/dev/null || true)
        nft_native=$(printf '%s\n' "$nft_tables" \
            | grep -vE '^table[[:space:]]+inet[[:space:]]+cf_owntracks$' \
            | grep -vE '^table[[:space:]]+(ip|ip6)[[:space:]]+ufw(-|$)' \
            | grep -vE '^table[[:space:]]+(ip|ip6)[[:space:]]+(filter|nat|mangle|raw|security)$' \
            | grep -v '^[[:space:]]*$' || true)
        if [[ -n "$nft_native" ]]; then
            active+=("nftables")
        fi
    fi

    if [[ ! " ${active[*]} " =~ " ufw " ]] && [[ ! " ${active[*]} " =~ " nftables " ]] && \
       command -v iptables >/dev/null 2>&1; then
        local ipt_rules
        ipt_rules=$(iptables -S 2>/dev/null \
            | grep -vE '^-P (INPUT|OUTPUT|FORWARD) ACCEPT$' \
            | grep -v 'CF-OWNTRACKS' || true)
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

# ---- SSH reachability heuristic ------------------------------------------------
check_ssh_reachable() {
    local backend="$1"
    local ports
    ports="$(detect_ssh_ports | tr '\n' ' ')"
    local port ok=0
    for port in $ports; do
        case "$backend" in
            ufw)
                # Numeric rules AND named app profiles (OpenSSH, SSH).
                if ufw status 2>/dev/null | grep -qiE "(^|[[:space:]])(${port}(/tcp)?|OpenSSH|\bSSH\b)[[:space:]].*ALLOW"; then
                    ok=1; break
                fi
                ;;
            nftables)
                local rs
                rs=$(nft list ruleset 2>/dev/null) || continue
                if grep -qE "tcp dport ${port}[^0-9].*accept" <<<"$rs" || \
                   grep -qE "tcp dport \{[^}]*\b${port}\b[^}]*\}.*accept" <<<"$rs" || \
                   grep -qE 'hook input.*policy accept' <<<"$rs"; then
                    ok=1; break
                fi
                ;;
            iptables)
                if iptables -S INPUT 2>/dev/null | grep -qE "dport ${port}[^0-9].*ACCEPT" || \
                   iptables -S 2>/dev/null | grep -qE '^-P INPUT ACCEPT$'; then
                    ok=1; break
                fi
                ;;
            none)
                ok=1; break
                ;;
        esac
    done
    (( ok == 1 ))
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
write_atomic() {
    local dest="$1"
    local tmp="${dest}.tmp.$$"
    cat > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$dest"
}
