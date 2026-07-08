# OwnTrackDebianHardener

**Version 2.2.1**

A Debian 12 daemon that locks down an [OwnTracks](https://owntracks.org/)
deployment so only Cloudflare can reach it — with a **test-first workflow**:
observe exactly what *would* be blocked before you enforce anything.

The internal commands and config paths use a short `cf-owntracks` prefix
(`cf-owntracks-refresh`, `/etc/cf-owntracks/config`, `inet cf_owntracks`
nftables table, etc.) — these are the stable runtime identifiers.
"OwnTrackDebianHardener" is the project name.

> **⚠ v2 breaking change:** running `install.sh` now defaults to **TEST mode**
> (nothing enforces). Pass `--deploy` for the enforcing behavior that v1
> applied by default. Upgrading over a 1.x install switches that system back
> to test mode and tells you so — re-run with `--deploy` to re-enforce.

## The two modes

| | TEST (default) | DEPLOY (`--deploy`) |
|---|---|---|
| Firewall | logs + counts would-blocked traffic, **drops nothing** | drops non-Cloudflare traffic on managed ports |
| nginx | classifies every request, **rejects nothing** | returns 403 to anything not Cloudflare/localhost/allowlisted |
| mTLS (AOP) | verified `optional`, result recorded | required (via the 403 gate) for non-allowlisted sources |
| Decision log | **on** — every request → NDJSON | off |
| IP ranges | refreshed continuously | refreshed continuously |

Both modes run the full daemon + timer, so ranges/ports/allowlist stay current
and switching modes is instant: settings persist, so it's just

```sh
sudo ./install.sh --deploy --yes     # enforce
sudo ./install.sh --yes              # back to observing
```

## What protects the service in deploy mode

| Layer | Mechanism | What it stops |
|------|-----------|---------------|
| L3 firewall | nft / ufw / iptables — scoped to the **managed ports only** | Non-Cloudflare, non-allowlisted sources can't reach the ports |
| L7 nginx gate | geo classification + 403 (post-`set_real_ip_from`) | Belt-and-suspenders for L3 |
| L7 mTLS | Authenticated Origin Pulls, `ssl_verify_client optional` + conditional 403 | Even a spoofed/reassigned CF IP fails without a real edge certificate |
| App | OwnTracks recorder bound to `127.0.0.1` | No direct exposure even if every layer above fails |

**Always allowed, both modes, both layers:** loopback/localhost, and every
entry in `/etc/cf-owntracks/allowlist`.

**Never touched:** SSH and every other non-managed port — see the guarantee
below.

## Get the code

First install — clone the repo onto the Debian 12 box:

```sh
sudo apt-get install -y git          # if git isn't there yet
git clone https://github.com/Kinsman4249/OwnTrackDebianHardener.git
cd OwnTrackDebianHardener
# Files are stored non-executable in the repo. Tell git to ignore
# executable-bit differences so the chmod below never turns into a
# "local changes would be overwritten" conflict on a future `git pull`.
git config core.fileMode false
chmod +x install.sh uninstall.sh smoke-test.sh bin/cf-owntracks-refresh
```

> **Tip:** you can skip both the `core.fileMode` and `chmod` lines entirely by
> invoking the scripts with `bash` — e.g. `sudo bash install.sh` — which
> doesn't care about the executable bit.

Updating an existing clone to the latest version:

```sh
cd OwnTrackDebianHardener
git config core.fileMode false   # once per clone; harmless to repeat
git pull                         # no conflict even though you chmod'd earlier
sudo bash install.sh             # re-run; your settings are the defaults
```

To pin a specific release instead of `main`: `git checkout v2.1.0`
(or `git pull --tags && git checkout v2.1.0` on an existing clone).

No git? Grab a release tarball (tarballs preserve the executable bit, so no
chmod dance needed):

```sh
curl -L https://github.com/Kinsman4249/OwnTrackDebianHardener/archive/refs/tags/v2.1.0.tar.gz | tar xz
cd OwnTrackDebianHardener-2.1.0
sudo bash install.sh
```

## Install

```sh
sudo ./install.sh
```

That's it for a first look: the installer **prompts for every setting**
(server name, cert/key paths, recorder port, mTLS, redirect, refresh interval,
log cap, extra allowlist IPs), showing defaults you can accept with Enter.
On a box with a previous install, **your existing settings are the defaults —
nothing is clobbered.**

Two things it works out on its own:

- **Server name** — when you don't pass `--server-name` (and no prior config
  exists), it tries three sources in order: the **OwnTracks recorder's own
  config** (`/etc/default/ot-recorder` — URL-shaped values like
  `OTR_HTTPPREFIX` first, then an FQDN-valued `OTR_HOST`; the recorder knows
  the public URL it serves under, so this beats inference), then nginx
  `server_name` directives, then the reverse-DNS PTR of the box's public IP.
  Always shown as a prompt default, never applied silently — PTR names in
  particular are often generic ISP hostnames.
