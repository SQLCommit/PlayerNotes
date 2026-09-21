-- PlayerNotes profile list, ratings, tags, notes, and notifications.
-- Author: SQLCommit

require 'common';

local imgui = require 'imgui';
local chat  = require 'chat';   -- Write-failure warnings.

local ui = {};

local state       = require 'ui_state';
local ui_settings = require 'ui_settings';
ui_settings.bind(ui);

-- Module references (set during init)
ui.db      = nil;
ui.context = nil;
ui.settings = nil;

-- Window state
ui.is_open = { true, };
ui.reset_pending = false;
ui.settings_dirty = false;

-- Settings popout window
ui.show_settings = { false, };

-- Add Player popup window
ui.show_add_player = { false, };

-- Tag definitions (order matters for UI)
ui.tag_defs = T{
    { id = 'Healer',  color = { 0.4, 1.0, 0.4, 1.0 }, tip = 'WHM, SCH, etc.' },
    { id = 'Tank',    color = { 0.4, 0.7, 1.0, 1.0 }, tip = 'PLD, RUN, etc.' },
    { id = 'DPS',     color = { 1.0, 0.4, 0.4, 1.0 }, tip = 'WAR, SAM, etc.' },
    { id = 'Mage',    color = { 0.6, 0.4, 1.0, 1.0 }, tip = 'BLM, SMN, etc.' },
    { id = 'Support', color = { 0.7, 0.6, 1.0, 1.0 }, tip = 'BRD, COR, etc.' },
    { id = 'Crafter', color = { 1.0, 0.7, 0.3, 1.0 }, tip = 'Crafting partners.' },
    { id = 'Friend',  color = { 0.4, 1.0, 1.0, 1.0 }, tip = 'Triggers party and nearby alerts.' },
    { id = 'Avoid',   color = { 0.8, 0.2, 0.2, 1.0 }, tip = 'Warning alerts and red row highlight.' },
    { id = 'Mentor',  color = { 1.0, 0.85, 0.0, 1.0 }, tip = 'Helpful teachers.' },
};

-- Tag color lookup
ui.tag_colors = {};
for _, td in ipairs(ui.tag_defs) do
    ui.tag_colors[td.id] = td.color;
end

-- Player list search
ui.search_buf = { '', };
ui.search_buf_size = 128;

-- Selected player detail
ui.selected_player_id = nil;

-- Add note input (inside detail panel)
ui.add_note_buf = { '', };
ui.add_note_size = 512;

-- Edit note state
ui.edit_note_id = nil;
ui.edit_note_buf = { '', };
ui.edit_note_size = 512;

-- Delete confirmations
ui.confirm_delete_player = nil;
ui.confirm_delete_note = nil;

-- Add Player popup inputs
ui.new_name_buf = { '', };
ui.new_name_size = 32;
ui.new_rating = 0;
ui.new_tags = {};
ui.new_note_buf = { '', };
ui.new_note_size = 512;

-- Tag filter (inline on toolbar)
ui.tag_filter = nil;

-- From Target / Save error feedback
ui.target_err = nil;
ui.target_err_time = nil;

-- Sort state (column-based, matching ImGui sort specs)
-- Column IDs: 0=Name, 1=Rating, 2=Tags(nosort), 3=Notes(nosort), 4=Last Seen
ui.sort_col = 0;
ui.sort_asc = true;

-- Toast system
ui.toasts = T{};
ui.toast_duration = 5.0;
ui.alerted_players = {};

-- Settings input buffers
ui.setting_check_interval = { 10, };
ui.setting_toast_x = { 10, };
ui.setting_toast_y = { 40, };
ui.setting_toast_duration = { 5, };

-- Advanced toast settings window
ui.show_advanced_toast = { false, };

-- Advanced toast slider buffers
ui.setting_fade_in        = { 0.0, };
ui.setting_fade_out       = { 1.0, };
ui.setting_bg_opacity     = { 0.8, };
ui.setting_bg_color       = { 0.11, 0.11, 0.14, };
ui.setting_stack_spacing  = { 40, };
ui.setting_max_visible    = { 10, };
ui.setting_toast_rounding = { 0, };
ui.setting_toast_border   = { 0.0, };
ui.setting_toast_border_color = { 0.43, 0.43, 0.50, };
ui.setting_slide_in   = { 0.3, };
ui.setting_slide_out  = { 0.5, };
ui.setting_slide_dir  = { 0, };  -- 0=Left, 1=Right, 2=Top, 3=Bottom
ui.setting_bounce_speed = { 0.35, };
ui.setting_color_player_alert  = { 0.4, 1.0, 1.0, };
ui.setting_color_friend_alert  = { 0.4, 1.0, 0.4, };
ui.setting_color_friend_nearby = { 0.3, 0.8, 0.3, };
ui.setting_color_avoid_alert   = { 1.0, 0.3, 0.3, };
ui.setting_color_avoid_nearby  = { 1.0, 0.6, 0.3, };
ui.setting_color_disband       = { 0.4, 1.0, 1.0, };
ui.setting_sound_player_alert_file  = { 'player_alert.wav', };
ui.setting_sound_friend_alert_file  = { 'friend_alert.wav', };
ui.setting_sound_friend_nearby_file = { 'friend_nearby.wav', };
ui.setting_sound_avoid_alert_file   = { 'avoid_alert.wav', };
ui.setting_sound_avoid_nearby_file  = { 'avoid_nearby.wav', };
ui.setting_sound_disband_file       = { 'disband.wav', };
ui.setting_sound_file_size          = 64;
-- Disband popup state
ui.disband_open = false;
ui.disband_members = T{};

-- Table salt for reset
ui.table_salt = 0;


-- Player table resize
local table_user_h = nil;  -- nil = auto-size, number = user-dragged height
local table_dragging = false;
local table_drag_start_y = 0;
local table_drag_start_h = 0;
local resize_bar_u32 = nil;
local resize_bar_hover_u32 = nil;

-- Colors (shared palette lives in ui_state)
local colors = state.colors;

-- Cached ImU32 colors (computed once, not per-frame)
local avoid_row_color = nil; -- deferred until first render (imgui must be loaded)
local card_bg_u32 = nil;
local card_pinned_u32 = nil;
local accent_gold_u32 = nil;
local accent_gray_u32 = nil;
local shadow_u32 = nil;
local u32_colors_ready = false;   -- one sentinel for the whole palette (see init_u32_colors)
local panel_bg_u32 = nil;
local panel_border_u32 = nil;

-- Note card height cache (two-pass rendering: first pass measures, second draws)
local note_heights = {};
local last_detail_player_id = nil;

-- Section panel heights (two-pass: measure this frame, draw next frame)
local detail_panel_h = nil;
local notes_panel_h = nil;

-- Pre-computed star display strings (avoids per-row string concat at 60fps)
local star_strings = { [0] = '-', '*', '**', '***', '****', '*****' };

-- Cached References
local string_format = string.format;

-- Bound pending toast backlog; evict only the oldest unseen entries.
local TOAST_MAX_QUEUED = 32;

-- Reserve resize-handle height below the table to avoid overflowing its child.
local RESIZE_BAR_H = 6;
local toast_uid_counter = 0;
local function next_toast_uid() toast_uid_counter = toast_uid_counter + 1; return toast_uid_counter; end
local os_date = os.date;
local os_clock = os.clock;
local math_min = math.min;
local math_max = math.max;
local tostring = tostring;

-- Initialization

local function sync_color_buf(buf, src, d1, d2, d3)
    buf[1] = src[1] or d1;
    buf[2] = src[2] or d2;
    buf[3] = src[3] or d3;
end

local function sync_advanced_buffers(s)
    ui.setting_fade_in[1]       = s.toast_fade_in or 0.0;
    ui.setting_fade_out[1]      = s.toast_fade_out or 1.0;
    ui.setting_bg_opacity[1]    = s.toast_bg_opacity or 0.8;
    ui.setting_stack_spacing[1] = s.toast_stack_spacing or 40;
    ui.setting_max_visible[1]   = s.toast_max_visible or 10;
    ui.setting_toast_rounding[1] = s.toast_rounding or 0;
    ui.setting_toast_border[1]   = s.toast_border or 0.0;
    sync_color_buf(ui.setting_toast_border_color, s.toast_border_color or {}, 0.43, 0.43, 0.50);
    ui.setting_slide_in[1]  = s.toast_slide_in or 0.3;
    ui.setting_slide_out[1] = s.toast_slide_out or 0.5;
    ui.setting_slide_dir[1] = s.toast_slide_dir or 0;
    ui.setting_bounce_speed[1] = s.toast_bounce_speed or 0.35;

    sync_color_buf(ui.setting_bg_color, s.toast_bg_color or {}, 0.11, 0.11, 0.14);
    sync_color_buf(ui.setting_color_player_alert, s.toast_color_player_alert or {}, 0.4, 1.0, 1.0);
    sync_color_buf(ui.setting_color_friend_alert, s.toast_color_friend_alert or {}, 0.4, 1.0, 0.4);
    sync_color_buf(ui.setting_color_friend_nearby, s.toast_color_friend_nearby or {}, 0.3, 0.8, 0.3);
    sync_color_buf(ui.setting_color_avoid_alert, s.toast_color_avoid_alert or {}, 1.0, 0.3, 0.3);
    sync_color_buf(ui.setting_color_avoid_nearby, s.toast_color_avoid_nearby or {}, 1.0, 0.6, 0.3);
    sync_color_buf(ui.setting_color_disband, s.toast_color_disband or {}, 0.4, 1.0, 1.0);

    ui.setting_sound_player_alert_file[1]  = s.toast_sound_player_alert_file or 'player_alert.wav';
    ui.setting_sound_friend_alert_file[1]  = s.toast_sound_friend_alert_file or 'friend_alert.wav';
    ui.setting_sound_friend_nearby_file[1] = s.toast_sound_friend_nearby_file or 'friend_nearby.wav';
    ui.setting_sound_avoid_alert_file[1]   = s.toast_sound_avoid_alert_file or 'avoid_alert.wav';
    ui.setting_sound_avoid_nearby_file[1]  = s.toast_sound_avoid_nearby_file or 'avoid_nearby.wav';
    ui.setting_sound_disband_file[1]       = s.toast_sound_disband_file or 'disband.wav';
