#!/usr/bin/env bash
# =============================================================================
# cf-owntracks: common helpers sourced by the installer and the refresh daemon.
#
# This file is SOURCED (loaded into another script with `source file`), not
# executed on its own. That's why there is no `set -e` here: those settings
# would leak into whichever script loads us.
#
# v2.1.0 — mode model (test/deploy), dynamic port discovery, SSH guarantee,
# localhost + allowlist, ASN failsafe, NDJSON decision log.
# =============================================================================
#
# ---------------------------------------------------------------------------
# A SHORT GUIDE TO THE BASH IDIOMS USED THROUGHOUT THIS PROJECT
# (every other script in this repo points here instead of re-explaining)
# ---------------------------------------------------------------------------
#
#   local x="$1"        Inside a function: make x private to the function and
#                       set it to the first argument. "$1" is argument #1.
#
#   "${var:-default}"   Use $var, or "default" when var is unset/empty.
#   "${var:?message}"   Abort with "message" when var is unset/empty.
#   "${var%/*}"         $var with the shortest trailing "/anything" removed
#                       (e.g. "1.2.3.0/24" -> "1.2.3.0"). % trims from the END.
#   "${var#*/}"         $var with the shortest leading "anything/" removed
#                       (e.g. "1.2.3.0/24" -> "24"). # trims from the START.
#   "${var//a/b}"       $var with every "a" replaced by "b".
#   "${var,,}"          $var lowercased.
#   "${#var}"           Length of $var in characters.
#   "${var:0:5}"        First five characters of $var (substring: offset 0, length 5).
#
#   [[ ... ]]           Bash's test/conditional. Common operators:
#                         -z "$x"   true when $x is empty
#                         -n "$x"   true when $x is non-empty
#                         -f file   file exists and is a regular file
#                         -s file   file exists and is non-empty
#                         -r file   file exists and is readable
#                         =~        regular-expression match; captured groups
#                                   land in the BASH_REMATCH array
#                         == with * unquoted on the right = glob (wildcard) match
#
#   (( ... ))           Arithmetic context: (( a > b )), x=$(( a + b )).
#
#   $(command)          "Command substitution": run command, use its output.
#
#   cmd1 || cmd2        Run cmd2 only when cmd1 FAILS (non-zero exit).
#   cmd1 && cmd2        Run cmd2 only when cmd1 SUCCEEDS (zero exit).
#   cmd || true         Ignore cmd's failure ("|| true" always succeeds) —
#                       needed under `set -e`, which otherwise kills the
#                       script on any failing command.
#
#   >file  2>file       Redirect stdout / stderr to a file.
#   2>/dev/null         Throw stderr away.
#   2>&1                Send stderr wherever stdout currently goes.
#   <<<"$x"             "Here-string": feed $x to the command's stdin.
#   <<EOF ... EOF       "Heredoc": feed the following lines to stdin. With
#                       quotes ('EOF') variables inside are NOT expanded;
#                       without quotes they ARE.
#
#   while IFS= read -r line; do ...; done < file
#                       Read a file line by line. IFS= keeps leading spaces,
#                       -r stops backslashes being interpreted. We read from
#                       plain temp files rather than <(process substitution)
#                       because /dev/fd may be missing in minimal containers.
#
#   printf '%s\n' "$x"  Like echo but predictable with dashes/backslashes.
#   printf -v var ...   printf into a variable instead of stdout.
#
#   comments of the form "shellcheck disable=SC<number>" (seen above some
#                       lines) instruct the "shellcheck" linter to skip a
#                       specific warning where we are intentionally doing
#                       something it dislikes.
# ---------------------------------------------------------------------------
#
# Most CFO_* constants below are referenced from other files that source this
# one; shellcheck can't see those cross-file references.
# shellcheck disable=SC2034

# ---- Version -------------------------------------------------------------------
CFO_VERSION="2.2.2"

# ---- Paths -------------------------------------------------------------------
# The ${VAR:-default} pattern lets tests (or unusual installs) override any of
# these by exporting the variable before sourcing this file.
CFO_LIB_DIR="${CFO_LIB_DIR:-/usr/local/lib/cf-owntracks}"
CFO_CONFIG_FILE="${CFO_CONFIG_FILE:-/etc/cf-owntracks/config}"
CFO_ALLOWLIST_FILE="${CFO_ALLOWLIST_FILE:-/etc/cf-owntracks/allowlist}"
CFO_STATE_DIR="${CFO_STATE_DIR:-/var/lib/cf-owntracks}"
CFO_BACKUP_DIR="${CFO_BACKUP_DIR:-/var/backups/cf-owntracks}"
CFO_LOCK_FILE="${CFO_LOCK_FILE:-/run/cf-owntracks.lock}"
CFO_LOG_DIR="${CFO_LOG_DIR:-/var/log/cf-owntracks}"
CFO_DECISION_LOG="${CFO_LOG_DIR}/decisions.ndjson"

