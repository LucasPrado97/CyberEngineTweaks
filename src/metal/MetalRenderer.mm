// CET macOS: the Metal renderer. See metal/MetalRenderer.h for the design.

#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

#pragma push_macro("nil")
#undef nil
#define BOOL WINBOOL // the Win32 BOOL of the shared headers, not Objective-C's
#include <stdafx.h>

#include "MetalRenderer.h"

#include <CET.h>
#include <MacShims.hpp>
#include <Utils.h>
#undef BOOL
#pragma pop_macro("nil")

#include <imgui_impl_metal.h>
#if CET_IOS
#include <imgui_internal.h> // the active text field's position and its window (keyboard avoidance)
#endif

#include <pthread.h>

#if CET_IOS
#include <headless/InputIOS.h>

#include <dlfcn.h>
#endif

namespace
{
void RunOnMainSync(void (^aBlock)())
{
    if (pthread_main_np())
        aBlock();
    else
        dispatch_sync(dispatch_get_main_queue(), aBlock);
}

void RunOnMainAsync(void (^aBlock)())
{
    if (pthread_main_np())
        aBlock();
    else
        dispatch_async(dispatch_get_main_queue(), aBlock);
}

#if CET_IOS
// The CyPort shim's overlay functions (CyPort-hooks shim/MacShim.m, "CET overlay"), found by name: the shim is the app's own library.
struct ShimOverlay
{
    int (*RegisterLayer)(void*){nullptr};               // MSRegisterOverlayLayer: puts the layer over the game view, exempt from pacing
    void (*SetToggleHandler)(void (*)()){nullptr};      // MSOverlaySetToggleHandler: the touch pad's "CET" button
    void (*SetCapture)(int){nullptr};                   // MSOverlaySetCapture: overlay open, touches and keys come to the monitor
    void (*ShowKeyboard)(int){nullptr};                 // MSOverlayShowKeyboard: the iPhone keyboard

    static const ShimOverlay& Get()
    {
        static const ShimOverlay s_shim = []
        {
            ShimOverlay shim;
            shim.RegisterLayer = reinterpret_cast<int (*)(void*)>(dlsym(RTLD_DEFAULT, "MSRegisterOverlayLayer"));
            shim.SetToggleHandler = reinterpret_cast<void (*)(void (*)())>(dlsym(RTLD_DEFAULT, "MSOverlaySetToggleHandler"));
            shim.SetCapture = reinterpret_cast<void (*)(int)>(dlsym(RTLD_DEFAULT, "MSOverlaySetCapture"));
            shim.ShowKeyboard = reinterpret_cast<void (*)(int)>(dlsym(RTLD_DEFAULT, "MSOverlayShowKeyboard"));
            return shim;
        }();
        return s_shim;
    }
};

// The touch pad's "CET" button (main thread): Overlay::Toggle only sets a flag the game thread acts on.
void OnShimToggle()
{
    if (CetMac::CetReady())
        CET::Get().GetOverlay().Toggle();
}

bool s_keyboardShown = false; // the iPhone keyboard was opened for a text field (game thread)

// The top edge of the iPhone keyboard (with the shim's key row above it) in screen points from the top; 0 while it is hidden.
std::atomic<float> s_keyboardTop{0.0f};

void WatchKeyboard()
{
    static bool s_watching = false;
    if (s_watching)
        return;
    s_watching = true;
    NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:UIKeyboardWillChangeFrameNotification
                        object:nullptr
                         queue:nullptr
                    usingBlock:^(NSNotification* aNote) {
                        const CGRect frame = [aNote.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
                        const CGFloat screenHeight = UIScreen.mainScreen.bounds.size.height;
                        const bool visible = frame.size.height > 0 && frame.origin.y < screenHeight - 1;
                        s_keyboardTop = visible ? static_cast<float>(frame.origin.y) : 0.0f;
                    }];
    [center addObserverForName:UIKeyboardDidHideNotification
                        object:nullptr
                         queue:nullptr
                    usingBlock:^(NSNotification*) {
                        s_keyboardTop = 0.0f;
                    }];
}

// While the keyboard covers the text field being typed in, its window moves up until the field shows; it moves back when the
// keyboard closes. Call between NewFrame and the windows' Begin. aKeyboardTop: overlay pixels from the top, 0 = hidden.
void AvoidKeyboard(float aKeyboardTop)
{
    static ImGuiID s_movedWindow = 0;
    static float s_movedBy = 0.0f;

    ImGuiContext& g = *ImGui::GetCurrentContext();
    auto restore = [&]
    {
        if (s_movedBy > 0.0f)
        {
            if (ImGuiWindow* window = ImGui::FindWindowByID(s_movedWindow))
                ImGui::SetWindowPos(window, ImVec2(window->Pos.x, window->Pos.y + s_movedBy), ImGuiCond_Always);
        }
        s_movedWindow = 0;
        s_movedBy = 0.0f;
    };

    if (aKeyboardTop <= 0.0f)
    {
        restore();
        return;
    }
    // the caret of the text field that was active in the frame just built
    if (!g.PlatformImeDataPrev.WantVisible || !g.ActiveIdWindow || !g.ActiveIdWindow->RootWindow)
        return;
    ImGuiWindow* root = g.ActiveIdWindow->RootWindow;
    if (root->DockIsActive)
        return;
    const float fieldBottom = g.PlatformImeDataPrev.InputPos.y + g.PlatformImeDataPrev.InputLineHeight + 2.0f * g.Style.FramePadding.y;
    const float cover = fieldBottom - aKeyboardTop;
    if (cover <= 1.0f)
        return;
    if (s_movedWindow != root->ID)
        restore();
    ImGui::SetWindowPos(root, ImVec2(root->Pos.x, root->Pos.y - cover), ImGuiCond_Always);
    s_movedWindow = root->ID;
    s_movedBy += cover;
}

// Sizes for fingers instead of a mouse pointer, on top of CET's scaled style. aPoint: overlay pixels per screen point.
void ApplyTouchStyle(float aPoint, float aUIScale)
{
    const float unit = aPoint * aUIScale;
    auto& style = ImGui::GetStyle();
    style.FramePadding = ImVec2(6.0f * unit, 5.0f * unit);
    style.ItemSpacing = ImVec2(6.0f * unit, 5.0f * unit);
    style.ItemInnerSpacing = ImVec2(5.0f * unit, 4.0f * unit);
    style.TouchExtraPadding = ImVec2(3.0f * unit, 3.0f * unit);
    style.ScrollbarSize = 16.0f * unit;
    style.GrabMinSize = 14.0f * unit;
    style.WindowMinSize = ImVec2(80.0f * unit, 60.0f * unit);
}
#else
// The Windows build shows the cursor through the game's input system (InputSystemWin32Base::ForceCursor, a CName reason and a flag).
// On macOS the cursor is shown and released through AppKit while the overlay is open, and put back as it was when it closes.
struct CursorFallback
{
    bool Active{false};
    bool WasHidden{false};

