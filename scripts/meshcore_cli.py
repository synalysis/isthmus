#!/usr/bin/env python3
"""Send CLI commands to a MeshCore repeater console and print the replies.

The repeater console terminates commands with a carriage return, not a newline.
"""

import sys
import time

import serial

PORT = "/dev/ttyACM0"


def run(port, commands, settle=0.6):
    with serial.Serial(port, 115200, timeout=0.5) as ser:
        time.sleep(0.3)
        ser.reset_input_buffer()
        for cmd in commands:
            ser.write((cmd + "\r").encode())
            ser.flush()
            time.sleep(settle)
            reply = ser.read(4096).decode(errors="replace").strip()
            print(f"{cmd:<28} -> {reply}")


if __name__ == "__main__":
    args = sys.argv[1:]
    port = PORT
    if args and args[0].startswith("/dev/"):
        port = args.pop(0)
    run(port, args)