# nginx pieces this project owns (generated/managed by the daemon+installer).
CFO_NGINX_MAPS_CONF="/etc/nginx/conf.d/cf-owntracks-maps.conf"
CFO_NGINX_REALIP_SNIPPET="/etc/nginx/snippets/cloudflare-realip.conf"
CFO_NGINX_ENFORCE_SNIPPET="/etc/nginx/snippets/cloudflare-enforce.conf"
CFO_NGINX_MTLS_SNIPPET="/etc/nginx/snippets/cloudflare-mtls.conf"
CFO_NGINX_LEGACY_ALLOW_SNIPPET="/etc/nginx/snippets/cloudflare-allow.conf"  # v1 leftover
CFO_NGINX_VHOST="/etc/nginx/sites-available/owntracks.conf"
CFO_NGINX_VHOST_ENABLED="/etc/nginx/sites-enabled/owntracks.conf"
CFO_NGINX_GLOBAL_REDIRECT="/etc/nginx/sites-available/00-cf-global-redirect.conf"
CFO_NGINX_GLOBAL_REDIRECT_ENABLED="/etc/nginx/sites-enabled/00-cf-global-redirect.conf"

# Authenticated Origin Pulls (Cloudflare mTLS) client-CA material.
CFO_AOP_CA_FILE="/etc/ssl/cloudflare/authenticated_origin_pull_ca.pem"
CFO_AOP_CA_HASH="${CFO_STATE_DIR}/origin-pull-ca.sha256"
CFO_AOP_CA_URL="https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem"

# Cloudflare's published edge IP lists (the PRIMARY data source) and where we
# cache the last successfully-applied copies ("last known good").
CFO_IPS_V4_URL="https://www.cloudflare.com/ips-v4"
CFO_IPS_V6_URL="https://www.cloudflare.com/ips-v6"
CFO_IPS_V4_FILE="${CFO_STATE_DIR}/ips-v4.last"
CFO_IPS_V6_FILE="${CFO_STATE_DIR}/ips-v6.last"
CFO_ASN_V4_FILE="${CFO_STATE_DIR}/asn-v4.last"
CFO_ASN_V6_FILE="${CFO_STATE_DIR}/asn-v6.last"
CFO_PORTS_FILE="${CFO_STATE_DIR}/ports.last"

# BGP data sources for the ASN failsafe (the ASN number gets appended).
CFO_RIPESTAT_URL="https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS"
CFO_BGPVIEW_URL="https://api.bgpview.io/asn/"

# Sanity thresholds: bail out rather than apply suspicious data.
CFO_MIN_V4_RANGES=5      # published v4 list must have at least this many entries
CFO_MIN_V6_RANGES=3      # ... and v6 this many
CFO_MAX_DELTA_PCT=50     # refuse if the list changed by more than half
# ASN failsafe: cap the novel set so a poisoned source can't flood the ruleset.
# Reality check (2026-07): AS13335's real novel set is ~930 prefixes (761 v4 +
# 167 v6 beyond the published lists), so the cap needs comfortable headroom
# above that while still catching a poisoned source dumping tens of thousands.
CFO_MAX_ASN_NOVEL=2000
# ufw rule-count warning threshold (ufw makes one rule per CIDR — it gets big).
CFO_UFW_RULE_WARN=200

# ---- Logging -----------------------------------------------------------------
# One line goes to stderr (so you see it in the terminal) AND to the systemd
# journal via `logger` (so `journalctl -t cf-owntracks` finds it later).
_cfo_log() {
    local level="$1"; shift          # first arg = level; the rest = message
    local msg="$*"                   # "$*" joins all remaining args into one string
    local tag="cf-owntracks"
    printf '[%s] %s: %s\n' "$(date -u +%FT%TZ)" "$level" "$msg" >&2
    # `command -v x` = "does the command x exist?" — silent when logger is absent.
    if command -v logger >/dev/null 2>&1; then
        # ${level,,} lowercases the level to make a syslog priority like "user.info".
        logger -t "$tag" -p "user.${level,,}" -- "$msg" 2>/dev/null || true
    fi
}
log_info()  { _cfo_log "INFO"  "$@"; }
log_warn()  { _cfo_log "WARN"  "$@"; }
log_error() { _cfo_log "ERR"   "$@"; }
die()       { _cfo_log "ERR"   "$@"; exit 1; }   # log the error, then stop the script

# ---- Privilege ---------------------------------------------------------------
# EUID is bash's "effective user id"; 0 means root.
require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "must run as root (got uid $EUID)"
    fi
}