    // The game view keeps the cursor state itself (macos/PLATFORM_SURVEY.md): -[GameView ShowCursor] clears its hidden flag and
    // re-associates the mouse; -[GameView HideCursor] hides and captures it again. While the overlay is open CET's monitor keeps the
    // mouse events from the view, so the view's mouseMoved:/mouseDown: (the code that would hide and re-centre it) do not run.
    static bool ViewHidesCursor(NSView* aView)
    {
        SEL getter = NSSelectorFromString(@"cursorIsHidden");
        if (aView && [aView respondsToSelector:getter])
            return ((BOOL(*)(id, SEL))objc_msgSend)(aView, getter);
        return !CGCursorIsVisible();
    }

    static void Call(NSView* aView, NSString* aName)
    {
        SEL sel = NSSelectorFromString(aName);
        if (aView && [aView respondsToSelector:sel])
            ((void (*)(id, SEL))objc_msgSend)(aView, sel);
    }

    void Apply(NSView* aView, bool aShow)
    {
        RunOnMainAsync(^{
            const bool hasView = aView && [aView respondsToSelector:NSSelectorFromString(@"ShowCursor")];
            if (aShow && !Active)
            {
                WasHidden = ViewHidesCursor(aView);
                if (WasHidden)
                {
                    if (hasView)
                        Call(aView, @"ShowCursor");
                    else
                    {
                        CGAssociateMouseAndMouseCursorPosition(true);
                        [NSCursor unhide];
                    }
                }
                Active = true;
                Log::Info("[cet] cursor: overlay open, the game had it {}; {}; now hidden by the view: {}, visible on screen: {}",
                          WasHidden ? "hidden" : "shown", WasHidden ? (hasView ? "GameView ShowCursor" : "AppKit unhide") : "left as it was",
                          ViewHidesCursor(aView), static_cast<bool>(CGCursorIsVisible()));
            }
            else if (!aShow && Active)
            {
                if (WasHidden)
                {
                    if (hasView)
                        Call(aView, @"HideCursor");
                    else
                    {
                        [NSCursor hide];
                        CGAssociateMouseAndMouseCursorPosition(false);
                    }
                }
                Active = false;
                Log::Info("[cet] cursor: overlay closed; {}; now hidden by the view: {}, visible on screen: {}",
                          WasHidden ? (hasView ? "GameView HideCursor" : "AppKit hide") : "left as it was", ViewHidesCursor(aView),
                          static_cast<bool>(CGCursorIsVisible()));
            }
        });
    }
};
CursorFallback s_cursorFallback;
#endif // CET_IOS
} // namespace

D3D12::D3D12(Window& aWindow, Paths& aPaths, Options& aOptions)
    : m_paths(aPaths)
    , m_window(aWindow)
    , m_options(aOptions)
{
    // As on Windows: a repeated game-thread task builds each ImGui frame. On macOS it also renders it (no present hook).
    GameMainThread::Get().AddGenericTask(
        [this]
        {
            PrepareUpdate();
            return false;
        });
}

D3D12::~D3D12()
{
    ResetState(true);
}

