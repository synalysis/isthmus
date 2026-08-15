#!/usr/bin/env python3
"""Isthmus BLE sidecar — length-prefixed JSON IPC ({:packet, 4}).

MeshCore uses Nordic UART Service (NUS). Meshtastic uses ToRadio / FromRadio /
FromNum. Unsolicited notifications are emitted as
{"type":"notify","address":...,"data":"<base64>"}.
"""

from __future__ import annotations

import asyncio
import base64
import json
import struct
import sys
import threading
import traceback
from typing import Any, Optional

NUS_SERVICE = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
NUS_RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
NUS_TX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

MT_SERVICE = "6ba1b218-15a8-461f-9fa8-5dcae273eafd"
MT_TORADIO = "f75c76d2-129e-4dad-a1dd-7866124401e7"
MT_FROMRADIO = "2c55e69e-4993-11ed-b878-0242ac120002"
MT_FROMNUM = "ed9da18c-a800-4f66-a670-aa7547e34453"

NAME_PREFIXES = (
    "MeshCore-",
    "Whisper-",
    "WisCore-",
    "Seeed",
    "Lilygo",
    "HT-",
    "LowMesh_MC_",
    "NRF52",
    "Meshtastic",
)

_write_lock = threading.Lock()


def write_msg(obj: dict) -> None:
    body = json.dumps(obj, default=str).encode("utf-8")
    with _write_lock:
        sys.stdout.buffer.write(struct.pack("!I", len(body)))
        sys.stdout.buffer.write(body)
        sys.stdout.buffer.flush()


def reply(req_id: Optional[str], **payload) -> None:
    msg = dict(payload)
    if req_id is not None:
        msg["id"] = req_id
    write_msg(msg)


def read_msg() -> Optional[dict]:
    header = sys.stdin.buffer.read(4)
    if not header or len(header) < 4:
        return None
    (length,) = struct.unpack("!I", header)
    body = sys.stdin.buffer.read(length)
    if not body:
        return None
    return json.loads(body.decode("utf-8"))


def _bleak_available() -> bool:
    try:
        import bleak  # noqa: F401

        return True
    except Exception:
        return False


def _name_match(name: Optional[str]) -> bool:
    if not name:
        return False
    return any(name.startswith(p) or p.lower() in name.lower() for p in NAME_PREFIXES)


def _profile_for(name: Optional[str], uuids: list[str]) -> str:
    lowered = [u.lower() for u in uuids]
    if MT_SERVICE in lowered or (name or "").startswith("Meshtastic"):
        return "meshtastic"
    return "meshcore"


def _norm_addr(address: Optional[str]) -> str:
    addr = (address or "").strip()
    if addr.lower().startswith("ble:"):
        addr = addr[4:]
    return addr.upper()


def _transient_ble_error(exc: BaseException) -> bool:
    text = str(exc).lower()
    return any(
        token in text
        for token in (
            "inprogress",
            "already in progress",
            "failed to discover services",
            "device disconnected",
            "le connection already exists",
            "powered_off",
            "no powered bluetooth",
            "not_found",
        )
    )


def _needs_pair(exc: BaseException) -> bool:
    text = str(exc).lower()
    return any(
        token in text
        for token in ("pin or key missing", "authentication", "not paired", "not trusted")
    )


