# Reticulum / LXMF

Isthmus runs its **own** Reticulum + LXMF stack in a Python sidecar (`sidecar/rns_sidecar.py`).
It does **not** attach to MeshChatX’s process. The two nodes meet on the mesh via shared
transports (AutoInterface, TCP, etc.).

## Quick start

```bash
pip install -r sidecar/requirements.txt   # rns + lxmf
./bin/dev
```

Admin → Networks should show **Reticulum** as `live`.

Config lives under a dedicated directory (default `~/.isthmus/reticulum`), not `~/.reticulum`.

| Variable | Default | Purpose |
|---|---|---|
| `ISTHMUS_RNS_CONFIGDIR` | `~/.isthmus/reticulum` | Reticulum config + storage for the sidecar |
| `ISTHMUS_RNS_STORAGE` | `$CONFIGDIR/lxmf_storage` | LXMF router storage |
| `ISTHMUS_RNS_SOCKET` | `/tmp/isthmus.sock` | Unix socket for `IsthmusInterface` |
| `ISTHMUS_RNS_PEER` | — | Fallback LXMF destination hash for replies |
| `ISTHMUS_RNS_SIDECAR` | `./sidecar/rns_sidecar.py` | Sidecar script path |
| `ISTHMUS_RNS_NODE_NAME` | `isthmus` | LXMF node name |
| `ISTHMUS_RNS_LOGLEVEL` | `3` | RNS log level |

## LXMF gateway (DMs ↔ Nostr / MeshCore)

1. Register in Isthmus (`/register`) — mints a real LXMF `lxmf.delivery` destination.
2. Share that destination hash (QR on `/me`) with MeshChatX / Sideband / NomadNet.
3. Ensure MeshChatX and Isthmus can see each other on RNS:
   - Same LAN with AutoInterface, **or**
   - Add a `TCPClientInterface` / `TCPServerInterface` in **both** configs pointing at each other.
4. Message the Isthmus proxy destination → forwarded to your Nostr identity (and MeshCore when a peer is known).

Replies Nostr → RNS go to the last RNS peer that messaged the proxy, or `ISTHMUS_RNS_PEER`.

## Optional: MeshChatX as tunnel client (`IsthmusInterface`)

Only needed for **RNS-over-MeshCore** opaque tunnels (not for LXMF gateway DMs):

```bash
mkdir -p ~/.reticulum/interfaces
cp sidecar/IsthmusInterface.py ~/.reticulum/interfaces/
```

In `~/.reticulum/config` under `[interfaces]`:

```ini
[[Isthmus Bridge]]
  type = IsthmusInterface
  enabled = yes
  isthmus_socket = /tmp/isthmus.sock
```

Restart MeshChatX. Isthmus must be running so `/tmp/isthmus.sock` exists.

## Sharing transport with MeshChatX

Isthmus uses a **separate config directory** (`~/.isthmus/reticulum`), but Reticulum’s
default `share_instance` behavior means that if MeshChatX is already running a shared
RNS instance on this host, the sidecar will usually **attach to it** and reuse its
interfaces. That is the easiest way to share LoRa/TCP/AutoInterface with MeshChatX.

Check live role and interfaces in Admin → **Reticulum** (`/admin/reticulum`):

- **client (attached)** — sharing MeshChatX’s instance (or another local master)
- **shared master** — Isthmus owns the shared socket; start MeshChatX after Isthmus if you want MeshChatX to attach instead
- **standalone** — not attached; peer via AutoInterface/TCP

When attached as **client**, Admin → Reticulum only lists the local shared-instance
link. Physical radio/TCP stats live on MeshChatX. Full stats RPC needs a matching
`rpc_key` under `[reticulum]` in both `~/.reticulum/config` and
`~/.isthmus/reticulum/config` (otherwise RNS rejects the call with
“digest sent was rejected”).

If MeshChatX is not running, Isthmus starts a standalone stack. Edit
`~/.isthmus/reticulum/config` after the first start (Admin → **Reticulum** can
add/remove `AutoInterface` / TCP interfaces and toggle `share_instance` while
preserving comments; **Apply** restarts the sidecar):

- Keep **AutoInterface** enabled on both nodes on the same L2 network.
- Or add TCP peering, e.g. MeshChatX listens and Isthmus dials:

```ini
[[TCP to MeshChatX]]
  type = TCPClientInterface
  enabled = yes
  target_host = 127.0.0.1
  target_port = 4242
```

(Use the port MeshChatX’s TCPServerInterface advertises.)

To force a fully isolated stack, set `share_instance = No` in the Isthmus RNS config
(Admin → Reticulum → share_instance **No**, then Apply) and peer explicitly via
AutoInterface/TCP. Isthmus only ever writes its own config directory — never
`~/.reticulum`.
## Troubleshooting

- **stub / not live** — `pip install rns lxmf` and restart; check logs for `RNS sidecar hello`.
- **unknown_destination_path** — peer has not announced / no path yet; message the proxy first from MeshChatX, or set `ISTHMUS_RNS_PEER`.
- **unknown_destination** on Announce — only Isthmus-owned **proxy** destinations can be
  announced. Attached bridge members (MeshChatX hashes) cannot; mint/announce the bridge
  RNS proxy instead. For proxies, this usually means keys are not loaded in the sidecar —
  remint/register and retry.
- **Permission / socket** — ensure `ISTHMUS_RNS_SOCKET` is writable; default `/tmp/isthmus.sock`.
