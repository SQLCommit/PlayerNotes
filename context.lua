--[[
    PlayerNotes v1.0.0 - Game Context Capture
    Captures zone, party, nearby player, and target info from game APIs.

    Author: SQLCommit
    Version: 1.0.0
]]--

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

--- Get current zone name.
function context.get_zone_name()
    local zone_id = context.get_zone_id();
    if (zone_id > 0) then
        local res = AshitaCore:GetResourceManager();
        if (res ~= nil) then
            return res:GetString('zones.names', zone_id) or '';
        end
    end
    return '';
end

-------------------------------------------------------------------------------
-- Party
-------------------------------------------------------------------------------

--- Get active party member names (indices 1-5, skipping self at 0).
--- Returns a table of { name = string }.
function context.get_party_members()
    local members = {};
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return members; end

    local party = mem:GetParty();
    if (party == nil) then return members; end

    for i = 1, 5 do
        if (party:GetMemberIsActive(i) == 1) then
            local name = party:GetMemberName(i);
            if (name ~= nil and name ~= '') then
                members[#members + 1] = { name = name };
            end
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

--- Get the local player's character name.
function context.get_player_name()
    local mem = AshitaCore:GetMemoryManager();
    if (mem ~= nil) then
        local party = mem:GetParty();
        if (party ~= nil) then
            return party:GetMemberName(0) or '';
        end
    end
    return '';
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
