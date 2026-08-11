# MeshCore island bridge guide

Joins two MeshCore islands into a single mesh by carrying raw packets over an Isthmus tunnel. Unlike the `@token` gateway — which relays *messages* through our own identity — this replays whole `mesh::Packet`s verbatim, so adverts, DMs, ACKs and path discovery all cross. Nodes on the far island appear as ordinary mesh neighbours, and because the bridge repeaters take part in path discovery, discovery and reachability arrive together. No ghost contacts.

This is the first time MeshCore runs as a tunnel **payload**. The companion protocol cannot do it: it only surfaces traffic addressed to us, and its `CMD_SEND_RAW_DATA` builds a `RAW_CUSTOM` app packet from our own identity rather than replaying the original.

## How it fits together

```
Island A (906.875 MHz)                        Island B (910.5 MHz)
  Heltec #1 (USB companion)                     Heltec #2 (BLE + phone)
            |                                             |
        Wio #1 (bridge repeater)              Wio #2 (bridge repeater)
            |  USB CDC packet port                        |
            +------------ Isthmus, tunnel between --------+
```

| Piece | Module | Role |
| --- | --- | --- |
| Frame codec | `Isthmus.Networks.MeshCore.BridgeFrame` | `0xC03E` framing, Fletcher-16, stream resync |
| Serial link | `Isthmus.Networks.MeshCore.BridgeLink` | Owns the packet port, forwards inbound, injects outbound |
| Outbound | `Isthmus.Tunnel.Bridge.forward_packet/3` | Hash dedup and `from_tunnel` loop prevention |
| Inbound | `MeshCore.inject_raw/2` | Preferred over `send_raw/2` by `Tunnel.Engine` |

## Wire format

Six bytes of overhead, all fields big-endian, matching `BridgeSerialFramer` in the firmware:

```
[0]        0xC0
[1]        0x3E
[2..3]     payload length (1..256; zero and oversized are rejected)
[4..4+n-1] raw mesh packet
[4+n..5+n] Fletcher-16 over the payload only
```

The serial path is **not** encrypted. `BridgeCodec`'s XOR secret applies to the ESP-NOW bridge, which uses a different layout with no length field.

`test/isthmus/networks/mesh_core/bridge_frame_test.exs` pins golden vectors generated from the firmware's own encoder. If they ever fail, the two implementations have diverged on the wire.

## Firmware

> For a full, copy‑pasteable build‑and‑flash recipe (PlatformIO install, UF2 flashing, and CLI config), see [`meshcore_bridge_firmware_build.md`](./meshcore_bridge_firmware_build.md). The summary below is the short version.

