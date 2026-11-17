// CET iOS (CyPort) with the overlay: the game "window" and its input. See window/window.h (Apple branch) and ios/README.md.
//
// There is no AppKit on iOS. The CyPort shim implements the part of NSEvent the game uses, with local monitors: every keyboard key
// (Bluetooth keyboard or the shim's on-screen keyboard), mouse event and touch the shim turns into a mouse event is handed to the
// monitors on the game thread before the game sees it. This file installs one monitor on that class (found by name), queues
// MacInputEvent records for D3D12::PrepareUpdate (ImGui and VKBindings) and, while the overlay traps input, keeps the events from the
// game. Mouse positions are queued as fractions of the game view; the renderer scales them to the overlay's pixels.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#pragma push_macro("nil")
#undef nil
#define BOOL WINBOOL // the Win32 BOOL of the shared headers, not Objective-C's
#include <stdafx.h>

#include "window.h"

#include <CET.h>
#include <MacShims.hpp>
#include <headless/InputIOS.h>
#undef BOOL
#pragma pop_macro("nil")

// The part of the shim's NSEvent, NSWindow and NSView stand-ins used here (CyPort-hooks shim/MacShim.m).
@protocol CetOverlayShimView
- (CGRect)bounds;
@end

@protocol CetOverlayShimWindow
- (id<CetOverlayShimView>)contentView;
@end

@protocol CetOverlayShimEvent
- (NSUInteger)type;
- (NSUInteger)modifierFlags;
- (NSInteger)buttonNumber;
- (unsigned short)keyCode;
- (CGFloat)scrollingDeltaX;
- (CGFloat)scrollingDeltaY;
- (BOOL)hasPreciseScrollingDeltas;
- (CGPoint)locationInWindow;
- (NSString*)characters;
- (id<CetOverlayShimWindow>)window;
@end

@protocol CetOverlayShimEventClass
+ (id)addLocalMonitorForEventsMatchingMask:(unsigned long long)aMask handler:(id (^)(id))aHandler;
+ (void)removeMonitor:(id)aMonitor;
@end

