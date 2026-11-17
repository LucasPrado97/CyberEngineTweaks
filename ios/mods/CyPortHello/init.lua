-- CyPortHello: the smallest check that Cyber Engine Tweaks runs mods on CyPort (iOS).
-- Where to look after starting the game and loading a save:
--   bin/x64/plugins/cyber_engine_tweaks/scripting.log                          (print)
--   bin/x64/plugins/cyber_engine_tweaks/mods/CyPortHello/CyPortHello.log       (spdlog)
-- Expected lines: "loaded" when the scripts load, "onInit" once the player exists, "first onUpdate" on the next frame,
-- "PlayerPuppet:OnAction observed" on the first input, "PlayerPuppet:OnGameAttached observed" when a save is loaded after that.

local CyPortHello = { updates = 0, sawUpdate = false, sawAction = false, sawAttached = false }

local function say(text)
    print("[CyPortHello] " .. text)
    spdlog.info(text)
end

say("loaded (init.lua ran, CET " .. tostring(GetVersion()) .. ")")

registerForEvent("onInit", function()
    say("onInit: the Lua API is up")

    -- A script function the game calls on every input action: proves Observe on the game's own calls.
    Observe("PlayerPuppet", "OnAction", function()
        if not CyPortHello.sawAction then
            CyPortHello.sawAction = true
            say("PlayerPuppet:OnAction observed (Observe works)")
        end
    end)

    -- Called when the player enters the world: fires on the next save load (the first attach is before onInit).
    Observe("PlayerPuppet", "OnGameAttached", function()
        if not CyPortHello.sawAttached then
            CyPortHello.sawAttached = true
            say("PlayerPuppet:OnGameAttached observed")
        end
    end)
end)

registerForEvent("onUpdate", function(delta)
    CyPortHello.updates = CyPortHello.updates + 1
    if not CyPortHello.sawUpdate then
        CyPortHello.sawUpdate = true
        say(string.format("first onUpdate (delta %.4f s)", delta))
    end
end)

registerForEvent("onShutdown", function()
    say("onShutdown after " .. CyPortHello.updates .. " updates")
end)

return CyPortHello
