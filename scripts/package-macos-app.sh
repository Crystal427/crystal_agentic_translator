#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/dist}"
APP="$OUTPUT_DIR/CrystalTranslator.app"
ZIP="$OUTPUT_DIR/CrystalTranslator-macOS.zip"

cd "$ROOT"
swift build -c release --product CrystalTranslator
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/.build/release/CrystalTranslator" "$APP/Contents/MacOS/CrystalTranslator"
codesign --force --deep --sign - "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
printf 'Packaged app: %s\n' "$APP"
printf 'Packaged archive: %s\n' "$ZIP"
