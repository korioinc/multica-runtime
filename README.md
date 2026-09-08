# Multica Runtime

Multica Runtime is a custom development image based on the image from [korioinc/multica-runtime-controller](https://github.com/korioinc/multica-runtime-controller). It adds the languages, package managers, and tools needed for software development.

## Tool Search Paths

The image sets `PATH` for direct commands and non-login shells. Login shells such as
`bash -lc` also load `/etc/profile.d/10-multica-path.sh`, generated from the same
`build/layout.json` tool directories used by the controller. The profile restores
missing directories without duplicating existing entries.

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
- `pi-thinking-level`
- `pi-web-access`
- `pi-openai-service-tier`
- `@dietrichgebert/ponytail`
- `pi-cache-optimizer`

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
