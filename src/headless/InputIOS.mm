// CET headless on iOS (CyPort). See InputIOS.h.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "InputIOS.h"

#include <atomic>
#include <mutex>
#include <vector>

// The part of AppKit's NSEvent the CyPort shim implements (shim/MacShim.m); AppKit itself is not in the iOS SDK, so the class is
// found by name at run time.
@protocol CetShimEvent
- (NSUInteger)type;
- (NSUInteger)modifierFlags;
- (NSInteger)buttonNumber;
- (unsigned short)keyCode;
- (CGFloat)scrollingDeltaX;
- (CGFloat)scrollingDeltaY;
@end

@protocol CetShimEventClass
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
    kKeyDown = 10,
    kKeyUp = 11,
    kFlagsChanged = 12,
    kScrollWheel = 22,
    kOtherMouseDown = 25,
    kOtherMouseUp = 26,
};

// Windows virtual-key codes (WinUser.h).
enum : uint16_t
{
    VK_LBUTTON = 0x01, VK_RBUTTON = 0x02, VK_MBUTTON = 0x04, VK_XBUTTON1 = 0x05, VK_XBUTTON2 = 0x06,
    VK_BACK = 0x08, VK_TAB = 0x09, VK_RETURN = 0x0D, VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_CAPITAL = 0x14,
    VK_ESCAPE = 0x1B, VK_SPACE = 0x20, VK_PRIOR = 0x21, VK_NEXT = 0x22, VK_END = 0x23, VK_HOME = 0x24, VK_LEFT = 0x25, VK_UP = 0x26,
    VK_RIGHT = 0x27, VK_DOWN = 0x28, VK_INSERT = 0x2D, VK_DELETE = 0x2E, VK_LWIN = 0x5B, VK_RWIN = 0x5C, VK_NUMPAD0 = 0x60,
    VK_MULTIPLY = 0x6A, VK_ADD = 0x6B, VK_SUBTRACT = 0x6D, VK_DECIMAL = 0x6E, VK_DIVIDE = 0x6F, VK_F1 = 0x70, VK_F13 = 0x7C,
    VK_NUMLOCK = 0x90, VK_OEM_1 = 0xBA, VK_OEM_PLUS = 0xBB, VK_OEM_COMMA = 0xBC, VK_OEM_MINUS = 0xBD, VK_OEM_PERIOD = 0xBE,
    VK_OEM_2 = 0xBF, VK_OEM_3 = 0xC0, VK_OEM_4 = 0xDB, VK_OEM_5 = 0xDC, VK_OEM_6 = 0xDD, VK_OEM_7 = 0xDE, VK_OEM_102 = 0xE2,
};

