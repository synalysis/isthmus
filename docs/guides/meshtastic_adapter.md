# Meshtastic adapter guide

Isthmus treats each mesh stack as a pluggable `Isthmus.NetworkAdapter`. Meshtastic talks to **USB companion radios** over the serial protobuf API (`Isthmus.Networks.Meshtastic.Companion`). Each plugged-in companion is its own radio: channel slots and LoRa config belong to that device. Private channel slots can be linked to a bridge `RegistrationGroup`, the same way MeshCore companion channels are.

The **primary** companion (pinned with `ISTHMUS_MESHTASTIC_PORT`, or the first detected radio) is the named process used for group fan-out. Extra USB companions run as additional GenServers.

Opaque tunnel frames still go through the in-memory `Meshtastic.Transport` until a radio-backed raw path exists.

## Goals

1. Bridge Meshtastic **channel** traffic into an Isthmus group (Nostr / MeshCore / RNS legs).
2. Optionally bind a Meshtastic node id as an identity leg later.
3. Carry opaque tunnel frames (`send_raw/2`) when Meshtastic is a transport island.

## Companion radio

USB serial is **auto-detected** at boot (and on Rescan). The probe talks MeshCore first (`<`/`>` companion frames, then repeater CLI), then Meshtastic (`0x94 0xC3` + `want_config`). Every port that answers with a parsed FromRadio frame (`my_info`, channel, or `config_complete`) is claimed as a Meshtastic companion.

Pin only to choose which radio is **primary** when several are attached:

```bash
# ISTHMUS_MESHTASTIC_PORT=/dev/ttyUSB0
```

Admin → **Meshtastic** → **Rescan USB**. Each companion is a card under **Connected radios**. **Radio configuration** (LoRa region / modem) opens a modal on that card.

Each companion:

- Opens 115200 8N1 and sends `want_config` (channel table, LoRa `Config`, `MyNodeInfo`, node DB)
- Records NodeInfo as 24h Adverts sightings (`FromRadio.node_info` during config dump, plus live `NODEINFO_APP` packets). Identity is the 8-hex node id; Via is **Node DB** or **NodeInfo**.
- Publishes inbound TEXT_MESSAGE_APP broadcasts on `"meshtastic:inbound"` as `{:meshtastic_channel, attrs}`
- Sends group traffic with `send_channel_text/2` (broadcast on that slot)
- Provisions secondary slots 1–7 via AdminMessage (`get_channel` then `set_channel` with session passkey)
- Writes LoRa config (region / modem preset, or BW / SF / CR) via `get_config` then `set_config`, then reboots

Admin: `/admin/meshtastic`.

## Channel ↔ group

Same model as MeshCore:

| Radio | Group field | Invite |
|---|---|---|
| MeshCore slots 1–7 | `meshcore_channel_idx` + encrypted secret | `meshcore://channel/add?…` |
| Meshtastic slots 1–7 | `meshtastic_channel_idx` + encrypted PSK | `https://meshtastic.org/e/#…?add=true` |

Slot **0** is PRIMARY (sets the radio frequency). Isthmus creates private channels in empty **secondary** slots 1–7 only. Create groups on Admin → **Groups**, then assign a group from the **Linked group** dropdown on a companion’s slot table. Slot numbers are local to each radio; other devices join by **name + PSK**.

LoRa **region** (country / band) and **modem preset** (Long Fast, Medium Fast, …) are per companion: open **Radio configuration** on that radio’s card. Switch Modem to **Custom** for explicit bandwidth / spreading factor / coding rate and an optional override frequency. Apply writes LoRa config and reboots that companion.

When a group has `meshtastic_channel_idx` set:

- Inbound channel texts fan out to attached Nostr / RNS / MeshCore members
- Traffic into the group is posted back onto that Meshtastic channel (`[via Isthmus/…]`)
- Echoes from our own node id are dropped so we do not loop

## Suggested next steps

- [x] Adapter module + registry entry (`:meshtastic`)
- [x] Placeholder identity / QR presentation
- [x] Opaque tunnel `send_raw/2` via in-memory `Meshtastic.Transport`
- [x] Live serial companion (`ISTHMUS_MESHTASTIC_PORT`)
- [x] Channel ↔ group link + translator fan-out
- [x] Admin page `/admin/meshtastic`
- [x] Provision secondary slots onto existing groups
- [x] LoRa region / modem preset / custom radio config (per-radio modal)
- [x] Multiple USB companions (primary + extras)
- [x] NodeInfo → Admin Adverts (no MeshCore-style flood advert)
- [ ] MQTT / TCP client (optional second transport)
- [ ] Attach Meshtastic node ids as group member legs (DM path)

## Non-goals

- Full Meshtastic device admin (Bluetooth, MQTT module, canned messages, …)
- Replacing native Meshtastic clients for chat
- Cross-signing Meshtastic crypto with Nostr keys
