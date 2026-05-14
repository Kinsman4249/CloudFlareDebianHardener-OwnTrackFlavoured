#!/usr/bin/env bash
# cf-owntracks smoke test
#
# Verifies the daemon installed correctly and the security posture is as
# expected. Designed to run on the origin box OR from any internet-connected
# machine.
#
# Local checks (only meaningful when run on origin):
#   - systemd timer is active and enabled
#   - config file exists
#   - last-known-good IP files exist and are non-empty
#   - nginx snippets exist, nginx -t passes
#   - firewall has CF rules loaded for the detected backend
#   - port 443 has a listener
#   - mTLS CA cert exists (if mTLS enabled)
#
# Remote checks (run from anywhere — origin or your laptop):
#   - HTTPS via Cloudflare DNS returns 2xx/3xx — site is reachable for real users
#   - HTTP via Cloudflare returns 301 to https
#   - Direct connection to origin IP on :443 (bypassing CF) has the expected
#     failure mode:
#       * mTLS on: TLS handshake fails ("alert handshake failure" or "no
#         required SSL certificate")
#       * mTLS off: HTTP 403 from nginx allow/deny (real client IP isn't CF)
#   - Direct connection to origin IP on :80 (bypassing CF) is dropped at the
#     firewall (timeout) — the *only* way to verify the firewall is doing its
#     job from a non-CF source IP
#
# Usage:
#   sudo ./smoke-test.sh                          # auto-load config, all checks
#   ./smoke-test.sh --server-name owntracks.example.com --origin-ip 203.0.113.5
#   ./smoke-test.sh --local-only                  # only on-box checks
#   ./smoke-test.sh --remote-only                 # only network checks
#   ./smoke-test.sh --skip-direct                 # don't try direct-to-origin
#
# Exit code: 0 if all checks pass, 1 if any fail.

set -Eeuo pipefail

# ---- Config / args ----------------------------------------------------------
SERVER_NAME=""
ORIGIN_IP=""
MODE="all"            # all | local-only | remote-only
SKIP_DIRECT=0
EXPECTED_MTLS=""      # 0, 1, or "" for "auto-detect from config"
TIMEOUT_DIRECT_DROP=6 # how long to wait before declaring "dropped" on :80

usage() { sed -n '2,37p' "$0"; }

while (( $# )); do
    case "$1" in
        --server-name)    SERVER_NAME="$2"; shift 2 ;;
        --origin-ip)      ORIGIN_IP="$2"; shift 2 ;;
        --local-only)     MODE="local-only"; shift ;;
        --remote-only)    MODE="remote-only"; shift ;;
        --skip-direct)    SKIP_DIRECT=1; shift ;;
        --mtls)           EXPECTED_MTLS="$2"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

# Best-effort: load installed config to fill in defaults.
CFG="/etc/cf-owntracks/config"
if [[ -r "$CFG" ]]; then
    # shellcheck disable=SC1090
    source "$CFG"
    SERVER_NAME="${SERVER_NAME:-${CFO_SERVER_NAME:-}}"
    EXPECTED_MTLS="${EXPECTED_MTLS:-${CFO_MTLS_ENABLED:-}}"
fi

[[ -n "$SERVER_NAME" ]] || { echo "ERROR: --server-name required (or run on origin with /etc/cf-owntracks/config readable)" >&2; exit 2; }

# ---- Output helpers ---------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

if [[ -t 1 ]]; then
    C_OK=$'\e[32m'; C_FAIL=$'\e[31m'; C_SKIP=$'\e[33m'; C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
    C_OK=""; C_FAIL=""; C_SKIP=""; C_DIM=""; C_RST=""
fi

