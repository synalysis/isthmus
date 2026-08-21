#!/usr/bin/env python3
"""Write one ESP32 image with esptool (offset + file)."""

from __future__ import annotations

import argparse
import sys


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--offset", required=True, help="Flash address, e.g. 0x0 or 0x10000")
    parser.add_argument("--image", required=True)
    args = parser.parse_args(argv)

    try:
        import esptool
    except ImportError:
        print(
            "esptool is not installed. pip install -r sidecar/firmware-requirements.txt",
            file=sys.stderr,
        )
        return 2

    try:
        offset = int(args.offset, 0)
    except ValueError:
        print(f"invalid offset {args.offset!r}", file=sys.stderr)
        return 2

    esptool.main(
        [
            "--chip",
            "auto",
            "--port",
            args.port,
            "--baud",
            "460800",
            "write_flash",
            hex(offset),
            args.image,
        ]
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
