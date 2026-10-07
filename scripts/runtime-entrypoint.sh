#!/bin/bash
# The worker becomes PID 1 before optional desktop processes can start.
set -euo pipefail

configure_package_proxy() {
  [[ -n "${PACKAGE_PROXY_URL:-}" ]] || return 0
  local proxy_url=$PACKAGE_PROXY_URL cargo_config="$HOME/.cargo/config.toml" proxy_host trusted_hosts
  while [[ "$proxy_url" == */ ]]; do proxy_url=${proxy_url%/}; done
  [[ "$proxy_url" =~ ^https?://[^/?#[:space:]]+(/[^?#[:space:]]*)?$ ]] || {
    echo 'PACKAGE_PROXY_URL must be an HTTP(S) base URL without query or fragment' >&2
    return 1
  }

  # Rust (Cargo)
  # Cargo still prefers its legacy filename when it is present.
  [[ ! -f "$HOME/.cargo/config" ]] || cargo_config="$HOME/.cargo/config"
  mkdir -p "$HOME/.cargo"
  touch "$cargo_config"
  PACKAGE_PROXY_CARGO_REGISTRY="sparse+$proxy_url/cargo/" yq -p toml -o toml -i \
    '.source."crates-io"."replace-with" = "proxy" | .source.proxy = {"registry": strenv(PACKAGE_PROXY_CARGO_REGISTRY)}' \
    "$cargo_config"

  # JavaScript / TypeScript (npm)
  npm config set registry "$proxy_url/npm/" --location=user --userconfig="$HOME/.npmrc"

  # Python (pip)
  pip config --user set global.index-url "$proxy_url/pypi/simple/" >/dev/null

  # PHP (Composer)
  composer --no-plugins --no-scripts --no-interaction config --global \
    repositories.proxy composer "$proxy_url/composer"

  if [[ "$proxy_url" == http://* ]]; then
    # Python (pip): trust the HTTP proxy host.
    proxy_host=${proxy_url#*://}
    proxy_host=${proxy_host%%/*}
    proxy_host=${proxy_host##*@}
    trusted_hosts=$(pip config --user get global.trusted-host 2>/dev/null || true)
    if ! printf '%s\n' "$trusted_hosts" | tr '[:space:]' '\n' | grep -Fxq -- "$proxy_host"; then
      pip config --user set global.trusted-host "${trusted_hosts:+$trusted_hosts$'\n'}$proxy_host" >/dev/null
    fi
    # PHP (Composer): allow HTTP repositories.
    composer --no-plugins --no-scripts --no-interaction config --global secure-http false
  fi
}

runtime=/opt/multica/controller/runtime
if [[ "${1:-}" == controller ]]; then
  # Capture the injected value in the controller's existing worker environment
  # contract, including its configuration digest. Explicit operator values win.
  if [[ -v PACKAGE_PROXY_URL && ! -v MULTICA_OPERATOR_PACKAGE_PROXY_URL ]]; then
    export MULTICA_OPERATOR_PACKAGE_PROXY_URL="$PACKAGE_PROXY_URL"
  fi
  exec "$runtime" init "$@"
fi
case "${1:-}" in
  --worker-task)
    [[ $# == 1 ]]
    umask 077
    configure_package_proxy
    exit 0
    ;;
  --worker-desktop) [[ $# == 1 ]] ;;
  *) exec "$runtime" "$@" ;;
esac

# Invoked once by the admitted session's neutral desktop owner.
umask 077
[[ "$XDG_RUNTIME_DIR" == /* && ! -L "$XDG_RUNTIME_DIR" ]]
[[ "$DISPLAY" =~ ^:[0-9]+$ && "$MULTICA_DESKTOP_SCREEN" =~ ^[1-9][0-9]*x[1-9][0-9]*x24$ ]]
mkdir -p "$XDG_RUNTIME_DIR"
[[ -O "$XDG_RUNTIME_DIR" && $(stat -c %a "$XDG_RUNTIME_DIR") == 700 ]]
config=/etc/multica/desktop-supervisord.conf
# Supervisor redirects desktop settings; Cua must share the agent CLI's paths.
export MULTICA_CUA_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
export MULTICA_CUA_CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}
export MULTICA_CUA_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
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
    if ! supervisorctl -c "$config" status cua-driver | grep -q 'RUNNING'; then
      supervisorctl -c "$config" start cua-driver || break
    fi
    deadline=$((SECONDS + 10))
    while ((SECONDS < deadline)); do
      if timeout 1 cua-driver call list_apps '{}' </dev/null >/dev/null 2>&1; then
        echo "Virtual display and Cua Driver ready: $DISPLAY ($MULTICA_DESKTOP_SCREEN)" >&2
        exit 0
      fi
      sleep 0.1
    done
    break
  fi
  sleep 0.1
done
supervisorctl -c "$config" status >&2 || true
echo "Virtual display or Cua Driver startup failed; see $XDG_RUNTIME_DIR/*.log" >&2
exit 1
