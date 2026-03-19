#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="${DOCKER_E2E_SMOKE_IMAGE:-shell-as-mcp:latest}"
HOST="${DOCKER_E2E_SMOKE_HOST:-127.0.0.1}"
PORT="${DOCKER_E2E_SMOKE_PORT:-}"
HTTP_PATH="${DOCKER_E2E_SMOKE_HTTP_PATH:-/mcp}"
PROTOCOL_VERSION="${DOCKER_E2E_PROTOCOL_VERSION:-2025-03-26}"
KEEP_WORKDIR="${DOCKER_E2E_KEEP_WORKDIR:-0}"
KEEP_CONTAINER="${DOCKER_E2E_KEEP_CONTAINER:-0}"

WORK_DIR="$(mktemp -d /tmp/docker_e2e_smoke_XXXXXX)"
SERVER_LOG="$WORK_DIR/server.log"
INIT_HEADERS="$WORK_DIR/init.headers"
INIT_BODY="$WORK_DIR/init.body"
NOTI_HEADERS="$WORK_DIR/noti.headers"
NOTI_BODY="$WORK_DIR/noti.body"
LIST_HEADERS="$WORK_DIR/list.headers"
LIST_BODY="$WORK_DIR/list.body"
CALL_HEADERS="$WORK_DIR/call.headers"
CALL_BODY="$WORK_DIR/call.body"
LIST_PAYLOAD="$WORK_DIR/list.payload.json"
CALL_PAYLOAD="$WORK_DIR/call.payload.json"

CONTAINER_NAME="docker-e2e-smoke-$(date +%s)-$RANDOM"
CONTAINER_ID=""
SESSION_ID=""

cleanup() {
  if [[ -n "$CONTAINER_ID" && "$KEEP_CONTAINER" != "1" ]]; then
    docker kill "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi

  if [[ "$KEEP_WORKDIR" == "1" ]]; then
    echo "INFO: keep work dir: $WORK_DIR"
  else
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

assert_status_in() {
  local name="$1"
  local actual="$2"
  local allowed_csv="$3"

  case ",$allowed_csv," in
    *",$actual,"*) ;;
    *)
      echo "ERROR: $name expected status in [$allowed_csv], got $actual" >&2
      exit 1
      ;;
  esac
}

extract_session_id() {
  awk '
    tolower($0) ~ /^mcp-session-id:/ {
      line = $0
      sub(/^[^:]*:[[:space:]]*/, "", line)
      sub(/\r$/, "", line)
      print line
      exit
    }
  ' "$1"
}

resolve_port() {
  if [[ -n "$PORT" ]]; then
    return 0
  fi

  PORT="$(node -e "const n=require('net');const s=n.createServer();s.listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close();});")"
}

wait_for_server_ready() {
  for _ in $(seq 1 60); do
    if grep -Eq "streamable-http at http://[^[:space:]]+$HTTP_PATH" "$SERVER_LOG"; then
      return 0
    fi

    if [[ -n "$CONTAINER_ID" ]]; then
      local running
      running="$(docker inspect -f '{{.State.Running}}' "$CONTAINER_ID" 2>/dev/null || echo false)"
      if [[ "$running" != "true" ]]; then
        echo "ERROR: container exited before readiness" >&2
        docker logs "$CONTAINER_ID" >&2 || true
        exit 1
      fi
    fi

    sleep 0.25
  done

  echo "ERROR: streamable-http server not ready in time" >&2
  cat "$SERVER_LOG" >&2 || true
  exit 1
}

extract_json_payload() {
  node -e "
const fs = require('node:fs');
const inputPath = process.argv[1];
const outputPath = process.argv[2];
const raw = fs.readFileSync(inputPath, 'utf8').trim();

function parseJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

let payload = parseJson(raw);
if (!payload) {
  const candidates = raw
    .split(/\\r?\\n/)
    .filter((line) => line.startsWith('data:'))
    .map((line) => line.slice(5).trim())
    .map((line) => parseJson(line))
    .filter((obj) => obj && typeof obj === 'object');
  payload = candidates.find((obj) => Object.prototype.hasOwnProperty.call(obj, 'result') || Object.prototype.hasOwnProperty.call(obj, 'error')) || null;
}

if (!payload) {
  process.stderr.write('failed to extract JSON payload from response body\\n');
  process.exit(2);
}

fs.writeFileSync(outputPath, JSON.stringify(payload));
" "$1" "$2"
}

list_healthz_tools() {
  node -e "
const fs = require('node:fs');
const filePath = process.argv[1];
const raw = fs.readFileSync(filePath, 'utf8');
const payload = JSON.parse(raw);
const tools = payload?.result?.tools;
if (!Array.isArray(tools)) {
  process.stderr.write('tools/list response missing result.tools\\n');
  process.exit(2);
}
const names = tools
  .map((t) => t?.name)
  .filter((name) => typeof name === 'string' && name.endsWith('__healthz'));
if (names.length === 0) {
  process.stderr.write('no __healthz tool found\\n');
  process.exit(3);
}
process.stdout.write(names.join('\\n'));
" "$1"
}

