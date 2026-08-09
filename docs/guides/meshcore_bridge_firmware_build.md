# Building the MeshCore bridge firmware (Wio Tracker L1)

Step‑by‑step, reproducible recipe for building and flashing the **Isthmus
bridge** firmware — the MeshCore repeater that joins two islands over a tunnel.
Target board: **Seeed Wio Tracker L1** (nRF52840). The bridge stream rides on a
second USB CDC interface (CDC 0 = CLI, CDC 1 = raw packets), so one USB cable is
all you need — no UART wiring.

For how the bridge fits into the wider system, see
[`meshcore_island_bridge.md`](./meshcore_island_bridge.md).

## Source of truth

The firmware lives in a **MeshCore fork** checked out at
`~/projects/meshcore-isthmus` (branch `isthmus-bridge`). On top of upstream
MeshCore `v1.16.0` it adds:

- **USB‑CDC bridge transport** (`feat: add USB CDC bridge transport support`)
  and the Wio Tracker L1 bridge env (`Add Wio Tracker L1 USB serial bridge
  repeater env`).
- **Bridge framing, frame queue and tx pacing helpers** + the nRF52 RS232 baud
  fix and the "queue instead of drop" fix.
- **Bridge stats CLI**: `get bridge.rxstats`, `get bridge.txstats`, and a
  top‑level `bridge.stats reset`.
- A **custom repeater UI** for `examples/simple_repeater` — a 4‑screen,
  joystick‑navigable display (see [below](#the-custom-repeater-ui)).

> **Important — some of this is uncommitted.** The transport/queue/stats work is
> committed, but the custom UI (`examples/simple_repeater/UITask.{cpp,h}`,
> `MyMesh.h`) and the `-D UI_HAS_JOYSTICK=1` line in the Wio env are currently
> **working‑tree changes**, and `tools/dump_bridge_vectors.cpp` is untracked.
> Commit them (and push to your own fork) before relying on this for the long
> term or sharing with others — otherwise the joystick UI can be lost on a
> `git checkout`/reset. See [Making it shareable](#making-it-shareable).

## Versions pinned by this recipe

| Component | Value |
| --- | --- |
| Upstream base | MeshCore `v1.16.0` |
| Board | `seeed-wio-tracker-l1`, SoftDevice S140 7.3.0 |
| PlatformIO Core | 6.1.19 |
| PlatformIO env | `WioTrackerL1_repeater_bridge_usbserial` |

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
  -D UI_HAS_JOYSTICK=1
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
- `UI_HAS_JOYSTICK=1` enables the joystick navigation in the custom UI. Without
  it the UI falls back to the single user button (which just wakes the OLED).
- `MomentaryButton.cpp` is compiled via `arduino_base`, so it doesn't need to be
  listed here.

## 2. The custom repeater UI

`examples/simple_repeater/UITask.{cpp,h}` replace the stock single‑screen UI
with **four screens**, and `UITask.h` sets `#define UI_HAS_BRIDGE 1` so the
bridge page is always present:

| # | Screen | Shows |
| --- | --- | --- |
| 1/4 | **Home** | node name, FREQ, BW/SF, CR/TX power |
| 2/4 | **Radio** | packets RX/TX, last RSSI/SNR |
| 3/4 | **Bridge** | bridge state (running/stopped), `IN` delivered, `DUP` |
| 4/4 | **Node** | uptime, battery mV, firmware version |

Navigation (when `UI_HAS_JOYSTICK`):

- **Joystick left / right** — previous / next screen (wraps around).
- **User button (joystick press)** click — next screen; **long‑press** — turn the
  OLED off.
- **Back button** — jump to Home.
- Any input first **wakes** the OLED if it auto‑off'd (30 s timeout); the header
  shows the page indicator (`1/4` … `4/4`).

The bridge page reads live counters via `MyMesh::getBridge()`; the same data is
available over the CLI (next section).

## 3. Build and create the UF2

```bash
cd ~/projects/meshcore-isthmus
ENV=WioTrackerL1_repeater_bridge_usbserial

~/.venvs/pio/bin/pio run -e "$ENV"
~/.venvs/pio/bin/pio run -e "$ENV" -t create_uf2
# -> .pio/build/$ENV/firmware.uf2   (~890 KB; flash usage ~55%)

cp .pio/build/$ENV/firmware.uf2 ~/Downloads/isthmus-bridge-WioTrackerL1.uf2
```

## 4. Flash the UF2

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

## 5. Configure the device over the CLI

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

## 6. Hand off to Isthmus

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

## Making it shareable

For "anyone can rebuild this," the fork's changes need to be committed and
pushed somewhere clonable:

```bash
cd ~/projects/meshcore-isthmus
git add examples/simple_repeater/UITask.cpp \
        examples/simple_repeater/UITask.h \
        examples/simple_repeater/MyMesh.h \
        variants/wio-tracker-l1/platformio.ini \
        tools/dump_bridge_vectors.cpp
git commit -m "Isthmus bridge: 4-screen joystick repeater UI + Wio joystick env"

# point origin at your own fork, then:
git push -u <your-fork> isthmus-bridge
```

Then this whole guide reduces to: clone that fork/branch → §0 install PlatformIO
→ §3 build → §4 flash → §5 configure.

## Appendix: reconstructing the transport from upstream (no fork)

If you only have upstream MeshCore and want the **bridge transport** (not the
custom 4‑screen UI), you can assemble it from PRs:

```bash
git clone --filter=blob:none https://github.com/meshcore-dev/MeshCore.git
cd MeshCore
git fetch origin pull/2959/head:pr-2959            # 2nd USB-CDC bridge stream
git checkout -b isthmus-bridge pr-2959
git fetch origin pull/3018/head:pr-3018 pull/3038/head:pr-3038
git cherry-pick 3d168838                            # nRF52 RS232 baud init (#3018)
git cherry-pick beb91173                            # framing/queue/tx pacing (#3038)
git cherry-pick 7babfaaa                            # queue instead of drop  (#3038)
```

Resolve the `beb91173` conflicts: in root `platformio.ini` keep the incoming
`test_filter` lines, and `git rm -f variants/heltec_rc32/platformio.ini`. Then
add `+<helpers/bridges/BridgeFrameQueue.cpp>` and
`+<helpers/bridges/BridgeTxQueue.cpp>` to `[arduino_base] build_src_filter`, and
add the env from §1. This yields a working bridge with the **stock** repeater UI
(single screen, button wakes OLED) — the 4‑screen joystick UI only exists in the
fork above.

## Troubleshooting

- **Second CDC doesn't enumerate.** Fall back to a hardware UART: drop
  `WITH_USB_SERIAL_BRIDGE` and use `-D WITH_RS232_BRIDGE=Serial1` with
  `-D WITH_RS232_BRIDGE_RX=PIN_WIRE1_SDA -D WITH_RS232_BRIDGE_TX=PIN_WIRE1_SCL`,
  reached with a 3.3 V USB‑TTL adapter on the Grove port.
- **`Permission denied` opening `/dev/ttyACM*`.** Your shell isn't in the
  `dialout` group for this session — prefix commands with `sg dialout -c '…'`
  or add yourself to the group and re‑login.
- **`get bridge.rxstats` says `Unknown command`.** You're not running this fork
  (stock firmware) — rebuild from `~/projects/meshcore-isthmus`.
- **1200 bps touch does nothing.** The current firmware may not support it; use
  the physical double‑tap reset instead.
