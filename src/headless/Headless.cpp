#include <stdafx.h>

// CET headless: see Headless.h. The Windows build compiles every .cpp under src; there this file is empty.
#ifdef CET_HEADLESS

#include <CET.h>

#if CET_IOS
#include "InputIOS.h"
#include "MacShims.hpp"
#endif

namespace
{
VKBind s_overlayToggleBind{"overlay_key", "Overlay Key", "The overlay is not part of this build.", [] {}};
VKModBind s_overlayToggleModBind{"cet", s_overlayToggleBind.ID};
} // namespace

const VKModBind& Bindings::GetOverlayToggleModBind() noexcept
{
    return s_overlayToggleModBind;
}

const VKBind& Bindings::GetOverlayToggleBind() noexcept
{
    return s_overlayToggleBind;
}

Window::Window(VKBindings*, D3D12*)
{
#if CET_IOS
    if (!CetIOSInstallInput())
    {
        Log::Warn("No input source for mod hotkeys (the CyPort shim's NSEvent stand-in was not found)");
        return;
    }

    Log::Info("Input monitor installed: mod hotkeys (registerHotkey / registerInput) get keys and mouse buttons");
    // The same hand-over the renderer does on macOS and Windows: queued input goes to VKBindings on the game's main thread, whose
    // Update (LuaVM::Update) then runs the mods' callbacks.
    GameMainThread::Get().AddGenericTask(
        []
        {
            if (!CetMac::CetReady())
                return false;

            auto& bindings = CET::Get().GetBindings();
            CetIOSInputEvent events[64];
            while (const size_t count = CetIOSDrainInput(events, std::size(events)))
            {
                for (size_t i = 0; i < count; ++i)
                {
                    if (events[i].EventType == CetIOSInputEvent::Type::Key)
                        bindings.OnMacKey(events[i].VKCode, events[i].Down);
                    else
                        bindings.OnMacWheel(events[i].Wheel);
                }
            }
            return false;
        });
#endif
}

Window::~Window()
{
#if CET_IOS
    CetIOSRemoveInput();
#endif
}

SIZE D3D12::GetResolution() const noexcept
{
    int32_t width = 0, height = 0;
#if CET_IOS
    CetIOSScreenPixels(&width, &height);
#endif
    return {width, height};
}

#endif // CET_HEADLESS
