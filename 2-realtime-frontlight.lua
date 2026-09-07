-- Real-time frontlight + warmth: press-and-hold on a screen edge, then drag
-- up/down to change the value *live*, instead of only on swipe release.
--   left edge  -> brightness
--   right edge -> warmth (only on devices with natural light)

local ok, err = pcall(function()

    local Device = require("device")
    if not Device:hasFrontlight() then return end

    local ReaderHighlight = require("apps/reader/modules/readerhighlight")
    local Screen = Device.screen

    local EDGE_W     = 1/8   -- width of each edge strip, as a screen-width ratio
    local DRAG_SCALE = 0.8   -- full-height drag ~= full range; lower = touchier

    local function clamp(v, lo, hi)
        if v < lo then return lo elseif v > hi then return hi else return v end
    end

    -- Built fresh at grab time so a drag always starts from the live value.
    local function intensity_channel()
        local p = Device:getPowerDevice()
        return {
            cur = p:frontlightIntensity(),          -- native
            min = p.fl_min,
            max = p.fl_max,
            set = function(v) Device:getPowerDevice():setIntensity(v) end,
        }
    end

    local function warmth_channel()
        local p = Device:getPowerDevice()
        return {
            cur = p:toNativeWarmth(p:frontlightWarmth() or 0),  -- normalized -> native
            min = p.fl_warmth_min,
            max = p.fl_warmth_max,
            -- native -> normalized (inverse of toNativeWarmth); setWarmth re-rounds
            set = function(v) Device:getPowerDevice():setWarmth(v * p.warmth_scale) end,
        }
    end

    function ReaderHighlight:_rtflBegin(ges, make_channel)
        local c = make_channel()
        self._rtfl = { y0 = ges.pos.y, v0 = c.cur, min = c.min, max = c.max,
                       set = c.set, last = c.cur }
        return true
    end

    function ReaderHighlight:_rtflUpdate(ges)
        local s = self._rtfl
        if not s then return true end
        local range  = s.max - s.min
        local scale  = Screen:getHeight() * DRAG_SCALE
        local delta  = (s.y0 - ges.pos.y) / scale * range   -- up = increase
        local target = clamp(math.floor(s.v0 + delta + 0.5), s.min, s.max)
        if target ~= s.last then
            s.set(target)
            s.last = target
        end
        return true
    end

    function ReaderHighlight:_rtflEnd()
        self._rtfl = nil
        return true
    end

    local function edge_zones(self, suffix, make_channel, ratio_x)
        local zone = { ratio_x = ratio_x, ratio_y = 0, ratio_w = EDGE_W, ratio_h = 1 }
        return {
            {
                id = "patch_rtfl_hold_" .. suffix,
                ges = "hold",
                screen_zone = zone,
                overrides = { "readerhighlight_hold" },
                handler = function(ges) return self:_rtflBegin(ges, make_channel) end,
            },
            {
                id = "patch_rtfl_hold_pan_" .. suffix,
                ges = "hold_pan",
                screen_zone = zone,
                overrides = { "readerhighlight_hold_pan" },
                handler = function(ges) return self:_rtflUpdate(ges) end,
            },
            {
                id = "patch_rtfl_hold_release_" .. suffix,
                ges = "hold_release",
                screen_zone = zone,
                overrides = { "readerhighlight_hold_release" },
                handler = function(ges) return self:_rtflEnd(ges) end,
            },
        }
    end

    local _orig_onReaderReady = ReaderHighlight.onReaderReady
    function ReaderHighlight:onReaderReady(...)
        if _orig_onReaderReady then _orig_onReaderReady(self, ...) end
        local zones = edge_zones(self, "fl", intensity_channel, 0)
        if Device:hasNaturalLight() then
            for _, z in ipairs(edge_zones(self, "warmth", warmth_channel, 1 - EDGE_W)) do
                table.insert(zones, z)
            end
        end
        self.ui:registerTouchZones(zones)
    end

end)

if not ok then
    require("logger").warn("[realtime-frontlight] setup failed:", err)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = "realtime-frontlight error:\n" .. tostring(err) })
end
