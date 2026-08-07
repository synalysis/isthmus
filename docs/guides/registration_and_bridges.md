# Registration and bridge groups

Isthmus has two identity models that share the same gateway fan-out path.

## Registration (minted proxies)

You own a **primary** identity on one network. Isthmus mints **proxy** identities on the others and stores any private material in the vault.

| Primary | Minted |
|---|---|
| Nostr (session npub) | Reticulum LXMF dest + MeshCore contact |
| MeshCore pubkey / contact URI | Nostr keypair + Reticulum dest |
| Reticulum destination hash | Nostr keypair + MeshCore contact (+ RNS receive inbox proxy) |

Self-service: `/register` (when policy allows). Admin can still create via APIs with `created_by: "admin"`.

## Bridge groups (attached real identities)

Admin creates a **bridge** group and **attaches** real Nostr / MeshCore / Reticulum identities.
No keys are minted for attached members. When a message arrives from (or addressed to) any
member, Isthmus forwards to every other member.

**RNS caveat:** an attached Reticulum hash (e.g. MeshChatX) is an *external* peer. Isthmus
cannot announce it — only the peer app can. Channel bridges also mint an Isthmus-owned
**RNS proxy** (announceable inbox / LXMF source). Existing bridges without one: Admin →
Groups → **Mint RNS proxy**, or `/me` → **Mint RNS proxy**. Use **Request path** on the
attached member so Isthmus can learn how to deliver *to* MeshChatX.

Attach the **LXMF destination** hash used for messaging when possible — not the identity
hash from MeshChatX’s “Identity &lt;…&gt; loaded” banner. Those differ; Isthmus remaps a known
identity hash to `lxmf.delivery` after the peer has announced.

Use this when everyone already has working identities and you only need a cross-network fan-out.

Manage under **Admin → Groups** (`/admin/registrations`).

## MeshCore companion constraint

One USB/BLE companion = one RF inbox. Isthmus cannot receive as N minted MeshCore pubkeys on that radio.

Disambiguation when several groups are active:

1. Sender `from_ref` matches a MeshCore **primary** or **member** leg
2. Message body starts with `@token` (slug of the group display name, or an 8-hex identity prefix)
3. Single active group fallback

Example: `Alice Camp` → token `@alice-camp`. Send to the companion:

```text
@alice-camp hello from the trail
```

Isthmus strips the token before forwarding. See `/me` for your group’s token.

## Delivery rules

| Leg role | Outbound destination |
|---|---|
| `primary` / `member` | Always `identity_ref` (real contact / dest / npub) |
| MeshCore / RNS `proxy` | Last peer who messaged that group, or `ISTHMUS_MESHCORE_PEER` / `ISTHMUS_RNS_PEER` |
| Nostr `proxy` | Ingress only (not DMed outbound) |

Gateway direction policy still applies to both registration and bridge traffic.

## Diagnosing MeshCore companion USB

Stop Phoenix first (it holds the serial port), then:

```bash
# Device handshake (DEVICE_QUERY + APP_START)
sg dialout -c 'mix isthmus.meshcore.probe --device'

# Contacts table
sg dialout -c 'mix isthmus.meshcore.probe --contacts'

# Channel slots 0–7
sg dialout -c 'mix isthmus.meshcore.probe --channels'

# Full suite + raw frame hex
sg dialout -c 'mix isthmus.meshcore.probe'

# Optional low-level Python cross-check
sg dialout -c 'python3 scripts/meshcore_raw_probe.py /dev/ttyACM0'
```

Interpretation:

- `companion online via usb` only means the port opened — not that RPC works
- Probe `OK` on `device` / `contacts` means companion firmware is answering
- `FAIL` with outbound frames but **zero inbound** usually means wrong firmware role
  (repeater / room / KISS) or a wedged CDC interface (unplug/replug the radio)

## MeshCore channels (group chat)

MeshCore companion radios support **channels** — shared-secret group chat slots (index 0 = public, 1–7 = private). Isthmus can:

- **Sync** channel slots from the companion (`GET_CHANNEL`)
- **Create** a channel on the radio and a matching bridge group (Admin → **MeshCore** → “Create channel + bridge”)
- **Link** an existing radio channel to a bridge group (Admin → **MeshCore**)

When a bridge group has `meshcore_channel_idx` set:

- Inbound channel messages fan out to all attached Nostr / RNS / MeshCore DM members
- Inbound traffic from other networks is also posted to that MeshCore channel

Channel secrets are stored encrypted in the database. Isthmus auto-creates in slots **1–7** only (never overwrites occupied slots).

### Invite a second MeshCore device

Isthmus talks to **one** USB companion (the gateway radio). Other MeshCore devices join the same private channel via the MeshCore app — they do not need USB to Isthmus.

1. Admin → **MeshCore** → select the bridge with a linked channel
2. Click **Show channel invite**
3. On the second device, MeshCore app → join private channel using either:
   - **Secret key** — paste the channel name + 32-char hex secret from the panel
   - **QR code** — scan the QR (or paste the `meshcore://channel/add?…` URI)
4. Send a message in that channel; Isthmus fans it out to attached members (e.g. Reticulum)

Bridge membership (attach RNS / Nostr / MeshCore identities) stays under Admin → **Groups**.

Slot index is local to each radio and does not need to match. Name + secret are what matter.

DM `@token` disambiguation still applies for direct messages; channels are separate from DM legs.
