# Multica Runtime

Multica Runtime is a custom development image based on the image from [korioinc/multica-runtime-controller](https://github.com/korioinc/multica-runtime-controller). It adds the languages, package managers, and tools needed for software development.

## Build Inputs and Verification

`versions.env` is the public source of build versions. `scripts/lib.sh` owns the
required keys and their installation scopes; unknown, duplicate, missing, and
invalid values fail before installation. Inspect or validate inputs with:

```sh
scripts/inputs.sh check --production
scripts/inputs.sh env languages
scripts/inputs.sh npm-manifest pi-packages
```

The Dockerfile projects validated inputs into OS, language, package, and desktop
files using only tools available in the controller base. All installation layers
feed the same final runtime image. Each installer consumes its own file, so
changing a Pi package version preserves the OS and language
installation caches. The prepared image records the exact original `versions.env`
in `/opt/multica/runtime/inventory/versions.env`; final verification compares it
with the checkout. Adding a tool requires assigning its version key to a scope in
`runtime_input_keys` as well as adding its installer and execution probe.

Builds progress through installation, a prepared image, controller-owned adapter
verification, and a final image containing the verification report. Before that
report exists, native tool probes use a disposable seeded HOME. Final image
verification uses the controller's actual `home layout` initialization. These
two paths have distinct bootstrap and admission responsibilities.

Release failures report the operation, command exit code, and captured output on
stderr while preserving JSON output for successful commands. A failed remote
write may already have completed; retries inspect existing artifacts and retain
the verified immutable bytes.

## Tool Search Paths

The image sets `PATH` for direct commands and non-login shells. Login shells such as
`bash -lc` also load `/etc/profile.d/10-multica-path.sh`, generated from the same
`build/layout.json` tool directories used by the controller. The profile restores
missing directories without duplicating existing entries.
Image finalization also checks that Docker's `ENV PATH` matches the layout, so a
new tool directory cannot silently work only through controller-managed commands.

This applies to task-worker Pods with a fresh HOME volume and an overridden image
entrypoint. Preinstalled commands such as `multica`, `codex`, `pi`, `node`, `php`,
`cargo`, `go`, and `chrome-devtools-mcp` can be invoked by name. Rebuild the image
and recreate Pods with the new image to apply changes to the system profile.

`python` and `python3` use Debian's system Python, and `pip`, `pip3`, and
`python -m pip` use its matching pip installation. The OCI CLI keeps its own
virtual environment, but only the `oci` executable is linked into the shared
tools directory. Its Python and pip executables are excluded from the shared
`PATH`, including login shells and controller-managed commands.

Install project dependencies in a writable virtual environment. Debian manages
the system Python, while preinstalled cloud tools live in read-only directories:

```sh
python -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
```

Activating the environment makes `python`, `python3`, and `pip` use that
environment. `uv venv` and `uv pip install` are also available. User-installed
CLI tools from pipx or `uv tool install` normally live in `$HOME/.local/bin`;
add that directory to the current shell's `PATH` when using them.

## Virtual Desktop and Cua Driver

The standard runtime image includes [Cua Driver](https://cua.ai/docs/tutorials/drive-your-first-app),
official Google Chrome Stable, and an X11 desktop backed by Xvfb and Openbox.
Every normal build and release includes these tools alongside the existing
controller, language runtimes, and agent tools. Deploy the runtime image through
the existing controller and task-worker deployment flow.
The desktop renders real windows at `2560x1440x24` without a physical monitor.
D-Bus and AT-SPI provide native application accessibility. Mousepad is available
as a small native GUI app.
Cua Driver is pinned in `versions.env`; both Linux architectures use official
release archives checked against `build/cua-driver.sha256`. Skills and MCP client
registrations are left to the caller.

Chrome's Debian package version is also pinned in `versions.env`. Official ARM64
and AMD64 packages are checked against `build/google-chrome.sha256`; browser updates
are applied by updating the pin and checksums and rebuilding the image.

The image entrypoint prepares the desktop as UID 65532 before starting
`worker serve` in each task-worker Pod. The screen is ready before Chrome or Cua
Driver is invoked in that worker. The worker keeps PID 1 and its existing process
reaper. The controller Pod and management commands such as `image verify` and
`home layout` go directly to the runtime without starting a desktop.
The desktop's private configuration,
logs, Xauthority cookie, and Unix sockets live under `/tmp/multica-desktop` with
mode `0700`. X11 TCP access is disabled; no VNC or HTTP service is started.
Runtime `HOME` and `/tmp` must be writable, including on a read-only root filesystem.

The image environment and controller layout share `DISPLAY=:99`,
`XDG_RUNTIME_DIR=/tmp/multica-desktop`,
`DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/multica-desktop/bus`, and
`XAUTHORITY=/tmp/multica-desktop/Xauthority`, so later `docker exec` commands and
agent processes can use the same screen. `cua-driver` resolves directly to the
official executable, and Chrome uses its official `google-chrome-stable` command.
There are no per-command desktop or browser launch wrappers. Inspect the prepared
screen and use the installed programs inside the task-worker container:

```sh
xdpyinfo -display "$DISPLAY"
google-chrome-stable about:blank
cua-driver serve
```

From another command in the same task-worker container:

```sh
cua-driver doctor
```

Set `MULTICA_DESKTOP_SCREEN=1920x1080x24` when creating the container to change
the resolution from the default `2560x1440x24`.
Screen contents are ephemeral and disappear when the container stops.

Chrome accepts its standard options, including `--ozone-platform=x11` and
`--force-renderer-accessibility` when needed. In a disposable container where the
runtime blocks user namespaces and the setuid sandbox, the caller can explicitly
use `google-chrome-stable --no-sandbox about:blank`; this disables Chrome's
process sandbox and requires container isolation. Allocate sufficient `/dev/shm`
(for example, Docker `--shm-size=1g`, or a memory-backed Kubernetes volume).

The deployment must preserve the image entrypoint for this startup sequence.
Controller `0.3.45` starts worker Pods with `args: [worker, serve]` and preserves
the image entrypoint; its Pod validation requires that shape. Select `0.3.45`
or a compatible newer controller. Older controllers that override the worker
Pod's `command` bypass desktop initialization.

The driver starts in the task-worker Pod when the caller runs its CLI/service/MCP
workflow after the worker's HOME initialization. Follow the
[Linux setup and readiness checks](https://cua.ai/docs/how-to-guides/driver/install)
when connecting an agent. An empty app list does not prove GUI readiness: launch
an application, then inspect its window and accessibility state. Xvfb supports
capture and AT-SPI operations, but some raw background input routes require a
full Xorg session and `/dev/uinput`; see the
[Linux limitations](https://cua.ai/docs/concepts/linux-desktops-and-computer-use).

## Languages and Package Managers

- Go SDK (included in the base image)
- JavaScript: Node.js, npm, Corepack
- Python 3: pip, venv, pipx, uv, uvx, development headers (`python3-dev`)
- PHP CLI: Composer
- Rust: rustc, Cargo
- C/C++: GCC, G++, Make (`build-essential`)

## PHP Extensions

- Strings and internationalization: mbstring, intl
- Math: bcmath, gmp
- Processes and networking: pcntl, sockets, curl, openssl
- Databases: mysqli, pdo_mysql, pdo_pgsql, mongodb, redis
- Compression: bz2, zlib, zip, zstd
- Other: readline, xsl

## AI and MCP Tools

- Multica CLI
- OpenAI Codex (`@openai/codex`)
- Pi Coding Agent (`@earendil-works/pi-coding-agent`)
- Codebase Memory MCP (`codebase-memory-mcp`)
- Chrome DevTools MCP (`chrome-devtools-mcp`)

## Pi Packages

- `pi-mcp-adapter`
- `pi-web-access`
- `pi-openai-service-tier`
- `@dietrichgebert/ponytail`
- `pi-cache-optimizer`

Packages and their dependencies are installed at image build time in
`/opt/multica/runtime/home-seed/.pi/agent/npm`. The controller's HOME
initialization copies this installation to `~/.pi/agent/npm` before the worker
starts. Both direct shell commands and controller-managed Pi execute the
installed Pi CLI directly. Operator settings can keep `npm:` references without
network installation on a new Pod. An existing npm directory is preserved,
including user package additions and updates. Package changes remain local to
that Pod.

Extension installs use Pi's `--legacy-peer-deps` policy because its loader
provides the host Pi APIs. HOME initialization publishes the complete package
directory from a private staging directory without replacing existing state,
preserving executable bits and npm command links within the package tree. The
HOME seed validator allows package source directories such as `token` under
`node_modules` while retaining credential/session checks outside the package
installation. Image verification uses `npm:` references for both the first Pi
launch and a second launch in the same HOME, including an actual MCP read.
Final image verification initializes that HOME through the controller.

## Installed Dependency Records

The image stores resolved dependency inventories under
`/opt/multica/runtime/inventory`: `debian.tsv`, `npm-providers.json`,
`npm-pi-packages.json`, and `python-oci.json`. npm records use
[`npm query`](https://docs.npmjs.com/cli/v11/commands/npm-query/) to inspect the
installed package trees, including Pi's installation with host-provided peer
APIs. They retain package names, versions, locations, and available source URLs
and integrity hashes in a stable order. Python records use the OCI virtual
environment's `pip list`.

These records make differences between builds inspectable. Direct version pins
and installed inventories do not lock transitive dependency resolution or promise
byte-identical rebuilds.

## Development and System Tools

- Git: Git, Git LFS, git-flow, GitHub CLI (`gh`), Lefthook
- Build tools: Autoconf, Automake, CMake, Ninja, Libtool, pkg-config, re2c
- Shell and data tools: Bash, ShellCheck, shfmt, jq, yq
- File and process tools: GNU coreutils, grep, ripgrep (`rg`), fd, file, tree, rsync, procps, lsof
- Editor and pager: Vim, less
- Network tools: curl, OpenSSH client, CA certificates, iproute2 (`ip`, `ss`), bind9-dnsutils (`dig`)
- Archive tools: tar, gzip, bzip2, xz, zip, unzip, zstd

Ripgrep comes from the pinned Debian snapshot. Bookworm's `fd-find` is 8.6 and
installs the command as `fdfind`, so the image installs the official
[fd release](https://github.com/sharkdp/fd/releases) as `fd` instead.
`FD_VERSION` pins a version meeting the minimum requirement of 8.7; both AMD64
and ARM64 archives are checked against `build/fd.sha256`. Update the version
and both checksums together when upgrading.

## Development Libraries

- TLS and networking: `libssl-dev`, `libcurl4-openssl-dev`, `libsasl2-dev`
- Python native extensions: `python3-dev`, `libffi-dev`
- Databases: `libpq-dev`, `libsqlite3-dev`
- Text and XML: `libicu-dev`, `libonig-dev`, `libreadline-dev`, `libxml2-dev`, `libxslt1-dev`
- Images: `libjpeg-dev`, `libpng-dev`, `libwebp-dev`
- Compression: `libbz2-dev`, `libzip-dev`, `libzstd-dev`, `zlib1g-dev`
- Math: `libgmp-dev`

## Document and Media Tools

- Pandoc
- Poppler utilities
- ImageMagick
- FFmpeg
- groff-base

## Kubernetes and Cloud Tools

- Kubernetes: kubectl, k9s, kubectx, kubens
- AWS CLI v2
- Oracle Cloud Infrastructure CLI (`oci`)
- Google Cloud CLI (`gcloud`)
