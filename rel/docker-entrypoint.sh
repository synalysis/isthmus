#!/usr/bin/env bash
# Docker entrypoint: make USB serial nodes writable, then drop privileges.
#
# Host dialout GID often differs from Debian's (Fedora=18, Debian=20), so
# usermod -aG dialout is not enough. World-writable nodes work across GIDs.
# --keep-groups preserves docker --group-add (host dialout) if it was set.
set -euo pipefail

chmod_usb() {
  shopt -s nullglob
  local d
  for d in /dev/ttyUSB* /dev/ttyACM* /dev/ttyAMA*; do
    chmod 666 "$d" 2>/dev/null || true
  done
}

drop_to_nobody() {
  if command -v setpriv >/dev/null 2>&1; then
    exec setpriv --reuid=nobody --regid=nogroup --keep-groups --inh-caps=-all -- "$@"
  fi
  echo "isthmus: setpriv not found; staying root so USB serial stays usable" >&2
  exec "$@"
}

if [ "$(id -u)" = "0" ]; then
  chmod_usb
  if [ "${ISTHMUS_RUN_AS_ROOT:-}" = "true" ]; then
    exec "$@"
  fi
  drop_to_nobody "$@"
fi

exec "$@"