- **The origin certificate** — see the next section.

Non-interactive (with automatic cert):

```sh
sudo CF_ORIGIN_CA_KEY=v1.0-xxxx ./install.sh \
    --server-name owntracks.example.com \
    --cf-auto-cert \
    --allow 203.0.113.7 \
    --yes
```

### Automatic origin certificate (`--cf-auto-cert`)

Instead of supplying `--cert`/`--key`, let the installer provision a
**15-year Cloudflare Origin CA certificate** for the server name:

1. It generates a private key + CSR locally (key never leaves the box).
2. It calls Cloudflare's `POST /client/v4/certificates` API.
3. The signed cert + key land at `/etc/ssl/cloudflare/origin.{pem,key}`
   (key mode 0600). A still-valid existing cert covering the hostname
   (>30 days left) is **reused, not reissued**.

#### Credentials — exactly what the key needs

One of the two, preferably via environment variable (invisible to `ps`):

**Option A — Origin CA Key (`CF_ORIGIN_CA_KEY`, recommended)**

- **Where:** Cloudflare dashboard → **My Profile → API Tokens** → scroll to
  the **API Keys** section → **Origin CA Key** → View. It looks like
  `v1.0-xxxxxxxx...`.
- **What it can do:** issue and revoke Origin CA certificates for zones on
  your account — *and nothing else*. It cannot touch DNS, zone settings,
  firewall rules, or billing. That built-in narrowness is why it's the
  recommended option.

**Option B — API Token (`CF_API_TOKEN`)**

Create at **My Profile → API Tokens → Create Token → Custom token** with
exactly this permission set:

| Setting | Value |
|---|---|
| Permissions | **Zone → SSL and Certificates → Edit** (Edit, not Read — issuing a cert is a write) |
| Zone Resources | **Include → Specific zone →** the zone your server name lives in |
| Client IP Address Filtering | leave empty, or include the **origin server's public IP** — the API call is made *from the origin box* |
| TTL | optional; see note below |

Nothing else is required — no DNS permissions, no account-level permissions,
no additional zones.

**Credential hygiene notes**

- The installer uses the credential **once per issuance** and never persists
  it: it isn't written to `/etc/cf-owntracks/config`, and it's passed to
  `curl` via a mode-600 temp config file (never on the command line).
- Because the issued cert lasts 15 years and re-runs *reuse* a valid cert
  instead of calling the API, you can safely give an API token a short TTL
  or delete it right after installing.
- If the API answers `Auth error` / `9109`: wrong credential type for the
  auth header (Origin CA keys and API tokens are not interchangeable — the
  installer picks the header by the `v1.0-` prefix), missing the Edit
  permission, the zone isn't included in the token's scope, or IP filtering
  is excluding the origin box.