void D3D12::SetTrapInputInImGui(const bool acEnabled)
{
    // Windows calls the game's InputSystemWin32Base::ForceCursor on CGameEngine::unkD0. On macOS the engine global is not mapped and
    // the game view hides the cursor itself (macos/PLATFORM_SURVEY.md), so the cursor is shown and released through AppKit while the
    // overlay is open and put back as it was when it closes.
#if CET_IOS
    // iOS: the shim hides its touch pad and sends every touch, mouse event and key to CET's monitor while the overlay is open.
    const auto& shim = ShimOverlay::Get();
    if (shim.SetCapture)
        shim.SetCapture(acEnabled ? 1 : 0);
    if (!acEnabled && s_keyboardShown)
    {
        s_keyboardShown = false;
        if (shim.ShowKeyboard)
            shim.ShowKeyboard(0);
    }
#else
    s_cursorFallback.Apply((__bridge NSView*)m_window.GetView(), acEnabled);
#endif

    m_trapInputInImGui = acEnabled;
}

void D3D12::DelayedSetTrapInputInImGui(const bool acEnabled)
{
    m_delayedTrapInputState = acEnabled;
    m_delayedTrapInput = true;
}

void* D3D12::GetDevice() const
{
    return m_device;
}

bool D3D12::ResetState(const bool acDestroyContext)
{
    if (m_initialized)
    {
        std::lock_guard _(m_imguiLock);
        ImGui_ImplMetal_Shutdown();
        if (acDestroyContext)
            ImGui::DestroyContext();
    }

    void* layer = m_layer;
    m_layer = nullptr;
#if CET_IOS
    if (layer)
    {
        const auto& shim = ShimOverlay::Get();
        if (shim.SetToggleHandler)
            shim.SetToggleHandler(nullptr);
        if (shim.SetCapture)
            shim.SetCapture(0);
        if (shim.RegisterLayer)
            shim.RegisterLayer(nullptr);
    }
#endif
    if (layer)
    {
        RunOnMainAsync(^{
            CAMetalLayer* metalLayer = (__bridge_transfer CAMetalLayer*)layer;
            [metalLayer removeFromSuperlayer];
        });
    }
    if (m_commandQueue)
        CFRelease(m_commandQueue);
    if (m_device)
        CFRelease(m_device);
    m_commandQueue = m_device = nullptr;

    m_outSize = {0, 0};
    m_initialized = false;
    return false;
}

float D3D12::ScaleFromReference() const
{
#if CET_IOS
    // A phone: the text is sized in screen points, not against a 1080p desktop. With the default font size (18) and scales this is
    // about 14 pt text.
    return m_pointScale * 0.8f * m_options.Font.OverlayUIScale;
#else
    // TODO - scale also by DPI
    return std::min(static_cast<float>(m_outSize.cx) / 1920.0f, static_cast<float>(m_outSize.cy) / 1080.0f);
#endif
}