# ---- CIDR validation ---------------------------------------------------------
# A "CIDR" is an IP range written as address/prefix-length, e.g. 104.16.0.0/13.
# These validators are strict on purpose: everything we feed to the firewall
# comes from the network, so malformed input must be rejected, not guessed at.

is_valid_cidr_v4() {
    # Shape check first: four dot-separated 1-3 digit groups, slash, 1-2 digits.
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
    local ip="${1%/*}" mask="${1#*/}"       # split "a.b.c.d/nn" into ip + mask
    (( mask >= 0 && mask <= 32 )) || return 1
    # Setting IFS (the field separator) to "." makes the unquoted expansion
    # below split the address into its four octets.
    local IFS=.
    # shellcheck disable=SC2206
    local parts=($ip)
    local p
    for p in "${parts[@]}"; do              # each octet must be 0..255
        (( p >= 0 && p <= 255 )) || return 1
    done
    return 0
}

is_valid_cidr_v6() {
    # IPv6 is harder: hex groups separated by ":", with "::" allowed ONCE as a
    # shorthand for "one or more all-zero groups".
    [[ "$1" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]] || return 1
    local mask="${1#*/}"
    (( mask >= 0 && mask <= 128 )) || return 1
    local addr="${1%/*}"
    # ":::" (three or more colons in a row) is never legal.
    [[ "$addr" == *":::"* ]] && return 1
    # Count the colons by deleting everything that isn't one and measuring.
    local colons="${addr//[^:]/}"
    (( ${#colons} >= 2 && ${#colons} <= 7 )) || return 1
    # Count occurrences of "::" — at most one allowed. The loop chops the
    # string after each "::" it finds and counts how many times that worked.
    local rest="$addr" dcount=0
    while [[ "$rest" == *"::"* ]]; do
        dcount=$((dcount + 1))
        rest="${rest#*::}"
    done
    (( dcount <= 1 )) || return 1
    # Finally: every colon-separated group must be 0-4 hex characters.
    local IFS=:
    # shellcheck disable=SC2206
    local groups=($addr)
    local g
    for g in "${groups[@]}"; do
        [[ "$g" =~ ^[0-9a-fA-F]{0,4}$ ]] || return 1
    done
    return 0
}

# Accepts a bare address too (no /mask) and normalizes to a host CIDR:
# "1.2.3.4" -> "1.2.3.4/32", "2001:db8::1" -> "2001:db8::1/128".
normalize_cidr() {
    local c="$1"
    if [[ "$c" == */* ]]; then           # already has a mask — pass through
        printf '%s\n' "$c"
    elif [[ "$c" == *:* ]]; then         # contains ":" — it's IPv6
        printf '%s/128\n' "$c"
    else                                  # otherwise assume IPv4
        printf '%s/32\n' "$c"
    fi
}

# Read a list file: strip "# comments" and whitespace, drop blank lines.
read_cidr_file() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    # sed does the cleanup; the final grep drops now-empty lines. `|| true`
    # because grep exits non-zero when NOTHING matches, and an empty list is
    # not an error for us.
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$f" | grep -v '^$' || true
}

# Validate a list of CIDRs arriving on stdin. Valid lines are echoed through;
# the function fails (non-zero) if ANY line is invalid or none are valid.
# Used for the published Cloudflare lists where we want all-or-nothing.
validate_cidr_list() {
    local family="$1"                    # "v4" or "v6"
    local validator
    case "$family" in
        v4) validator=is_valid_cidr_v4 ;;
        v6) validator=is_valid_cidr_v6 ;;
        *) die "validate_cidr_list: bad family $family" ;;
    esac
    local line bad=0 ok=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # "$validator" holds a FUNCTION NAME; calling a variable runs it.
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
# To decide whether one CIDR range is contained inside another we expand
# addresses to strings of "0"/"1" characters and compare the first N bits as a
# plain string prefix. Slower than real bit math, but pure bash and identical
# for IPv4 (32 chars) and IPv6 (128 chars).

# Convert an IPv4 address to a 32-char binary string, e.g.
# 255.0.0.1 -> 11111111000000000000000000000001
ipv4_to_bin() {
    local ip="$1" out="" o b
    local IFS=.
    # shellcheck disable=SC2206
    local octets=($ip)
    for o in "${octets[@]}"; do
        # For each octet, extract its 8 bits from most to least significant:
        # (o >> b) shifts right by b, "& 1" keeps only the lowest bit.
        for (( b=7; b>=0; b-- )); do
            out+=$(( (o >> b) & 1 ))
        done
    done
    printf '%s\n' "$out"
}

# Expand an IPv6 address (:: shorthand allowed) to exactly 32 lowercase hex
# characters ("nibbles"), e.g. 2606:4700:: -> 26064700000000000000000000000000
expand_ipv6_nibbles() {
    local addr="${1,,}" left right         # ${1,,} = lowercase the input
    local -a lg=() rg=()                   # groups left / right of the "::"
    if [[ "$addr" == *"::"* ]]; then
        left="${addr%%::*}"                # %%::* = everything before the ::
        right="${addr##*::}"               # ##*:: = everything after the ::
        # `read -a array <<< string` splits the string into an array using IFS.
        [[ -n "$left"  ]] && IFS=: read -r -a lg <<<"$left"
        [[ -n "$right" ]] && IFS=: read -r -a rg <<<"$right"
    else
        IFS=: read -r -a lg <<<"$addr"
    fi
    # The "::" stands for however many all-zero groups are needed to reach 8.
    local total=$(( ${#lg[@]} + ${#rg[@]} ))
    local fill=$(( 8 - total ))
    local -a groups=()
    groups+=("${lg[@]}")
    local i
    for (( i=0; i<fill; i++ )); do groups+=("0"); done
    groups+=("${rg[@]}")
    # Zero-pad each group to 4 hex chars: "%04s" right-aligns in width 4 with
    # spaces, then ${g// /0} turns those spaces into zeros.
    local out="" g
    for g in "${groups[@]}"; do
        printf -v g '%04s' "$g"
        out+="${g// /0}"
    done
    printf '%s\n' "$out"
}

# Convert 32 hex nibbles to a 128-char binary string (4 bits per nibble).
_nibbles_to_bin() {
    local nibbles="$1" out="" n
    local i
    for (( i=0; i<${#nibbles}; i++ )); do
        n="${nibbles:i:1}"                 # the i-th character
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

# cidr_to_bin <cidr> → the address part as a full binary string
# (32 chars for IPv4, 128 for IPv6) on stdout.
cidr_to_bin() {
    local cidr="$1" addr="${1%/*}"
    if [[ "$addr" == *:* ]]; then
        _nibbles_to_bin "$(expand_ipv6_nibbles "$addr")"
    else
        ipv4_to_bin "$addr"
    fi
}

# filter_novel_prefixes <candidates-file> <base-file>
# Echo the candidate CIDRs that are NOT contained in any base CIDR.
# "Contained" means: candidate's prefix length >= base's, and their first
# base-length bits are identical. A contained candidate adds nothing to the
# allow set (the base range already covers it), so we drop it.
filter_novel_prefixes() {
    local cand_file="$1" base_file="$2"
    # Plain temp files instead of process substitution: portable everywhere,
    # including minimal containers without a working /dev/fd.
    local base_tmp cand_tmp
    base_tmp="$(mktemp)"; cand_tmp="$(mktemp)"
    read_cidr_file "$base_file" > "$base_tmp" || true
    read_cidr_file "$cand_file" > "$cand_tmp" || true

    # First pass: pre-compute every base range's prefix length and binary form
    # into two parallel arrays (index i of one matches index i of the other).
    local -a base_lens=() base_bins=()
    local b blen bbin
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        blen="${b#*/}"
        bbin="$(cidr_to_bin "$b")" || continue
        base_lens+=("$blen")
        base_bins+=("$bbin")
    done < "$base_tmp"

    # Second pass: for each candidate, compare against every base range.
    local c clen cbin i contained
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        clen="${c#*/}"
        cbin="$(cidr_to_bin "$c")" || continue
        contained=0
        for (( i=0; i<${#base_lens[@]}; i++ )); do
            # ${cbin:0:N} = first N bits of the candidate; if they equal the
            # base's first N bits (and the candidate is at least as specific),
            # the candidate lives inside the base range.
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
# Download a URL to a file, retrying up to 3 times with a growing pause.
# curl flags: --fail = treat HTTP errors as failures, --silent --show-error =
# quiet except real errors, --location = follow redirects, -A = User-Agent.
fetch_with_retry() {
    local url="$1" dest="$2" attempt
    for attempt in 1 2 3; do
        if curl --fail --silent --show-error --location \
                --max-time 25 --connect-timeout 10 \
                -A "cf-owntracks/${CFO_VERSION}" \
                "$url" -o "$dest"; then
            if [[ -s "$dest" ]]; then     # -s = file exists AND is non-empty
                return 0
            fi
            log_warn "fetch ${url}: empty response (attempt ${attempt})"
        else
            log_warn "fetch ${url}: curl failed (attempt ${attempt})"
        fi
        sleep $(( attempt * 2 ))          # back off: 2s, then 4s
    done
    return 1
}

# Compare a freshly-fetched list against the cached last-known-good copy and
# refuse changes that look implausibly large (a wrong/hijacked answer should
# not be able to rewrite the whole firewall in one tick).
check_delta() {
    local new_file="$1" old_file="$2" family="$3"
    if [[ ! -f "$old_file" ]]; then
        log_info "no prior ${family} list; accepting new list"
        return 0
    fi
    local old_count new_count added removed total max_count delta_pct
    old_count=$(grep -c . "$old_file" || true)     # grep -c . = count non-empty lines
    new_count=$(grep -c . "$new_file" || true)
    # `comm` compares two SORTED lists: -23 = lines only in the first,
    # -13 = lines only in the second. That gives us adds and removals.
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
# Pull every "prefix":"..." value out of a JSON blob WITHOUT a JSON parser:
# grep -oE prints just the matching part of each line; sed keeps what's
# between the final pair of quotes. Works for both RIPEstat and bgpview
# response shapes because both use a "prefix" key.
_extract_json_prefixes() {
    grep -oE '"prefix"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed 's/.*"\([^"]*\)"$/\1/'
}

# fetch_asn_prefixes <out-v4> <out-v6> <asn> [asn...]
# Union of announced prefixes for all ASNs. RIPEstat primary, bgpview fallback.
# Returns 0 if at least one source produced data for at least one ASN.
fetch_asn_prefixes() {
    local out_v4="$1" out_v6="$2"; shift 2   # shift 2 = drop the first two args;
    local asn tmp got_any=0                  # "$@" is now just the ASN list
    tmp="$(mktemp)"
    : > "$out_v4"                            # ": > file" truncates/creates a file
    : > "$out_v6"
    for asn in "$@"; do
        asn="${asn#AS}"                      # accept "AS13335" or "13335"
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
    # Split into families by the presence of ":" (only IPv6 has colons),
    # dedupe with sort -u. Validation happens at the call site.
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
    # The config file is itself a shell fragment (VAR=value lines), so
    # loading it is just sourcing it.
    # shellcheck disable=SC1090
    source "$CFO_CONFIG_FILE"
    # ": ${VAR:?msg}" = abort with msg if VAR missing; ": ${VAR:=x}" = default it.
    # The leading ":" is a no-op command that exists just to host the expansion.
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
    : "${CFO_ATTACH_VHOST:=}"
    case "$CFO_MODE" in
        test|deploy) : ;;
        *) die "invalid CFO_MODE in config: $CFO_MODE" ;;
    esac
}

# ---- Port discovery ------------------------------------------------------------
# The firewall protects "the ports nginx actually serves the managed vhosts
# on" — discovered from nginx's own configuration, not hardcoded.

# Extract the port number from one nginx `listen` directive value.
_listen_to_port() {
    # Input examples: "80", "[::]:443 ssl http2", "0.0.0.0:8080", "443 ssl"
    local v="$1"
    v="${v%%;*}"          # drop everything from the ";" on
    # First whitespace-separated token is the address/port part.
    v="${v%% *}"
    if [[ "$v" == \[*\]:* ]]; then          # "[v6addr]:port" form
        printf '%s\n' "${v##*:}"            # ##*: = keep only after the LAST ":"
    elif [[ "$v" == *.*.*.*:* ]]; then      # "v4addr:port" form
        printf '%s\n' "${v##*:}"
    elif [[ "$v" =~ ^[0-9]+$ ]]; then       # bare "port" form
        printf '%s\n' "$v"
    fi
    # Bare-address forms (listen [::]; / listen 1.2.3.4;) default to 80 —
    # we don't emit those; our managed vhosts always specify a port.
}

# parse_managed_ports_from_dump <nginx-T-dump-file> [attached-vhost-path]
# Reads an `nginx -T` dump and emits the listen ports found in the config files
# this tool manages (owntracks vhost + optional global redirect + the operator
# vhost named by --attach-vhost, when set), sorted unique.
# `nginx -T` marks each file's content with a "# configuration file <path>:"
# header line — the loop below tracks whether we are inside one of OUR files.
parse_managed_ports_from_dump() {
    local dump="$1" attach="${2:-}"
    local in_managed=0 line port
    while IFS= read -r line; do
        case "$line" in
            "# configuration file "*)
                if [[ "$line" == *"/owntracks.conf"* ]] || \
                   [[ "$line" == *"/00-cf-global-redirect.conf"* ]] || \
                   { [[ -n "$attach" ]] && [[ "$line" == "# configuration file ${attach}:" ]]; }; then
                    in_managed=1
                else
                    in_managed=0
                fi
                ;;
            *)
                # Inside a managed file: pick the value out of "listen ...;"
                # lines (the regex capture lands in BASH_REMATCH[1]).
                if (( in_managed == 1 )) && [[ "$line" =~ ^[[:space:]]*listen[[:space:]]+(.+)$ ]]; then
                    port="$(_listen_to_port "${BASH_REMATCH[1]}")"
                    [[ -n "$port" ]] && printf '%s\n' "$port"
                fi
                ;;
        esac
    done < "$dump" | sort -un
}

# discover_managed_ports → space-separated port list on stdout.
# Includes the attached vhost's ports when CFO_ATTACH_VHOST is configured.
# Falls back to cached ports, then to "80 443", warning on fallback.
discover_managed_ports() {
    local dump ports
    dump="$(mktemp)"
    if nginx -T > "$dump" 2>/dev/null; then
        ports="$(parse_managed_ports_from_dump "$dump" "${CFO_ATTACH_VHOST:-}" | tr '\n' ' ')"
        ports="${ports% }"          # trim the trailing space tr left behind
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

# List ALL nginx listen ports (any vhost) — for the opt-in surface report the
# diagnostics print ("these other ports exist but are untouched").
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
        # 1) hosts inside URL-shaped values (https://host/... or http://host:port).
        #    The sed capture group grabs just the hostname characters after "://".
        sed -n 's/.*https\?:\/\/\([A-Za-z0-9.-]*\).*/\1/p' "$f" >> "$tmp"
        # 2) bare hostname values of the interesting OTR_ variables
        #    (works with either quoting style or none at all).
        sed -n "s/^[[:space:]]*OTR_\(HTTPPREFIX\|HOST\)[[:space:]]*=[[:space:]]*[\"']\?\([A-Za-z0-9.-]*\).*/\2/p" "$f" >> "$tmp"
    done
    # awk '!seen[$0]++' = keep the FIRST occurrence of each line (an
    # order-preserving dedupe — URL-derived names stay ahead of OTR_HOST).
    # Then keep only things that look like real multi-label hostnames and
    # are not local/bind addresses.
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
    # `nginx -T` prints the ENTIRE merged configuration nginx would run with.
    if ! nginx -T > "$dump" 2>/dev/null; then
        rm -f "$dump"
        return 1
    fi
    # server_name lines can carry several names: "server_name a b c;".
    # sed grabs the value part, tr splits multiple names onto their own lines.
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
    # cdn-cgi/trace returns plain "key=value" lines; we want the "ip=" one.
    ip="$(curl -fsS --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
        | sed -n 's/^ip=//p' | head -1)"
    if [[ -z "$ip" ]]; then
        ip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    fi
    [[ -n "$ip" ]] || return 1
    printf '%s\n' "$ip"
}

# Reverse DNS (PTR) for an IP. Tries getent (part of glibc, always present),
# then host/dig if installed. Echoes the name without trailing dot, or fails.
reverse_dns() {
    local ip="$1" name=""
    # getent prints "IP  hostname"; awk grabs the second column.
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

# ---- Attach mode: layer includes into an operator-owned vhost ----------------------
# When a box already has a rich, hand-crafted vhost for the OwnTracks host
# (auth, PHP frontend, custom locations), generating our own vhost creates a
# "conflicting server name" — nginx ignores one of them (found in production
# 2026-07-08). Attach mode is the answer: inject our three include lines into
# THEIR vhost instead, delimited by marker comments so the operation is
# idempotent and cleanly reversible.

CFO_ATTACH_MARKER_BEGIN="# >>> cf-owntracks includes (managed) >>>"
CFO_ATTACH_MARKER_END="# <<< cf-owntracks includes <<<"

# _strip_cfo_includes <vhost-file>
# Removes ALL prior cf-owntracks include traces from a vhost, whatever their
# origin: our marker-delimited block, bare `include .../cloudflare-*.conf;`
# lines added by hand, and the "# --- cf-owntracks protection ---" comment a
# manual setup might carry. This is what makes attach idempotent against a
# file that already has includes from any source — without it, a second set
# would double-include a snippet and duplicate `real_ip_header` (which nginx
# rejects; hit in production 2026-07-08 on a hand-edited vhost).
_strip_cfo_includes() {
    local vf="$1" tmp
    tmp="$(mktemp)"
    # `\#...#` uses '#' as the sed delimiter so the '/' in paths needs no
    # escaping. First expression deletes the whole marker block as a range;
    # the rest delete any stray snippet includes and our manual comment line.
    sed -e '/>>> cf-owntracks includes (managed) >>>/,/<<< cf-owntracks includes <<</d' \
        -e '\#include[^;]*snippets/cloudflare-realip\.conf#d' \
        -e '\#include[^;]*snippets/cloudflare-mtls\.conf#d' \
        -e '\#include[^;]*snippets/cloudflare-enforce\.conf#d' \
        -e '/# --- cf-owntracks protection/d' \
        "$vf" > "$tmp"
    cat "$tmp" > "$vf"
    rm -f "$tmp"
}

# attach_vhost_includes <vhost-file>
# Strips any prior cf-owntracks includes, then inserts exactly one include
# stanza after the FIRST server_name directive of each server block (one per
# block — a duplicate real_ip_header would fail nginx -t). Validates with
# nginx -t afterwards; on failure the original file is restored and we die.
# A one-time backup is left at <file>.pre-cfo.
attach_vhost_includes() {
    local vf="$1"
    [[ -f "$vf" ]] || die "attach-vhost: file not found: $vf"
    grep -qE '^[[:space:]]*server[[:space:]{]' "$vf" || die "attach-vhost: no server block found in $vf"

    # Back the file up OUTSIDE any nginx-scanned directory. Debian's nginx
    # includes sites-enabled/* (EVERY file, not just *.conf), so a backup left
    # next to the vhost is itself loaded as a duplicate server for the same
    # name — a "conflicting server name" that can shadow the real vhost (hit
    # in production 2026-07-08). The state dir is never scanned by nginx.
    local bak
    bak="${CFO_STATE_DIR}/$(basename "$vf").pre-cfo"
    mkdir -p "$CFO_STATE_DIR"
    # Migrate + remove any stray backup a buggy earlier version dropped beside
    # the vhost (that stray is exactly what causes the conflict).
    if [[ -f "${vf}.pre-cfo" ]]; then
        [[ -f "$bak" ]] || cp -p "${vf}.pre-cfo" "$bak"
        rm -f "${vf}.pre-cfo"
    fi
    # First-seen copy, never overwritten once created.
    [[ -f "$bak" ]] || cp -p "$vf" "$bak"

    # Clean slate: remove any existing cf-owntracks includes (marker block,
    # bare includes, manual comment) so we never end up with two sets.
    _strip_cfo_includes "$vf"

    local tmp
    tmp="$(mktemp)"
    # awk walks the file: entering a server block resets the "done" flag; the
    # first server_name line of each block gets the include stanza appended.
    # (mawk-compatible: plain patterns and print only.)
    awk -v mb="$CFO_ATTACH_MARKER_BEGIN" -v me="$CFO_ATTACH_MARKER_END" '
        /^[ \t]*server[ \t{]/ { done = 0 }
        { print }
        /^[ \t]*server_name[ \t]/ && done == 0 {
            print "        " mb
            print "        include /etc/nginx/snippets/cloudflare-realip.conf;"
            print "        include /etc/nginx/snippets/cloudflare-mtls.conf;"
            print "        include /etc/nginx/snippets/cloudflare-enforce.conf;"
            print "        " me
            done = 1
        }
    ' "$vf" > "$tmp"

    # `cat >` (not mv) writes THROUGH a sites-enabled symlink to its target
    # and preserves the file's owner/mode.
    cat "$tmp" > "$vf"
    rm -f "$tmp"

    if ! nginx -t 2>&1; then
        log_error "attach-vhost: nginx -t failed after injection — restoring $vf"
        cat "$bak" > "$vf"
        nginx -t >/dev/null 2>&1 || log_error "nginx config broken even after restore — manual attention required"
        die "attach-vhost: injection made nginx config invalid; original restored"
    fi
    log_info "attach-vhost: includes injected into $vf (backup: ${bak})"
}

# detach_vhost_includes <vhost-file>
# Removes all cf-owntracks include traces (marker block + any bare snippet
# includes). Safe to call when the file or the includes don't exist.
detach_vhost_includes() {
    local vf="$1"
    [[ -f "$vf" ]] || return 0
    # Nothing to do if no trace of us is present (avoids a needless rewrite).
    grep -qE "cf-owntracks includes|snippets/cloudflare-(realip|mtls|enforce)\.conf" "$vf" || return 0
    _strip_cfo_includes "$vf"
    log_info "attach-vhost: includes removed from $vf"
}

# ---- SSH port detection ----------------------------------------------------------
# Union of sshd_config "Port" directives (incl. conf.d includes) and the ports
# a live sshd process is actually listening on. Always emits at least "22".
detect_ssh_ports() {
    {
        local f
        for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
            [[ -r "$f" ]] || continue
            # Match lines like "Port 2222" (any leading spaces, either case P/p).
            sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' "$f"
        done
        # Live sshd listeners: `ss -ltnpH` lists TCP LISTEN sockets with the
        # owning process; the sed pulls the port out of "addr:port" and only
        # keeps lines owned by sshd.
        if command -v ss >/dev/null 2>&1; then
            ss -ltnpH 2>/dev/null | grep -F '"sshd"' | \
                sed -n 's/.*[]:.]\([0-9]\+\)[[:space:]].*users:.*/\1/p'
        fi
        echo 22
    } | grep -E '^[0-9]+$' | sort -un    # numbers only, numeric sort, dedupe
}

# build_managed_ports <vhost-ports> <extra-ports> <ssh-ports>
# All args are space-separated lists. Emits the final managed set with every
# SSH port subtracted. Warns loudly when an SSH port had to be excluded.
build_managed_ports() {
    local vhost_ports="$1" extra_ports="$2" ssh_ports="$3"
    # An "associative array" (dictionary): key = port, presence = is-SSH.
    local -A ssh_set=()
    local p
    for p in $ssh_ports; do ssh_set["$p"]=1; done
    local out=()
    for p in $vhost_ports $extra_ports; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue          # ignore junk tokens
        if [[ -n "${ssh_set[$p]:-}" ]]; then         # is this port in the SSH set?
            log_warn "SSH GUARD: port $p is an SSH port — excluded from managed set (SSH always wins)"
            continue
        fi
        out+=("$p")
    done
    # Print one per line -> numeric dedupe -> back to a single spaced line.
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
        # Route each entry to the family the caller asked for, dropping
        # anything that fails strict validation.
        case "$family" in
            v4) [[ "$norm" != *:* ]] && is_valid_cidr_v4 "$norm" && printf '%s\n' "$norm" ;;
            v6) [[ "$norm" == *:* ]] && is_valid_cidr_v6 "$norm" && printf '%s\n' "$norm" ;;
        esac
    done < "$tmp"
    rm -f "$tmp"
    return 0
}

# ---- Decision log rotation ------------------------------------------------------
# rotate_decision_log <max-mb> — when the NDJSON decision log exceeds the cap,
# rename it to ".1" (keeping exactly one archive) and tell nginx to reopen its
# log files so it starts writing a fresh one.
rotate_decision_log() {
    local max_mb="$1"
    [[ -f "$CFO_DECISION_LOG" ]] || return 0
    local size max_bytes
    size="$(stat -c %s "$CFO_DECISION_LOG" 2>/dev/null || echo 0)"   # %s = size in bytes
    max_bytes=$(( max_mb * 1024 * 1024 ))
    if (( size > max_bytes )); then
        log_info "rotating decision log (${size} bytes > ${max_bytes})"
        mv -f "$CFO_DECISION_LOG" "${CFO_DECISION_LOG}.1"
        # "nginx -s reopen" sends the signal that makes nginx close + reopen
        # every log file (otherwise it would keep writing to the renamed one).
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
#
# Detection is heuristic because on Debian 12 the `iptables` command is really
# iptables-nft: rules created with it also show up inside nftables, so we have
# to work out which TOOL the admin actually uses, not just what the kernel has.
detect_firewall() {
    local active=()

    # 1) ufw is easy: it reports its own status.
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        active+=("ufw")
    fi

    # 2) nftables "native" usage = any table that is NOT ours, NOT ufw's, and
    #    NOT one of the standard names the iptables compatibility layer uses.
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

    # 3) iptables counts only when it has rules beyond the empty defaults
    #    (and we ignore our own chains here too).
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

    # ${#active[@]} = how many entries the array has.
    case "${#active[@]}" in
        0) echo "none"; return 0 ;;
        1) echo "${active[0]}"; return 0 ;;
        *) log_error "multiple firewall backends appear active: ${active[*]}"; return 2 ;;
    esac
}

