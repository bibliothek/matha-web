# matha-web

Docker Compose deployment for four apps behind a single Cloudflare Tunnel:

| App | Repo | Internal address |
|---|---|---|
| MathAuth (SSO / OIDC provider) | [bibliothek/mathauth](https://github.com/bibliothek/mathauth) | `http://mathauth:8080` |
| MathaHub (link dashboard) | [bibliothek/matha-hub](https://github.com/bibliothek/matha-hub) | `http://mathahub:8080` |
| Extensible Checklist | [bibliothek/extensible-checklist](https://github.com/bibliothek/extensible-checklist) | `http://extensible-checklist:8080` |
| AdventRunner | [bibliothek/AdventRunner](https://github.com/bibliothek/AdventRunner) | `http://adventrunner:8085` |

No host ports are published. The only inbound path is `cloudflared`, which
reaches the apps over the internal compose network.

AdventRunner is standalone: it authenticates against Auth0 (`adventrunner.eu.auth0.com`,
hardcoded in the app) and talks to Strava, so it needs no MathAuth client. The
other two authenticate against MathAuth over OIDC. The client
registrations live in `oidc-clients.json`, mounted read-only into MathAuth;
each app gets its own credentials from `.env`. The client id and secret must
match on both sides.

## Host layout

All persistent state is bind-mounted from `DATA_ROOT/<appname>/` (default `/app`):

```
/app/mathauth/data                      SQLite DB                        (root)
/app/mathauth/data/keys                 data-protection keys             (root)
/app/mathauth/config/oidc-clients.json  client registrations             (root, ro)
/app/mathauth/certs                     signing.pfx, encryption.pfx      (root, ro)
/app/mathahub/links/<user>.json         per-user link configs            (uid 1654)
/app/extensible-checklist/data          SQLite DB                        (uid 1654)
/app/adventrunner/data                  users/ + shared-links/ JSON      (root)
```

MathaHub and the Checklist run as uid 1654, and bind mounts do not inherit the
image's ownership, so those two directories must be chowned or the apps cannot
write. `scripts/init-dirs.sh` creates the tree, sets that up, and drops an empty
`oidc-clients.json` to fill in (an existing one is left alone):

```bash
sudo ./scripts/init-dirs.sh
```

```json
{
  "OidcClients": []
}
```

Still yours to place: the client registrations in that file, the per-user link
JSONs, and `signing.pfx` / `encryption.pfx` in `certs/` (leave
`MATHAUTH_*_CERT_PATH` empty to run on ephemeral dev certs, which log everyone
out on every restart).

## Setup (Ubuntu)

Requires an **x86-64** host — the published images are `linux/amd64` only.
On arm64, build from source (see the last section).

```bash
# 1. Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER" && newgrp docker

# 2. Config
cp .env.example .env
openssl rand -base64 32   # → MATHAHUB_CLIENT_SECRET
openssl rand -base64 32   # → CHECKLIST_CLIENT_SECRET
$EDITOR .env              # AUTH_PUBLIC_URL, admin password, tunnel token, secrets

# 3. Host directories + your config files in place (see "Host layout" above)
sudo ./scripts/init-dirs.sh

# 4. Go
docker compose up -d
docker compose logs -f
```

**Re-run `sudo ./scripts/init-dirs.sh` whenever you drop files into the data
directories by hand.** Files copied in as root stay root-owned, and MathaHub and
the Checklist run as uid 1654 — they need to write the files themselves, not
just the directory. Without the re-run, SQLite fails with *"attempt to write a
readonly database"* and MathaHub's Edit page silently never saves. The script's
`chown -R` repairs this, and re-running is safe: it leaves an existing
`oidc-clients.json` alone. MathAuth and AdventRunner run as root, so their files
are fine either way.

### Cloudflare Tunnel

Zero Trust dashboard → **Networks → Tunnels → Create a tunnel** (Cloudflared),
copy the token into `TUNNEL_TOKEN`, then add three public hostnames:

| Public hostname | Service |
|---|---|
| `auth.thaller.space` | `http://mathauth:8080` |
| `hub.thaller.space` | `http://mathahub:8080` |
| `checklist.thaller.space` | `http://extensible-checklist:8080` |
| `adventrunner.com` | `http://adventrunner:8085` |
| `www.adventrunner.com` | `http://adventrunner:8085` |

`adventrunner.com` is a second zone on the same Cloudflare account, so the same
tunnel serves it.

Cloudflare creates the proxied `CNAME → <tunnel-id>.cfargotunnel.com` records
itself, since `thaller.space` is on the same account. Nothing needs to be opened
on the server — the tunnel is outbound-only.

Do **not** put the apps behind Cloudflare Access: MathaHub and the Checklist
fetch OIDC metadata and tokens from `AUTH_PUBLIC_URL` server-side, and Access
would block those calls.

## Configuration

`/app/mathauth/config/oidc-clients.json` holds the client registrations (ids,
secrets, redirect URIs). Everything else is driven by `.env`:

| Variable | Purpose |
|---|---|
| `AUTH_PUBLIC_URL` | MathAuth's tunnel hostname, used as the OIDC issuer. No trailing slash. |
| `TUNNEL_TOKEN` | Cloudflare Tunnel token |
| `MATHAUTH_ADMIN_USERNAME` / `MATHAUTH_ADMIN_PASSWORD` | Admin account, seeded on first start (min. 8 chars) |
| `MATHAUTH_SIGNING_CERT_PATH` / `MATHAUTH_ENCRYPTION_CERT_PATH` / `MATHAUTH_CERT_PASSWORD` | Token certificates, mounted from `DATA_ROOT/mathauth/certs` |
| `AR_AUTH0_CLIENT_ID` / `AR_AUTH0_CLIENT_SECRET` | AdventRunner's Auth0 management-API client |
| `AR_STRAVA_CLIENT_ID` / `AR_STRAVA_CLIENT_SECRET` | AdventRunner's Strava app |
| `MATHAHUB_CLIENT_ID` / `MATHAHUB_CLIENT_SECRET` | MathaHub's credentials — must match `oidc-clients.json` |
| `CHECKLIST_CLIENT_ID` / `CHECKLIST_CLIENT_SECRET` | The Checklist's credentials — must match `oidc-clients.json` |
| `DATA_ROOT` | Base host directory for all app state (default `/app`) |
| `ASPNETCORE_ENVIRONMENT` | `Production`. `Development` disables HTTPS enforcement — only for local testing. |

### Changing secrets after first run

MathAuth seeds clients and the admin user **once** and then skips anything that
already exists. Editing a secret or redirect URI in `oidc-clients.json`
(or the admin password in `.env`) therefore does not update the database. To
apply a change:

```bash
# per client: delete it, then recreate on next start
docker compose exec mathauth sh -c \
  "apt-get update -qq && apt-get install -y -qq sqlite3 && \
   sqlite3 /app/data/mathauth.db \"delete from OpenIddictApplications where ClientId='mathahub';\""
docker compose restart mathauth
```

Or start clean: `docker compose down && sudo rm -rf /app/mathauth/data`
(this also deletes users). Passwords are better changed through MathAuth's own
UI at `AUTH_PUBLIC_URL/Account/ChangePassword`.

## Operations

```bash
docker compose ps
docker compose logs -f mathauth
docker compose pull && docker compose up -d     # deploy the tags in images.yml
docker compose down                             # stop (state on disk survives)
```

### Updating

Image tags are pinned in [`images.yml`](images.yml) as commit SHAs. After a
successful build on its default branch, each app's CI commits its new tag there
(needs a `MATHA_WEB_TOKEN` secret with write access to this repo). To deploy or
roll back by hand, edit `images.yml` or `git revert` a bump.

`scripts/update.sh` pulls this repo and the images, for cron. Compose
recreates only the services whose image actually changed — everything else
keeps running, tunnel included:

```bash
sudo tee /etc/cron.d/matha-web-update >/dev/null <<'EOF'
0 */6 * * * root /app/matha-web/scripts/update.sh > /var/log/matha-web-update.log 2>&1
EOF
```

Adjust the path to wherever this repo lives. The cron.d filename must not
contain a dot or cron ignores the file.

A single `>` means the log holds only the most recent run — it never grows and
needs no rotation. Each run opens with a `=== <timestamp>` header so you can
tell when it last fired.

### Backups

Everything lives under `DATA_ROOT` — users, clients, tokens, data-protection
keys, checklists, link configs and certificates — and, with the repo checked out
at `/app/matha-web`, `.env` too.

`scripts/backup.sh` tars the whole directory and prunes archives older than 60
days:

```bash
sudo tee /etc/cron.d/matha-web-backup >/dev/null <<'EOF'
30 3 * * * root /app/matha-web/scripts/backup.sh > /var/log/matha-web-backup.log 2>&1
EOF
```

| Variable | Default | |
|---|---|---|
| `DATA_ROOT` | `/app` | what gets archived (read from `.env`) |
| `BACKUP_DIR` | `/var/backups/matha-web` | where archives land — must be outside `DATA_ROOT` |
| `KEEP_DAYS` | `60` | retention |

Archives are named `app-YYYY-MM-DD.tar.gz`, written `0600` in a `0700`
directory: they contain client secrets, signing certificates and `.env`, so
treat one like a password file, and copy it off the box if you want the backup
to survive losing the box.

The tar runs against a live stack. The SQLite databases are small and quiet
enough that this is fine in practice, but it is a hot copy — if you want a
guaranteed-consistent snapshot, `docker compose stop` before it and `start`
after, at the cost of a few seconds of downtime.

### Local debugging

There are no published ports. To reach a container directly:

```bash
docker compose exec mathauth sh
docker run --rm --network matha-web_matha busybox wget -qO- http://mathauth:8080/health
```

MathaHub exposes `/health`, the Checklist `/api/health`, MathAuth `/health`;
AdventRunner has none — `GET /` returns the SPA, and its API answers 403 without
a bearer token.
Note that OpenIddict rejects plain-HTTP requests in `Production`, so hitting
`http://mathauth:8080/connect/authorize` directly will fail — that is expected;
through the tunnel Cloudflare sets `X-Forwarded-Proto: https` and all three
apps honour it.

## Building from source instead of pulling images

Clone the repos next to this one and initialise the submodules of the three
matha apps (`git submodule update --init --recursive` — each needs
`shared/matha-ui`; AdventRunner has none), then
uncomment the `build:` blocks in `docker-compose.yml` and run
`docker compose up -d --build`.