pass() { printf '%s  PASS%s  %s\n'      "$C_OK"   "$C_RST" "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { printf '%s  FAIL%s  %s\n%s        %s%s\n' "$C_FAIL" "$C_RST" "$1" "$C_DIM" "${2:-}" "$C_RST"; FAIL_COUNT=$((FAIL_COUNT+1)); }
skip() { printf '%s  SKIP%s  %s%s\n%s        %s%s\n' "$C_SKIP" "$C_RST" "$1" "" "$C_DIM" "${2:-}" "$C_RST"; SKIP_COUNT=$((SKIP_COUNT+1)); }
section() { printf '\n%s== %s ==%s\n' "$C_DIM" "$1" "$C_RST"; }

# ---- Local checks -----------------------------------------------------------
run_local_checks() {
    if (( EUID != 0 )); then
        skip "local checks" "need root to read /etc/cf-owntracks and inspect firewall; rerun with sudo"
        return 0
    fi

    section "Local (on-box) checks"

    # systemd timer
    if systemctl is-active cf-owntracks.timer >/dev/null 2>&1; then
        pass "systemd timer is active"
    else
        fail "systemd timer is active" "$(systemctl is-active cf-owntracks.timer 2>&1 || true)"
    fi
    if systemctl is-enabled cf-owntracks.timer >/dev/null 2>&1; then
        pass "systemd timer is enabled at boot"
    else
        fail "systemd timer is enabled at boot" "$(systemctl is-enabled cf-owntracks.timer 2>&1 || true)"
    fi

    # Config file
    if [[ -r "$CFG" ]]; then
        pass "config file present at $CFG"
    else
        fail "config file present at $CFG" "not readable"
    fi

    # Last-known-good IP lists
    local v4f="/var/lib/cf-owntracks/ips-v4.last"
    local v6f="/var/lib/cf-owntracks/ips-v6.last"
    if [[ -s "$v4f" ]]; then
        local n4; n4=$(grep -c . "$v4f" || true)
        pass "IPv4 last-known-good list present (${n4} ranges)"
    else
        fail "IPv4 last-known-good list" "$v4f missing or empty — refresh has never succeeded"
    fi
    if [[ -s "$v6f" ]]; then
        local n6; n6=$(grep -c . "$v6f" || true)
        pass "IPv6 last-known-good list present (${n6} ranges)"
    else
        fail "IPv6 last-known-good list" "$v6f missing or empty"
    fi

    # nginx snippets
    for f in /etc/nginx/snippets/cloudflare-realip.conf /etc/nginx/snippets/cloudflare-allow.conf; do
        if [[ -s "$f" ]]; then pass "nginx snippet $f exists"
        else fail "nginx snippet $f exists" "missing or empty"
        fi
    done
    if [[ "${EXPECTED_MTLS:-1}" == "1" ]]; then
        if [[ -s /etc/nginx/snippets/cloudflare-mtls.conf ]]; then
            pass "mTLS snippet exists"
        else
            fail "mTLS snippet exists" "missing"
        fi
        if [[ -s /etc/ssl/cloudflare/authenticated_origin_pull_ca.pem ]] \
           && openssl x509 -in /etc/ssl/cloudflare/authenticated_origin_pull_ca.pem -noout 2>/dev/null; then
            pass "Cloudflare origin-pull CA cert valid"
        else
            fail "Cloudflare origin-pull CA cert valid" "missing or not a valid x509"
        fi
    fi

    # nginx config validity
    if nginx -t >/dev/null 2>&1; then
        pass "nginx -t passes"
    else
        fail "nginx -t passes" "$(nginx -t 2>&1 | tail -5)"
    fi

    # Firewall has CF rules loaded
    if [[ -r "$CFG" ]]; then
        case "${CFO_FW_BACKEND:-}" in
            nftables)
                if nft list table inet cf_owntracks >/dev/null 2>&1 && \
                   nft list table inet cf_owntracks 2>/dev/null | grep -q 'set cf_v4 {'; then
                    local nv4 nv6
                    # Count CIDR-like elements inside cf_v4 / cf_v6 sets.
                    nv4=$(nft list table inet cf_owntracks 2>/dev/null | awk '/set cf_v4 {/,/}/' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | wc -l)
                    nv6=$(nft list table inet cf_owntracks 2>/dev/null | awk '/set cf_v6 {/,/}/' | grep -oE '[0-9a-fA-F:]+/[0-9]+' | wc -l)
                    pass "nftables table inet cf_owntracks present (${nv4} v4 + ${nv6} v6 entries)"
                else
                    fail "nftables table inet cf_owntracks present" "not found or empty"
                fi
                ;;
            ufw)
                local c; c=$(ufw status numbered 2>/dev/null | grep -c cf-owntracks || true)
                if (( c > 0 )); then pass "ufw has $c rules tagged cf-owntracks"
                else fail "ufw has rules tagged cf-owntracks" "none found"; fi
                ;;
            iptables)
                if iptables -S CF-OWNTRACKS  >/dev/null 2>&1 && \
                   ip6tables -S CF-OWNTRACKS6 >/dev/null 2>&1; then
                    pass "iptables chains CF-OWNTRACKS and CF-OWNTRACKS6 present"
                else
                    fail "iptables chains CF-OWNTRACKS/CF-OWNTRACKS6 present" "missing"
                fi
                ;;
        esac
    fi

    # Port 443 listener
    if ss -ltn '( sport = :443 )' 2>/dev/null | grep -q LISTEN; then
        pass "something is listening on :443"
    else
        fail "something is listening on :443" "no LISTEN state"
    fi

    # Last successful refresh
    if journalctl -u cf-owntracks.service --since '1 day ago' 2>/dev/null | grep -q 'refresh complete'; then
        pass "refresh has succeeded within the last 24h"
    else
        skip "refresh has succeeded within the last 24h" "no 'refresh complete' in journal — run: sudo systemctl start cf-owntracks.service"
    fi
}