#if CET_IOS
bool D3D12::Initialize()
{
    if (m_initialized)
        return true;

    if (!m_window.IsInitialized())
        return false;

    const auto& shim = ShimOverlay::Get();
    if (!shim.RegisterLayer)
    {
        Log::Error("D3D12::Initialize() (iOS) - this CyPort app has no MSRegisterOverlayLayer (built without the CET overlay support); the overlay stays off");
        m_initFailed = true;
        return false;
    }

    // The screen in points times the overlay's pixels per point; PrepareUpdate follows the layer once the shim has laid it out.
    int32_t screenWidth = 0, screenHeight = 0;
    CetIOSScreenPixels(&screenWidth, &screenHeight);
    const float screenScale = CetIOSScreenScale();
    if (screenWidth <= 0 || screenHeight <= 0 || screenScale <= 0.0f)
        return false; // UIKit has not answered yet

    m_pointScale = std::min(m_options.Font.OverlayRenderScale, screenScale);
    const SIZE size{static_cast<LONG>(std::lround(screenWidth / screenScale * m_pointScale)),
                    static_cast<LONG>(std::lround(screenHeight / screenScale * m_pointScale))};

    __block void* device = nullptr;
    __block void* queue = nullptr;
    __block void* layer = nullptr;
    RunOnMainSync(^{
        id<MTLDevice> mtlDevice = MTLCreateSystemDefaultDevice();
        if (!mtlDevice)
            return;

        id<MTLCommandQueue> mtlQueue = [mtlDevice newCommandQueue];
        mtlQueue.label = @"CET overlay";

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        CAMetalLayer* metalLayer = [CAMetalLayer layer];
        metalLayer.name = @"CET overlay";
        metalLayer.device = mtlDevice;
        metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        metalLayer.framebufferOnly = YES;
        metalLayer.opaque = NO;
        metalLayer.maximumDrawableCount = 3;
        metalLayer.allowsNextDrawableTimeout = YES;
        metalLayer.drawableSize = CGSizeMake(1, 1); // no drawables until something is drawn (Render)
        metalLayer.hidden = YES;
        [CATransaction commit];

        device = (__bridge_retained void*)mtlDevice;
        queue = (__bridge_retained void*)mtlQueue;
        layer = (__bridge_retained void*)metalLayer;
        WatchKeyboard();
    });

    if (!layer)
    {
        Log::Error("D3D12::Initialize() (iOS) - could not create the Metal device, queue or overlay layer");
        m_initFailed = true;
        return false;
    }

    // before the first nextDrawable: the shim leaves this layer out of its frame pacing from here on
    shim.RegisterLayer(layer);

    m_device = device;
    m_commandQueue = queue;
    m_layer = layer;
    m_outSize = size;
    m_window.SetClientMetrics(size, m_pointScale);
    if (!m_inFlight)
        m_inFlight = (__bridge_retained void*)dispatch_semaphore_create(2);

    if (!InitializeImGui())
    {
        Log::Error("D3D12::Initialize() (iOS) - failed to initialize ImGui!");
        m_initFailed = true;
        return ResetState();
    }

    const auto* fonts = ImGui::GetIO().Fonts;
    Log::Info("D3D12::Initialize() (iOS) - Metal overlay layer {}x{} px ({:.2f} px per point, UI scale {:.2f}), font atlas {}x{} ({:.1f} MB), "
              "3 drawables of {:.1f} MB while visible; initialization successful!",
              size.cx, size.cy, m_pointScale, ScaleFromReference(), fonts->TexWidth, fonts->TexHeight,
              fonts->TexWidth * fonts->TexHeight * 4.0 / 1048576.0, size.cx * size.cy * 4.0 / 1048576.0);
    m_initialized = true;
    if (shim.SetToggleHandler)
        shim.SetToggleHandler(&OnShimToggle);
    OnInitialized.Emit();
    return true;
}
#else
bool D3D12::Initialize()
{
    if (m_initialized)
        return true;

    if (!m_window.IsInitialized())
        return false;

    const SIZE size = m_window.GetClientSize();
    if (size.cx <= 0 || size.cy <= 0)
        return false;

    __block bool created = false;
    __block void* device = nullptr;
    __block void* queue = nullptr;
    __block void* layer = nullptr;
    NSView* view = (__bridge NSView*)m_window.GetView();
    const float scale = m_window.GetBackingScale();
    RunOnMainSync(^{
        id<MTLDevice> mtlDevice = nullptr;
        if ([view.layer isKindOfClass:[CAMetalLayer class]])
            mtlDevice = ((CAMetalLayer*)view.layer).device;
        if (!mtlDevice)
            mtlDevice = MTLCreateSystemDefaultDevice();
        if (!mtlDevice || !view.layer)
            return;

        id<MTLCommandQueue> mtlQueue = [mtlDevice newCommandQueue];
        mtlQueue.label = @"CET overlay";

        CAMetalLayer* metalLayer = [CAMetalLayer layer];
        metalLayer.name = @"CET overlay";
        metalLayer.device = mtlDevice;
        metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        metalLayer.framebufferOnly = YES;
        metalLayer.opaque = NO;
        metalLayer.displaySyncEnabled = NO;
        metalLayer.maximumDrawableCount = 3;
        metalLayer.allowsNextDrawableTimeout = YES;
        metalLayer.contentsScale = scale;
        metalLayer.frame = view.layer.bounds;
        metalLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        metalLayer.drawableSize = CGSizeMake(size.cx, size.cy);
        metalLayer.zPosition = 1000.0;
        metalLayer.hidden = YES;
        [view.layer addSublayer:metalLayer];

        device = (__bridge_retained void*)mtlDevice;
        queue = (__bridge_retained void*)mtlQueue;
        layer = (__bridge_retained void*)metalLayer;
        created = true;
    });

    if (!created)
    {
        Log::Error("D3D12::Initialize() (macOS) - could not create the Metal device, queue or overlay layer");
        m_initFailed = true;
        return false;
    }

    m_device = device;
    m_commandQueue = queue;
    m_layer = layer;
    m_outSize = size;
    if (!m_inFlight)
        m_inFlight = (__bridge_retained void*)dispatch_semaphore_create(2);

    if (!InitializeImGui())
    {
        Log::Error("D3D12::Initialize() (macOS) - failed to initialize ImGui!");
        m_initFailed = true;
        return ResetState();
    }

    Log::Info("D3D12::Initialize() (macOS) - Metal overlay layer {}x{} px (scale {:.1f}) on the game view; initialization successful!", size.cx,
              size.cy, scale);
    m_initialized = true;
    OnInitialized.Emit();
    return true;
}

#endif // CET_IOS

