#!/usr/bin/env python3
"""Isthmus RNS sidecar — length-prefixed JSON IPC on stdio (Erlang {:packet, 4}).

Owns a dedicated Reticulum + LXMF stack (separate from MeshChatX). Speaks:
  identity_create / identity_register / identity_announce / lxmf_send / ping / shutdown

Inbound LXMF is emitted as {"type":"lxmf","message":{...}}.
"""

from __future__ import annotations

import json
import os
import struct
import sys
import threading
import time
import traceback
import uuid
from typing import Any, Optional


def read_msg():
    header = sys.stdin.buffer.read(4)
    if not header or len(header) < 4:
        return None
    (length,) = struct.unpack("!I", header)
    body = sys.stdin.buffer.read(length)
    if not body:
        return None
    return json.loads(body.decode("utf-8"))


def write_msg(obj: dict) -> None:
    body = json.dumps(obj, default=str).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("!I", len(body)))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def reply(req_id: Optional[str], **payload) -> None:
    msg = dict(payload)
    if req_id is not None:
        msg["id"] = req_id
    write_msg(msg)


def hex_of(data: Optional[bytes]) -> Optional[str]:
    if data is None:
        return None
    return data.hex()


class Sidecar:
    def __init__(self) -> None:
        self.RNS = None
        self.LXMF = None
        self.LXMessage = None
        self.APP_NAME = "lxmf"
        self.reticulum = None
        self.router = None
        self.configdir = None
        self.storagepath = None
        self.live = False
        self.identities: dict[str, Any] = {}  # dest_hash_hex -> identity
        self.destinations: dict[str, Any] = {}  # dest_hash_hex -> Destination
        self._lock = threading.RLock()

    def try_boot(self) -> dict:
        try:
            import RNS
            import LXMF
            from LXMF import LXMRouter, LXMessage
            from LXMF.LXMF import APP_NAME
        except Exception as exc:  # noqa: BLE001
            return {"rns": False, "lxmf": False, "error": f"import_failed:{exc}"}

        self.RNS = RNS
        self.LXMF = LXMF
        self.LXMessage = LXMessage
        self.APP_NAME = APP_NAME

        self.configdir = os.environ.get(
            "ISTHMUS_RNS_CONFIGDIR",
            os.path.expanduser("~/.isthmus/reticulum"),
        )
        self.storagepath = os.environ.get(
            "ISTHMUS_RNS_STORAGE",
            os.path.join(self.configdir, "lxmf_storage"),
        )
        os.makedirs(self.configdir, exist_ok=True)
        os.makedirs(self.storagepath, exist_ok=True)

        try:
            # Separate instance from MeshChatX (~/.reticulum).
            loglevel = os.environ.get("ISTHMUS_RNS_LOGLEVEL", "3")
            try:
                loglevel = int(loglevel)
            except ValueError:
                loglevel = 3

            self.reticulum = RNS.Reticulum(
                configdir=self.configdir,
                loglevel=loglevel,
            )
            self.router = LXMRouter(
                storagepath=self.storagepath,
                name=os.environ.get("ISTHMUS_RNS_NODE_NAME", "isthmus"),
            )
            self.router.register_delivery_callback(self._on_delivery)
            self.live = True
            return {
                "rns": True,
                "lxmf": True,
                "configdir": self.configdir,
                "storagepath": self.storagepath,
                "rns_version": getattr(RNS, "__version__", None),
                "lxmf_version": getattr(LXMF, "__version__", None),
            }
        except Exception as exc:  # noqa: BLE001
            return {
                "rns": True,
                "lxmf": True,
                "error": f"boot_failed:{exc}",
                "trace": traceback.format_exc()[-800:],
            }

    def _on_delivery(self, lxm) -> None:
        try:
            body = ""
            try:
                body = lxm.content_as_string()
            except Exception:  # noqa: BLE001
                if isinstance(getattr(lxm, "content", None), (bytes, bytearray)):
                    body = bytes(lxm.content).decode("utf-8", errors="replace")
                else:
                    body = str(getattr(lxm, "content", "") or "")

            title = getattr(lxm, "title", None) or ""
            if isinstance(title, (bytes, bytearray)):
                title = title.decode("utf-8", errors="replace")

            msg_hash = getattr(lxm, "hash", None)
            write_msg(
                {
                    "type": "lxmf",
                    "message": {
                        "id": hex_of(msg_hash) or str(uuid.uuid4()),
                        "from": hex_of(getattr(lxm, "source_hash", None)),
                        "to": hex_of(getattr(lxm, "destination_hash", None)),
                        "body": body,
                        "title": title,
                    },
                }
            )
        except Exception as exc:  # noqa: BLE001
            write_msg({"type": "error", "error": f"delivery_callback:{exc}"})

    def _destination_hash_for(self, identity) -> bytes:
        return self.RNS.Destination.hash_from_name_and_identity(
            f"{self.APP_NAME}.delivery", identity
        )

    def identity_create(self) -> dict:
        identity = self.RNS.Identity()
        dest = self._destination_hash_for(identity)
        return {
            "private_key_hex": hex_of(identity.get_private_key()),
            "public_key_hex": hex_of(identity.get_public_key()),
            "identity_hash": identity.hexhash,
            "destination_hash": hex_of(dest),
        }

    def _load_identity(self, private_key_hex: str):
        raw = bytes.fromhex(private_key_hex)
        identity = self.RNS.Identity(create_keys=False)
        identity.load_private_key(raw)
        return identity

    def identity_register(self, private_key_hex: str, display_name: Optional[str] = None) -> dict:
        if not self.live or self.router is None:
            return {"ok": False, "error": "not_live"}

        with self._lock:
            identity = self._load_identity(private_key_hex)
            dest_hash = self._destination_hash_for(identity)
            dest_hex = hex_of(dest_hash)

            if dest_hex in self.destinations:
                return {
                    "ok": True,
                    "destination_hash": dest_hex,
                    "identity_hash": identity.hexhash,
                    "already": True,
                }

            # LXMRouter.register_delivery_identity only allows one; we support many
            # proxies by mirroring its setup into delivery_destinations.
            ratchetpath = self.router.ratchetpath
            if not os.path.isdir(ratchetpath):
                os.makedirs(ratchetpath)

            delivery_destination = self.RNS.Destination(
                identity,
                self.RNS.Destination.IN,
                self.RNS.Destination.SINGLE,
                self.APP_NAME,
                "delivery",
            )
            delivery_destination.enable_ratchets(
                f"{ratchetpath}/{self.RNS.hexrep(delivery_destination.hash, delimit=False)}.ratchets"
            )
            delivery_destination.set_packet_callback(self.router.delivery_packet)
            delivery_destination.set_link_established_callback(
                self.router.delivery_link_established
            )
            delivery_destination.display_name = display_name or "Isthmus"

            if display_name is not None:

                def get_app_data(dest_hash=delivery_destination.hash):
                    return self.router.get_announce_app_data(dest_hash)

                delivery_destination.set_default_app_data(get_app_data)

            self.router.delivery_destinations[delivery_destination.hash] = delivery_destination
            self.router.set_inbound_stamp_cost(delivery_destination.hash, None)

            self.RNS.Identity.remember(
                packet_hash=None,
                destination_hash=delivery_destination.hash,
                public_key=identity.get_public_key(),
                app_data=None,
            )

            self.identities[dest_hex] = identity
            self.destinations[dest_hex] = delivery_destination

            return {
                "ok": True,
                "destination_hash": dest_hex,
                "identity_hash": identity.hexhash,
            }

    def identity_announce(self, destination_hash: str) -> dict:
        if not self.live or self.router is None:
            return {"ok": False, "error": "not_live"}
        dest_hex = destination_hash.lower().strip()
        raw = bytes.fromhex(dest_hex)
        if raw not in self.router.delivery_destinations:
            return {"ok": False, "error": "unknown_destination"}
        self.router.announce(raw)
        return {"ok": True, "destination_hash": dest_hex}

    def path_status(self, destination_hash: str) -> dict:
        if not self.live:
            return {"ok": False, "error": "not_live"}
        resolved = self._resolve_peer(destination_hash)
        if not resolved.get("ok"):
            return resolved
        dest_hex = resolved["destination_hash"]
        to_hash = bytes.fromhex(dest_hex)
        has_path = False
        try:
            has_path = bool(self.RNS.Transport.has_path(to_hash))
        except Exception:  # noqa: BLE001
            has_path = False
        backchannel = False
        direct = False
        if self.router is not None:
            backchannel = to_hash in getattr(self.router, "backchannel_links", {})
            direct = to_hash in getattr(self.router, "direct_links", {})
        return {
            "ok": True,
            "destination_hash": dest_hex,
            "identity_hash": resolved.get("identity_hash"),
            "identity_known": resolved["identity"] is not None,
            "path_known": has_path,
            "backchannel": backchannel,
            "direct_link": direct,
            "resolved_from_identity_hash": resolved.get("resolved_from_identity_hash", False),
        }

    def request_path(self, destination_hash: str) -> dict:
        status = self.path_status(destination_hash)
        if not status.get("ok"):
            return status
        to_hash = bytes.fromhex(status["destination_hash"])
        try:
            self.RNS.Transport.request_path(to_hash)
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "error": str(exc), **{k: v for k, v in status.items() if k != "ok"}}
        known = self.RNS.Identity.recall(to_hash) is not None
        has_path = False
        try:
            has_path = bool(self.RNS.Transport.has_path(to_hash))
        except Exception:  # noqa: BLE001
            has_path = False
        return {
            "ok": True,
            "destination_hash": status["destination_hash"],
            "identity_hash": status.get("identity_hash"),
            "identity_known": known,
            "path_known": has_path,
            "requested": True,
            "resolved_from_identity_hash": status.get("resolved_from_identity_hash", False),
        }

    def _resolve_peer(self, destination_hash: str) -> dict:
        """Resolve an LXMF destination hash, or an identity hexhash → lxmf.delivery dest."""
        try:
            dest_hex = (destination_hash or "").lower().strip()
            to_hash = bytes.fromhex(dest_hex)
        except ValueError:
            return {"ok": False, "error": "invalid_destination"}

        if len(to_hash) != self.RNS.Reticulum.TRUNCATED_HASHLENGTH // 8:
            return {"ok": False, "error": "invalid_destination"}

        identity = self.RNS.Identity.recall(to_hash)
        if identity is not None:
            return {
                "ok": True,
                "destination_hash": dest_hex,
                "identity_hash": identity.hexhash,
                "identity": identity,
                "resolved_from_identity_hash": False,
            }

        # Callers often paste MeshChatX *identity* hashes; LXMF uses lxmf.delivery dest.
        for known_dest, _meta in list(self.RNS.Identity.known_destinations.items()):
            ident = self.RNS.Identity.recall(known_dest)
            if ident is None or ident.hexhash != dest_hex:
                continue
            lxmf_dest = self.RNS.Destination.hash_from_name_and_identity(
                f"{self.APP_NAME}.delivery", ident
            )
            return {
                "ok": True,
                "destination_hash": lxmf_dest.hex(),
                "identity_hash": ident.hexhash,
                "identity": ident,
                "resolved_from_identity_hash": True,
            }

        return {
            "ok": True,
            "destination_hash": dest_hex,
            "identity_hash": None,
            "identity": None,
            "resolved_from_identity_hash": False,
        }

    def lxmf_send(self, message: dict) -> dict:
        if not self.live or self.router is None:
            return {"ok": False, "error": "not_live", "stub": True}

        to_hex = (message.get("to") or "").lower().strip()
        body = message.get("body") or ""
        from_hex = (message.get("from") or "").lower().strip()
        title = message.get("title") or ""
        # Default DIRECT: MeshChatX DMs create a backchannel link we can reply on.
        # Opportunistic often "succeeds" in our queue without MeshChatX ever seeing it.
        method_name = (message.get("method") or "direct").lower()
        wait_s = float(message.get("wait_seconds") or 12)

        if not to_hex or len(bytes.fromhex(to_hex)) != self.RNS.Reticulum.TRUNCATED_HASHLENGTH // 8:
            return {"ok": False, "error": "invalid_to"}

        # Pick source: explicit from, else first registered proxy.
        source_dest = None
        if from_hex and from_hex in self.destinations:
            source_dest = self.destinations[from_hex]
        elif self.destinations:
            source_dest = next(iter(self.destinations.values()))
        else:
            return {"ok": False, "error": "no_source_identity"}

        resolved = self._resolve_peer(to_hex)
        if not resolved.get("ok"):
            return {"ok": False, "error": resolved.get("error", "invalid_to")}

        to_identity = resolved["identity"]
        dest_hex = resolved["destination_hash"]
        to_hash = bytes.fromhex(dest_hex)

        if to_identity is None:
            pk_hex = (message.get("public_key_hex") or "").strip()
            if pk_hex:
                to_identity = self.RNS.Identity(create_keys=False)
                to_identity.load_public_key(bytes.fromhex(pk_hex))
                self.RNS.Identity.remember(
                    packet_hash=None,
                    destination_hash=to_hash,
                    public_key=to_identity.get_public_key(),
                    app_data=None,
                )

        if to_identity is None:
            self.RNS.Transport.request_path(to_hash)
            return {"ok": False, "error": "unknown_destination_path", "to": dest_hex}

        destination = self.RNS.Destination(
            to_identity,
            self.RNS.Destination.OUT,
            self.RNS.Destination.SINGLE,
            self.APP_NAME,
            "delivery",
        )

        has_path = False
        try:
            has_path = bool(self.RNS.Transport.has_path(destination.hash))
        except Exception:  # noqa: BLE001
            has_path = False
        backchannel = destination.hash in getattr(self.router, "backchannel_links", {})
        direct_link = destination.hash in getattr(self.router, "direct_links", {})

        # Auto-select: prefer direct when a reply link or path exists.
        if method_name in ("auto", ""):
            method_name = "direct" if (backchannel or direct_link or has_path) else "opportunistic"

        method = self.LXMessage.DIRECT
        if method_name == "opportunistic":
            method = self.LXMessage.OPPORTUNISTIC
        elif method_name == "propagated":
            method = self.LXMessage.PROPAGATED

        if method == self.LXMessage.DIRECT and not has_path and not backchannel and not direct_link:
            try:
                self.RNS.Transport.request_path(destination.hash)
            except Exception:  # noqa: BLE001
                pass

        lxm = self.LXMessage(
            destination,
            source_dest,
            content=body,
            title=title,
            desired_method=method,
            include_ticket=True,
        )
        self.router.handle_outbound(lxm)

        # Wait briefly so gateway status reflects real delivery, not just enqueue.
        deadline = time.time() + max(0.0, wait_s)
        while time.time() < deadline:
            state = getattr(lxm, "state", None)
            if state == self.LXMessage.DELIVERED:
                break
            if state in (self.LXMessage.FAILED, self.LXMessage.REJECTED, self.LXMessage.CANCELLED):
                break
            time.sleep(0.15)

        state = getattr(lxm, "state", None)
        state_name = None
        for name in ("DELIVERED", "FAILED", "REJECTED", "CANCELLED", "SENT", "SENDING", "OUTBOUND"):
            if state == getattr(self.LXMessage, name, None):
                state_name = name.lower()
                break

        ok = state == self.LXMessage.DELIVERED or state == self.LXMessage.SENT
        # SENT is opportunistic-without-proof yet; treat as ok but pending.
        if state == self.LXMessage.DELIVERED:
            ok = True
        elif state in (self.LXMessage.FAILED, self.LXMessage.REJECTED, self.LXMessage.CANCELLED):
            ok = False
        elif state in (self.LXMessage.SENT, self.LXMessage.SENDING, self.LXMessage.OUTBOUND):
            # Still in flight after wait — report pending so we don't claim delivery.
            ok = False
            state_name = state_name or "pending"

        result = {
            "ok": ok,
            "id": hex_of(getattr(lxm, "hash", None)) or str(uuid.uuid4()),
            "to": hex_of(destination.hash) or dest_hex,
            "to_requested": to_hex,
            "from": hex_of(source_dest.hash),
            "method": method_name,
            "state": state_name,
            "path_known": has_path,
            "backchannel": backchannel,
            "direct_link": direct_link,
            "resolved_from_identity_hash": resolved.get("resolved_from_identity_hash", False),
            "stub": False,
        }
        if not ok:
            result["error"] = state_name or "delivery_pending"
        return result

    def status(self) -> dict:
        instance = {
            "is_shared_instance": None,
            "is_connected_to_shared_instance": None,
            "is_standalone_instance": None,
            "share_instance": None,
            "instance_name": None,
            "transport_enabled": None,
        }
        traffic = {"rxb": None, "txb": None, "rxs": None, "txs": None}
        interfaces: list[dict] = []
        stats_error = None
        stats_note = None

        if self.live and self.reticulum is not None and self.RNS is not None:
            r = self.reticulum
            attached = bool(getattr(r, "is_connected_to_shared_instance", False))
            instance.update(
                {
                    "is_shared_instance": bool(getattr(r, "is_shared_instance", False)),
                    "is_connected_to_shared_instance": attached,
                    "is_standalone_instance": bool(getattr(r, "is_standalone_instance", False)),
                    "share_instance": bool(getattr(r, "share_instance", False)),
                    "instance_name": getattr(r, "local_socket_path", None) or "default",
                    "transport_enabled": bool(self.RNS.Reticulum.transport_enabled()),
                }
            )

            # As a shared-instance client, get_interface_stats() RPCs the master using
            # this process's rpc_key. MeshChatX (~/.reticulum) derives a different key,
            # so auth fails with "digest sent was rejected". Skip RPC and list local
            # interfaces instead unless a shared rpc_key is configured.
            if attached:
                interfaces = self._local_interfaces()
                stats_note = (
                    "Attached as shared-instance client — physical interface stats live "
                    "on the master (MeshChatX). Local view shows the LocalClient link only. "
                    "To enable full stats RPC, set the same rpc_key hex in both "
                    "~/.reticulum/config and ~/.isthmus/reticulum/config under [reticulum]."
                )
            else:
                try:
                    stats = r.get_interface_stats() or {}
                    traffic = {
                        "rxb": stats.get("rxb"),
                        "txb": stats.get("txb"),
                        "rxs": stats.get("rxs"),
                        "txs": stats.get("txs"),
                    }
                    for iface in stats.get("interfaces") or []:
                        interfaces.append(self._sanitize_iface(iface))
                except Exception as exc:  # noqa: BLE001
                    msg = str(exc)
                    if "digest" in msg.lower() or "AuthenticationError" in type(exc).__name__:
                        stats_note = (
                            "Interface stats RPC auth failed (mismatched rpc_key with shared "
                            "master). Showing local interfaces only."
                        )
                    else:
                        stats_error = msg
                    interfaces = self._local_interfaces()

        role = "unknown"
        if instance["is_connected_to_shared_instance"]:
            role = "client"
        elif instance["is_shared_instance"]:
            role = "shared_master"
        elif instance["is_standalone_instance"]:
            role = "standalone"

        return {
            "live": self.live,
            "configdir": self.configdir,
            "storagepath": self.storagepath,
            "config": self._config_summary(),
            "instance": instance,
            "instance_role": role,
            "traffic": traffic,
            "registered": list(self.destinations.keys()),
            "registered_count": len(self.destinations),
            "interfaces": interfaces,
            "stats_error": stats_error,
            "stats_note": stats_note,
        }

    def _local_interfaces(self) -> list[dict]:
        out: list[dict] = []
        if self.RNS is None:
            return out
        try:
            for iface in self.RNS.Transport.interfaces:
                online = bool(getattr(iface, "online", False))
                entry = {
                    "name": str(iface),
                    "short_name": str(getattr(iface, "name", iface)),
                    "type": type(iface).__name__,
                    "online": online,
                    "status": online,
                    "rxb": getattr(iface, "rxb", None),
                    "txb": getattr(iface, "txb", None),
                    "bitrate": getattr(iface, "bitrate", None),
                    "clients": getattr(iface, "clients", None),
                    "peers": len(iface.peers) if getattr(iface, "peers", None) is not None else None,
                }
                out.append(self._sanitize_iface(entry))
        except Exception:  # noqa: BLE001
            pass
        return out

    def _config_summary(self) -> dict:
        path = os.path.join(self.configdir or "", "config")
        summary: dict[str, Any] = {
            "path": path if os.path.isfile(path) else None,
            "share_instance": None,
            "instance_name": None,
            "enable_transport": None,
            "configured_interfaces": [],
        }
        if not summary["path"]:
            return summary

        try:
            text = open(path, "r", encoding="utf-8").read()
        except OSError as exc:
            summary["error"] = str(exc)
            return summary

        import re

        def section_kv(section_name: str) -> dict[str, str]:
            m = re.search(
                rf"(?ms)^\[{re.escape(section_name)}\]\s*(.*?)(?=^\[|\Z)",
                text,
            )
            if not m:
                return {}
            body = m.group(1)
            # strip nested [[iface]] blocks from reticulum/logging sections
            body = re.split(r"(?m)^\[\[", body, maxsplit=1)[0]
            out: dict[str, str] = {}
            for line in body.splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
            return out

        r = section_kv("reticulum")
        summary["share_instance"] = self._cfg_bool(r.get("share_instance"))
        summary["instance_name"] = (r.get("instance_name") or "default").strip()
        summary["enable_transport"] = self._cfg_bool(r.get("enable_transport"))
        summary["configured_interfaces"] = self._parse_interface_blocks(path)
        return summary

    def _parse_interface_blocks(self, path: str) -> list[dict]:
        try:
            text = open(path, "r", encoding="utf-8").read()
        except OSError:
            return []

        import re

        blocks = re.split(r"(?m)^\s*\[\[([^\]]+)\]\]\s*$", text)
        # blocks: [preamble, name1, body1, name2, body2, ...]
        out: list[dict] = []
        for i in range(1, len(blocks), 2):
            name = blocks[i].strip()
            body = blocks[i + 1] if i + 1 < len(blocks) else ""
            # stop at next top-level section
            body = re.split(r"(?m)^\s*\[", body, maxsplit=1)[0]
            fields: dict[str, Any] = {"name": name}
            for line in body.splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k, v = k.strip(), v.strip()
                if k == "type":
                    fields["type"] = v
                elif k == "enabled":
                    fields["enabled"] = self._cfg_bool(v)
                elif k in ("port", "device", "target_host", "target_port", "frequency", "bandwidth"):
                    fields[k] = v
            if "type" in fields or "enabled" in fields:
                out.append(fields)
        return out

    @staticmethod
    def _cfg_bool(value: Optional[str]) -> Optional[bool]:
        if value is None:
            return None
        v = str(value).strip().lower()
        if v in ("yes", "true", "1", "on"):
            return True
        if v in ("no", "false", "0", "off"):
            return False
        return None

    @staticmethod
    def _sanitize_iface(iface: dict) -> dict:
        out: dict[str, Any] = {}
        for key, value in iface.items():
            if isinstance(value, (bytes, bytearray)):
                out[key] = value.hex()
            elif isinstance(value, (int, float, str, bool)) or value is None:
                out[key] = value
            elif isinstance(value, list):
                out[key] = [
                    x.hex() if isinstance(x, (bytes, bytearray)) else x
                    for x in value
                    if isinstance(x, (bytes, bytearray, int, float, str, bool)) or x is None
                ]
            else:
                out[key] = str(value)

        # Normalize online flag for UI
        if "online" not in out and "status" in out:
            out["online"] = bool(out["status"])
        return out