end

function ui.init(db, context, s, defaults)
    ui.db       = db;
    ui.context  = context;
    ui.settings = s;
    ui.defaults = defaults;
    ui.setting_check_interval[1] = s.player_check_interval or 10;
    ui.setting_toast_x[1] = s.toast_x or 10;
    ui.setting_toast_y[1] = s.toast_y or 40;
    ui.setting_toast_duration[1] = s.toast_duration or 5;
    ui.toast_duration = s.toast_duration or 5;
    sync_advanced_buffers(s);
end

function ui.sync_settings()
    if (ui.settings == nil) then return; end
    ui.settings.player_check_interval = ui.setting_check_interval[1];
    ui.settings.toast_x = ui.setting_toast_x[1];
    ui.settings.toast_y = ui.setting_toast_y[1];
    ui.settings.toast_duration = ui.setting_toast_duration[1];

    -- Advanced toast
    ui.settings.toast_fade_in       = ui.setting_fade_in[1];
    ui.settings.toast_fade_out      = ui.setting_fade_out[1];
    ui.settings.toast_bg_opacity    = ui.setting_bg_opacity[1];
    ui.settings.toast_stack_spacing = ui.setting_stack_spacing[1];
    ui.settings.toast_max_visible   = ui.setting_max_visible[1];
    ui.settings.toast_rounding      = ui.setting_toast_rounding[1];
    ui.settings.toast_border        = ui.setting_toast_border[1];
    ui.settings.toast_border_color  = T{ ui.setting_toast_border_color[1], ui.setting_toast_border_color[2], ui.setting_toast_border_color[3] };
    ui.settings.toast_slide_in  = ui.setting_slide_in[1];
    ui.settings.toast_slide_out = ui.setting_slide_out[1];
    ui.settings.toast_slide_dir = ui.setting_slide_dir[1];
    ui.settings.toast_bounce_speed = ui.setting_bounce_speed[1];

    ui.settings.toast_bg_color = T{
        ui.setting_bg_color[1], ui.setting_bg_color[2], ui.setting_bg_color[3],
    };
    ui.settings.toast_color_player_alert = T{
        ui.setting_color_player_alert[1], ui.setting_color_player_alert[2], ui.setting_color_player_alert[3],
    };
    ui.settings.toast_color_friend_alert = T{
        ui.setting_color_friend_alert[1], ui.setting_color_friend_alert[2], ui.setting_color_friend_alert[3],
    };
    ui.settings.toast_color_friend_nearby = T{
        ui.setting_color_friend_nearby[1], ui.setting_color_friend_nearby[2], ui.setting_color_friend_nearby[3],
    };
    ui.settings.toast_color_avoid_alert = T{
        ui.setting_color_avoid_alert[1], ui.setting_color_avoid_alert[2], ui.setting_color_avoid_alert[3],
    };
    ui.settings.toast_color_avoid_nearby = T{
        ui.setting_color_avoid_nearby[1], ui.setting_color_avoid_nearby[2], ui.setting_color_avoid_nearby[3],
    };
    ui.settings.toast_color_disband = T{
        ui.setting_color_disband[1], ui.setting_color_disband[2], ui.setting_color_disband[3],
    };

    ui.settings.toast_sound_player_alert_file  = (ui.setting_sound_player_alert_file[1] or ''):gsub('%z+$', '');
    ui.settings.toast_sound_friend_alert_file  = (ui.setting_sound_friend_alert_file[1] or ''):gsub('%z+$', '');
    ui.settings.toast_sound_friend_nearby_file = (ui.setting_sound_friend_nearby_file[1] or ''):gsub('%z+$', '');
    ui.settings.toast_sound_avoid_alert_file   = (ui.setting_sound_avoid_alert_file[1] or ''):gsub('%z+$', '');
    ui.settings.toast_sound_avoid_nearby_file  = (ui.setting_sound_avoid_nearby_file[1] or ''):gsub('%z+$', '');
    ui.settings.toast_sound_disband_file       = (ui.setting_sound_disband_file[1] or ''):gsub('%z+$', '');
end

function ui.apply_settings(s)
    ui.settings = s;
    ui.setting_check_interval[1] = s.player_check_interval or 10;
    ui.setting_toast_x[1] = s.toast_x or 10;
    ui.setting_toast_y[1] = s.toast_y or 40;
    ui.setting_toast_duration[1] = s.toast_duration or 5;
    ui.toast_duration = s.toast_duration or 5;
    sync_advanced_buffers(s);
end

-- Helpers

local function tid(name)
    return name .. '_s' .. tostring(ui.table_salt);
end

local function fmt_time(ts)
    if (ts == nil or ts == 0) then return ''; end
    return os_date('%m/%d %H:%M', ts);
end

local function fmt_date(ts)
    if (ts == nil or ts == 0) then return ''; end
    return os_date('%m/%d', ts);
end

local trim_buf = state.trim_buf;

--- Parse comma-separated tags string into a set table.
local function parse_tags(tag_str)
    local set = {};
    if (tag_str == nil or tag_str == '') then return set; end
    for tag in tag_str:gmatch('[^,]+') do
        local trimmed = tag:match('^%s*(.-)%s*$');
        if (trimmed ~= '') then
            set[trimmed] = true;
        end
    end
    return set;
end