# ---- SSH reachability heuristic ------------------------------------------------
# Best-effort answer to "does the current firewall policy let SSH in?".
# Purely informational — this project never touches SSH ports either way.
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
                # Match "tcp dport 22 ... accept", the set form
                # "tcp dport { 22, 80 } ... accept", or a default-accept policy.
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
                ok=1; break     # no firewall at all: nothing blocks SSH
                ;;
        esac
    done
    (( ok == 1 ))               # function's exit code = the test's result
}

# ---- nginx helpers -----------------------------------------------------------
nginx_test_or_die() {
    # `nginx -t` parses the whole config and reports errors without applying.
    if ! nginx -t 2>&1; then
        die "nginx -t failed; refusing to reload"
    fi
}

nginx_reload() {
    log_info "reloading nginx"
    # "-s reload" = graceful reload: new workers with the new config, old
    # workers finish their in-flight requests.
    nginx -s reload || die "nginx reload failed"
}

# ---- Atomic file swap --------------------------------------------------------
# write_atomic <dest>  (content arrives on stdin)
# Writing to a temp file and `mv`-ing it into place is atomic on the same
# filesystem: readers see either the whole old file or the whole new file,
# never a half-written one.
write_atomic() {
    local dest="$1"
    local tmp="${dest}.tmp.$$"      # $$ = this shell's process id (unique-ish)
    cat > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$dest"
}