namespace
{
// AppKit NSEventType values.
enum : NSUInteger
{
    kLeftMouseDown = 1,
    kLeftMouseUp = 2,
    kRightMouseDown = 3,
    kRightMouseUp = 4,
    kMouseMoved = 5,
    kLeftMouseDragged = 6,
    kRightMouseDragged = 7,
    kKeyDown = 10,
    kKeyUp = 11,
    kFlagsChanged = 12,
    kScrollWheel = 22,
    kOtherMouseDown = 25,
    kOtherMouseUp = 26,
    kOtherMouseDragged = 27,
};

// AppKit NSEventModifierFlag values (device independent).
enum : NSUInteger
{
    kFlagCapsLock = 1u << 16,
    kFlagShift = 1u << 17,
    kFlagControl = 1u << 18,
    kFlagOption = 1u << 19,
    kFlagCommand = 1u << 20,
};

// macOS virtual key code (the codes the shim's events carry) to ImGuiKey; the table of src/window/window_mac.mm in numbers.
ImGuiKey MacKeyToImGui(uint16_t aKeyCode)
{
    static constexpr struct
    {
        uint16_t Code;
        ImGuiKey Key;
    } kKeys[] = {
        {0x00, ImGuiKey_A}, {0x0B, ImGuiKey_B}, {0x08, ImGuiKey_C}, {0x02, ImGuiKey_D}, {0x0E, ImGuiKey_E}, {0x03, ImGuiKey_F},
        {0x05, ImGuiKey_G}, {0x04, ImGuiKey_H}, {0x22, ImGuiKey_I}, {0x26, ImGuiKey_J}, {0x28, ImGuiKey_K}, {0x25, ImGuiKey_L},
        {0x2E, ImGuiKey_M}, {0x2D, ImGuiKey_N}, {0x1F, ImGuiKey_O}, {0x23, ImGuiKey_P}, {0x0C, ImGuiKey_Q}, {0x0F, ImGuiKey_R},
        {0x01, ImGuiKey_S}, {0x11, ImGuiKey_T}, {0x20, ImGuiKey_U}, {0x09, ImGuiKey_V}, {0x0D, ImGuiKey_W}, {0x07, ImGuiKey_X},
        {0x10, ImGuiKey_Y}, {0x06, ImGuiKey_Z}, {0x1D, ImGuiKey_0}, {0x12, ImGuiKey_1}, {0x13, ImGuiKey_2}, {0x14, ImGuiKey_3},
        {0x15, ImGuiKey_4}, {0x17, ImGuiKey_5}, {0x16, ImGuiKey_6}, {0x1A, ImGuiKey_7}, {0x1C, ImGuiKey_8}, {0x19, ImGuiKey_9},
        {0x32, ImGuiKey_GraveAccent}, {0x1B, ImGuiKey_Minus}, {0x18, ImGuiKey_Equal}, {0x21, ImGuiKey_LeftBracket},
        {0x1E, ImGuiKey_RightBracket}, {0x2A, ImGuiKey_Backslash}, {0x29, ImGuiKey_Semicolon}, {0x27, ImGuiKey_Apostrophe},
        {0x2B, ImGuiKey_Comma}, {0x2F, ImGuiKey_Period}, {0x2C, ImGuiKey_Slash}, {0x24, ImGuiKey_Enter}, {0x30, ImGuiKey_Tab},
        {0x31, ImGuiKey_Space}, {0x33, ImGuiKey_Backspace}, {0x35, ImGuiKey_Escape}, {0x75, ImGuiKey_Delete}, {0x73, ImGuiKey_Home},
        {0x77, ImGuiKey_End}, {0x74, ImGuiKey_PageUp}, {0x79, ImGuiKey_PageDown}, {0x72, ImGuiKey_Insert}, {0x7B, ImGuiKey_LeftArrow},
        {0x7C, ImGuiKey_RightArrow}, {0x7E, ImGuiKey_UpArrow}, {0x7D, ImGuiKey_DownArrow}, {0x38, ImGuiKey_LeftShift},
        {0x3C, ImGuiKey_RightShift}, {0x3B, ImGuiKey_LeftCtrl}, {0x3E, ImGuiKey_RightCtrl}, {0x3A, ImGuiKey_LeftAlt},
        {0x3D, ImGuiKey_RightAlt}, {0x37, ImGuiKey_LeftSuper}, {0x36, ImGuiKey_RightSuper}, {0x39, ImGuiKey_CapsLock},
        {0x7A, ImGuiKey_F1}, {0x78, ImGuiKey_F2}, {0x63, ImGuiKey_F3}, {0x76, ImGuiKey_F4}, {0x60, ImGuiKey_F5}, {0x61, ImGuiKey_F6},
        {0x62, ImGuiKey_F7}, {0x64, ImGuiKey_F8}, {0x65, ImGuiKey_F9}, {0x6D, ImGuiKey_F10}, {0x67, ImGuiKey_F11}, {0x6F, ImGuiKey_F12},
        {0x52, ImGuiKey_Keypad0}, {0x53, ImGuiKey_Keypad1}, {0x54, ImGuiKey_Keypad2}, {0x55, ImGuiKey_Keypad3},
        {0x56, ImGuiKey_Keypad4}, {0x57, ImGuiKey_Keypad5}, {0x58, ImGuiKey_Keypad6}, {0x59, ImGuiKey_Keypad7},
        {0x5B, ImGuiKey_Keypad8}, {0x5C, ImGuiKey_Keypad9}, {0x41, ImGuiKey_KeypadDecimal}, {0x43, ImGuiKey_KeypadMultiply},
        {0x45, ImGuiKey_KeypadAdd}, {0x47, ImGuiKey_NumLock}, {0x4B, ImGuiKey_KeypadDivide}, {0x4C, ImGuiKey_KeypadEnter},
        {0x4E, ImGuiKey_KeypadSubtract}, {0x51, ImGuiKey_KeypadEqual},
    };
    for (const auto& key : kKeys)
    {
        if (key.Code == aKeyCode)
            return key.Key;
    }
    return ImGuiKey_None;
}

// The character a key types on a US keyboard, 0 if none. The shim's on-screen keyboard sends the characters with its key events; a
// Bluetooth keyboard's events carry none (the shim gets key codes from GameController), so the text comes from this table.
uint32_t CharForKey(uint16_t aVK, bool aShift, bool aCapsLock)
{
    if (aVK >= 'A' && aVK <= 'Z')
        return (aShift != aCapsLock) ? aVK : aVK + ('a' - 'A');
    if (aVK >= '0' && aVK <= '9')
        return aShift ? static_cast<uint32_t>(")!@#$%^&*("[aVK - '0']) : aVK;
    if (aVK >= VK_NUMPAD0 && aVK <= VK_NUMPAD9)
        return '0' + (aVK - VK_NUMPAD0);
    switch (aVK)
    {
    case VK_SPACE: return ' ';
    case VK_OEM_3: return aShift ? '~' : '`';
    case VK_OEM_MINUS: return aShift ? '_' : '-';
    case VK_OEM_PLUS: return aShift ? '+' : '=';
    case VK_OEM_4: return aShift ? '{' : '[';
    case VK_OEM_6: return aShift ? '}' : ']';
    case VK_OEM_5: return aShift ? '|' : '\\';
    case VK_OEM_1: return aShift ? ':' : ';';
    case VK_OEM_7: return aShift ? '"' : '\'';
    case VK_OEM_COMMA: return aShift ? '<' : ',';
    case VK_OEM_PERIOD: return aShift ? '>' : '.';
    case VK_OEM_2: return aShift ? '?' : '/';
    case VK_DECIMAL: return '.';
    case VK_MULTIPLY: return '*';
    case VK_ADD: return '+';
    case VK_SUBTRACT: return '-';
    case VK_DIVIDE: return '/';
    default: return 0;
    }
}

// The device-independent modifier bit a flagsChanged event's key belongs to; 0 for a key that is no modifier.
NSUInteger ModifierClassForKey(uint16_t aKeyCode)
{
    switch (aKeyCode)
    {
    case 0x39: return kFlagCapsLock;
    case 0x38:
    case 0x3C: return kFlagShift;
    case 0x3B:
    case 0x3E: return kFlagControl;
    case 0x3A:
    case 0x3D: return kFlagOption;
    case 0x37:
    case 0x36: return kFlagCommand;
    default: return 0;
    }
}

constexpr size_t kMaxQueued = 2048; // nobody draining (CET not started): drop instead of growing
} // namespace