--- Build comma-separated tags string from a set table.
local function tags_to_string(tag_set)
    local parts = {};
    for _, td in ipairs(ui.tag_defs) do
        if (tag_set[td.id]) then
            parts[#parts + 1] = td.id;
        end
    end
    return table.concat(parts, ',');
end

--- Render inline star rating. Returns new rating if changed, nil if unchanged.
local function render_stars(label, current_rating)
    local new_rating = nil;
    for i = 1, 5 do
        if (i > 1) then imgui.SameLine(0, 2); end
        local is_on = (i <= current_rating);
        imgui.PushStyleColor(ImGuiCol_Text, is_on and colors.star_on or colors.star_off);
        if (imgui.Button((is_on and '*' or '.') .. '##star_' .. label .. '_' .. i)) then
            if (i == current_rating) then
                new_rating = 0;
            else
                new_rating = i;
            end
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip(i == current_rating and 'Click to clear rating' or (i .. ' star' .. (i > 1 and 's' or '')));
        end
        imgui.PopStyleColor();
    end
    return new_rating;
end

-- Initialize all panel colors together; shared sentinels must not leave a partial palette.
local function init_u32_colors()
    if (u32_colors_ready) then return; end
    u32_colors_ready = true;

    card_bg_u32      = imgui.ColorConvertFloat4ToU32({ colors.card_bg[1], colors.card_bg[2], colors.card_bg[3], colors.card_bg[4] });
    card_pinned_u32  = imgui.ColorConvertFloat4ToU32({ colors.card_pinned[1], colors.card_pinned[2], colors.card_pinned[3], colors.card_pinned[4] });
    accent_gold_u32  = imgui.ColorConvertFloat4ToU32({ colors.accent_gold[1], colors.accent_gold[2], colors.accent_gold[3], colors.accent_gold[4] });
    accent_gray_u32  = imgui.ColorConvertFloat4ToU32({ colors.accent_gray[1], colors.accent_gray[2], colors.accent_gray[3], colors.accent_gray[4] });
    shadow_u32       = imgui.ColorConvertFloat4ToU32({ 0.0, 0.0, 0.0, 0.15 });
    panel_bg_u32     = imgui.ColorConvertFloat4ToU32({ 0.22, 0.22, 0.26, 1.0 });
    panel_border_u32 = imgui.ColorConvertFloat4ToU32({ 0.35, 0.35, 0.40, 1.0 });
end

--- Render tag toggle buttons. Modifies tag_set in-place. Returns true if changed.
local function render_tag_toggles(label, tag_set)
    local changed = false;
    for i, td in ipairs(ui.tag_defs) do
        if (i > 1) then imgui.SameLine(0, 2); end
        local is_on = (tag_set[td.id] == true);
        if (is_on) then
            imgui.PushStyleColor(ImGuiCol_Button, td.color);
            imgui.PushStyleColor(ImGuiCol_Text, { 0.0, 0.0, 0.0, 1.0 });
        else
            imgui.PushStyleColor(ImGuiCol_Button, { 0.25, 0.25, 0.25, 1.0 });
            imgui.PushStyleColor(ImGuiCol_Text, td.color);
        end
        if (imgui.Button(td.id .. '##tag_' .. label .. '_' .. i)) then
            tag_set[td.id] = not is_on;
            changed = true;
        end
        imgui.PopStyleColor(2);
        if (imgui.IsItemHovered() and td.tip) then
            imgui.PushStyleColor(ImGuiCol_Text, td.color);
            imgui.SetTooltip(td.id .. ': ' .. td.tip);
            imgui.PopStyleColor();
        end
    end
    return changed;
end

--- Render colored tag chips (read-only, inline).
local function render_tag_chips(tag_str)
    if (tag_str == nil or tag_str == '') then return; end
    local first = true;
    for tag in tag_str:gmatch('[^,]+') do
        local trimmed = tag:match('^%s*(.-)%s*$');
        local color = ui.tag_colors[trimmed];
        if (color ~= nil) then
            if (not first) then imgui.SameLine(0, 4); end
            imgui.TextColored(color, trimmed);
            first = false;
        end
    end
end

--- In-memory sort for tag-filtered results.
local function sort_players_list(players, sort_col, sort_asc)
    table.sort(players, function(a, b)
        if (sort_col == 0) then
            if (sort_asc) then
                return (a.player_name or ''):lower() < (b.player_name or ''):lower();
            else
                return (a.player_name or ''):lower() > (b.player_name or ''):lower();
            end
        elseif (sort_col == 1) then
            if (a.rating ~= b.rating) then
                if (sort_asc) then return a.rating < b.rating; end
                return a.rating > b.rating;
            end
            return (a.player_name or ''):lower() < (b.player_name or ''):lower();
        elseif (sort_col == 4) then
            if (sort_asc) then return (a.updated_at or 0) < (b.updated_at or 0); end
            return (a.updated_at or 0) > (b.updated_at or 0);
        end
        -- Default: name ascending
        return (a.player_name or ''):lower() < (b.player_name or ''):lower();
    end);
end

-- Toast System

-- Color and sound lookup tables for 6 toast types
local toast_color_keys = {
    player_alert  = 'toast_color_player_alert',
    friend_alert  = 'toast_color_friend_alert',
    friend_nearby = 'toast_color_friend_nearby',
    avoid_alert   = 'toast_color_avoid_alert',
    avoid_nearby  = 'toast_color_avoid_nearby',
    disband       = 'toast_color_disband',
};
local toast_sound_file_keys = {
    player_alert  = 'toast_sound_player_alert_file',
    friend_alert  = 'toast_sound_friend_alert_file',
    friend_nearby = 'toast_sound_friend_nearby_file',
    avoid_alert   = 'toast_sound_avoid_alert_file',
    avoid_nearby  = 'toast_sound_avoid_nearby_file',
    disband       = 'toast_sound_disband_file',
};

-- Report each write-failure kind once per session.
local warned_write = {};
function ui.warn_write_failed(what)
    if (warned_write[what]) then return; end
    warned_write[what] = true;
    print(chat.header('playernotes'):append(chat.error(
        'Could not save that ' .. what .. ' -- the database refused the write. Your text was kept.')));
end

function ui.show_toast(text, toast_type, color)
    local s = ui.settings;

    -- Resolve default color from settings if no explicit override
    if (color == nil and s ~= nil and toast_type ~= nil) then
        local key = toast_color_keys[toast_type];
        if (key ~= nil) then
            local c = s[key] or { 0.4, 1.0, 1.0 };
            color = { c[1], c[2], c[3], 1.0 };
        end
    end

    -- Fallback color
    if (color == nil) then
        color = { 0.4, 1.0, 1.0, 1.0 };
    end

    -- Evict only unseen toasts; displayed warnings must finish their duration.
    while (#ui.toasts >= TOAST_MAX_QUEUED) do
        local victim = nil;
        for i, t in ipairs(ui.toasts) do
            if (t.start == nil) then victim = i; break; end
        end
        if (victim == nil) then break; end
        table.remove(ui.toasts, victim);
    end

    ui.toasts:append({
        text = text,
        -- Start the display clock on first draw, not while queued behind max_visible.
        queued = os_clock(),
        start = nil,
        color = color,
        -- Use stable IDs so removing a toast cannot redirect a click to its successor.
        uid = next_toast_uid(),
    });

    -- Sound: nil type = silent (visual only), master toggle gates all sounds
    -- Per-type sound controlled by file presence (clear filename to mute)
    if (toast_type ~= nil and s ~= nil and s.toast_sound_enabled ~= false) then
        local file_key = toast_sound_file_keys[toast_type];
        local sound_file = (file_key ~= nil and s[file_key]) or '';
        if (sound_file ~= '') then
            pcall(ashita.misc.play_sound, addon.path:append('\\sounds\\'):append(sound_file));
        end
    end
end

local function render_toasts()
    local now = os_clock();
    local remove = T{};
    local s = ui.settings;
    local duration = ui.toast_duration;
    local base_x = (s ~= nil and s.toast_x) or 10;
    local base_y = (s ~= nil and s.toast_y) or 40;

    -- Advanced settings (with safe defaults)
    local fade_enabled  = (s == nil) or (s.toast_fade_enabled ~= false);
    local fade_in       = (s ~= nil and s.toast_fade_in) or 0.0;
    local fade_out      = (s ~= nil and s.toast_fade_out) or 1.0;
    local bg_opacity    = (s ~= nil and s.toast_bg_opacity) or 0.8;
    local bg_color      = (s ~= nil and s.toast_bg_color) or nil;
    local stack_down    = (s == nil) or (s.toast_stack_down ~= false);
    local stack_spacing = (s ~= nil and s.toast_stack_spacing) or 40;
    local max_visible   = (s ~= nil and s.toast_max_visible) or 10;
    local click_dismiss = (s ~= nil and s.toast_click_dismiss);
    local slide_enabled = (s ~= nil and s.toast_slide_enabled);
    local slide_in      = (s ~= nil and s.toast_slide_in) or 0.3;
    local slide_out     = (s ~= nil and s.toast_slide_out) or 0.5;
    local slide_dir     = (s ~= nil and s.toast_slide_dir) or 0;
    local slide_bounce  = (s ~= nil and s.toast_slide_bounce);
    local bounce_speed  = (s ~= nil and s.toast_bounce_speed) or 0.35;

    local visible = 0;
    for i, toast in ipairs(ui.toasts) do
        local elapsed = (toast.start ~= nil) and (now - toast.start) or 0;
        if (toast.start ~= nil and elapsed > duration) then
            remove:append(i);
        elseif (visible < max_visible) then
            if (toast.start == nil) then toast.start = now; elapsed = 0; end
            visible = visible + 1;

            -- Alpha calculation with fade in/out
            local alpha = 1.0;
            if (fade_enabled) then
                if (fade_in > 0 and elapsed < fade_in) then
                    alpha = elapsed / fade_in;
                end
                if (fade_out > 0 and elapsed > duration - fade_out) then
                    alpha = math_min(alpha, (duration - elapsed) / fade_out);
                end
            end
            alpha = math_max(0.0, math_min(1.0, alpha));

            -- Position: stack direction
            local y_offset = (visible - 1) * stack_spacing;
            if (not stack_down) then y_offset = -y_offset; end

            -- Slide animation (independent timing)
            local x = base_x;
            local y_slide = 0;
            if (slide_enabled) then
                local sliding_in  = (slide_in > 0 and elapsed < slide_in);
                local sliding_out = (slide_out > 0 and elapsed > duration - slide_out);
                local slide_t = 1.0;
                if (sliding_in) then
                    slide_t = elapsed / slide_in;
                end
                if (sliding_out) then
                    slide_t = math_min(slide_t, (duration - elapsed) / slide_out);
                end
                slide_t = math_max(0.0, math_min(1.0, slide_t));
                -- Easing: bounce (elastic) on entry only, cubic on exit
                local eased;
                if (slide_bounce and sliding_in and not sliding_out) then
                    if (slide_t == 0 or slide_t == 1) then
                        eased = slide_t;
                    else
                        local p = bounce_speed;
                        eased = 2.0 ^ (-10.0 * slide_t) * math.sin((slide_t - p / 4.0) * 6.2831853 / p) + 1.0;
                    end
                else
                    -- Ease-out cubic for smooth deceleration
                    eased = 1.0 - (1.0 - slide_t) * (1.0 - slide_t) * (1.0 - slide_t);
                end
                local slide_dist = 300;
                local offset = slide_dist * (1.0 - eased);
                if (slide_dir == 0) then     -- From left
                    x = base_x - offset;
                elseif (slide_dir == 1) then -- From right
                    x = base_x + offset;
                elseif (slide_dir == 2) then -- From top
                    y_slide = -offset;
                else                         -- From bottom
                    y_slide = offset;
                end
            end
            imgui.SetNextWindowPos({ x, base_y + y_offset + y_slide }, ImGuiCond_Always);

            if (bg_color ~= nil) then
                imgui.PushStyleColor(ImGuiCol_WindowBg, {
                    bg_color[1] or 0.11, bg_color[2] or 0.11, bg_color[3] or 0.14, bg_opacity * alpha,
                });
            else
                imgui.SetNextWindowBgAlpha(bg_opacity * alpha);
            end

            local rounding = (s ~= nil and s.toast_rounding) or 0;
            local border   = (s ~= nil and s.toast_border) or 0.0;
            local bcol     = (s ~= nil and s.toast_border_color) or nil;
            imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, rounding);
            imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, border);
            if (bcol ~= nil) then
                imgui.PushStyleColor(ImGuiCol_Border, { bcol[1], bcol[2], bcol[3], alpha });
            end

            local flags = ImGuiWindowFlags_NoDecoration
                + ImGuiWindowFlags_AlwaysAutoResize
                + ImGuiWindowFlags_NoSavedSettings
                + ImGuiWindowFlags_NoFocusOnAppearing;
            if (not click_dismiss) then
                flags = flags + ImGuiWindowFlags_NoInputs;
            end

            if (imgui.Begin('##pn_toast_' .. tostring(toast.uid or i), nil, flags)) then
                local c = toast.color or { 0.4, 1.0, 1.0, 1.0 };
                imgui.TextColored({ c[1], c[2], c[3], alpha }, toast.text);

                -- Click to dismiss
                if (click_dismiss and imgui.IsWindowHovered() and imgui.IsMouseClicked(0)) then
                    remove:append(i);
                end
            end
            imgui.End();

            imgui.PopStyleVar(2);
            if (bcol ~= nil) then
                imgui.PopStyleColor();
            end
            if (bg_color ~= nil) then
                imgui.PopStyleColor();
            end
        end
    end

    -- Deduplicate removal indices and process them in reverse.
    local remove_set = {};
    for _, idx in ipairs(remove) do remove_set[idx] = true; end
    local sorted_remove = {};
    for idx in pairs(remove_set) do sorted_remove[#sorted_remove + 1] = idx; end
    table.sort(sorted_remove, function(a, b) return a > b; end);
    for _, idx in ipairs(sorted_remove) do
        table.remove(ui.toasts, idx);
    end
end

-- Disband Popup

-- Disband member card height cache (two-pass)
local disband_card_heights = {};
local disband_size_set = false;
local disband_cached_h = 0;

-- Members carry name and server_id to preserve identity on save.
function ui.show_disband_popup(members)
    -- Merge a second disband into an open popup without losing unfinished cards.
    local seen = {};
    if (ui.disband_open and #ui.disband_members > 0) then
        for _, m in ipairs(ui.disband_members) do seen[m.name] = true; end
    else
        ui.disband_members = T{};
    end

    ui.disband_open = true;
    disband_size_set = false;
    disband_cached_h = 0;
    disband_card_heights = {};

    for _, m in ipairs(members) do
        local name = m.name or m;
        local sid  = m.server_id or 0;
        if (not seen[name]) then
            seen[name] = true;
            ui.disband_members:append({
                name = name,
                server_id = sid,
                note_buf = { '', },
                note_size = 256,
                rating = 0,
                tag_set = {},
                saved = false,
            });
        end
    end
    if (ui.settings == nil or ui.settings.toast_sound_disband ~= false) then
        ui.show_toast('Party disbanded — add notes?', 'disband');
    end
end

local function render_disband_popup()
    if (not ui.disband_open) then return; end

    local num = #ui.disband_members;

    -- Use measured card heights when available, generous estimate otherwise
    local h;
    if (disband_cached_h > 0) then
        h = disband_cached_h;
    else
        h = 120 + num * 135;
    end

    if (not disband_size_set) then
        imgui.SetNextWindowSize({ 450, h }, ImGuiCond_Always);
        disband_size_set = true;
    end
    imgui.SetNextWindowSizeConstraints({ 300, h }, { 9999, h });

    local open = { true, };
    local flags = ImGuiWindowFlags_NoSavedSettings;

    if (imgui.Begin('Party Disbanded##pn', open, flags)) then
        local win_y = select(2, imgui.GetWindowPos());

        init_u32_colors();

        imgui.TextColored(colors.header, 'Your party has disbanded!');
        imgui.TextColored(colors.muted, 'Add notes about your party members?');
        imgui.Spacing();
        imgui.Spacing();

        local ddl = imgui.GetWindowDrawList();
        local dpad = 8;
        local dpanel_w = imgui.GetContentRegionAvail();

        local all_done = true;
        for i, member in ipairs(ui.disband_members) do
            imgui.PushID('disband_' .. i);

            local cx, cy = imgui.GetCursorScreenPos();
            local cached_h = disband_card_heights[i];

            -- Draw bubble using cached height
            if (cached_h ~= nil and cached_h > 0) then
                if (member.saved) then
                    local saved_bg = imgui.ColorConvertFloat4ToU32({ 0.15, 0.22, 0.15, 1.0 });
                    local saved_border = imgui.ColorConvertFloat4ToU32({ 0.3, 0.5, 0.3, 1.0 });
                    ddl:AddRectFilled({ cx + 3, cy + 3 }, { cx + dpanel_w + 3, cy + cached_h + 3 }, shadow_u32, 8.0);
                    ddl:AddRectFilled({ cx, cy }, { cx + dpanel_w, cy + cached_h }, saved_bg, 8.0);
                    ddl:AddRect({ cx, cy }, { cx + dpanel_w, cy + cached_h }, saved_border, 8.0);
                else
                    ddl:AddRectFilled({ cx + 3, cy + 3 }, { cx + dpanel_w + 3, cy + cached_h + 3 }, shadow_u32, 8.0);
                    ddl:AddRectFilled({ cx, cy }, { cx + dpanel_w, cy + cached_h }, panel_bg_u32, 8.0);
                    ddl:AddRect({ cx, cy }, { cx + dpanel_w, cy + cached_h }, panel_border_u32, 8.0);
                end
            end

            imgui.Dummy({ 0, dpad });

            if (not member.saved) then
                all_done = false;

                imgui.SetCursorPosX(imgui.GetCursorPosX() + dpad);
                imgui.TextColored(colors.player, member.name);
                -- Cache DB lookup per member (avoid querying every frame)
                if (member.existing == nil) then
                    member.existing = ui.db.get_player_by_name(member.name, member.server_id) or false;
                end
                local existing = (member.existing ~= false) and member.existing or nil;
                if (existing ~= nil) then
                    imgui.SameLine();
                    imgui.TextColored(colors.muted, '(has profile)');
                end

                imgui.SetCursorPosX(imgui.GetCursorPosX() + dpad);
                imgui.Text('Rating: ');
                imgui.SameLine();
                local new_r = render_stars('disband_' .. i, member.rating);
                if (new_r ~= nil) then member.rating = new_r; end

                -- New profiles expose tags here; existing tags remain editable in the detail panel.
                if (existing == nil) then
                    imgui.SetCursorPosX(imgui.GetCursorPosX() + dpad);
                    render_tag_toggles('disband_' .. i, member.tag_set);
                end

                imgui.SetCursorPosX(imgui.GetCursorPosX() + dpad);
                imgui.PushItemWidth(dpanel_w - dpad * 2 - 60);
                imgui.InputTextWithHint('##disband_note_' .. i, 'Add a note...', member.note_buf, member.note_size);
                imgui.PopItemWidth();
                imgui.SameLine();
                if (imgui.Button('Save##dsave_' .. i)) then
                    local note_text = trim_buf(member.note_buf[1]);
                    local zone_name = ui.context.get_zone_name();

                    -- Skip empty cards. Check enabled tags, not next(): disabled tags remain stored as
                    -- false.
                    local tag_str = tags_to_string(member.tag_set);
                    local has_input = member.rating > 0 or note_text ~= '' or tag_str ~= '';
                    local wrote = false;
                    if (has_input) then
                        -- Re-read the profile so saving cannot overwrite tags edited since the popup
                        -- opened.
                        local current = ui.db.get_player_by_name(member.name, member.server_id);

                        local player_id;
                        if (current ~= nil) then
                            player_id = current.id;
                            -- Merge selected tags with the current profile, including tags-only edits.
                            local merged = parse_tags(current.tags or '');
                            for tag, on in pairs(member.tag_set) do
                                if (on) then merged[tag] = true; end
                            end
                            local merged_str = tags_to_string(merged);
                            local new_rating = (member.rating > 0) and member.rating or (current.rating or 0);
                            if (new_rating ~= (current.rating or 0) or merged_str ~= (current.tags or '')) then
                                if (ui.db.update_player(player_id, new_rating, merged_str) ~= true) then
                                    player_id = nil;   -- the edit was rejected: do not report it saved
                                end
                            end
                        else
                            player_id = ui.db.add_player(member.name, member.rating, tag_str, member.server_id);
                        end

                        -- Report saved only after the database confirms the write.
                        wrote = (player_id ~= nil);
                        if (player_id ~= nil and note_text ~= '') then
                            wrote = (ui.db.add_note(player_id, note_text, zone_name) ~= nil);
                        end
                        if (wrote) then ui.db.bind_identity(player_id, member.server_id); end
                    end

                    -- Keep failed cards open for retry; collapse only empty or successfully saved cards.
                    member.written = has_input and wrote;
                    member.write_failed = has_input and not wrote;
                    member.saved = not member.write_failed;
                    if (member.write_failed) then ui.warn_write_failed('disband note'); end
                    disband_card_heights = {};
                end
                if (imgui.IsItemHovered()) then
                    imgui.SetTooltip('Save rating and note for this player.');
                end
                if (member.write_failed) then
                    imgui.SetCursorPosX(imgui.GetCursorPosX() + dpad);
                    imgui.TextColored(colors.error,
                        'Not saved -- the database refused the write. Your text is still here.');
                end
            else
                imgui.SetCursorPosX(imgui.GetCursorPosX() + dpad);
                if (member.written) then
                    imgui.TextColored(colors.success, member.name .. ' — Saved!');
                else
                    imgui.TextColored(colors.muted, member.name .. ' — Skipped (nothing entered)');
                end
            end

            imgui.Dummy({ 0, dpad });
            -- Measure card height for next frame
            local end_y = select(2, imgui.GetCursorScreenPos());
            disband_card_heights[i] = end_y - cy;

            imgui.PopID();
            imgui.Spacing();
            imgui.Spacing();
        end

        imgui.Spacing();
        if (all_done) then
            if (imgui.Button('Done')) then
                ui.disband_open = false;
                disband_card_heights = {};
            end
            if (imgui.IsItemHovered()) then
                imgui.SetTooltip('Close this popup. Every member has been handled.');
            end
        else
            if (imgui.Button('Skip')) then
                ui.disband_open = false;
                disband_card_heights = {};
            end
            if (imgui.IsItemHovered()) then
                imgui.SetTooltip('Close without saving remaining members.');
            end
        end

        -- Measure actual content height for next frame's constraints
        local end_y = select(2, imgui.GetCursorScreenPos());
        disband_cached_h = end_y - win_y + 8;
    end

    if (not open[1]) then
        ui.disband_open = false;
        disband_card_heights = {};
    end
    imgui.End();
end

-- Player Detail Panel (below table)

local function render_player_detail()
    if (ui.selected_player_id == nil) then return; end

    local player = ui.db.get_player_by_id(ui.selected_player_id);
    if (player == nil) then
        ui.selected_player_id = nil;
        return;
    end

    imgui.Spacing();
    imgui.Spacing();
    imgui.Spacing();

    -- Lazy-init U32 colors for panels
    local dl = imgui.GetWindowDrawList();
    init_u32_colors();

    local pad = 8;
    local panel_w = imgui.GetContentRegionAvail();

    -- Player Detail Bubble
    local det_x, det_y = imgui.GetCursorScreenPos();
    if (detail_panel_h ~= nil and detail_panel_h > 0) then
        dl:AddRectFilled({ det_x + 3, det_y + 3 }, { det_x + panel_w + 3, det_y + detail_panel_h + 3 }, shadow_u32, 8.0);
        dl:AddRectFilled({ det_x, det_y }, { det_x + panel_w, det_y + detail_panel_h }, panel_bg_u32, 8.0);
        dl:AddRect({ det_x, det_y }, { det_x + panel_w, det_y + detail_panel_h }, panel_border_u32, 8.0);
    end
    imgui.Dummy({ 0, pad });
    imgui.SetCursorPosX(imgui.GetCursorPosX() + pad);

    imgui.TextColored(colors.player, player.player_name);
    if ((player.server_id or 0) ~= 0) then
        imgui.SameLine();
        imgui.TextColored(colors.muted, '#' .. tostring(player.server_id));
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('This character\'s server id. A name can be freed and taken by someone else later; this is what tells them apart.');
        end
    else
        imgui.SameLine();
        imgui.TextColored(colors.muted, '(name only)');
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('This profile is not tied to a character yet, so it matches anyone of this name. Adding a note or rating while they are with you will tie it to them.');
        end
    end
    imgui.SameLine();
    imgui.TextColored(colors.muted, string_format('(since %s)', fmt_time(player.created_at)));

    -- Parse tags once for both rating and tag sections
    local tag_set = parse_tags(player.tags);

    -- Rating (editable stars)
    imgui.SetCursorPosX(imgui.GetCursorPosX() + pad);
    imgui.Text('Rating: ');
    imgui.SameLine();
    local new_rating = render_stars('detail', player.rating);
    if (new_rating ~= nil) then
        ui.db.update_player(player.id, new_rating, tags_to_string(tag_set));
    end

    -- Tags (editable toggles)
    imgui.SetCursorPosX(imgui.GetCursorPosX() + pad);
    imgui.Text('Tags:   ');
    imgui.SameLine();
    if (render_tag_toggles('detail', tag_set)) then
        ui.db.update_player(player.id, player.rating, tags_to_string(tag_set));
    end

    imgui.Dummy({ 0, pad });
    -- Measure detail panel height for next frame
    local det_end_y = select(2, imgui.GetCursorScreenPos());
    detail_panel_h = det_end_y - det_y;

    imgui.Spacing();
    imgui.Spacing();
    imgui.Spacing();
    imgui.Spacing();

    -- Notes Bubble
    local notes = ui.db.get_notes(player.id);
    local nt_x, nt_y = imgui.GetCursorScreenPos();
    if (notes_panel_h ~= nil and notes_panel_h > 0) then
        dl:AddRectFilled({ nt_x + 3, nt_y + 3 }, { nt_x + panel_w + 3, nt_y + notes_panel_h + 3 }, shadow_u32, 8.0);
        dl:AddRectFilled({ nt_x, nt_y }, { nt_x + panel_w, nt_y + notes_panel_h }, panel_bg_u32, 8.0);
        dl:AddRect({ nt_x, nt_y }, { nt_x + panel_w, nt_y + notes_panel_h }, panel_border_u32, 8.0);
    end
    imgui.Dummy({ 0, pad });
    imgui.SetCursorPosX(imgui.GetCursorPosX() + pad);
    imgui.TextColored(colors.header, string_format('Notes (%d)', #notes));

    -- Clear height caches when player changes
    if (last_detail_player_id ~= player.id) then
        note_heights = {};
        detail_panel_h = nil;
        notes_panel_h = nil;
        last_detail_player_id = player.id;
    end

    -- Add new note (multiline input with manual placeholder text)
    imgui.SetCursorPosX(imgui.GetCursorPosX() + pad);
    local note_input_x, note_input_y = imgui.GetCursorScreenPos();
    imgui.InputTextMultiline('##add_note', ui.add_note_buf, ui.add_note_size, { -(pad + 1), 50 });
    local buf_empty = (ui.add_note_buf[1] == nil or ui.add_note_buf[1] == '' or ui.add_note_buf[1]:byte(1) == 0);
    if (buf_empty and not imgui.IsItemActive()) then
        local hint_dl = imgui.GetWindowDrawList();
        local hint_color = imgui.ColorConvertFloat4ToU32({ colors.muted[1], colors.muted[2], colors.muted[3], 0.6 });
        hint_dl:AddText({ note_input_x + 4, note_input_y + 3 }, hint_color, 'Write a note...');
    end
    imgui.SetCursorPosX(imgui.GetCursorPosX() + pad);
    if (imgui.Button('+ Add##note')) then
        local note_text = trim_buf(ui.add_note_buf[1]);
        if (note_text ~= '') then
            local zone_name = ui.context.get_zone_name();
            -- Clear input only after the note is stored; preserve it on failure.
            if (ui.db.add_note(player.id, note_text, zone_name) ~= nil) then
                ui.db.bind_identity(player.id, ui.context.find_server_id(player.player_name));
                ui.add_note_buf[1] = '';
                note_heights = {};
            else
                ui.warn_write_failed('note');
            end
        end
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Add a new note. Current zone is saved automatically.');
    end
    imgui.Spacing();

    -- Scrollable notes region (inset within bubble, no border to avoid clipping)
    if (#notes > 0) then
        imgui.SetCursorPosX(imgui.GetCursorPosX() + pad);
        imgui.BeginChild('##notes_scroll', { -(pad + 1), -50 }, ImGuiChildFlags_None);
        local drawlist = imgui.GetWindowDrawList();
        local region_w = imgui.GetContentRegionAvail();

        for i, note in ipairs(notes) do
            imgui.PushID('note_' .. note.id);

            local is_pinned = (note.pinned == 1);
            local card_start_x, card_start_y = imgui.GetCursorScreenPos();

            -- Use the previous frame's measured height.
            local cached_h = note_heights[note.id];
            if (cached_h ~= nil and cached_h > 0) then
                local bg_color = is_pinned and card_pinned_u32 or card_bg_u32;
                local bar_color = is_pinned and accent_gold_u32 or accent_gray_u32;
                drawlist:AddRectFilled(
                    { card_start_x, card_start_y },
                    { card_start_x + region_w, card_start_y + cached_h },
                    bg_color, 4.0
                );
                -- Left accent bar (4px wide)
                drawlist:AddRectFilled(
                    { card_start_x, card_start_y + 2 },
                    { card_start_x + 4, card_start_y + cached_h - 2 },
                    bar_color, 2.0
                );
            end

            -- Indent past accent bar
            imgui.SetCursorPosX(imgui.GetCursorPosX() + 10);

            -- Header line: pin button + zone + date + actions
            local pin_label = 'Pin##pin';
            imgui.PushStyleColor(ImGuiCol_Text, is_pinned and colors.accent_gold or colors.muted);
            if (imgui.SmallButton(pin_label)) then
                if (ui.db.pin_note(note.id, player.id) ~= true) then ui.warn_write_failed('pin'); end
                note_heights = {};
            end
            if (imgui.IsItemHovered()) then
                imgui.SetTooltip(is_pinned and 'Unpin this note.' or 'Pin this note. Pinned notes appear first and show in alert toasts.');
            end
            imgui.PopStyleColor();
            imgui.SameLine();

            -- Zone name + date
            local meta = '';
            if (note.zone_name ~= nil and note.zone_name ~= '') then
                meta = note.zone_name .. '  ';
            end
            meta = meta .. fmt_time(note.created_at);
            imgui.TextColored(colors.muted, meta);

            if (is_pinned) then
                imgui.SameLine();
                imgui.TextColored(colors.accent_gold, '[Pinned]');
            end

            -- Action buttons (right-aligned on header line)
            imgui.SameLine();
            if (imgui.SmallButton('Edit##' .. note.id)) then
                if (ui.edit_note_id == note.id) then
                    ui.edit_note_id = nil;
                else
                    ui.edit_note_id = note.id;
                    ui.edit_note_buf[1] = note.note;
                    -- Size the edit buffer for imported notes plus spare capacity; never truncate on save.
                    ui.edit_note_size = math.max(512, #note.note + 256);
                end
            end
            if (imgui.IsItemHovered()) then
                imgui.SetTooltip(ui.edit_note_id == note.id and 'Close editor.' or 'Edit this note.');
            end
            imgui.SameLine();
            if (ui.confirm_delete_note == note.id) then
                imgui.TextColored(colors.error, 'Delete?');
                imgui.SameLine();
                if (imgui.SmallButton('Y##ndel')) then
                    if (ui.db.delete_note(note.id) ~= true) then ui.warn_write_failed('note deletion'); end
                    ui.confirm_delete_note = nil;
                    note_heights[note.id] = nil;
                end
                imgui.SameLine();
                if (imgui.SmallButton('N##ncan')) then
                    ui.confirm_delete_note = nil;
                end
            else
                if (imgui.SmallButton('x##del_' .. note.id)) then
                    ui.confirm_delete_note = note.id;
                end
                if (imgui.IsItemHovered()) then
                    imgui.SetTooltip('Delete this note.');
                end
            end

            -- Note body
            imgui.SetCursorPosX(imgui.GetCursorPosX() + 10);
            if (ui.edit_note_id == note.id) then
                -- Edit mode: multiline input
                imgui.InputTextMultiline('##edit_note', ui.edit_note_buf, ui.edit_note_size, { -10, 60 });
                imgui.SetCursorPosX(imgui.GetCursorPosX() + 10);
                if (imgui.Button('OK')) then
                    local new_text = trim_buf(ui.edit_note_buf[1]);
                    -- Keep rejected edits open for retry.
                    local edited = (new_text == '') or (ui.db.update_note(note.id, new_text) == true);
                    if (edited) then
                        ui.edit_note_id = nil;
                        note_heights = {};
                    else
                        ui.warn_write_failed('edited note');
                    end
                end
                imgui.SameLine();
                if (imgui.Button('Cancel')) then
                    ui.edit_note_id = nil;
                end
            else
                -- Display mode
                imgui.PushTextWrapPos(imgui.GetCursorPosX() + region_w - 20);
                -- Render literal text so percent signs in notes are not treated as format specifiers.
                imgui.TextUnformatted(note.note);
                imgui.PopTextWrapPos();
            end

            -- Measure card height for next frame
            local card_end_y = select(2, imgui.GetCursorScreenPos());
            note_heights[note.id] = card_end_y - card_start_y + 4;

            imgui.Spacing();
            if (i < #notes) then
                imgui.Separator();
            end

            imgui.PopID();
        end
        imgui.EndChild();
    else
        imgui.SetCursorPosX(imgui.GetCursorPosX() + pad);
        imgui.TextColored(colors.muted, 'No notes yet.');
    end

    imgui.Dummy({ 0, pad });
    -- Measure notes panel height for next frame
    local nt_end_y = select(2, imgui.GetCursorScreenPos());
    notes_panel_h = nt_end_y - nt_y;

    -- Delete player button
    imgui.Spacing();
    if (ui.confirm_delete_player == player.id) then
        imgui.TextColored(colors.error, 'Delete player and all notes?');
        imgui.SameLine();
        if (imgui.Button('Yes##pdel')) then
            if (ui.db.delete_player(player.id) ~= true) then ui.warn_write_failed('player deletion'); end
            ui.selected_player_id = nil;
            ui.confirm_delete_player = nil;
        end
        imgui.SameLine();
        if (imgui.Button('No##pcan')) then
            ui.confirm_delete_player = nil;
        end
    else
        if (imgui.Button('Delete Player')) then
            ui.confirm_delete_player = player.id;
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('Permanently delete this player and all their notes.');
        end
    end
    imgui.SameLine();
    if (imgui.Button('Close')) then
        ui.selected_player_id = nil;
        ui.confirm_delete_player = nil;
        ui.confirm_delete_note = nil;
        ui.edit_note_id = nil;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Close this player detail panel.');
    end
end

-- Player View (single page: toolbar + sortable table + detail panel)

local function render_players()
    -- Toolbar: Search box with hint
    imgui.PushItemWidth(160);
    imgui.InputTextWithHint('##player_search', 'Search...', ui.search_buf, ui.search_buf_size);
    imgui.PopItemWidth();

    -- Tags dropdown filter
    imgui.SameLine(0, 8);
    if (ui.tag_filter ~= nil) then
        local tc = ui.tag_colors[ui.tag_filter];
        imgui.PushStyleColor(ImGuiCol_Button, tc);
        imgui.PushStyleColor(ImGuiCol_Text, { 0.0, 0.0, 0.0, 1.0 });
    end
    local tag_label = ui.tag_filter or 'Tags';
    if (imgui.Button(tag_label .. '##tf_btn')) then
        imgui.OpenPopup('##pn_tag_popup');
    end
    if (ui.tag_filter ~= nil) then
        imgui.PopStyleColor(2);
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Filter by tag. Click again to change or clear.');
    end

    if (imgui.BeginPopup('##pn_tag_popup')) then
        if (imgui.MenuItem('All (clear filter)', '', ui.tag_filter == nil)) then
            ui.tag_filter = nil;
        end
        imgui.Separator();
        for _, td in ipairs(ui.tag_defs) do
            imgui.PushStyleColor(ImGuiCol_Text, td.color);
            if (imgui.MenuItem(td.id, '', ui.tag_filter == td.id)) then
                if (ui.tag_filter == td.id) then
                    ui.tag_filter = nil;
                else
                    ui.tag_filter = td.id;
                end
            end
            imgui.PopStyleColor();
        end
        imgui.EndPopup();
    end

    -- + Add button
    imgui.SameLine(0, 8);
    if (imgui.Button('+ Add##player')) then
        ui.show_add_player[1] = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Add a player by their character name.\nPlayer names only — no NPCs or monsters.\nLetters only, no spaces or numbers (auto-formatted: Firstname).\n3-15 characters.\nUse "From Target" to auto-fill from your current target (rejects NPCs).\nYou cannot track yourself.');
    end

    -- Get players (search > tag filter > all)
    local search_term = trim_buf(ui.search_buf[1]);
    local players;
    if (search_term ~= '') then
        players = ui.db.search_players(search_term);
        sort_players_list(players, ui.sort_col, ui.sort_asc);
    elseif (ui.tag_filter ~= nil) then
        players = ui.db.get_players_by_tag(ui.tag_filter);
        sort_players_list(players, ui.sort_col, ui.sort_asc);
    else
        players = ui.db.get_players(ui.sort_col, ui.sort_asc);
    end

    if (#players == 0) then
        imgui.Spacing();
        if (search_term ~= '') then
            imgui.TextColored(colors.muted, 'No players match "' .. search_term .. '".');
        elseif (ui.tag_filter ~= nil) then
            imgui.TextColored(colors.muted, 'No players tagged "' .. ui.tag_filter .. '".');
        else
            imgui.TextColored(colors.muted, 'No players tracked yet.');
            imgui.TextColored(colors.muted, 'Click + Add or use /pn <name> <note> to get started!');
        end
        return;
    end

    -- Player table (sortable, scrollable, max 10 rows visible)
    local table_flags = ImGuiTableFlags_RowBg
        + ImGuiTableFlags_BordersInnerH
        + ImGuiTableFlags_SizingStretchProp
        + ImGuiTableFlags_Resizable
        + ImGuiTableFlags_Sortable
        + ImGuiTableFlags_ScrollY;

    local row_height = imgui.GetTextLineHeightWithSpacing();
    local header_height = row_height + 4;
    local min_table_h = header_height + row_height;
    local table_h;
    if (table_user_h ~= nil) then
        table_h = math_max(table_user_h, min_table_h);
    else
        local max_rows = 10;
        local detail_height = (ui.selected_player_id ~= nil) and 300 or 0;
        -- Validate the binding's content-height return before sizing the table.
        local _a, _b = imgui.GetContentRegionAvail();
        local avail_h = (type(_b) == 'number' and _b) or (type(_a) == 'number' and _a) or 0;
        if (avail_h < 60) then avail_h = 300; end
        -- Reserve both resize-handle height and item spacing below the table.
        local spacing_y = 4;
        pcall(function()
            local st = imgui.GetStyle();
            if (st and st.ItemSpacing and type(st.ItemSpacing.y) == 'number') then spacing_y = st.ItemSpacing.y; end
        end);
        local reserve = RESIZE_BAR_H + spacing_y + detail_height;
        local max_table_h = header_height + (row_height * math_min(#players, max_rows));
        table_h = math_min(max_table_h, math_max(avail_h - reserve, 80));
    end

    local name_counts = {};
    for _, p in ipairs(players) do
        local k = (p.player_name or ''):lower();
        name_counts[k] = (name_counts[k] or 0) + 1;
    end

    if (imgui.BeginTable(tid('##players_tbl'), 5, table_flags, { 0, table_h })) then
        imgui.TableSetupScrollFreeze(0, 1);
        imgui.TableSetupColumn('Player',    ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortAscending + ImGuiTableColumnFlags_DefaultSort, 90, 0);
        imgui.TableSetupColumn('Rating',    ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 70, 1);
        imgui.TableSetupColumn('Tags',      ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_NoSort, 0, 2);
        imgui.TableSetupColumn('Notes',     ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_NoSort, 40, 3);
        imgui.TableSetupColumn('Updated',   ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 70, 4);
        imgui.TableHeadersRow();

        -- Handle sort-spec changes.
        local sort_specs = imgui.TableGetSortSpecs();
        if (sort_specs) then
            local spec = sort_specs.Specs;
            if (spec) then
                local col = spec.ColumnUserID;
                local asc = (spec.SortDirection == ImGuiSortDirection_Ascending);
                if (col ~= ui.sort_col or asc ~= ui.sort_asc) then
                    ui.sort_col = col;
                    ui.sort_asc = asc;
                    ui.db.players_dirty = true;
                end
            end
        end

        for _, p in ipairs(players) do
            imgui.TableNextRow();

            -- Highlight Avoid-tagged rows
            local has_avoid = (p.tags ~= nil and p.tags:find('Avoid'));
            if (has_avoid) then
                if (avoid_row_color == nil) then
                    avoid_row_color = imgui.ColorConvertFloat4ToU32({ 0.8, 0.2, 0.2, 0.25 });
                end
                imgui.TableSetBgColor(ImGuiTableBgTarget_RowBg1, avoid_row_color);
            end

            -- Name (clickable)
            imgui.TableNextColumn();
            local is_selected = (ui.selected_player_id == p.id);
            -- Show character IDs only for duplicate names in this list.
            local label = p.player_name;
            if ((name_counts[(p.player_name or ''):lower()] or 0) > 1) then
                label = label .. '  #' .. tostring(p.server_id or 0);
            end
            if (imgui.Selectable(label .. '##p_' .. p.id, is_selected, ImGuiSelectableFlags_SpanAllColumns)) then
                if (is_selected) then
                    ui.selected_player_id = nil;
                    ui.confirm_delete_player = nil;
                    ui.confirm_delete_note = nil;
                    ui.edit_note_id = nil;
                else
                    ui.selected_player_id = p.id;
                    ui.confirm_delete_player = nil;
                    ui.confirm_delete_note = nil;
                    ui.edit_note_id = nil;
                    ui.add_note_buf[1] = '';
                end
            end

            -- Rating stars (pre-computed lookup)
            imgui.TableNextColumn();
            local stars = star_strings[p.rating] or '-';
            imgui.TextColored(p.rating > 0 and colors.star_on or colors.star_off, stars);

            -- Tags (colored)
            imgui.TableNextColumn();
            render_tag_chips(p.tags);

            -- Note count
            imgui.TableNextColumn();
            imgui.TextColored(colors.muted, tostring(ui.db.get_note_count(p.id)));

            -- Last seen
            imgui.TableNextColumn();
            imgui.TextColored(colors.muted, fmt_date(p.updated_at));
        end

        imgui.EndTable();
    end

    -- Resize bar (draggable handle below table)
    if (resize_bar_u32 == nil) then
        resize_bar_u32       = imgui.ColorConvertFloat4ToU32({ 0.35, 0.35, 0.40, 1.0 });
        resize_bar_hover_u32 = imgui.ColorConvertFloat4ToU32({ 0.5, 0.5, 0.55, 1.0 });
    end
    local bar_w = imgui.GetContentRegionAvail();
    local bar_h = RESIZE_BAR_H;
    local bar_x, bar_y = imgui.GetCursorScreenPos();
    imgui.InvisibleButton('##table_resize', { bar_w, bar_h });
    local bar_hovered = imgui.IsItemHovered();
    if (bar_hovered and not table_dragging) then
        imgui.SetTooltip('Drag to resize table. Double-click to reset.');
    end
    local bar_active = imgui.IsItemActive();

    -- Double-click to reset to auto height (check before drag so it takes priority)
    if (bar_hovered and imgui.IsMouseDoubleClicked(0)) then
        table_user_h = nil;
        table_dragging = false;
    elseif (bar_active) then
        if (not table_dragging) then
            table_dragging = true;
            table_drag_start_y = select(2, imgui.GetMousePos());
            table_drag_start_h = table_h;
        end
        local mouse_y = select(2, imgui.GetMousePos());
        local delta = mouse_y - table_drag_start_y;
        table_user_h = math_max(table_drag_start_h + delta, min_table_h);
    else
        table_dragging = false;
    end

    local rdl = imgui.GetWindowDrawList();
    local bar_color = (bar_hovered or bar_active) and resize_bar_hover_u32 or resize_bar_u32;
    rdl:AddRectFilled({ bar_x, bar_y + 1 }, { bar_x + bar_w, bar_y + 3 }, bar_color, 1.0);
    -- Grip dots (centered, 3 small squares)
    local grip_cx = bar_x + bar_w * 0.5;
    local grip_y = bar_y + 2;
    rdl:AddRectFilled({ grip_cx - 10, grip_y }, { grip_cx - 6, grip_y + 2 }, bar_color, 0);
    rdl:AddRectFilled({ grip_cx - 1, grip_y }, { grip_cx + 3, grip_y + 2 }, bar_color, 0);
    rdl:AddRectFilled({ grip_cx + 8, grip_y }, { grip_cx + 12, grip_y + 2 }, bar_color, 0);

    render_player_detail();
end

-- Add Player Popup Window

local function render_add_player_popup()
    if (not ui.show_add_player[1]) then return; end

    imgui.SetNextWindowSize({ 400, 0, }, ImGuiCond_Appearing);
    local flags = ImGuiWindowFlags_AlwaysAutoResize + ImGuiWindowFlags_NoSavedSettings;

    if (imgui.Begin('Add Player##pn_add', ui.show_add_player, flags)) then
        local label_w = 80;

        imgui.Text('Name:');
        imgui.SameLine(label_w);
        imgui.PushItemWidth(160);
        imgui.InputTextWithHint('##new_pname', 'Player name...', ui.new_name_buf, ui.new_name_size);
        imgui.PopItemWidth();

        -- Add from target button
        imgui.SameLine();
        if (imgui.Button('From Target')) then
            local tname, err = ui.context.get_target_name();
            if (tname ~= '') then
                local self_name = ui.context.get_player_name();
                if (self_name ~= '' and tname:lower() == self_name:lower()) then
                    ui.target_err = 'Cannot track yourself.';
                    ui.target_err_time = os_clock();
                else
                    ui.new_name_buf[1] = tname;
                    ui.target_err = nil;
                end
            elseif (err == 'not_pc') then
                ui.target_err = 'Target is not a player.';
                ui.target_err_time = os_clock();
            else
                ui.target_err = 'No target selected.';
                ui.target_err_time = os_clock();
            end
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('Fill name from your current target (players only).');
        end
        if (ui.target_err ~= nil and (os_clock() - (ui.target_err_time or 0)) < 3) then
            imgui.SameLine();
            imgui.TextColored(colors.error, ui.target_err);
        else
            ui.target_err = nil;
        end

        imgui.Spacing();
        imgui.Text('Rating:');
        imgui.SameLine(label_w);
        local new_r = render_stars('new', ui.new_rating);
        if (new_r ~= nil) then ui.new_rating = new_r; end

        imgui.Spacing();
        imgui.Text('Tags:');
        imgui.SameLine(label_w);
        render_tag_toggles('new', ui.new_tags);

        -- Initial note
        imgui.Spacing();
        imgui.Text('Note:');
        imgui.SameLine(label_w);
        imgui.PushItemWidth(-1);
        local note_cx, note_cy = imgui.GetCursorScreenPos();
        imgui.InputTextMultiline('##new_pnote', ui.new_note_buf, ui.new_note_size, { -1, 80 });
        local buf_empty = (ui.new_note_buf[1] == nil or ui.new_note_buf[1] == '' or ui.new_note_buf[1]:byte(1) == 0);
        if (buf_empty and not imgui.IsItemActive()) then
            local hint_col = imgui.ColorConvertFloat4ToU32({ colors.muted[1], colors.muted[2], colors.muted[3], 0.6 });
            imgui.GetWindowDrawList():AddText({ note_cx + 4, note_cy + 3 }, hint_col, 'Add a note...');
        end
        imgui.PopItemWidth();

        -- Context preview
        imgui.Spacing();
        local zone_name = ui.context.get_zone_name();
        if (zone_name ~= '') then
            imgui.TextColored(colors.muted, 'Zone: ' .. zone_name);
        end

        imgui.Spacing();
        if (imgui.Button('Save Player', { 120, 0 })) then
            local pname = trim_buf(ui.new_name_buf[1]);
            local self_name = ui.context.get_player_name();
            if (pname == '') then
                ui.target_err = 'Name cannot be empty.';
                ui.target_err_time = os_clock();
            elseif (pname:find('[^%a]')) then
                ui.target_err = 'Letters only — no spaces, numbers, or symbols.';
                ui.target_err_time = os_clock();
            elseif (#pname < 3 or #pname > 15) then
                ui.target_err = 'Name must be 3-15 characters.';
                ui.target_err_time = os_clock();
            elseif (self_name ~= '' and pname:lower() == self_name:lower()) then
                ui.target_err = 'Cannot track yourself.';
                ui.target_err_time = os_clock();
            else
                -- Auto-format: Firstname (first upper, rest lower)
                pname = pname:sub(1, 1):upper() .. pname:sub(2):lower();
                local tag_str = tags_to_string(ui.new_tags);
                local sid = ui.context.find_server_id(pname);
                local player_id = ui.db.add_player(pname, ui.new_rating, tag_str, sid);

                -- Keep the popup and input if the initial note fails to save.
                local note_text = (player_id ~= nil) and trim_buf(ui.new_note_buf[1]) or '';
                local note_ok = (note_text == '') or (ui.db.add_note(player_id, note_text, zone_name) ~= nil);
                if (player_id ~= nil and not note_ok) then ui.warn_write_failed('note'); end

                if (player_id ~= nil and note_ok) then
                    -- Bind legacy identity only when the user writes with that character present.
                    ui.db.bind_identity(player_id, sid);

                    ui.new_name_buf[1] = '';
                    ui.new_rating = 0;
                    ui.new_tags = {};
                    ui.new_note_buf[1] = '';

                    -- Close popup and select new player
                    ui.show_add_player[1] = false;
                    ui.selected_player_id = player_id;
                end
            end
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('Create player profile with optional rating, tags, and initial note.');
        end
    end
    imgui.End();
end

-- Status Bar

local function render_status_bar()
    imgui.Separator();

    local pc, nc = ui.db.get_counts();
    imgui.TextColored(colors.muted, string_format('%d players | %d notes', pc, nc));

    -- Settings + Reset UI (right-aligned, -170 for two buttons + resize grip)
    local cursor_x = imgui.GetCursorPosX();
    local avail_w = imgui.GetContentRegionAvail();
    imgui.SameLine(cursor_x + avail_w - 170);
    if (imgui.Button('Settings')) then
        ui.show_settings[1] = not ui.show_settings[1];
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Open settings window.');
    end
    imgui.SameLine();
    imgui.PushStyleColor(ImGuiCol_Button, { 0.3, 0.3, 0.3, 1.0 });
    if (imgui.Button('Reset UI')) then
        ui.reset_pending = true;
    end
    imgui.PopStyleColor();
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Reset window size, position, and column widths to defaults.');
    end
    imgui.Dummy({ 0, 4 });
end

-- Main Render

function ui.render()
    -- Don't render anything until character is logged in and DB is ready
    if (ui.db == nil or ui.db.conn == nil) then return; end

    if (not ui.is_open[1]) then
        ui_settings.render_settings();
        ui_settings.render_advanced();
        render_toasts();
        render_disband_popup();
        render_add_player_popup();
        return;
    end

    if (ui.reset_pending) then
        ui.reset_pending = false;
        ui.table_salt = ui.table_salt + 1;
        ui.selected_player_id = nil;
        ui.confirm_delete_player = nil;
        ui.confirm_delete_note = nil;
        ui.edit_note_id = nil;
        ui.tag_filter = nil;
        ui.sort_col = 0;
        ui.sort_asc = true;
        table_user_h = nil;
        imgui.SetNextWindowSize({ 580, 440, }, ImGuiCond_Always);
        imgui.SetNextWindowPos({ 100, 100, }, ImGuiCond_Always);
    end
    imgui.SetNextWindowSize({ 580, 440, }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints({ 420, 320, }, { FLT_MAX, FLT_MAX, });

    if (imgui.Begin('PlayerNotes', ui.is_open, ImGuiWindowFlags_None)) then
        -- Content area (single view, no tabs)
        imgui.BeginChild('##pn_content', { 0, -30 });
        render_players();
        imgui.EndChild();

        render_status_bar();
    end
    imgui.End();

    ui_settings.render_settings();
    ui_settings.render_advanced();
    render_toasts();
    render_disband_popup();
    render_add_player_popup();
end

-- Public: Player alert check (called from main loop)

--- Append pinned (or latest) note snippet to toast text if setting is enabled.
local function maybe_append_note(text, player)
    local s = ui.settings;
    if (s == nil or not s.toast_append_note) then return text; end

    -- get_notes returns pinned first (ORDER BY pinned DESC, created_at DESC)
    local notes = ui.db.get_notes(player.id);
    local snippet = notes[1] and notes[1].note;
    if (snippet ~= nil) then
        if (#snippet > 50) then
            snippet = snippet:sub(1, 47) .. '...';
        end
        return text .. ' | "' .. snippet .. '"';
    end
    return text;
end

function ui.check_party_alerts(party, get_player_by_name)
    if (ui.settings == nil or not ui.settings.alert_known_players) then return; end

    local s = ui.settings;
    for _, p in ipairs(party) do
        -- Keyed by identity, not by name: a re-taken name is a different character, and gets its own alert.
        local akey = p.name .. '#' .. tostring(p.server_id or 0);
        if (ui.alerted_players[akey]) then
            -- Already alerted this zone
        else
            local player = get_player_by_name(p.name, p.server_id);
            if (player ~= nil) then
                ui.alerted_players[akey] = true;
                local tags = player.tags or '';

                -- Choose alert type before checking its toggle; disabling Avoid must not fall through to a
                -- generic alert.
                local kind, text;
                if (tags:find('Avoid')) then
                    kind, text = 'avoid_alert', string_format('WARNING: %s joined party - Avoid', p.name);
                elseif (tags:find('Friend')) then
                    kind, text = 'friend_alert', string_format('%s joined party (Friend)', p.name);
                else
                    kind, text = 'player_alert', string_format('%s joined party', p.name);
                end
                -- Label unverified identity rather than attributing legacy notes to the current character.
                if (player.identity_unverified) then text = text .. ' [unconfirmed]'; end

                if (s['toast_sound_' .. kind] ~= false) then
                    ui.show_toast(maybe_append_note(text, player), kind);
                end
            end
        end
    end
end

function ui.check_nearby_alerts(nearby, get_player_by_name, in_town)
    if (ui.settings == nil or not ui.settings.alert_known_players) then return; end

    local s = ui.settings;
    local allow_avoid  = not in_town or (s.toast_avoid_nearby_in_town ~= false);
    local allow_friend = not in_town or s.toast_friend_nearby_in_town;

    for _, p in ipairs(nearby) do
        local akey = p.name .. '#' .. tostring(p.server_id or 0);
        if (ui.alerted_players[akey]) then
            -- Already alerted (party alert takes priority)
        else
            local player = get_player_by_name(p.name, p.server_id);
            if (player ~= nil) then
                local tags = player.tags or '';

                -- Choose type before gating; suppressed Avoid/Friend alerts must not fall through.
                -- Untagged players receive party alerts only.
                local kind, text, allowed;
                if (tags:find('Avoid')) then
                    kind, text, allowed = 'avoid_nearby', string_format('WARNING: %s nearby - Avoid', p.name), allow_avoid;
                elseif (tags:find('Friend')) then
                    kind, text, allowed = 'friend_nearby', string_format('%s is nearby (Friend)', p.name), allow_friend;
                end
                if (kind ~= nil and player.identity_unverified) then text = text .. ' [unconfirmed]'; end

                if (kind ~= nil and allowed and s['toast_sound_' .. kind] ~= false) then
                    ui.alerted_players[akey] = true;
                    ui.show_toast(maybe_append_note(text, player), kind);
                end
            end
        end
    end
end

--- Reset alerted players when zoning.
function ui.reset_alerts()
    ui.alerted_players = {};
end

-- Reset DB-bound UI state on character switch. Row IDs are local to each database;
-- retained selections or delete confirmations could target unrelated rows.
function ui.reset_for_character()
    ui.reset_alerts();
    ui.selected_player_id    = nil;
    ui.confirm_delete_player = nil;
    ui.confirm_delete_note   = nil;
    ui.edit_note_id          = nil;
    ui.disband_open          = false;
    ui.disband_members       = T{};   -- held the previous character's party
end

return ui;