// macOS virtual key code (Carbon kVK_*, the codes the shim's events carry) to the Windows virtual-key code raw input reports on a US
// layout; the same table as src/window/window_mac.mm (both sides of a modifier map to the generic VK_SHIFT / VK_CONTROL / VK_MENU).
uint16_t MacKeyToVK(uint16_t aKeyCode)
{
    switch (aKeyCode)
    {
    case 0x00: return 'A';
    case 0x0B: return 'B';
    case 0x08: return 'C';
    case 0x02: return 'D';
    case 0x0E: return 'E';
    case 0x03: return 'F';
    case 0x05: return 'G';
    case 0x04: return 'H';
    case 0x22: return 'I';
    case 0x26: return 'J';
    case 0x28: return 'K';
    case 0x25: return 'L';
    case 0x2E: return 'M';
    case 0x2D: return 'N';
    case 0x1F: return 'O';
    case 0x23: return 'P';
    case 0x0C: return 'Q';
    case 0x0F: return 'R';
    case 0x01: return 'S';
    case 0x11: return 'T';
    case 0x20: return 'U';
    case 0x09: return 'V';
    case 0x0D: return 'W';
    case 0x07: return 'X';
    case 0x10: return 'Y';
    case 0x06: return 'Z';
    case 0x1D: return '0';
    case 0x12: return '1';
    case 0x13: return '2';
    case 0x14: return '3';
    case 0x15: return '4';
    case 0x17: return '5';
    case 0x16: return '6';
    case 0x1A: return '7';
    case 0x1C: return '8';
    case 0x19: return '9';
    case 0x32: return VK_OEM_3;      // grave
    case 0x1B: return VK_OEM_MINUS;
    case 0x18: return VK_OEM_PLUS;   // equal
    case 0x21: return VK_OEM_4;      // left bracket
    case 0x1E: return VK_OEM_6;      // right bracket
    case 0x2A: return VK_OEM_5;      // backslash
    case 0x29: return VK_OEM_1;      // semicolon
    case 0x27: return VK_OEM_7;      // quote
    case 0x2B: return VK_OEM_COMMA;
    case 0x2F: return VK_OEM_PERIOD;
    case 0x2C: return VK_OEM_2;      // slash
    case 0x0A: return VK_OEM_102;    // ISO section
    case 0x24: return VK_RETURN;
    case 0x30: return VK_TAB;
    case 0x31: return VK_SPACE;
    case 0x33: return VK_BACK;
    case 0x35: return VK_ESCAPE;
    case 0x75: return VK_DELETE;     // forward delete
    case 0x73: return VK_HOME;
    case 0x77: return VK_END;
    case 0x74: return VK_PRIOR;
    case 0x79: return VK_NEXT;
    case 0x72: return VK_INSERT;     // help
    case 0x7B: return VK_LEFT;
    case 0x7C: return VK_RIGHT;
    case 0x7E: return VK_UP;
    case 0x7D: return VK_DOWN;
    case 0x38:
    case 0x3C: return VK_SHIFT;
    case 0x3B:
    case 0x3E: return VK_CONTROL;
    case 0x3A:
    case 0x3D: return VK_MENU;
    case 0x37: return VK_LWIN;
    case 0x36: return VK_RWIN;
    case 0x39: return VK_CAPITAL;
    case 0x7A: return VK_F1;
    case 0x78: return VK_F1 + 1;
    case 0x63: return VK_F1 + 2;
    case 0x76: return VK_F1 + 3;
    case 0x60: return VK_F1 + 4;
    case 0x61: return VK_F1 + 5;
    case 0x62: return VK_F1 + 6;
    case 0x64: return VK_F1 + 7;
    case 0x65: return VK_F1 + 8;
    case 0x6D: return VK_F1 + 9;
    case 0x67: return VK_F1 + 10;
    case 0x6F: return VK_F1 + 11;
    case 0x69: return VK_F13;
    case 0x6B: return VK_F13 + 1;
    case 0x71: return VK_F13 + 2;
    case 0x6A: return VK_F13 + 3;
    case 0x40: return VK_F13 + 4;
    case 0x4F: return VK_F13 + 5;
    case 0x50: return VK_F13 + 6;
    case 0x5A: return VK_F13 + 7;
    case 0x52: return VK_NUMPAD0;
    case 0x53: return VK_NUMPAD0 + 1;
    case 0x54: return VK_NUMPAD0 + 2;
    case 0x55: return VK_NUMPAD0 + 3;
    case 0x56: return VK_NUMPAD0 + 4;
    case 0x57: return VK_NUMPAD0 + 5;
    case 0x58: return VK_NUMPAD0 + 6;
    case 0x59: return VK_NUMPAD0 + 7;
    case 0x5B: return VK_NUMPAD0 + 8;
    case 0x5C: return VK_NUMPAD0 + 9;
    case 0x41: return VK_DECIMAL;
    case 0x43: return VK_MULTIPLY;
    case 0x45: return VK_ADD;
    case 0x47: return VK_NUMLOCK;    // keypad clear
    case 0x4B: return VK_DIVIDE;
    case 0x4C: return VK_RETURN;     // keypad enter
    case 0x4E: return VK_SUBTRACT;
    case 0x51: return VK_OEM_PLUS;   // keypad equals
    default: return 0;
    }
}

// The device-independent modifier bit (NSEventModifierFlag*) a flagsChanged event's key belongs to; 0 for a key that is no modifier.
NSUInteger ModifierClassForKey(uint16_t aKeyCode)
{
    switch (aKeyCode)
    {
    case 0x39: return 1u << 16; // caps lock
    case 0x38:
    case 0x3C: return 1u << 17; // shift
    case 0x3B:
    case 0x3E: return 1u << 18; // control
    case 0x3A:
    case 0x3D: return 1u << 19; // option
    case 0x37:
    case 0x36: return 1u << 20; // command
    default: return 0;
    }
}

std::mutex g_lock;
std::vector<CetIOSInputEvent> g_queue;
id g_monitor = nil;
std::atomic<int32_t> g_screenWidth{0};
std::atomic<int32_t> g_screenHeight{0};

void Push(CetIOSInputEvent aEvent)
{
    std::lock_guard lock(g_lock);
    if (g_queue.size() < 1024) // nobody draining (CET not started): drop instead of growing
        g_queue.push_back(aEvent);
}

