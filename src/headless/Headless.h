#pragma once

// CET headless (CET_HEADLESS, the iOS build for CyPort): the Lua runtime and scripting API without the ImGui overlay. No ImGui, no
// renderer, no window and no overlay widgets are compiled in; these are the stand-ins for the classes the shared code (CET.h, LuaVM,
// Scripting, VKBindings, ScriptStore) names. See ios/README.md.

struct D3D12;
struct VKBindings;
struct LuaVM;
struct PersistentState;

// The game window. Headless: nothing to find; on iOS it installs the input monitor that feeds VKBindings (src/headless/InputIOS.mm).
struct Window
{
    Window(VKBindings* apBindings, D3D12* apD3D12);
    ~Window();

    HWND GetWindow() const { return nullptr; }
    bool IsInitialized() const { return false; }
};

// The renderer. Headless: no device, no ImGui; only the display size for GetDisplayResolution().
struct D3D12
{
    D3D12(Window&, Paths&, Options&) {}

    void ReloadFonts() {}
    void SetTrapInputInImGui(const bool) {}
    void DelayedSetTrapInputInImGui(const bool) {}
    [[nodiscard]] bool IsTrapInputInImGui() const noexcept { return false; }
    [[nodiscard]] bool IsInitialized() const noexcept { return false; }
    [[nodiscard]] SIZE GetResolution() const noexcept;

    TiltedPhoques::Signal<void()> OnInitialized;
};

// The Bindings widget owns the overlay toggle bind ("cet" / "overlay_key"); VKBindings and ScriptStore ask for it by these names.
// Headless: the bind exists (bindings.json keeps its entry) and does nothing.
struct Bindings
{
    [[nodiscard]] static const VKModBind& GetOverlayToggleModBind() noexcept;
    [[nodiscard]] static const VKBind& GetOverlayToggleBind() noexcept;
};

// The overlay. Headless: never initialized, never open (mods' onOverlayOpen / onOverlayClose / onDraw never fire).
struct Overlay
{
    Overlay(VKBindings&, Options&, PersistentState&, LuaVM&) {}

    [[nodiscard]] bool IsInitialized() const noexcept { return false; }
    [[nodiscard]] bool IsEnabled() const noexcept { return false; }
    void Toggle() {}
    void Update() {}
};
