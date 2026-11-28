#!/bin/bash
# Runs the SFTP integration tests (SFTPIntegrationTests) against a
# throwaway `rclone serve sftp`: a fresh server on a free local port with a
# host key made here, signing in with a user name and password or with any
# of the client keys made here (ed25519, an encrypted ed25519, RSA in
# OpenSSH format and RSA in old PEM format, all in an authorized_keys
# file). A second server on the same folder with another host key is the
# "identity changed" case, and `rclone serve http` serves the folder for
# the public links. Everything is stopped and deleted afterwards.
#
# One-time setup: brew install rclone
#
# With --openssh, macOS's own OpenSSH server (/usr/sbin/sshd, run as you on
# a local port, keys only: a non-root sshd can't check passwords) serves
# the folder instead, with /usr/libexec/sftp-server.
#
# Usage: scripts/test-sftp.sh [--openssh] [--all] [extra xcodebuild arguments]
#   --openssh  test against OpenSSH instead of rclone
#   --all      run the whole AktarTests suite with the server up, not just
#              the SFTP integration tests
set -euo pipefail
cd "$(dirname "$0")/.."

SERVER=rclone
if [[ "${1:-}" == "--openssh" ]]; then
  SERVER=openssh
  shift
fi
ONLY_TESTING=(-only-testing:AktarTests/SFTPIntegrationTests)
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

SFTP_PORT="$(free_port)"
OTHER_PORT="$(free_port)"
HTTP_PORT="$(free_port)"
USER_NAME="aktar-test"
PASSWORD="aktar-test-$(uuidgen | tr -d - | head -c 16)"
PASSPHRASE="aktar-phrase-$(uuidgen | tr -d - | head -c 8)"
DATA_DIR="$(mktemp -d -t aktar-sftp)"
KEYS="$(mktemp -d -t aktar-sftp-keys)"
CONFIG="$(mktemp -t aktar-rclone-conf)"
LOG="$(mktemp -t aktar-rclone-log)"

cleanup() {
  for pid in "${SFTP_PID:-}" "${OTHER_PID:-}" "${HTTP_PID:-}"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$DATA_DIR" "$KEYS"
  rm -f "$CONFIG" "$LOG"
}
trap cleanup EXIT

# Host keys: the server's, and another one for the changed-identity case.
ssh-keygen -q -t ed25519 -N "" -C aktar-host -f "$KEYS/host"
ssh-keygen -q -t ed25519 -N "" -C aktar-other-host -f "$KEYS/other-host"
# Client keys.
ssh-keygen -q -t ed25519 -N "" -C aktar-ed25519 -f "$KEYS/id_ed25519"
ssh-keygen -q -t ed25519 -N "$PASSPHRASE" -C aktar-ed25519-encrypted -f "$KEYS/id_ed25519_encrypted"
ssh-keygen -q -t rsa -b 3072 -N "" -C aktar-rsa -f "$KEYS/id_rsa"
ssh-keygen -q -t rsa -b 3072 -N "$PASSPHRASE" -C aktar-rsa-encrypted -f "$KEYS/id_rsa_encrypted"
ssh-keygen -q -t rsa -b 2048 -m PEM -N "" -C aktar-rsa-pem -f "$KEYS/id_rsa_pem"
cat "$KEYS"/id_ed25519.pub "$KEYS"/id_ed25519_encrypted.pub "$KEYS"/id_rsa.pub "$KEYS"/id_rsa_encrypted.pub "$KEYS"/id_rsa_pem.pub > "$KEYS/authorized_keys"

# The destination's folder, one level under the login folder (rclone) or
# under the data folder by its full path (OpenSSH, whose login folder is
# your home).
mkdir -p "$DATA_DIR/aktar"
ROOT="aktar"

serve_openssh() {
  local config="$KEYS/sshd_config_$1"
  cat > "$config" <<CONFIG
Port $1
ListenAddress 127.0.0.1
HostKey $2
PidFile $KEYS/sshd_$1.pid
AuthorizedKeysFile $KEYS/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
Subsystem sftp /usr/libexec/sftp-server
CONFIG
  /usr/sbin/sshd -D -f "$config" -E "$LOG" &
}

