#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_PORT="3910"
PORT="${REGRESS_PACK_SMOKE_PORT:-}"
HOST="127.0.0.1"
HTTP_PATH="/mcp"
PROTOCOL_VERSION="2025-03-26"

WORK_DIR="$(mktemp -d /tmp/regress_pack_smoke_XXXXXX)"
SERVER_LOG="$WORK_DIR/server.log"
INIT_HEADERS="$WORK_DIR/init.headers"
INIT_BODY="$WORK_DIR/init.body"
NOTI_HEADERS="$WORK_DIR/noti.headers"
NOTI_BODY="$WORK_DIR/noti.body"
LIST_HEADERS="$WORK_DIR/list.headers"
LIST_BODY="$WORK_DIR/list.body"
SERVER_PID=""
PACK_TGZ=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$PACK_TGZ" && "${REGRESS_PACK_SMOKE_KEEP_TGZ:-0}" != "1" ]]; then
    rm -f "$REPO_ROOT/$PACK_TGZ"
  fi

  if [[ "${REGRESS_PACK_SMOKE_KEEP_WORKDIR:-0}" == "1" ]]; then
    echo "INFO: keep work dir: $WORK_DIR"
  else
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

assert_status_in() {
  local name="$1"
  local actual="$2"
  local allowed="$3"

  case ",$allowed," in
    *",$actual,"*) ;;
    *)
      echo "ERROR: $name expected status in [$allowed], got $actual" >&2
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

wait_for_server_ready() {
  local i
  for i in $(seq 1 40); do
    if grep -q "streamable-http at http://$HOST:$PORT$HTTP_PATH" "$SERVER_LOG"; then
      return 0
    fi
    sleep 0.25
  done

  echo "ERROR: streamable-http server not ready in time" >&2
  cat "$SERVER_LOG" >&2 || true
  exit 1
}

resolve_port() {
  if [[ -n "$PORT" ]]; then
    return 0
  fi

  if node -e "const n=require('net');const s=n.createServer();s.once('error',()=>process.exit(1));s.once('listening',()=>s.close(()=>process.exit(0)));s.listen($DEFAULT_PORT,'127.0.0.1');" >/dev/null 2>&1; then
    PORT="$DEFAULT_PORT"
    return 0
  fi

  PORT="$(node -e "const n=require('net');const s=n.createServer();s.listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close();});")"
}

cd "$REPO_ROOT"
resolve_port

echo "[1/5] build"
make build >/dev/null

echo "[2/5] pack"
PACK_TGZ="$(npm pack | tail -n 1)"
if [[ ! -f "$REPO_ROOT/$PACK_TGZ" ]]; then
  echo "ERROR: npm pack output not found: $PACK_TGZ" >&2
  exit 1
fi

echo "[3/5] boot package server"
npx -y "./$PACK_TGZ" --transport streamable-http --host "$HOST" --port "$PORT" --http-path "$HTTP_PATH" >"$SERVER_LOG" 2>&1 &
SERVER_PID="$!"
wait_for_server_ready

echo "[4/5] strict handshake"
INIT_STATUS="$(
  curl -sS -D "$INIT_HEADERS" -o "$INIT_BODY" -w "%{http_code}" -X POST "http://$HOST:$PORT$HTTP_PATH" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    --data '{"jsonrpc":"2.0","id":501,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"regress-pack-smoke","version":"1.0.0"}}}'
)"
assert_status_in "initialize" "$INIT_STATUS" "200"

SESSION_ID="$(extract_session_id "$INIT_HEADERS")"
if [[ -z "$SESSION_ID" ]]; then
  echo "ERROR: initialize response missing mcp-session-id" >&2
  echo "--- init headers ---" >&2
  cat "$INIT_HEADERS" >&2
  exit 1
fi

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
    --data '{"jsonrpc":"2.0","id":502,"method":"tools/list","params":{}}'
)"
assert_status_in "tools/list" "$LIST_STATUS" "200"

if ! grep -q '"result"' "$LIST_BODY" || ! grep -q '"tools"' "$LIST_BODY"; then
  echo "ERROR: tools/list response body missing result.tools" >&2
  echo "--- list body ---" >&2
  cat "$LIST_BODY" >&2
  exit 1
fi

echo "[5/5] done"
echo "PASS regress-pack-smoke"
echo "  package: $PACK_TGZ"
echo "  init_status: $INIT_STATUS"
echo "  noti_status: $NOTI_STATUS"
echo "  list_status: $LIST_STATUS"

echo "artifacts:"
echo "  $INIT_HEADERS"
echo "  $INIT_BODY"
echo "  $NOTI_HEADERS"
echo "  $NOTI_BODY"
echo "  $LIST_HEADERS"
echo "  $LIST_BODY"
echo "  $SERVER_LOG"
