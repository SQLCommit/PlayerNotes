--[[
    PlayerNotes v1.2.1 - Game Context Capture
    Captures zone, party, nearby player, and target info from game APIs.

    Author: SQLCommit
    Version: 1.2.1
]]--

require 'common';

local context = {};

-------------------------------------------------------------------------------
-- Town Zone IDs
-------------------------------------------------------------------------------
local town_zones = {
    [230] = true, [231] = true, [232] = true, [233] = true,  -- San d'Oria
    [234] = true, [235] = true, [236] = true, [237] = true,  -- Bastok
    [238] = true, [239] = true, [240] = true, [241] = true, [242] = true, -- Windurst
    [243] = true, [244] = true, [245] = true, [246] = true,  -- Jeuno
    [247] = true, -- Rabao
    [248] = true, -- Selbina
    [249] = true, -- Mhaura
    [250] = true, -- Kazham
    [252] = true, -- Norg
    [26]  = true, -- Tavnazian Safehold
    [48]  = true, -- Al Zahbi
    [50]  = true, -- Whitegate
    [53]  = true, -- Nashmau
    [256] = true, [257] = true, -- Adoulin
};

--- Check if a zone ID is a town zone.
function context.is_town_zone(zone_id)
    return town_zones[zone_id] == true;
end

-------------------------------------------------------------------------------
-- Zone
-------------------------------------------------------------------------------

--- Get current zone ID.
function context.get_zone_id()
    local mem = AshitaCore:GetMemoryManager();
    if (mem ~= nil) then
        local party = mem:GetParty();
        if (party ~= nil) then
            return party:GetMemberZone(0);
        end
    end
    return 0;
end

--- Get current zone name (cached per zone_id).
local cached_zone_id = 0;
local cached_zone_name = '';

function context.get_zone_name()
    local zone_id = context.get_zone_id();
    if (zone_id == cached_zone_id and cached_zone_id > 0) then
        return cached_zone_name;
    end
    if (zone_id > 0) then
        local res = AshitaCore:GetResourceManager();
        if (res ~= nil) then
            cached_zone_id = zone_id;
            cached_zone_name = res:GetString('zones.names', zone_id) or '';
            return cached_zone_name;
        end
    end
    cached_zone_id = 0;
    cached_zone_name = '';
    return '';
end

-------------------------------------------------------------------------------
-- Party
-------------------------------------------------------------------------------

--- Trust name cache: populated from entity type scans and idx >= 1792.
--- Survives zone transitions so despawned trusts are still recognized.
local known_trust_names = {};

