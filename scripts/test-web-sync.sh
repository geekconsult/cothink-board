#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
workspace="$PWD"
default_web="$workspace/../cothink-board-web"
web="$(cd "${1:-$default_web}" && pwd)"
mac_version="$(cat VERSION)"
web_version="$(node -p 'require(process.argv[1]).version' "$web/package.json")"
if [[ "$mac_version" != "$web_version" ]]; then
  printf 'Release mismatch: macOS %s vs web %s\n' "$mac_version" "$web_version" >&2
  exit 1
fi
export COTHINK_TEST_VERSION="$web_version"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/cothink-sync.XXXXXX")"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  printf 'Smoke test logs and screenshots: %s\n' "$scratch"
}
trap cleanup EXIT
export COTHINK_TEST_EMAIL="sync-smoke@example.test"
export COTHINK_TEST_PASSWORD="$(openssl rand -hex 24)"
export COTHINK_TEST_WEB="$web"
export COTHINK_TEST_NODE="$(command -v node)"
export COTHINK_TEST_CHROME="$workspace/scripts/sync-smoke-browser.mjs"
export COTHINK_TEST_SCREENSHOT="$scratch/desktop.png"
export COTHINK_TEST_MOBILE="$scratch/mobile.png"
port="$(node -e 'const s=require("node:net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
export COTHINK_TEST_URL="http://127.0.0.1:$port"
(
  cd "$web"
  npm run build
  exec env COTHINK_WEB_HOME="$scratch/web-data" COTHINK_WEB_PORT="$port" COTHINK_WEB_HOST=127.0.0.1 \
    COTHINK_ADMIN_EMAIL="$COTHINK_TEST_EMAIL" COTHINK_ADMIN_PASSWORD="$COTHINK_TEST_PASSWORD" \
    COTHINK_OAUTH_ISSUER="$COTHINK_TEST_URL" COTHINK_LEGACY_OWNER_EMAIL="$COTHINK_TEST_EMAIL" node server/index.js
) > "$scratch/server.log" 2>&1 &
server_pid="$!"
for attempt in {1..60}; do
  if curl --fail --silent "$COTHINK_TEST_URL/healthz" >/dev/null; then break; fi
  if ! kill -0 "$server_pid" 2>/dev/null; then cat "$scratch/server.log"; exit 1; fi
  sleep 0.2
done
curl --fail --silent "$COTHINK_TEST_URL/healthz" >/dev/null
swift test --filter CloudWorkspaceIntegrationTests
