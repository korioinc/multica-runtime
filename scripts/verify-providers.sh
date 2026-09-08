#!/bin/bash
# Browser-free local protocol probes. No prompt/model generation is sent.
set -euo pipefail
umask 077
scratch=$(mktemp -d /tmp/runtime-providers.XXXXXX)
server_pid=''
cleanup_server() {
  if [[ -n "$server_pid" ]]; then
    kill -- "-$server_pid" 2>/dev/null || kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=''
  fi
}
cleanup() { cleanup_server; rm -rf -- "$scratch"; }
trap cleanup EXIT
start_server() {
  local name=$1
  shift
  : > "$scratch/$name.stderr"
  coproc SERVER { exec setsid "$@" 2> "$scratch/$name.stderr"; }
  # shellcheck disable=SC2153
  server_pid=$SERVER_PID
  exec {server_input}>&"${SERVER[1]}"
  exec {server_output}<&"${SERVER[0]}"
}
receive() {
  local predicate=$1 line deadline=$((SECONDS + 90))
  while ((SECONDS < deadline)); do
    IFS= read -r -t "$((deadline - SECONDS))" -u "$server_output" line || break
    if jq -e "$predicate" <<< "$line" >/dev/null 2>&1; then printf '%s\n' "$line"; return; fi
    if jq -e '.error != null or .type == "extension_error" or (.type == "response" and .success == false)' <<< "$line" >/dev/null 2>&1; then
      echo 'Local provider protocol returned an error' >&2
      jq -r 'if (.error | type) == "string" then .error elif (.error | type) == "object" then .error.message else "fixture request failed" end' <<< "$line" >&2
      return 1
    fi
  done
  echo 'Local provider protocol did not complete' >&2
  cat "$scratch"/*.stderr >&2
  return 1
}
send() { printf '%s\n' "$1" >&"$server_input"; }
mcp_probe() {
  local name=$1
  shift
  start_server "$name" "$@"
  send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"runtime-image-verifier","version":"1.0.0"}}}'
  receive '.id == 1 and .result != null' > "$scratch/$name.initialize.json"
  send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  send '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  receive '.id == 2 and (.result.tools | length > 0)' > "$scratch/$name.tools.json"
  if [[ "$name" == cbm ]]; then
    send '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_projects","arguments":{}}}'
    receive '.id == 3 and .result != null and .result.isError != true' > "$scratch/$name.read.json"
  fi
  cleanup_server
  echo "$name: MCP initialization and tool discovery passed"
}
mcp_probe cbm /opt/multica/tools/bin/codebase-memory-mcp
mcp_probe chrome /opt/multica/tools/providers/node_modules/.bin/chrome-devtools-mcp

mkdir -p "$HOME/.pi/agent"
# Exercise the same npm resolver as operator settings, using the image's
# installed manifest as input instead of maintaining a separate package list.
# The Pi launcher prepares its writable npm directory on the first invocation.
jq '{packages:(.dependencies | keys | map("npm:" + .)),
  defaultProvider:"runtime-fixture",defaultModel:"local-model"}' \
  /opt/multica/tools/pi-packages/package.json > "$HOME/.pi/agent/settings.json"
jq -n '{providers:{"runtime-fixture":{baseUrl:"http://127.0.0.1:1/v1",api:"openai-completions",apiKey:"synthetic-not-a-credential",models:[{id:"local-model",name:"Local fixture",reasoning:false,input:["text"],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:32768,maxTokens:2048}]}}}' > "$HOME/.pi/agent/models.json"
jq -n '{mcpServers:{fixture:{command:"/opt/multica/tools/bin/codebase-memory-mcp"}}}' > "$HOME/.pi/agent/mcp.json"
# Pi's CLI bundle supplies the SDK alias to extensions. Using that supported
# loader avoids optional server packages imported by the standalone SDK barrel.
cat > "$scratch/pi-mcp-read.ts" <<'FIXTURE'
import { createAgentSession, SessionManager } from "@earendil-works/pi-coding-agent";
export default function (pi) {
  pi.registerCommand("runtime-image-mcp-read", {
    description: "Local image verification fixture; performs no model request",
    handler: async (_args, ctx) => {
      const { session, extensionsResult } = await createAgentSession({ sessionManager: SessionManager.inMemory() });
      try {
        if (extensionsResult.errors.length) throw new Error("Pi could not load image extensions");
        await session.bindExtensions({ mode: "rpc" });
        const mcp = session.agent.state.tools.find(tool => tool.name === "mcp");
        if (!mcp) throw new Error("Pi MCP tool was not loaded");
        const connected = await mcp.execute("runtime-fixture-connect", { connect: "fixture" }, AbortSignal.timeout(30000));
        if (connected.isError || connected.details?.isError || connected.details?.error) throw new Error(`Pi MCP connection failed: ${connected.details?.error ?? "server_error"}`);
        const result = await mcp.execute("runtime-fixture-read", { server: "fixture", tool: "fixture_list_projects", args: {} }, AbortSignal.timeout(30000));
        if (result.isError || result.details?.isError || result.details?.error) throw new Error(`Pi MCP read failed: ${result.details?.error ?? "server_error"}`);
        const projects = result.content.filter(item => item.type === "text").some(item => {
          try { return Array.isArray(JSON.parse(item.text).projects); } catch { return false; }
        });
        if (!projects) throw new Error("Pi MCP adapter did not return the local server read result");
        ctx.ui.notify("runtime-image-mcp-read-passed", "info");
      } finally {
        await session.extensionRunner.emit({ type: "session_shutdown", reason: "exit" });
        session.dispose();
      }
    }
  });
}
FIXTURE
for startup in first repeat; do
  start_server "pi-$startup" pi --mode rpc --no-session --extension "$scratch/pi-mcp-read.ts"
  send '{"id":"models","type":"get_available_models"}'
  receive '.id == "models" and .success == true and (.data.models | any(.id == "local-model" and .provider == "runtime-fixture"))' > "$scratch/pi-$startup.models.json"
  send '{"id":"state","type":"get_state"}'
  receive '.id == "state" and .success == true and .data.model.id == "local-model"' > "$scratch/pi-$startup.state.json"
  send '{"id":"commands","type":"get_commands"}'
  receive '.id == "commands" and .success == true and (.data.commands | any(.name == "mcp" and .source == "extension")) and (.data.commands | any(.name == "runtime-image-mcp-read"))' > "$scratch/pi-$startup.commands.json"
  send '{"id":"mcp-read","type":"prompt","message":"/runtime-image-mcp-read"}'
  receive '.type == "extension_ui_request" and .method == "notify" and .message == "runtime-image-mcp-read-passed"' > "$scratch/pi-$startup.mcp-read.json"
  receive '.id == "mcp-read" and .success == true' > "$scratch/pi-$startup.mcp-complete.json"
  cleanup_server
  echo "Pi $startup startup: npm packages loaded, synthetic model selected and RPC extension commands available"
  echo "Pi $startup startup: actual MCP adapter -> CBM list_projects read passed without model generation"
done

start_server codex codex app-server
send '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"runtime-image-verifier","version":"1.0.0"},"capabilities":{"experimentalApi":true}}}'
receive '.id == 1 and .result != null' > "$scratch/codex.initialize.json"
send '{"method":"initialized","params":{}}'
send '{"id":2,"method":"model/list","params":{}}'
receive '.id == 2 and (.result.data | length > 0)' > "$scratch/codex.models.json"
cleanup_server
echo 'Codex: actual app-server initialization and model discovery passed without generation'
