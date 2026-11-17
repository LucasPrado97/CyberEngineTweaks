#!/bin/bash
# Stages the folder to copy over the game folder on the phone (Documents/Cyberpunk 2077): the signed plugin, CET's Lua scripts, an
# empty mods folder and the CyPortHello test mod. Writes nothing outside this checkout and copies nothing to a device.
# Usage: ios/stage-deploy.sh [build dir=build-ios] [codesign identity]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; CET="$(dirname "$HERE")"
BUILD="${1:-$CET/build-ios}"; IDENTITY="${2:-9921DA56B69BB846944ECD1FAB6CCAC526172D37}"
DYLIB="$BUILD/cyber_engine_tweaks.dylib"
[[ -f "$DYLIB" ]] || { echo "stage-deploy.sh: $DYLIB not built" >&2; exit 1; }
ROOT="$CET/deploy/Cyberpunk 2077"
PLUGIN="$ROOT/red4ext/plugins/cyber_engine_tweaks"
DATA="$ROOT/bin/x64/plugins/cyber_engine_tweaks"
rm -rf "$CET/deploy" && mkdir -p "$PLUGIN" "$DATA/mods" "$DATA/scripts"
cp "$DYLIB" "$PLUGIN/cyber_engine_tweaks.dylib"
codesign -f -s "$IDENTITY" "$PLUGIN/cyber_engine_tweaks.dylib"
codesign -v "$PLUGIN/cyber_engine_tweaks.dylib"
# json and IconGlyphs: required, the Lua VM does not start without them.
cp -R "$CET/scripts/json" "$CET/scripts/IconGlyphs" "$DATA/scripts/"
cp -R "$HERE/mods/CyPortHello" "$DATA/mods/"
(cd "$ROOT" && find . -type f | sort)