Repeater firmware from **[synalysis/MeshCore](https://github.com/synalysis/MeshCore)** (`main`). Upstream MeshCore does not ship USB-serial island-bridge binaries.

USB dual-CDC (CDC 0 = CLI, CDC 1 = packets — one cable, no UART wiring):

```bash
git clone https://github.com/synalysis/MeshCore.git
cd MeshCore
pio run -e WioTrackerL1_repeater_bridge_usbserial
pio run -e WioTrackerL1_repeater_bridge_usbserial -t create_uf2
```

Other USB-serial repeater envs in the same repo: `RAK_4631_repeater_bridge_usbserial`, `SenseCap_Solar_repeater_bridge_usbserial`. CLI stats: `get bridge.rxstats`, `get bridge.txstats`, `bridge.stats reset`.

Flash by double-tap reset and dragging `firmware.uf2` onto the mass-storage volume (or use the 1200 bps‑touch software trigger described in the build guide).

**If the second CDC does not enumerate**, fall back to a hardware UART: drop `WITH_USB_SERIAL_BRIDGE` and use `-D WITH_RS232_BRIDGE=Serial1` with `-D WITH_RS232_BRIDGE_RX=PIN_WIRE1_SDA -D WITH_RS232_BRIDGE_TX=PIN_WIRE1_SCL`. `variant.h` wires `Serial1` to the GPS on pins that aren't exposed, but `RS232Bridge::begin()` calls `setPins()` at runtime, so it can be repointed onto the Grove port and reached with a 3.3V USB-TTL adapter.

## Device configuration

Per bridge repeater, over the **CLI** port:

```
set repeat on
set bridge.enabled on
set radio 906.875,62.5,8,5     # island B: 910.5 — needs a reboot to apply
reboot
```

`bridge.source` selects which packets cross: `logTx` (default, packets the repeater retransmits, already filtered by its forwarding rules) or `rx` (everything heard). Start with the default. `bridge_delay` defaults to 500 ms per packet and is worth tuning once traffic flows.

Run the two islands on different frequencies. At MeshCore's default 62.5 kHz bandwidth, 3.6 MHz of separation is roughly 58 bandwidths, and a receiver cannot demodulate outside its own bandwidth. That makes the end-to-end test conclusive: the two companions physically cannot hear each other, so anything that arrives came through the bridge.

## Isthmus configuration

By default Isthmus **auto-detects** roles on USB serial ports:

| Role | How detected | Process |
| --- | --- | --- |
| Companion | Companion Protocol `DEVICE_QUERY` | `Companion` |
| Bridge CLI | Text `ver` reply | `BridgeCLI` (radio config) |
| Bridge packet | Sibling CDC of the CLI (same USB serial) | `BridgeLink` |

Optional env overrides pin a port when several devices are attached:

```bash
# ISTHMUS_MESHCORE_PORT=/dev/ttyACM2              # companion
# ISTHMUS_MESHCORE_BRIDGE_CLI_PORT=/dev/ttyACM0   # repeater CLI (CDC 0)
# ISTHMUS_MESHCORE_BRIDGE_PORT=/dev/ttyACM1       # repeater packets (CDC 1)
```

Never point the packet port at the CLI console — CLI text is counted as resync noise.

Left undetected / unset, `BridgeLink` and `BridgeCLI` stay `:disabled`.

Health and radio configuration live on `/admin/meshcore` (detected devices, companion / repeater RF forms, frames in/out, checksum errors). A bridged network is called out on `/admin/topology`.

## Staged bring-up

Each stage isolates one unknown, so a failure points at a single layer.

1. **Codec and transport.** One Wio flashed and plugged in. Confirm two serial ports enumerate, set the bridge port, and watch a companion's adverts arrive. Frames in should climb while checksum errors stay at zero. Needs only two devices.
2. **Island to island, no tunnel.** Both Wios on the host at their two frequencies, forwarded in process. Proves packet flow in both directions.
3. **Insert the tunnel.** Create a tunnel peer with payload `meshcore` and any carrier, and confirm delivery reaches the serial write rather than the companion. A `{:error, :bridge_disabled}` delivery result means the bridge port is unset.
4. **Round trip.** From the phone on Heltec #2, message the contact on Heltec #1 learned across the bridge, and confirm the reply routes back.

### Bench conditions

At a metre with +22 dBm, each radio delivers roughly -10 dBm into its neighbour, enough to desensitise the front end or make channel-activity detection hold off transmits. Both show up as *missed* packets, so the rig looks broken when it is not. Before blaming the bridge:

- `set tx 0` on all four devices, and separate the two islands physically if you can.
- `set int.thresh 0` if radios stall instead of transmitting.
- Optionally give each island a different spreading factor, for quasi-orthogonality on top of the frequency split.

Do not remove antennas to attenuate — transmitting into an open circuit can damage the PA.

## Carrier delivery over Reticulum: broadcast vs addressed

When the carrier is Reticulum, tunnel frames can travel two ways:

- **Addressed (default).** The sidecar exposes a dedicated `isthmus.tunnel` SINGLE destination. Each side announces its own tunnel destination; the sender encrypts the frame to the peer's announced tunnel identity so only that peer receives it. Set the peer's tunnel destination hash (shown first under **Your ref on reticulum** on `/admin/tunnels`) as the `peer_ref`. Until the peer's identity and a path are known the sidecar returns `no_path` and the send **falls back to broadcast**, requesting a path (throttled) so a later frame can go direct. Frames larger than an RNS single-packet MDU also fall back to broadcast.
- **Broadcast (`ISTHMUS_TUNNEL_ADDRESSED=0`).** `Reticulum.send_raw/2` injects the opaque ISTH frame onto the RNS interface (via a connected MeshChat `IsthmusInterface`, or `Transport.inbound` on the sidecar). It is *not* addressed to a destination — every node on that RNS segment receives every frame and drops the ones whose `tunnel_id` it doesn't recognise. Simple and needs no path, but it amplifies traffic with more islands or other RNS nodes on the segment.

Addressed mode runs on **both** ends by default: exchange the new tunnel refs and keep `tunnel_id` paired as usual — addressing decides *who receives* the frame, `tunnel_id` still decides *which tunnel* it belongs to.

## Things to keep in view

This is an all-or-nothing mesh merge. Every forwarded packet crosses, so each island absorbs the other's airtime and regional duty-cycle limits apply to the union. The firmware has no filtering hook, so any policy has to live in Isthmus, dropping packets before the tunnel or before the serial write.

The serial link is unauthenticated by design, so both ports are trust boundaries: anything written to the bridge port is transmitted on the mesh verbatim.

Loop prevention is layered. The firmware's `_seen_packets` suppresses echoes of what it just transmitted, and `BridgeLink.inject/1` additionally marks each injected packet via `Tunnel.Bridge.mark_forwarded/1` so an echo that does arrive is not sent back down the tunnel.