void OnEvent(id<CetShimEvent> aEvent)
{
    const NSUInteger type = [aEvent type];
    switch (type)
    {
    case kKeyDown:
    case kKeyUp:
    {
        if (const uint16_t vk = MacKeyToVK([aEvent keyCode]))
            Push({CetIOSInputEvent::Type::Key, vk, type == kKeyDown, 0});
        break;
    }
    case kFlagsChanged:
    {
        const uint16_t keyCode = [aEvent keyCode];
        const NSUInteger bit = ModifierClassForKey(keyCode);
        if (const uint16_t vk = bit ? MacKeyToVK(keyCode) : 0)
            Push({CetIOSInputEvent::Type::Key, vk, ([aEvent modifierFlags] & bit) != 0, 0});
        break;
    }
    case kLeftMouseDown:
    case kLeftMouseUp:
        Push({CetIOSInputEvent::Type::Key, VK_LBUTTON, type == kLeftMouseDown, 0});
        break;
    case kRightMouseDown:
    case kRightMouseUp:
        Push({CetIOSInputEvent::Type::Key, VK_RBUTTON, type == kRightMouseDown, 0});
        break;
    case kOtherMouseDown:
    case kOtherMouseUp:
    {
        static constexpr uint16_t kButtonVK[] = {VK_LBUTTON, VK_RBUTTON, VK_MBUTTON, VK_XBUTTON1, VK_XBUTTON2};
        const NSInteger button = [aEvent buttonNumber];
        if (button >= 2 && button <= 4)
            Push({CetIOSInputEvent::Type::Key, kButtonVK[button], type == kOtherMouseDown, 0});
        break;
    }
    case kScrollWheel:
    {
        const CGFloat dx = [aEvent scrollingDeltaX];
        const CGFloat dy = [aEvent scrollingDeltaY];
        if (dy != 0)
            Push({CetIOSInputEvent::Type::Wheel, 0, false, static_cast<int8_t>(dy > 0 ? 1 : -1)});
        if (dx != 0)
            Push({CetIOSInputEvent::Type::Wheel, 0, false, static_cast<int8_t>(dx > 0 ? 2 : -2)});
        break;
    }
    default: break;
    }
}
} // namespace

bool CetIOSInstallInput()
{
    dispatch_async(dispatch_get_main_queue(), ^{
        const CGRect bounds = UIScreen.mainScreen.nativeBounds; // pixels, portrait
        g_screenWidth = static_cast<int32_t>(MAX(bounds.size.width, bounds.size.height));
        g_screenHeight = static_cast<int32_t>(MIN(bounds.size.width, bounds.size.height));
    });

    Class eventClass = NSClassFromString(@"NSEvent");
    if (!eventClass || ![eventClass respondsToSelector:@selector(addLocalMonitorForEventsMatchingMask:handler:)])
    {
        NSLog(@"[cet] no NSEvent stand-in with local monitors in this process (not CyPort?): mod hotkeys get no input");
        return false;
    }

    const unsigned long long mask = (1ULL << kKeyDown) | (1ULL << kKeyUp) | (1ULL << kFlagsChanged) | (1ULL << kLeftMouseDown) |
                                    (1ULL << kLeftMouseUp) | (1ULL << kRightMouseDown) | (1ULL << kRightMouseUp) |
                                    (1ULL << kOtherMouseDown) | (1ULL << kOtherMouseUp) | (1ULL << kScrollWheel);
    g_monitor = [(id<CetShimEventClass>)eventClass addLocalMonitorForEventsMatchingMask:mask
                                                                                  handler:^id(id aEvent) {
                                                                                      OnEvent(aEvent);
                                                                                      return aEvent; // never kept from the game
                                                                                  }];
    return g_monitor != nil;
}

void CetIOSRemoveInput()
{
    Class eventClass = NSClassFromString(@"NSEvent");
    if (g_monitor && eventClass && [eventClass respondsToSelector:@selector(removeMonitor:)])
        [(id<CetShimEventClass>)eventClass removeMonitor:g_monitor];
    g_monitor = nil;
}

size_t CetIOSDrainInput(CetIOSInputEvent* apOut, size_t aCapacity)
{
    std::lock_guard lock(g_lock);
    const size_t count = std::min(aCapacity, g_queue.size());
    std::copy_n(g_queue.begin(), count, apOut);
    g_queue.erase(g_queue.begin(), g_queue.begin() + static_cast<std::ptrdiff_t>(count));
    return count;
}

void CetIOSScreenPixels(int32_t* apWidth, int32_t* apHeight)
{
    *apWidth = g_screenWidth;
    *apHeight = g_screenHeight;
}
