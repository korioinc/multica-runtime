#!/bin/bash
# Prepare the container's desktop once, then run the original runtime command.
set -euo pipefail
runtime=/opt/multica/controller/runtime
if [[ "${1:-}" != worker || "${2:-}" != serve ]]; then
  exec "$runtime" "$@"
fi

umask 077
[[ "$XDG_RUNTIME_DIR" == /* && ! -L "$XDG_RUNTIME_DIR" ]]
[[ "$DISPLAY" =~ ^:[0-9]+$ && "$MULTICA_DESKTOP_SCREEN" =~ ^[1-9][0-9]*x[1-9][0-9]*x24$ ]]
mkdir -p "$XDG_RUNTIME_DIR"
[[ -O "$XDG_RUNTIME_DIR" && $(stat -c %a "$XDG_RUNTIME_DIR") == 700 ]]
config=/etc/multica/desktop-supervisord.conf
if ! supervisorctl -c "$config" pid >/dev/null 2>&1; then
  [[ ! -L "$XAUTHORITY" ]]
  touch "$XAUTHORITY"
  xauth -f "$XAUTHORITY" add "$DISPLAY" MIT-MAGIC-COOKIE-1 "$(mcookie)"
  # Supervisor replaces stale sockets from a previous container lifetime.
  supervisord -c "$config"
fi

for ((attempt=0; attempt<100; attempt++)); do
  if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 &&
     dbus-send --session --print-reply --reply-timeout=1000 --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames >/dev/null 2>&1 &&
     xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q 'window id # 0x'; then
    echo "Virtual display ready: $DISPLAY ($MULTICA_DESKTOP_SCREEN)" >&2
    exec "$runtime" "$@"
  fi
  sleep 0.1
done
supervisorctl -c "$config" status >&2 || true
echo "Virtual display startup failed; see $XDG_RUNTIME_DIR/*.log" >&2
exit 1
