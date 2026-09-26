#!/bin/bash
# Populates Sources/Aktar/Assets.xcassets/AppIcon.appiconset from a single
# master PNG (ideally 1024x1024, square, no transparency needed but fine
# either way).
#
# Usage: scripts/make_iconset.sh path/to/logo-1024.png
set -euo pipefail

SRC="${1:?Usage: scripts/make_iconset.sh path/to/logo-1024.png}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Sources/Aktar/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$SRC" ]; then
  echo "No such file: $SRC" >&2
  exit 1
fi

SIZES=(16 32 32 64 128 256 256 512 512 1024)
NAMES=(
  "icon_16x16.png"
  "icon_16x16@2x.png"
  "icon_32x32.png"
  "icon_32x32@2x.png"
  "icon_128x128.png"
  "icon_128x128@2x.png"
  "icon_256x256.png"
  "icon_256x256@2x.png"
  "icon_512x512.png"
  "icon_512x512@2x.png"
)

for i in "${!SIZES[@]}"; do
  size="${SIZES[$i]}"
  name="${NAMES[$i]}"
  sips -z "$size" "$size" "$SRC" --out "$DEST/$name" >/dev/null
  echo "wrote $name (${size}x${size})"
done

python3 - "$DEST" <<'PY'
import json, sys

dest = sys.argv[1]
mapping = [
    ("16x16", "1x", "icon_16x16.png"),
    ("16x16", "2x", "icon_16x16@2x.png"),
    ("32x32", "1x", "icon_32x32.png"),
    ("32x32", "2x", "icon_32x32@2x.png"),
    ("128x128", "1x", "icon_128x128.png"),
    ("128x128", "2x", "icon_128x128@2x.png"),
    ("256x256", "1x", "icon_256x256.png"),
    ("256x256", "2x", "icon_256x256@2x.png"),
    ("512x512", "1x", "icon_512x512.png"),
    ("512x512", "2x", "icon_512x512@2x.png"),
]
contents = {
    "images": [
        {"idiom": "mac", "size": size, "scale": scale, "filename": filename}
        for size, scale, filename in mapping
    ],
    "info": {"author": "xcode", "version": 1},
}
with open(f"{dest}/Contents.json", "w") as f:
    json.dump(contents, f, indent=2)
    f.write("\n")
PY

echo "Done. Run 'xcodegen generate' and rebuild to see the new icon."
