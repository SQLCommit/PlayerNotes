--[[
    PlayerNotes v1.0.0 - Player Tracking Addon for Ashita v4

    Track players you meet in FFXI with ratings, tags, and notes.
    Get toast alerts when tracked players appear nearby or join
    your party.

    Commands:
        /pn                      - Toggle the PlayerNotes window
        /pn show / hide          - Show or hide the window
        /pn <name> <note>        - Quick note on a player
        /pn rate <name> <1-5>    - Set player rating
        /pn tag <name> <tag>     - Toggle tag on a player
        /pn search <term>        - Search players
        /pn export               - Export all data to JSON
        /pn import [file]        - Import from export file
        /pn resetui / reset      - Reset UI layout
        /pn help                 - Show commands

    Author: SQLCommit
    Version: 1.0.0
]]--

addon.name      = 'playernotes';
addon.author    = 'SQLCommit';
addon.version   = '1.0.0';
addon.desc      = 'Player tracking with ratings, tags, and notes.';
addon.link      = 'https://github.com/SQLCommit/playernotes';

require 'common';

local chat     = require 'chat';
local settings = require 'settings';
local json     = require 'json';
local ui       = require 'ui';
local db       = require 'db';
local context  = require 'context';

-------------------------------------------------------------------------------
-- Default Settings (saved per-character via Ashita settings)
-------------------------------------------------------------------------------
local default_settings = T{
    show_on_load          = true,
    alert_known_players   = true,
    toast_append_note     = false,
    player_check_interval = 10,
    prompt_on_disband     = true,
    toast_x               = 10,
    toast_y               = 40,
    toast_duration        = 5,
    toast_sound_enabled   = true,
    -- Per-type sound toggles (6)
    toast_sound_player_alert  = true,
    toast_sound_friend_alert  = true,
    toast_sound_friend_nearby = true,
    toast_sound_avoid_alert   = true,
    toast_sound_avoid_nearby  = true,
    toast_sound_disband       = true,
    -- Per-type colors (6)
    toast_color_player_alert  = T{ 0.4, 1.0, 1.0 },
    toast_color_friend_alert  = T{ 0.4, 1.0, 0.4 },
    toast_color_friend_nearby = T{ 0.3, 0.8, 0.3 },
    toast_color_avoid_alert   = T{ 1.0, 0.3, 0.3 },
    toast_color_avoid_nearby  = T{ 1.0, 0.6, 0.3 },
    toast_color_disband       = T{ 0.4, 1.0, 1.0 },
    -- Per-type sound files (6)
    toast_sound_player_alert_file  = 'player_alert.wav',
    toast_sound_friend_alert_file  = 'friend_alert.wav',
    toast_sound_friend_nearby_file = 'friend_nearby.wav',
    toast_sound_avoid_alert_file   = 'avoid_alert.wav',
    toast_sound_avoid_nearby_file  = 'avoid_nearby.wav',
    toast_sound_disband_file       = 'disband.wav',
    -- Town filter (per-type)
    toast_friend_nearby_in_town = false,
    toast_avoid_nearby_in_town  = true,
    -- Advanced toast
    toast_fade_enabled       = true,
    toast_fade_in            = 0.0,
    toast_fade_out           = 1.0,
    toast_bg_opacity         = 0.8,
    toast_bg_color           = T{ 0.11, 0.11, 0.14 },
    toast_stack_down         = true,
    toast_stack_spacing      = 40,
    toast_max_visible        = 10,
    toast_click_dismiss      = false,
};

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
local last_player_check = 0;
local last_zone_id = 0;
local last_party_names = T{};
local known_party_names = T{};
local last_was_alliance = false;

-------------------------------------------------------------------------------
-- Valid tags (for command validation)
-------------------------------------------------------------------------------
local valid_tags = {
    healer = 'Healer', tank = 'Tank', dps = 'DPS', support = 'Support',
    crafter = 'Crafter', friend = 'Friend', avoid = 'Avoid', mentor = 'Mentor',
};

