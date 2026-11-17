# Cyber Engine Tweaks on iOS (CyPort), stage A: headless

The Lua runtime and scripting API of Cyber Engine Tweaks for Cyberpunk 2077 2.5.0 (Steam Mac build, UUID
`7D7382D0-EADD-36F0-BA1C-CEBEC1D5BEBC`) running on an iPhone through CyPort, as a RED4ext plugin. No overlay: no ImGui, no console
window, no renderer. Based on the macOS port in `../macos` (codeman101, branch `mac-next`); everything iOS-specific is behind `CET_IOS`
and `CET_HEADLESS`, and the macOS and Windows builds are unchanged.

Nothing here has run on a phone yet.

## What works without the overlay

`registerForEvent` (`onHook`, `onTweak`, `onInit`, `onUpdate`, `onShutdown`), `Observe` / `ObserveAfter` / `Override`, `Game.*`,
`GetSingleton`, `NewObject`, `TweakDB`, `CName`, `TweakDBID`, `json`, `require` / `dofile` / `loadfile` / `io` / `dir` inside the mod's
folder, `db` (SQLite), `spdlog`, `registerHotkey` / `registerInput` (see Input).

`onDraw`, `onOverlayOpen` and `onOverlayClose` never fire. `ImGui`, the `ImGui*` enums, `ImVec2` and `ImVec4` exist as inert stand-ins
(every `ImGui.x` is a function that does nothing, every enum member is 0), so a mod that names them while it loads still loads.

## Differences from the macOS build

| area | macOS | iOS |
|---|---|---|
| overlay, ImGui, Metal, AppKit window | compiled in | not compiled (`src/headless/` stands in for `D3D12`, `Window`, `Overlay`, `Bindings`) |
| LuaJIT | with the JIT compiler | interpreter only (`build-luajit.sh`: `TARGET_SYS=iOS`, `-DLUAJIT_DISABLE_JIT`); the `jit` library is not opened |
| hooks | RED4ext hooking, any allowlisted address | RED4ext hooking onto CyPort's baked sites (`CyPort-hooks/tools/sites/cet.txt`); an address that is not baked fails and only its feature is off |
| game-state ticks | four `OnTick` hooks | RED4ext game-state callbacks (`GameMainThread`, `src/scripting/GameHooks.cpp`) |
| hooks shared with ArchiveXL / Codeware | queued, chained at the first tick | attached at once (a baked site takes several detours) |
| data folder | `red4ext/plugins/cyber_engine_tweaks/` | `bin/x64/plugins/cyber_engine_tweaks/` (the Windows layout, so Nexus archives unpack unchanged); the dylib stays in `red4ext/plugins/cyber_engine_tweaks/` |
| working folder | changed to the mod's folder around file access | never changed (it is the game folder and the game relies on it); mod paths are absolute |
| file names | case-insensitive volume | case-sensitive: mod paths are resolved through the shim's `MSResolvePathCase`; `\` in a mod path is read as `/` |
| game folder | from the executable path | from the shim's `MSGameExecutablePath` |
| input | `NSEvent` local monitor (AppKit) | the same monitor on the shim's `NSEvent` stand-in, found by name (`src/headless/InputIOS.mm`); events are never kept from the game |

No code is written at run time: there are no byte patches, `Override` uses the stub pool assembled into the dylib
(`../macos/OverrideThunks.S`) and a copied vtable on the heap, and LuaJIT has no machine-code allocator.

## Input

Mod hotkeys work from a hardware keyboard or mouse (and touches the shim turns into mouse buttons). There is no Bindings window, so a
bind is set in `bin/x64/plugins/cyber_engine_tweaks/bindings.json`: start the game once with the mod installed (CET writes the mod's
ids with the value 0), then set the value to the key combination's code (up to four 16-bit Windows virtual-key codes, first key in
the highest 16 bits: F5 alone is `0x0074000000000000`, written in decimal: `32651097298436096`).

## Build

Dependency sources in `../../vendor-mac/`: `luajit2` (OpenResty v2.1-20260914), `sol2` v3.5.0, `json` (nlohmann v3.12.0),
`hopscotch-map` v2.3.1, `TiltedCore` v0.2.7, `fmt` 12.2.0 and `spdlog` 1.17.0 (both used header-only).

```bash
cmake -S macos -B build-ios -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
      -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
      -DRED4EXT_SDK_DIR=<RED4ext.SDK-macos, branch mac-next-sdk1212> -DCODEWARE_DIR=<cp2077-codeware, branch ios>
cmake --build build-ios
ios/stage-deploy.sh        # signs the dylib and makes deploy/Cyberpunk 2077/
```

The link uses no `-undefined dynamic_lookup`: every import resolves against the iOS SDK.

## Install

Copy the contents of `deploy/Cyberpunk 2077/` over the game folder on the phone:

```
red4ext/plugins/cyber_engine_tweaks/cyber_engine_tweaks.dylib
bin/x64/plugins/cyber_engine_tweaks/scripts/json/, scripts/IconGlyphs/     (required)
bin/x64/plugins/cyber_engine_tweaks/mods/<Mod>/init.lua                    (mods; CyPortHello is the test mod)
```

The app must be built with `tools/sites/cet.txt` in CyPort-hooks. CET needs Codeware (the game instance) and writes its logs
(`cyber_engine_tweaks.log`, `scripting.log`, `gamelog.log`) and `config.json`, `bindings.json`, `persistent.json` in
`bin/x64/plugins/cyber_engine_tweaks/`.

TweakDBID names: the game's Oodle decompressor is not exported on macOS or iOS, so `tweakdb/tweakdbstr.kark` cannot be read; an
uncompressed `tweakdb/tweakdb.str` is.

## LuaJIT and C++ exceptions

`build-luajit.sh` changes one line in its own copy of the LuaJIT source: LuaJIT turns frame unwinding off on every iOS target, and CET
needs C++ exceptions to cross Lua frames as on macOS. `test-luajit-unwind.sh` builds the same library for the iOS simulator and runs
`test-luajit-unwind.cpp` in it.
