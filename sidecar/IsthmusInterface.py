"""
IsthmusInterface — Reticulum custom interface for MeshChatX / local RNS nodes.

Install:
  mkdir -p ~/.reticulum/interfaces
  cp sidecar/IsthmusInterface.py ~/.reticulum/interfaces/

Config (~/.reticulum/config) — add under [interfaces]:

  [[Isthmus Bridge]]
    type = IsthmusInterface
    enabled = yes
    isthmus_socket = /tmp/isthmus.sock

Match `isthmus_socket` to Isthmus `ISTHMUS_RNS_SOCKET` (default `/tmp/isthmus.sock`).

This interface speaks HDLC-framed RNS packets (same as PipeInterface) over a
Unix domain socket to the Isthmus daemon, enabling RNS-over-MeshCore tunnels.
LXMF gateway traffic does NOT need this interface — that uses Isthmus's own
sidecar RNS instance under ~/.isthmus/reticulum.
"""

from __future__ import annotations

import socket
import threading
import time

import RNS
from RNS.Interfaces.Interface import Interface


class HDLC:
    FLAG = 0x7E
    ESC = 0x7D
    ESC_MASK = 0x20

    @staticmethod
    def escape(data: bytes) -> bytes:
        data = data.replace(bytes([HDLC.ESC]), bytes([HDLC.ESC, HDLC.ESC ^ HDLC.ESC_MASK]))
        data = data.replace(bytes([HDLC.FLAG]), bytes([HDLC.ESC, HDLC.FLAG ^ HDLC.ESC_MASK]))
        return data


class IsthmusInterface(Interface):
    DEFAULT_IFAC_SIZE = 8
    HW_MTU = 1064
    BITRATE_GUESS = 10_000

    def __init__(self, owner, configuration):
        super().__init__()
        c = Interface.get_config_obj(configuration)
        self.HW_MTU = IsthmusInterface.HW_MTU
        self.owner = owner
        self.name = c["name"]
        self.socket_path = (
            c["isthmus_socket"] if "isthmus_socket" in c else "/tmp/isthmus.sock"
        )
        self.online = False
        self.bitrate = IsthmusInterface.BITRATE_GUESS
        self._sock = None
        self._rx_thread = None
        self.spawn_connect()

    def spawn_connect(self):
        threading.Thread(target=self._connect_loop, daemon=True).start()

    def _connect_loop(self):
        while True:
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.connect(self.socket_path)
                self._sock = sock
                self.online = True
                RNS.log(
                    f"IsthmusInterface {self} connected to {self.socket_path}",
                    RNS.LOG_NOTICE,
                )
                self._read_loop()
            except Exception as exc:  # noqa: BLE001
                self.online = False
                self._sock = None
                RNS.log(
                    f"IsthmusInterface reconnecting after error: {exc}",
                    RNS.LOG_ERROR,
                )
                time.sleep(5)

    def _read_loop(self):
        in_frame = False
        escape = False
        data_buffer = b""

        try:
            while self.online and self._sock:
                chunk = self._sock.recv(4096)
                if not chunk:
                    break

                for byte in chunk:
                    if in_frame and byte == HDLC.FLAG:
                        in_frame = False
                        if data_buffer:
                            self.rxb += len(data_buffer)
                            self.owner.inbound(data_buffer, self)
                        data_buffer = b""
                        escape = False
                    elif byte == HDLC.FLAG:
                        in_frame = True
                        data_buffer = b""
                        escape = False
                    elif in_frame and len(data_buffer) < self.HW_MTU:
                        if byte == HDLC.ESC:
                            escape = True
                        else:
                            if escape:
                                if byte == HDLC.FLAG ^ HDLC.ESC_MASK:
                                    byte = HDLC.FLAG
                                elif byte == HDLC.ESC ^ HDLC.ESC_MASK:
                                    byte = HDLC.ESC
                                escape = False
                            data_buffer += bytes([byte])
        finally:
            self.online = False
            try:
                if self._sock:
                    self._sock.close()
            except Exception:  # noqa: BLE001
                pass
            self._sock = None

    def process_outgoing(self, data):
        if self.online and self._sock:
            try:
                frame = bytes([HDLC.FLAG]) + HDLC.escape(data) + bytes([HDLC.FLAG])
                self._sock.sendall(frame)
                self.txb += len(data)
            except Exception as exc:  # noqa: BLE001
                RNS.log(f"IsthmusInterface send failed: {exc}", RNS.LOG_ERROR)
                self.online = False

    def __str__(self):
        return f"IsthmusInterface[{self.name}]"
