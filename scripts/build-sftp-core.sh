#!/bin/bash
# Builds the SFTP core (rust/: sftp-core, the copy of getaktar/desktop's
# crates/sftp-core, and aktar-sftp-ffi, its UniFFI layer) for the app:
#
#   build/sftp-core/lib/libaktar_sftp_ffi.a      static library (lipo of the archs)
#   build/sftp-core/include/AktarSFTPFFI.h       C side of the bindings
#   build/sftp-core/include/module.modulemap     the AktarSFTPFFI module
#   build/sftp-core/swift/AktarSFTP.swift        Swift side, compiled into the app
#
# Xcode runs this before each build (the SFTPCore target in project.yml)
# with ARCHS set: arm64 alone for a Debug build on Apple silicon, arm64 and
# x86_64 for a Release archive. It does nothing when the Rust sources,
# Cargo.lock and this script are as they were last time and the library
# already has the archs asked for.
# Always a release build of the Rust code (rust/Cargo.toml's profile): it's
# small, and SSH crypto is slow unoptimized.
#
# One-time setup: rustup (https://rustup.rs), then
#   rustup target add aarch64-apple-darwin x86_64-apple-darwin
#
# Options:
#   --archs "arm64 x86_64"  which Mac archs (default: $ARCHS, else both)
#   --xcframework           also build/sftp-core/AktarSFTP.xcframework
#   --ios                   with --xcframework: add iOS (aarch64-apple-ios)
#                           and Simulator (aarch64-apple-ios-sim,
#                           x86_64-apple-ios) slices, built for iOS
#                           $IPHONEOS_DEPLOYMENT_TARGET (default 16.4);
#                           needs those rustup targets
#   --force                 build even when nothing changed
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

MAC_ARCHS="${ARCHS:-arm64 x86_64}"
XCFRAMEWORK=0
IOS=0
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archs) MAC_ARCHS="$2"; shift 2 ;;
    --xcframework) XCFRAMEWORK=1; shift ;;
    --ios) IOS=1; shift ;;
    --force) FORCE=1; shift ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
done

OUT="$ROOT/build/sftp-core"
RUST="$ROOT/rust"
TARGET_DIR="$RUST/target"
LIB_NAME="libaktar_sftp_ffi.a"

# The app's deployment target (project.yml), unless Xcode set it.
setting() { grep -E "^ *$1: " "$ROOT/project.yml" | head -1 | sed 's/.*: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/'; }
MACOS_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$(setting MACOSX_DEPLOYMENT_TARGET)}"
MACOS_TARGET="${MACOS_TARGET:-14.0}"
IOS_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.4}"

# Xcode's script environment has no ~/.cargo/bin in PATH.
SEARCH_PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
CARGO="$(PATH="$SEARCH_PATH" command -v cargo || true)"
if [[ -z "$CARGO" ]]; then
  echo "error: cargo isn't installed. Install Rust with rustup (https://rustup.rs), then: rustup target add aarch64-apple-darwin x86_64-apple-darwin" >&2
  exit 1
fi
CARGO_BIN="$(dirname "$CARGO")"

rust_target() {
  case "$1" in
    arm64) echo aarch64-apple-darwin ;;
    x86_64) echo x86_64-apple-darwin ;;
    *) echo "error: no Rust target for the arch $1" >&2; exit 1 ;;
  esac
}

# Everything that decides the output, but the archs: a library that has
# every arch asked for (a universal one, for an arm64 Debug build) will do.
fingerprint() {
  {
    echo "macos=$MACOS_TARGET xcframework=$XCFRAMEWORK ios=$IOS ios-target=$IOS_TARGET"
    shasum < "$0"
    (cd "$RUST" && find . -path ./target -prune -o -type f ! -name .DS_Store -print | LC_ALL=C sort | xargs shasum)
  } | shasum | cut -d' ' -f1
}
STAMP="$OUT/.stamp"
CURRENT="$(fingerprint)"
has_archs() {
  local built
  built=" $(lipo -archs "$OUT/lib/$LIB_NAME" 2>/dev/null) "
  for arch in $MAC_ARCHS; do
    [[ "$built" == *" $arch "* ]] || return 1
  done
}
if [[ "$FORCE" == 0 && -f "$STAMP" && "$(cat "$STAMP")" == "$CURRENT" && -f "$OUT/swift/AktarSFTP.swift" ]] && has_archs; then
  echo "SFTP core is up to date."
  exit 0
