# Meshtastic adapter guide

Isthmus treats each mesh stack as a pluggable `Isthmus.NetworkAdapter`. Meshtastic is registered as a **stub** (`Isthmus.Networks.Meshtastic`) so the identity registry, QR UX, and health surfaces can grow without rewriting the gateway core.

## Goals

1. Mint / bind a Meshtastic node id as an identity leg on a registration group.
2. Bridge DMs between Meshtastic and Nostr / MeshCore / RNS via the existing `Gateway.Translator`.
3. Optionally carry opaque tunnel frames (`send_raw/2`) when a Meshtastic channel is used as a transport island.

## Suggested implementation steps

### 1. Transport client

Choose one host API and wrap it in a GenServer similar to `Isthmus.Networks.MeshCore.Companion`:

- Serial / TCP to a Meshtastic device running serial API
- Or MQTT / protobuf over TCP if you already run a Meshtastic gateway

Expose:

- `health/0`
- `send_text(node_id, body)`
- inbound PubSub topic `"meshtastic:inbound"` with `{:meshtastic_dm, attrs}`

### 2. Complete the adapter

In `lib/isthmus/networks/meshtastic.ex`:

- Replace stub `generate_proxy_identity/1` with radio-backed node ids when available
- Implement `send_message/3` → companion send
- Subscribe translator to `"meshtastic:inbound"` (mirror MeshCore / Reticulum handlers)

### 3. Registration policy

Decide whether self-service Nostr registration also mints a Meshtastic proxy by default, or only when an admin enables it. Keep private keys out of QR payloads.

### 4. Governor

Reuse `Announce.Governor` budgets for `:meshtastic` airtime. Prefer delta / allowlisted node announcements — never flood the mesh.

### 5. QR / handoff

Prefer official Meshtastic deep links or `!xxxxxxxx` node ids. Keep `identity_presentations/2` as the single UI contract so `/me` stays unchanged.

## Non-goals (for the stub)

- Full Meshtastic admin UI inside Phoenix
- Replacing native Meshtastic clients for chat
- Cross-signing Meshtastic crypto with Nostr keys

## Status checklist

- [x] Adapter module + registry entry (`:meshtastic`)
- [x] Placeholder identity / QR presentation
- [x] Opaque tunnel `send_raw/2` via in-memory `Meshtastic.Transport`
- [ ] Live radio/MQTT transport
- [ ] Gateway translator inbound/outbound
- [ ] Admin health card + chaos tests against airtime budgets