local exports_dir = '';

-------------------------------------------------------------------------------
-- Helper: Self-name check (prevent tracking yourself)
-------------------------------------------------------------------------------
local function is_self_name(name)
    local self_name = context.get_player_name();
    return self_name ~= '' and name:lower() == self_name:lower();
end

-------------------------------------------------------------------------------
-- Helper: Print help information
-------------------------------------------------------------------------------

local function print_help()
    print(chat.header(addon.name):append(chat.message('Available commands:')));
    local cmds = T{
        { '/pn',                        'Toggle the PlayerNotes window.' },
        { '/pn show / hide',            'Show or hide the window.' },
        { '/pn <name> <note>',          'Quick note on a player.' },
        { '/pn rate <name> <1-5>',      'Set player rating.' },
        { '/pn tag <name> <tag>',       'Toggle tag (Healer/Tank/DPS/Support/Crafter/Friend/Avoid/Mentor).' },
        { '/pn search <term>',          'Search players by name or tag.' },
        { '/pn export',                 'Export all players and notes to a JSON file.' },
        { '/pn import [file]',          'Import from the latest (or named) export file.' },
        { '/pn resetui',                'Reset window size and position.' },
        { '/pn help',                   'Show this help message.' },
    };
    cmds:ieach(function (v)
        print(chat.header(addon.name)
            :append(chat.message('  '))
            :append(chat.success(v[1]))
            :append(chat.message(' - ' .. v[2])));
    end);
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

ashita.events.register('load', 'playernotes_load', function ()
    local s = settings.load(default_settings);

    -- Initialize database
    local config_path = AshitaCore:GetInstallPath() .. '\\config\\addons\\playernotes';
    ashita.fs.create_directory(config_path);
    db.init(config_path);

    exports_dir = config_path .. '\\exports';
    ashita.fs.create_directory(exports_dir);

    -- Initialize UI
    ui.init(db, context, s, default_settings);
    ui.is_open[1] = s.show_on_load;

    print(chat.header(addon.name):append(chat.message('v' .. addon.version .. ' loaded. Use ')):append(chat.success('/pn')):append(chat.message(' to toggle window.')));
end);

ashita.events.register('unload', 'playernotes_unload', function ()
    ui.sync_settings();
    settings.save();
    db.close();
end);

