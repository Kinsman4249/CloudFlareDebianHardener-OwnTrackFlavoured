#!/usr/bin/env bash
# cf-owntracks: iptables backend.
# Strategy: dedicated chain `CF-OWNTRACKS` (and ip6tables `CF-OWNTRACKS6`).
# INPUT chain jumps to ours for tcp dports 80,443. We rebuild the chain via
# iptables-restore --noflush which is atomic for the chains it defines.

CFO_IPT_CHAIN="CF-OWNTRACKS"
CFO_IPT_CHAIN6="CF-OWNTRACKS6"

# Render iptables-restore input for IPv4.
# Args: <v4-cidr-file>
iptables_render_v4() {
    local v4_file="$1"
    local cidr
    {
        echo "*filter"
        echo ":${CFO_IPT_CHAIN} - [0:0]"
        echo "-F ${CFO_IPT_CHAIN}"
        while IFS= read -r cidr; do
            [[ -z "$cidr" ]] && continue
            printf -- '-A %s -s %s -j RETURN\n' "${CFO_IPT_CHAIN}" "$cidr"
        done < <(read_cidr_file "$v4_file")
        echo "-A ${CFO_IPT_CHAIN} -j DROP"
        echo "COMMIT"
    }
}

# Render ip6tables-restore input for IPv6.
iptables_render_v6() {
    local v6_file="$1"
    local cidr
    {
        echo "*filter"
        echo ":${CFO_IPT_CHAIN6} - [0:0]"
        echo "-F ${CFO_IPT_CHAIN6}"
        while IFS= read -r cidr; do
            [[ -z "$cidr" ]] && continue
            printf -- '-A %s -s %s -j RETURN\n' "${CFO_IPT_CHAIN6}" "$cidr"
        done < <(read_cidr_file "$v6_file")
        echo "-A ${CFO_IPT_CHAIN6} -j DROP"
        echo "COMMIT"
    }
}

iptables_check() {
    local v4_file="$1" v6_file="$2"
    iptables-restore --test < "$v4_file" 2>&1 || return 1
    ip6tables-restore --test < "$v6_file" 2>&1 || return 1
    return 0
}

# Apply both v4 and v6 chains, then ensure INPUT jumps are present.
iptables_apply() {
    local v4_file="$1" v6_file="$2"
    log_info "applying iptables ruleset"

    iptables-restore --noflush < "$v4_file" || return 1
    ip6tables-restore --noflush < "$v6_file" || return 1

    # Ensure INPUT chain jumps to our chain for tcp 80,443.
    # Use -C to check, -I 1 to insert at top if missing (so we run before any DROP).
    iptables -C INPUT -p tcp -m multiport --dports 80,443 -j ${CFO_IPT_CHAIN} 2>/dev/null \
        || iptables -I INPUT 1 -p tcp -m multiport --dports 80,443 -j ${CFO_IPT_CHAIN}
    ip6tables -C INPUT -p tcp -m multiport --dports 80,443 -j ${CFO_IPT_CHAIN6} 2>/dev/null \
        || ip6tables -I INPUT 1 -p tcp -m multiport --dports 80,443 -j ${CFO_IPT_CHAIN6}

    return 0
}

iptables_snapshot() {
    local out="$1"
    {
        echo "## iptables CF-OWNTRACKS chain (v4) ##"
        iptables -S ${CFO_IPT_CHAIN} 2>/dev/null || echo "## (chain absent) ##"
        echo "## ip6tables CF-OWNTRACKS6 chain (v6) ##"
        ip6tables -S ${CFO_IPT_CHAIN6} 2>/dev/null || echo "## (chain absent) ##"
        echo "## INPUT jumps ##"
        iptables -S INPUT | grep -F "${CFO_IPT_CHAIN}" || true
        ip6tables -S INPUT | grep -F "${CFO_IPT_CHAIN6}" || true
    } > "$out"
}

iptables_restore() {
    # Snapshot file is accepted for API symmetry with nftables_restore but
    # not consumed: rebuilding iptables rules from a textual snapshot is
    # fragile, so we just tear down our chain and trust the next refresh.
    local snap="$1"; : "$snap"
    log_warn "iptables_restore: removing CF chains; next refresh will rebuild"
    iptables -D INPUT -p tcp -m multiport --dports 80,443 -j ${CFO_IPT_CHAIN} 2>/dev/null || true
    iptables -F ${CFO_IPT_CHAIN} 2>/dev/null || true
    iptables -X ${CFO_IPT_CHAIN} 2>/dev/null || true
    ip6tables -D INPUT -p tcp -m multiport --dports 80,443 -j ${CFO_IPT_CHAIN6} 2>/dev/null || true
    ip6tables -F ${CFO_IPT_CHAIN6} 2>/dev/null || true
    ip6tables -X ${CFO_IPT_CHAIN6} 2>/dev/null || true
}

iptables_persist() {
    # Debian uses iptables-persistent (netfilter-persistent) to save rules across reboots.
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || \
            log_warn "netfilter-persistent save failed; rules will not survive reboot"
    else
        log_warn "netfilter-persistent not installed; iptables rules will not survive reboot"
        log_warn "  install with: apt-get install iptables-persistent"
    fi
}
