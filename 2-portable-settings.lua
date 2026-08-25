--[[
Portable Settings — export/import a device-agnostic subset of
G_reader_settings through a Syncthing-synced file.

Design:
  * WHITELIST (prefix-heavy). Only keys matching a prefix (or the small
    exact-key set) are exported. Import re-applies the SAME filter, so a
    hand-edited or stale file can never inject a hardware key.
  * Export  -> filter G_reader_settings -> write portable_settings.lua
  * Import  -> read file -> re-filter -> saveSetting each -> flush ->
               offer restart (settings apply cleanly on next launch).
  * Gestures, patches, styletweaks, wallpapers are NOT handled here —
    they are byte-identical across devices and ride Syncthing directly.

Install: drop in koreader/patches/2-portable-settings.lua
Menu:    Reader menu > More tools > Portable settings (open a book).
         Also hooked into the file manager menu.

Verify against your build (APIs drift between versions):
  * UIManager restart call (see do_import)
--]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local ConfirmBox  = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager   = require("ui/uimanager")
local Device      = require("device")
local logger      = require("logger")
local _           = require("gettext")
local T           = require("ffi/util").template

local SCHEMA    = 1
local SYNC_FILE = DataStorage:getDataDir() .. "/portable_settings.lua"

--------------------------------------------------------------------
-- Whitelist: prefix-heavy, with an exact-key set for standalone prefs.
--
-- The test for inclusion: does this key hold a LOGICAL PREFERENCE that
-- means the same thing on any device? Include it.
-- Does it hold a per-device VALUE, PATH, or transient STATE (frontlight
-- level, geo coords, a filesystem path, a "was it on last time" flag,
-- a migration/first-run marker)? Exclude it.
--
-- "Hardware-related" is NOT the test — auto_restore_wifi is a boolean
-- behavior pref and travels; autowarmth_latitude is a bound geographic
-- value and does not. swipe_to_go_back is a setting, not a gesture, and
-- lives here (not in gestures.lua), so it must be exported to travel.
--------------------------------------------------------------------
local KEEP_PREFIXES = {
    -- Typography / rendering (the core of it)
    "copt_",           -- change-options: font size, margins, line spacing, gamma...
    "font",            -- font_size, font_face, font_hinting, font_menu_sort...
    "cre_",            -- crengine typesetting + header (cre_header_*) config
    "style_tweaks",    -- enabled style-tweak toggles (CSS files ride Syncthing)
    "hyph_",           -- hyphenation algorithm + soft-hyphen trust
    "word_",           -- word_spacing, word_expansion
    "render_dpi",

    -- UI / view / status display
    "show_",           -- show_bottom_menu, show_filter, show_hidden...
    "view_",
    "status_bar",
    "footer",          -- footer, footer_presets
    "reader_footer",   -- reader_footer_mode/custom_text (NOT caught by "footer")
    "highlight_",      -- highlight_dialog_position, highlight_lighten_factor...
    "bookmarks_items", -- bookmark list appearance
    "reading_insights",-- insights popup/chart display prefs
    "panel_zoom",      -- comic/manga panel-zoom behavior prefs

    -- Input / navigation BEHAVIOR (logical prefs, not bindings or hardware)
    "page_turns_",     -- tap-zone ratios, swipe-always, disable-tap (all logical)
    "autoturn_",       -- auto page-turn distance/timeout

    -- Dictionary popup prefs (dict names, not paths)
    "dict_",
}

-- Standalone preference keys with no tidy shared prefix.
local KEEP_EXACT = {
    -- Navigation behavior
    ["swipe_to_go_back"]        = true,
    ["back_in_filemanager"]     = true,
    ["back_in_reader"]          = true,
    ["back_to_exit"]            = true,
    ["start_with"]              = true,
    ["open_last_menu_show_filename"] = true,

    -- Input behavior (prefs, not bindings; gestures.lua rides Syncthing separately)
    ["multiswipes_enabled"]     = true,
    ["inertial_scroll"]         = true,
    ["scroll_method"]           = true,
    ["page_turn_animation_steps"] = true,
    ["ges_tap_interval_on_keyboard_ms"] = true,

    -- Wifi BEHAVIOR (booleans/actions, not SSIDs or bound state)
    ["auto_restore_wifi"]       = true,
    ["wifi_enable_action"]      = true,
    ["wifi_disable_action"]     = true,
    -- wifi_was_on is transient state -> excluded on purpose

    -- Reading / language / display-format prefs
    ["default_highlight_action"] = true,
    ["text_lang_fallback"]      = true,
    ["collate"]                 = true,
    ["history_filter"]          = true,
    ["duration_format"]         = true,
    ["dimension_units"]         = true,
    ["toc_items_per_page"]      = true,
    ["book_map_ten_pages_markers"] = true,
    ["bookshelf_hero_regions"]  = true,

    -- Keyboard (soft-keyboard layout/appearance, not physical keys)
    ["keyboard_layout"]         = true,
    ["keyboard_layouts"]        = true,
    ["keyboard_key_font_size"]  = true,

    -- Housekeeping behavior
    ["auto_save_settings_interval_minutes"] = true,

    -- Plugin config that's portable IF the same dicts/plugins exist on
    -- each device. Harmless-but-inert if a referenced item is missing.
    ["dicts_order"]             = true,
    ["dicts_disabled"]          = true,   -- drop if your dict sets differ per device
    ["wikipedia_languages"]     = true,
    ["vocabulary_builder"]      = true,
    ["statistics"]              = true,   -- plugin config (not the DB); drop if it holds a path

    -- Which plugins are explicitly disabled. Safe to sync HERE because
    -- your plugins/ folder rides Syncthing, so the plugin set is mirrored
    -- across devices. Disabling-by-name of a platform-specific plugin that
    -- isn't present on the target simply no-ops -> fails safe either way.
    ["plugins_disabled"]        = true,

    -- Fonts chosen in the toggle-font patch (2-toggle-font.lua). Font NAMES,
    -- portable because fonts ride Syncthing; without these the other devices
    -- fall back to that patch's DEFAULT_FONT_A/B.
    ["toggle_font_font_a"]      = true,
    ["toggle_font_font_b"]      = true,

    -- Screensaver PREFERENCES only — message text, backgrounds, stretch/scale,
    -- layout, timing. The screensaver_*_dir / _folder PATH keys are
    -- deliberately NOT listed (they differ per device); listing these keys
    -- explicitly, rather than a blanket "screensaver_" prefix, is what keeps
    -- the paths out.
    ["screensaver_message"]                   = true,
    ["screensaver_show_message"]              = true,
    ["screensaver_hide_fallback_msg"]         = true,
    ["screensaver_msg_background"]            = true,
    ["screensaver_img_background"]            = true,
    ["screensaver_message_alpha"]             = true,
    ["screensaver_message_position"]          = true,
    ["screensaver_message_vertical_position"] = true,
    ["screensaver_message_container"]         = true,
    ["screensaver_stretch"]                   = true,
    ["screensaver_stretch_images"]            = true,
    ["screensaver_stretch_limit_percentage"]  = true,
    ["screensaver_rotate_auto_for_best_fit"]  = true,
    ["screensaver_delay"]                     = true,
    -- Borderline: which screensaver kind (cover/random-image/message). Portable
    -- as a value, but if set to a dir-based mode the per-device dir differs.
    -- Wallpapers ride Syncthing to a mirrored location, so usually fine:
    ["screensaver_type"]                      = true,
    ["screensaver_mode"]                      = true,
    -- NOT included (paths / unknown): screensaver_dir, screensaver_images_dir,
    --   screensaver_folder, screensaver_random_dir, screensaver_banner

    ----------------------------------------------------------------
    -- BORDERLINE-BY-INTENT: portable values you may WANT different per
    -- device (e-reader vs phone). Uncomment to sync them too.
    ----------------------------------------------------------------
    -- ["auto_standby_timeout_seconds"]   = true,
    -- ["auto_suspend_timeout_seconds"]   = true,
    -- ["autoshutdown_timeout_seconds"]   = true,
    -- ["autodim_duration_seconds"]       = true,
    -- ["autodim_fraction"]               = true,
    -- ["autodim_starttime_minutes"]      = true,
    -- ["refresh_on_chapter_boundaries"]  = true,  -- eink-semantic; inert elsewhere

    ----------------------------------------------------------------
    -- OPT-IN plugin families (highest risk of referencing a missing
    -- plugin/path on the target). Enable per key only if you run the
    -- plugin on every device. Left OUT by default:
    --   rakuyomi_*, zlibrary_* (has a download_dir path!), rssreader_*,
    --   terminal_*, httpinspector_port
    ----------------------------------------------------------------

    ----------------------------------------------------------------
    -- DELIBERATELY EXCLUDED (do not add — here so the reasoning is on record):
    --   home_dir, lastdir, lastfile, *_dir, *_folder, folder_shortcuts,
    --     document_metadata_folder            -> per-device PATHS
    --   frontlight_*, is_frontlight_on, night_mode, *full_refresh_count,
    --     dev_no_c_blitter                     -> hardware / eink values
    --   autowarmth_*                           -> bound geo values (lat/long/tz)
    --   device_id, device_status_*, closed_rotation_mode,
    --     input_invert_page_turn_keys, input_lock_gsensor -> device-bound
    --   screensaver_dir/_images_dir/_folder/_random_dir, screensaver_banner
    --                                          -> per-device PATHS (the
    --                                             screensaver PREF keys ARE synced above)
    --   kosync, provider                       -> account / sync state
    --   *_migrated*, quickstart_shown_version, last_migration_date,
    --     coverbrowser_initial_default_setup_done, glimpse_gesture_tip_shown,
    --     profiles_autoexec, filemanagermenu_tab_index -> first-run / transient state
    --   debug, debug_verbose                   -> dev flags
    ----------------------------------------------------------------
}

local function is_portable(k)
    if type(k) ~= "string" then return false end
    if KEEP_EXACT[k] then return true end
    for _, p in ipairs(KEEP_PREFIXES) do
        if k:sub(1, #p) == p then return true end
    end
    return false
end

local function filtered(src)
    local out = {}
    for k, v in pairs(src) do
        if is_portable(k) then out[k] = v end
    end
    return out
end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--------------------------------------------------------------------
-- Export
--------------------------------------------------------------------
local function do_export()
    local payload = {
        _schema   = SCHEMA,
        _source   = Device.model or "unknown",
        _time     = os.time(),
        settings  = filtered(G_reader_settings.data),
    }
    -- LuaSettings gives us serpent-backed atomic write in KOReader's own format.
    local store = LuaSettings:open(SYNC_FILE)
    store.data = payload
    store:flush()
    UIManager:show(InfoMessage:new{
        text = T(_("Exported %1 settings for sync."), count(payload.settings)),
    })
end

--------------------------------------------------------------------
-- Import & merge
--------------------------------------------------------------------
local function do_import()
    local store = LuaSettings:open(SYNC_FILE)
    local payload = store.data
    if not payload or type(payload) ~= "table" then
        UIManager:show(InfoMessage:new{ text = _("No settings file found to import.") })
        return
    end
    if payload._schema ~= SCHEMA then
        UIManager:show(InfoMessage:new{
            text = T(_("Settings file schema (%1) does not match this patch (%2)."),
                     tostring(payload._schema), tostring(SCHEMA)),
        })
        return
    end

    -- Re-filter on import: never trust the file to contain only safe keys.
    local incoming = filtered(payload.settings or {})
    local n = count(incoming)
    if n == 0 then
        UIManager:show(InfoMessage:new{ text = _("Nothing portable to import.") })
        return
    end

    UIManager:show(ConfirmBox:new{
        text = T(_("Import %1 settings from %2?\nKOReader will restart to apply."),
                 n, tostring(payload._source or "unknown")),
        ok_text = _("Import & restart"),
        ok_callback = function()
            for k, v in pairs(incoming) do
                G_reader_settings:saveSetting(k, v)
            end
            G_reader_settings:flush()
            -- VERIFY this call on your build. Common variants:
            --   UIManager:restartKOReader()
            --   UIManager:broadcastEvent(require("ui/event"):new("Restart"))
            UIManager:restartKOReader()
        end,
    })
end

--------------------------------------------------------------------
-- Debug: dump the live keyspace so you can tune KEEP_PREFIXES.
-- Writes a sorted key list to koreader/portable_keys_dump.txt and
-- also flags which keys the current whitelist would export.
--------------------------------------------------------------------
local function do_dump_keys()
    local keys = {}
    for k in pairs(G_reader_settings.data) do
        if type(k) == "string" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local path = DataStorage:getDataDir() .. "/portable_keys_dump.txt"
    local f = io.open(path, "w")
    if not f then
        UIManager:show(InfoMessage:new{ text = _("Could not write key dump.") })
        return
    end
    for _, k in ipairs(keys) do
        f:write(string.format("%s %s\n", is_portable(k) and "[x]" or "[ ]", k))
    end
    f:close()
    logger.info("portable-settings: key dump ->", path)
    UIManager:show(InfoMessage:new{
        text = T(_("Dumped %1 keys to portable_keys_dump.txt\n[x] = will export"), #keys),
    })
end

--------------------------------------------------------------------
-- Menu registration
--
-- Pattern proven on this build (see 2-toggle-font.lua): hook the
-- addToMainMenu of a module already registered with the menu system,
-- and use sorting_hint to place the entry under Tools > More tools.
-- This avoids the version-fragile menu-order tables entirely.
--------------------------------------------------------------------
local menu_entry = {
    text = _("Portable settings"),
    sorting_hint = "more_tools",
    sub_item_table = {
        {
            text = _("Export settings (this device -> sync)"),
            callback = do_export,
        },
        {
            text = _("Import settings (sync -> this device)"),
            callback = do_import,
        },
        {
            text = _("Dump setting keys (debug)"),
            callback = do_dump_keys,
        },
    },
}

-- Reader menu: hook ReaderFont, a module always present in an open
-- document (the same module the toggle-font patch hooks). Reliably
-- lands the entry under Reader menu > More tools.
local ReaderFont = require("apps/reader/modules/readerfont")
local orig_reader_addToMainMenu = ReaderFont.addToMainMenu
ReaderFont.addToMainMenu = function(self, menu_items)
    orig_reader_addToMainMenu(self, menu_items)
    menu_items.portable_settings = menu_entry
end

-- File manager menu: also expose the entry from the browser (no open
-- document). The file manager's section layout differs from the reader's,
-- so sorting_hint may not map to a "More tools" tab there — the entry
-- will still be present, possibly at top level. Wrapped defensively.
local ok_fm, FileManagerMenu = pcall(require, "apps/filemanager/filemanagermenu")
if ok_fm and FileManagerMenu and FileManagerMenu.addToMainMenu then
    local orig_fm_addToMainMenu = FileManagerMenu.addToMainMenu
    FileManagerMenu.addToMainMenu = function(self, menu_items)
        orig_fm_addToMainMenu(self, menu_items)
        menu_items.portable_settings = menu_entry
    end
end