Window::Window(VKBindings* apBindings, D3D12* apD3D12)
    : m_pBindings(apBindings)
    , m_pD3D12(apD3D12)
{
    CetIOSQueryScreen();

    Class eventClass = NSClassFromString(@"NSEvent");
    if (!eventClass || ![eventClass respondsToSelector:@selector(addLocalMonitorForEventsMatchingMask:handler:)])
    {
        CetMac::Log("[cet] Window: no NSEvent stand-in with local monitors in this process (not CyPort?); the overlay stays off");
        return;
    }

    const unsigned long long mask = (1ULL << kKeyDown) | (1ULL << kKeyUp) | (1ULL << kFlagsChanged) | (1ULL << kMouseMoved) |
                                    (1ULL << kLeftMouseDown) | (1ULL << kLeftMouseUp) | (1ULL << kRightMouseDown) |
                                    (1ULL << kRightMouseUp) | (1ULL << kOtherMouseDown) | (1ULL << kOtherMouseUp) |
                                    (1ULL << kLeftMouseDragged) | (1ULL << kRightMouseDragged) | (1ULL << kOtherMouseDragged) |
                                    (1ULL << kScrollWheel);
    Window* self = this;
    id monitor = [(id<CetOverlayShimEventClass>)eventClass addLocalMonitorForEventsMatchingMask:mask
                                                                                        handler:^id(id aEvent) {
                                                                                            return self->OnEvent((__bridge void*)aEvent)
                                                                                                       ? (id)nullptr
                                                                                                       : aEvent;
                                                                                        }];
    if (!monitor)
    {
        CetMac::Log("[cet] Window: the shim's NSEvent gave no monitor; the overlay stays off");
        return;
    }
    m_monitor = (__bridge_retained void*)monitor;

    // the app left the foreground: release held keys in ImGui and VKBindings
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
                                                                    object:nullptr
                                                                     queue:nullptr
                                                                usingBlock:^(NSNotification*) {
                                                                    std::lock_guard lock(self->m_queueLock);
                                                                    MacInputEvent focus;
                                                                    focus.EventType = MacInputEvent::Type::FocusLost;
                                                                    self->m_queue.push_back(focus);
                                                                }];
    m_observers = (__bridge_retained void*)observer;

    m_initialized = true;
    CetMac::Log("[cet] Window: input monitor installed on the CyPort shim's NSEvent (keyboard, mouse, touches as mouse)");
}