class BluezPinAgent:
    """org.bluez.Agent1 — known PIN (MeshCore) or interactive wait (Meshtastic)."""

    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self.loop = loop
        self.pin = ""
        self.prompt = False
        self.address = ""
        self.name = ""
        self.bus = None
        self._registered = False
        self._future: Optional[asyncio.Future] = None

    @property
    def is_registered(self) -> bool:
        return self._registered

    async def start(self, pin: Optional[str], prompt: bool = False) -> None:
        if sys.platform != "linux":
            return
        self.pin = pin or ""
        self.prompt = prompt
        if self._registered:
            return
        try:
            from dbus_fast import BusType
            from dbus_fast.aio import MessageBus
            from dbus_fast.service import ServiceInterface, method
        except Exception:
            return

        class Agent1(ServiceInterface):
            def __init__(self, owner: "BluezPinAgent") -> None:
                super().__init__("org.bluez.Agent1")
                self.owner = owner

            @method()
            def Release(self):
                return None

            @method()
            async def RequestPinCode(self, _device: "o") -> "s":
                return await self.owner.wait_pin()

            @method()
            async def RequestPasskey(self, _device: "o") -> "u":
                return int(await self.owner.wait_pin())

            @method()
            def DisplayPasskey(self, _device: "o", _passkey: "u", _entered: "q"):
                return None

            @method()
            def DisplayPinCode(self, _device: "o", _pincode: "s"):
                return None

            @method()
            def RequestConfirmation(self, _device: "o", _passkey: "u"):
                return None

            @method()
            def RequestAuthorization(self, _device: "o"):
                return None

            @method()
            def AuthorizeService(self, _device: "o", _uuid: "s"):
                return None

            @method()
            def Cancel(self):
                self.owner.cancel_pin()
                return None

        try:
            self.bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
            self.bus.export("/isthmus/ble_agent", Agent1(self))
            intro = await self.bus.introspect("org.bluez", "/org/bluez")
            proxy = self.bus.get_proxy_object("org.bluez", "/org/bluez", intro)
            manager = proxy.get_interface("org.bluez.AgentManager1")
            await manager.call_register_agent("/isthmus/ble_agent", "KeyboardOnly")
            await manager.call_request_default_agent("/isthmus/ble_agent")
            self._registered = True
        except Exception:
            self._registered = False

    async def stop(self) -> None:
        if not self.bus:
            return
        try:
            if self._registered:
                intro = await self.bus.introspect("org.bluez", "/org/bluez")
                proxy = self.bus.get_proxy_object("org.bluez", "/org/bluez", intro)
                manager = proxy.get_interface("org.bluez.AgentManager1")
                await manager.call_unregister_agent("/isthmus/ble_agent")
        except Exception:
            pass
        try:
            self.bus.disconnect()
        except Exception:
            pass
        self.bus = None
        self._registered = False

    async def wait_pin(self) -> str:
        if not self.prompt and self.pin:
            return self.pin
        write_msg(
            {
                "type": "pin_request",
                "address": self.address,
                "name": self.name,
            }
        )
        self._future = self.loop.create_future()
        try:
            pin = await asyncio.wait_for(asyncio.shield(self._future), timeout=75.0)
            self.pin = str(pin).strip()
            return self.pin
        except asyncio.TimeoutError as exc:
            raise RuntimeError("pin_timeout") from exc
        finally:
            self._future = None

    def provide_pin(self, pin: str) -> None:
        fut = self._future
        if fut is not None and not fut.done():
            fut.set_result(str(pin).strip())

    def cancel_pin(self) -> None:
        fut = self._future
        if fut is not None and not fut.done():
            fut.set_exception(RuntimeError("pin_cancelled"))