void D3D12::ReloadFonts()
{
    std::lock_guard _(m_imguiLock);

    const auto scaleFromReference = ScaleFromReference();

    auto& io = ImGui::GetIO();
    io.Fonts->Clear();
#if CET_IOS
    io.Fonts->Flags |= ImFontAtlasFlags_NoPowerOfTwoHeight; // memory: the atlas is as high as its glyphs need
#endif

    ImFontConfig config;
    const auto& fontSettings = m_options.Font;
    config.SizePixels = std::floor(fontSettings.BaseSize * scaleFromReference);
    config.OversampleH = fontSettings.OversampleHorizontal;
    config.OversampleV = fontSettings.OversampleVertical;
    if (config.OversampleH == 1 && config.OversampleV == 1)
        config.PixelSnapH = true;
    config.MergeMode = false;

    // add default font
    const auto customFontPath = fontSettings.Path.empty() ? std::filesystem::path{} : GetAbsolutePath(fontSettings.Path, m_paths.Fonts(), false);
    auto cetFontPath = GetAbsolutePath(std::string("NotoSans-Regular.ttf"), m_paths.Fonts(), false);
    const auto* cpGlyphRanges = io.Fonts->GetGlyphRangesDefault();
    if (customFontPath.empty())
    {
        if (!fontSettings.Path.empty())
            Log::Warn("D3D12::ReloadFonts() - Custom font path is invalid! Using default CET font.");

        if (cetFontPath.empty())
        {
            Log::Warn("D3D12::ReloadFonts() - Missing default fonts!");
            io.Fonts->AddFontDefault(&config);
        }
        else
            io.Fonts->AddFontFromFileTTF(cetFontPath.c_str(), config.SizePixels, &config, cpGlyphRanges);
    }
    else
        io.Fonts->AddFontFromFileTTF(customFontPath.c_str(), config.SizePixels, &config, cpGlyphRanges);

    // the language font: from the settings, else from the system's preferred language (Windows: GetSystemDefaultLangID)
    std::string language = fontSettings.Language;
#if CET_IOS
    // iOS: Latin by default whatever the phone's language, and no CJK set at all: its atlas alone is tens to hundreds of MB of
    // texture, in a process that runs close to the memory limit.
    if (language == "ChineseFull" || language == "ChineseSimplifiedCommon" || language == "Japanese" || language == "Korean")
    {
        Log::Warn("D3D12::ReloadFonts() - the {} glyph set is not loaded on iOS (memory); using Latin.", language);
        language = "Default";
    }
    if (false)
#else
    if (language.empty() || language == "Default")
#endif
    {
        NSString* preferred = [NSLocale preferredLanguages].firstObject;
        const std::string code = preferred ? preferred.UTF8String : "";
        if (code.rfind("zh-Hant", 0) == 0 || code.rfind("zh-TW", 0) == 0 || code.rfind("zh-HK", 0) == 0)
            language = "ChineseFull";
        else if (code.rfind("zh", 0) == 0)
            language = "ChineseSimplifiedCommon";
        else if (code.rfind("ja", 0) == 0)
            language = "Japanese";
        else if (code.rfind("ko", 0) == 0)
            language = "Korean";
        else if (code.rfind("ru", 0) == 0 || code.rfind("be", 0) == 0)
            language = "Cyrillic";
        else if (code.rfind("th", 0) == 0)
            language = "Thai";
        else if (code.rfind("vi", 0) == 0)
            language = "Vietnamese";
    }
    if (language == "ChineseFull")
    {
        cetFontPath = GetAbsolutePath(std::string("NotoSansTC-Regular.otf"), m_paths.Fonts(), false);
        cpGlyphRanges = io.Fonts->GetGlyphRangesChineseFull();
    }
    else if (language == "ChineseSimplifiedCommon")
    {
        cetFontPath = GetAbsolutePath(std::string("NotoSansSC-Regular.otf"), m_paths.Fonts(), false);
        cpGlyphRanges = io.Fonts->GetGlyphRangesChineseSimplifiedCommon();
    }
    else if (language == "Japanese")
    {
        cetFontPath = GetAbsolutePath(std::string("NotoSansJP-Regular.otf"), m_paths.Fonts(), false);
        cpGlyphRanges = io.Fonts->GetGlyphRangesJapanese();
    }
    else if (language == "Korean")
    {
        cetFontPath = GetAbsolutePath(std::string("NotoSansKR-Regular.otf"), m_paths.Fonts(), false);
        cpGlyphRanges = io.Fonts->GetGlyphRangesKorean();
    }
    else if (language == "Cyrillic")
    {
        cetFontPath = GetAbsolutePath(std::string("NotoSans-Regular.ttf"), m_paths.Fonts(), false);
        cpGlyphRanges = io.Fonts->GetGlyphRangesCyrillic();
    }
    else if (language == "Thai")
    {
        cetFontPath = GetAbsolutePath(std::string("NotoSansThai-Regular.ttf"), m_paths.Fonts(), false);
        cpGlyphRanges = io.Fonts->GetGlyphRangesThai();
    }
    else if (language == "Vietnamese")
    {
        cetFontPath = GetAbsolutePath(std::string("NotoSans-Regular.ttf"), m_paths.Fonts(), false);
        cpGlyphRanges = io.Fonts->GetGlyphRangesVietnamese();
    }

    // add extra glyphs from language font
    config.MergeMode = true;
    if (customFontPath.empty())
    {
        if (cetFontPath.empty())
        {
            Log::Warn("D3D12::ReloadFonts() - Missing fonts for extra language glyphs!");
            io.Fonts->AddFontDefault(&config);
        }
        else
            io.Fonts->AddFontFromFileTTF(cetFontPath.c_str(), config.SizePixels, &config, cpGlyphRanges);
    }
    else
        io.Fonts->AddFontFromFileTTF(customFontPath.c_str(), config.SizePixels, &config, cpGlyphRanges);

    // add icons from fontawesome4
    config.GlyphMinAdvanceX = config.SizePixels;
#if CET_IOS
    // about 7400 icons: no oversampling (ImGui's own rasterizer honours it, FreeType on the desktop does not), a third of the atlas
    config.OversampleH = config.OversampleV = 1;
    config.PixelSnapH = true;
#endif
    static const ImWchar icon_ranges[] = {ICON_MIN_MD, ICON_MAX_MD, 0};
    auto cetIconPath = GetAbsolutePath(std::string("materialdesignicons.ttf"), m_paths.Fonts(), false);
    if (!cetIconPath.empty())
        io.Fonts->AddFontFromFileTTF(cetIconPath.c_str(), config.SizePixels, &config, icon_ranges);
}

