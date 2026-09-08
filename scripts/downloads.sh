#!/usr/bin/env bash
# Versioned upstream URLs for the inputs exported from versions.env.
download_url() {
  if [[ $# -ne 2 ]]; then
    echo 'Usage: download_url NAME ARCH' >&2
    return 1
  fi
  local name=$1 target_arch=$2 cpu node_arch kctx google

  # --- Architecture names used by upstream releases ---
  case "$target_arch" in
    amd64) cpu=x86_64; node_arch=x64; kctx=x86_64; google=x86_64 ;;
    arm64) cpu=aarch64; node_arch=arm64; kctx=arm64; google=arm ;;
    *) echo "Unsupported download architecture: $target_arch" >&2; return 1 ;;
  esac

  case "$name" in
    # --- PHP runtime, Composer, and extensions ---
    php) printf 'https://www.php.net/distributions/php-%s.tar.xz\n' "${PHP_VERSION:?PHP_VERSION is required}" ;;
    composer) printf 'https://getcomposer.org/download/%s/composer.phar\n' "${COMPOSER_VERSION:?COMPOSER_VERSION is required}" ;;
    mongodb) printf 'https://pecl.php.net/get/mongodb-%s.tgz\n' "${MONGODB_PHP_EXTENSION_VERSION:?MONGODB_PHP_EXTENSION_VERSION is required}" ;;
    redis) printf 'https://pecl.php.net/get/redis-%s.tgz\n' "${PHPREDIS_VERSION:?PHPREDIS_VERSION is required}" ;;
    zstd) printf 'https://pecl.php.net/get/zstd-%s.tgz\n' "${ZSTD_PHP_EXTENSION_VERSION:?ZSTD_PHP_EXTENSION_VERSION is required}" ;;

    # --- Node.js and Rust toolchains ---
    node) printf 'https://nodejs.org/dist/v%s/node-v%s-linux-%s.tar.xz\n' "${NODE_VERSION:?NODE_VERSION is required}" "$NODE_VERSION" "$node_arch" ;;
    rust) printf 'https://static.rust-lang.org/dist/rust-%s-%s-unknown-linux-gnu.tar.xz\n' "${RUST_VERSION:?RUST_VERSION is required}" "$cpu" ;;

    # --- Developer CLIs and MCP tools ---
    multica) printf 'https://github.com/multica-ai/multica/releases/download/v%s/multica-cli-%s-linux-%s.tar.gz\n' "${MULTICA_CLI_VERSION:?MULTICA_CLI_VERSION is required}" "$MULTICA_CLI_VERSION" "$target_arch" ;;
    gh) printf 'https://github.com/cli/cli/releases/download/v%s/gh_%s_linux_%s.tar.gz\n' "${GH_VERSION:?GH_VERSION is required}" "$GH_VERSION" "$target_arch" ;;
    k9s) printf 'https://github.com/derailed/k9s/releases/download/v%s/k9s_Linux_%s.tar.gz\n' "${K9S_VERSION:?K9S_VERSION is required}" "$target_arch" ;;
    kubectl) printf 'https://dl.k8s.io/release/v%s/bin/linux/%s/kubectl\n' "${KUBECTL_VERSION:?KUBECTL_VERSION is required}" "$target_arch" ;;
    kubectx|kubens) printf 'https://github.com/ahmetb/kubectx/releases/download/v%s/%s_v%s_linux_%s.tar.gz\n' "${KUBECTX_VERSION:?KUBECTX_VERSION is required}" "$name" "$KUBECTX_VERSION" "$kctx" ;;
    yq) printf 'https://github.com/mikefarah/yq/releases/download/v%s/yq_linux_%s\n' "${YQ_VERSION:?YQ_VERSION is required}" "$target_arch" ;;
    shfmt) printf 'https://github.com/mvdan/sh/releases/download/v%s/shfmt_v%s_linux_%s\n' "${SHFMT_VERSION:?SHFMT_VERSION is required}" "$SHFMT_VERSION" "$target_arch" ;;
    lefthook) printf 'https://github.com/evilmartians/lefthook/releases/download/v%s/lefthook_%s_Linux_%s\n' "${LEFTHOOK_VERSION:?LEFTHOOK_VERSION is required}" "$LEFTHOOK_VERSION" "$kctx" ;;
    uv) printf 'https://github.com/astral-sh/uv/releases/download/%s/uv-%s-unknown-linux-gnu.tar.gz\n' "${UV_VERSION:?UV_VERSION is required}" "$cpu" ;;
    cbm) printf 'https://github.com/DeusData/codebase-memory-mcp/releases/download/v%s/codebase-memory-mcp-linux-%s-portable.tar.gz\n' "${CODEBASE_MEMORY_MCP_VERSION:?CODEBASE_MEMORY_MCP_VERSION is required}" "$target_arch" ;;

    # --- Cloud CLIs ---
    aws) printf 'https://awscli.amazonaws.com/awscli-exe-linux-%s-%s.zip\n' "$cpu" "${AWS_CLI_VERSION:?AWS_CLI_VERSION is required}" ;;
    gcloud) printf 'https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-%s-linux-%s.tar.gz\n' "${GCLOUD_CLI_VERSION:?GCLOUD_CLI_VERSION is required}" "$google" ;;
    *) echo "Unsupported download artifact: $name" >&2; return 1 ;;
  esac
}