def main() -> int:
    # Only one sidecar per configdir — duplicate processes steal interfaces and
    # break LXMF delivery while looking "delivered" from the wrong stack.
    configdir = os.path.expanduser(
        os.environ.get("ISTHMUS_RNS_CONFIGDIR") or "~/.isthmus/reticulum"
    )
    os.makedirs(configdir, exist_ok=True)
    lock_path = os.path.join(configdir, "isthmus_sidecar.lock")
    lock_fh = open(lock_path, "w", encoding="utf-8")
    try:
        import fcntl

        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        write_msg(
            {
                "type": "hello",
                "ts": time.time(),
                "rns": False,
                "lxmf": False,
                "error": f"another sidecar holds {lock_path}",
                "configdir": configdir,
            }
        )
        return 1

    lock_fh.write(str(os.getpid()))
    lock_fh.flush()

    sidecar = Sidecar()
    boot = sidecar.try_boot()
    write_msg({"type": "hello", "ts": time.time(), **boot})

    while True:
        try:
            msg = read_msg()
        except Exception as exc:  # noqa: BLE001
            write_msg({"type": "error", "error": str(exc)})
            continue

        if msg is None:
            break

        mtype = msg.get("type")
        req_id = msg.get("id")

        try:
            if mtype == "ping":
                reply(req_id, type="pong", ts=time.time())
            elif mtype == "status":
                reply(req_id, type="status", **sidecar.status())
            elif mtype == "identity_create":
                if not sidecar.live:
                    # Deterministic-ish stub so registration still works offline.
                    seed = os.urandom(32)
                    dest = __import__("hashlib").sha256(seed).digest()[:16].hex()
                    reply(
                        req_id,
                        type="identity_create_result",
                        ok=True,
                        stub=True,
                        private_key_hex=seed.hex(),
                        public_key_hex=(seed + seed).hex()[:64],
                        identity_hash=dest,
                        destination_hash=dest,
                    )
                else:
                    result = sidecar.identity_create()
                    reply(req_id, type="identity_create_result", ok=True, stub=False, **result)
            elif mtype == "identity_register":
                result = sidecar.identity_register(
                    msg.get("private_key_hex") or "",
                    display_name=msg.get("display_name"),
                )
                reply(req_id, type="identity_register_result", **result)
            elif mtype == "identity_announce":
                result = sidecar.identity_announce(msg.get("destination_hash") or "")
                reply(req_id, type="identity_announce_result", **result)
            elif mtype == "path_status":
                result = sidecar.path_status(msg.get("destination_hash") or "")
                reply(req_id, type="path_status", **result)
            elif mtype == "request_path":
                result = sidecar.request_path(msg.get("destination_hash") or "")
                reply(req_id, type="request_path_result", **result)
            elif mtype == "lxmf_send":
                result = sidecar.lxmf_send(msg.get("message") or {})
                reply(req_id, type="lxmf_sent", **result)
            elif mtype == "packet":
                # Raw packet bridging reserved for interface-socket path; ack only.
                reply(
                    req_id,
                    type="ack",
                    data=msg.get("data"),
                    note="use_interface_socket",
                )
            elif mtype == "shutdown":
                break
            else:
                reply(req_id, type="error", error=f"unknown type {mtype}")
        except Exception as exc:  # noqa: BLE001
            reply(
                req_id,
                type="error",
                error=str(exc),
                trace=traceback.format_exc()[-800:],
            )

    try:
        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)
    except Exception:  # noqa: BLE001
        pass
    lock_fh.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
