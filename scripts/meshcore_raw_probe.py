#!/usr/bin/env python3
"""One-shot MeshCore companion framing probe (no Phoenix)."""

import serial
import time
import sys

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyACM0"


def framed(payload: bytes) -> bytes:
    return b"<" + len(payload).to_bytes(2, "little") + payload


def try_once(label: str, **kwargs):
    ser = serial.Serial(PORT, 115200, timeout=0.2, **kwargs)
    time.sleep(0.8)
    ser.reset_input_buffer()

    # DEVICE_QUERY: cmd + app protocol version (firmware requires len >= 2)
    ser.write(framed(bytes([0x16, 0x03])))
    ser.flush()
    time.sleep(0.15)
    # APP_START: cmd + 7 reserved bytes + null-terminated name at offset 8
    ser.write(framed(bytes([0x01]) + bytes(7) + b"Probe\x00"))
    ser.flush()

    buf = b""
    end = time.time() + 2.0
    while time.time() < end:
        chunk = ser.read(512)
        if chunk:
            buf += chunk

    print(f"{label}: framed rx {len(buf)} {buf[:120].hex()}")

    # parse > frames
    i = 0
    while i + 3 <= len(buf):
        if buf[i] != ord(">"):
            i += 1
            continue
        ln = int.from_bytes(buf[i + 1 : i + 3], "little")
        if i + 3 + ln > len(buf):
            break
        frame = buf[i + 3 : i + 3 + ln]
        code = frame[0] if frame else None
        print(f"  frame code=0x{code:02x} len={ln} hex={frame.hex()}")
        i += 3 + ln

    ser.reset_input_buffer()
    ser.write(bytes([0x16]))
    ser.flush()
    time.sleep(0.8)
    raw = ser.read(512)
    print(f"{label}: raw0x16 rx {len(raw)} {raw.hex()}")

    time.sleep(0.5)
    idle = ser.read(512)
    print(f"{label}: idle rx {len(idle)} {idle.hex()}")
    ser.close()


def main():
    for label, kw in [
        ("default", {}),
        ("dsrdtr_false", {"dsrdtr": False}),
        ("rtscts_true", {"rtscts": True}),
    ]:
        try:
            try_once(label, **kw)
        except Exception as e:
            print(f"{label}: ERR {type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