bool D3D12::InitializeImGui()
{
    std::lock_guard _(m_imguiLock);

    const auto scaleFromReference = ScaleFromReference();

    if (ImGui::GetCurrentContext() == nullptr)
    {
        // do this once, do not repeat context creation!
        IMGUI_CHECKVERSION();
        ImGui::CreateContext();

        // TODO - make this configurable eventually and overridable by mods for themselves easily
        // setup CET default style
        ImGui::StyleColorsDark(&m_styleReference);
        m_styleReference.WindowRounding = 6.0f;
        m_styleReference.WindowTitleAlign.x = 0.5f;
        m_styleReference.ChildRounding = 6.0f;
        m_styleReference.PopupRounding = 6.0f;
        m_styleReference.FrameRounding = 6.0f;
        m_styleReference.ScrollbarRounding = 12.0f;
        m_styleReference.GrabRounding = 12.0f;
        m_styleReference.TabRounding = 6.0f;
    }

    ImGui::GetStyle() = m_styleReference;
    ImGui::GetStyle().ScaleAllSizes(scaleFromReference);
#if CET_IOS
    ApplyTouchStyle(m_pointScale, m_options.Font.OverlayUIScale);
#endif

    auto& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange; // Do not modify cursor from ImGui backend
#if CET_IOS
    io.BackendPlatformName = "cet_ios";
#else
    io.BackendPlatformName = "cet_macos";
#endif
    // ImGui sizes are in pixels as on Windows (the drawable is the view size times the backing scale), so CET's 1080p-relative scaling
    // gives the same layout at the same resolution.
    io.DisplayFramebufferScale = ImVec2(1.0f, 1.0f);

    static std::string s_layoutPath;
    s_layoutPath = GetAbsolutePath(std::string("layout.ini"), m_paths.CETRoot(), true).string();
    io.IniFilename = s_layoutPath.c_str();

    if (!ImGui_ImplMetal_Init((__bridge id<MTLDevice>)m_device))
    {
        Log::Error("D3D12::InitializeImGui() - ImGui_ImplMetal_Init call failed!");
        return false;
    }

    ReloadFonts();

    if (!ImGui_ImplMetal_CreateDeviceObjects((__bridge id<MTLDevice>)m_device))
    {
        Log::Error("D3D12::InitializeImGui() - ImGui_ImplMetal_CreateDeviceObjects call failed!");
        ImGui_ImplMetal_Shutdown();
        return false;
    }
#if CET_IOS
    io.Fonts->ClearTexData(); // the pixels are in the Metal texture now
#endif

    return true;
}