serve() {
  "$RCLONE" --config "$CONFIG" serve sftp "$DATA_DIR" --addr "127.0.0.1:$1" --key "$2" \
    --user "$USER_NAME" --pass "$PASSWORD" --authorized-keys "$KEYS/authorized_keys" --dir-cache-time 100ms >>"$LOG" 2>&1 &
}
if [[ "$SERVER" == openssh ]]; then
  USER_NAME="$(whoami)"
  PASSWORD=""
  ROOT="$(cd "$DATA_DIR" && pwd -P)/aktar"
  chmod 600 "$KEYS/authorized_keys"
  serve_openssh "$SFTP_PORT" "$KEYS/host"
  SFTP_PID=$!
  serve_openssh "$OTHER_PORT" "$KEYS/other-host"
  OTHER_PID=$!
else
  serve "$SFTP_PORT" "$KEYS/host"
  SFTP_PID=$!
  serve "$OTHER_PORT" "$KEYS/other-host"
  OTHER_PID=$!
fi
"$RCLONE" --config "$CONFIG" serve http "$DATA_DIR" --addr "127.0.0.1:$HTTP_PORT" --dir-cache-time 0s >>"$LOG" 2>&1 &
HTTP_PID=$!

PUBLIC="http://127.0.0.1:$HTTP_PORT/aktar"
listening() {
  python3 -c 'import socket, sys; s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1); s.close()' "$1" 2>/dev/null
}
for _ in $(seq 1 60); do
  if listening "$SFTP_PORT" && listening "$OTHER_PORT" && curl -fs -o /dev/null "$PUBLIC/"; then
    break
  fi
  for pid in "$SFTP_PID" "$OTHER_PID" "$HTTP_PID"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "The servers didn't start:" >&2
      cat "$LOG" >&2
      exit 1
    fi
  done
  sleep 0.5
done
listening "$SFTP_PORT" || { echo "Nothing answered on 127.0.0.1:$SFTP_PORT" >&2; cat "$LOG" >&2; exit 1; }
if [[ "$SERVER" == openssh ]]; then
  echo "$(/usr/sbin/sshd -V 2>&1 | head -1) on 127.0.0.1:$SFTP_PORT (other host key on $OTHER_PORT), public links on $PUBLIC"
else
  echo "$("$RCLONE" version | head -1) on 127.0.0.1:$SFTP_PORT (other host key on $OTHER_PORT), public links on $PUBLIC"
fi

# Picks up test files added since the project was last generated.
xcodegen generate --quiet

# xcodebuild hands TEST_RUNNER_ prefixed variables to the tests, without
# the prefix.
TEST_RUNNER_AKTAR_TEST_SFTP_ENDPOINT="127.0.0.1:$SFTP_PORT" \
TEST_RUNNER_AKTAR_TEST_SFTP_OTHER_ENDPOINT="127.0.0.1:$OTHER_PORT" \
TEST_RUNNER_AKTAR_TEST_SFTP_USER="$USER_NAME" \
TEST_RUNNER_AKTAR_TEST_SFTP_ROOT="$ROOT" \
TEST_RUNNER_AKTAR_TEST_SFTP_PASSWORD="$PASSWORD" \
TEST_RUNNER_AKTAR_TEST_SFTP_KEYS="$KEYS" \
TEST_RUNNER_AKTAR_TEST_SFTP_PASSPHRASE="$PASSPHRASE" \
TEST_RUNNER_AKTAR_TEST_SFTP_HOST_FINGERPRINT="$(ssh-keygen -l -E sha256 -f "$KEYS/host.pub" | awk '{print $2}')" \
TEST_RUNNER_AKTAR_TEST_SFTP_PUBLIC_URL="$PUBLIC" \
TEST_RUNNER_AKTAR_TEST_SFTP_DIR="$DATA_DIR/aktar" \
  xcodebuild test \
    -project Aktar.xcodeproj \
    -scheme Aktar \
    -destination 'platform=macOS' \
    ${ONLY_TESTING[@]+"${ONLY_TESTING[@]}"} \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    "$@"
