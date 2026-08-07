# Isthmus

Multi-network mesh gateway for **Reticulum**, **MeshCore**, and **Nostr** (Meshtastic later).

Isthmus runs as an Elixir/OTP + Phoenix app with:

- **Transport tunnels** — join same-protocol islands via another network as carrier
- **Identity gateway** — register identities and mint trusted proxies across networks
- **NIP-07 auth** — sign in with a Nostr browser extension; admin ops allowlisted by npub
- **Self-service registration** — bind Nostr, MeshCore, or Reticulum as primary and mint proxies on the others
- **Bridge groups** — attach real identities (no minting); gateway fans out among members

## Quick start (local Mix)

```bash
export ISTHMUS_ADMIN_NPUBS=npub1youradminkeyhere
./bin/dev
```

Visit [http://localhost:4000](http://localhost:4000) (override with `PORT=4005 ./bin/dev`).

- `/login` — NIP-07 sign-in
- `/register` / `/me` — self-service identity + QR handoff
- `/admin` — relays, groups (registration + bridges), policy (admin npubs only)

Identity models: [docs/guides/registration_and_bridges.md](docs/guides/registration_and_bridges.md).
- `/healthz` / `/readyz` — liveness / readiness probes

Detect a MeshCore USB companion port:

```bash
mix isthmus.meshcore.ports
# → Suggested ISTHMUS_MESHCORE_PORT=/dev/ttyUSB0
```

Reticulum / LXMF (requires `pip install -r sidecar/requirements.txt`):

See [docs/guides/reticulum.md](docs/guides/reticulum.md). Isthmus runs its own RNS
instance under `~/.isthmus/reticulum` and peers with MeshChatX over AutoInterface/TCP.

## Docker

```bash
cp .env.example .env
# fill SECRET_KEY_BASE (mix phx.gen.secret) and ISTHMUS_VAULT_SECRET
docker compose up --build
```

Data persists in the `isthmus_data` volume at `/data/isthmus.db`.

## Render.com

`render.yaml` defines a Docker web service with a 1 GB disk mounted at `/data`.

1. Push this repo and create a Blueprint (or a Docker Web Service pointing at the Dockerfile).
2. Set `ISTHMUS_ADMIN_NPUBS` in the Render dashboard.
3. Optionally set `PHX_HOST` to your custom domain; otherwise `RENDER_EXTERNAL_HOSTNAME` is used.
4. Health check path: `/healthz`.

**Note:** MeshCore USB/BLE needs hardware access. Render suits the web/ops + Nostr side; run Docker on a host with radios when attaching companions.

## Environment

| Variable | Purpose |
|---|---|
| `PORT` | HTTP listen port (Render/Docker default 4000) |
| `PHX_HOST` | Public hostname (cookies, URLs, LiveView) |
| `RENDER_EXTERNAL_HOSTNAME` | Used as `PHX_HOST` fallback on Render |
| `DATABASE_PATH` | SQLite file path (use a persistent volume/disk) |
| `SECRET_KEY_BASE` | Phoenix cookie/session signing (`mix phx.gen.secret`) |
| `ISTHMUS_VAULT_SECRET` | Encrypts proxy private keys at rest |
| `ISTHMUS_ADMIN_NPUBS` | Comma-separated admin npubs |
| `ISTHMUS_RNS_CONFIGDIR` | Sidecar Reticulum config dir (default `~/.isthmus/reticulum`) |
| `ISTHMUS_RNS_SOCKET` | Unix socket for `IsthmusInterface` (default `/tmp/isthmus.sock`) |
| `FORCE_SSL` | `true` (default in prod) behind TLS; `false` for plain local Docker |
| `CHECK_ORIGIN` | `false` or comma-separated origins; default allows `https://$PHX_HOST` |
| `POOL_SIZE` | Ecto pool size (default 5) |

## Status

Phase 0–4 delivered: auth, registration/QR, relays, tunnels, AnnounceGovernor,
MeshCore USB companion, Nostr relay pool, **live RNS/LXMF sidecar**, gateway
translator, admin network health + forward log. See `docs/guides/reticulum.md`
for MeshChatX peering.
