#!/bin/bash
# Runs the S3 integration tests (S3IntegrationTests) against a throwaway
# MinIO: a fresh server on a free local port with its data on a RAM disk,
# stopped and detached afterwards. The tests create and delete their
# own buckets.
#
# One-time setup: brew install minio
#   (MinIO no longer publishes binaries itself; Homebrew builds it from source.)
#
# Usage: scripts/test-integration.sh [--all] [extra xcodebuild arguments]
#   --all   run the whole AktarTests suite with MinIO up, not just the
#           integration tests
set -euo pipefail
cd "$(dirname "$0")/.."

ONLY_TESTING=(-only-testing:AktarTests/S3IntegrationTests)
if [[ "${1:-}" == "--all" ]]; then
  ONLY_TESTING=()
  shift
fi

MINIO="${MINIO:-$(command -v minio || true)}"
if [[ -z "$MINIO" ]]; then
  echo "minio isn't installed. Install it with: brew install minio" >&2
  exit 1
fi

PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
CONSOLE_PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
ENDPOINT="http://127.0.0.1:$PORT"
ACCESS_KEY="aktar-test"
SECRET_KEY="aktar-test-$(uuidgen | tr -d - | head -c 16)"
LOG="$(mktemp -t aktar-minio-log)"

cleanup() {
  if [[ -n "${MINIO_PID:-}" ]]; then
    kill "$MINIO_PID" 2>/dev/null || true
    wait "$MINIO_PID" 2>/dev/null || true
  fi
  if [[ -n "${RAM_DISK:-}" ]]; then
    hdiutil detach -force "$RAM_DISK" >/dev/null 2>&1 || true
  fi
  rm -f "$LOG"
}
trap cleanup EXIT

# MinIO's data lives on a 2 GB RAM disk, detached afterwards: nothing is
# left on the Mac's drive, and MinIO refuses writes when its drive is
# nearly full, which would otherwise depend on how full the Mac is.
RAM_DISK="$(hdiutil attach -nomount ram://$((2 * 1024 * 2048)) | awk '{print $1}')"
VOLUME="AktarMinIO-$$"
# APFS keeps names as written; HFS+ would hand keys back in another
# Unicode normalization (NFD) than they were uploaded with.
diskutil erasevolume APFS "$VOLUME" "$RAM_DISK" >/dev/null
DATA_DIR="/Volumes/$VOLUME/data"
mkdir -p "$DATA_DIR"

MINIO_ROOT_USER="$ACCESS_KEY" MINIO_ROOT_PASSWORD="$SECRET_KEY" MINIO_BROWSER=off \
  "$MINIO" server --quiet --address "127.0.0.1:$PORT" --console-address "127.0.0.1:$CONSOLE_PORT" "$DATA_DIR" >"$LOG" 2>&1 &
MINIO_PID=$!

for _ in $(seq 1 60); do
  if curl -fs "$ENDPOINT/minio/health/live" >/dev/null; then break; fi
  if ! kill -0 "$MINIO_PID" 2>/dev/null; then
    echo "MinIO didn't start:" >&2
    cat "$LOG" >&2
    exit 1
  fi
  sleep 0.5
done
curl -fs "$ENDPOINT/minio/health/live" >/dev/null || { echo "MinIO didn't answer on $ENDPOINT" >&2; cat "$LOG" >&2; exit 1; }
echo "MinIO $("$MINIO" --version | head -1 | awk '{print $3}') on $ENDPOINT"

# Picks up test files added since the project was last generated.
xcodegen generate --quiet

# xcodebuild hands TEST_RUNNER_ prefixed variables to the tests, without
# the prefix.
TEST_RUNNER_AKTAR_TEST_S3_ENDPOINT="$ENDPOINT" \
TEST_RUNNER_AKTAR_TEST_S3_ACCESS_KEY="$ACCESS_KEY" \
TEST_RUNNER_AKTAR_TEST_S3_SECRET_KEY="$SECRET_KEY" \
  xcodebuild test \
    -project Aktar.xcodeproj \
    -scheme Aktar \
    -destination 'platform=macOS' \
    ${ONLY_TESTING[@]+"${ONLY_TESTING[@]}"} \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    "$@"
