# matha-web

Docker Compose deployment for three apps behind a single Cloudflare Tunnel:

| App | Repo | Internal address |
|---|---|---|
| MathAuth (SSO / OIDC provider) | [bibliothek/mathauth](https://github.com/bibliothek/mathauth) | `http://mathauth:8080` |
| MathaHub (link dashboard) | [bibliothek/matha-hub](https://github.com/bibliothek/matha-hub) | `http://mathahub:8080` |
| Extensible Checklist | [bibliothek/extensible-checklist](https://github.com/bibliothek/extensible-checklist) | `http://extensible-checklist:8080` |

No host ports are published. The only inbound path is `cloudflared`, which
reaches the apps over the internal compose network.

MathaHub and the Checklist authenticate against MathAuth over OIDC. The client
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

### Cloudflare Tunnel

Zero Trust dashboard → **Networks → Tunnels → Create a tunnel** (Cloudflared),
copy the token into `TUNNEL_TOKEN`, then add three public hostnames:

| Public hostname | Service |
|---|---|
| `auth.thaller.space` | `http://mathauth:8080` |
| `hub.thaller.space` | `http://mathahub:8080` |
| `checklist.thaller.space` | `http://extensible-checklist:8080` |

Cloudflare creates the proxied `CNAME → <tunnel-id>.cfargotunnel.com` records
itself, since `thaller.space` is on the same account. Nothing needs to be opened
on the server — the tunnel is outbound-only.

All three names currently exist as DNS-only CNAMEs to Azure App Service, so
adding them as public hostnames **replaces those records and cuts traffic over
from Azure**. Delete the old CNAMEs first if the dashboard refuses to overwrite.

Do **not** put the apps behind Cloudflare Access: MathaHub and the Checklist
fetch OIDC metadata and tokens from `AUTH_PUBLIC_URL` server-side, and Access
would block those calls.

### Migrating from Azure App Service

MathAuth's users, clients and tokens live in its SQLite DB. To keep the existing
accounts, copy them off the Azure Files share before cutting over:

```
mathauth.db        → /app/mathauth/data/mathauth.db
data-protection keys → /app/mathauth/data/keys/
signing/encryption PFXs → /app/mathauth/certs/
checklist.db       → /app/extensible-checklist/data/checklist.db
```

A copied `mathauth.db` already contains the client registrations, and MathAuth
never re-seeds an existing `ClientId` — so `oidc-clients.json` is ignored and
`MATHAHUB_CLIENT_SECRET` / `CHECKLIST_CLIENT_SECRET` in `.env` must be the
secrets Azure was using. Starting fresh instead means new accounts.

## Configuration

`/app/mathauth/config/oidc-clients.json` holds the client registrations (ids,
secrets, redirect URIs). Everything else is driven by `.env`:

| Variable | Purpose |
|---|---|
| `AUTH_PUBLIC_URL` | MathAuth's tunnel hostname, used as the OIDC issuer. No trailing slash. |
| `TUNNEL_TOKEN` | Cloudflare Tunnel token |
| `MATHAUTH_ADMIN_USERNAME` / `MATHAUTH_ADMIN_PASSWORD` | Admin account, seeded on first start (min. 8 chars) |
| `MATHAUTH_SIGNING_CERT_PATH` / `MATHAUTH_ENCRYPTION_CERT_PATH` / `MATHAUTH_CERT_PASSWORD` | Token certificates, mounted from `DATA_ROOT/mathauth/certs` |
| `MATHAHUB_CLIENT_ID` / `MATHAHUB_CLIENT_SECRET` | MathaHub's credentials — must match `oidc-clients.json` |
| `CHECKLIST_CLIENT_ID` / `CHECKLIST_CLIENT_SECRET` | The Checklist's credentials — must match `oidc-clients.json` |
| `*_IMAGE` | Image tags to deploy |
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
docker compose pull && docker compose up -d     # deploy new images
docker compose down                             # stop (state on disk survives)
```

### Updating MathaHub / Checklist

Only `mathauth` publishes a `:latest` tag; the other two images are tagged per
commit. Grab the current tag and bump `.env`:

```bash
curl -s https://hub.docker.com/v2/repositories/mthaller/mathahub/tags?page_size=1 \
  | grep -o '"name":"[^"]*"' | head -1
```

### Backups

Everything lives under `DATA_ROOT` — users, clients, tokens, data-protection
keys, checklists, link configs and certificates — plus `.env` in this repo.

```bash
sudo tar czf "matha-web-$(date +%F).tar.gz" -C /app mathauth mathahub extensible-checklist
```

### Local debugging

There are no published ports. To reach a container directly:

```bash
docker compose exec mathauth sh
docker run --rm --network matha-web_matha busybox wget -qO- http://mathauth:8080/health
```

MathaHub exposes `/health`, the Checklist `/api/health`, MathAuth `/health`.
Note that OpenIddict rejects plain-HTTP requests in `Production`, so hitting
`http://mathauth:8080/connect/authorize` directly will fail — that is expected;
through the tunnel Cloudflare sets `X-Forwarded-Proto: https` and all three
apps honour it.

## Building from source instead of pulling images

Clone the three repos next to this one, initialise their submodules
(`git submodule update --init --recursive` — each needs `shared/matha-ui`), then
uncomment the `build:` blocks in `docker-compose.yml` and run
`docker compose up -d --build`.
