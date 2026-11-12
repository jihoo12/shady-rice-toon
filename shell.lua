-- Toon: shady-shell drawn like a cartoon.
--
-- Everything is a sticker cut from paper, with a thick ink outline and a hard
-- shadow, and everything moves on bouncy springs: panels pop in crooked and
-- settle, buttons lift under the pointer and press in when switched on.
-- Over a cartoon sky (shaders/toon.frag) that follows the hour, a bar of
-- three stickers floats on the top edge: the workspaces as candy bubbles,
-- with a minimap of the strip; the clock (click: a calendar); and the
-- system's state (click: the control center, Super+S). Notifications arrive
-- as speech bubbles. Super+Space opens the launcher, Super+Shift+E the power
-- menu; volume and brightness keys show an OSD.
--
-- The compositor side is Tide's (config.lua and init.lua run Tide's), whose
-- keys reach the shell as `tide.do`.
--
-- shell.base("toon", options) builds on this file:
--   palette   colours to change, by the names in style.lua
--   wallpaper a picture, a folder of them or "#rrggbb", instead of the sky
--   bar       { left = fn(ctx), center = fn(ctx), right = fn(ctx) }, stickers to add
--   tiles     fn(ctx, tile), more tiles for the control center, as a list
--   launcher  fn(query), results to put first: { title, subtitle, icon, run }
-- It returns the pieces it is made of (see the end of the file).
local options = ... or {}

local HERE = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."
shell.fonts(HERE .. "/fonts")

local a, mix = shell.alpha, shell.mix
local settings = dofile(HERE .. "/settings.lua")
local palette = { accent = settings.accent, accent_2 = settings.accent_2 }
for name, colour in pairs(options.palette or {}) do palette[name] = colour end
local S = dofile(HERE .. "/style.lua")(palette)
local P, font, text, sticker, island, panel, round = S.P, S.font, S.text, S.sticker, S.island, S.panel, S.round
local BAR = S.BAR
local WHITE = "#FFFFFF"
-- Values the hand drives (sliders, the OSD) follow quickly, with a wobble.
local QUICK = { stiffness = 900, damping = 38 }

local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function first_letter(s)
    return ((s or ""):match("^[%z\1-\127\194-\244][\128-\191]*") or "?"):upper()
end

-- Whether a program is on PATH. (Not os.execute: the process reaps its
-- children itself, so system() never sees the status.)
local function has(command)
    for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
        local f = io.open(dir .. "/" .. command, "r")
        if f then f:close() return true end
    end
    return false
end
local HAVE = {
    grim = has("grim"), playerctl = has("playerctl"), nmcli = has("nmcli"), bluetoothctl = has("bluetoothctl"),
    settings = has("gloam-settings"), powerprofiles = has("powerprofilesctl"), wlcopy = has("wl-copy"),
    swaylock = has("swaylock"),
}

-- ---- system state ----------------------------------------------------------
-- Polled with plain tools. A value the shell itself just changed wins over
-- the poll for a few seconds, so sliders do not jump back.

local override = {}
local function remember(k, v) override[k] = { value = v, at = os.time() } end
local function live(k, polled)
    local o = override[k]
    if o and os.time() - o.at < 3 then return o.value end
    return polled
end

local sys = {}

function sys.volume()
    local out = shell.poll("wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null", 4000)
    local v = tonumber(out:match("Volume:%s*([%d%.]+)") or "")
    return live("volume", v and math.floor(v * 100 + 0.5)), live("mute", out:find("MUTED") ~= nil)
end

function sys.mic_muted()
    local out = shell.poll("wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null", 8000)
    return live("mic", out:find("MUTED") ~= nil)
end

local brightness_cmd = string.format("sh %q", shell.data_dir .. "/bin/shady-brightness")
function sys.brightness()
    return live("brightness", tonumber(shell.poll(brightness_cmd .. " get 2>/dev/null", 8000)))
end

function sys.battery()
    local out = shell.poll("cat /sys/class/power_supply/BAT*/capacity /sys/class/power_supply/BAT*/status 2>/dev/null | head -n2 | tr '\\n' ' '", 20000)
    local level, status = out:match("(%d+)%s+(%a+)")
    if not level then return nil end
    return tonumber(level), status
end

function sys.battery_time()
    local out = shell.poll("upower -i $(upower -e 2>/dev/null | grep -m1 BAT) 2>/dev/null | grep -E 'time to (empty|full)' | head -n1", 60000)
    local what, n, unit = out:match("time to (%a+):%s*([%d%.]+)%s*(%a+)")
    if not what then return nil end
    return string.format("%s %s until %s", n, unit, what == "empty" and "empty" or "full")
end

function sys.wifi()
    if not HAVE.nmcli then return nil end
    local state = trim(shell.poll("nmcli -t -f WIFI general 2>/dev/null", 10000))
    local ssid = trim(shell.poll("nmcli -t -f active,ssid device wifi 2>/dev/null | sed -n 's/^yes://p' | head -n1", 10000))
    local wired = trim(shell.poll("nmcli -t -f TYPE,STATE device 2>/dev/null | grep -m1 '^ethernet:connected'", 15000))
    return live("wifi", state == "enabled"), ssid, wired ~= ""
end

function sys.bluetooth()
    if not HAVE.bluetoothctl then return nil end
    local out = shell.poll("bluetoothctl show 2>/dev/null | grep -m1 Powered", 10000)
    if out == "" then return nil end
    local connected = trim(shell.poll("bluetoothctl devices Connected 2>/dev/null | head -n1 | cut -d' ' -f3-", 10000))
    return live("bluetooth", out:find("yes") ~= nil), connected
end

function sys.profile()
    if not HAVE.powerprofiles then return nil end
    return live("profile", trim(shell.poll("powerprofilesctl get 2>/dev/null", 15000)))
end

function sys.media()
    if not HAVE.playerctl then return nil end
    local out = shell.poll("playerctl metadata --format '{{status}}\t{{title}}\t{{artist}}' 2>/dev/null", 2500)
    local status, title, artist = out:match("^(%a+)\t([^\t]*)\t([^\n]*)")
    if not status or status == "Stopped" then return nil end
    return { playing = live("playing", status == "Playing"), title = title, artist = trim(artist) }
end

function sys.uptime()
    local s = tonumber((shell.poll("cut -d' ' -f1 /proc/uptime", 60000)):match("^[%d]+") or "")
    if not s then return "" end
    local h, m = s // 3600, (s % 3600) // 60
    return h > 0 and string.format("up %dh %dm", h, m) or string.format("up %d min", m)
end

local act = {}
function act.volume(v)
    v = clamp(math.floor(v + 0.5), 0, 150)
    remember("volume", v)
    remember("mute", false)
    shell.spawn(string.format("wpctl set-mute @DEFAULT_AUDIO_SINK@ 0; wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ %.2f", v / 100))
end
function act.mute()
    local _, muted = sys.volume()
    remember("mute", not muted)
    shell.spawn("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")
end
function act.mic_mute()
    remember("mic", not sys.mic_muted())
    shell.spawn("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle")
end
function act.brightness(v)
    v = clamp(math.floor(v + 0.5), 1, 100)
    remember("brightness", v)
    shell.spawn(string.format("%s set %d", brightness_cmd, v))
end
function act.wifi()
    local on = sys.wifi()
    remember("wifi", not on)
    shell.spawn("nmcli radio wifi " .. (on and "off" or "on"))
end
function act.bluetooth()
    local on = sys.bluetooth()
    remember("bluetooth", not on)
    shell.spawn("bluetoothctl power " .. (on and "off" or "on"))
