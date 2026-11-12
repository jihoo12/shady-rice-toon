-- Driver for capture.sh: Toon's runtime layer (Tide's) and shell with three
-- terminals in the strip, then the stills. CAPTURE_MODE=sky takes only the
-- empty desktop, for the hours of the sky.
shady.base("toon")

local out = assert(os.getenv("CAPTURE_OUT"))
local mode = os.getenv("CAPTURE_MODE") or "tour"
local auto = shady.automation
local after = auto.after
local L = shady.layout

local ini = os.getenv("CAPTURE_FOOT_INI")
local function term(id, title, script)
    shady.spawn(string.format("foot --config=%q --app-id=%s --title=%q sh -c %q",
        ini, id, title, script .. "; sleep 3600"))
end

local function sequence(steps)
    local function run(i) if steps[i] then steps[i](function() run(i + 1) end) end end
    run(1)
end
local function wait(ms) return function(k) after(ms, k) end end
local function shoot(name)
    return function(k)
        auto.screenshot(out .. "/" .. name .. ".png", function(ok)
            assert(ok, "screenshot failed: " .. name)
            k()
        end)
    end
end
local function act(fn) return function(k) fn(); k() end end
local serial = 100
local function tide(action) serial = serial + 1; shady.publish("tide.do", action .. " " .. serial) end
local function notify(summary, body)
    shady.spawn(string.format(
        "busctl --user call org.freedesktop.Notifications /org/freedesktop/Notifications "
        .. "org.freedesktop.Notifications Notify susssasa{sv}i Calendar 0 '' %q %q 0 0 8000",
        summary, body))
end

auto.move_pointer(1279, 719)
shady.spawn(string.format("%q", assert(os.getenv("SHADY_SHELL_BIN"))))

if mode == "sky" then
    after(4500, function()
        sequence { shoot("sky"), function() shady.quit() end }
    end)
    after(30000, function() shady.quit() end)
    return
end

after(700, function() term("notes", "notes", "printf '\\n  toon\\n\\n  everything is a sticker\\n'") end)
after(1200, function() term("build", "build", "printf '\\n  $ ninja -C build\\n  [312/312] Linking target shady\\n\\n  layout: PASS\\n'") end)
after(1700, function() term("logs", "logs", "printf '\\n  focus  ->  build\\n  column ->  2 of 3\\n'") end)
after(2200, function() term("top", "top", "printf '\\n  under the third column\\n'") end)

after(4200, function()
    sequence {
        act(function() L.consume_or_expel("left") end),
        act(function() L.focus("left") end),
        wait(900),
        act(function() notify("Standup in 10 minutes", "Room 3 · bring the cartoon demo") end),
        wait(1600),
        shoot("preview"),
        act(function() tide("control") end),
        wait(1500),
        shoot("control"),
        act(function() tide("control") end),
        wait(600),
        act(function() shady.toggle_launcher() end),
        wait(500),
        act(function() auto.type_text("te") end),
        wait(1200),
        shoot("launcher"),
        act(function() shady.toggle_launcher() end),
        wait(600),
        act(function() tide("power") end),
        wait(1300),
        shoot("power"),
        act(function() tide("power") end),
        wait(600),
        act(function() auto.move_pointer(640, 25) end),
        wait(300),
        act(function() auto.click("left") end),
        wait(1300),
        shoot("calendar"),
        act(function() auto.click("left") end),
        wait(600),
        act(function() tide("lock") end),
        wait(1800),
        shoot("lock"),
        function() shady.quit() end,
    }
end)
after(60000, function() shady.quit() end)
