--[[
    PlayerNotes v1.0.0 - ImGui UI Rendering
    Single-view layout: toolbar (search + tag filter + add) + sortable table + detail panel.
    Player detail panel with star ratings, tag toggles, and notes.

    Author: SQLCommit
    Version: 1.0.0
]]--

require 'common';

local imgui = require 'imgui';

local ui = {};

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
    { id = 'DPS',     color = { 1.0, 0.4, 0.4, 1.0 }, tip = 'Damage dealers' },
    { id = 'Support', color = { 0.7, 0.4, 1.0, 1.0 }, tip = 'BRD, COR, GEO' },
    { id = 'Crafter', color = { 1.0, 0.7, 0.3, 1.0 }, tip = 'Crafting partners' },
    { id = 'Friend',  color = { 0.4, 1.0, 1.0, 1.0 }, tip = 'Triggers party + nearby alerts' },
    { id = 'Avoid',   color = { 0.8, 0.2, 0.2, 1.0 }, tip = 'Warning alerts + red row highlight' },
    { id = 'Mentor',  color = { 1.0, 0.85, 0.0, 1.0 }, tip = 'Helpful teachers' },
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

-- Colors
local colors = {
    header    = { 1.0, 0.65, 0.26, 1.0 },
    success   = { 0.0, 1.0, 0.1, 1.0 },
    error     = { 1.0, 0.4, 0.4, 1.0 },
    muted     = { 0.6, 0.6, 0.6, 1.0 },
    star_on   = { 1.0, 0.85, 0.0, 1.0 },
    star_off  = { 0.4, 0.4, 0.4, 1.0 },
    player    = { 0.4, 1.0, 1.0, 1.0 },
};

-- Cached ImU32 colors (computed once, not per-frame)
local avoid_row_color = nil; -- deferred until first render (imgui must be loaded)

-------------------------------------------------------------------------------
-- Cached References
-------------------------------------------------------------------------------
local string_format = string.format;
local os_date = os.date;
local os_clock = os.clock;

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

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

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

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

local function trim_buf(s)
    if (type(s) == 'string') then
        return s:trim('\0');
    end
    return '';
end

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
        if (imgui.IsItemHovered() and td.tip) then
            imgui.SetTooltip(td.id .. ': ' .. td.tip);
        end
        imgui.PopStyleColor(2);
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

-------------------------------------------------------------------------------
-- Toast System
-------------------------------------------------------------------------------

