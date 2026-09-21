-- PlayerNotes settings windows. Shared UI state is injected through bind().

require 'common';

local imgui = require 'imgui';
local state = require 'ui_state';

local colors        = state.colors;
local trim_buf      = state.trim_buf;
local string_format = string.format;

-- Toast test cycle state
local toast_test_index = 0;
local toast_test_types = {
    { toast = 'player_alert',  fmt = '%s joined party' },
    { toast = 'friend_alert',  fmt = '%s joined party (Friend)' },
    { toast = 'friend_nearby', fmt = '%s is nearby (Friend)' },
    { toast = 'avoid_alert',   fmt = 'WARNING: %s joined party — Avoid' },
    { toast = 'avoid_nearby',  fmt = 'WARNING: %s nearby — Avoid' },
    { toast = 'disband',       fmt = 'Party disbanded — add notes?' },
};

local M = {};

-- Inject the shared table to avoid a circular require of ui.
local ui;
function M.bind(ui_ref)
    ui = ui_ref;
end

function M.render_settings()
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

    -- Detection sub-options (indented + disabled when detection off)
    imgui.BeginDisabled(not s.alert_known_players);
    imgui.Indent();

    local append_note = { s.toast_append_note, };
    if (imgui.Checkbox('Append pinned note to alerts', append_note)) then
        s.toast_append_note = append_note[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Alert toasts will include the pinned note (if set) or the most recent note.');
    end

    local friend_town = { s.toast_friend_nearby_in_town, };
    if (imgui.Checkbox('Friend nearby alerts in town', friend_town)) then
        s.toast_friend_nearby_in_town = friend_town[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('When unchecked, Friend nearby alerts are suppressed in town zones.');
    end

    local avoid_town = { s.toast_avoid_nearby_in_town ~= false, };
    if (imgui.Checkbox('Avoid nearby alerts in town', avoid_town)) then
        s.toast_avoid_nearby_in_town = avoid_town[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('When unchecked, Avoid nearby alerts are suppressed in town zones.');
    end

    imgui.Unindent();
    imgui.EndDisabled();

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
        imgui.SetTooltip('Master toggle for all toast alert sounds. Clear individual filenames in Advanced to mute specific types.');
    end

    local click_dismiss = { s.toast_click_dismiss == true, };
    if (imgui.Checkbox('Click to dismiss', click_dismiss)) then
        s.toast_click_dismiss = click_dismiss[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Click on a toast to immediately dismiss it.');
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
    local screen_w, screen_h = imgui.GetIO().DisplaySize.x, imgui.GetIO().DisplaySize.y;
    if (screen_w < 800) then screen_w = 3840; end
    if (screen_h < 600) then screen_h = 2160; end
    if (imgui.SliderInt('Toast X position', ui.setting_toast_x, 0, screen_w)) then
        s.toast_x = ui.setting_toast_x[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Horizontal screen position for toast notifications.');
    end
    if (imgui.SliderInt('Toast Y position', ui.setting_toast_y, 0, screen_h)) then
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
        imgui.SetTooltip('Configure animations, colors, layout, sounds, and more.');
    end
    imgui.SameLine();
    if (imgui.Button('Test')) then
        toast_test_index = toast_test_index + 1;
        if (toast_test_index > #toast_test_types) then
            toast_test_index = 1;
        end
        local t = toast_test_types[toast_test_index];
        local name = ui.context.get_player_name();
        if (name == '') then name = 'Player'; end
        local text = t.fmt:find('%%s') and string_format(t.fmt, name) or t.fmt;
        ui.show_toast(text, t.toast);
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Click to show a sample toast. Each press cycles to the next type.');
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
            -- Deep-copy tables (color arrays) to avoid corrupting defaults
            if (type(v) == 'table') then
                ui.settings[k] = T{};
                for i2, v2 in pairs(v) do
                    ui.settings[k][i2] = v2;
                end
            else
                ui.settings[k] = v;
            end
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

function M.render_advanced()
    if (not ui.show_advanced_toast[1]) then return; end

    local s = ui.settings;
    if (s == nil) then return; end

    imgui.SetNextWindowSize({ 420, 0, }, ImGuiCond_Appearing);

    if (not imgui.Begin('Advanced Toast Settings##pn', ui.show_advanced_toast, ImGuiWindowFlags_AlwaysAutoResize)) then
        imgui.End();
        return;
    end

    local section_flags = bit.bor(ImGuiTreeNodeFlags_DefaultOpen, ImGuiTreeNodeFlags_NoTreePushOnOpen);

    -- Scan interval
    imgui.PushStyleColor(ImGuiCol_Text, colors.header);
    local timing_open = imgui.TreeNodeEx('Timing', section_flags);
    imgui.PopStyleColor();
    imgui.Separator();
    if (timing_open) then
    imgui.PushItemWidth(200);
    if (imgui.SliderInt('Check interval (seconds)', ui.setting_check_interval, 5, 60)) then
        s.player_check_interval = ui.setting_check_interval[1];
        ui.settings_dirty = true;
    end
    imgui.PopItemWidth();
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('How often to scan for nearby tracked players. Lower = more responsive, higher = less CPU.');
    end
    end

    -- Animation section
    imgui.Spacing();
    imgui.PushStyleColor(ImGuiCol_Text, colors.header);
    local anim_open = imgui.TreeNodeEx('Animation', section_flags);
    imgui.PopStyleColor();
    imgui.Separator();
    if (anim_open) then

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

    local slide_enabled = { s.toast_slide_enabled == true, };
    if (imgui.Checkbox('Slide enabled', slide_enabled)) then
        s.toast_slide_enabled = slide_enabled[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Enable slide-in and slide-out animation for toast notifications.');
    end

    if (s.toast_slide_enabled) then
        imgui.PushItemWidth(200);
        if (imgui.SliderFloat('Slide in (sec)', ui.setting_slide_in, 0.0, 3.0, '%.1f')) then
            s.toast_slide_in = ui.setting_slide_in[1];
            ui.settings_dirty = true;
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('How long the toast takes to slide in. 0 = instant.');
        end
        if (imgui.SliderFloat('Slide out (sec)', ui.setting_slide_out, 0.0, 3.0, '%.1f')) then
            s.toast_slide_out = ui.setting_slide_out[1];
            ui.settings_dirty = true;
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('How long the toast takes to slide out before expiring.');
        end
        if (imgui.Combo('Slide direction', ui.setting_slide_dir, 'From left\0From right\0From top\0From bottom\0')) then
            s.toast_slide_dir = ui.setting_slide_dir[1];
            ui.settings_dirty = true;
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('Direction toasts slide in from off-screen.');
        end
        imgui.PopItemWidth();
        local bounce = { s.toast_slide_bounce == true, };
        if (imgui.Checkbox('Bounce', bounce)) then
            s.toast_slide_bounce = bounce[1];
            ui.settings_dirty = true;
        end
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('Elastic overshoot on slide-in for a bouncy feel. Slide-out stays smooth.');
        end
        if (s.toast_slide_bounce) then
            imgui.PushItemWidth(200);
            if (imgui.SliderFloat('Bounce speed', ui.setting_bounce_speed, 0.15, 0.80, '%.2f')) then
                s.toast_bounce_speed = ui.setting_bounce_speed[1];
                ui.settings_dirty = true;
            end
            if (imgui.IsItemHovered()) then
                imgui.SetTooltip('Controls bounce oscillation period. Lower = faster/tighter bounces, higher = slower/wider.');
            end
            imgui.PopItemWidth();
        end
    end

    end -- Animation

    -- Layout section
    imgui.Spacing();
    imgui.PushStyleColor(ImGuiCol_Text, colors.header);
    local layout_open = imgui.TreeNodeEx('Layout', section_flags);
    imgui.PopStyleColor();
    imgui.Separator();
    if (layout_open) then

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

    end -- Layout

    -- Appearance section
    imgui.Spacing();
    imgui.PushStyleColor(ImGuiCol_Text, colors.header);
    local appear_open = imgui.TreeNodeEx('Appearance', section_flags);
    imgui.PopStyleColor();
    imgui.Separator();
    if (appear_open) then

    imgui.PushItemWidth(200);
    if (imgui.SliderInt('Corner rounding', ui.setting_toast_rounding, 0, 16)) then
        s.toast_rounding = ui.setting_toast_rounding[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Rounded corner radius for toast windows. 0 = square.');
    end
    if (imgui.SliderFloat('Border size', ui.setting_toast_border, 0.0, 3.0, '%.1f')) then
        s.toast_border = ui.setting_toast_border[1];
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Border thickness around toast windows. 0 = no border.');
    end
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
    if (imgui.ColorEdit3('Border color', ui.setting_toast_border_color)) then
        s.toast_border_color = T{ ui.setting_toast_border_color[1], ui.setting_toast_border_color[2], ui.setting_toast_border_color[3] };
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Border color for toast windows. Set border size above 0 to see it.');
    end

    end -- Appearance

    -- Text Colors section
    imgui.Spacing();
    imgui.PushStyleColor(ImGuiCol_Text, colors.header);
    local tcolors_open = imgui.TreeNodeEx('Text Colors', section_flags);
    imgui.PopStyleColor();
    imgui.Separator();
    if (tcolors_open) then

    if (imgui.ColorEdit3('Player alert', ui.setting_color_player_alert)) then
        s.toast_color_player_alert = T{ ui.setting_color_player_alert[1], ui.setting_color_player_alert[2], ui.setting_color_player_alert[3] };
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Text color for tracked player party join alerts.');
    end
    if (imgui.ColorEdit3('Friend alert', ui.setting_color_friend_alert)) then
        s.toast_color_friend_alert = T{ ui.setting_color_friend_alert[1], ui.setting_color_friend_alert[2], ui.setting_color_friend_alert[3] };
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Text color for Friend-tagged player party join alerts.');
    end
    if (imgui.ColorEdit3('Friend nearby', ui.setting_color_friend_nearby)) then
        s.toast_color_friend_nearby = T{ ui.setting_color_friend_nearby[1], ui.setting_color_friend_nearby[2], ui.setting_color_friend_nearby[3] };
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Text color for Friend-tagged player proximity alerts.');
    end
    if (imgui.ColorEdit3('Avoid alert', ui.setting_color_avoid_alert)) then
        s.toast_color_avoid_alert = T{ ui.setting_color_avoid_alert[1], ui.setting_color_avoid_alert[2], ui.setting_color_avoid_alert[3] };
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Text color for Avoid-tagged player party join warnings.');
    end
    if (imgui.ColorEdit3('Avoid nearby', ui.setting_color_avoid_nearby)) then
        s.toast_color_avoid_nearby = T{ ui.setting_color_avoid_nearby[1], ui.setting_color_avoid_nearby[2], ui.setting_color_avoid_nearby[3] };
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Text color for Avoid-tagged player proximity warnings.');
    end
    if (imgui.ColorEdit3('Disband', ui.setting_color_disband)) then
        s.toast_color_disband = T{ ui.setting_color_disband[1], ui.setting_color_disband[2], ui.setting_color_disband[3] };
        ui.settings_dirty = true;
    end
    if (imgui.IsItemHovered()) then
        imgui.SetTooltip('Text color for party disband notifications.');
    end

    end -- Text Colors

    -- Per-type toast selection
    imgui.Spacing();
    imgui.PushStyleColor(ImGuiCol_Text, colors.header);
    local alerts_open = imgui.TreeNodeEx('Alert Types', section_flags);
    imgui.PopStyleColor();
    imgui.Separator();
    if (alerts_open) then
    imgui.TextColored(colors.muted, 'Uncheck to disable an alert. Clear the filename to mute just its sound.');
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
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('Enable or disable the ' .. st.label .. ' alert. Clear the filename to mute just the sound.');
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
        if (imgui.IsItemHovered()) then
            imgui.SetTooltip('Sound file for ' .. st.label .. '. Clear to mute sound. Must be in the sounds/ folder.');
        end
        imgui.PopItemWidth();
    end
    imgui.TextColored(colors.muted, 'Files must be in the sounds/ folder.');
    end -- Alert Types

    imgui.Spacing();
    imgui.Separator();
    if (imgui.Button('Close##adv_toast')) then
        ui.show_advanced_toast[1] = false;
    end

    imgui.End();
end

return M;