end
local PROFILES = { "power-saver", "balanced", "performance" }
local PROFILE_NAMES = { ["power-saver"] = "Power saver", balanced = "Balanced", performance = "Performance" }
function act.profile()
    local current, next = sys.profile(), PROFILES[1]
    for i, p in ipairs(PROFILES) do if p == current then next = PROFILES[i % #PROFILES + 1] end end
    remember("profile", next)
    shell.spawn("powerprofilesctl set " .. next)
end
function act.media(what)
    if what == "play-pause" then
        local m = sys.media()
        if m then remember("playing", not m.playing) end
    end
    shell.spawn("playerctl " .. what)
end

-- ---- session -----------------------------------------------------------------

local dnd = false
local function caffeine() return shell.compositor_value("tide.caffeine", "0") == "1" end

-- The lock screen is drawn further down; defined here so the session
-- commands can use it.
local lock

local SESSION = {
    { id = "lock", label = "Lock", icon = "lock", color = P.accent_2, run = function() lock() end },
    { id = "logout", label = "Log out", icon = "close", color = P.grape, run = function() shell.quit() end },
    { id = "suspend", label = "Nap", icon = "moon", color = P.sun, run = function()
        lock()
        shell.spawn("sleep 0.5; systemctl suspend")
    end },
    { id = "reboot", label = "Restart", icon = "sliders", color = P.mint, run = function() shell.spawn("systemctl reboot") end },
    { id = "poweroff", label = "Shut down", icon = "power", color = P.danger, danger = true,
        run = function() shell.spawn("systemctl poweroff") end },
}

-- ---- wallpaper -------------------------------------------------------------
-- The cartoon sky is Toon's own wallpaper. shady-shell's wallpaper manager
-- draws it unless something replaces it: the picture chosen in Settings (or
-- the `wallpaper` option), a picture saved as ~/.config/shady/wallpaper.jpg,
-- a folder wallpapers/ (a slideshow), or `shady-wallpaper set`.
--
-- The sky moves (the sun's rays, the clouds), which redraws the screen on
-- every frame. TOON_STILL=1 stops it: the sky is then drawn once.

local home = os.getenv("HOME") or ""
local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function sky_shader()
    local path = HERE .. "/shaders/toon.frag"
    if os.getenv("TOON_STILL") ~= "1" then return shell.shader(path) end
    -- The same sky with the clock stopped: without u_time it is not animated.
    local f = io.open(path, "r")
    if not f then return shell.shader(path) end
    local source = f:read("a"):gsub("uniform float u_time;", "const float u_time = 0.0;")
    f:close()
    local dir = os.getenv("XDG_RUNTIME_DIR") or os.getenv("TMPDIR") or "/tmp"
    local still = dir .. "/toon-sky-still.frag"
    local out = io.open(still, "w")
    if not out then return shell.shader(path) end
    out:write(source)
    out:close()
    return shell.shader(still)
end

-- The hour the sky shows: the clock's, or TOON_HOUR (for trying them out).
local function hour()
    local fixed = tonumber(os.getenv("TOON_HOUR") or "")
    if fixed then return fixed end
    local now = os.date("*t")
    return now.hour + now.min / 60
end

local chosen = options.wallpaper or (settings.wallpaper and settings.wallpaper ~= "" and settings.wallpaper) or nil
local SKY = {
    shader = sky_shader(),
    uniforms = function()
        local u = { hour = hour() }
        for k, v in pairs(S.SKY_UNIFORMS) do u[k] = v end
        return u
    end,
    color = "#8DD3FF",
}

local has_manager, wallpaper = pcall(require, "wallpaper")
if has_manager then
    wallpaper.install { name = "toon-wallpaper", default = SKY, source = chosen }
else
    -- A shady-shell from before the manager: a PNG, else the sky.
    local path = chosen and chosen:gsub("^~/", home .. "/")
        or (os.getenv("XDG_CONFIG_HOME") or (home .. "/.config")) .. "/shady/wallpaper.png"
    local picture = exists(path)
    wallpaper = {
        widget = function(ctx)
            local layer = { left = 0, top = 0, width = ctx.width, height = ctx.height }
            if picture then
                layer.path = path
                return shell.stack { width = ctx.width, height = ctx.height, shell.image(layer) }
            end
            layer.shader, layer.uniforms = SKY.shader, SKY.uniforms()
            return shell.stack { width = ctx.width, height = ctx.height, shell.box(layer) }
        end,
    }
    shell.popup {
        name = "toon-wallpaper", layer = "background", fill = true, outputs = "all",
        input = "widgets", view = function(ctx) return wallpaper.widget(ctx) end,
    }
end

-- Every few minutes, so the sky follows the hour.
local function follow_the_sun()
    shell.redraw()
    shell.after(240000, follow_the_sun)
end
shell.after(240000, follow_the_sun)

-- ---- little drawings ---------------------------------------------------------

-- A cartoon battery: an outlined body with a nub, filled to the level.
local function battery_drawing(level, status, scale)
    scale = scale or 1
    local charging = status == "Charging" or status == "Full"
    local fill = (level <= 15 and not charging) and P.danger or (level <= 35 and not charging and P.sun or P.mint)
    local w, h = 26 * scale, 14 * scale
    local inner = math.max(1, (w - 6 * scale) * clamp(level / 100, 0, 1))
    return shell.canvas {
        width = w + 4 * scale, height = h,
        { "rect", 1, 1, w - 2, h - 2, radius = 4 * scale, fill = P.paper, stroke = P.ink, width = 2.2 },
        { "rect", 3 * scale, 3 * scale, inner, h - 6 * scale, radius = 2 * scale, fill = fill },
        { "rect", w - 1, h * 0.3, 3.5 * scale, h * 0.4, radius = 1.5, fill = P.ink },
        charging and { "path", string.format("M %f %f L %f %f L %f %f L %f %f Z",
            w * 0.52, h * 0.12, w * 0.32, h * 0.56, w * 0.48, h * 0.56, w * 0.42, h * 0.9),
            fill = P.ink } or false,
    }
end

local function battery_badge(level, status)
    local low = level <= 15 and status ~= "Charging" and status ~= "Full"
    return shell.row {
        gap = 5, align = "center",
        battery_drawing(level, status),
        text(level .. "%", { font = font("SemiBold", 9.5), color = low and P.danger or P.ink }),
    }
end

-- A speech bubble's tail, pointing up from the bubble's top edge, `right`
-- pixels from its right end.
-- Its fill covers the bubble's outline between its feet.
local function tail(right, colour)
    return shell.canvas {
        right = right, top = -11, width = 22, height = 14,
        { "path", "M 1 13.5 L 13 1.5 L 19 13.5", fill = colour or P.paper, stroke = P.ink, width = 2.5,
            cap = "round" },
    }
end

-- ---- the strip minimap -----------------------------------------------------

local function strip()
    local raw = shell.compositor_value("layout.strip", "")
    local screen, view, active = raw:match("^(%-?%d+) (%-?%d+) (%d+)")
    local s = { screen = tonumber(screen) or 0, view = tonumber(view) or 0,
        active = tonumber(active) or 0, cols = {} }
    for x, w, rows in raw:gmatch("|(%-?%d+) (%d+) (%d+)") do
        s.cols[#s.cols + 1] = { x = tonumber(x), w = tonumber(w), rows = tonumber(rows) }
    end
    return s
end

local MAP_H = 14
local function minimap()
    local s = strip()
    if #s.cols < 2 or s.screen <= 0 then return false end
    local last = s.cols[#s.cols]
    local origin = math.min(0, s.view)
    local extent = math.max(last.x + last.w, s.view + s.screen) - origin
    local width = clamp(#s.cols * 14, 40, 110)
    local scale = width / extent
    local parts = {}
    for i, c in ipairs(s.cols) do
        local on = i == s.active
        local w = math.max(4, c.w * scale - 2)
        local h = (MAP_H - (c.rows - 1)) / c.rows
        for r = 1, c.rows do
            parts[#parts + 1] = shell.box {
                key = "map:" .. i .. ":" .. r, animate = "bouncy",
                left = (c.x - origin) * scale, top = (r - 1) * (h + 1), width = w, height = h,
                radius = 3, background = on and P.paper or a(P.ink, 0.35),
                border = on and P.ink or nil, border_width = 1.5,
            }
        end
    end
    parts[#parts + 1] = shell.box {
        key = "map:view", animate = "bouncy",
        left = (s.view - origin) * scale - 2, top = -2, width = s.screen * scale + 2, height = MAP_H + 4,
        radius = 5, border = P.ink, border_width = 1.5,
    }
    return shell.stack { key = "minimap", width = width, height = MAP_H, parts }
end

-- ---- bar ---------------------------------------------------------------------

local function workspace_names()
    local busy = {}
    for _, w in ipairs(shell.windows()) do busy[w.workspace] = true end
    local active = shell.active_workspace()
    local names = {}
    for _, n in ipairs(shell.workspaces()) do
        if busy[n] or n == active then names[#names + 1] = n end
    end
    table.sort(names, function(x, y)
        local nx, ny = tonumber(x), tonumber(y)
        if nx and ny then return nx < ny end
        return x < y
    end)
    return names, active, busy
end

local function workspace_colour(n)
    local i = tonumber(n)
    if i then return S.CANDY[(i - 1) % #S.CANDY + 1] end
    return S.candy(n)
end

local function workspaces_island(ctx)
    local names, active = workspace_names()
    local items = {}
    for _, n in ipairs(names) do
        local on = n == active
        local id = "ws:" .. n
        local colour = workspace_colour(n)
        items[#items + 1] = shell.row {
            id = id, key = id, height = 26, radius = 13, gap = 8, animate = "bouncy",
            padding = { 0, on and 10 or 0 }, min_width = 26, justify = "center",
            background = on and colour or (ctx.hovered == id and P.cream or P.paper),
            border = P.ink, border_width = 2,
            scale = on and 1 or 0.9,
            rotate = on and -2 or 0,
            enter = { scale = 0, opacity = 0 },
            hover = not on and { scale = 1.0, rotate = 6 } or nil,
            on_click = function() shell.workspace(n) end,
            text(n, { font = font("Bold", 10) }),
            on and minimap() or false,
        }
    end
    return island {
        key = "island:left", padding = { 0, 6 }, gap = 4, rotate = -1.2,
        on_scroll = function(dy)
            if math.abs(dy) < 2 then return end
            shell.key(dy > 0 and "Super+Page_Down" or "Super+Page_Up")
        end,
        items,
    }
end

local function focused_window()
    local f = shell.focused()
    if not f then return nil end
    local title = f.title ~= "" and f.title or f.app_id
    if title == "" then return nil end
    return title, f.app_id ~= "" and f.app_id or title
end

local function title_island(ctx)
    local title, app = focused_window()
    if not title then return false end
    return island {
        key = "island:title", padding = { 0, 12, 0, 6 }, gap = 8, rotate = 0.8,
        shell.row { width = 24, height = 24, radius = 12, justify = "center",
            background = S.candy(app), border = P.ink, border_width = 2,
            text(first_letter(app), { font = font("Bold", 9.5) }) },
        text(title, { font = font("Medium", 10), max_width = math.floor(ctx.width * 0.22) }),
    }
end

local function clock_island(ctx)
    local open = shell.is_open("toon-calendar")
    return island {
        key = "island:clock", id = "clock", gap = 8,
        background = open and P.accent or P.sun, rotate = open and -1.5 or 1.4,
        on_click = function() shell.toggle("toon-calendar") end,
        text(shell.date("%a %d"), { font = font("SemiBold", 9.5) }),
        text(shell.date("%H:%M"), { font = font("Bold", 12.5) }),
    }
end

local function status_island(ctx)
    local items = {}
    local function icon(name, colour)
        return shell.icon(name, { size = 16, stroke = 2.4, color = colour or P.ink })
    end
    local media = sys.media()
    if media and media.title ~= "" then
        items[#items + 1] = shell.row {
            id = "bar:media", gap = 6, align = "center",
            on_click = function(button)
                if button == "right" then act.media("next") else act.media("play-pause") end
            end,
            shell.row { width = 22, height = 22, radius = 11, justify = "center", background = P.accent_2,
                border = P.ink, border_width = 2,
                shell.icon(media.playing and "music" or "pause", { size = 11, stroke = 2.4, color = P.ink }) },
            text(media.title, { font = font("Medium", 9.5), max_width = 150 }),
        }
    end
    if dnd then items[#items + 1] = icon("bell", P.accent) end
    if caffeine() then items[#items + 1] = text("☕", { font = font("Medium", 11) }) end
    local wifi_on, ssid, wired = sys.wifi()
    if wifi_on ~= nil then
        items[#items + 1] = icon("wifi", (wired or (wifi_on and ssid ~= "")) and P.ink or a(P.ink, 0.35))
    end
    local bt_on = sys.bluetooth()
    if bt_on then items[#items + 1] = icon("bluetooth") end
    local volume, muted = sys.volume()
    if volume then
        items[#items + 1] = shell.row {
            id = "bar:volume", gap = 4, align = "center",
            on_scroll = function(dy) act.volume(volume - dy / 4) end,
            on_click = function(button) if button == "middle" or button == "right" then act.mute() end end,
            icon(muted and "mute" or "volume", muted and a(P.ink, 0.4) or P.ink),
        }
    end
    local level, status = sys.battery()
    if level then items[#items + 1] = battery_badge(level, status) end
    local open = shell.is_open("toon-control")
    local power_hover = ctx.hovered == "bar:power"
    return island {
        key = "island:status", id = "status", rotate = open and 1.5 or -1,
        padding = { 0, 6, 0, 14 },
        background = open and P.accent_2 or P.paper,
        on_click = function() shell.toggle("toon-control") end,
        items,
        shell.row {
            id = "bar:power", width = 26, height = 26, radius = 13, justify = "center",
            background = P.danger, border = P.ink, border_width = 2, animate = "bouncy",
            rotate = power_hover and 90 or 0, scale = power_hover and 1.1 or 1,
            on_click = function() shell.toggle("toon-power") end,
            shell.icon("power", { size = 13, stroke = 2.6, color = WHITE }),
        },
    }
end

shell.bar {
    name = "toon-bar",
    edge = "top",
    size = BAR,
    exclusive = true,
    layer = "top",
    view = function(ctx)
        local extra = options.bar or {}
        return shell.stack {
            align = "start", justify = "center",
            shell.row { left = 10, top = 7, gap = 10, align = "center",
                workspaces_island(ctx),
                title_island(ctx),
                extra.left and extra.left(ctx) or false,
            },
            shell.row { top = 7, gap = 10, align = "center", clock_island(ctx),
                extra.center and extra.center(ctx) or false },
            shell.row { right = 14, top = 7, gap = 10, align = "center",
                extra.right and extra.right(ctx) or false, status_island(ctx) },
        }
    end,
}

-- ---- sliders and tiles -----------------------------------------------------

-- A chunky slider: an outlined track holding the filled share, the knob and
-- the rest, so no widget needs to know the track's width.
local dragging = {}

local function slider(ctx, id, icon, value, max, on_set, on_icon, muted, colour)
    local f = value and clamp(value / max, 0, 1) or 0
    local hovered = ctx.hovered == id or dragging[id]
    colour = muted and a(P.ink, 0.25) or (colour or P.accent)
    local motion = not dragging[id] and QUICK or false
    return shell.row {
        height = 44, gap = 12, align = "center",
        round(id .. ":icon", icon, 34, ctx.hovered == id .. ":icon",
            { on_click = on_icon, background = muted and P.cream or colour, depth = 2 }),
        shell.row {
            id = id, grow = 1, height = 18, align = "center", gap = 0, radius = 9,
            background = P.cream, border = P.ink, border_width = 2.5,
            on_drag = function(info)
                dragging[id] = not info.done or nil
                on_set(info.fx * max)
                shell.redraw()
            end,
            on_scroll = function(dy) on_set((value or 0) - dy / 4 * max / 100); shell.redraw() end,
            shell.box { key = id .. ":a", grow = math.max(f, 0.0001), height = 13, radius = 7,
                animate = motion, background = colour },
            shell.box { key = id .. ":knob", width = 26, height = 26, radius = 13,
                animate = "bouncy", background = P.paper, border = P.ink, border_width = 2.5,
                shadow = S.drop(2), scale = hovered and 1.15 or 1 },
            shell.box { key = id .. ":b", grow = math.max(1 - f, 0.0001), height = 13 },
        },
        shell.row { width = 40, height = 24, radius = 8, justify = "center",
            background = P.paper, border = P.ink, border_width = 2,
            text(value and tostring(math.floor(value + 0.5)) or "–", { font = font("Bold", 9.5) }) },
    }
end

-- A tile is a big button. Switched on it is filled with its colour and
-- pressed into the paper.
local TILE_COLOURS = { "accent_2", "grape", "accent", "sun", "mint", "peach" }
local tiles_made = 0
local function tile(ctx, id, icon, title, subtitle, on, on_click, colour)
    tiles_made = tiles_made + 1
    colour = colour or P[TILE_COLOURS[(tiles_made - 1) % #TILE_COLOURS + 1]]
    local hovered = ctx.hovered == id
    return sticker({
        id = id, grow = 1, height = 60, radius = 18, padding = { 0, 12 }, gap = 10,
        background = on and colour or (hovered and P.cream or P.paper),
        on_click = on_click,
        shell.row {
            width = 34, height = 34, radius = 17, justify = "center",
            background = on and P.paper or colour, border = P.ink, border_width = 2,
            rotate = on and -8 or 0, animate = "bouncy",
            shell.icon(icon, { size = 16, stroke = 2.4, color = P.ink }),
        },
        shell.column {
            grow = 1, shrink = 1, align = "start", gap = 0,
            text(title, { font = font("SemiBold", 10.5) }),
            text(subtitle, { font = font("Medium", 9), color = on and a(P.ink, 0.75) or P.dim }),
        },
    }, on)
end

local function section(label)
    return text(label, { font = font("Bold", 11) })
end

-- ---- notifications ---------------------------------------------------------
-- Speech bubbles: the app as a round badge, what it says, its buttons.

shell.notification_server { timeout = 6000 }

local function ago(seconds)
    if seconds < 60 then return "now" end
    if seconds < 3600 then return (seconds // 60) .. "m" end
    if seconds < 86400 then return (seconds // 3600) .. "h" end
    return (seconds // 86400) .. "d"
end

local function activate(n)
    for _, action in ipairs(n.actions) do
        if action.key == "default" then
            shell.invoke_notification(n.id, "default")
            return
        end
    end
    shell.dismiss_notification(n.id)
end

local function note(ctx, n, opts)
    opts = opts or {}
    local id = (opts.prefix or "note:") .. n.id
    local critical = n.urgency == "critical"
    local app = n.app ~= "" and n.app or "Notification"
    local actions = {}
    for _, action in ipairs(n.actions) do
        if action.key ~= "default" and action.label ~= "" then
            local aid = id .. ":" .. action.key
            actions[#actions + 1] = sticker {
                id = aid, radius = 12, padding = { 5, 12 }, depth = 2,
                background = ctx.hovered == aid and P.sun or P.paper,
                on_click = function() shell.invoke_notification(n.id, action.key) end,
                text(action.label, { font = font("SemiBold", 9.5) }),
            }
        end
    end
    local close = id .. ":x"
    local body = sticker {
        key = id, id = id, direction = "column", align = "stretch", gap = 6, padding = { 12, 14 },
        width = opts.bubble,
        radius = 20, depth = opts.depth or 4,
        enter = opts.enter or { opacity = 0, scale = 0.5, rotate = -8, translate = { 40, -10 } },
        background = critical and mix(P.paper, P.danger, 0.18)
            or (opts.flat and ctx.hovered == id and P.cream or P.paper),
        hover = opts.flat and {} or nil,
        on_click = function() activate(n) end,
        shell.row {
            gap = 8, align = "center",
            shell.row { width = 24, height = 24, radius = 12, justify = "center",
                background = critical and P.danger or S.candy(app), border = P.ink, border_width = 2,
                text(first_letter(app), { font = font("Bold", 9.5) }) },
            text(app, { font = font("SemiBold", 9.5), color = P.dim, shrink = 1 }),
            shell.spacer(),
            text(ago(os.time() - n.time), { font = font("Medium", 9), color = P.dim }),
            shell.row {
                id = close, width = 22, height = 22, radius = 11, justify = "center", animate = "bouncy",
                background = ctx.hovered == close and P.danger or nil,
                border = ctx.hovered == close and P.ink or nil, border_width = 2,
                rotate = ctx.hovered == close and 90 or 0,
                on_click = function() shell.dismiss_notification(n.id) end,
                shell.icon("close", { size = 11, stroke = 2.6, color = P.ink }),
            },
        },
        n.summary ~= "" and text(n.summary, { font = font("SemiBold", 11), wrap = true, max_lines = 2,
            max_width = opts.width or 320 }) or false,
        n.body ~= "" and text(n.body, { font = font("Regular", 10), color = a(P.ink, 0.8), wrap = true,
            max_lines = opts.lines or 3, max_width = opts.width or 320 }) or false,
        #actions > 0 and shell.row { gap = 6, actions } or false,
    }
    if not opts.tail then return body end
    -- The tail rides along with the bubble, pointing up at the status sticker.
    return shell.stack { key = id .. ":bubble", align = "stretch", body,
        tail(34, critical and mix(P.paper, P.danger, 0.18) or P.paper) }
end

local function sync_toasts()
    local want = false
    if not dnd and not shell.is_open("toon-control") then
        for _, n in ipairs(shell.notifications()) do want = want or n.active end
    end
    if want ~= shell.is_open("toon-toasts") then
        if want then shell.open("toon-toasts") else shell.close("toon-toasts") end
    end
end
shell.on("notifications", sync_toasts)

shell.popup {
    name = "toon-toasts",
    anchor = { "top", "right" },
    margin = { top = BAR - 2, right = 6 },
    width = 372,
    keyboard = "none",
    input = "widgets",
    view = function(ctx)
        local list = {}
        for _, n in ipairs(shell.notifications()) do
            if n.active and #list < 3 then
                list[#list + 1] = note(ctx, n, { prefix = "toast:", width = 300, bubble = 344,
                    tail = #list == 0 })
            end
        end
        return shell.column { align = "stretch", gap = 12, padding = { 14, 14, 14, 8 }, list }
    end,
}

-- ---- control center ----------------------------------------------------------

local user = os.getenv("USER") or "you"

local function media_card(ctx)
    local m = sys.media()
    if not m then return false end
    local function button(id, icon, what, big)
        local size = big and 42 or 32
        return round(id, icon, size, ctx.hovered == id, {
            background = big and P.sun or (ctx.hovered == id and P.cream or P.paper),
            on_click = function() act.media(what) end })
    end
    -- A record that ticks round while it plays.
    local turn = m.playing and (tonumber(shell.date("%S")) or 0) * 30 or 0
    return sticker {
        radius = 20, padding = { 10, 12 }, gap = 12, depth = 3, background = P.accent_2,
        shell.canvas {
            key = "media:disc", width = 44, height = 44, animate = "bouncy", rotate = turn,
            { "circle", 22, 22, 20, fill = P.ink },
            { "circle", 22, 22, 14, stroke = a(WHITE, 0.25), width = 1.2 },
            { "circle", 22, 22, 9, fill = P.accent },
            { "circle", 22, 22, 2.5, fill = P.paper },
            { "rect", 20, 4, 4, 7, radius = 2, fill = a(WHITE, 0.5) },
        },
        shell.column { grow = 1, shrink = 1, align = "start", gap = 1,
            text(m.title, { font = font("SemiBold", 10.5), max_width = 160 }),
            text(m.artist ~= "" and m.artist or "Playing", { font = font("Medium", 9), color = a(P.ink, 0.7),
                max_width = 160 }),
        },
        button("media:prev", "previous", "previous"),
        button("media:play", m.playing and "pause" or "play", "play-pause", true),
        button("media:next", "next", "next"),
    }
end

local function control_view(ctx)
    local volume, muted = sys.volume()
    local brightness = sys.brightness()
    local wifi_on, ssid, wired = sys.wifi()
    local bt_on, bt_dev = sys.bluetooth()
    local profile = sys.profile()
    local level, status = sys.battery()
    tiles_made = 0

    local header = shell.row {
        gap = 10, align = "center",
        shell.row { width = 44, height = 44, radius = 22, justify = "center", rotate = -6,
            background = P.grape, border = P.ink, border_width = 2.5, shadow = S.drop(2),
            text(first_letter(user), { font = font("Bold", 16) }) },
        shell.column { grow = 1, align = "start", gap = 0,
            text("Hi, " .. user .. "!", { font = font("Bold", 14) }),
            text(sys.uptime(), { font = font("Medium", 9), color = P.dim }) },
        HAVE.settings and round("cc:settings", "sliders", 36, ctx.hovered == "cc:settings", {
            on_click = function() shell.close("toon-control"); shell.spawn("gloam-settings") end }) or false,
        round("cc:lock", "lock", 36, ctx.hovered == "cc:lock", { on_click = function() lock() end }),
        round("cc:power", "power", 36, ctx.hovered == "cc:power", {
            background = P.danger, color = WHITE,
            on_click = function() shell.close("toon-control"); shell.open("toon-power") end }),
    }

    local tiles = {}
    if wifi_on ~= nil then
        tiles[#tiles + 1] = tile(ctx, "t:wifi", "wifi", "Wi-Fi",
            wired and "Wired" or (wifi_on and (ssid ~= "" and ssid or "Not connected") or "Off"),
            wifi_on, act.wifi, P.accent_2)
    end
    if bt_on ~= nil then
        tiles[#tiles + 1] = tile(ctx, "t:bt", "bluetooth", "Bluetooth",
            bt_on and (bt_dev ~= "" and bt_dev or "On") or "Off", bt_on, act.bluetooth, P.grape)
    end
    tiles[#tiles + 1] = tile(ctx, "t:dnd", "bell", "Quiet", dnd and "Shh…" or "Off", dnd,
        function() dnd = not dnd; sync_toasts() end, P.accent)
    tiles[#tiles + 1] = tile(ctx, "t:caffeine", "sun", "Stay awake", caffeine() and "On" or "Off",
        caffeine(), function() shell.key("Super+Ctrl+Shift+F12") end, P.sun)
    if profile and profile ~= "" then
        tiles[#tiles + 1] = tile(ctx, "t:profile", "sliders", "Power", PROFILE_NAMES[profile] or profile,
            profile ~= "balanced", act.profile, P.mint)
    end
    tiles[#tiles + 1] = tile(ctx, "t:shot", "capture", "Screenshot", "Snap!", false, function()
        shell.close("toon-control")
        shell.after(350, function() shell.key("Print") end)
    end, P.peach)
    if options.tiles then
        for _, extra in ipairs(options.tiles(ctx, tile)) do tiles[#tiles + 1] = extra end
    end
    local grid = {}
    for i = 1, #tiles, 2 do
        grid[#grid + 1] = shell.row { gap = 10, align = "stretch", tiles[i], tiles[i + 1] or shell.spacer { grow = 1 } }
    end

    local notes, count = {}, 0
    for _, n in ipairs(shell.notifications()) do
        count = count + 1
        if #notes < 4 then
            notes[#notes + 1] = note(ctx, n, { width = 300, lines = 2, depth = 2, flat = true,
                enter = { opacity = 0, translate = { 0, -8 } } })
        end
    end

    local battery_line = false
    if level then
        local when = sys.battery_time()
        battery_line = shell.row { gap = 8, align = "center",
            battery_badge(level, status),
            text(status == "Charging" and "Charging" or (status == "Full" and "Full" or "On battery"),
                { font = font("Medium", 9.5), color = P.dim }),
            shell.spacer(),
            when and text(when, { font = font("Medium", 9.5), color = P.dim }) or false,
        }
    end

    return panel {
        width = 396, padding = 16, gap = 14,
        header,
        shell.column { align = "stretch", gap = 4,
            slider(ctx, "s:volume", muted and "mute" or "volume", volume, 100, act.volume, act.mute, muted, P.accent),
            brightness and slider(ctx, "s:brightness", "sun", brightness, 100, act.brightness, nil, false, P.sun) or false,
        },
        shell.column { align = "stretch", gap = 10, grid },
        media_card(ctx),
        shell.column { align = "stretch", gap = 8,
            shell.row { align = "center", gap = 8,
                section("Notifications"),
                count > 0 and shell.row { height = 20, min_width = 20, radius = 10, padding = { 0, 6 },
                    justify = "center", background = P.accent, border = P.ink, border_width = 2,
                    text(tostring(count), { font = font("Bold", 9) }) } or false,
                shell.spacer(),
                count > 0 and sticker { id = "cc:clear", radius = 10, padding = { 3, 10 }, depth = 2,
                    background = ctx.hovered == "cc:clear" and P.sun or P.paper,
                    on_click = function() shell.clear_notifications() end,
                    text("Clear", { font = font("SemiBold", 9.5) }) } or false,
            },
            #notes > 0 and shell.column { align = "stretch", gap = 8, notes }
                or shell.row { radius = 16, padding = { 12, 14 }, gap = 10, background = P.cream,
                    border = a(P.ink, 0.35), border_width = 2,
                    text("✿", { font = font("Bold", 13), color = P.accent }),
                    text("All quiet. Nothing new!", { font = font("Medium", 10), color = P.dim }) },
        },
        battery_line,
    }
end

shell.popup {
    name = "toon-control",
    anchor = { "top", "right" },
    margin = { top = BAR - 6, right = 2 },
    keyboard = "on_demand",
    input = "widgets",
    view = control_view,
    on_key = function(key)
        if key == "Escape" then shell.close("toon-control") end
    end,
}

-- ---- calendar ----------------------------------------------------------------

local cal = { offset = 0 }

shell.popup {
    name = "toon-calendar",
    anchor = { "top" },
    margin = { top = BAR - 6 },
    keyboard = "on_demand",
    input = "widgets",
    view = function(ctx)
        local now = os.date("*t")
        local first = os.time { year = now.year, month = now.month + cal.offset, day = 1, hour = 12 }
        local ft = os.date("*t", first)
        local days = os.date("*t", os.time { year = ft.year, month = ft.month + 1, day = 0, hour = 12 }).day
        local lead = (ft.wday + 5) % 7 -- Monday first
        local rows, cells = {}, {}
        local heads = {}
        for i, d in ipairs({ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }) do
            heads[#heads + 1] = text(d, { width = 36, text_align = 0.5, font = font("Bold", 9),
                color = i >= 6 and P.accent or P.dim })
        end
        rows[1] = shell.row { gap = 2, heads }
        for _ = 1, lead do cells[#cells + 1] = shell.box { width = 36, height = 32 } end
        for d = 1, days do
            local today = cal.offset == 0 and d == now.day
            local weekend = #cells >= 5
            cells[#cells + 1] = shell.row {
                key = "day:" .. cal.offset .. ":" .. d, width = 36, height = 32, radius = 16, justify = "center",
                background = today and P.accent or nil, border = today and P.ink or nil, border_width = 2.5,
                shadow = today and S.drop(2) or nil, rotate = today and -8 or 0,
                enter = { opacity = 0, scale = 0.3 }, animate = "bouncy",
                text(tostring(d), { font = font(today and "Bold" or "Medium", 10),
                    color = (weekend and not today) and mix(P.ink, P.accent, 0.55) or P.ink }),
            }
            if #cells == 7 then
                rows[#rows + 1] = shell.row { gap = 2, cells }
                cells = {}
            end
        end
        if #cells > 0 then rows[#rows + 1] = shell.row { gap = 2, cells } end
        local function nav(id, icon, delta)
            return round(id, icon, 30, ctx.hovered == id, {
                on_click = function() cal.offset = cal.offset + delta; shell.redraw() end })
        end
        return panel {
            padding = 16, gap = 12,
            shell.row { align = "center", gap = 8,
                shell.column { align = "start", gap = 0,
                    text(os.date("%B %Y", first), { font = font("Bold", 15) }),
                    text(os.date("%A, %d %B"), { font = font("Medium", 9.5), color = P.dim }) },
                shell.spacer(),
                nav("cal:prev", "previous", -1), nav("cal:next", "next", 1),
            },
            shell.column { gap = 2, align = "start", rows },
        }
    end,
    on_key = function(key)
        if key == "Escape" then shell.close("toon-calendar"); cal.offset = 0
        elseif key == "Left" then cal.offset = cal.offset - 1
        elseif key == "Right" then cal.offset = cal.offset + 1 end
        shell.redraw()
    end,
}

-- ---- launcher ----------------------------------------------------------------
-- Apps, ordered by how often they were launched; "= 2*21" calculates,
-- "> cmd" runs a command, and the session's commands match by name.

local state_dir = (os.getenv("XDG_STATE_HOME") or (home .. "/.local/state")) .. "/toon"
local counts_path = state_dir .. "/launches"
local counts = {}
do
    local f = io.open(counts_path, "r")
    if f then
        for line in f:lines() do
            local n, name = line:match("^(%d+)\t(.+)$")
            if n then counts[name] = tonumber(n) end
        end
        f:close()
    end
end
local function save_counts()
    os.execute(string.format("mkdir -p %q", state_dir))
    local f = io.open(counts_path, "w")
    if not f then return end
    for name, n in pairs(counts) do f:write(n, "\t", name, "\n") end
    f:close()
end

local L = { query = "", selected = 1 }

local function calculate(expr)
    expr = expr:gsub("^=%s*", "")
    if expr == "" or not expr:match("^[%d%s%.%+%-%*/%%%^%(%)eEpisqrtlogfloorcexpabnm,]+$") then return nil end
    local env = setmetatable({}, { __index = math })
    local fn = load("return " .. expr, "calc", "t", env)
    if not fn then return nil end
    local ok, v = pcall(fn)
    if not ok or type(v) ~= "number" or v ~= v then return nil end
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
    return (string.format("%.10g", v))
end

local function results()
    local q = L.query
    local list = {}
    if q:match("^>") then
        local cmd = trim(q:sub(2))
        if cmd ~= "" then
            list[#list + 1] = { kind = "run", title = cmd, subtitle = "Run command", icon = "grid",
                run = function() shell.spawn(cmd) end }
        end
        return list
    end
    if options.launcher then
        for _, item in ipairs(options.launcher(q)) do
            item.kind = "extra"
            item.subtitle = item.subtitle or ""
            list[#list + 1] = item
        end
    end
    local value = calculate(q)
    if value and (q:match("^=") or q:match("[%+%-%*/%^%%]")) then
        list[#list + 1] = { kind = "calc", title = value, subtitle = "= " .. trim(q:gsub("^=", "")) ..
            (HAVE.wlcopy and "  ·  Enter copies" or ""), icon = "plus",
            run = function()
                if HAVE.wlcopy then shell.spawn(string.format("printf %%s %q | wl-copy", value)) end
            end }
    end
    local lq = q:lower()
    if lq ~= "" then
        for _, s in ipairs(SESSION) do
            if s.label:lower():find(lq, 1, true) == 1 or s.id:find(lq, 1, true) == 1 then
                list[#list + 1] = { kind = "session", title = s.label, subtitle = "Session",
                    icon = s.icon, run = s.run }
            end
        end
    end
    local apps = shell.apps(q, q == "" and 60 or 12)
    table.sort(apps, function(x, y)
        local cx, cy = counts[x.name] or 0, counts[y.name] or 0
        if q ~= "" then
            -- A name that starts with the query beats one that contains it.
            local sx = x.name:lower():find(lq, 1, true) == 1
            local sy = y.name:lower():find(lq, 1, true) == 1
            if sx ~= sy then return sx end
        end
        if cx ~= cy then return cx > cy end
        return x.name < y.name
    end)
    for _, app in ipairs(apps) do
        if #list >= 7 then break end
        local category = (app.categories or ""):match("^([^;]+)") or ""
        list[#list + 1] = { kind = "app", title = app.name, subtitle = category,
            app = app, run = function()
                counts[app.name] = (counts[app.name] or 0) + 1
                save_counts()
                shell.launch(app)
            end }
    end
    return list
end

local function choose(item)
    shell.close("toon-launcher")
    if item then item.run() end
end

shell.on("launcher", function()
    L.query, L.selected = "", 1
    shell.close("toon-control")
    shell.toggle("toon-launcher")
end)

local GREETINGS = { "What'll it be?", "Where to?", "Let's go!", "Pick one!" }

shell.popup {
    name = "toon-launcher",
    width = 600,
    keyboard = "exclusive",
    text_input = true,
    input = "widgets",
    view = function(ctx)
        local list = results()
        if L.selected > #list then L.selected = math.max(#list, 1) end
        local rows = {}
        for i, item in ipairs(list) do
            local id = "res:" .. i
            local sel = i == L.selected
            local lit = sel or ctx.hovered == id
            local colour = S.candy(item.title)
            local glyph = item.kind == "app"
                and text(first_letter(item.title), { font = font("Bold", 13) })
                or shell.icon(item.icon or "grid", { size = 16, stroke = 2.4, color = P.ink })
            rows[#rows + 1] = shell.row {
                id = id, key = "res:" .. item.kind .. ":" .. item.title, height = 52, radius = 16,
                padding = { 0, 10 }, gap = 12, animate = "bouncy",
                enter = { opacity = 0, translate = { -20, 0 }, scale = 0.9 },
                background = sel and P.sun or (lit and P.cream or nil),
                border = sel and P.ink or nil, border_width = 2.5,
                shadow = sel and S.drop(3) or false,
                rotate = sel and -0.8 or 0, translate = sel and { 4, 0 } or { 0, 0 },
                on_click = function() choose(item) end,
                shell.row { width = 36, height = 36, radius = 12, justify = "center",
                    background = item.kind == "app" and colour or P.accent_2,
                    border = P.ink, border_width = 2.5, rotate = sel and 8 or 0, animate = "bouncy",
                    glyph },
                shell.column { grow = 1, shrink = 1, align = "start", gap = 0,
                    text(item.title, { font = font(sel and "Bold" or "Medium", 11) }),
                    item.subtitle ~= "" and text(item.subtitle, { font = font("Medium", 9),
                        color = sel and a(P.ink, 0.7) or P.dim }) or false },
                sel and shell.row { height = 24, radius = 8, padding = { 0, 8 }, background = P.paper,
                    border = P.ink, border_width = 2,
                    text("↵ go", { font = font("Bold", 9) }) } or false,
            }
        end
        if #list == 0 then
            rows[1] = shell.column { padding = { 14, 12 }, align = "start", gap = 3,
                text("Hmm, nothing here!", { font = font("Bold", 12) }),
                text("“= 2+2” calculates, “> cmd” runs a command", { font = font("Medium", 9.5), color = P.dim }) }
        end
        local preedit = ctx.preedit or ""
        local field = shell.row {
            height = 50, radius = 18, padding = { 0, 8 }, gap = 10, align = "center",
            background = WHITE, border = P.ink, border_width = 3,
            shell.row { width = 34, height = 34, radius = 17, justify = "center", background = P.accent,
                border = P.ink, border_width = 2.5, rotate = (#L.query % 2 == 0) and -10 or 10, animate = "bouncy",
                shell.icon("search", { size = 16, stroke = 2.6, color = P.ink }) },
            (L.query ~= "" or preedit ~= "") and shell.row { gap = 1, align = "center",
                text(L.query, { font = font("SemiBold", 13) }),
                preedit ~= "" and text(preedit, { font = font("SemiBold", 13), color = P.accent }) or false,
                shell.box { width = 3, height = 22, radius = 2, background = P.accent, caret = true },
            } or shell.row { gap = 0, align = "center",
                shell.box { width = 0, height = 22, caret = true },
                text("Search apps, = calculate, > run", { font = font("Medium", 12), color = a(P.dim, 0.8) }),
            },
        }
        return panel {
            width = 600, padding = 16, gap = 12, radius = 28,
            shell.row { align = "center", gap = 10,
                text(GREETINGS[(os.time() // 3600) % #GREETINGS + 1], { font = font("Bold", 17) }),
                shell.spacer(),
                text("✦", { font = font("Bold", 14), color = P.accent }),
                text("✦", { font = font("Bold", 10), color = P.sun }),
                text("✦", { font = font("Bold", 12), color = P.accent_2 }),
            },
            field,
            shell.column { align = "stretch", gap = 4, rows },
        }
    end,
    on_key = function(key, typed)
        local list = results()
        if key == "Escape" then
            shell.close("toon-launcher")
        elseif key == "Return" or key == "KP_Enter" then
            choose(list[L.selected])
        elseif key == "Down" or key == "Tab" then
            if #list > 0 then L.selected = L.selected % #list + 1 end
        elseif key == "Up" or key == "ISO_Left_Tab" then
            if #list > 0 then L.selected = (L.selected - 2) % #list + 1 end
        elseif key == "BackSpace" then
            local cut = utf8.offset(L.query, -1)
            if cut then L.query = L.query:sub(1, cut - 1) end
            L.selected = 1
        elseif typed ~= "" and #L.query + #typed < 120 then
            L.query = L.query .. typed
            L.selected = 1
        end
        shell.redraw()
    end,
}

-- ---- screenshots ---------------------------------------------------------------
-- Print opens this over the live screen: drag a region, point at a window, or
-- take the whole screen. It closes before the picture is taken, so it is not
-- in it. Tide's init.lua publishes the output and windows as `tide.shot`.

local Shot = { mode = "region", windows = {} }
local SHOT_MODES = { "region", "window", "screen" }
local SHOT_LABELS = { region = "Region", window = "Window", screen = "Screen" }
local SHOT_HINTS = {
    region = "Drag to select  ·  drag inside to move  ·  Enter to snap",
    window = "Click a window  ·  Enter takes the focused one",
    screen = "Click or press Enter",
}

-- "<output> <x> <y> <w> <h>|<x> <y> <w> <h> <focused> <app>|..."
local function shot_read()
    local raw = shell.compositor_value("tide.shot", "")
    local head, rest = raw:match("^([^|]*)|?(.*)$")
    local name, ox, oy, ow, oh = (head or ""):match("^(%S+) (-?%d+) (-?%d+) (%d+) (%d+)$")
    if not name then return false end
    ox, oy, ow, oh = tonumber(ox), tonumber(oy), tonumber(ow), tonumber(oh)
    if Shot.output ~= name then Shot.rect = nil end
    Shot.output, Shot.ox, Shot.oy, Shot.ow, Shot.oh = name, ox, oy, ow, oh
    Shot.windows = {}
    for x, y, w, h, focused, app in rest:gmatch("(-?%d+) (-?%d+) (%d+) (%d+) ([01]) ([^|]*)") do
        -- On this output, without the part scrolled past its edges.
        local x1, y1 = math.max(tonumber(x) - ox, 0), math.max(tonumber(y) - oy, 0)
        local x2 = math.min(tonumber(x) - ox + tonumber(w), ow)
        local y2 = math.min(tonumber(y) - oy + tonumber(h), oh)
        if x2 - x1 >= 8 and y2 - y1 >= 8 then
            Shot.windows[#Shot.windows + 1] = { x = x1, y = y1, w = x2 - x1, h = y2 - y1,
                focused = focused == "1", app = app }
        end
    end
    return true
end

local function shot_target()
    if Shot.mode == "region" then return Shot.rect end
    if Shot.mode == "screen" then return { screen = true } end
    if Shot.hovered then return Shot.hovered end
    for _, w in ipairs(Shot.windows) do if w.focused then return w end end
    return nil
end

-- Wait for the picture and say what became of it: without this a screenshot
-- looks like the picker just closing.
local function shot_report(path, tries)
    if exists(path) then
        shell.log("screenshot saved: " .. path)
        shell.notify("Snap! Screenshot saved",
            (path:gsub("^" .. home, "~")) .. (HAVE.wlcopy and "\nCopied to the clipboard"
                or "\nNot copied: wl-copy is not installed"), "Screenshot")
    elseif tries <= 0 then
        shell.log("screenshot failed: " .. path)
        shell.notify("Screenshot failed", "grim could not save " .. path, "Screenshot")
    else
        shell.after(100, function() shot_report(path, tries - 1) end)
    end
end

-- target: { x, y, w, h } in the output's coordinates, or { screen = true }.
local function shot_capture(target)
    if not target then return end
    local dir = (os.getenv("XDG_PICTURES_DIR") or (home .. "/Pictures")) .. "/Screenshots"
    local path = string.format("%s/Screenshot from %s.png", dir, os.date("%Y-%m-%d %H-%M-%S"))
    local part = dir .. "/.screenshot.part"
    local what = target.screen and string.format("-o %q", Shot.output)
        or string.format("-g '%d,%d %dx%d'", Shot.ox + target.x, Shot.oy + target.y, target.w, target.h)
    shell.log("screenshot: " .. what)
    shell.close("toon-shot")
    -- Once this surface is off the screen.
    shell.after(150, function()
        shell.spawn(string.format("mkdir -p %q && grim %s %q && mv -f %q %q%s",
            dir, what, part, part, path,
            HAVE.wlcopy and string.format(" && wl-copy < %q", path) or ""))
        shot_report(path, 50)
    end)
end

local function shot_veil(ctx, hole)
    local veil = a(P.ink, 0.5)
    local function piece(x, y, w, h)
        if w <= 0 or h <= 0 then return false end
        return shell.box { left = x, top = y, width = w, height = h, background = veil }
    end
    if not hole then return { piece(0, 0, ctx.width, ctx.height) } end
    local x2, y2 = hole.x + hole.w, hole.y + hole.h
    return {
        piece(0, 0, ctx.width, hole.y),
        piece(0, y2, ctx.width, ctx.height - y2),
        piece(0, hole.y, hole.x, hole.h),
        piece(x2, hole.y, ctx.width - x2, hole.h),
    }
end

local function shot_frame(ctx, hole, label)
    local tag = label or string.format("%d × %d", hole.w, hole.h)
    local above = hole.y >= BAR + 34
    return {
        shell.canvas { left = hole.x - 2, top = hole.y - 2, width = hole.w + 4, height = hole.h + 4,
            { "rect", 2, 2, hole.w, hole.h, stroke = P.sun, width = 3, dash = { 10, 6 } } },
        shell.row { left = math.max(hole.x, 0), top = above and hole.y - 34 or hole.y + 10,
            height = 26, radius = 10, padding = { 0, 10 }, background = P.sun, border = P.ink,
            border_width = 2, shadow = S.drop(2), rotate = -2,
            text(tag, { font = font("Bold", 9.5) }) },
    }
end

local function shot_drag(ctx, info)
    local px = clamp(math.floor(info.px + 0.5), 0, ctx.width)
    local py = clamp(math.floor(info.py + 0.5), 0, ctx.height)
    if info.done then
        Shot.drag = nil
        if Shot.rect and (Shot.rect.w < 4 or Shot.rect.h < 4) then Shot.rect = nil end
    elseif not Shot.drag then
        local r = Shot.rect
        if r and px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then
            Shot.drag = { move = true, dx = px - r.x, dy = py - r.y }
        else
            Shot.drag = { x = px, y = py }
            Shot.rect = { x = px, y = py, w = 0, h = 0 }
        end
    elseif Shot.drag.move then
        local r = Shot.rect
        r.x = clamp(px - Shot.drag.dx, 0, ctx.width - r.w)
        r.y = clamp(py - Shot.drag.dy, 0, ctx.height - r.h)
    else
        local d = Shot.drag
        Shot.rect = { x = math.min(d.x, px), y = math.min(d.y, py),
            w = math.abs(px - d.x), h = math.abs(py - d.y) }
    end
    shell.redraw()
end

local function shot_set_mode(mode)
    Shot.mode, Shot.hovered = mode, nil
    shell.redraw()
end

local function shot_toolbar(ctx)
    local segments = {}
    for _, mode in ipairs(SHOT_MODES) do
        local on = mode == Shot.mode
        local id = "shot:mode:" .. mode
        segments[#segments + 1] = sticker({
            id = id, height = 36, radius = 12, padding = { 0, 14 }, depth = 2,
            background = on and P.sun or (ctx.hovered == id and P.cream or P.paper),
            on_click = function() shot_set_mode(mode) end,
            text(SHOT_LABELS[mode], { font = font(on and "Bold" or "Medium", 10.5) }),
        }, on)
    end
    local ready = shot_target() ~= nil
    return shell.column {
        bottom = 36, gap = 10, align = "center",
        sticker {
            gap = 10, padding = 8, radius = 22, align = "center", depth = 5, enter = S.POP,
            shell.row { gap = 6, segments },
            round("shot:take", "capture", 44, false, {
                background = ready and P.accent or P.cream, opacity = ready and 1 or 0.5,
                on_click = function() shot_capture(shot_target()) end }),
            round("shot:close", "close", 34, ctx.hovered == "shot:close", {
                on_click = function() shell.close("toon-shot") end }),
        },
        shell.row { height = 26, radius = 10, padding = { 0, 12 }, background = P.paper, border = P.ink,
            border_width = 2,
            text(SHOT_HINTS[Shot.mode], { font = font("Medium", 9.5) }) },
    }
end

shell.popup {
    name = "toon-shot",
    fill = true,
    keyboard = "exclusive",
    view = function(ctx)
        local layers = {}
        local function add(w) layers[#layers + 1] = w end
        if Shot.mode == "region" then
            add(shell.box { left = 0, top = 0, right = 0, bottom = 0, id = "shot:area",
                on_drag = function(info) shot_drag(ctx, info) end })
            local hole = Shot.rect and Shot.rect.w > 0 and Shot.rect.h > 0 and Shot.rect or nil
            add(shot_veil(ctx, hole))
            if hole then add(shot_frame(ctx, hole)) end
        elseif Shot.mode == "window" then
            add(shell.box { left = 0, top = 0, right = 0, bottom = 0, id = "shot:none" })
            -- The hit test takes the widget drawn last: the topmost window.
            for i = #Shot.windows, 1, -1 do
                local w = Shot.windows[i]
                add(shell.box { left = w.x, top = w.y, width = w.w, height = w.h, id = "shot:win:" .. i,
                    on_click = function() shot_capture(w) end })
            end
            Shot.hovered = nil
            for i, w in ipairs(Shot.windows) do
                if ctx.hovered == "shot:win:" .. i then Shot.hovered = w end
            end
            local target = shot_target()
            add(shot_veil(ctx, target))
            if target then add(shot_frame(ctx, target, target.app)) end
        else
            add(shell.box { left = 0, top = 0, right = 0, bottom = 0, id = "shot:whole",
                on_click = function() shot_capture({ screen = true }) end })
            add(shell.box { left = 0, top = 0, width = ctx.width, height = ctx.height,
                border = P.sun, border_width = 5 })
        end
        add(shot_toolbar(ctx))
        return shell.stack { width = ctx.width, height = ctx.height, justify = "center", layers }
    end,
    on_key = function(key)
        local k = key:lower()
        if k == "escape" then
            shell.close("toon-shot")
        elseif k == "return" or k == "kp_enter" or k == "space" then
            shot_capture(shot_target())
        elseif k == "tab" or k == "iso_left_tab" then
            local step = k == "tab" and 1 or -1
            for i, mode in ipairs(SHOT_MODES) do
                if mode == Shot.mode then
                    shot_set_mode(SHOT_MODES[(i - 1 + step) % #SHOT_MODES + 1])
                    break
                end
            end
        elseif k == "r" or k == "1" then shot_set_mode("region")
        elseif k == "w" or k == "2" then shot_set_mode("window")
        elseif k == "s" or k == "3" then shot_set_mode("screen")
        end
    end,
}

-- ---- power menu ----------------------------------------------------------------
-- A row of big candy buttons; the chosen one jumps up.

local power = { selected = 1 }

shell.popup {
    name = "toon-power",
    keyboard = "exclusive",
    input = "widgets",
    view = function(ctx)
        local buttons = {}
        for i, s in ipairs(SESSION) do
            local id = "pw:" .. s.id
            local sel = i == power.selected or ctx.hovered == id
            buttons[#buttons + 1] = shell.column {
                id = id, width = 100, height = 116, radius = 24, gap = 10, justify = "center", align = "center",
                animate = "bouncy",
                background = sel and s.color or P.paper,
                border = P.ink, border_width = 3,
                shadow = S.drop(sel and 6 or 3),
                translate = sel and { 0, -10 } or { 0, 0 },
                rotate = sel and (i % 2 == 0 and 3 or -3) or 0,
                enter = { opacity = 0, scale = 0.3, translate = { 0, 40 } },
                on_click = function() shell.close("toon-power"); s.run() end,
                shell.row { width = 48, height = 48, radius = 24, justify = "center",
                    background = sel and P.paper or s.color, border = P.ink, border_width = 2.5,
                    shell.icon(s.icon, { size = 22, stroke = 2.6, color = P.ink }) },
                text(s.label, { font = font("SemiBold", 11) }),
            }
        end
        return panel {
            padding = { 20, 22 }, gap = 16, radius = 30, align = "center",
            text("Bye for now, " .. user .. "!", { font = font("Bold", 17) }),
            shell.row { gap = 12, padding = { 10, 0, 0, 0 }, buttons },
            text("←  →  choose     ↵  confirm     Esc  stay", { font = font("Medium", 9.5), color = P.dim }),
        }
    end,
    on_key = function(key, typed)
        if key == "Escape" then shell.close("toon-power")
        elseif key == "Left" or key == "ISO_Left_Tab" then power.selected = (power.selected - 2) % #SESSION + 1
        elseif key == "Right" or key == "Tab" then power.selected = power.selected % #SESSION + 1
        elseif key == "Return" or key == "KP_Enter" then
            shell.close("toon-power")
            SESSION[power.selected].run()
        else
            for i, s in ipairs(SESSION) do
                if typed ~= "" and s.label:lower():sub(1, 1) == typed:lower() then power.selected = i end
            end
        end
        shell.redraw()
    end,
}

-- ---- OSD -----------------------------------------------------------------------

local osd = { kind = "volume", value = 0, muted = false, timer = nil, bump = 0 }

local function show_osd(kind, value, muted)
    osd.kind, osd.value, osd.muted = kind, value or 0, muted
    osd.bump = osd.bump + 1
    if not shell.is_open("toon-osd") then shell.open("toon-osd") end
    if osd.timer then shell.cancel(osd.timer) end
    osd.timer = shell.after(1400, function()
        osd.timer = nil
        shell.close("toon-osd")
    end)
    shell.redraw()
end

shell.popup {
    name = "toon-osd",
    anchor = { "bottom" },
    margin = { bottom = 70 },
    keyboard = "none",
    input = "widgets",
    view = function()
        local brightness = osd.kind == "brightness"
        local icon = brightness and "sun" or (osd.muted and "mute" or "volume")
        local colour = osd.muted and P.cream or (brightness and P.sun or P.accent)
        local f = clamp(osd.value / 100, 0, 1)
        return shell.column { padding = { 6, 14, 16, 8 },
            sticker {
                width = 300, padding = { 10, 12 }, radius = 26, gap = 12, depth = 5,
                enter = { opacity = 0, scale = 0.5, translate = { 0, 40 } },
                exit = { opacity = 0, scale = 0.7, translate = { 0, 30 } },
                shell.row { width = 38, height = 38, radius = 19, justify = "center",
                    background = colour, border = P.ink, border_width = 2.5,
                    -- A little hop on every press.
                    key = "osd:icon", animate = "bouncy", rotate = (osd.bump % 2 == 0) and -10 or 10,
                    shell.icon(icon, { size = 18, stroke = 2.6, color = P.ink }) },
                shell.row { grow = 1, height = 16, gap = 0, align = "center", radius = 8,
                    background = P.cream, border = P.ink, border_width = 2.5,
                    shell.box { key = "osd:a", grow = math.max(f, 0.0001), height = 11, radius = 6,
                        animate = QUICK, background = colour },
                    shell.box { key = "osd:b", grow = math.max(1 - f, 0.0001), height = 11, animate = QUICK },
                },
                text(tostring(math.floor(osd.value + 0.5)), { width = 30, text_align = 1, font = font("Bold", 12) }),
            },
        }
    end,
}

-- ---- lock screen ----------------------------------------------------------------
-- The clock large over the sky, a field for the password, and the
-- fingerprint reader listening at the same time when there is one. Any key
-- types into the field; Enter checks it, Escape clears it.

local LK = { password = "", busy = false, message = "", error = false, shake = 0,
    fingerprint = nil, checking = nil, at = 0 }
local FINGERPRINT_SERVICE = "shady-lock-fingerprint"

local function cancel_auth(field)
    if LK[field] then shell.cancel_authentication(LK[field]); LK[field] = nil end
end

local function listen_fingerprint()
    if LK.fingerprint or not shell.locked() or not exists("/etc/pam.d/" .. FINGERPRINT_SERVICE) then return end
    LK.fingerprint = shell.authenticate(nil, function(ok)
        LK.fingerprint = nil
        if ok then
            cancel_auth("checking")
            shell.unlock()
        elseif shell.locked() then
            -- Wrong finger or a timeout: listen again a little later.
            shell.after(1500, listen_fingerprint)
        end
    end, { service = FINGERPRINT_SERVICE, on_message = function(_, msg)
        if not LK.busy then LK.message, LK.error = msg, false end
    end })
end

local function reset_lock()
    LK.password, LK.busy, LK.message, LK.error = "", false, "", false
end

lock = function()
    shell.close("toon-control")
    shell.close("toon-power")
    shell.close("toon-launcher")
    if shell.locked() then return end
    reset_lock()
    LK.at = os.time()
    -- Without the helper no password would ever unlock it: swaylock instead.
    if shell.can_authenticate() and shell.lock() then
        listen_fingerprint()
    elseif HAVE.swaylock then
        shell.spawn("pidof swaylock >/dev/null || swaylock -f -c 8dd3ff")
    else
        shell.notify("Cannot lock the screen", "The compositor offers no session lock.", "Toon")
    end
end

local function submit()
    -- An empty password too: PAM decides whether the account takes one.
    if LK.busy then return end
    LK.busy, LK.message, LK.error = true, "Checking…", false
    local password = LK.password
    local started, id = pcall(shell.authenticate, password, function(ok, reason)
        LK.checking, LK.busy = nil, false
        if ok then
            cancel_auth("fingerprint")
            reset_lock()
            shell.unlock()
        else
            LK.password, LK.error = "", true
            LK.message = reason ~= "" and reason or "Oops! That wasn't it"
            LK.shake = LK.shake + 1
        end
        shell.redraw()
    end)
    if started then
        LK.checking = id
    else
        LK.busy, LK.password, LK.error = false, "", true
        LK.message = "Cannot check the password"
    end
end

shell.on("unlocked", function()
    cancel_auth("fingerprint")
    cancel_auth("checking")
    reset_lock()
end)

-- Big type with an ink drop behind it, as on a cartoon's title card.
local function title_card(s, size, colour)
    local f = font("Bold", size)
    local drop = math.max(3, math.floor(size / 16))
    return shell.stack {
        text(s, { font = f, color = P.ink, letter_spacing = 1, translate = { drop, drop + 1 } }),
        text(s, { font = f, color = colour or WHITE, letter_spacing = 1 }),
    }
end

shell.popup {
    name = "toon-lock",
    lock = true,
    keyboard = "exclusive",
    text_input = false,
    view = function(ctx)
        local level, status = sys.battery()
        local dots = {}
        local n = utf8.len(LK.password) or #LK.password
        for i = 1, math.min(n, 20) do
            dots[#dots + 1] = shell.box { key = "dot:" .. i, width = 14, height = 14, radius = 7,
                background = S.CANDY[(i - 1) % #S.CANDY + 1], border = P.ink, border_width = 2,
                enter = { opacity = 0, scale = 0.1, translate = { 0, -14 } }, animate = "bouncy" }
        end
        local field = shell.row {
            key = "lock:field:" .. LK.shake, width = 320, height = 54, radius = 27,
            padding = { 0, 20 }, gap = 6, align = "center", justify = n > 0 and "center" or "start",
            background = WHITE, border = LK.error and P.danger or P.ink, border_width = 3,
            shadow = S.drop(4),
            enter = LK.shake > 0 and { translate = { 22, 0 }, rotate = 3 } or nil, animate = "bouncy",
            n > 0 and dots or shell.row { gap = 10, align = "center",
                shell.icon("lock", { size = 16, stroke = 2.4, color = P.dim }),
                text("Password", { font = font("Medium", 12), color = P.dim }) },
        }
        local message = LK.message ~= "" and shell.row {
            key = "lock:msg:" .. LK.shake .. LK.message, height = 30, radius = 15, padding = { 0, 14 },
            background = LK.error and P.danger or P.paper, border = P.ink, border_width = 2.5,
            shadow = S.drop(2), enter = { opacity = 0, scale = 0.4 }, animate = "bouncy",
            text(LK.message, { font = font("SemiBold", 10.5), color = LK.error and WHITE or P.ink }),
        } or shell.box { height = 30 }
        return shell.stack {
            width = ctx.width, height = ctx.height, justify = "center",
            wallpaper.widget(ctx),
            shell.column {
                top = math.floor(ctx.height * 0.14), align = "center", gap = 0,
                enter = { opacity = 0, scale = 0.4, translate = { 0, -40 } }, animate = "bouncy",
                rotate = -2,
                title_card(shell.date("%H:%M"), 104),
                shell.row { height = 34, radius = 17, padding = { 0, 16 }, background = P.sun,
                    border = P.ink, border_width = 2.5, shadow = S.drop(3), rotate = 3,
                    text(shell.date("%A, %d %B"), { font = font("SemiBold", 13) }) },
            },
            shell.column {
                bottom = math.floor(ctx.height * 0.2), align = "center", gap = 14,
                enter = { opacity = 0, translate = { 0, 40 } }, animate = "bouncy",
                shell.row { width = 76, height = 76, radius = 38, justify = "center",
                    background = P.grape, border = P.ink, border_width = 3, shadow = S.drop(4),
                    rotate = LK.busy and 360 or -6, animate = "bouncy",
                    text(first_letter(user), { font = font("Bold", 28) }) },
                shell.row { height = 30, radius = 15, padding = { 0, 14 }, background = P.paper,
                    border = P.ink, border_width = 2.5,
                    text(user, { font = font("SemiBold", 12) }) },
                field,
                message,
            },
            level and shell.row { right = 28, bottom = 24, height = 32, radius = 16, padding = { 0, 12 },
                background = P.paper, border = P.ink, border_width = 2.5, shadow = S.drop(2),
                battery_badge(level, status) } or false,
        }
    end,
    on_key = function(key, typed)
        if key == "Return" or key == "KP_Enter" then
            submit()
        elseif key == "Escape" then
            LK.password, LK.message, LK.error = "", "", false
        elseif key == "BackSpace" then
            local cut = utf8.offset(LK.password, -1)
            if cut then LK.password = LK.password:sub(1, cut - 1) end
        elseif typed ~= "" and not LK.busy and #LK.password < 512 then
            LK.password = LK.password .. typed
            if LK.error then LK.message, LK.error = "", false end
        end
        shell.redraw()
    end,
}

-- A shell started (or restarted) while the session is locked takes the
-- lock over, so it can still be unlocked.
shell.on("value", function(k, v)
    if k == "session.lock" and v == "abandoned" then lock() end
end)

-- ---- keys from the compositor ------------------------------------------------

local function handle(action)
    local verb, arg = action:match("^(%S+)%s*(%S*)")
    if verb == "volume" then
        local v = sys.volume() or 50
        act.volume(v + (tonumber(arg) or 0))
        show_osd("volume", sys.volume(), false)
    elseif verb == "mute" then
        act.mute()
        local v, m = sys.volume()
        show_osd("volume", v, m)
    elseif verb == "mic-mute" then
        act.mic_mute()
        shell.notify(sys.mic_muted() and "Microphone muted" or "Microphone on", "", "Audio")
    elseif verb == "brightness" then
        local b = sys.brightness() or 50
        act.brightness(b + (tonumber(arg) or 0))
        show_osd("brightness", sys.brightness(), false)
    elseif verb == "media" then
        act.media(arg)
    elseif verb == "control" then
        shell.close("toon-launcher")
        shell.toggle("toon-control")
    elseif verb == "notifications" then
        shell.toggle("toon-control")
    elseif verb == "power" then
        power.selected = 1
        shell.toggle("toon-power")
    elseif verb == "lock" then
        lock()
    elseif verb == "shot" and arg ~= "" and HAVE.grim and shot_read() then
        -- Ctrl+Print and Alt+Print: no picker.
        if arg == "screen" then
            shot_capture({ screen = true })
        else
            for _, w in ipairs(Shot.windows) do
                if w.focused then
                    shot_capture(w)
                    break
                end
            end
        end
    elseif verb == "shot" then
        if shell.is_open("toon-shot") then
            shell.close("toon-shot")
        elseif HAVE.grim and shot_read() then
            shell.close("toon-launcher")
            shell.close("toon-control")
            shell.open("toon-shot", { output = Shot.output })
        else
            shell.notify("Cannot take a screenshot", "grim is not installed", "Screenshot")
        end
    end
end

-- Values already set are replayed when the shell connects; those are not
-- key presses.
local started = os.time()
shell.on("value", function(k, v)
    if not v then return end
    if k == "tide.do" then
        if os.time() - started < 2 then return end
        handle((v:gsub("%s+%d+$", "")))
    elseif k == "screenshot.saved" and os.time() - started >= 2 then
        shell.notify("Snap! Screenshot saved", (v:gsub("^" .. home, "~")), "Screenshot")
    end
end)

-- The control center replaces the toasts while it is open.
shell.on("change", sync_toasts)

-- ---- shortcuts (Super+Shift+/) -------------------------------------------------

require("shortcut_overlay").install {
    name = "toon-shortcuts",
    palette = { text = P.ink, text_dim = P.dim, accent = P.accent, surface = P.paper },
    backdrop = a(P.ink, 0.45),
    title = "Shortcuts!",
    title_font = font("Bold", 17),
    font = font("Medium", 10),
    bold = font("SemiBold", 10),
    columns = 3,
    order = { "Windows", "Workspaces", "Shell", "Shady" },
    cap = function()
        return { radius = 8, font = font("Bold", 9), color = P.ink, background = P.sun, border = P.ink }
    end,
    frame = function(body)
        return panel { radius = 28, padding = 24, body }
    end,
}

-- The Settings application changed something: draw the shell again with it.
do
    local seen = shell.compositor_value("tide.settings")
    shell.on("value", function(k, v)
        if k == "tide.settings" and v and v ~= seen then
            seen = v
            shell.reload()
        end
    end)
end

-- ---- what a config built on Toon can use -----------------------------------

return {
    style = S, P = P, font = font, text = text, sticker = sticker, island = island, panel = panel,
    round = round, tile = tile, slider = slider, has = has, sys = sys, act = act,
    lock = function() lock() end, wallpaper = wallpaper,
}
