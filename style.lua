-- Toon's look: paper, ink and candy colours. Everything the shell draws is a
-- sticker: a flat colour, a thick ink outline and a hard shadow offset down
-- and to the right, as in a cartoon.
--
-- Colours come from, in order: the overrides passed in (the `palette` option
-- of shell.base("toon", ...)), the SHADY_SHELL_* environment, Toon's own.

local DEFAULTS = {
    ink = "#231A35",      -- outlines, shadows and text
    paper = "#FFF8EC",    -- what stickers are cut from
    cream = "#FFEBCB",    -- a second paper, for tracks and wells
    dim = "#7C6F8F",      -- quiet text
    accent = "#FF6F91",   -- bubblegum
    accent_2 = "#5CC8FF", -- sky
    sun = "#FFD23F",
    mint = "#5EE0A0",
    grape = "#A98BFF",
    peach = "#FF9F5A",
    danger = "#FF4F5E",
}
local ENVIRONMENT = {
    accent = "SHADY_SHELL_ACCENT", accent_2 = "SHADY_SHELL_ACCENT_2", danger = "SHADY_SHELL_DANGER",
}

return function(overrides)
    overrides = overrides or {}
    local a = shell.alpha
    local P = {}
    for name, default in pairs(DEFAULTS) do
        local env = ENVIRONMENT[name] and os.getenv(ENVIRONMENT[name])
        P[name] = overrides[name] or (env and env ~= "" and env) or default
    end
    -- Tide's names, for code shared with it (the shortcut overlay, plugins).
    P.text, P.surface, P.good, P.warn = P.ink, P.paper, P.mint, P.sun

    -- Fredoka is round and friendly; Jua draws Hangul in the same spirit.
    local S = { P = P, FAMILY = "Fredoka,Jua", INK = 2.5, BAR = 54, ISLAND = 36 }

    -- The candy colours, in the order things that need one take them.
    S.CANDY = { P.accent, P.sun, P.accent_2, P.mint, P.grape, P.peach }
    function S.candy(name)
        local h = 0
        for i = 1, #(name or "") do h = (h * 31 + name:byte(i)) % 997 end
        return S.CANDY[h % #S.CANDY + 1]
    end

    function S.font(weight, size) return S.FAMILY .. " " .. weight .. " " .. size end

    function S.text(s, props)
        props = props or {}
        props.color = props.color or P.ink
        props.font = props.font or S.font("Medium", 10)
        props.letter_spacing = props.letter_spacing or 0.2
        return shell.text(s, props)
    end

    -- A hard cartoon shadow, `depth` pixels down and right.
    function S.drop(depth) return { depth, depth + 1, P.ink } end

    -- A sticker: a flat shape with an ink outline and a hard shadow. It
    -- lifts a little under the pointer and is pressed in when `pressed`.
    function S.sticker(props, pressed)
        props.background = props.background or P.paper
        props.border = props.border or P.ink
        props.border_width = props.border_width or S.INK
        props.radius = props.radius or 14
        props.animate = props.animate == nil and "bouncy" or props.animate
        local depth = props.depth or 3
        props.depth = nil
        if pressed then
            props.shadow, props.translate = S.drop(1), { depth - 1, depth - 1 }
        else
            props.shadow = props.shadow or S.drop(depth)
            if props.id and props.hover == nil then
                props.hover = { translate = { -1, -2 }, shadow = S.drop(depth + 2) }
            end
        end
        return props.direction == "column" and shell.column(props) or shell.row(props)
    end

    -- A pill of the bar, stuck on a little crooked.
    function S.island(props)
        props.height = S.ISLAND
        props.radius = props.radius or 18
        props.padding = props.padding or { 0, 12 }
        props.gap = props.gap or 10
        props.align = "center"
        props.enter = props.enter or { opacity = 0, scale = 0.4, translate = { 0, -30 } }
        return S.sticker(props)
    end

    -- How panels pop in and out: from small and crooked to full size, with
    -- an overshoot.
    S.POP = { opacity = 0, scale = 0.55, rotate = -5, translate = { 0, -24 } }
    S.UNPOP = { opacity = 0, scale = 0.8, rotate = 4, translate = { 0, -10 } }

    -- The card every panel is drawn on. The padding around it is where its
    -- shadow falls (a surface shows nothing past its edge).
    function S.panel(props)
        props.direction = "column"
        props.radius = props.radius or 24
        props.align = props.align or "stretch"
        props.border_width = props.border_width or 3
        props.depth = props.depth or 6
        props.enter, props.exit = props.enter or S.POP, props.exit or S.UNPOP
        local card = S.sticker(props)
        return shell.column { padding = { 6, 14, 16, 8 }, align = "stretch", card }
    end

    -- A round button holding an icon.
    function S.round(id, icon, size, hovered, props)
        props = props or {}
        props.id, props.width, props.height = id, size, size
        props.radius, props.justify = size / 2, "center"
        props.depth = props.depth or 2
        props.background = props.background or (hovered and P.cream or P.paper)
        props[#props + 1] = shell.icon(icon, { size = math.floor(size * 0.46), stroke = 2.4,
            color = props.color or P.ink })
        props.color = nil
        return S.sticker(props)
    end

    -- The uniforms of shaders/toon.frag, the cartoon sky.
    S.SKY_UNIFORMS = { ink = P.ink, accent = P.accent }

    return S
end