void D3D12::PrepareUpdate()
{
    if (!m_initialized)
    {
        if (m_initFailed || !Initialize())
        {
#if CET_IOS
            // no overlay (yet): mod hotkeys still get their keys, as in the headless build
            if (m_window.IsInitialized() && CetMac::CetReady())
            {
                static std::vector<MacInputEvent> s_early;
                s_early.clear();
                m_window.DrainInput(s_early);
                auto& earlyBindings = CET::Get().GetBindings();
                for (const auto& e : s_early)
                {
                    if (e.EventType == MacInputEvent::Type::KeyDown || e.EventType == MacInputEvent::Type::KeyUp)
                    {
                        if (e.VKCode != 0)
                            earlyBindings.OnMacKey(e.VKCode, e.EventType == MacInputEvent::Type::KeyDown);
                    }
                    else if (e.EventType == MacInputEvent::Type::MouseDown || e.EventType == MacInputEvent::Type::MouseUp)
                        earlyBindings.OnMacKey(e.VKCode, e.EventType == MacInputEvent::Type::MouseDown);
                }
            }
#endif
            return;
        }
    }

    std::lock_guard _(m_imguiLock);

#if CET_IOS
    // the game view changed size (rotation, a TV connected): the shim keeps the layer the view's size; follow it
    SIZE size = m_outSize;
    {
        const CGSize bounds = ((__bridge CAMetalLayer*)m_layer).bounds.size; // points
        if (bounds.width >= 1 && bounds.height >= 1)
            size = {static_cast<LONG>(std::lround(bounds.width * m_pointScale)), static_cast<LONG>(std::lround(bounds.height * m_pointScale))};
    }
    if (size.cx != m_outSize.cx || size.cy != m_outSize.cy)
    {
        Log::Info("D3D12 (iOS) - overlay resized to {}x{} px", size.cx, size.cy);
        m_outSize = size;
        m_window.SetClientMetrics(size, m_pointScale);
        if (m_layerVisible)
        {
            void* layer = m_layer;
            RunOnMainAsync(^{
                ((__bridge CAMetalLayer*)layer).drawableSize = CGSizeMake(size.cx, size.cy);
            });
        }
    }
#else
    // the game view changed size (window mode, fullscreen, display): resize the layer, rescale the style and rebuild the fonts
    const SIZE size = m_window.GetClientSize();
    if (size.cx > 0 && size.cy > 0 && (size.cx != m_outSize.cx || size.cy != m_outSize.cy))
    {
        Log::Info("D3D12 (macOS) - game view resized to {}x{} px", size.cx, size.cy);
        m_outSize = size;
        void* layer = m_layer;
        const float scale = m_window.GetBackingScale();
        RunOnMainAsync(^{
            CAMetalLayer* metalLayer = (__bridge CAMetalLayer*)layer;
            metalLayer.contentsScale = scale;
            metalLayer.drawableSize = CGSizeMake(size.cx, size.cy);
        });
        const auto scaleFromReference = ScaleFromReference();
        ImGui::GetStyle() = m_styleReference;
        ImGui::GetStyle().ScaleAllSizes(scaleFromReference);
        ImGui_ImplMetal_DestroyFontsTexture();
        ReloadFonts();
        ImGui_ImplMetal_CreateFontsTexture((__bridge id<MTLDevice>)m_device);
    }
#endif

    if (m_delayedTrapInput)
    {
        SetTrapInputInImGui(m_delayedTrapInputState);
        m_delayedTrapInput = false;
    }

    // input queued by the AppKit monitor: ImGui gets it always (it only acts on it while a window wants it), VKBindings gets keys and
    // buttons as it gets raw input on Windows
    static std::vector<MacInputEvent> s_events;
    s_events.clear();
    m_window.DrainInput(s_events);
#if CET_IOS
    int hoverMoves = 0; // moves with no button held: a mouse sends them all the time, a finger one per tap
#endif
    auto& io = ImGui::GetIO();
    auto& bindings = CET::Get().GetBindings();
    for (const auto& e : s_events)
    {
        switch (e.EventType)
        {
        case MacInputEvent::Type::KeyDown:
        case MacInputEvent::Type::KeyUp:
        {
            const bool down = e.EventType == MacInputEvent::Type::KeyDown;
            io.AddKeyEvent(ImGuiMod_Shift, e.Shift);
            io.AddKeyEvent(ImGuiMod_Ctrl, e.Ctrl);
            io.AddKeyEvent(ImGuiMod_Alt, e.Alt);
            io.AddKeyEvent(ImGuiMod_Super, e.Super);
            if (e.ImGuiKeyCode != ImGuiKey_None)
                io.AddKeyEvent(static_cast<ImGuiKey>(e.ImGuiKeyCode), down);
            if (e.VKCode != 0)
                bindings.OnMacKey(e.VKCode, down);
            break;
        }
        case MacInputEvent::Type::Text: io.AddInputCharacter(e.Character); break;
#if CET_IOS
        // fractions of the game view (window_ios.mm)
        case MacInputEvent::Type::MouseMove:
            io.AddMousePosEvent(e.X * static_cast<float>(m_outSize.cx), e.Y * static_cast<float>(m_outSize.cy));
            hoverMoves += e.MouseButton;
            break;
#else
        case MacInputEvent::Type::MouseMove: io.AddMousePosEvent(e.X, e.Y); break;
#endif
        case MacInputEvent::Type::MouseDown:
        case MacInputEvent::Type::MouseUp:
        {
            const bool down = e.EventType == MacInputEvent::Type::MouseDown;
            io.AddMouseButtonEvent(e.MouseButton, down);
            bindings.OnMacKey(e.VKCode, down);
            break;
        }
        case MacInputEvent::Type::Wheel:
#if CET_IOS
        {
            // points of finger movement (window_ios.mm) to wheel steps: ImGui scrolls 5 text lines per step, so the list follows
            // the finger
            const float fontSize = io.Fonts->Fonts.empty() ? 18.0f : io.Fonts->Fonts[0]->FontSize * io.FontGlobalScale;
            const float perPoint = m_pointScale / (5.0f * std::max(fontSize, 1.0f));
            io.AddMouseWheelEvent(e.WheelX * perPoint, e.WheelY * perPoint);
        }
#else
            io.AddMouseWheelEvent(e.WheelX, e.WheelY);
#endif
            if (e.WheelY != 0.0f)
                bindings.OnMacWheel(e.WheelY > 0.0f ? 1 : -1);
            if (e.WheelX != 0.0f)
                bindings.OnMacWheel(e.WheelX > 0.0f ? 2 : -2);
            break;
        case MacInputEvent::Type::FocusLost:
            io.AddFocusEvent(false);
            bindings.OnMacFocusLost();
            break;
        }
    }

    static auto s_lastFrame = std::chrono::steady_clock::now();
    const auto now = std::chrono::steady_clock::now();
    const float delta = std::chrono::duration<float>(now - s_lastFrame).count();
    s_lastFrame = now;
    io.DisplaySize = ImVec2(static_cast<float>(m_outSize.cx), static_cast<float>(m_outSize.cy));
    io.DeltaTime = delta > 0.0f ? delta : 1.0f / 60.0f;
#if CET_IOS
    {
        // A mouse (Bluetooth, through the shim) has no system pointer over the game: ImGui draws one while a mouse is moving and
        // the overlay is open, and for 5 seconds after. Fingers get none.
        static int s_hoverFrames = 0;
        static auto s_pointerUntil = now;
        s_hoverFrames = hoverMoves > 0 ? s_hoverFrames + 1 : 0;
        if (hoverMoves >= 2 || s_hoverFrames >= 3)
            s_pointerUntil = now + std::chrono::seconds(5);
        io.MouseDrawCursor = m_trapInputInImGui && now < s_pointerUntil;
    }
#endif

    ImGui::NewFrame();

#if CET_IOS
    {
        // The iPhone keyboard: opened a moment after a tap that left a text field active, closed when no text field wants input any
        // more. (The pad's keyboard button opens and closes it at any time.)
        static int s_framesSinceTap = 1000;
        s_framesSinceTap = io.MouseReleased[0] ? 0 : std::min(s_framesSinceTap + 1, 1000);
        const bool wantsText = m_trapInputInImGui && io.WantTextInput;
        AvoidKeyboard(m_trapInputInImGui ? s_keyboardTop.load() * m_pointScale : 0.0f);
        const auto& shim = ShimOverlay::Get();
        if (shim.ShowKeyboard)
        {
            if (wantsText && s_framesSinceTap == 3)
            {
                shim.ShowKeyboard(1);
                s_keyboardShown = true;
            }
            else if (!wantsText && s_keyboardShown)
            {
                shim.ShowKeyboard(0);
                s_keyboardShown = false;
            }
        }
    }
#endif

    CET::Get().GetOverlay().Update();

    CET::Get().GetVM().Draw();

    ImGui::Render();
    ++m_framesBuilt;

    Render();
}

