#!/usr/bin/env bash
# cf-owntracks: nftables backend.
# Strategy: dedicated `inet cf_owntracks` table with named interval sets.
# A single `nft -f` swaps the whole table atomically (flush + add in one tx).

CFO_NFT_TABLE="inet cf_owntracks"

# Render a complete ruleset to stdout.
# Args: <v4-cidr-file> <v6-cidr-file>
nftables_render() {
    local v4_file="$1" v6_file="$2"
    local v4_elements v6_elements

    # Build elements lists from files (comma-separated, on a single set element line).
    v4_elements=$(read_cidr_file "$v4_file" | paste -sd, -)
    v6_elements=$(read_cidr_file "$v6_file" | paste -sd, -)

    cat <<NFT
# cf-owntracks managed table — do not edit by hand
add table ${CFO_NFT_TABLE}
flush table ${CFO_NFT_TABLE}
table ${CFO_NFT_TABLE} {
    set cf_v4 {
        type ipv4_addr
        flags interval
        elements = { ${v4_elements} }
    }
    set cf_v6 {
        type ipv6_addr
        flags interval
        elements = { ${v6_elements} }
    }
    chain input_filter {
        type filter hook input priority -10; policy accept;
        # Cloudflare traffic on web ports: defer to other chains (return)
        ip  saddr @cf_v4 tcp dport { 80, 443 } return
        ip6 saddr @cf_v6 tcp dport { 80, 443 } return
        # Anything else on 80/443 is non-Cloudflare: drop
        tcp dport { 80, 443 } drop
        # Other ports fall through to existing chains untouched
    }
}
NFT
}

# Validate a rendered ruleset with `nft -c` (dry-run check).
# Args: <ruleset-file>
nftables_check() {
    local file="$1"
    nft -c -f "$file" 2>&1
}

# Apply a rendered ruleset (atomic for the table).
# Args: <ruleset-file>
nftables_apply() {
    local file="$1"
    log_info "applying nftables ruleset"
    nft -f "$file" || return 1
    return 0
}

# Snapshot current state of our table only (for rollback).
# Args: <snapshot-file>
nftables_snapshot() {
    local out="$1"
    if nft list table ${CFO_NFT_TABLE} >/dev/null 2>&1; then
        nft list table ${CFO_NFT_TABLE} > "$out"
    else
        : > "$out"  # empty means "no table existed"
    fi
}

# Restore from snapshot (or remove the table if snapshot is empty).
nftables_restore() {
    local snap="$1"
    if [[ -s "$snap" ]]; then
        log_warn "restoring previous nftables table"
        nft delete table ${CFO_NFT_TABLE} 2>/dev/null || true
        nft -f "$snap" || log_error "nftables restore failed"
    else
        log_warn "removing nftables table (no prior state)"
        nft delete table ${CFO_NFT_TABLE} 2>/dev/null || true
    fi
}

# Make rules persistent across reboot.
# On Debian 12 with nftables-persistent or by writing /etc/nftables.conf include.
nftables_persist() {
    local include_marker="# cf-owntracks-include"
    local nft_conf="/etc/nftables.conf"
    local persist_file="/etc/nftables.d/cf-owntracks.conf"

    mkdir -p /etc/nftables.d
    if nft list table ${CFO_NFT_TABLE} >/dev/null 2>&1; then
        nft list table ${CFO_NFT_TABLE} > "$persist_file"
    fi

    if [[ -f "$nft_conf" ]] && ! grep -q "$include_marker" "$nft_conf"; then
        cat >> "$nft_conf" <<EOF

${include_marker}
include "/etc/nftables.d/*.conf"
EOF
        log_info "added cf-owntracks include to $nft_conf"
    fi

    systemctl enable nftables.service >/dev/null 2>&1 || true
}
