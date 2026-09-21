-- PlayerNotes game context: zone, party, nearby players, and target.
-- Author: SQLCommit

require 'common';

local context = {};

-- Town Zone IDs
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

function context.is_town_zone(zone_id)
    return town_zones[zone_id] == true;
end

-- Zone

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

-- Cache zone names by zone ID.
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

-- Presence

-- Require an actor pointer and a clear invisible bit before using entity identity.
-- Departed slots retain names and IDs, so RenderFlags0 alone is insufficient.
-- This presence rule is verified for mobs; its use for PCs assumes shared entity semantics.
local function is_present(entity_mgr, i)
    if (entity_mgr == nil) then return false; end
    local ok, live = pcall(function()
        local ap = entity_mgr:GetActorPointer(i);
        if (ap == nil or ap == 0) then return false; end
        local f2 = entity_mgr:GetRenderFlags2(i) or 0;
        if (bit.band(f2, 0x40) ~= 0) then return false; end
        return true;
    end);
    -- If an accessor is unavailable, fall back rather than hiding every player.
    if (not ok) then return true; end
    return live;
end

-- Party

-- Retain trust names across zoning to recognize despawned trusts.
local known_trust_names = {};

-- Return party names excluding self and trusts. Use each member's target entity index:
-- GetMemberIndex may be zero or stale, and a render-only scan misses unrendered trusts.
function context.get_party_members()
    local members = {};
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return members; end

    local party = mem:GetParty();
    if (party == nil) then return members; end

    local entity_mgr = mem:GetEntity();

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

    -- Classify from the member's entity first. The trust/pet range starts at 1792;
    -- otherwise confirm the entity name before trusting its type to avoid stale indices.
    local verdict = {};   -- name -> true (PC) / false (trust); nil = undecided, pass 2 decides
    for _, s in ipairs(slots) do
        local eidx = party:GetMemberTargetIndex(s.slot) or 0;
        if (entity_mgr ~= nil and eidx > 0 and eidx < 2304) then
            if (eidx >= 1792) then
                -- A PC-typed slot contradicts the trust range; defer stale indices to the fallback scan.
                local ok, etype = pcall(function() return entity_mgr:GetType(eidx); end);
                if (ok and etype == 0 and entity_mgr:GetName(eidx) ~= s.name) then
                    -- stale: stay silent, pass 2 decides
                else
                    verdict[s.name] = false;
                    known_trust_names[s.name] = true;
                end
            else
                local ok, etype = pcall(function()
                    if (entity_mgr:GetName(eidx) ~= s.name) then return nil; end
                    return entity_mgr:GetType(eidx);
                end);
                if (ok and etype ~= nil) then
                    if (etype == 0) then
                        verdict[s.name] = true;
                        known_trust_names[s.name] = nil;
                    else
                        verdict[s.name] = false;
                        known_trust_names[s.name] = true;
                    end
                end
            end
        end
    end

    -- Fallback to rendered entities for members whose target index could not be classified.
    local need_fallback = false;
    for _, s in ipairs(slots) do
        if (verdict[s.name] == nil) then need_fallback = true; break; end
    end

    local entity_is_pc = {};
    if (need_fallback and entity_mgr ~= nil) then
        -- Scan the entity array by name. Range: PCs at 1024-1791, trusts/pets at 1792-2303.
        for j = 1024, 2303 do
            if (entity_mgr:GetRenderFlags0(j) ~= 0) then
                local ename = entity_mgr:GetName(j);
                if (ename ~= nil and name_set[ename] and verdict[ename] == nil) then
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

    for _, s in ipairs(slots) do
        local include;

        if (verdict[s.name] ~= nil) then
            include = verdict[s.name];
        else
            local idx = party:GetMemberIndex(s.slot);
            if (idx ~= nil and idx >= 1792) then
                known_trust_names[s.name] = true;
                include = false;
            elseif (entity_is_pc[s.name]) then
                include = true;
            elseif (known_trust_names[s.name]) then
                include = false;
            else
                include = true;
            end
        end

        if (include) then
            -- Carry the server ID to distinguish characters sharing a name.
            local sid = 0;
            local eidx = party:GetMemberTargetIndex(s.slot) or 0;
            if (entity_mgr ~= nil and eidx > 0 and eidx < 2304) then
                pcall(function()
                    -- Require presence before reading identity; departed slots retain matching names and
                    -- IDs.
                    if (entity_mgr:GetName(eidx) == s.name and is_present(entity_mgr, eidx)) then
                        sid = entity_mgr:GetServerId(eidx) or 0;
                    end
                end);
            end
            if (sid == 0) then
                -- GetMemberServerId reads 0 on LSB, so it is the fallback, never the first choice.
                local ok, msid = pcall(function() return party:GetMemberServerId(s.slot); end);
                if (ok and msid ~= nil) then sid = msid; end
            end
            members[#members + 1] = { name = s.name, server_id = sid or 0 };
        end
    end

    return members;
end

-- Resolve a loaded PC by name. Return zero when absent or ambiguous.
function context.find_server_id(name)
    if (name == nil or name == '') then return 0; end
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return 0; end
    local entity_mgr = mem:GetEntity();
    if (entity_mgr == nil) then return 0; end

    local found, hits = 0, 0;
    local lname = name:lower();
    for i = 1024, 1791 do
        local ok = pcall(function()
            if (entity_mgr:GetRenderFlags0(i) == 0) then return; end
            -- Do not bind a profile from a departed player's stale slot.
            if (not is_present(entity_mgr, i)) then return; end
            if (entity_mgr:GetType(i) ~= 0) then return; end
            local ename = entity_mgr:GetName(i);
            if (ename ~= nil and ename:lower() == lname) then
                hits = hits + 1;
                found = entity_mgr:GetServerId(i) or 0;
            end
        end);
        if (not ok) then return 0; end
    end
    if (hits ~= 1) then return 0; end
    return found;
end

-- Retain known trust names so previously unclassified roster entries can be filtered later.
function context.is_known_trust(name)
    return known_trust_names[name] == true;
end

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

-- Nearby Players

-- Return nearby PCs as {name, server_id}.
function context.get_nearby_players()
    local players = {};
    local mem = AshitaCore:GetMemoryManager();
    if (mem == nil) then return players; end

    local entity_mgr = mem:GetEntity();
    if (entity_mgr == nil) then return players; end

    -- PCs are only at entity indices 1024-1791.
    for i = 1024, 1791 do
        local render = entity_mgr:GetRenderFlags0(i);
        if (render ~= 0 and is_present(entity_mgr, i)) then
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

-- Player Name

-- Cache the local name after a successful read.
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

-- Clear character-specific caches on logout or switch.
function context.clear_player_cache()
    cached_player_name = nil;
    known_trust_names = {};
end



-- Target

-- Return a PC target name; NPC/mob gives empty name and not_pc, no target gives empty name and nil.
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
