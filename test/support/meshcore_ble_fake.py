#!/usr/bin/env python3
"""Packet-4 JSON fake for MeshCore BLE sidecar IPC tests (no bleak)."""

from __future__ import annotations

import base64
import json
import struct
import sys


def write_msg(obj: dict) -> None:
    body = json.dumps(obj).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("!I", len(body)))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def read_msg() -> dict | None:
    header = sys.stdin.buffer.read(4)
    if not header or len(header) < 4:
        return None
    (length,) = struct.unpack("!I", header)
    body = sys.stdin.buffer.read(length)
    if not body:
        return None
    return json.loads(body.decode("utf-8"))


def main() -> None:
    write_msg({"type": "hello", "bleak": True, "error": None})
    while True:
        req = read_msg()
        if req is None:
            return
        req_id = req.get("id")
        typ = req.get("type")
        if typ == "scan":
            write_msg(
                {
                    "id": req_id,
                    "type": "scan_result",
                    "ok": True,
                    "devices": [
                        {
                            "address": "AA:BB:CC:DD:EE:FF",
                            "name": "MeshCore-1",
                            "rssi": -40,
                            "kind": "meshcore",
                        },
                        {
                            "address": "11:22:33:44:55:66",
                            "name": "Meshtastic_Andreas",
                            "rssi": -50,
                            "kind": "meshtastic",
                        },
                    ],
                }
            )
        elif typ == "connect":
            address = req.get("address") or "AA:BB:CC:DD:EE:FF"
            write_msg(
                {
                    "id": req_id,
                    "type": "connect_result",
                    "ok": True,
                    "address": address,
                    "mtu": 185,
                }
            )
            write_msg(
                {
                    "type": "notify",
                    "address": address,
                    "data": base64.b64encode(b"\x0a").decode("ascii"),
                }
            )
        elif typ == "write":
            write_msg({"id": req_id, "type": "write_result", "ok": True})
        elif typ == "adapter_status":
            write_msg(
                {
                    "id": req_id,
                    "type": "adapter_status_result",
                    "ok": True,
                    "discovering": False,
                    "clients": [],
                    "connecting": [],
                    "devices": [],
                }
            )
        elif typ == "disconnect":
            write_msg({"id": req_id, "type": "disconnect_result", "ok": True})
        elif typ == "pin_reply":
            write_msg({"id": req_id, "type": "pin_reply_result", "ok": True})
        elif typ == "pin_cancel":
            write_msg({"id": req_id, "type": "pin_cancel_result", "ok": True})
        elif typ == "ping":
            write_msg({"id": req_id, "type": "pong", "ok": True})
        else:
            write_msg(
                {
                    "id": req_id,
                    "type": "error",
                    "ok": False,
                    "error": f"unknown_type:{typ}",
                }
            )


if __name__ == "__main__":
    main()
