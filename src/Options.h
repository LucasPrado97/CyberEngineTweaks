#pragma once

#include "Image.h"

struct Paths;

struct PatchesSettings
{
    void Load(const nlohmann::json& aConfig);
    nlohmann::json Save() const;
    void ResetToDefaults();

    [[nodiscard]] auto operator<=>(const PatchesSettings&) const = default;

    bool AsyncCompute{false};
    bool Antialiasing{false};
    bool DisableVignette{false};
    bool DisableBoundaryTeleport{false};
    bool DisableWin7Vsync{false};
};

struct FontSettings
{
    void Load(const nlohmann::json& aConfig);
    nlohmann::json Save() const;
    void ResetToDefaults();

    [[nodiscard]] auto operator<=>(const FontSettings&) const = default;

    std::string Path{};
    std::string Language{"Default"};
    float BaseSize{18.0f};
    int32_t OversampleHorizontal{3};
    int32_t OversampleVertical{1};
    // iOS overlay only ("ios_render_scale", "ios_ui_scale" in config.json): the overlay's pixels per screen point (1 to 3; the phone
    // has 3, fewer cost less memory) and a factor on the size of the text and controls (0.5 to 2).
    float OverlayRenderScale{1.5f};
    float OverlayUIScale{1.0f};
};

struct DeveloperSettings
{
    void Load(const nlohmann::json& aConfig);
    nlohmann::json Save() const;
    void ResetToDefaults();

    [[nodiscard]] auto operator<=>(const DeveloperSettings&) const = default;

    bool RemoveDeadBindings{true};
    bool EnableImGuiAssertions{false};
    bool DumpGameOptions{false};
    uint64_t MaxLinesConsoleHistory{1000};
    bool PersistentConsole{true};
    bool EnableJIT{true};
};

struct Options
{
    Options(Paths& aPaths);
    ~Options() = default;

    void Load();
    void Save() const;
    void ResetToDefaults();

    Image GameImage;
    bool ExeValid{false};

    PatchesSettings Patches{};
    FontSettings Font{};
    DeveloperSettings Developer{};

private:
    Paths& m_paths;
};
