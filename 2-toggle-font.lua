--[[
  Toggles between two configured fonts in reflowable-documents.
  Fonts are configurable from within KOReader itself,
  and the toggle is exposed as a Gesture Manager action.

  INSTALL
    1. Copy this file to: koreader/patches/2-toggle-font.lua
    2. Restart KOReader.
    3. Open a book, then: Reader menu > "More tools" tab >
       "Toggle font" > pick a font under "Font A" and "Font B".
       (Until you pick, it falls back to the DEFAULT_FONT_A/B below.)
    4. Bind the gesture: Settings > Taps and gestures > Gesture
       manager > pick a gesture > Reflowable documents > "Toggle font".
--]]

local Dispatcher = require("dispatcher")
local ReaderFont = require("apps/reader/modules/readerfont")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local T = require("ffi/util").template
local _ = require("gettext")

-- Fallback defaults, used only until you pick fonts from the menu.
local DEFAULT_FONT_A = "KF Libron"
local DEFAULT_FONT_B = "Fast_serif"

local SETTING_A = "toggle_font_font_a"
local SETTING_B = "toggle_font_font_b"

local function getFontA()
    return G_reader_settings:readSetting(SETTING_A) or DEFAULT_FONT_A
end

local function getFontB()
    return G_reader_settings:readSetting(SETTING_B) or DEFAULT_FONT_B
end

-- Builds a checkable list of all installed fonts for the given setting key
local function buildFontPickerTable(setting_key)
    local cre = require("document/credocument"):engineInit()
    local fonts = cre.getFontFaces()
    table.sort(fonts)
    local items = {}
    for _, font_name in ipairs(fonts) do
        table.insert(items, {
            text = font_name,
            checked_func = function()
                return G_reader_settings:readSetting(setting_key) == font_name
            end,
            callback = function()
                G_reader_settings:saveSetting(setting_key, font_name)
            end,
        })
    end
    return items
end

-- Add a "Toggle font" settings entry to the reader menu
local orig_addToMainMenu = ReaderFont.addToMainMenu
ReaderFont.addToMainMenu = function(self, menu_items)
    orig_addToMainMenu(self, menu_items)
    menu_items.toggle_font_settings = {
        text = _("Toggle font"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text_func = function()
                    return T(_("Font A: %1"), getFontA())
                end,
                sub_item_table = buildFontPickerTable(SETTING_A),
            },
            {
                text_func = function()
                    return T(_("Font B: %1"), getFontB())
                end,
                sub_item_table = buildFontPickerTable(SETTING_B),
            },
        },
    }
end

-- Gesture Manager action: toggle between Font A and Font B
local DEBOUNCE_S = 1.5
local last_trigger

Dispatcher:registerAction("toggle_font", {
    category = "none",
    event = "ToggleFont",
    title = _("Toggle font"),
    rolling = true, -- only offered for reflowable documents
})

function ReaderFont:onToggleFont()
    local now = time.now()
    if last_trigger and time.to_s(time.since(last_trigger)) < DEBOUNCE_S then
        return true -- swallow accidental double-trigger (e.g. long corner hold)
    end
    last_trigger = now

    local font_a, font_b = getFontA(), getFontB()
    local target = (self.font_face == font_a) and font_b or font_a
    self:onSetFont(target)
    UIManager:show(Notification:new{
        text = _("Font: ") .. target,
        timeout = 1,
    })
    return true
end
