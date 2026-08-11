# Building the MeshCore bridge firmware (Wio Tracker L1)

Step‑by‑step, reproducible recipe for building and flashing the **Isthmus
bridge** firmware — the MeshCore repeater that joins two islands over a tunnel.
Target board: **Seeed Wio Tracker L1** (nRF52840). The bridge stream rides on a
second USB CDC interface (CDC 0 = CLI, CDC 1 = raw packets), so one USB cable is
all you need — no UART wiring.

For how the bridge fits into the wider system, see
[`meshcore_island_bridge.md`](./meshcore_island_bridge.md).

## Source of truth

Build from **[synalysis/MeshCore](https://github.com/synalysis/MeshCore)**
(`main`). That fork is upstream MeshCore plus the Isthmus USB-serial island
bridge (merged in
[PR #1](https://github.com/synalysis/MeshCore/pull/1)):

- **USB‑CDC bridge transport** — second CDC for raw packets (CLI stays on CDC 0)
- USB-serial repeater envs for **Wio Tracker L1**, **RAK4631**, and **SenseCAP Solar**
- Framing / frame queue / tx pacing, nRF52 RS232 baud fix, CLI stats
  (`get bridge.rxstats`, `get bridge.txstats`, `bridge.stats reset`)

Upstream [meshcore-dev/MeshCore](https://github.com/meshcore-dev/MeshCore) does
**not** ship these USB-serial island-bridge builds.

```bash
git clone https://github.com/synalysis/MeshCore.git
cd MeshCore
```

## Versions pinned by this recipe

| Component | Value |
| --- | --- |
| Firmware repo | `synalysis/MeshCore` `main` |
| Board (this recipe) | `seeed-wio-tracker-l1`, SoftDevice S140 7.3.0 |
| PlatformIO Core | 6.1.19 |
| PlatformIO env | `WioTrackerL1_repeater_bridge_usbserial` |
| Other USB-serial envs | `RAK_4631_repeater_bridge_usbserial`, `SenseCap_Solar_repeater_bridge_usbserial` |

## 0. Prerequisites

- `git`
- Python 3 with `venv`. **Note:** on very new Pythons (e.g. 3.14) PlatformIO
  must live in its own virtualenv — don't rely on a system `pio`.
- ~2 GB free disk for the toolchain + framework on first build.

### Install PlatformIO Core into an isolated venv

```bash
python3 -m venv ~/.venvs/pio
~/.venvs/pio/bin/pip install --upgrade pip
~/.venvs/pio/bin/pip install platformio
~/.venvs/pio/bin/pio --version      # expect: PlatformIO Core, version 6.1.x
```

Use `~/.venvs/pio/bin/pio` everywhere below (or add it to `PATH`).

## 1. The Wio Tracker L1 bridge env

In `variants/wio-tracker-l1/platformio.ini`:

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

Notes:

- `WITH_RS232_BRIDGE` names a `Stream` object (not a boolean); it points at the
  second USB‑CDC instance `bridgeSerial`, which is why `WITH_USB_SERIAL_BRIDGE`
  and `CFG_TUD_CDC=2` are set. That second CDC carries the raw packet stream.
- The published fork uses the **stock** repeater OLED UI. Bridge health is on
  the CLI (`get bridge.rxstats` / `get bridge.txstats`).
- `MomentaryButton.cpp` is compiled via `arduino_base`, so it doesn't need to be
  listed here.

## 2. Build and create the UF2

```bash
cd MeshCore   # the synalysis/MeshCore clone
ENV=WioTrackerL1_repeater_bridge_usbserial

~/.venvs/pio/bin/pio run -e "$ENV"
~/.venvs/pio/bin/pio run -e "$ENV" -t create_uf2
# -> .pio/build/$ENV/firmware.uf2   (~890 KB; flash usage ~55%)

cp .pio/build/$ENV/firmware.uf2 ~/Downloads/isthmus-bridge-WioTrackerL1.uf2
```

## 3. Flash the UF2

The nRF52840 UF2 bootloader appears as a USB mass‑storage volume labelled
**`TRACKER L1`**; dropping `firmware.uf2` on it flashes and reboots the board.

### 4a. Enter the bootloader

**Preferred — physical:** double‑tap the small **RESET** button (like a mouse
double‑click). The onboard LED fades and the `TRACKER L1` drive mounts.

**Software fallback (1200 bps touch):** if double‑tap is awkward, free the CLI
port first (stop anything holding it — e.g. the Isthmus dev server), then:

```python
# uf2_touch.py
import sys, time, serial
port = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyACM0"
s = serial.Serial(port, 1200)
try: s.dtr = False
except Exception: pass
time.sleep(0.4)
s.close()
print("touch sent")
```

```bash
# the port is owned by the 'dialout' group
sg dialout -c "~/.venvs/pio/bin/python uf2_touch.py /dev/ttyACM0"
```

### 4b. Copy the firmware

The desktop usually auto‑mounts the volume at `/run/media/$USER/TRACKER L1`
(mind the space in the label). If not, mount it with
`udisksctl mount -b /dev/sdX`.

```bash
cp ~/Downloads/isthmus-bridge-WioTrackerL1.uf2 "/run/media/$USER/TRACKER L1/"
sync
```

`INFO_UF2.TXT` on the volume should read `Board-ID: TRACKER L1`,
`SoftDevice: S140 7.3.0`. The volume disappears within a second or two as the
board reboots into the app.

> Reflashing the app does **not** wipe the internal filesystem, so a board's
> identity and `set …` config survive a firmware update.

### 4c. Confirm the bridge firmware booted

The bridge build enumerates **two** CDC interfaces:

```bash
for p in /dev/ttyACM*; do
  echo "$p -> $(udevadm info -q property -n "$p" | grep ID_USB_INTERFACE_NUM=)"
done
# ttyACM0 -> ID_USB_INTERFACE_NUM=00   (CLI)
# ttyACM1 -> ID_USB_INTERFACE_NUM=02   (raw packet bridge)
```

## 4. Configure the device over the CLI

Talk to **CDC 0** (interface `00`, usually `/dev/ttyACM0`) at 115200. Commands
are newline‑terminated; replies come back as `  -> …`.

```
set repeat on
set bridge.enabled on
set radio 906.875,62.5,8,5      # island A; use 910.5 for island B
reboot
```

`bridge.source` selects which packets cross: `logTx` (default — packets the
repeater retransmits, already filtered by its forwarding rules) or `rx`
(everything heard). Start with `logTx`.

Verify after the reboot:

```
get radio            ; -> 910.5,62.5,8,5
get repeat           ; -> on
get bridge.enabled   ; -> on
get bridge.source    ; -> logTx
get bridge.rxstats   ; -> RX in=… ok=… dup=… crc=… len=… noise=… nopar=… pool=… qfull=… hwm=…
get bridge.txstats   ; -> TX dup=… big=…
```

The `bridge.rxstats` / `bridge.txstats` counters are the quickest way to confirm
you flashed this fork (stock repeater firmware answers `Unknown command`). Reset
them with `bridge.stats reset`.

Run the two islands on **different frequencies** (e.g. A 906.875, B 910.5). At
62.5 kHz bandwidth the companions physically cannot hear each other, so anything
that arrives proves it came through the bridge.

## 5. Hand off to Isthmus

Plug the board into the Isthmus host. Isthmus auto‑detects roles on USB serial:
the CLI CDC becomes `BridgeCLI` (radio config) and its sibling CDC becomes
`BridgeLink` (packet transport). Pin ports explicitly if several devices are
attached:

```bash
# ISTHMUS_MESHCORE_BRIDGE_CLI_PORT=/dev/ttyACM0   # repeater CLI  (CDC 0)
# ISTHMUS_MESHCORE_BRIDGE_PORT=/dev/ttyACM1       # repeater pkts (CDC 1)
```

See [`meshcore_island_bridge.md`](./meshcore_island_bridge.md) for tunnel setup,
carrier delivery (broadcast vs addressed), and staged bring‑up.

## Troubleshooting

- **Second CDC doesn't enumerate.** Fall back to a hardware UART: drop
  `WITH_USB_SERIAL_BRIDGE` and use `-D WITH_RS232_BRIDGE=Serial1` with
  `-D WITH_RS232_BRIDGE_RX=PIN_WIRE1_SDA -D WITH_RS232_BRIDGE_TX=PIN_WIRE1_SCL`,
  reached with a 3.3 V USB‑TTL adapter on the Grove port.
- **`Permission denied` opening `/dev/ttyACM*`.** Your shell isn't in the
  `dialout` group for this session — prefix commands with `sg dialout -c '…'`
  or add yourself to the group and re‑login.
- **`get bridge.rxstats` says `Unknown command`.** You're not running this fork
  (stock upstream firmware) — rebuild from
  [synalysis/MeshCore](https://github.com/synalysis/MeshCore).
- **1200 bps touch does nothing.** The current firmware may not support it; use
  the physical double‑tap reset instead.
