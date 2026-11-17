#include <stdafx.h>

#include "Widget.h"

#include <CET.h>

Widget::Widget(const std::string& acpName, bool aOwnerDraw)
    : m_name(acpName)
    , m_ownerDraw(aOwnerDraw)
{
}

WidgetResult Widget::OnEnable()
{
    m_enabled = true;
    return WidgetResult::ENABLED;
}

WidgetResult Widget::OnDisable()
{
    m_enabled = false;
    return WidgetResult::DISABLED;
}

bool Widget::IsEnabled() const
{
    return m_enabled;
}

void Widget::Toggle()
{
    m_toggle = true;
}

WidgetResult Widget::OnPopup()
{
    return m_enabled ? WidgetResult::DISABLED : WidgetResult::ENABLED;
}

void Widget::OnToggle()
{
    if (m_enabled)
    {
        const auto ret = OnDisable();
        if (ret == WidgetResult::CANCEL)
        {
            m_toggle = false;
        }
        if (ret == WidgetResult::DISABLED)
        {
            m_enabled = false;
            m_toggle = false;
        }
    }
    else
    {
        const auto ret = OnEnable();
        if (ret == WidgetResult::CANCEL)
        {
            m_toggle = false;
        }
        if (ret == WidgetResult::ENABLED)
        {
            m_enabled = true;
            m_toggle = false;
        }
    }
}

void Widget::Draw()
{
    if (m_drawPopup)
    {
        CET::Get().GetVM().BlockDraw(true);
        m_drawPopup = OnPopup() == WidgetResult::ENABLED;
        if (!m_drawPopup)
        {
            CET::Get().GetVM().BlockDraw(false);
            ImGui::CloseCurrentPopup();
        }
    }

    if (m_toggle)
        OnToggle();

    if (!m_enabled)
        return;

    bool newEnabled = m_enabled;

    if (m_ownerDraw)
        OnUpdate();
    else
    {
        const auto [width, height] = CET::Get().GetD3D12().GetResolution();
#if CET_IOS
        // a phone: under the toolbar, most of the screen
        ImGui::SetNextWindowPos(ImVec2(width * 0.1f, height * 0.4f), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSize(ImVec2(width * 0.8f, height * 0.56f), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSizeConstraints(ImVec2(width * 0.3f, height * 0.3f), ImVec2(FLT_MAX, FLT_MAX));
#else
        ImGui::SetNextWindowPos(ImVec2(width * 0.2f, height * 0.2f), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSize(ImVec2(width * 0.6f, height * 0.6f), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSizeConstraints(ImVec2(420, 315), ImVec2(FLT_MAX, FLT_MAX));
#endif
        if (ImGui::Begin(m_name.c_str(), &newEnabled))
            OnUpdate();
        ImGui::End();
    }

    if (!newEnabled)
    {
        Toggle();
        OnToggle();
    }
}