class Sidecar:
    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self.loop = loop
        self.clients: dict[str, Any] = {}
        self.mtus: dict[str, int] = {}
        self.lock = asyncio.Lock()
        self.scanner = None
        self.agent = BluezPinAgent(loop)
        self._connecting: set[str] = set()
        self._closing: set[str] = set()
        self.known: dict[str, Any] = {}
        self.profiles: dict[str, str] = {}
        self._draining: set[str] = set()
        self._need_drain: set[str] = set()
        self._abort: set[str] = set()
        self._our_scan = False

    async def scan(self, timeout_s: float) -> list[dict]:
        from bleak import BleakScanner

        async with self.lock:
            await self._ensure_powered()
            await self._stop_scanner()
            seen = await self._known_meshcore_devices()

            def _cb(device, adv) -> None:
                name = device.name or getattr(adv, "local_name", None)
                uuids = [u.lower() for u in (getattr(adv, "service_uuids", None) or [])]
                if (
                    NUS_SERVICE not in uuids
                    and MT_SERVICE not in uuids
                    and not _name_match(name)
                ):
                    return
                addr = _norm_addr(device.address)
                self.known[addr] = device
                seen[addr] = {
                    "address": addr,
                    "name": name or "",
                    "rssi": getattr(adv, "rssi", None),
                    "kind": _profile_for(name, uuids),
                }

            # KDE / another client can keep Adapter1.Discovering true.
            # Never fight that with StopDiscovery — paired radios are in BlueZ.
            if await self._adapter_discovering():
                return list(seen.values())

            scanner = BleakScanner(detection_callback=_cb)
            self.scanner = scanner
            try:
                await self._start_scanner(scanner)
                self._our_scan = True
            except Exception as exc:
                self.scanner = None
                if "inprogress" in str(exc).lower():
                    return list(seen.values())
                raise
            try:
                await asyncio.sleep(timeout_s)
            finally:
                await self._stop_scanner()
            return list(seen.values())

    async def connect(self, address: str, pin: Optional[str], profile: str = "meshcore") -> dict:
        address = _norm_addr(address)
        self._abort.discard(address)
        async with self.lock:
            try:
                await self._ensure_powered()
                await self._stop_scanner()
                if address in self.clients:
                    await self.disconnect(address, abort=False)
                elif await self._release_orphan_connection(address):
                    # A killed sidecar can leave BlueZ Connected.
                    await asyncio.sleep(0.4)
                await self._trust_device(address)
                if address in self._abort:
                    raise RuntimeError("cancelled")
                known = self.known.get(address)
                self.agent.address = address
                self.agent.name = getattr(known, "name", None) or ""
                already_paired = await self._device_paired(address)
                # Already-bonded radios do not show a PIN. Registering as the
                # default BlueZ agent fights KDE and can leave Device.Connect stuck.
                prompt = profile == "meshtastic" and not pin and not already_paired
                if not already_paired:
                    await self.agent.start(pin, prompt=prompt)
                last_err: Optional[BaseException] = None
                want_pair = profile == "meshtastic" and not already_paired
                for attempt in range(3):
                    if address in self._abort:
                        raise RuntimeError("cancelled")
                    if attempt > 0:
                        if _needs_pair(last_err or Exception()):
                            await self._remove_device(address)
                            self.known.pop(address, None)
                            prompt = profile == "meshtastic" and not pin
                            await self.agent.start(pin, prompt=prompt)
                            want_pair = True
                        elif last_err and "inprogress" in str(last_err).lower():
                            await self._bluez_disconnect(address)
                            if attempt >= 2:
                                await self._remove_device(address)
                                self.known.pop(address, None)
                                want_pair = profile == "meshtastic"
                                if want_pair:
                                    await self.agent.start(pin, prompt=not pin)
                            await asyncio.sleep(0.5)
                        else:
                            await asyncio.sleep(0.8)
                    try:
                        return await self._connect_once(
                            address,
                            pin,
                            pair=want_pair,
                            profile=profile,
                        )
                    except Exception as exc:
                        last_err = exc
                        if "inprogress" not in str(exc).lower():
                            await self.disconnect(address, abort=False)
                        if attempt < 2 and (_transient_ble_error(exc) or _needs_pair(exc)):
                            continue
                        raise
                raise last_err or RuntimeError("connect_failed")
            finally:
                await self._stop_scanner()

    async def adapter_status(self) -> dict:
        discovering = await self._adapter_discovering()
        known = await self._known_meshcore_devices()
        devices = []
        for addr, info in known.items():
            flags = await self._bluez_device_flags(addr)
            devices.append(
                {
                    **info,
                    "paired": bool(flags.get("paired")),
                    "trusted": bool(flags.get("trusted")),
                    "connected": bool(flags.get("connected")),
                    "owned": addr in self.clients,
                }
            )
        return {
            "discovering": discovering,
            "clients": list(self.clients),
            "connecting": list(self._connecting),
            "devices": devices,
        }

    async def _resolve_device(self, address: str):
        from bleak import BleakScanner

        address = _norm_addr(address)
        device = self.known.get(address)
        if device is not None:
            return device
        # Paired radios stay in BlueZ after Isthmus restarts, even when they
        # are not advertising. BleakClient accepts the MAC on Linux.
        if await self._bluez_has_device(address):
            return address
        device = await BleakScanner.find_device_by_address(address, timeout=12.0)
        if device is not None:
            self.known[address] = device
            return device
        raise RuntimeError(f"not_found:{address}")

    async def _connect_once(
        self, address: str, pin: Optional[str], pair: bool, profile: str = "meshcore"
    ) -> dict:
        from bleak import BleakClient

        self._connecting.add(address)
        try:
            target = await self._resolve_device(address)
            client = BleakClient(
                target, disconnected_callback=self._on_disconnect, timeout=15.0
            )
            try:
                await client.connect()
            except Exception as exc:
                if "inprogress" not in str(exc).lower():
                    raise
                # A leftover Connect sits InProgress forever. Cancel it; do not
                # stack another Connect on the same Device1 object.
                await self._bluez_disconnect(address)
                if not await self._wait_device_connected(address, 2.0):
                    raise
                await client.connect()
            if pair and not bool(getattr(client, "is_paired", False)) and self.agent.is_registered:
                try:
                    await client.pair()
                except Exception:
                    pass
            mtu = getattr(client, "mtu_size", None) or 185
            self.mtus[address] = int(mtu)
            self.profiles[address] = profile
            self.clients[address] = client
            if profile == "meshtastic":
                await self._start_meshtastic(client, address)
            else:
                await self._start_meshcore(client, address)
            await asyncio.sleep(0.25)
            if not getattr(client, "is_connected", False):
                raise RuntimeError("disconnected")
            return {"address": address, "mtu": self.mtus[address], "profile": profile}
        finally:
            self._connecting.discard(address)

    async def _start_meshcore(self, client, address: str) -> None:
        def _notify(_handle, data: bytearray) -> None:
            write_msg(
                {
                    "type": "notify",
                    "address": address,
                    "profile": "meshcore",
                    "data": base64.b64encode(bytes(data)).decode("ascii"),
                }
            )

        await client.start_notify(NUS_TX, _notify)

    async def _start_meshtastic(self, client, address: str) -> None:
        def _fromnum(_handle, _data: bytearray) -> None:
            asyncio.run_coroutine_threadsafe(self._kick_drain(address), self.loop)

        await client.start_notify(MT_FROMNUM, _fromnum)
        # Do not block Connect on the first FromRadio drain — the companion
        # sends want_config as soon as the RPC returns.
        self.loop.create_task(self._kick_drain(address))

    async def _kick_drain(self, address: str) -> None:
        async with self.lock:
            await self._drain_fromradio_unlocked(address)

    async def _drain_fromradio_unlocked(self, address: str) -> None:
        if address in self._draining:
            self._need_drain.add(address)
            return
        client = self.clients.get(address)
        if client is None or not client.is_connected:
            return
        self._draining.add(address)
        try:
            while True:
                self._need_drain.discard(address)
                await self._read_fromradio(client, address)
                if address not in self._need_drain:
                    break
        except Exception:
            pass
        finally:
            self._draining.discard(address)

    async def _read_fromradio(self, client, address: str) -> None:
        empty_tries = 0
        for _ in range(512):
            raw = bytes(await client.read_gatt_char(MT_FROMRADIO))
            if not raw:
                empty_tries += 1
                if empty_tries >= 5:
                    return
                await asyncio.sleep(0.1)
                continue
            empty_tries = 0
            write_msg(
                {
                    "type": "notify",
                    "address": address,
                    "profile": "meshtastic",
                    "data": base64.b64encode(raw).decode("ascii"),
                }
            )

    async def disconnect(self, address: str, abort: bool = True) -> None:
        address = _norm_addr(address)
        if abort:
            self._abort.add(address)
        self._closing.add(address)
        try:
            await self._stop_scanner()
            await self._bluez_disconnect(address)
            client = self.clients.pop(address, None)
            self.mtus.pop(address, None)
            self.profiles.pop(address, None)
            if client is not None and getattr(client, "is_connected", False):
                await client.disconnect()
        except Exception:
            pass
        finally:
            self._closing.discard(address)

    async def write(self, address: str, data: bytes) -> None:
        address = _norm_addr(address)
        async with self.lock:
            client = self.clients.get(address)
            if client is None or not client.is_connected:
                raise RuntimeError("not_connected")
            if self.profiles.get(address) == "meshtastic":
                await client.write_gatt_char(MT_TORADIO, data, response=True)
                await asyncio.sleep(0.02)
                # Return as soon as ToRadio is accepted. A blocking drain here
                # stalls the Elixir companion so LiveView times out while the
                # channel list is still arriving.
                self.loop.create_task(self._kick_drain(address))
                return
            mtu = max(20, int(self.mtus.get(address) or 185) - 3)
            for i in range(0, len(data), mtu):
                chunk = data[i : i + mtu]
                await client.write_gatt_char(NUS_RX, chunk, response=False)

    def _address_for_client(self, client) -> Optional[str]:
        for addr, held in list(self.clients.items()):
            if held is client:
                return addr
        raw = getattr(client, "address", None)
        if not raw:
            return None
        want = _norm_addr(raw)
        for addr in list(self.clients):
            if _norm_addr(addr) == want:
                return addr
        return want or None

    def _on_disconnect(self, client) -> None:
        address = self._address_for_client(client)
        if not address:
            return
        self.clients.pop(address, None)
        self.mtus.pop(address, None)
        self.profiles.pop(address, None)
        # Always drop a dead client. Skip the notify only for an intentional
        # disconnect() — during connect a drop must not leave a stale session.
        if address in self._closing:
            return
        write_msg({"type": "disconnected", "address": address})

    async def _start_scanner(self, scanner) -> None:
        last_err: Optional[BaseException] = None
        for attempt in range(4):
            try:
                await scanner.start()
                return
            except Exception as exc:
                last_err = exc
                if "inprogress" not in str(exc).lower():
                    raise
                await asyncio.sleep(0.4)
        raise last_err or RuntimeError("scan_in_progress")

    async def _wait_device_connected(self, address: str, timeout_s: float) -> bool:
        address = _norm_addr(address)
        deadline = asyncio.get_event_loop().time() + timeout_s
        while asyncio.get_event_loop().time() < deadline:
            if address in self._abort:
                return False
            if (await self._bluez_device_flags(address)).get("connected"):
                return True
            await asyncio.sleep(0.3)
        return False

    async def _wait_adapter_idle(self, timeout_s: float = 2.5) -> None:
        deadline = asyncio.get_event_loop().time() + timeout_s
        while True:
            if not await self._adapter_discovering():
                return
            if asyncio.get_event_loop().time() >= deadline:
                return
            await asyncio.sleep(0.2)

    async def _adapter_discovering(self) -> bool:
        if sys.platform != "linux":
            return False
        try:
            bus, objects = await self._bluez_objects()
            try:
                for _path, ifaces in objects.items():
                    props = ifaces.get("org.bluez.Adapter1")
                    if props and bool(self._prop(props, "Discovering") or False):
                        return True
            finally:
                bus.disconnect()
        except Exception:
            pass
        return False

    async def _stop_scanner(self) -> None:
        scanner = self.scanner
        self.scanner = None
        self._our_scan = False
        if scanner is None:
            return
        try:
            await scanner.stop()
        except Exception:
            pass

    async def _bluez_disconnect(self, address: str) -> None:
        address = _norm_addr(address)
        if sys.platform != "linux" or not address:
            return
        suffix = "dev_" + address.replace(":", "_").upper()
        try:
            bus, objects = await self._bluez_objects()
            for path, ifaces in objects.items():
                props = ifaces.get("org.bluez.Device1")
                if not props:
                    continue
                addr = _norm_addr(self._prop(props, "Address") or "")
                if addr != address and not path.upper().endswith(suffix):
                    continue
                intro = await bus.introspect("org.bluez", path)
                proxy = bus.get_proxy_object("org.bluez", path, intro)
                device = proxy.get_interface("org.bluez.Device1")
                try:
                    await device.call_disconnect()
                except Exception:
                    pass
            bus.disconnect()
        except Exception:
            pass

    def _prop(self, props: dict, key: str, default=None):
        val = props.get(key, default)
        return getattr(val, "value", val)

    async def _known_meshcore_devices(self) -> dict[str, dict]:
        found: dict[str, dict] = {}
        if sys.platform != "linux":
            return found
        try:
            bus, objects = await self._bluez_objects()
            for _path, ifaces in objects.items():
                props = ifaces.get("org.bluez.Device1")
                if not props:
                    continue
                name = self._prop(props, "Name") or self._prop(props, "Alias") or ""
                uuids = [str(u).lower() for u in (self._prop(props, "UUIDs") or [])]
                address = _norm_addr(self._prop(props, "Address") or "")
                if not address:
                    continue
                if (
                    NUS_SERVICE not in uuids
                    and MT_SERVICE not in uuids
                    and not _name_match(name)
                ):
                    continue
                found[address] = {
                    "address": address,
                    "name": name,
                    "rssi": self._prop(props, "RSSI"),
                    "kind": _profile_for(name, uuids),
                }
            bus.disconnect()
        except Exception:
            pass
        return found

    async def _release_orphan_connection(self, address: str) -> bool:
        """Drop a BlueZ link this sidecar does not own so Connect can attach."""
        address = _norm_addr(address)
        if not address or address in self.clients or address in self._connecting:
            return False
        if not (await self._bluez_device_flags(address)).get("connected"):
            return False
        await self._bluez_disconnect(address)
        return True

    async def _bluez_has_device(self, address: str) -> bool:
        return bool((await self._bluez_device_flags(address)).get("known"))

    async def _ensure_powered(self) -> None:
        if sys.platform != "linux":
            return
        try:
            from dbus_fast import Variant

            bus, objects = await self._bluez_objects()
            for path, ifaces in objects.items():
                if "org.bluez.Adapter1" not in ifaces:
                    continue
                intro = await bus.introspect("org.bluez", path)
                proxy = bus.get_proxy_object("org.bluez", path, intro)
                props = proxy.get_interface("org.freedesktop.DBus.Properties")
                powered = await props.call_get("org.bluez.Adapter1", "Powered")
                value = getattr(powered, "value", powered)
                if not value:
                    await props.call_set(
                        "org.bluez.Adapter1", "Powered", Variant("b", True)
                    )
                    await asyncio.sleep(0.4)
            bus.disconnect()
        except Exception:
            pass

    async def _device_paired(self, address: str) -> bool:
        """True when BlueZ already has a bond — no on-radio PIN will appear."""
        return bool((await self._bluez_device_flags(address)).get("paired"))

    async def _bluez_device_flags(self, address: str) -> dict[str, bool]:
        flags = {"paired": False, "trusted": False, "connected": False, "known": False}
        address = _norm_addr(address)
        if sys.platform != "linux" or not address:
            return flags
        suffix = "dev_" + address.replace(":", "_").upper()
        try:
            bus, objects = await self._bluez_objects()
            for path, ifaces in objects.items():
                props = ifaces.get("org.bluez.Device1")
                if not props:
                    continue
                addr = _norm_addr(self._prop(props, "Address") or "")
                if addr != address and not path.upper().endswith(suffix):
                    continue
                flags["known"] = True
                flags["paired"] = bool(self._prop(props, "Paired") or False)
                flags["trusted"] = bool(self._prop(props, "Trusted") or False)
                flags["connected"] = bool(self._prop(props, "Connected") or False)
                break
            bus.disconnect()
        except Exception:
            pass
        return flags

    async def _trust_device(self, address: str) -> None:
        if sys.platform != "linux" or not address:
            return
        suffix = "dev_" + address.replace(":", "_").upper()
        try:
            from dbus_fast import Variant

            bus, objects = await self._bluez_objects()
            for path, ifaces in objects.items():
                if "org.bluez.Device1" not in ifaces:
                    continue
                if not path.upper().endswith(suffix):
                    continue
                intro = await bus.introspect("org.bluez", path)
                proxy = bus.get_proxy_object("org.bluez", path, intro)
                props = proxy.get_interface("org.freedesktop.DBus.Properties")
                await props.call_set("org.bluez.Device1", "Trusted", Variant("b", True))
            bus.disconnect()
        except Exception:
            pass

    async def _bluez_objects(self):
        from dbus_fast import BusType
        from dbus_fast.aio import MessageBus

        bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
        intro = await bus.introspect("org.bluez", "/")
        root = bus.get_proxy_object("org.bluez", "/", intro)
        manager = root.get_interface("org.freedesktop.DBus.ObjectManager")
        objects = await manager.call_get_managed_objects()
        return bus, objects

    async def _stop_discovery(self) -> None:
        if sys.platform != "linux":
            return
        try:
            bus, objects = await self._bluez_objects()
            for path, ifaces in objects.items():
                if "org.bluez.Adapter1" not in ifaces:
                    continue
                intro = await bus.introspect("org.bluez", path)
                proxy = bus.get_proxy_object("org.bluez", path, intro)
                adapter = proxy.get_interface("org.bluez.Adapter1")
                try:
                    await adapter.call_stop_discovery()
                except Exception:
                    pass
            bus.disconnect()
        except Exception:
            pass

    async def _remove_device(self, address: str) -> None:
        if sys.platform != "linux" or not address:
            return
        suffix = "dev_" + address.replace(":", "_").upper()
        try:
            bus, objects = await self._bluez_objects()
            for path, ifaces in objects.items():
                if "org.bluez.Device1" not in ifaces:
                    continue
                if not path.upper().endswith(suffix):
                    continue
                adapter_path = path.rsplit("/", 1)[0]
                intro = await bus.introspect("org.bluez", adapter_path)
                proxy = bus.get_proxy_object("org.bluez", adapter_path, intro)
                adapter = proxy.get_interface("org.bluez.Adapter1")
                try:
                    await adapter.call_remove_device(path)
                except Exception:
                    pass
            bus.disconnect()
        except Exception:
            pass


