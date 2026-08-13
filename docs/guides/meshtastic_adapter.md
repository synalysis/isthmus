# Meshtastic adapter guide

Isthmus treats each mesh stack as a pluggable `Isthmus.NetworkAdapter`. Meshtastic talks to **USB companion radios** over the serial protobuf API (`Isthmus.Networks.Meshtastic.Companion`). Each plugged-in companion is its own radio: channel slots and LoRa config belong to that device. Private channel slots can be linked to a bridge `RegistrationGroup`, the same way MeshCore companion channels are.

The **primary** companion (pinned with `ISTHMUS_MESHTASTIC_PORT`, or the first detected radio) is the named process used for group fan-out. Extra USB companions run as additional GenServers.

Opaque tunnel frames still go through the in-memory `Meshtastic.Transport` until a radio-backed raw path exists.

## Goals

1. Bridge Meshtastic **channel** traffic into an Isthmus group (Nostr / MeshCore / RNS legs).
2. Optionally bind a Meshtastic node id as an identity leg later.
3. Carry opaque tunnel frames (`send_raw/2`) when Meshtastic is a transport island.

## Companion radio

USB serial is **auto-detected** at boot (and on Rescan). The probe sends MeshCore `DEVICE_QUERY`, Meshtastic `want_config`, and repeater CLI `ver`, then RNode. A port is Meshtastic when a **FromRadio** payload arrives (`my_info`, channel, config, metadata, log, or the boot `:rebooted` frame) or the firmware prints the Meshtastic boot banner. An echo of the `want_config` ToRadio we wrote does not count — MeshCore repeater CLIs echo those bytes. Companion / CLI / `0xC0 0x3E` bridge frames win over Meshtastic. Seeed Wio Tracker L1 boards use the same USB identity for Meshtastic and MeshCore island-bridge firmware; those ports are probed with `want_config` first, and a silent dual-CDC pair is **not** claimed as MeshCore. CP210x / CH340 / Espressif USB-UART boards (Heltec Wireless Tracker, T-Beam, …) are the same: opening the port pulses DTR and Meshtastic ESP32 firmware immediately emits a FromRadio `:rebooted` frame plus the `MESHTASTIC` boot banner. Discovery listens for that **before** flushing or sending `ver`. DTR+RTS are asserted on ACM (nRF) ports so the serial API talks; CP210x/CH340 keep both clear so a second reset is not held.

Pin only to choose which radio is **primary** when several are attached:

```bash
# ISTHMUS_MESHTASTIC_PORT=/dev/ttyUSB0
```

Admin → **Meshtastic** → **Rescan USB**. Each companion is a card under **Connected radios**. **Device settings** (buzzer, LoRa region / modem) opens a modal on that card.

Each companion:

- Opens 115200 8N1 and sends `want_config` (channel table, LoRa `Config`, `MyNodeInfo`, node DB)
- Records NodeInfo as 24h Adverts sightings (`FromRadio.node_info` during config dump, plus live `NODEINFO_APP` packets). Identity is the 8-hex node id; Via is **Node DB** or **NodeInfo**.
- Publishes inbound TEXT_MESSAGE_APP broadcasts on `"meshtastic:inbound"` as `{:meshtastic_channel, attrs}`
- Sends group traffic with `send_channel_text/2` (broadcast on that slot)
- Provisions secondary slots 1–7 via AdminMessage (`get_channel` then `set_channel` with session passkey)
- Writes DeviceConfig (buzzer mode) and LoRa config (region / modem preset, or BW / SF / CR) via `get_config` then `set_config`, then reboots
- Syncs host Unix time onto the radio (`AdminMessage.set_time_only`) after each config dump, and on **Sync time**. Also writes `DeviceConfig.tzdef` (POSIX timezone from the Isthmus host, or the browser zone on **Sync time**) so the OLED shows **local** time. The RTC itself stays UTC. The admin card shows the radio clock in the browser’s local timezone. Devices without GPS or an RTC otherwise sit at epoch until a client sets time. Override with `ISTHMUS_MESHTASTIC_TZ` (IANA or POSIX).

Admin: `/admin/meshtastic`.

## Channel ↔ group

Same model as MeshCore:

| Radio | Group field | Invite |
|---|---|---|
| MeshCore slots 1–7 | `group_radio_channels` (network `meshcore`) | `meshcore://channel/add?…` |
| Meshtastic slots 1–7 | `group_radio_channels` (network `meshtastic`) | `https://meshtastic.org/e/#…?add=true` |

Slot **0** is PRIMARY (sets the radio frequency). Isthmus creates private channels in empty **secondary** slots 1–7 only. Create groups on Admin → **Groups**, then assign a group from the **Linked group** dropdown on a companion’s slot table. Slot numbers are local to each radio’s identity (Meshtastic node id / MeshCore pubkey); the same slot index on a second radio is not the same channel. The same group **can** be linked on several USB companions at once (each radio keeps its own slot + PSK). Other devices join by **name + PSK**.

LoRa **region** (country / band) and **modem preset** (Long Fast, Medium Fast, …) are per companion: open **Device settings** on that radio’s card. The same dialog has an **Alerts** section for the onboard **buzzer** (Disabled silences incoming-message beeps). Switch Modem to **Custom** for explicit bandwidth / spreading factor / coding rate and an optional override frequency. Apply writes config and reboots that companion.

When a group is linked to one or more Meshtastic radios (`group_radio_channels`):

- Inbound channel texts fan out to attached Nostr / RNS / MeshCore members
- Traffic into the group is posted back onto **each** linked Meshtastic companion (`[via Isthmus/…]`), except the radio/slot the message arrived on
- Echoes from our own node id are dropped so we do not loop

## Suggested next steps

- [x] Adapter module + registry entry (`:meshtastic`)
- [x] Placeholder identity / QR presentation
- [x] Opaque tunnel `send_raw/2` via in-memory `Meshtastic.Transport`
- [x] Live serial companion (`ISTHMUS_MESHTASTIC_PORT`)
- [x] Channel ↔ group link + translator fan-out
- [x] Admin page `/admin/meshtastic`
- [x] Provision secondary slots onto existing groups
- [x] Device settings dialog (buzzer + LoRa; extra DeviceConfig fields can be added as new sections)
- [x] Multiple USB companions (primary + extras)
- [x] NodeInfo → Admin Adverts (no MeshCore-style flood advert)
- [x] Companion RTC / `set_time_only` + admin clock display
- [ ] MQTT / TCP client (optional second transport)
- [ ] Attach Meshtastic node ids as group member legs (DM path)

## Non-goals

- Full Meshtastic device admin (Bluetooth, MQTT module, canned messages, …)
- Replacing native Meshtastic clients for chat
- Cross-signing Meshtastic crypto with Nostr keys