--- Get active party member names (indices 1-5, skipping self at 0).
--- Filters trusts using entity type scan, index range, and name cache.
--- Returns a table of { name = string }.
function context.get_party_members()
    local members = {};
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return members; end

    local party = mem:GetParty();
    if (party == nil) then return members; end

    local entity_mgr = mem:GetEntity();

    -- Collect active party member names
    local slots = {};
    local name_set = {};
    for i = 1, 5 do
        if (party:GetMemberIsActive(i) == 1) then
            local name = party:GetMemberName(i);
            if (name ~= nil and name ~= '') then
                slots[#slots + 1] = { slot = i, name = name };
                name_set[name] = true;
            end
        end
    end

    if (#slots == 0) then return members; end

    -- Scan entity array: for each party member name, check entity type.
    -- Type 0 = PC (confirmed player), anything else = trust/NPC.
    -- This catches trusts even when GetMemberIndex returns 0.
    local entity_is_pc = {};
    if (entity_mgr ~= nil) then
        for j = 1, 2047 do
            if (entity_mgr:GetRenderFlags0(j) ~= 0) then
                local ename = entity_mgr:GetName(j);
                if (ename ~= nil and name_set[ename]) then
                    if (entity_mgr:GetType(j) == 0) then
                        entity_is_pc[ename] = true;
                        known_trust_names[ename] = nil;
                    elseif (not entity_is_pc[ename]) then
                        known_trust_names[ename] = true;
                    end
                end
            end
        end
    end

    -- Classify each party member
    for _, s in ipairs(slots) do
        local idx = party:GetMemberIndex(s.slot);
        local include = false;

        if (idx ~= nil and idx >= 1792) then
            -- Trust/pet entity range (0x700+)
            known_trust_names[s.name] = true;
        elseif (entity_is_pc[s.name]) then
            -- Confirmed PC entity in our zone (type 0)
            include = true;
        elseif (known_trust_names[s.name]) then
            -- Cached trust name (from entity scan or previous check)
            include = false;
        else
            -- Not in our entity array and not a known trust = remote PC
            include = true;
        end

        if (include) then
            members[#members + 1] = { name = s.name };
        end
    end

    return members;
end

--- Check if player is currently in an alliance (indices 6-17).
function context.is_alliance()
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return false; end

    local party = mem:GetParty();
    if (party == nil) then return false; end

    for i = 6, 17 do
        if (party:GetMemberIsActive(i) == 1) then
            return true;
        end
    end
    return false;
end

-------------------------------------------------------------------------------
-- Nearby Players
-------------------------------------------------------------------------------

--- Scan entity array for nearby player characters.
--- Returns a table of { name = string, server_id = number }.
function context.get_nearby_players()
    local players = {};
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return players; end

    local entity_mgr = mem:GetEntity();
    if (entity_mgr == nil) then return players; end

    for i = 1, 2047 do
        local render = entity_mgr:GetRenderFlags0(i);
        if (render ~= 0) then
            local etype = entity_mgr:GetType(i);
            if (etype == 0) then
                local name = entity_mgr:GetName(i);
                if (name ~= nil and name ~= '') then
                    players[#players + 1] = {
                        name = name,
                        server_id = entity_mgr:GetServerId(i) or 0,
                    };
                end
            end
        end
    end

    return players;
end

-------------------------------------------------------------------------------
-- Player Name
-------------------------------------------------------------------------------

--- Get the local player's character name (cached after first successful read).
local cached_player_name = nil;

function context.get_player_name()
    if (cached_player_name ~= nil) then return cached_player_name; end

    local mem = AshitaCore:GetMemoryManager();
    if (mem ~= nil) then
        local party = mem:GetParty();
        if (party ~= nil) then
            local name = party:GetMemberName(0) or '';
            if (name ~= '') then
                cached_player_name = name;
            end
            return name;
        end
    end
    return '';
end

--- Clear the cached player name and trust names (call on logout/character switch).
function context.clear_player_cache()
    cached_player_name = nil;
    known_trust_names = {};
end

-------------------------------------------------------------------------------
-- Player Info (for deferred per-character DB init)
-------------------------------------------------------------------------------

--- Get the local player's character name and server ID.
--- Returns name, server_id or '', 0 if not yet available.
--- Requires the player to be in a valid zone (not character select screen).
function context.get_player_info()
    local player = GetPlayerEntity();
    if (player == nil) then return '', 0; end

    local name = player.Name;
    if (name == nil or name == '' or name == 'N/A') then return '', 0; end

    local server_id = player.ServerId;
    if (server_id == nil or server_id == 0) then return '', 0; end

    -- Wait until actually in a zone (not character select screen)
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return '', 0; end
    local party = mem:GetParty();
    if (party == nil) then return '', 0; end
    local zone_id = party:GetMemberZone(0);
    if (zone_id == nil or zone_id == 0) then return '', 0; end

    return name, server_id;
end

-------------------------------------------------------------------------------
-- Target
-------------------------------------------------------------------------------

--- Get current target name (for "Add from Target" button).
--- Returns name only if target is a player character (entity type 0).
--- Returns '', 'not_pc' if target is an NPC/mob, or '', nil if no target.
function context.get_target_name()
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return '', nil; end

    local target = mem:GetTarget();
    if (target == nil) then return '', nil; end

    local tidx = target:GetTargetIndex(0);
    if (tidx ~= nil and tidx > 0) then
        local entity_mgr = mem:GetEntity();
        if (entity_mgr ~= nil) then
            if (entity_mgr:GetType(tidx) ~= 0) then
                return '', 'not_pc';
            end
            local name = entity_mgr:GetName(tidx);
            return name or '', nil;
        end
    end
    return '', nil;
end

return context;
