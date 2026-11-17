#pragma once

// CET headless on iOS (CyPort): key and mouse-button input for mod hotkeys (registerHotkey / registerInput) without the overlay.
// InputIOS.mm installs one local event monitor on the CyPort shim's NSEvent stand-in, which hands every keyboard, mouse and
// touch-as-mouse event to its monitors on the game thread before the game sees it. The monitor never keeps an event from the game; it
// queues {Windows virtual-key code, down} records that Headless.cpp drains into VKBindings on the game's main thread.

#include <cstdint>

struct CetIOSInputEvent
{
    enum class Type : uint8_t
    {
        Key,  // VKCode, Down (keyboard keys and mouse buttons)
        Wheel // Wheel: +1/-1 vertical, +2/-2 horizontal
    };

    Type EventType{Type::Key};
    uint16_t VKCode{0};
    bool Down{false};
    int8_t Wheel{0};
};

// True when the monitor was installed (the shim's NSEvent class exists).
bool CetIOSInstallInput();
void CetIOSRemoveInput();
// Moves the queued events to apOut (at most aCapacity, oldest first); returns the count.
size_t CetIOSDrainInput(CetIOSInputEvent* apOut, size_t aCapacity);
// The screen in pixels, landscape (0 x 0 until UIKit has answered on the main thread).
void CetIOSScreenPixels(int32_t* apWidth, int32_t* apHeight);

// For the overlay build (src/window/window_ios.mm), which installs its own monitor:
// macOS virtual key code (the codes the shim's events carry) to the Windows virtual-key code, 0 if none.
uint16_t CetIOSMacKeyToVK(uint16_t aKeyCode);
// Asks UIKit for the screen size and scale on the main thread (CetIOSInstallInput does it too).
void CetIOSQueryScreen();
// Pixels per point of the screen (0 until UIKit has answered).
float CetIOSScreenScale();
