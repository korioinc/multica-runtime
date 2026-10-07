#!/bin/bash
# shellcheck disable=SC2016
# Dollar expressions below are literal upstream shell source.
set -euo pipefail

# Both public commands and desktop entries use this upstream launcher. Keep its
# environment setup and exec semantics, and add the flags before caller arguments
# so an explicit -- separator cannot turn it into a positional argument.
launcher=/opt/google/chrome/google-chrome
original='exec -a "$0" "$HERE/chrome" "$@"'
[[ $(grep -Fxc -- "$original" "$launcher") == 1 ]] || {
  echo 'Unexpected Google Chrome launcher; cannot configure runtime flags' >&2
  exit 1
}
sed -i 's|^exec -a "\$0" "\$HERE/chrome" "\$@"$|exec -a "$0" "$HERE/chrome" --disable-dev-shm-usage --no-first-run "$@"|' "$launcher"
preserved_launcher=$launcher.multica-original

# Initialize once during the image build. Keep only the public extension
# and its installation metadata; each worker creates its own browser state.
/usr/bin/python3 - <<'PY'
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

extension_id = 'bgjoihaepiejlfjinojjfgokghnodnhd'
binary = '/opt/multica/tools/bin/open-browser-use'
destination = Path('/home/multica/agents/.config/google-chrome/Default')
setup = [binary, 'setup', '--no-open', '--browser', 'chrome']
with tempfile.TemporaryDirectory(prefix='chrome-profile-') as scratch:
    build_env = dict(os.environ, HOME=scratch, TMPDIR=scratch,
                     XDG_CONFIG_HOME=scratch + '/.config',
                     XDG_CACHE_HOME=scratch + '/.cache',
                     XDG_DATA_HOME=scratch + '/.local/share',
                     XDG_RUNTIME_DIR=scratch)
    profile = Path(scratch) / '.config/google-chrome/Default'
    # Exclude npx: setup otherwise also updates globally installed agent skills.
    subprocess.run(setup, env=dict(build_env, PATH='/usr/bin:/bin'), check=True)
    with open(Path(scratch) / 'chrome.log', 'w+') as log:
        # Root BuildKit initialization only; the runtime launcher keeps its sandbox.
        chrome = subprocess.Popen(
            ['/usr/bin/google-chrome-stable', '--headless', '--no-sandbox',
             '--user-data-dir=' + str(profile.parent), 'about:blank'],
            env=build_env, stdout=log, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic() + 120
            while chrome.poll() is None and time.monotonic() < deadline:
                try:
                    result = subprocess.run(
                        ['/opt/multica/tools/bin/obu', 'ping', '--browser', 'chrome',
                         '--profile', 'Default', '--session-id', 'image-chrome-bootstrap',
                         '--timeout', '1s'], env=build_env, stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL, timeout=2)
                    if result.returncode == 0:
                        break
                except subprocess.TimeoutExpired:
                    pass
                time.sleep(0.2)
            else:
                log.seek(0)
                raise SystemExit('Chrome extension initialization failed:\n' + log.read())
        finally:
            chrome.terminate()
            try:
                chrome.wait(timeout=10)
            finally:
                try:
                    os.killpg(chrome.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                chrome.wait()

    installed = json.loads((profile / 'Preferences').read_text())['extensions']['settings'][extension_id]
    # Exclude profile identifiers, keys, storage, and service-worker session state.
    settings = {key: installed[key] for key in (
        'active_permissions', 'creation_flags', 'disable_reasons', 'from_webstore',
        'granted_permissions', 'location', 'manifest', 'path', 'withholding_permissions')}
    destination.mkdir(parents=True, mode=0o700)
    shutil.copytree(profile / 'Extensions' / extension_id, destination / 'Extensions' / extension_id)
    (destination / 'Preferences').write_text(json.dumps({'extensions': {'settings': {extension_id: settings}}}) + '\n')

    # Publish setup's native host registration for every worker profile. Its
    # temporary HOME link cannot survive in the image; target the pinned binary.
    manifest_name = 'com.ifuryst.open_browser_use.extension.json'
    manifest = json.loads((profile.parent / 'NativeMessagingHosts' / manifest_name).read_text())
    manifest['path'] = binary
    native_hosts = Path('/etc/opt/chrome/native-messaging-hosts')
    native_hosts.mkdir(parents=True, exist_ok=True)
    manifest_path = native_hosts / manifest_name
    manifest_path.write_text(json.dumps(manifest) + '\n')
    manifest_path.chmod(0o444)

for path in [destination.parent.parent, destination.parent, destination, *destination.rglob('*')]:
    path.chmod(0o700 if path.is_dir() else 0o600)
    os.chown(path, 65532, 65532)
external = Path('/opt/google/chrome/extensions')
external.chmod(0o755)
(external / (extension_id + '.json')).chmod(0o444)
PY

# Aliases, desktop entries, and Obu all reach this root-owned image launcher.
# The runtime selects the launch domain from the typed bootstrap and kernel peer.
mv "$launcher" "$preserved_launcher"
cat > "$launcher" <<'LAUNCHER'
#!/bin/bash
exec /opt/multica/controller/runtime worker chrome "$@"
LAUNCHER
chmod 0755 "$launcher"
