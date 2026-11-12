-- Toon
-- A cartoon desktop. The windows, the keys and the rules are Tide's (a strip
-- of columns that scrolls sideways, niri's keys): shady.base("tide") runs
-- Tide's config.lua first. Toon only draws the windows like stickers, with
-- a thick ink outline and a candy colour around the focused one. The shell
-- (shell.lua) is Toon's own.

shady.base("tide")
shady.log("loading rice: Toon")

local INK = "#231A35"

shady.set("layout_gap", 14)
shady.set("window_corner_radius", 16.0)
shady.set("window_border_width", 3.0)
shady.set("window_border_color", INK)
shady.set("window_border_focus_color", "#FF6F91")
shady.set("shadows", true)

-- Behind the wallpaper, in case the shell is not running: the day sky.
shady.set("background_top", "#4DB3FF")
shady.set("background_horizon", "#CCF0FF")
shady.set("background_bottom", "#52C26B")
shady.set("background_color", "#8DD3FF")

-- What the Settings application saved wins over Toon's look too, as it does
-- over Tide's.
local home = os.getenv("HOME") or ""
local dir = os.getenv("XDG_CONFIG_HOME")
if not dir or dir == "" then dir = home .. "/.config" end
local ok, settings = pcall(dofile, dir .. "/shady/settings.lua")
if ok and type(settings) == "table" then
    for _, key in ipairs({ "layout_gap", "window_corner_radius" }) do
        if settings[key] ~= nil then pcall(shady.set, key, settings[key]) end
    end
    if settings.accent then pcall(shady.set, "window_border_focus_color", settings.accent) end
end
