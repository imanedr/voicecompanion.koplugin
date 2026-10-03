#!/bin/sh
# Build dist/voicecompanion.koplugin.zip with a top-level voicecompanion.koplugin/ folder.
set -eu

cd "$(dirname "$0")/.."
NAME=voicecompanion.koplugin
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/$NAME" dist
for f in _meta.lua main.lua configuration.sample.lua LICENSE README.md; do
    if [ -e "$f" ]; then
        cp "$f" "$STAGE/$NAME/"
    else
        echo "warning: $f not found, skipping" >&2
    fi
done
cp -r voicecompanion "$STAGE/$NAME/"

rm -f "dist/$NAME.zip"
OUT="$PWD/dist/$NAME.zip"
if command -v zip >/dev/null 2>&1; then
    (cd "$STAGE" && zip -qr "$OUT" "$NAME")
else
    python3 - "$STAGE" "$NAME" "$OUT" <<'PY'
import os, sys, zipfile
stage, name, out = sys.argv[1:4]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(os.path.join(stage, name)):
        for f in sorted(files):
            full = os.path.join(root, f)
            z.write(full, os.path.relpath(full, stage))
PY
fi
echo "Built dist/$NAME.zip"