ashita.events.register('command', 'playernotes_command', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/pn', '/playernotes')) then
        return;
    end

    e.blocked = true;

    -- /pn - Toggle window
    if (#args == 1) then
        ui.is_open[1] = not ui.is_open[1];
        return;
    end

    -- /pn show
    if (args[2]:any('show')) then
        ui.is_open[1] = true;
        return;
    end

    -- /pn hide
    if (args[2]:any('hide')) then
        ui.is_open[1] = false;
        return;
    end

    -- /pn help
    if (args[2]:any('help')) then
        print_help();
        return;
    end

    -- /pn resetui
    if (args[2]:any('resetui', 'reset')) then
        ui.reset_pending = true;
        ui.is_open[1] = true;
        print(chat.header(addon.name):append(chat.success('UI reset to defaults.')));
        return;
    end

    -- /pn export
    if (args[2]:any('export')) then
        local data = db.export_all();

        -- Count notes
        local note_count = 0;
        for _, p in ipairs(data.players) do
            note_count = note_count + #p.notes;
        end

        -- Add meta block
        data.meta = {
            addon        = 'playernotes',
            version      = addon.version,
            exported_at  = os.date('%Y-%m-%d %H:%M:%S'),
            player_count = #data.players,
            note_count   = note_count,
        };

        local ok, encoded = pcall(json.encode, data);
        if (not ok) then
            print(chat.header(addon.name):append(chat.error('Export failed: could not encode JSON.')));
            return;
        end

        local filename = 'playernotes_' .. os.date('%Y%m%d_%H%M%S') .. '.json';
        local filepath = exports_dir .. '\\' .. filename;
        local f, err = io.open(filepath, 'w');
        if (f == nil) then
            print(chat.header(addon.name):append(chat.error('Export failed: ' .. (err or 'unknown error'))));
            return;
        end
        f:write(encoded);
        f:close();

        print(chat.header(addon.name):append(chat.success('Exported: '))
            :append(chat.message(filename))
            :append(chat.message(' (' .. #data.players .. ' players, ' .. note_count .. ' notes)')));
        return;
    end

    -- /pn import [filename]
    if (args[2]:any('import')) then
        local filepath = nil;

        if (#args >= 3) then
            -- Specific filename provided
            local fname = args[3];
            if (fname:find('\\') or fname:find('/')) then
                filepath = fname; -- Absolute or relative path
            else
                filepath = exports_dir .. '\\' .. fname;
            end
        else
            -- Find latest export file
            local files = ashita.fs.get_dir(exports_dir, '.*%.json', false);
            if (files == nil or #files == 0) then
                print(chat.header(addon.name):append(chat.error('No export files found in exports/ directory.')));
                return;
            end
            table.sort(files);
            filepath = exports_dir .. '\\' .. files[#files];
        end

        local f, err = io.open(filepath, 'r');
        if (f == nil) then
            print(chat.header(addon.name):append(chat.error('Import failed: ' .. (err or 'file not found'))));
            return;
        end
        local content = f:read('*a');
        f:close();

        local ok, data = pcall(json.decode, content);
        if (not ok or data == nil) then
            print(chat.header(addon.name):append(chat.error('Import failed: invalid JSON.')));
            return;
        end

        if (data.meta == nil or data.meta.addon ~= 'playernotes' or type(data.players) ~= 'table') then
            print(chat.header(addon.name):append(chat.error('Import failed: not a valid PlayerNotes export file.')));
            return;
        end

        local result = db.import_data(data.players);
        print(chat.header(addon.name):append(chat.success('Import complete: '))
            :append(chat.message(result.players_added .. ' added, ' .. result.players_updated .. ' updated, '
                .. result.notes_added .. ' notes added, ' .. result.notes_skipped .. ' skipped')));
        return;
    end

    -- /pn search <term>
    if (args[2]:any('search') and #args >= 3) then
        local term = args:concat(' ', 3);
        ui.search_buf[1] = term;
        ui.db.search_dirty = true;
        ui.is_open[1] = true;
        return;
    end

    -- /pn rate <name> <1-5>
    if (args[2]:any('rate') and #args >= 4) then
        local pname = args[3];
        if (is_self_name(pname)) then
            print(chat.header(addon.name):append(chat.error('Cannot track yourself.')));
            return;
        end
        local rating = tonumber(args[4]);
        if (rating ~= nil and rating >= 0 and rating <= 5) then
            local player = db.get_player_by_name(pname);
            if (player ~= nil) then
                db.update_player(player.id, rating, player.tags);
                print(chat.header(addon.name):append(chat.success('Rating set: '))
                    :append(chat.message(pname .. ' = ' .. rating .. ' stars')));
            else
                -- Create player with rating
                local id = db.add_player(pname, rating, '');
                if (id ~= nil) then
                    print(chat.header(addon.name):append(chat.success('Player added with rating: '))
                        :append(chat.message(pname .. ' = ' .. rating .. ' stars')));
                end
            end
        else
            print(chat.header(addon.name):append(chat.error('Rating must be 0-5.')));
        end
        return;
    end

    -- /pn tag <name> <tag>
    if (args[2]:any('tag') and #args >= 4) then
        local pname = args[3];
        if (is_self_name(pname)) then
            print(chat.header(addon.name):append(chat.error('Cannot track yourself.')));
            return;
        end
        local tag_input = args[4]:lower();
        local tag_name = valid_tags[tag_input];
        if (tag_name == nil) then
            print(chat.header(addon.name):append(chat.error('Unknown tag. Valid: Healer, Tank, DPS, Support, Crafter, Friend, Avoid, Mentor')));
            return;
        end

        local player = db.get_player_by_name(pname);
        if (player == nil) then
            -- Create player with tag
            db.add_player(pname, 0, tag_name);
            print(chat.header(addon.name):append(chat.success('Player added with tag: '))
                :append(chat.message(pname .. ' [' .. tag_name .. ']')));
        else
            -- Toggle tag
            local tags = player.tags or '';
            if (tags:find(tag_name)) then
                tags = tags:gsub(',?' .. tag_name .. ',?', '');
                tags = tags:gsub('^,', ''):gsub(',$', '');
                print(chat.header(addon.name):append(chat.message('Tag removed: '))
                    :append(chat.message(pname .. ' [-' .. tag_name .. ']')));
            else
                if (tags ~= '') then tags = tags .. ','; end
                tags = tags .. tag_name;
                print(chat.header(addon.name):append(chat.success('Tag added: '))
                    :append(chat.message(pname .. ' [+' .. tag_name .. ']')));
            end
            db.update_player(player.id, player.rating, tags);
        end
        return;
    end

    -- /pn <name> <note> - Quick note (default: anything with 3+ args)
    if (#args >= 3) then
        local pname = args[2];
        if (is_self_name(pname)) then
            print(chat.header(addon.name):append(chat.error('Cannot track yourself.')));
            return;
        end
        local note_text = args:concat(' ', 3);

        -- Create or get player
        local player = db.get_player_by_name(pname);
        local player_id;
        if (player ~= nil) then
            player_id = player.id;
        else
            player_id = db.add_player(pname, 0, '');
        end

        if (player_id ~= nil) then
            local zone_name = context.get_zone_name();
            db.add_note(player_id, note_text, zone_name);
            print(chat.header(addon.name):append(chat.success('Note added: '))
                :append(chat.message(pname .. ' - ' .. note_text)));
        end
        return;
    end

    -- Unknown subcommand
    print(chat.header(addon.name):append(chat.error('Unknown command. Use /pn help for usage.')));
end);

ashita.events.register('d3d_present', 'playernotes_present', function ()
    -- Save settings if UI flagged a change
    if (ui.settings_dirty) then
        ui.settings_dirty = false;
        ui.sync_settings();
        settings.save();
    end

    if (ui.settings == nil) then
        ui.render();
        return;
    end

    -- Zone change detection
    local zone_id = context.get_zone_id();
    if (zone_id ~= last_zone_id and zone_id > 0) then
        if (last_zone_id > 0) then
            ui.reset_alerts();
        end
        last_zone_id = zone_id;
    end

    -- Periodic checks
    local now = os.clock();
    if (now - last_player_check >= (ui.settings.player_check_interval or 10)) then
        last_player_check = now;

        local party = context.get_party_members();

        -- Player proximity + party alerts
        if (ui.settings.alert_known_players) then
            local nearby = context.get_nearby_players();
            local in_town = context.is_town_zone(zone_id);
            ui.check_party_alerts(party, db.get_player_by_name);
            ui.check_nearby_alerts(nearby, db.get_player_by_name, in_town);
        end

        -- Disband detection
        local current_names = T{};
        for _, p in ipairs(party) do
            current_names:append(p.name);
            if (not known_party_names:contains(p.name)) then
                known_party_names:append(p.name);
            end
        end
        local current_is_alliance = context.is_alliance();

        if (#last_party_names > 0 and #current_names == 0) then
            if (ui.settings.prompt_on_disband and not last_was_alliance) then
                ui.show_disband_popup(known_party_names);
            end
            known_party_names = T{};
        end

        last_party_names = current_names;
        last_was_alliance = current_is_alliance;
    end

    ui.render();
end);

-------------------------------------------------------------------------------
-- Event: Settings changed externally
-------------------------------------------------------------------------------
settings.register('settings', 'playernotes_settings_update', function(s)
    if (s ~= nil) then
        ui.apply_settings(s);
    end
end);
