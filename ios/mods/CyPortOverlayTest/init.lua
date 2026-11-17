-- CyPortOverlayTest: checks the Cyber Engine Tweaks overlay on CyPort (iOS): drawing, touch, the keyboard and the overlay events.
-- Open the overlay with the touch pad's CET button (or F11). A window "CyPort overlay test" appears next to CET's own windows.
-- Lines in bin/x64/plugins/cyber_engine_tweaks/scripting.log: "overlay open", "overlay closed", "button tapped N".

local state = { open = false, taps = 0, text = "", value = 0.5, check = false, frames = 0 }

local function say(text)
    print("[CyPortOverlayTest] " .. text)
end

registerForEvent("onInit", function()
    local width, height = GetDisplayResolution()
    say(string.format("onInit: overlay %dx%d px", width, height))
end)

registerForEvent("onOverlayOpen", function()
    state.open = true
    say("overlay open")
end)

registerForEvent("onOverlayClose", function()
    state.open = false
    say("overlay closed")
end)

registerForEvent("onDraw", function()
    state.frames = state.frames + 1
    if not state.open then
        return
    end

    local width, height = GetDisplayResolution()
    ImGui.SetNextWindowPos(width * 0.05, height * 0.42, ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowSize(width * 0.42, height * 0.54, ImGuiCond.FirstUseEver)
    if ImGui.Begin("CyPort overlay test") then
        ImGui.Text(string.format("overlay %dx%d px, frame %d", width, height, state.frames))
        if ImGui.Button("Tap me") then
            state.taps = state.taps + 1
            say("button tapped " .. state.taps)
        end
        ImGui.SameLine()
        ImGui.Text("taps: " .. state.taps)
        state.check = ImGui.Checkbox("checkbox", state.check)
        state.value = ImGui.SliderFloat("slider", state.value, 0.0, 1.0)
        ImGui.Text("hold a finger still, then drag: slider, window")
        state.text = ImGui.InputText("text", state.text, 100)
        ImGui.Text(IconGlyphs.Check .. " drag a finger over this list: it scrolls")
        if ImGui.BeginChild("list", 0, 0, true) then
            for i = 1, 40 do
                ImGui.Text("line " .. i)
            end
        end
        ImGui.EndChild()
    end
    ImGui.End()
end)

say("loaded")
