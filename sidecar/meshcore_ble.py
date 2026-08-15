#!/usr/bin/env python3
"""Isthmus MeshCore BLE sidecar — length-prefixed JSON IPC ({:packet, 4}).

Scan / connect / write Nordic UART Service (NUS) used by MeshCore Companion
Bluetooth firmware. Unsolicited TX notifications are emitted as
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

NAME_PREFIXES = (
    "MeshCore-",
    "Whisper-",
    "WisCore-",
    "Seeed",
    "Lilygo",
    "HT-",
    "LowMesh_MC_",
    "NRF52",
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
        )
    )


def _needs_pair(exc: BaseException) -> bool:
    text = str(exc).lower()
    return any(
        token in text
        for token in ("pin or key missing", "authentication", "not paired", "not trusted")
    )


class BluezPinAgent:
    """Minimal org.bluez.Agent1 that answers MeshCore PIN/passkey prompts."""

    def __init__(self) -> None:
        self.pin = "123456"
        self.bus = None
        self._registered = False

    @property
    def is_registered(self) -> bool:
        return self._registered

    async def start(self, pin: str) -> None:
        if sys.platform != "linux":
            return
        self.pin = pin or "123456"
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
            def RequestPinCode(self, _device: "o") -> "s":
                return self.owner.pin

            @method()
            def RequestPasskey(self, _device: "o") -> "u":
                return int(self.owner.pin)

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


class Sidecar:
    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self.loop = loop
        self.clients: dict[str, Any] = {}
        self.mtus: dict[str, int] = {}
        self.lock = asyncio.Lock()
        self.scanner = None
        self.agent = BluezPinAgent()
        self._connecting: set[str] = set()
        self._closing: set[str] = set()
        self.known: dict[str, Any] = {}

    async def scan(self, timeout_s: float) -> list[dict]:
        from bleak import BleakScanner

        async with self.lock:
            await self._ensure_powered()
            await self._release_orphan_connections()
            seen = await self._known_meshcore_devices()

            def _cb(device, adv) -> None:
                name = device.name or getattr(adv, "local_name", None)
                uuids = [u.lower() for u in (getattr(adv, "service_uuids", None) or [])]
                if NUS_SERVICE not in uuids and not _name_match(name):
                    return
                addr = device.address
                self.known[addr] = device
                seen[addr] = {
                    "address": addr,
                    "name": name or "",
                    "rssi": getattr(adv, "rssi", None),
                }

            scanner = BleakScanner(detection_callback=_cb)
            self.scanner = scanner
            await scanner.start()
            try:
                await asyncio.sleep(timeout_s)
            finally:
                try:
                    await scanner.stop()
                except Exception:
                    pass
                self.scanner = None
            return list(seen.values())

    async def connect(self, address: str, pin: Optional[str]) -> dict:
        async with self.lock:
            await self._ensure_powered()
            await self._stop_scanner()
            await self.disconnect(address)
            await self._stop_discovery()
            await self._trust_device(address)
            await self.agent.start(pin or "123456")
            last_err: Optional[BaseException] = None
            for attempt in range(2):
                if attempt > 0:
                    if _needs_pair(last_err or Exception()):
                        await self._remove_device(address)
                        await self.agent.start(pin or "123456")
                    await asyncio.sleep(1.0)
                try:
                    return await self._connect_once(
                        address, pin, pair=attempt > 0 and _needs_pair(last_err or Exception())
                    )
                except Exception as exc:
                    last_err = exc
                    await self.disconnect(address)
                    if attempt == 0 and (_transient_ble_error(exc) or _needs_pair(exc)):
                        continue
                    raise
            raise last_err or RuntimeError("connect_failed")

    async def _resolve_device(self, address: str):
        from bleak import BleakScanner

        device = self.known.get(address)
        if device is not None:
            return device
        device = await BleakScanner.find_device_by_address(address, timeout=8.0)
        if device is None:
            raise RuntimeError(f"not_found:{address}")
        self.known[address] = device
        return device

    async def _connect_once(self, address: str, pin: Optional[str], pair: bool) -> dict:
        from bleak import BleakClient

        self._connecting.add(address)
        try:
            target = await self._resolve_device(address)
            client = BleakClient(
                target, disconnected_callback=self._on_disconnect, timeout=25.0
            )
            await client.connect()
            if pair and pin and self.agent.is_registered:
                try:
                    await client.pair()
                except Exception:
                    pass
            mtu = getattr(client, "mtu_size", None) or 185
            self.mtus[address] = int(mtu)

            def _notify(_handle, data: bytearray) -> None:
                write_msg(
                    {
                        "type": "notify",
                        "address": address,
                        "data": base64.b64encode(bytes(data)).decode("ascii"),
                    }
                )

            await client.start_notify(NUS_TX, _notify)
            self.clients[address] = client
            await asyncio.sleep(0.25)
            return {"address": address, "mtu": self.mtus[address]}
        finally:
            self._connecting.discard(address)

    async def disconnect(self, address: str) -> None:
        self._closing.add(address)
        client = self.clients.pop(address, None)
        self.mtus.pop(address, None)
        try:
            if client is not None and client.is_connected:
                await client.disconnect()
        except Exception:
            pass
        finally:
            self._closing.discard(address)

    async def write(self, address: str, data: bytes) -> None:
        async with self.lock:
            client = self.clients.get(address)
            if client is None or not client.is_connected:
                raise RuntimeError("not_connected")
            mtu = max(20, int(self.mtus.get(address) or 185) - 3)
            for i in range(0, len(data), mtu):
                chunk = data[i : i + mtu]
                await client.write_gatt_char(NUS_RX, chunk, response=False)

    def _on_disconnect(self, client) -> None:
        address = getattr(client, "address", None)
        if not address or address in self._connecting or address in self._closing:
            return
        self.clients.pop(address, None)
        write_msg({"type": "disconnected", "address": address})

    async def _stop_scanner(self) -> None:
        scanner = self.scanner
        self.scanner = None
        if scanner is None:
            return
        try:
            await scanner.stop()
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
                address = self._prop(props, "Address") or ""
                if not address:
                    continue
                if NUS_SERVICE not in uuids and not _name_match(name):
                    continue
                found[address] = {
                    "address": address,
                    "name": name,
                    "rssi": self._prop(props, "RSSI"),
                }
            bus.disconnect()
        except Exception:
            pass
        return found

    async def _release_orphan_connections(self) -> None:
        """Drop BlueZ links this sidecar does not own so the radio can advertise."""
        if sys.platform != "linux":
            return
        try:
            bus, objects = await self._bluez_objects()
            for path, ifaces in objects.items():
                props = ifaces.get("org.bluez.Device1")
                if not props:
                    continue
                address = self._prop(props, "Address") or ""
                connected = bool(self._prop(props, "Connected") or False)
                name = self._prop(props, "Name") or self._prop(props, "Alias") or ""
                uuids = [str(u).lower() for u in (self._prop(props, "UUIDs") or [])]
                if not connected or not address or address in self.clients:
                    continue
                if NUS_SERVICE not in uuids and not _name_match(name):
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
            info = await sidecar.connect(address, req.get("pin"))
            reply(req_id, type="connect_result", ok=True, **info)
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
