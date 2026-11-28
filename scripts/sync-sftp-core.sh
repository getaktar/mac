#!/bin/bash
# Copies the SFTP core from the desktop repo (getaktar/desktop,
# crates/sftp-core: the source of truth) into rust/sftp-core, so this repo
# builds on its own. With --check, only compares the two and fails when
# they differ (release.sh and CI-minded runs use that).
#
# The desktop repo is looked for next to this one (../windows, or
# ../desktop); set DESKTOP_REPO to point elsewhere. Build output and the
# core's own Cargo.lock aren't copied.
#
# Usage: scripts/sync-sftp-core.sh [--check]
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK=0
if [[ "${1:-}" == "--check" ]]; then
  CHECK=1
fi

DESKTOP="${DESKTOP_REPO:-}"
if [[ -z "$DESKTOP" ]]; then
  for candidate in ../windows ../desktop; do
    if [[ -d "$candidate/crates/sftp-core" ]]; then
      DESKTOP="$candidate"
      break
    fi
  done
fi
if [[ -z "$DESKTOP" || ! -d "$DESKTOP/crates/sftp-core" ]]; then
  echo "The desktop repo (with crates/sftp-core) isn't next to this one. Set DESKTOP_REPO." >&2
  exit 2
fi
SOURCE="$DESKTOP/crates/sftp-core"
TARGET="rust/sftp-core"
EXCLUDES=(--exclude target --exclude Cargo.lock --exclude .DS_Store)

if [[ "$CHECK" == 1 ]]; then
  if [[ ! -d "$TARGET" ]]; then
    echo "$TARGET is missing. Run scripts/sync-sftp-core.sh." >&2
    exit 1
  fi
  if ! diff -r -q "${EXCLUDES[@]/--exclude/-x}" "$SOURCE" "$TARGET"; then
    echo "$TARGET differs from $SOURCE. Run scripts/sync-sftp-core.sh (change the core in the desktop repo, not here)." >&2
    exit 1
  fi
  echo "$TARGET matches $SOURCE."
  exit 0
fi

mkdir -p "$TARGET"
rsync -a --delete "${EXCLUDES[@]}" "$SOURCE/" "$TARGET/"
echo "Copied $SOURCE to $TARGET."