Window::~Window()
{
    void* monitor = m_monitor;
    void* observer = m_observers;
    m_monitor = m_observers = nullptr;
    m_initialized = false;
    if (monitor)
    {
        id held = (__bridge_transfer id)monitor;
        Class eventClass = NSClassFromString(@"NSEvent");
        if (eventClass && [eventClass respondsToSelector:@selector(removeMonitor:)])
            [(id<CetOverlayShimEventClass>)eventClass removeMonitor:held];
    }
    if (observer)
        [[NSNotificationCenter defaultCenter] removeObserver:(__bridge_transfer id)observer];
}

void Window::UpdateMetrics()
{
    // nothing to measure: the renderer sets the metrics (SetClientMetrics)
}

bool Window::OnEvent(void* apNSEvent)
{
    id<CetOverlayShimEvent> event = (__bridge id<CetOverlayShimEvent>)apNSEvent;
    if (!event)
        return false;

    const NSUInteger type = [event type];
    const NSUInteger flags = [event modifierFlags];
    // While the overlay traps input, key presses, clicks, mouse moves and scrolling are kept from the game. Releases (key up,
    // modifier up, mouse up) always reach it: a key held when the overlay opened would otherwise stay down in the game.
    const bool trap = m_pD3D12 && m_pD3D12->IsTrapInputInImGui();
    auto fill = [&](MacInputEvent& aOut)
    {
        aOut.Shift = (flags & kFlagShift) != 0;
        aOut.Ctrl = (flags & kFlagControl) != 0;
        aOut.Alt = (flags & kFlagOption) != 0;
        aOut.Super = (flags & kFlagCommand) != 0;
    };
    // the position as fractions of the game view (the shim's events are in AppKit window coordinates: origin bottom-left)
    auto position = [&](MacInputEvent& aOut) -> bool
    {
        id<CetOverlayShimWindow> window = [event window];
        id<CetOverlayShimView> view = (window && [(id)window respondsToSelector:@selector(contentView)]) ? [window contentView] : nullptr;
        if (!view || ![(id)view respondsToSelector:@selector(bounds)])
            return false;
        const CGRect bounds = [view bounds];
        if (bounds.size.width < 1 || bounds.size.height < 1)
            return false;
        const CGPoint at = [event locationInWindow];
        aOut.X = static_cast<float>(std::clamp(at.x / bounds.size.width, 0.0, 1.0));
        aOut.Y = static_cast<float>(std::clamp(1.0 - at.y / bounds.size.height, 0.0, 1.0));
        return true;
    };

    std::lock_guard lock(m_queueLock);
    if (m_queue.size() >= kMaxQueued)
        return trap;

    switch (type)
    {
    case kKeyDown:
    case kKeyUp:
    {
        const bool down = type == kKeyDown;
        const uint16_t keyCode = [event keyCode];
        MacInputEvent key;
        key.EventType = down ? MacInputEvent::Type::KeyDown : MacInputEvent::Type::KeyUp;
        key.VKCode = CetIOSMacKeyToVK(keyCode);
        key.ImGuiKeyCode = MacKeyToImGui(keyCode);
        fill(key);
        m_queue.push_back(key);

        if (down && trap && !(flags & (kFlagCommand | kFlagControl)))
        {
            NSString* characters = [event characters];
            if (characters.length > 0)
            {
                for (NSUInteger i = 0; i < characters.length; ++i)
                {
                    const unichar c = [characters characterAtIndex:i];
                    if (c < 0x20 || c == 0x7F || (c >= 0xF700 && c <= 0xF8FF))
                        continue;
                    MacInputEvent text;
                    text.EventType = MacInputEvent::Type::Text;
                    text.Character = c;
                    m_queue.push_back(text);
                }
            }
            else if (const uint32_t c = CharForKey(key.VKCode, key.Shift, (flags & kFlagCapsLock) != 0))
            {
                MacInputEvent text;
                text.EventType = MacInputEvent::Type::Text;
                text.Character = c;
                m_queue.push_back(text);
            }
        }
        return down && trap;
    }
    case kFlagsChanged:
    {
        const uint16_t keyCode = [event keyCode];
        const NSUInteger bit = ModifierClassForKey(keyCode);
        if (!bit)
            return trap;
        const bool down = (flags & bit) != 0;
        m_modifierFlags = static_cast<uint32_t>(flags);
        MacInputEvent key;
        key.EventType = down ? MacInputEvent::Type::KeyDown : MacInputEvent::Type::KeyUp;
        key.VKCode = CetIOSMacKeyToVK(keyCode);
        key.ImGuiKeyCode = MacKeyToImGui(keyCode);
        fill(key);
        m_queue.push_back(key);
        return down && trap;
    }
    case kMouseMoved:
    case kLeftMouseDragged:
    case kRightMouseDragged:
    case kOtherMouseDragged:
    {
        MacInputEvent move;
        move.EventType = MacInputEvent::Type::MouseMove;
        move.MouseButton = type == kMouseMoved ? 1 : 0; // 1: a move with no button held (a mouse hovering; a tap sends one)
        fill(move);
        if (position(move))
            m_queue.push_back(move);
        return trap;
    }
    case kLeftMouseDown:
    case kLeftMouseUp:
    case kRightMouseDown:
    case kRightMouseUp:
    case kOtherMouseDown:
    case kOtherMouseUp:
    {
        const bool down = type == kLeftMouseDown || type == kRightMouseDown || type == kOtherMouseDown;
        NSInteger button = [event buttonNumber]; // 0 left, 1 right, 2 middle, 3 and 4 extra
        if (type == kLeftMouseDown || type == kLeftMouseUp)
            button = 0;
        else if (type == kRightMouseDown || type == kRightMouseUp)
            button = 1;
        if (button < 0 || button > 4)
            return trap;
        static constexpr uint16_t kButtonVK[] = {VK_LBUTTON, VK_RBUTTON, VK_MBUTTON, VK_XBUTTON1, VK_XBUTTON2};
        // a touch has no hover: the press carries its own position
        MacInputEvent move;
        move.EventType = MacInputEvent::Type::MouseMove;
        if (position(move))
            m_queue.push_back(move);
        MacInputEvent click;
        click.EventType = down ? MacInputEvent::Type::MouseDown : MacInputEvent::Type::MouseUp;
        click.MouseButton = static_cast<int32_t>(button);
        click.VKCode = kButtonVK[button];
        fill(click);
        m_queue.push_back(click);
        return down && trap;
    }
    case kScrollWheel:
    {
        // Points of finger (or wheel) movement, down and right positive: the renderer turns them into ImGui wheel steps. A finger
        // drag on the game view arrives as this event with the shim's ScrollSpeed (default 1.5) applied and no precise deltas.
        MacInputEvent wheel;
        wheel.EventType = MacInputEvent::Type::Wheel;
        const CGFloat divide = [event hasPreciseScrollingDeltas] ? 1.0 : 1.5;
        wheel.WheelX = static_cast<float>([event scrollingDeltaX] / divide);
        wheel.WheelY = static_cast<float>([event scrollingDeltaY] / divide);
        fill(wheel);
        if (wheel.WheelX != 0.0f || wheel.WheelY != 0.0f)
        {
            MacInputEvent move;
            move.EventType = MacInputEvent::Type::MouseMove;
            if (position(move))
                m_queue.push_back(move);
            m_queue.push_back(wheel);
        }
        return trap;
    }
    default: return false;
    }
}

void Window::DrainInput(std::vector<MacInputEvent>& aOut)
{
    std::lock_guard lock(m_queueLock);
    aOut.insert(aOut.end(), m_queue.begin(), m_queue.end());
    m_queue.clear();
}