void D3D12::Render()
{
    ImDrawData* drawData = ImGui::GetDrawData();
    const bool needed = CET::Get().GetOverlay().IsEnabled() || (drawData && drawData->TotalVtxCount > 0);

    CAMetalLayer* layer = (__bridge CAMetalLayer*)m_layer;
    if (!needed)
    {
        if (m_layerVisible.exchange(false))
        {
            RunOnMainAsync(^{
                layer.hidden = YES;
#if CET_IOS
                layer.drawableSize = CGSizeMake(1, 1); // gives the drawables back while nothing is drawn
#endif
            });
        }
        return;
    }

#if CET_IOS
    // Something to draw again: full-size drawables first, then the layer is shown. Frames are skipped until the layer hands out
    // drawables of the right size (below).
    if (!m_layerVisible.exchange(true))
    {
        const SIZE size = m_outSize;
        RunOnMainAsync(^{
            layer.drawableSize = CGSizeMake(size.cx, size.cy);
            layer.hidden = NO;
        });
        return;
    }
#endif

    dispatch_semaphore_t inFlight = (__bridge dispatch_semaphore_t)m_inFlight;
    if (dispatch_semaphore_wait(inFlight, DISPATCH_TIME_NOW) != 0)
        return; // two frames still on the GPU: skip this one rather than block the game thread

    @autoreleasepool
    {
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (!drawable)
        {
            dispatch_semaphore_signal(inFlight);
            return;
        }
#if CET_IOS
        // a resize (or the first frame after the layer was hidden) has not reached the layer yet: ImGui's scissor rectangles would
        // not fit this texture
        if (drawable.texture.width != static_cast<NSUInteger>(m_outSize.cx) || drawable.texture.height != static_cast<NSUInteger>(m_outSize.cy))
        {
            dispatch_semaphore_signal(inFlight);
            return;
        }
#endif

        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)m_commandQueue;
        id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
        commandBuffer.label = @"CET overlay";

        ImGui_ImplMetal_NewFrame(pass);
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
        encoder.label = @"CET ImGui";
        ImGui_ImplMetal_RenderDrawData(drawData, commandBuffer, encoder);
        [encoder endEncoding];

        [commandBuffer presentDrawable:drawable];
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer>) {
            dispatch_semaphore_signal(inFlight);
        }];
        [commandBuffer commit];
    }
    ++m_framesPresented;

    if (!m_layerVisible.exchange(true))
    {
        RunOnMainAsync(^{
            layer.hidden = NO;
        });
    }
}

// Texture.cpp (Lua ImGui images): an RGBA8 texture with the decoded pixels, retained for the caller. ImGui's Metal backend draws it
// when the id<MTLTexture> is passed as the ImTextureID.
void* CetMacCreateRGBA8Texture(void* apDevice, const unsigned char* apPixels, int aWidth, int aHeight)
{
    id<MTLDevice> device = (__bridge id<MTLDevice>)apDevice;
    if (!device || !apPixels || aWidth <= 0 || aHeight <= 0)
        return nullptr;

    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                          width:static_cast<NSUInteger>(aWidth)
                                                                                         height:static_cast<NSUInteger>(aHeight)
                                                                                      mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (!texture)
        return nullptr;
    [texture replaceRegion:MTLRegionMake2D(0, 0, static_cast<NSUInteger>(aWidth), static_cast<NSUInteger>(aHeight))
               mipmapLevel:0
                 withBytes:apPixels
               bytesPerRow:static_cast<NSUInteger>(aWidth) * 4];
    return (__bridge_retained void*)texture;
}

void CetMacReleaseTexture(void* apTexture)
{
    if (apTexture)
        CFRelease(apTexture);
}
