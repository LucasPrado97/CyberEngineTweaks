#!/bin/bash
# Builds the openresty LuaJIT as a static arm64 library for iOS: interpreter only. iOS forbids generating code at run time, so the JIT
# compiler is left out twice over (TARGET_SYS=iOS sets LJ_OS_NOJIT in lj_arch.h, and -DLUAJIT_DISABLE_JIT says so explicitly); the FFI
# stays (64-bit integers are FFI cdata), Lua 5.2 compatibility as in the Windows and macOS builds.
#
# One line of lj_arch.h is changed in the build's own copy of the source (the checkout is not touched): LuaJIT turns frame unwinding off
# for every iOS target (LJ_NO_UNWIND, from the 32-bit ARM days), which makes a C++ exception thrown through a Lua frame end the
# process. CET is built so that exceptions do cross Lua frames (SOL_EXCEPTIONS_SAFE_PROPAGATION), the way they do on macOS, where LuaJIT
# uses the system unwinder (LUAJIT_UNWIND_EXTERNAL). arm64 iOS has the same unwinder and the same Mach-O unwind tables as arm64 macOS,
# so the iOS library is built in the macOS mode. ios/test-luajit-unwind.sh checks it on the iOS simulator.
#
# Usage: build-luajit.sh <luajit2 source dir> <output dir> [sdk=iphoneos] [min version=18.0]
set -euo pipefail
SRC="$1"; OUT="$2"; SDK="${3:-iphoneos}"; MIN="${4:-18.0}"
[[ -f "$SRC/src/luajit.h" || -f "$SRC/src/luajit_rolling.h" ]] || { echo "build-luajit.sh: $SRC is not a LuaJIT checkout" >&2; exit 1; }
STAMP="$OUT/.built-$SDK-$MIN-$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo src)"
if [[ -f "$STAMP" && -f "$OUT/lib/libluajit-5.1.a" ]]; then exit 0; fi
rm -rf "$OUT/work" && mkdir -p "$OUT/work" "$OUT/lib" "$OUT/include"
cp -R "$SRC/." "$OUT/work/"

ARCH_H="$OUT/work/src/lj_arch.h"
grep -q '__GNU_COMPACT_EH__ || defined(__symbian__) || LJ_TARGET_IOS || LJ_TARGET_PS3' "$ARCH_H" || { echo "build-luajit.sh: the LJ_NO_UNWIND line of lj_arch.h is not the expected one" >&2; exit 1; }
sed -i '' 's/__GNU_COMPACT_EH__ || defined(__symbian__) || LJ_TARGET_IOS || LJ_TARGET_PS3/__GNU_COMPACT_EH__ || defined(__symbian__) || LJ_TARGET_PS3/' "$ARCH_H"

ISDKP="$(xcrun --sdk "$SDK" --show-sdk-path)"
ICC="$(xcrun --sdk "$SDK" --find clang)"
if [[ "$SDK" == iphonesimulator* ]]; then MINFLAG="-mios-simulator-version-min=$MIN"; else MINFLAG="-miphoneos-version-min=$MIN"; fi
# The host tools (minilua, buildvm) are built for this Mac with the same XCFLAGS, so the generated VM matches the target options.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
make -C "$OUT/work" -j8 amalg BUILDMODE=static DEFAULT_CC=clang CROSS="$(dirname "$ICC")/" TARGET_SYS=iOS \
    TARGET_FLAGS="-arch arm64 -isysroot $ISDKP $MINFLAG" \
    XCFLAGS="-DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_DISABLE_JIT -DLUAJIT_UNWIND_EXTERNAL" >"$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log" >&2; exit 1; }
cp "$OUT/work/src/libluajit.a" "$OUT/lib/libluajit-5.1.a"
for h in lua.h lualib.h lauxlib.h luaconf.h lua.hpp luajit.h; do cp "$OUT/work/src/$h" "$OUT/include/"; done

# No JIT compiler in the library: its machine-code allocator (lj_mcode.c) and trace recorder must be absent.
if nm "$OUT/lib/libluajit-5.1.a" 2>/dev/null | grep -qE ' [Tt] _(lj_mcode_alloc|lj_trace_ins|lj_record_ins|lj_asm_trace)'; then
  echo "build-luajit.sh: the library contains JIT compiler code" >&2; exit 1
fi
rm -f "$OUT"/.built-* && touch "$STAMP"
echo "LuaJIT (interpreter only) built for $SDK: $OUT/lib/libluajit-5.1.a"