validate_call_result() {
  node -e "
const fs = require('node:fs');
const filePath = process.argv[1];
const raw = fs.readFileSync(filePath, 'utf8');
const payload = JSON.parse(raw);
if (payload?.error) {
  process.stderr.write('tools/call returned JSON-RPC error: ' + JSON.stringify(payload.error) + '\\n');
  process.exit(2);
}
const result = payload?.result;
if (!result) {
  process.stderr.write('tools/call missing result\\n');
  process.exit(3);
}
if (result.isError === true) {
  process.stderr.write('tools/call isError=true\\n');
  process.exit(4);
}
process.exit(0);
" "$1"
}

cd "$REPO_ROOT"
resolve_port

echo "[1/6] build docker image"
make docker-build >/dev/null

echo "[2/6] boot container"
CONTAINER_ID="$(docker run -d --rm \
  --name "$CONTAINER_NAME" \
  -p "$PORT:3001" \
  "$IMAGE" \
  --transport streamable-http \
  --spec-dir /app/dist/shell_as_mcp_defs \
  --host 0.0.0.0 \
  --port 3001 \
  --http-path "$HTTP_PATH")"

docker logs -f "$CONTAINER_ID" >"$SERVER_LOG" 2>&1 &
LOG_PID="$!"

wait_for_server_ready

echo "[3/6] initialize handshake"
INIT_STATUS="$(
  curl -sS -D "$INIT_HEADERS" -o "$INIT_BODY" -w "%{http_code}" -X POST "http://$HOST:$PORT$HTTP_PATH" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":801,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"$PROTOCOL_VERSION\",\"capabilities\":{},\"clientInfo\":{\"name\":\"docker-e2e-smoke\",\"version\":\"1.0.0\"}}}"
)"
assert_status_in "initialize" "$INIT_STATUS" "200"

SESSION_ID="$(extract_session_id "$INIT_HEADERS")"
if [[ -z "$SESSION_ID" ]]; then
  echo "ERROR: initialize response missing mcp-session-id" >&2
  cat "$INIT_HEADERS" >&2 || true
  exit 1
fi

echo "[4/6] notifications + tools/list"
NOTI_STATUS="$(
  curl -sS -D "$NOTI_HEADERS" -o "$NOTI_BODY" -w "%{http_code}" -X POST "http://$HOST:$PORT$HTTP_PATH" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "mcp-protocol-version: $PROTOCOL_VERSION" \
    -H "mcp-session-id: $SESSION_ID" \
    --data '{"jsonrpc":"2.0","method":"notifications/initialized"}'
)"
assert_status_in "notifications/initialized" "$NOTI_STATUS" "200,202,204"

LIST_STATUS="$(
  curl -sS -D "$LIST_HEADERS" -o "$LIST_BODY" -w "%{http_code}" -X POST "http://$HOST:$PORT$HTTP_PATH" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "mcp-protocol-version: $PROTOCOL_VERSION" \
    -H "mcp-session-id: $SESSION_ID" \
    --data '{"jsonrpc":"2.0","id":802,"method":"tools/list","params":{}}'
)"
assert_status_in "tools/list" "$LIST_STATUS" "200"

if ! grep -q '"result"' "$LIST_BODY" || ! grep -q '"tools"' "$LIST_BODY"; then
  echo "ERROR: tools/list response body missing result.tools" >&2
  cat "$LIST_BODY" >&2 || true
  exit 1
fi

extract_json_payload "$LIST_BODY" "$LIST_PAYLOAD"
echo "[5/6] tools/call shell__run_script_echo"
CALL_STATUS="$(
  curl -sS -D "$CALL_HEADERS" -o "$CALL_BODY" -w "%{http_code}" -X POST "http://$HOST:$PORT$HTTP_PATH" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "mcp-protocol-version: $PROTOCOL_VERSION" \
    -H "mcp-session-id: $SESSION_ID" \
    --data '{"jsonrpc":"2.0","id":803,"method":"tools/call","params":{"name":"shell__run_script_echo","arguments":{"value":"docker-e2e-smoke","mcp_response_mode":"structuredContent"}}}'
)"
assert_status_in "tools/call" "$CALL_STATUS" "200"

extract_json_payload "$CALL_BODY" "$CALL_PAYLOAD"
validate_call_result "$CALL_PAYLOAD"

CALLED_TOOL="shell__run_script_echo"

echo "[6/6] done"
echo "PASS docker-e2e-smoke"
echo "  image: $IMAGE"
echo "  host: $HOST"
echo "  port: $PORT"
echo "  session_id: $SESSION_ID"
echo "  called_tool: $CALLED_TOOL"
echo "artifacts:"
echo "  $WORK_DIR"

kill "$LOG_PID" >/dev/null 2>&1 || true
wait "$LOG_PID" >/dev/null 2>&1 || true
