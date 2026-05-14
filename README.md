# OwnTrackDebianHardener

**Version 1.0**

A Debian 12 daemon that locks down an [OwnTracks](https://owntracks.org/)
deployment so only Cloudflare can reach it.

The internal commands and config paths use a short `cf-owntracks` prefix
(`cf-owntracks-refresh`, `/etc/cf-owntracks/config`, `inet cf_owntracks`
nftables table, etc.) — these are the stable runtime identifiers.
"OwnTrackDebianHardener" is the project name.

It runs daily via a systemd timer, fetches Cloudflare's published IPv4 + IPv6
ranges, and atomically updates **both** the firewall (scoped to ports 80/443)
and an nginx allowlist + real-ip snippet. Port 80 is redirect-only. Optional:
apply a global 80→443 redirect across every nginx site. Authenticated Origin
Pulls (Cloudflare mTLS) enforced by default for a third layer of defense.

## What it gives you

| Layer | Mechanism | What it stops |
|------|-----------|---------------|
| L3 firewall | nft / ufw / iptables — scoped to 80/443 only | Anyone not on a Cloudflare IP can't even reach the port |
| L7 nginx ACL | `allow`/`deny` after `set_real_ip_from` rewrite | Belt-and-suspenders for L3 |
| L7 mTLS (optional, on by default) | `ssl_verify_client on` against the Cloudflare origin-pull CA | Even a spoofed CF IP can't complete the TLS handshake |
| App | OwnTracks recorder bound to `127.0.0.1` | No direct exposure even if every firewall layer fails |

## Install

```sh
sudo ./install.sh \
    --server-name owntracks.example.com \
    --cert /etc/ssl/cloudflare/origin.pem \
    --key  /etc/ssl/cloudflare/origin.key
```

Useful flags:

| Flag | Default | Meaning |
|------|---------|---------|
| `--server-name <host>` | (required) | Public FQDN of the OwnTracks vhost |
| `--cert <path> --key <path>` | (required) | TLS material (use a Cloudflare Origin CA cert if you want a 15-year free one) |
| `--owntracks-port <port>` | `8083` | Local recorder port to proxy to |
| `--no-mtls` | mTLS **on** | Disable Authenticated Origin Pulls enforcement |
| `--global-http-redirect` | off | Add a default_server on :80 that 301s every unmatched host to https |
| `--force <backend>` | (autodetect) | Override firewall detection (`nftables`/`ufw`/`iptables`) |
| `--refresh-interval daily\|hourly` | `daily` | systemd timer cadence |
| `--yes` | (interactive) | Skip all confirmation prompts |
| `--dry-run` | | Validate everything, change nothing |
| `--uninstall` | | Remove the daemon and restore prior state |

### Pre-install: enable Authenticated Origin Pulls on Cloudflare

If you're keeping the default (mTLS on), enable the zone-level toggle **before**
running the installer:

> Cloudflare dashboard → SSL/TLS → Origin Server → **Authenticated Origin Pulls** → on

If the toggle is off and the installer enables mTLS enforcement, every request
will fail at handshake with `400 No required SSL certificate was sent`. The
installer will refuse to proceed unless you confirm this is enabled.

## How it works

```
                  /usr/local/sbin/cf-owntracks-refresh
                                │
                ┌───────────────┼───────────────┐
                ▼               ▼               ▼
       https://www.cloudflare.com/ips-v4   ips-v6   developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem
                                │
                  ┌─────────────┴─────────────┐
                  ▼                           ▼
        nginx snippets atomically       firewall ruleset atomically
        installed + `nginx -t`          swapped (nftables) or
        + `nginx -s reload`             rebuilt (ufw/iptables)
                  │                           │
                  └───────────┬───────────────┘
                              ▼
                  /var/lib/cf-owntracks/*.last
                  (last-known-good cache)
```

Daily at a randomized offset (`OnCalendar=daily` + `RandomizedDelaySec=1h`),
the timer fires the refresh. The script:

1. Acquires `/run/cf-owntracks.lock` via `flock` (no overlap).
2. Fetches the v4 and v6 lists (curl, three retries with backoff).
3. Validates every CIDR; bails if any are malformed or counts fall below
   sanity thresholds (≥ 5 v4, ≥ 3 v6).
4. Compares against the last-known-good cache; refuses to apply if the diff
   exceeds 50 % of either side.
5. If mTLS is enabled, fetches the Cloudflare origin-pull CA cert, validates
   it as a real x509, hashes it, and rotates only if changed.
6. Renders new nginx snippets to temp files; runs `nginx -t`; rolls back on
   failure.
7. Reloads nginx; on reload failure, rolls back and reloads with the previous
   safe state.
8. Applies the new firewall ruleset atomically. On failure: rolls back the
   firewall AND nginx.
9. Promotes the new lists to `/var/lib/cf-owntracks/ips-v{4,6}.last`.

## Inspect

| Want to see | Command |
|-------------|---------|
| Last refresh result | `journalctl -u cf-owntracks.service -n 50` |
| Timer schedule | `systemctl list-timers cf-owntracks.timer` |
| Current allowlist (nginx) | `cat /etc/nginx/snippets/cloudflare-allow.conf` |
| Current allowlist (nftables) | `nft list table inet cf_owntracks` |
| Current allowlist (ufw) | `ufw status numbered \| grep cf-owntracks` |
| Current allowlist (iptables) | `iptables -S CF-OWNTRACKS && ip6tables -S CF-OWNTRACKS6` |
| Origin-pull CA cert | `openssl x509 -in /etc/ssl/cloudflare/authenticated_origin_pull_ca.pem -noout -subject -dates` |

Force a refresh:

```sh
sudo systemctl start cf-owntracks.service
```

Run the smoke test (from anywhere with curl):

```sh
./smoke-test.sh --server-name owntracks.example.com --origin-ip 203.0.113.5
```

## Common troubleshooting

### Every request gets `400 No required SSL certificate was sent`
You enabled mTLS in the installer but Authenticated Origin Pulls is off in the
Cloudflare dashboard. Toggle it on (SSL/TLS → Origin Server → Authenticated
Origin Pulls). Effect is near-instant.

### Let's Encrypt HTTP-01 renewal fails
HTTP-01 challenges come from LE's IPs, which our firewall drops. Switch your
cert renewal to **DNS-01** (works through Cloudflare's API too), or move to
a **Cloudflare Origin CA cert** which doesn't expire for 15 years.

### `curl https://owntracks.example.com` from my laptop fails
With mTLS on, that's expected — your laptop isn't a CF edge and doesn't have
the origin-pull cert. The TLS handshake fails. Test via DNS (which routes
through Cloudflare) instead, or use `./smoke-test.sh` which knows about this.

### Site is broken after a refresh
1. `journalctl -u cf-owntracks.service -n 100` — what did the daemon say?
2. `nginx -t` — is the current config valid?
3. `cat /etc/nginx/snippets/cloudflare-allow.conf` — does the allowlist look
   sensible? (5 v4 + 3 v6 minimum; the daemon refuses to apply less)
4. `sudo systemctl start cf-owntracks.service` — force another run.

### I'm locked out of SSH
This daemon **only manages 80/443**. It cannot have locked you out of SSH. If
SSH is unreachable, something else changed (your hosting provider's panel
firewall, a `ufw deny` you forgot you ran, etc.). The installer runs an
SSH-reachability heuristic before applying anything and refuses to proceed if
SSH looks blocked.

## Uninstall

```sh
sudo ./uninstall.sh
# or equivalently:
sudo ./install.sh --uninstall
```

Removes the daemon, firewall rules, nginx managed files, and systemd units.
Preserves `/var/lib/cf-owntracks` (last-known-good cache) and
`/var/backups/cf-owntracks` (install-time state snapshots) for forensic purposes.
Delete them manually if you want a clean wipe.

## Files

```
/usr/local/sbin/cf-owntracks-refresh                  # daily script
/usr/local/lib/cf-owntracks/{common,nftables,ufw,iptables}.sh
/usr/local/share/cf-owntracks/README.md               # this file
/etc/cf-owntracks/config                              # daemon config (sourced)
/etc/systemd/system/cf-owntracks.{service,timer}      # systemd units
/etc/nginx/sites-available/owntracks.conf             # vhost
/etc/nginx/sites-enabled/owntracks.conf               # → symlink
/etc/nginx/snippets/cloudflare-{realip,allow,mtls}.conf  # managed by daemon
/etc/nginx/conf.d/cfo-upgrade-map.conf                # WebSocket upgrade map
/etc/ssl/cloudflare/authenticated_origin_pull_ca.pem  # CF mTLS CA (managed)
/var/lib/cf-owntracks/ips-v{4,6}.last                 # last-known-good lists
/var/lib/cf-owntracks/origin-pull-ca.sha256           # CA cert hash
/var/backups/cf-owntracks/<timestamp>/                # install-time state snapshot
/run/cf-owntracks.lock                                # flock guard
```