-- Color and sound lookup tables for 6 toast types
local toast_color_keys = {
    player_alert  = 'toast_color_player_alert',
    friend_alert  = 'toast_color_friend_alert',
    friend_nearby = 'toast_color_friend_nearby',
    avoid_alert   = 'toast_color_avoid_alert',
    avoid_nearby  = 'toast_color_avoid_nearby',
    disband       = 'toast_color_disband',
};
local toast_sound_toggle_keys = {
    player_alert  = 'toast_sound_player_alert',
    friend_alert  = 'toast_sound_friend_alert',
    friend_nearby = 'toast_sound_friend_nearby',
    avoid_alert   = 'toast_sound_avoid_alert',
    avoid_nearby  = 'toast_sound_avoid_nearby',
    disband       = 'toast_sound_disband',
};
local toast_sound_file_keys = {
    player_alert  = 'toast_sound_player_alert_file',
    friend_alert  = 'toast_sound_friend_alert_file',
    friend_nearby = 'toast_sound_friend_nearby_file',
    avoid_alert   = 'toast_sound_avoid_alert_file',
    avoid_nearby  = 'toast_sound_avoid_nearby_file',
    disband       = 'toast_sound_disband_file',
};

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

    ui.toasts:append({
        text = text,
        start = os_clock(),
        color = color,
    });

    -- Sound: nil type = silent (visual only), master toggle gates all sounds
    if (toast_type ~= nil and s ~= nil and s.toast_sound_enabled ~= false) then
        local toggle_key = toast_sound_toggle_keys[toast_type];
        local file_key = toast_sound_file_keys[toast_type];
        if (toggle_key ~= nil and s[toggle_key]) then
            local sound_file = (file_key ~= nil and s[file_key]) or 'player_alert.wav';
            if (sound_file ~= '') then
                pcall(ashita.misc.play_sound, addon.path:append('\\sounds\\'):append(sound_file));
            end
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

    local visible = 0;
    for i, toast in ipairs(ui.toasts) do
        local elapsed = now - toast.start;
        if (elapsed > duration) then
            remove:append(i);
        elseif (visible < max_visible) then
            visible = visible + 1;

            -- Alpha calculation with fade in/out
            local alpha = 1.0;
            if (fade_enabled) then
                if (fade_in > 0 and elapsed < fade_in) then
                    alpha = elapsed / fade_in;
                end
                if (fade_out > 0 and elapsed > duration - fade_out) then
                    alpha = math.min(alpha, (duration - elapsed) / fade_out);
                end
            end
            alpha = math.max(0.0, math.min(1.0, alpha));

            -- Position: stack direction
            local y_offset = (visible - 1) * stack_spacing;
            if (not stack_down) then y_offset = -y_offset; end
            imgui.SetNextWindowPos({ base_x, base_y + y_offset }, ImGuiCond_Always);

            -- Background color/opacity
            if (bg_color ~= nil) then
                imgui.PushStyleColor(ImGuiCol_WindowBg, {
                    bg_color[1] or 0.11, bg_color[2] or 0.11, bg_color[3] or 0.14, bg_opacity * alpha,
                });
            else
                imgui.SetNextWindowBgAlpha(bg_opacity * alpha);
            end

            local flags = ImGuiWindowFlags_NoDecoration
                + ImGuiWindowFlags_AlwaysAutoResize
                + ImGuiWindowFlags_NoSavedSettings
                + ImGuiWindowFlags_NoFocusOnAppearing;
            if (not click_dismiss) then
                flags = flags + ImGuiWindowFlags_NoInputs;
            end

            if (imgui.Begin('##pn_toast_' .. i, nil, flags)) then
                local c = toast.color or { 0.4, 1.0, 1.0, 1.0 };
                imgui.TextColored({ c[1], c[2], c[3], alpha }, toast.text);

                -- Click to dismiss
                if (click_dismiss and imgui.IsWindowHovered() and imgui.IsMouseClicked(0)) then
                    remove:append(i);
                end
            end
            imgui.End();

            if (bg_color ~= nil) then
                imgui.PopStyleColor();
            end
        end
    end

    -- Remove expired/dismissed toasts (reverse order for stable indices)
    -- Deduplicate indices first
    local remove_set = {};
    for _, idx in ipairs(remove) do remove_set[idx] = true; end
    local sorted_remove = {};
    for idx in pairs(remove_set) do sorted_remove[#sorted_remove + 1] = idx; end
    table.sort(sorted_remove, function(a, b) return a > b; end);
    for _, idx in ipairs(sorted_remove) do
        table.remove(ui.toasts, idx);
    end
end

-------------------------------------------------------------------------------
-- Disband Popup
-------------------------------------------------------------------------------

function ui.show_disband_popup(names)
    ui.disband_open = true;
    ui.disband_members = T{};
    for _, name in ipairs(names) do
        ui.disband_members:append({
            name = name,
            note_buf = { '', },
            note_size = 256,
            rating = 0,
            tag_set = {},
            saved = false,
        });
    end
    ui.show_toast('Party disbanded — add notes?', 'disband');
end

local function render_disband_popup()
    if (not ui.disband_open) then return; end

    imgui.SetNextWindowSize({ 480, 0, }, ImGuiCond_Appearing);

    local open = { true, };
    local flags = ImGuiWindowFlags_AlwaysAutoResize + ImGuiWindowFlags_NoSavedSettings;

    if (imgui.Begin('Party Disbanded##pn', open, flags)) then
        imgui.TextColored(colors.header, 'Your party has disbanded!');
        imgui.TextColored(colors.muted, 'Add notes about your party members?');
        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        local all_done = true;
        for i, member in ipairs(ui.disband_members) do
            if (not member.saved) then
                all_done = false;
                imgui.TextColored(colors.player, member.name);
                local existing = ui.db.get_player_by_name(member.name);
                if (existing ~= nil) then
                    imgui.SameLine();
                    imgui.TextColored(colors.muted, '(has profile)');
                end

                -- Rating
                imgui.Text('  Rating: ');
                imgui.SameLine();
                local new_r = render_stars('disband_' .. i, member.rating);
                if (new_r ~= nil) then member.rating = new_r; end

                -- Note
                imgui.PushItemWidth(340);
                imgui.InputText('##disband_note_' .. i, member.note_buf, member.note_size);
                imgui.PopItemWidth();
                imgui.SameLine();
                if (imgui.Button('Save##dsave_' .. i)) then
                    local note_text = trim_buf(member.note_buf[1]);
                    local zone_name = ui.context.get_zone_name();

                    -- Create or get player profile
                    local player_id;
                    if (existing ~= nil) then
                        player_id = existing.id;
                        if (member.rating > 0) then
                            -- Preserve existing tags (disband popup has no tag UI)
                            ui.db.update_player(player_id, member.rating, existing.tags or '');
                        end
                    else
                        local tag_str = tags_to_string(member.tag_set);
                        player_id = ui.db.add_player(member.name, member.rating, tag_str);
                    end

                    if (player_id ~= nil and note_text ~= '') then
                        ui.db.add_note(player_id, note_text, zone_name);
                    end

                    member.saved = true;
                end
            else
                imgui.TextColored(colors.success, member.name .. ' — Saved!');
            end
            imgui.Spacing();
        end

        imgui.Separator();
        if (all_done) then
            if (imgui.Button('Done')) then
                ui.disband_open = false;
            end
        else
            if (imgui.Button('Skip')) then
                ui.disband_open = false;
            end
        end
    end

    if (not open[1]) then
        ui.disband_open = false;
    end
    imgui.End();
end

-------------------------------------------------------------------------------
-- Player Detail Panel (below table)
-------------------------------------------------------------------------------

local function render_player_detail()
    if (ui.selected_player_id == nil) then return; end

    local player = ui.db.get_player_by_id(ui.selected_player_id);
    if (player == nil) then
        ui.selected_player_id = nil;
        return;
    end

    imgui.Separator();
    imgui.Spacing();

    -- Player name header
    imgui.TextColored(colors.player, player.player_name);
    imgui.SameLine();
    imgui.TextColored(colors.muted, string_format('(since %s)', fmt_time(player.created_at)));

    -- Rating (editable stars)
    imgui.Text('Rating: ');
    imgui.SameLine();
    local new_rating = render_stars('detail', player.rating);
    if (new_rating ~= nil) then
        local tag_set = parse_tags(player.tags);
        ui.db.update_player(player.id, new_rating, tags_to_string(tag_set));
    end

    -- Tags (editable toggles)
    imgui.Text('Tags:   ');
    imgui.SameLine();
    local tag_set = parse_tags(player.tags);
    if (render_tag_toggles('detail', tag_set)) then
        ui.db.update_player(player.id, player.rating, tags_to_string(tag_set));
    end

    imgui.Spacing();

    -- Notes section
    imgui.TextColored(colors.header, 'Notes');
    imgui.Separator();

    -- Add new note (above list so newest-on-top feels natural)
    imgui.PushItemWidth(-70);
    imgui.InputTextWithHint('##add_note', 'Write a note...', ui.add_note_buf, ui.add_note_size);
    imgui.PopItemWidth();
    imgui.SameLine();
    if (imgui.Button('+ Add##note')) then
        local note_text = trim_buf(ui.add_note_buf[1]);
        if (note_text ~= '') then
            local zone_name = ui.context.get_zone_name();
            ui.db.add_note(player.id, note_text, zone_name);
            ui.add_note_buf[1] = '';
        end
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Add a new note. Current zone is saved automatically.');
    end
    imgui.Spacing();

    local notes = ui.db.get_notes(player.id);

    if (#notes > 0) then
        for _, note in ipairs(notes) do
            imgui.PushID('note_' .. note.id);

            -- Note card: metadata line then text
            local meta = '';
            if (note.zone_name ~= '') then
                meta = note.zone_name .. ' | ';
            end
            meta = meta .. fmt_time(note.created_at);
            imgui.TextColored(colors.muted, meta);

            if (ui.edit_note_id == note.id) then
                -- Edit mode
                imgui.PushItemWidth(-80);
                imgui.InputText('##edit_note', ui.edit_note_buf, ui.edit_note_size);
                imgui.PopItemWidth();
                imgui.SameLine();
                if (imgui.Button('OK')) then
                    local new_text = trim_buf(ui.edit_note_buf[1]);
                    if (new_text ~= '') then
                        ui.db.update_note(note.id, new_text);
                    end
                    ui.edit_note_id = nil;
                end
                imgui.SameLine();
                if (imgui.Button('X')) then
                    ui.edit_note_id = nil;
                end
            else
                -- Display mode
                imgui.TextWrapped(note.note);
                imgui.SameLine();
                -- Edit button
                if (imgui.SmallButton('Edit##' .. note.id)) then
                    ui.edit_note_id = note.id;
                    ui.edit_note_buf[1] = note.note;
                end
                imgui.SameLine();
                -- Delete with confirmation
                if (ui.confirm_delete_note == note.id) then
                    imgui.TextColored(colors.error, 'Delete?');
                    imgui.SameLine();
                    if (imgui.SmallButton('Y##ndel')) then
                        ui.db.delete_note(note.id);
                        ui.confirm_delete_note = nil;
                    end
                    imgui.SameLine();
                    if (imgui.SmallButton('N##ncan')) then
                        ui.confirm_delete_note = nil;
                    end
                else
                    if (imgui.SmallButton('x##del_' .. note.id)) then
                        ui.confirm_delete_note = note.id;
                    end
                end
            end

            imgui.Spacing();
            imgui.PopID();
        end
    else
        imgui.TextColored(colors.muted, 'No notes yet.');
    end

    -- Delete player button
    imgui.Spacing();
    imgui.Separator();
    if (ui.confirm_delete_player == player.id) then
        imgui.TextColored(colors.error, 'Delete player and all notes?');
        imgui.SameLine();
        if (imgui.Button('Yes##pdel')) then
            ui.db.delete_player(player.id);
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
end

-------------------------------------------------------------------------------
-- Player View (single page: toolbar + sortable table + detail panel)
-------------------------------------------------------------------------------

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
        imgui.SetTooltip('Add a new player profile.');
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
    local max_rows = 10;
    local header_height = row_height + 4;
    local detail_height = (ui.selected_player_id ~= nil) and 300 or 0;
    local _, avail_h = imgui.GetContentRegionAvail();
    local max_table_h = header_height + (row_height * math.min(#players, max_rows));
    local table_h = math.min(max_table_h, math.max((avail_h or 300) - detail_height - 4, 80));

    if (imgui.BeginTable(tid('##players_tbl'), 5, table_flags, { 0, table_h })) then
        imgui.TableSetupScrollFreeze(0, 1);
        imgui.TableSetupColumn('Player',    ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortAscending + ImGuiTableColumnFlags_DefaultSort, 90, 0);
        imgui.TableSetupColumn('Rating',    ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 70, 1);
        imgui.TableSetupColumn('Tags',      ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_NoSort, 0, 2);
        imgui.TableSetupColumn('Notes',     ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_NoSort, 40, 3);
        imgui.TableSetupColumn('Updated',   ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 70, 4);
        imgui.TableHeadersRow();

        -- Handle sort spec changes (MemScope pattern)
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
            if (imgui.Selectable(p.player_name .. '##p_' .. p.id, is_selected, ImGuiSelectableFlags_SpanAllColumns)) then
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

            -- Rating stars
            imgui.TableNextColumn();
            if (p.rating > 0) then
                local stars = '';
                for i = 1, p.rating do stars = stars .. '*'; end
                imgui.TextColored(colors.star_on, stars);
            else
                imgui.TextColored(colors.star_off, '-');
            end

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

    -- Detail panel
    render_player_detail();
end

-------------------------------------------------------------------------------
-- Add Player Popup Window
-------------------------------------------------------------------------------

local function render_add_player_popup()
    if (not ui.show_add_player[1]) then return; end

    imgui.SetNextWindowSize({ 400, 0, }, ImGuiCond_Appearing);
    local flags = ImGuiWindowFlags_AlwaysAutoResize + ImGuiWindowFlags_NoSavedSettings;

    if (imgui.Begin('Add Player##pn_add', ui.show_add_player, flags)) then
        local label_w = 80;

        -- Name input
        imgui.Text('Name:');
        imgui.SameLine(label_w);
        imgui.PushItemWidth(160);
        imgui.InputText('##new_pname', ui.new_name_buf, ui.new_name_size);
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

        -- Rating
        imgui.Spacing();
        imgui.Text('Rating:');
        imgui.SameLine(label_w);
        local new_r = render_stars('new', ui.new_rating);
        if (new_r ~= nil) then ui.new_rating = new_r; end

        -- Tags
        imgui.Spacing();
        imgui.Text('Tags:');
        imgui.SameLine(label_w);
        render_tag_toggles('new', ui.new_tags);

        -- Initial note
        imgui.Spacing();
        imgui.Text('Note:');
        imgui.SameLine(label_w);
        imgui.PushItemWidth(-1);
        imgui.InputTextMultiline('##new_pnote', ui.new_note_buf, ui.new_note_size, { -1, 80 });
        imgui.PopItemWidth();

        -- Context preview
        imgui.Spacing();
        local zone_name = ui.context.get_zone_name();
        if (zone_name ~= '') then
            imgui.TextColored(colors.muted, 'Zone: ' .. zone_name);
        end

        -- Save button
        imgui.Spacing();
        if (imgui.Button('Save Player', { 120, 0 })) then
            local pname = trim_buf(ui.new_name_buf[1]);
            local self_name = ui.context.get_player_name();
            if (pname ~= '' and self_name ~= '' and pname:lower() == self_name:lower()) then
                ui.target_err = 'Cannot track yourself.';
                ui.target_err_time = os_clock();
            elseif (pname ~= '') then
                local tag_str = tags_to_string(ui.new_tags);
                local player_id = ui.db.add_player(pname, ui.new_rating, tag_str);

                if (player_id ~= nil) then
                    local note_text = trim_buf(ui.new_note_buf[1]);
                    if (note_text ~= '') then
                        ui.db.add_note(player_id, note_text, zone_name);
                    end

                    -- Clear inputs
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

-------------------------------------------------------------------------------
-- Settings Popout Window
-------------------------------------------------------------------------------

local function render_settings()
    if (not ui.show_settings[1]) then return; end

    local s = ui.settings;
    if (s == nil) then return; end

    if (not imgui.Begin('PlayerNotes Settings', ui.show_settings, ImGuiWindowFlags_AlwaysAutoResize)) then
        imgui.End();
        return;
    end

    -- Show on load
    local show_on_load = { s.show_on_load, };
    if (imgui.Checkbox('Open window when addon loads', show_on_load)) then
        s.show_on_load = show_on_load[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Automatically open the PlayerNotes window when the addon is loaded.');
    end

    imgui.Spacing();
    imgui.TextColored(colors.header, 'Player Alerts');
    imgui.Separator();

    -- Prompt on disband
    local disband = { s.prompt_on_disband, };
    if (imgui.Checkbox('Prompt to add notes after party disbands', disband)) then
        s.prompt_on_disband = disband[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Shows a popup after your party disbands. Alliances are skipped.');
    end

    -- Alert known players (master toggle for detection engine)
    local alert = { s.alert_known_players, };
    if (imgui.Checkbox('Enable player detection', alert)) then
        s.alert_known_players = alert[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Scans for tracked players nearby and in your party. All alerts require this to be enabled.');
    end

    -- Detection sub-options (indented + greyed out when detection disabled)
    if (not s.alert_known_players) then
        imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.4);
    end
    imgui.Indent();

    local append_note = { s.toast_append_note, };
    if (imgui.Checkbox('Append latest note to alerts', append_note)) then
        if (s.alert_known_players) then
            s.toast_append_note = append_note[1];
            ui.settings_dirty = true;
        end
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('When enabled, alert toasts will include the most recent note about the player.');
    end

    local friend_town = { s.toast_friend_nearby_in_town, };
    if (imgui.Checkbox('Friend nearby alerts in town', friend_town)) then
        if (s.alert_known_players) then
            s.toast_friend_nearby_in_town = friend_town[1];
            ui.settings_dirty = true;
        end
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('When unchecked, Friend nearby alerts are suppressed in town zones.');
    end

    local avoid_town = { s.toast_avoid_nearby_in_town ~= false, };
    if (imgui.Checkbox('Avoid nearby alerts in town', avoid_town)) then
        if (s.alert_known_players) then
            s.toast_avoid_nearby_in_town = avoid_town[1];
            ui.settings_dirty = true;
        end
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('When unchecked, Avoid nearby alerts are suppressed in town zones.');
    end

    imgui.Unindent();
    if (not s.alert_known_players) then
        imgui.PopStyleVar();
    end

    imgui.Spacing();
    imgui.TextColored(colors.header, 'Toasts');
    imgui.Separator();

    -- Master sound toggle
    local snd_enabled = { s.toast_sound_enabled ~= false, };
    if (imgui.Checkbox('Enable sound', snd_enabled)) then
        s.toast_sound_enabled = snd_enabled[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Master toggle for all toast alert sounds. Per-type toggles in Advanced.');
    end

    imgui.Spacing();

    -- Toast duration
    imgui.PushItemWidth(200);
    if (imgui.SliderInt('Toast duration (seconds)', ui.setting_toast_duration, 2, 15)) then
        s.toast_duration = ui.setting_toast_duration[1];
        ui.toast_duration = ui.setting_toast_duration[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('How long each toast notification stays on screen.');
    end

    -- Toast position
    if (imgui.SliderInt('Toast X position', ui.setting_toast_x, 0, 1920)) then
        s.toast_x = ui.setting_toast_x[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Horizontal screen position for toast notifications.');
    end
    if (imgui.SliderInt('Toast Y position', ui.setting_toast_y, 0, 1080)) then
        s.toast_y = ui.setting_toast_y[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Vertical screen position for toast notifications.');
    end
    imgui.PopItemWidth();

    imgui.Spacing();
    if (imgui.Button('Advanced Toast Settings')) then
        ui.show_advanced_toast[1] = not ui.show_advanced_toast[1];
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Configure fade, colors, stacking, sounds, and more.');
    end

    imgui.Spacing();
    imgui.Separator();
    imgui.TextColored({ 0.4, 0.8, 1.0, 1.0 }, 'Import / Export');

    if (imgui.Button('Export All')) then
        AshitaCore:GetChatManager():QueueCommand(1, '/pn export');
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Export all players and notes to a JSON file.');
    end
    imgui.SameLine();
    if (imgui.Button('Import')) then
        AshitaCore:GetChatManager():QueueCommand(1, '/pn import');
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Import from the most recent export file. Merges with existing data.');
    end

    imgui.Spacing();
    imgui.Separator();
    if (ui.defaults and imgui.Button('Restore Defaults')) then
        for k, v in pairs(ui.defaults) do
            ui.settings[k] = v;
        end
        ui.apply_settings(ui.settings);
        ui.settings_dirty = true;
    end
    if (ui.defaults and imgui.IsItemHovered()) then
        imgui.SetTooltip('Reset all settings to their default values.');
    end
    if (ui.defaults) then imgui.SameLine(); end
    if (imgui.Button('Close')) then
        ui.show_settings[1] = false;
    end

    imgui.End();
end

-------------------------------------------------------------------------------
-- Advanced Toast Settings Window
-------------------------------------------------------------------------------

local function render_advanced_toast_settings()
    if (not ui.show_advanced_toast[1]) then return; end

    local s = ui.settings;
    if (s == nil) then return; end

    imgui.SetNextWindowSize({ 420, 0, }, ImGuiCond_Appearing);

    if (not imgui.Begin('Advanced Toast Settings##pn', ui.show_advanced_toast, ImGuiWindowFlags_AlwaysAutoResize)) then
        imgui.End();
        return;
    end

    -- Scan interval
    imgui.TextColored(colors.header, 'Timing');
    imgui.Separator();

    imgui.PushItemWidth(200);
    if (imgui.SliderInt('Check interval (seconds)', ui.setting_check_interval, 5, 60)) then
        s.player_check_interval = ui.setting_check_interval[1];
        ui.settings_dirty = true;
    end
    imgui.PopItemWidth();
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('How often to scan for nearby tracked players. Lower = more responsive, higher = less CPU.');
    end

    -- Animation section
    imgui.Spacing();
    imgui.TextColored(colors.header, 'Animation');
    imgui.Separator();

    local fade_enabled = { s.toast_fade_enabled ~= false, };
    if (imgui.Checkbox('Fade enabled', fade_enabled)) then
        s.toast_fade_enabled = fade_enabled[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Enable fade-in and fade-out animation for toast notifications.');
    end

    if (s.toast_fade_enabled ~= false) then
        imgui.PushItemWidth(200);
        if (imgui.SliderFloat('Fade in (sec)', ui.setting_fade_in, 0.0, 3.0, '%.1f')) then
            s.toast_fade_in = ui.setting_fade_in[1];
            ui.settings_dirty = true;
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('How long the toast takes to appear. 0 = instant.');
        end
        if (imgui.SliderFloat('Fade out (sec)', ui.setting_fade_out, 0.0, 3.0, '%.1f')) then
            s.toast_fade_out = ui.setting_fade_out[1];
            ui.settings_dirty = true;
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('How long the toast takes to disappear before expiring.');
        end
        imgui.PopItemWidth();
    end

    -- Interaction section
    imgui.Spacing();
    imgui.TextColored(colors.header, 'Interaction');
    imgui.Separator();

    local click_dismiss = { s.toast_click_dismiss == true, };
    if (imgui.Checkbox('Click to dismiss', click_dismiss)) then
        s.toast_click_dismiss = click_dismiss[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Click on a toast to immediately dismiss it.');
    end

    -- Layout section
    imgui.Spacing();
    imgui.TextColored(colors.header, 'Layout');
    imgui.Separator();

    local stack_idx = { (s.toast_stack_down ~= false) and 0 or 1, };
    imgui.PushItemWidth(200);
    if (imgui.Combo('Stack direction', stack_idx, 'Stack down\0Stack up\0')) then
        s.toast_stack_down = (stack_idx[1] == 0);
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Direction new toasts stack from the base position.');
    end
    imgui.PopItemWidth();

    imgui.PushItemWidth(200);
    if (imgui.SliderInt('Stack spacing', ui.setting_stack_spacing, 10, 80)) then
        s.toast_stack_spacing = ui.setting_stack_spacing[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Vertical pixel spacing between stacked toasts.');
    end
    if (imgui.SliderInt('Max visible', ui.setting_max_visible, 1, 20)) then
        s.toast_max_visible = ui.setting_max_visible[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Maximum number of toasts shown at once. Older toasts are hidden until space opens.');
    end
    imgui.PopItemWidth();

    -- Appearance section
    imgui.Spacing();
    imgui.TextColored(colors.header, 'Appearance');
    imgui.Separator();

    imgui.PushItemWidth(200);
    if (imgui.SliderFloat('Background opacity', ui.setting_bg_opacity, 0.1, 1.0, '%.2f')) then
        s.toast_bg_opacity = ui.setting_bg_opacity[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Toast background transparency. 1.0 = fully opaque.');
    end
    imgui.PopItemWidth();

    if (imgui.ColorEdit3('Background color', ui.setting_bg_color)) then
        s.toast_bg_color = T{ ui.setting_bg_color[1], ui.setting_bg_color[2], ui.setting_bg_color[3] };
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Toast notification background color.');
    end

    -- Text Colors section
    imgui.Spacing();
    imgui.TextColored(colors.header, 'Text Colors');
    imgui.Separator();

    if (imgui.ColorEdit3('Player alert', ui.setting_color_player_alert)) then
        s.toast_color_player_alert = T{ ui.setting_color_player_alert[1], ui.setting_color_player_alert[2], ui.setting_color_player_alert[3] };
        ui.settings_dirty = true;
    end
    if (imgui.ColorEdit3('Friend alert', ui.setting_color_friend_alert)) then
        s.toast_color_friend_alert = T{ ui.setting_color_friend_alert[1], ui.setting_color_friend_alert[2], ui.setting_color_friend_alert[3] };
        ui.settings_dirty = true;
    end
    if (imgui.ColorEdit3('Friend nearby', ui.setting_color_friend_nearby)) then
        s.toast_color_friend_nearby = T{ ui.setting_color_friend_nearby[1], ui.setting_color_friend_nearby[2], ui.setting_color_friend_nearby[3] };
        ui.settings_dirty = true;
    end
    if (imgui.ColorEdit3('Avoid alert', ui.setting_color_avoid_alert)) then
        s.toast_color_avoid_alert = T{ ui.setting_color_avoid_alert[1], ui.setting_color_avoid_alert[2], ui.setting_color_avoid_alert[3] };
        ui.settings_dirty = true;
    end
    if (imgui.ColorEdit3('Avoid nearby', ui.setting_color_avoid_nearby)) then
        s.toast_color_avoid_nearby = T{ ui.setting_color_avoid_nearby[1], ui.setting_color_avoid_nearby[2], ui.setting_color_avoid_nearby[3] };
        ui.settings_dirty = true;
    end
    if (imgui.ColorEdit3('Disband', ui.setting_color_disband)) then
        s.toast_color_disband = T{ ui.setting_color_disband[1], ui.setting_color_disband[2], ui.setting_color_disband[3] };
        ui.settings_dirty = true;
    end

    -- Per-type toast selection
    imgui.Spacing();
    imgui.TextColored(colors.header, 'Alert Types');
    imgui.Separator();
    imgui.TextColored(colors.muted, 'Toggle each alert type. Clear the filename to disable its sound.');
    imgui.Spacing();

    -- Per-type sound toggles with test buttons and file inputs (aligned columns)
    local sound_types = {
        { key = 'player_alert',  label = 'Player alert',  toast = 'player_alert',  fmt = '%s joined party',                    file_buf = ui.setting_sound_player_alert_file,  file_key = 'toast_sound_player_alert_file' },
        { key = 'friend_alert',  label = 'Friend alert',  toast = 'friend_alert',  fmt = '%s joined party (Friend)',            file_buf = ui.setting_sound_friend_alert_file,  file_key = 'toast_sound_friend_alert_file' },
        { key = 'friend_nearby', label = 'Friend nearby', toast = 'friend_nearby', fmt = '%s is nearby (Friend)',               file_buf = ui.setting_sound_friend_nearby_file, file_key = 'toast_sound_friend_nearby_file' },
        { key = 'avoid_alert',   label = 'Avoid alert',   toast = 'avoid_alert',   fmt = 'WARNING: %s joined party — Avoid',    file_buf = ui.setting_sound_avoid_alert_file,   file_key = 'toast_sound_avoid_alert_file' },
        { key = 'avoid_nearby',  label = 'Avoid nearby',  toast = 'avoid_nearby',  fmt = 'WARNING: %s nearby — Avoid',          file_buf = ui.setting_sound_avoid_nearby_file,  file_key = 'toast_sound_avoid_nearby_file' },
        { key = 'disband',       label = 'Disband',       toast = 'disband',       fmt = 'Party disbanded — add notes?',        file_buf = ui.setting_sound_disband_file,       file_key = 'toast_sound_disband_file' },
    };
    local col_test = 165; -- Test button column
    local col_file = 215; -- File input column
    for _, st in ipairs(sound_types) do
        local toggle_key = 'toast_sound_' .. st.key;
        local cb = { s[toggle_key], };
        if (imgui.Checkbox(st.label .. '##snd', cb)) then
            s[toggle_key] = cb[1];
            ui.settings_dirty = true;
        end
        imgui.SameLine(col_test);
        if (imgui.Button('Test##snd_' .. st.key)) then
            local name = ui.context.get_player_name();
            if (name == '') then name = 'Player'; end
            local text = st.fmt:find('%%s') and string_format(st.fmt, name) or st.fmt;
            if (s.toast_append_note and st.key ~= 'disband') then
                text = text .. ' | "Sample note for testing"';
            end
            ui.show_toast(text, st.toast);
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('Show a sample toast with sound for this alert type.');
        end
        imgui.SameLine(col_file);
        imgui.PushItemWidth(-1);
        if (imgui.InputText('##file_' .. st.key, st.file_buf, ui.setting_sound_file_size)) then
            s[st.file_key] = trim_buf(st.file_buf[1]);
            ui.settings_dirty = true;
        end
        imgui.PopItemWidth();
    end
    imgui.TextColored(colors.muted, 'Files must be in the sounds/ folder.');

    -- Close button
    imgui.Spacing();
    imgui.Separator();
    if (imgui.Button('Close##adv_toast')) then
        ui.show_advanced_toast[1] = false;
    end

    imgui.End();
end

-------------------------------------------------------------------------------
-- Status Bar
-------------------------------------------------------------------------------

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
end

-------------------------------------------------------------------------------
-- Main Render
-------------------------------------------------------------------------------

function ui.render()
    if (not ui.is_open[1]) then
        render_settings();
        render_advanced_toast_settings();
        render_toasts();
        render_disband_popup();
        render_add_player_popup();
        return;
    end

    -- Handle pending UI reset
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
        imgui.SetNextWindowSize({ 580, 440, }, ImGuiCond_Always);
        imgui.SetNextWindowPos({ 100, 100, }, ImGuiCond_Always);
    end
    imgui.SetNextWindowSize({ 580, 440, }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints({ 420, 320, }, { FLT_MAX, FLT_MAX, });

    if (imgui.Begin('PlayerNotes', ui.is_open, ImGuiWindowFlags_None)) then
        -- Content area (single view, no tabs)
        imgui.BeginChild('##pn_content', { 0, -24 });
        render_players();
        imgui.EndChild();

        -- Status bar
        render_status_bar();
    end
    imgui.End();

    render_settings();
    render_advanced_toast_settings();
    render_toasts();
    render_disband_popup();
    render_add_player_popup();
end

-------------------------------------------------------------------------------
-- Public: Player alert check (called from main loop)
-------------------------------------------------------------------------------

--- Append latest note snippet to toast text if setting is enabled.
local function maybe_append_note(text, player)
    local s = ui.settings;
    if (s == nil or not s.toast_append_note) then return text; end

    local notes = ui.db.get_notes(player.id);
    if (#notes > 0) then
        local snippet = notes[1].note;
        if (#snippet > 50) then
            snippet = snippet:sub(1, 47) .. '...';
        end
        return text .. ' | "' .. snippet .. '"';
    end
    return text;
end

function ui.check_party_alerts(party, get_player_by_name)
    if (not ui.settings.alert_known_players) then return; end

    for _, p in ipairs(party) do
        if (ui.alerted_players[p.name]) then
            -- Already alerted this zone
        else
            local player = get_player_by_name(p.name);
            if (player ~= nil) then
                ui.alerted_players[p.name] = true;
                local tags = player.tags or '';
                local msg;
                if (tags:find('Avoid')) then
                    msg = maybe_append_note(string_format('WARNING: %s joined party — Avoid', p.name), player);
                    ui.show_toast(msg, 'avoid_alert');
                elseif (tags:find('Friend')) then
                    msg = maybe_append_note(string_format('%s joined party (Friend)', p.name), player);
                    ui.show_toast(msg, 'friend_alert');
                else
                    msg = maybe_append_note(string_format('%s joined party', p.name), player);
                    ui.show_toast(msg, 'player_alert');
                end
            end
        end
    end
end

function ui.check_nearby_alerts(nearby, get_player_by_name, in_town)
    if (not ui.settings.alert_known_players) then return; end

    local s = ui.settings;
    local allow_avoid  = not in_town or (s.toast_avoid_nearby_in_town ~= false);
    local allow_friend = not in_town or s.toast_friend_nearby_in_town;

    for _, p in ipairs(nearby) do
        if (ui.alerted_players[p.name]) then
            -- Already alerted (party alert takes priority)
        else
            local player = get_player_by_name(p.name);
            if (player ~= nil) then
                local tags = player.tags or '';
                if (tags:find('Avoid') and allow_avoid) then
                    ui.alerted_players[p.name] = true;
                    local msg = maybe_append_note(string_format('WARNING: %s nearby — Avoid', p.name), player);
                    ui.show_toast(msg, 'avoid_nearby');
                elseif (tags:find('Friend') and allow_friend) then
                    ui.alerted_players[p.name] = true;
                    local msg = maybe_append_note(string_format('%s is nearby (Friend)', p.name), player);
                    ui.show_toast(msg, 'friend_nearby');
                end
                -- Untagged tracked players: no nearby alert (only party join fires)
            end
        end
    end
end

--- Reset alerted players when zoning.
function ui.reset_alerts()
    ui.alerted_players = {};
end

return ui;
