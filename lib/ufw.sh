#!/usr/bin/env bash
# cf-owntracks: ufw backend.
# Strategy: tag rules with comment "cf-owntracks" so we can enumerate + delete.
# Rebuild approach (no outage window):
#   1. Insert all new allow rules at top
#   2. Insert one final deny rule at the bottom of our tagged set
#   3. Enumerate any pre-existing "cf-owntracks" rules and delete them
#   During the brief window, both old and new are present — new takes precedence
#   because it's at the top.

CFO_UFW_COMMENT="cf-owntracks"

# Apply CF allowlist via ufw.
# Args: <v4-cidr-file> <v6-cidr-file>
ufw_apply() {
    local v4_file="$1" v6_file="$2"
    local cidr

    log_info "rebuilding ufw rules"

    # Step 1: insert new allow rules at top (prepend). Order doesn't matter among allows.
    # We insert in REVERSE so the final order is deterministic top-to-bottom.
    local -a all_cidrs=()
    while IFS= read -r cidr; do
        [[ -n "$cidr" ]] && all_cidrs+=("$cidr")
    done < <(read_cidr_file "$v4_file")
    while IFS= read -r cidr; do
        [[ -n "$cidr" ]] && all_cidrs+=("$cidr")
    done < <(read_cidr_file "$v6_file")

    # Step 2: deny rule at the bottom of our tagged block — but ufw deny rules
    # need to be ABOVE other allow rules to take effect. So we use `ufw insert 1 deny`
    # FIRST, then insert all allows on top of it.
    # Order after operations: [allow_N..allow_1, deny, ...existing rules...]
    # Match order: allows checked first, deny catches the rest.
    ufw --force insert 1 deny proto tcp from any to any port 80,443 \
        comment "${CFO_UFW_COMMENT}" >/dev/null

    for cidr in "${all_cidrs[@]}"; do
        ufw --force insert 1 allow proto tcp from "$cidr" to any port 80,443 \
            comment "${CFO_UFW_COMMENT}" >/dev/null
    done

    # Step 3: remove the previous tagged ruleset (the old block now lives below the new one).
    # We do this by enumerating with numbered status and deleting from the bottom up
    # (so positions don't shift mid-delete). The newly-added rules also carry the tag,
    # but we just added them at positions 1..N+1 — find rules tagged with our comment
    # that aren't in that fresh range.
    local new_count=$(( ${#all_cidrs[@]} + 1 ))
    # All numbered rules carrying our tag:
    mapfile -t numbered < <(ufw status numbered | awk -v tag="${CFO_UFW_COMMENT}" '
        $0 ~ tag {
            # Extract leading [N] number
            if (match($0, /^\[ *([0-9]+)\]/, m)) print m[1]
        }
    ' | sort -n)

    # Anything above new_count is leftover. Delete from highest first so numbers stay valid.
    local i
    for (( i=${#numbered[@]}-1; i>=0; i-- )); do
        if (( numbered[i] > new_count )); then
            ufw --force delete "${numbered[i]}" >/dev/null
        fi
    done

    return 0
}

# Snapshot existing tagged rules so we can restore on failure.
ufw_snapshot() {
    local out="$1"
    ufw status numbered | grep -F "${CFO_UFW_COMMENT}" > "$out" || : > "$out"
}

# Restore is best-effort: we drop all our tagged rules and replay the snapshot.
# Snapshot lines look like: "[ 3] Anywhere DENY IN  Anywhere  # cf-owntracks"
# Rebuilding from snapshot text is fragile; instead, we just remove our tagged
# rules and trust the next refresh run to re-apply correctly.
ufw_restore() {
    # Snapshot file accepted for API symmetry; not consumed (rebuilding ufw
    # rules from text is fragile, so we tear down tagged rules and let the
    # next refresh rebuild authoritatively).
    local snap="$1"; : "$snap"
    log_warn "ufw_restore: removing tagged rules; next refresh will rebuild"
    ufw_remove_all_tagged
}

# Remove every rule with our tag.
ufw_remove_all_tagged() {
    while :; do
        local n
        n=$(ufw status numbered | awk -v tag="${CFO_UFW_COMMENT}" '
            $0 ~ tag {
                if (match($0, /^\[ *([0-9]+)\]/, m)) { print m[1]; exit }
            }
        ')
        [[ -z "$n" ]] && break
        ufw --force delete "$n" >/dev/null
    done
}

ufw_persist() {
    # ufw rules persist by default — nothing to do.
    return 0
}