fi

# Cargo runs in a clean environment: Xcode's build settings (SDKROOT,
# compiler flags for the app's own targets) must not leak into the Rust
# build scripts. Paths in panic messages say /build, not the home folder.
cargo_build() {
  local target="$1"; shift
  env -i HOME="$HOME" PATH="$CARGO_BIN:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" \
    MACOSX_DEPLOYMENT_TARGET="$MACOS_TARGET" IPHONEOS_DEPLOYMENT_TARGET="$IOS_TARGET" \
    RUSTFLAGS="--remap-path-prefix=$HOME=/build" \
    CARGO_TARGET_DIR="$TARGET_DIR" \
    "$CARGO" build --manifest-path "$RUST/Cargo.toml" -p aktar-sftp-ffi --release --locked --target "$target" "$@"
}

copy_if_changed() {
  mkdir -p "$(dirname "$2")"
  if ! cmp -s "$1" "$2"; then
    cp "$1" "$2"
  fi
}

echo "Building the SFTP core for $MAC_ARCHS (macOS $MACOS_TARGET)"
MAC_LIBS=()
for arch in $MAC_ARCHS; do
  target="$(rust_target "$arch")"
  cargo_build "$target"
  MAC_LIBS+=("$TARGET_DIR/$target/release/$LIB_NAME")
done

STAGE="$OUT/.stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/lib" "$STAGE/include" "$STAGE/swift" "$STAGE/bindings"
lipo -create "${MAC_LIBS[@]}" -output "$STAGE/lib/$LIB_NAME"

echo "Generating the Swift bindings"
(cd "$RUST" && env -i HOME="$HOME" PATH="$CARGO_BIN:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" CARGO_TARGET_DIR="$TARGET_DIR" \
  "$CARGO" run --quiet --locked -p uniffi-bindgen -- generate --library "${MAC_LIBS[0]}" --language swift --out-dir "$STAGE/bindings")
cp "$STAGE/bindings/AktarSFTPFFI.h" "$STAGE/include/AktarSFTPFFI.h"
cp "$STAGE/bindings/AktarSFTPFFI.modulemap" "$STAGE/include/module.modulemap"
cp "$STAGE/bindings/aktar_sftp_ffi.swift" "$STAGE/swift/AktarSFTP.swift"

copy_if_changed "$STAGE/lib/$LIB_NAME" "$OUT/lib/$LIB_NAME"
copy_if_changed "$STAGE/include/AktarSFTPFFI.h" "$OUT/include/AktarSFTPFFI.h"
copy_if_changed "$STAGE/include/module.modulemap" "$OUT/include/module.modulemap"
copy_if_changed "$STAGE/swift/AktarSFTP.swift" "$OUT/swift/AktarSFTP.swift"

if [[ "$XCFRAMEWORK" == 1 ]]; then
  echo "Making AktarSFTP.xcframework"
  ARGS=(-library "$OUT/lib/$LIB_NAME" -headers "$OUT/include")
  if [[ "$IOS" == 1 ]]; then
    cargo_build aarch64-apple-ios
    cargo_build aarch64-apple-ios-sim
    cargo_build x86_64-apple-ios
    mkdir -p "$STAGE/ios-sim"
    lipo -create "$TARGET_DIR/aarch64-apple-ios-sim/release/$LIB_NAME" "$TARGET_DIR/x86_64-apple-ios/release/$LIB_NAME" -output "$STAGE/ios-sim/$LIB_NAME"
    ARGS+=(-library "$TARGET_DIR/aarch64-apple-ios/release/$LIB_NAME" -headers "$OUT/include")
    ARGS+=(-library "$STAGE/ios-sim/$LIB_NAME" -headers "$OUT/include")
  fi
  rm -rf "$OUT/AktarSFTP.xcframework"
  xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT/AktarSFTP.xcframework" >/dev/null
fi

rm -rf "$STAGE"
echo "$CURRENT" > "$STAMP"
echo "SFTP core built: $(du -h "$OUT/lib/$LIB_NAME" | cut -f1) static library in $OUT"
