# Cyber Engine Tweaks on iOS (CyPort)

Two builds: the headless plugin (stage A, the default, verified on an iPhone 17 Pro) and the plugin with the ImGui overlay
(`-DCET_IOS_OVERLAY=ON`, see [Overlay](#overlay-cet_ios_overlay); it builds and has not run on a phone yet).

## Stage A: headless

The Lua runtime and scripting API of Cyber Engine Tweaks for Cyberpunk 2077 2.5.0 (Steam Mac build, UUID
`7D7382D0-EADD-36F0-BA1C-CEBEC1D5BEBC`) running on an iPhone through CyPort, as a RED4ext plugin. No overlay: no ImGui, no console
window, no renderer. Based on the macOS port in `../macos` (codeman101, branch `mac-next`); everything iOS-specific is behind `CET_IOS`
and `CET_HEADLESS`, and the macOS and Windows builds are unchanged.

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

## Overlay (`CET_IOS_OVERLAY`)

`-DCET_IOS_OVERLAY=ON` builds ImGui (1.91.1-docking, its own stb_truetype rasterizer, no FreeType), CET's widgets (console, bindings,
settings, TweakDB editor, game log), the Lua `ImGui` bindings and the Metal renderer of the macOS port, with UIKit instead of AppKit.
`CET_HEADLESS` is not defined in this build; the headless build is unchanged and stays the default.

```bash
cmake -S macos -B build-ios-overlay -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
      -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 -DCET_IOS_OVERLAY=ON \
      -DRED4EXT_SDK_DIR=<RED4ext.SDK-macos, branch mac-next-sdk1212> -DCODEWARE_DIR=<cp2077-codeware, branch ios>
cmake --build build-ios-overlay
ios/stage-deploy.sh build-ios-overlay "" deploy-overlay     # deploy-overlay/Cyberpunk 2077/, with fonts/ and the CyPortOverlayTest mod
```

Two more dependency sources in `../../vendor-mac/`: `imgui` (v1.91.1-docking) and `stb` (2c980bb).

### What the app must have

The app must be built from a CyPort-hooks shim with the "CET overlay" section (`shim/MacShim.m`). CET finds four functions in it by
name; with an older app `MSRegisterOverlayLayer` is missing, CET logs that and runs without the overlay (mods and hotkeys still work).

| shim function | CET's use (`src/metal/MetalRenderer.mm`) |
|---|---|
| `MSRegisterOverlayLayer(CAMetalLayer*)` | once, before the first drawable: the shim puts the layer over the game view, keeps it the view's size and leaves it out of frame pacing, low latency and the TV mirror |
| `MSOverlaySetToggleHandler(void (*)(void))` | when the overlay is ready: the touch pad shows a CET button that calls `Overlay::Toggle` |
| `MSOverlaySetCapture(int)` | overlay opened / closed: the pad hides, touches become mouse events, keys and mouse pass controller-only mode |
| `MSOverlayShowKeyboard(int)` | a text field was tapped / no text field is active any more |

### How it differs from the macOS overlay

| area | macOS | iOS |
|---|---|---|
| layer | sublayer of the game's `NSView` layer, created and placed by CET | created by CET, placed and sized by the shim |
| size | the view's pixels | `ios_render_scale` pixels per screen point (default 1.5; the phone has 3): 1311 x 603 on an iPhone 17 Pro |
| drawables | always allocated | given back while nothing is drawn (the layer's drawable size goes to 1 x 1) |
| input | `NSEvent` local monitor (`window_mac.mm`) | the same monitor on the shim's `NSEvent` stand-in (`window_ios.mm`); positions arrive as fractions of the game view |
| touch | none | from the shim, as in the game's menus: tap = click, drag = scroll, hold still then drag = mouse drag (sliders, moving and resizing windows), two-finger tap = right click |
| text | `NSEvent.characters` | the shim's on-screen keyboard sends characters; a Bluetooth keyboard's keys go through a US layout table |
| keyboard on screen | none | opens when a text field is tapped; the window with the field moves up while the keyboard covers it |
| style | scaled against 1080p | sized in screen points (text about 14 pt), larger paddings, scroll bars and touch margins (`ApplyTouchStyle`); `ios_ui_scale` scales it |
| fonts | FreeType, the system language's glyph set | stb_truetype, Latin only (a CJK language setting is ignored: memory); icons without oversampling |
| first start | asks for an overlay key | no question: the CET button opens it; an unset overlay key becomes F11 |
| cursor | the game view's cursor | none for fingers; ImGui draws a pointer while a mouse moves |

`config.json`, under `font`: `ios_render_scale` (1 to 3, pixels per point) and `ios_ui_scale` (0.5 to 2, text and control size),
besides `base_size` (18).

### Memory (estimates, not measured on the phone)

| item | size |
|---|---|
| dylib | 9.8 MB on disk (headless: 6.2 MB) |
| font atlas texture, 2048 x 1376 RGBA at the default scale (measured on a Mac with the same settings) | 10.8 MB; 18.4 MB at `ios_render_scale` 2, 41.6 MB at 3 |
| drawables, 3 x 1311 x 603 BGRA, only while something is drawn | 9.5 MB; 16.9 MB at scale 2, 38 MB at 3 |
| ImGui context, draw lists, vertex buffers | 1 to 3 MB |
| Lua `ImGui` bindings in the VM | 1 to 2 MB |

About 25 MB with the overlay open and 15 MB closed, on top of the headless plugin.

### Not yet

- Nothing in this section has run on a phone.
- Images in mods (`ImGui.Image`, `LoadTexture`) are compiled in and untested.
- Copy and paste use ImGui's own clipboard, not the iPhone's.
- With a TV connected the keyboard is on the phone and the overlay on the TV; windows still move up for the keyboard.
