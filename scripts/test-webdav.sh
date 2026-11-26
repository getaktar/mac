#!/bin/bash
# Runs the WebDAV integration tests (WebDAVIntegrationTests) against a
# throwaway `rclone serve webdav`: a fresh server on a free local port,
# under a /dav base path, serving a temporary folder with a user name and
# password, plus `rclone serve http` on the same folder without a password
# for the public links (with no directory cache, so it serves a file as
# soon as WebDAV wrote it). Both are stopped and the folder deleted afterwards.
#
# One-time setup: brew install rclone
#
# Usage: scripts/test-webdav.sh [--all] [extra xcodebuild arguments]
#   --all   run the whole AktarTests suite with the server up, not just the
#           WebDAV integration tests
set -euo pipefail
cd "$(dirname "$0")/.."

ONLY_TESTING=(-only-testing:AktarTests/WebDAVIntegrationTests)
if [[ "${1:-}" == "--all" ]]; then
  ONLY_TESTING=()
  shift
fi

RCLONE="${RCLONE:-$(command -v rclone || true)}"
if [[ -z "$RCLONE" ]]; then
  echo "rclone isn't installed. Install it with: brew install rclone" >&2
  exit 1
fi

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

DAV_PORT="$(free_port)"
HTTP_PORT="$(free_port)"
USER_NAME="aktar-test"
PASSWORD="aktar-test-$(uuidgen | tr -d - | head -c 16)"
DATA_DIR="$(mktemp -d -t aktar-webdav)"
CONFIG="$(mktemp -t aktar-rclone-conf)"
LOG="$(mktemp -t aktar-rclone-log)"

cleanup() {
  for pid in "${DAV_PID:-}" "${HTTP_PID:-}"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$DATA_DIR"
  rm -f "$CONFIG" "$LOG"
}
trap cleanup EXIT

# The destination's folder, one level under the server's root, so keys
# are told apart from the endpoint's own path.
mkdir -p "$DATA_DIR/aktar"

"$RCLONE" --config "$CONFIG" serve webdav "$DATA_DIR" --addr "127.0.0.1:$DAV_PORT" --baseurl /dav \
  --user "$USER_NAME" --pass "$PASSWORD" >"$LOG" 2>&1 &
DAV_PID=$!
"$RCLONE" --config "$CONFIG" serve http "$DATA_DIR" --addr "127.0.0.1:$HTTP_PORT" --dir-cache-time 0s >>"$LOG" 2>&1 &
HTTP_PID=$!

ENDPOINT="http://127.0.0.1:$DAV_PORT/dav/aktar"
PUBLIC="http://127.0.0.1:$HTTP_PORT/aktar"
for _ in $(seq 1 60); do
  if curl -fs -o /dev/null -u "$USER_NAME:$PASSWORD" -X PROPFIND -H 'Depth: 0' "$ENDPOINT/" \
    && curl -fs -o /dev/null "$PUBLIC/"; then
    break
  fi
  if ! kill -0 "$DAV_PID" 2>/dev/null || ! kill -0 "$HTTP_PID" 2>/dev/null; then
    echo "rclone didn't start:" >&2
    cat "$LOG" >&2
    exit 1
  fi
  sleep 0.5
done
curl -fs -o /dev/null -u "$USER_NAME:$PASSWORD" -X PROPFIND -H 'Depth: 0' "$ENDPOINT/" \
  || { echo "rclone didn't answer on $ENDPOINT" >&2; cat "$LOG" >&2; exit 1; }
echo "$("$RCLONE" version | head -1) on $ENDPOINT, public links on $PUBLIC"

# Picks up test files added since the project was last generated.
xcodegen generate --quiet

# xcodebuild hands TEST_RUNNER_ prefixed variables to the tests, without
# the prefix.
TEST_RUNNER_AKTAR_TEST_WEBDAV_ENDPOINT="$ENDPOINT" \
TEST_RUNNER_AKTAR_TEST_WEBDAV_USER="$USER_NAME" \
TEST_RUNNER_AKTAR_TEST_WEBDAV_PASSWORD="$PASSWORD" \
TEST_RUNNER_AKTAR_TEST_WEBDAV_PUBLIC_URL="$PUBLIC" \
TEST_RUNNER_AKTAR_TEST_WEBDAV_DIR="$DATA_DIR/aktar" \
  xcodebuild test \
    -project Aktar.xcodeproj \
    -scheme Aktar \
    -destination 'platform=macOS' \
    ${ONLY_TESTING[@]+"${ONLY_TESTING[@]}"} \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    "$@"
