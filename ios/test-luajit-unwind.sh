#!/bin/bash
# Builds LuaJIT for the iOS simulator exactly as ios/build-luajit.sh builds it for the phone and runs ios/test-luajit-unwind.cpp in a
# booted simulator. Usage: test-luajit-unwind.sh <luajit2 source dir> <work dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$1"; WORK="$2"
"$HERE/build-luajit.sh" "$SRC" "$WORK/lj-sim" iphonesimulator 18.0
xcrun --sdk iphonesimulator clang++ -std=c++20 -arch arm64 -mios-simulator-version-min=18.0 -I"$WORK/lj-sim/include" \
    "$HERE/test-luajit-unwind.cpp" "$WORK/lj-sim/lib/libluajit-5.1.a" -o "$WORK/test-luajit-unwind"
codesign -f -s - "$WORK/test-luajit-unwind"
xcrun simctl list devices booted | grep -q Booted || { echo "no booted iOS simulator (boot one with: xcrun simctl boot <device>)" >&2; exit 2; }
xcrun simctl spawn booted "$WORK/test-luajit-unwind"
