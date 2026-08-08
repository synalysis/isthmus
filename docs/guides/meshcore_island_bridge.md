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

Repeater firmware built with `WITH_RS232_BRIDGE`. Upstream ships **no** prebuilt bridge binaries for any board, so a build is unavoidable.

Use MeshCore PR [#2959](https://github.com/meshcore-dev/MeshCore/pull/2959), which puts the bridge stream on a second USB CDC interface — CDC 0 stays the CLI, CDC 1 carries packets. One plain USB cable, no UART wiring, no USB-TTL adapter.

```bash
git clone https://github.com/meshcore-dev/MeshCore.git
cd MeshCore
git fetch origin pull/2959/head:pr-2959 && git checkout -b isthmus-bridge pr-2959

# Bridge fixes worth having; both touch code we depend on
git cherry-pick 3d168838   # nRF52 RS232 bridge baud init (#3018)
git cherry-pick beb91173   # bridge framing/queue helpers (#3038)
git cherry-pick 7babfaaa   # queue RS232 frames instead of dropping them (#3038)
```

`beb91173` conflicts only in `platformio.ini` and an unrelated variant; keep its `test_filter` lines. It also adds two sources that the Arduino targets do not pick up on their own, so add them to `arduino_base.build_src_filter`:

```ini
  +<helpers/bridges/BridgeFrameQueue.cpp>
  +<helpers/bridges/BridgeTxQueue.cpp>
```

Then add a Wio Tracker env. `WITH_RS232_BRIDGE` names a Stream object rather than being a boolean — `MyMesh.cpp` does `bridge(&_prefs, WITH_RS232_BRIDGE, ...)` — which is why it points at the PR's `bridgeSerial` CDC instance:

```ini
[env:WioTrackerL1_repeater_bridge_usbserial]
extends = WioTrackerL1
build_src_filter = ${WioTrackerL1.build_src_filter}
  +<helpers/bridges/RS232Bridge.cpp>
  +<../examples/simple_repeater>
build_flags =
  ${WioTrackerL1.build_flags}
  -D ADVERT_NAME='"Isthmus Bridge"'
  -D ADMIN_PASSWORD='"password"'
  -D MAX_NEIGHBOURS=50
  -D DISPLAY_CLASS=SH1106Display
  -D WITH_RS232_BRIDGE=bridgeSerial
  -D WITH_USB_SERIAL_BRIDGE
  -D CFG_TUD_CDC=2
  -UENV_INCLUDE_GPS
lib_deps = ${WioTrackerL1.lib_deps}
  adafruit/RTClib @ ^2.1.3
```

```bash
pio run -e WioTrackerL1_repeater_bridge_usbserial
pio run -e WioTrackerL1_repeater_bridge_usbserial -t create_uf2
```

Flash by double-tap reset and dragging `firmware.uf2` onto the mass-storage volume.

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
