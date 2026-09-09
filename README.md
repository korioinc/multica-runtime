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

The Dockerfile projects validated inputs into separate OS, language, and package
files using only tools available in the controller base. Each installer consumes
its own file, so changing a Pi package version preserves the OS and language
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

## Languages and Package Managers

- Go SDK (included in the base image)
- JavaScript: Node.js, npm, Corepack
- Python 3: pip, venv, pipx, uv, uvx
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
- Build tools: Autoconf, Automake, CMake, Libtool, pkg-config, re2c
- Shell and data tools: Bash, ShellCheck, shfmt, jq, yq
- File and process tools: GNU coreutils, grep, file, tree, procps
- Editor and pager: Vim, less
- Network tools: curl, OpenSSH client, CA certificates
- Archive tools: tar, gzip, bzip2, xz, zip, unzip

## Development Libraries

- TLS and networking: `libssl-dev`, `libcurl4-openssl-dev`, `libsasl2-dev`
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