async def handle(sidecar: Sidecar, req: dict) -> None:
    req_id = req.get("id")
    typ = req.get("type")
    try:
        if typ == "ping":
            reply(req_id, type="pong", ok=True)
        elif typ == "scan":
            timeout = float(req.get("timeout_ms") or 5000) / 1000.0
            devices = await sidecar.scan(max(0.5, min(timeout, 15.0)))
            reply(req_id, type="scan_result", ok=True, devices=devices)
        elif typ == "connect":
            address = req.get("address") or ""
            if not address:
                reply(req_id, type="error", ok=False, error="missing_address")
                return
            profile = req.get("profile") or "meshcore"
            info = await sidecar.connect(address, req.get("pin"), profile)
            reply(req_id, type="connect_result", ok=True, **info)
        elif typ == "pin_reply":
            sidecar.agent.provide_pin(str(req.get("pin") or ""))
            reply(req_id, type="pin_reply_result", ok=True)
        elif typ == "pin_cancel":
            sidecar.agent.cancel_pin()
            reply(req_id, type="pin_cancel_result", ok=True)
        elif typ == "adapter_status":
            info = await sidecar.adapter_status()
            reply(req_id, type="adapter_status_result", ok=True, **info)
        elif typ == "disconnect":
            await sidecar.disconnect(req.get("address") or "")
            reply(req_id, type="disconnect_result", ok=True)
        elif typ == "write":
            raw = base64.b64decode(req.get("data") or "")
            await sidecar.write(req.get("address") or "", raw)
            reply(req_id, type="write_result", ok=True)
        elif typ == "shutdown":
            for addr in list(sidecar.clients):
                await sidecar.disconnect(addr)
            reply(req_id, type="shutdown_result", ok=True)
            sidecar.loop.call_soon(sidecar.loop.stop)
        else:
            reply(req_id, type="error", ok=False, error=f"unknown_type:{typ}")
    except Exception as exc:
        reply(
            req_id,
            type="error",
            ok=False,
            error=str(exc) or exc.__class__.__name__,
            traceback=traceback.format_exc(),
        )


def stdin_thread(loop: asyncio.AbstractEventLoop, sidecar: Sidecar) -> None:
    while True:
        try:
            req = read_msg()
        except Exception as exc:
            write_msg({"type": "error", "error": f"ipc_read:{exc}"})
            continue
        if req is None:
            loop.call_soon_threadsafe(loop.stop)
            return
        asyncio.run_coroutine_threadsafe(handle(sidecar, req), loop)


def main() -> None:
    bleak = _bleak_available()
    write_msg({"type": "hello", "bleak": bleak, "error": None if bleak else "bleak_missing"})
    if not bleak:
        # Still accept pings so Elixir can report a clear stub.
        while True:
            req = read_msg()
            if req is None:
                return
            req_id = req.get("id")
            if req.get("type") == "ping":
                reply(req_id, type="pong", ok=True, bleak=False)
            else:
                reply(req_id, type="error", ok=False, error="bleak_missing")

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    sidecar = Sidecar(loop)
    threading.Thread(target=stdin_thread, args=(loop, sidecar), daemon=True).start()
    try:
        loop.run_forever()
    finally:
        loop.close()


if __name__ == "__main__":
    main()