In interactive installs the installer offers auto-provisioning whenever no
usable cert path is configured, and asks for the credential with hidden
input. Non-interactively, having a credential in the environment with no
`--cert` configured enables it automatically. Because these are Origin CA
certs, they're only trusted by Cloudflare — direct-access clients (your
allowlisted IPs) will see an untrusted-cert warning, exactly as covered in
the allowlist section.

The install finishes with an **install summary + diagnostics block** that
checks: Cloudflare endpoints (ips-v4/v6, origin-pull CA, RIPEstat), journald
write/read, `nginx -t`, listeners on every managed port, firewall rule
presence, the port→SSH exclusion proof, and state/log directory access —
each line PASS/WARN/FAIL. Re-run it anytime:

```sh
sudo ./install.sh --diagnostics
```

### Already have an nginx vhost for this host? Use `--attach-vhost`

If your box already serves the OwnTracks hostname through its own vhost —
basic-auth, PHP frontend, custom `location` blocks, the works — **don't let
the installer generate a competing one**. Two vhosts claiming the same
`server_name` make nginx silently ignore one of them ("conflicting server
name"), and whichever loses serves nothing.

Attach mode layers the protection into *your* vhost instead:

```sh
sudo bash install.sh --attach-vhost /etc/nginx/sites-enabled/owntracks --yes
```

What it does:

- Injects exactly three `include` lines (realip, mTLS, enforce) into each
  `server` block of your file, wrapped in marker comments — **idempotent**
  (re-runs detect the markers and do nothing) and **reversible**
  (`--uninstall` removes exactly that stanza; a one-time backup lands at
  `<file>.pre-cfo`).
- Removes any previously-generated standalone vhost so nothing competes.
- Persists the path in config (`CFO_ATTACH_VHOST`) — every future installer
  run reuses it automatically.
- Managed-port discovery reads *your* vhost's `listen` directives.
- Validates with `nginx -t` after injecting; restores your file on failure.

Your auth, routing, cookies, and locations are untouched — you just gain the
decision log, real-IP handling, mTLS verification, and (in deploy mode) the
Cloudflare-only 403 gate, inside the vhost that actually serves traffic.

The installer also **refuses to create its own vhost** when it detects
another enabled vhost claiming the server name, and points you at the exact
`--attach-vhost` command (override with `--force-own-vhost` if you really
mean it).

### Flags

| Flag | Default | Meaning |
|------|---------|---------|
| `--deploy` | test mode | Enforce. Without it you're observing only |
| `--attach-vhost <file>` | off | Layer includes into an existing vhost instead of generating one (persisted; see above) |
| `--force-own-vhost` | off | Generate our vhost despite a detected server-name conflict (not recommended) |
| `--server-name <host>` | auto-detect | Public FQDN (auto: OwnTracks config → nginx `server_name` → reverse-DNS PTR) |
| `--cert <path> --key <path>` | prompt/config | TLS material (or use `--cf-auto-cert`) |
| `--cf-auto-cert` | off | Provision a 15-year Origin CA cert via the Cloudflare API |
| `--cf-origin-ca-key <k>` / `--cf-api-token <t>` | env | Credentials for `--cf-auto-cert` (prefer `CF_ORIGIN_CA_KEY` / `CF_API_TOKEN` env vars) |
| `--owntracks-port <port>` | `8083` | Local recorder port |
| `--allow <ip-or-cidr>` | — | Always-allow this source (repeatable; persisted) |
| `--no-mtls` | mTLS on | Disable Authenticated Origin Pulls |
| `--no-asn-failsafe` | on | Disable the ASN prefix failsafe |
| `--asns "<a> <b>"` | `13335` | Cloudflare ASNs for the failsafe |
| `--manage-port <port>` | — | Opt another nginx port into management (repeatable) |
| `--global-http-redirect` | off | default_server on :80 that 301s all unmatched hosts |
| `--refresh-interval <v>` | `6h` | `6h` / `3h` / `12h` / `daily` / `hourly` |
| `--test-log-max-mb <n>` | `15` | Decision log size cap |
| `--force <backend>` | autodetect | `nftables` / `ufw` / `iptables` |
| `--yes` | interactive | Accept defaults, skip prompts |
| `--dry-run` | | Render to `./cf-owntracks-rendered/`, change nothing |
| `--diagnostics` | | Run health checks against the current install |
| `--uninstall` | | Remove daemon + rules (state/backups/logs preserved) |

### Pre-install for mTLS (deploy mode)

Enable the zone-level toggle **before** deploying with mTLS on:

> Cloudflare dashboard → SSL/TLS → Origin Server → **Authenticated Origin Pulls**

The installer refuses to deploy with mTLS until you confirm this. (In test
mode there's nothing to break — verification is recorded, never required.)

## The decision log (test mode)

Every request lands in `/var/log/cf-owntracks/decisions.ndjson` — one JSON
object per line, so it's grep-able by humans and trivially parseable by
machines:

```json
{"ts":"2026-07-08T13:05:22+00:00","conn_ip":"198.51.100.23","client_ip":"198.51.100.23","host":"owntracks.example.com","method":"GET","uri":"/","status":301,"tls_verify":"NONE","src_class":"would_block","would_block":1,"reason":"ip_not_cloudflare"}
```

Reasons you'll see:

| `reason` | Meaning |
|---|---|
| `allowed_cloudflare_list` | Source is in Cloudflare's published ranges |
| `allowed_cloudflare_asn` | Source matched the ASN failsafe (not in the published lists) |
| `allowed_localhost` | Loopback |
| `allowed_whitelist` | Matched `/etc/cf-owntracks/allowlist` |
| `ip_not_cloudflare` | Would be blocked: unknown source |
| `mtls_no_valid_cert` | Would be blocked: CF-range IP but no valid edge client cert |

Useful one-liners:

```sh
tail -f /var/log/cf-owntracks/decisions.ndjson
grep '"would_block":1' /var/log/cf-owntracks/decisions.ndjson | tail -20
grep -c '"reason":"allowed_cloudflare_asn"' /var/log/cf-owntracks/decisions.ndjson
```

The log self-limits: when it exceeds the cap (default **15 MB**, set with
`--test-log-max-mb` or `CFO_TEST_LOG_MAX_MB`), it rotates to
`decisions.ndjson.1` (one archive kept) and nginx reopens a fresh file.
Would-block *port probes* that never complete an HTTP request don't reach
nginx; those show up as rate-limited `cfo-wouldblock` kernel log entries
(`journalctl -k | grep cfo-wouldblock`) and firewall counters instead.

## Always-allow list

```sh
echo '203.0.113.7' | sudo tee -a /etc/cf-owntracks/allowlist
sudo systemctl start cf-owntracks.service   # or wait ≤6h for the next tick
```

One IP or CIDR per line, `#` comments allowed, IPv4 and IPv6 both fine. These
sources are always allowed on the managed ports — firewall **and** nginx,
both modes. Matching uses the **physical connection address**, which can't be
spoofed via `CF-Connecting-IP`/`X-Forwarded-For`.

**Direct-access TLS note:** allowlisted clients hitting the origin directly
will get an *untrusted certificate* warning if you serve a Cloudflare Origin
CA cert (it isn't publicly trusted) — that's expected; use `curl -k`, import
the CF root, or serve a publicly trusted cert.

## Port scope + the SSH guarantee

The firewall no longer assumes `80/443`. On every refresh the daemon reads
the **listen directives of the vhosts it manages** from `nginx -T` and scopes
the firewall to exactly those ports. Other nginx vhosts' ports are listed in
diagnostics but never touched unless you opt them in with `--manage-port`.

SSH can't be caught in the blast radius, by four independent layers:

1. SSH ports are detected from `sshd_config` (+ `sshd_config.d/`) *and* live
   `sshd` listeners — and **hard-subtracted** from the managed port set.
   If nginx ever listens on an SSH port, SSH wins and you get a loud warning.
2. The firewall chain starts with an explicit early `return` for SSH ports —
   insurance against any port-list bug.
3. Loopback is exempted before any verdict logic (`iif lo`).
4. Diagnostics and the smoke test print the port map and assert the managed
   set contains no SSH port.

Everything else on the box — every port not in the managed set — is simply
never referenced by any rule this tool writes.

## ASN failsafe

Cloudflare's published `ips-v4`/`ips-v6` lists are the primary source. As a
failsafe, the daemon also fetches the prefixes announced by Cloudflare's ASN
(default **AS13335**; RIPEstat primary, bgpview fallback), keeps only the
prefixes **not already covered** by the published lists, and merges them in.
In the decision log these show up distinctly (`allowed_cloudflare_asn`), so
test mode tells you exactly what the failsafe is catching.

Expect the novel set to be sizeable: as of mid-2026, AS13335 announces ~2400
IPv4 + ~2900 IPv6 prefixes, of which roughly **930 aren't covered** by the
published lists (including Cloudflare-operated space like `1.1.1.0/24`).
nftables absorbs that effortlessly; on **ufw** it means thousands of discrete
rules — use `--force nftables` or `--no-asn-failsafe` there.

Trade-off to know about: AS13335 also announces BYOIP/Magic-Transit customer
prefixes, so the failsafe widens the IP surface. Mitigations: the novel-only
filter and diagnostics keep the addition visible (exact counts printed),
deploy-mode mTLS still requires a real edge certificate regardless of IP, and
`--no-asn-failsafe` turns it off entirely. A failed or implausible ASN lookup
(>2000 novel prefixes) never fails a refresh — it degrades to the cached set.

## Autonomous refresh

- Every **6 hours** with jitter (configurable: `3h`/`12h`/`daily`/`hourly`)
- Automatic **retry ~30 minutes** after a failed run (transient CF hiccups
  don't leave you stale until the next tick)
- Every run re-derives: published ranges, ASN prefixes, origin-pull CA,
  managed ports (from nginx), and the allowlist
- All updates are transactional: `nginx -t` gate + full rollback (snippets,
  CA, firewall) on any failure — a failed run leaves the previous good state

Steady state needs **zero sysadmin action**.

## Inspect

| Want to see | Command |
|-------------|---------|
| Live decisions (test mode) | `tail -f /var/log/cf-owntracks/decisions.ndjson` |
| Would-block kernel hits | `journalctl -k \| grep cfo-wouldblock` |
| Last refresh | `journalctl -u cf-owntracks.service -n 50` |
| Timer schedule | `systemctl list-timers 'cf-owntracks*'` |
| Firewall (nftables) | `nft list table inet cf_owntracks` |
| Firewall (ufw) | `ufw status numbered \| grep cf-owntracks` |
| Firewall (iptables) | `iptables -S CF-OWNTRACKS; ip6tables -S CF-OWNTRACKS6` |
| Source classification | `cat /etc/nginx/conf.d/cf-owntracks-maps.conf` |
| Health | `sudo ./install.sh --diagnostics` |

Force a refresh: `sudo systemctl start cf-owntracks.service`

Smoke test (mode-aware):

```sh
sudo ./smoke-test.sh                                        # on origin
./smoke-test.sh --server-name owntracks.example.com \
                --origin-ip 203.0.113.5 --remote-only       # from anywhere
```

## Upgrading from 1.x

```sh
cd OwnTrackDebianHardener
git config core.fileMode false   # once per clone; ignores chmod exec-bit deltas
git pull
sudo bash install.sh
```

The installer reads your 1.x config as prompt defaults (nothing is
clobbered), removes v1 leftovers, and — because v2 defaults to test mode —
prints a prominent notice that **enforcement is being switched OFF** until
you re-run with `--deploy`. Fixes shipped in 2.0.0 that affected v1:

- ufw adapter crashed on Debian's default `mawk` during rule cleanup
- ufw IPv6 rules were never applied (`insert 1` invalid position)
- **loopback traffic to 80/443 was dropped** in deploy (nftables/iptables)
- firewall persistence writes were blocked by the systemd sandbox
- backend re-detection reported nftables on ufw boxes after first install
- first-run mTLS could fail the bootstrap if the CA fetch failed
- nginx rollback didn't restore the origin-pull CA

## Troubleshooting

**Nothing in the decision log** — no traffic has hit the vhost yet (or you're
in deploy mode, where the log is off). Check `nginx -t`, the listener, and CF
DNS. `sudo ./install.sh --diagnostics` covers all of it.

**Every request 403s after `--deploy` with mTLS** — the zone toggle
(SSL/TLS → Origin Server → Authenticated Origin Pulls) is off, so Cloudflare
isn't presenting the edge certificate. Turn it on; effect is near-instant.
The decision log (rerun test mode) would show `mtls_no_valid_cert`.

**Let's Encrypt HTTP-01 renewal fails (deploy mode)** — LE's challenge IPs
aren't Cloudflare's. Use DNS-01, a Cloudflare Origin CA cert (15-year, no
renewal traffic), or temporarily add LE to the allowlist.

**Locked out of SSH** — not by this tool: SSH ports are hard-excluded and
the smoke test proves it. Check your provider's edge firewall or your own
`ufw`/`nft` policy.

**`git pull` says "Your local changes … would be overwritten by merge"**
(listing `install.sh`, `uninstall.sh`, etc.) — you ran `chmod +x` during
setup, and git treats the executable-bit flip as a local modification.
Run `git config core.fileMode false` once in the clone, then `git pull`
again. It's harmless — it only tells git to stop comparing executable bits.
Watch for this one: if the pull aborts, the fix you were pulling never
installed, so a re-run of the installer will reproduce the *old* failure.

**ufw is slow / rule list is huge** — the ASN failsafe multiplies ufw's
per-CIDR rules. `--force nftables` (interval sets) handles the full merged
set effortlessly, or `--no-asn-failsafe`.

## Uninstall

```sh
sudo ./uninstall.sh          # = sudo ./install.sh --uninstall
```

Removes the daemon, timers, firewall rules, and managed nginx files.
Preserves `/var/lib/cf-owntracks` (caches), `/var/backups/cf-owntracks`
(pre-install snapshots), and `/var/log/cf-owntracks` (decision logs).

## Files

```
/usr/local/sbin/cf-owntracks-refresh                  # refresh daemon (bash)
/usr/local/lib/cf-owntracks/{common,nftables,ufw,iptables}.sh
/usr/local/share/cf-owntracks/README.md               # this file
/etc/cf-owntracks/config                              # settings (reused on reinstall)
/etc/cf-owntracks/allowlist                           # always-allow sources
/etc/systemd/system/cf-owntracks.{service,timer}      # 6-hourly refresh
/etc/systemd/system/cf-owntracks-retry.timer          # ~30min retry on failure
/etc/nginx/sites-available/owntracks.conf             # vhost (+ sites-enabled link)
/etc/nginx/conf.d/cf-owntracks-maps.conf              # geo/verdict maps + log format
/etc/nginx/conf.d/cfo-upgrade-map.conf                # WebSocket upgrade map
/etc/nginx/snippets/cloudflare-{realip,enforce,mtls}.conf
/etc/ssl/cloudflare/authenticated_origin_pull_ca.pem  # CF mTLS CA (managed)
/var/lib/cf-owntracks/{ips,asn}-v{4,6}.last           # last-known-good caches
/var/lib/cf-owntracks/ports.last                      # managed port set
/var/log/cf-owntracks/decisions.ndjson                # test-mode decision log
/run/cf-owntracks.lock                                # flock guard
```

## License

MIT