# ---- Remote / network checks ------------------------------------------------
run_remote_checks() {
    section "Remote (network) checks  [$SERVER_NAME]"

    # 1. HTTPS through Cloudflare DNS (the normal end-user path)
    local code
    code=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "https://${SERVER_NAME}/" 2>/dev/null || echo "000")
    case "$code" in
        2??|3??) pass "https://${SERVER_NAME}/ via CF returns $code" ;;
        000)     fail "https://${SERVER_NAME}/ via CF reachable" "curl failed (DNS/SSL/connectivity)" ;;
        5??)     fail "https://${SERVER_NAME}/ via CF returns 2xx/3xx" "got $code — Cloudflare can reach origin? Check CF dashboard." ;;
        *)       fail "https://${SERVER_NAME}/ via CF returns 2xx/3xx" "got $code" ;;
    esac

    # 2. HTTP via Cloudflare redirects to HTTPS
    code=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "http://${SERVER_NAME}/" 2>/dev/null || echo "000")
    case "$code" in
        301|302|307|308) pass "http://${SERVER_NAME}/ via CF returns redirect ($code)" ;;
        000)             fail "http://${SERVER_NAME}/ via CF reachable" "curl failed" ;;
        *)               fail "http://${SERVER_NAME}/ via CF returns redirect" "got $code (expected 301)" ;;
    esac

    # 3. Direct-to-origin checks (require --origin-ip and a non-CF source IP)
    if (( SKIP_DIRECT == 1 )); then
        skip "direct-to-origin checks" "--skip-direct"
        return 0
    fi
    if [[ -z "$ORIGIN_IP" ]]; then
        # Try DNS-resolved IP — but that might be a CF anycast IP, not the origin.
        # We can't reliably tell from DNS alone, so just skip with guidance.
        skip "direct-to-origin checks" "pass --origin-ip <public-IPv4-of-origin> to test the firewall"
        return 0
    fi

    # 3a. Direct HTTPS bypassing CF — should fail with handshake or 403
    local body errfile
    errfile="$(mktemp)"
    body=$(curl -sS --max-time 10 --resolve "${SERVER_NAME}:443:${ORIGIN_IP}" -o /dev/null -w '%{http_code}' "https://${SERVER_NAME}/" 2>"$errfile" || true)
    local err; err="$(<"$errfile")"
    rm -f "$errfile"
    if [[ "${EXPECTED_MTLS:-1}" == "1" ]]; then
        if [[ "$body" == "000" ]] && grep -qiE 'handshake|certificate|alert' <<<"$err"; then
            pass "direct https to origin fails TLS handshake (mTLS working): ${err%%$'\n'*}"
        elif [[ "$body" == "400" ]] && curl -sS --max-time 10 --resolve "${SERVER_NAME}:443:${ORIGIN_IP}" "https://${SERVER_NAME}/" 2>/dev/null | grep -qi 'No required SSL certificate'; then
            pass "direct https to origin returns 'No required SSL certificate' (mTLS working)"
        else
            fail "direct https to origin fails (mTLS enforced)" "got code=$body err=${err:0:120}"
        fi
    else
        # mTLS off — connection should succeed at TLS but nginx allow/deny returns 403
        if [[ "$body" == "403" ]]; then
            pass "direct https to origin returns 403 (nginx allowlist working)"
        else
            fail "direct https to origin returns 403" "got code=$body err=${err:0:120}"
        fi
    fi

    # 3b. Direct HTTP bypassing CF — should be DROPPED at the firewall (timeout)
    errfile="$(mktemp)"
    body=$(curl -sS --max-time "$TIMEOUT_DIRECT_DROP" --resolve "${SERVER_NAME}:80:${ORIGIN_IP}" -o /dev/null -w '%{http_code}' "http://${SERVER_NAME}/" 2>"$errfile" || true)
    err="$(<"$errfile")"
    rm -f "$errfile"
    if [[ "$body" == "000" ]] && grep -qiE 'timed? out|timeout|operation timed|connection timed|refused' <<<"$err"; then
        pass "direct http to origin is dropped by firewall (timeout/refused — what we want)"
    elif [[ "$body" =~ ^(301|302|307|308)$ ]]; then
        fail "direct http to origin is dropped by firewall" \
             "got $body redirect — your source IP appears to be in the Cloudflare ranges, or the firewall isn't filtering :80. Test from a non-CF IP."
    else
        fail "direct http to origin is dropped by firewall" "unexpected: code=$body err=${err:0:120}"
    fi
}

# ---- Dispatch ---------------------------------------------------------------
case "$MODE" in
    local-only)  run_local_checks ;;
    remote-only) run_remote_checks ;;
    all)         run_local_checks; run_remote_checks ;;
esac

# ---- Summary ----------------------------------------------------------------
echo
echo "------------------------------------------------------------"
printf '%s%d PASS%s   %s%d FAIL%s   %s%d SKIP%s\n' \
    "$C_OK" "$PASS_COUNT" "$C_RST" \
    "$C_FAIL" "$FAIL_COUNT" "$C_RST" \
    "$C_SKIP" "$SKIP_COUNT" "$C_RST"

(( FAIL_COUNT == 0 ))
