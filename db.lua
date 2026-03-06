--[[
    PlayerNotes v1.2.1 - SQLite3 Persistence Layer
    Two-table schema: players, notes.
    Uses Ashita v4.30's built-in LuaSQLite3 with dirty-flag caching.

    Per-character databases: each character gets their own DB file under
    config/addons/playernotes/<CharName>_<ServerId>/playernotes.db matching
    Ashita's settings folder convention. Avoids multi-box write contention
    and keeps data separated across characters/servers.

    LuaSQLite3 API reference:
        db:exec(sql)                    -- Execute SQL statement
        db:rows(sql)                    -- Iterator over result rows (as arrays)
        db:nrows(sql)                   -- Iterator over result rows (as named tables)
        db:close()                      -- Close database connection
        db:prepare(sql)                 -- Prepare a statement
        stmt:bind_values(...)           -- Bind values to prepared statement
        stmt:step()                     -- Execute step
        stmt:finalize()                 -- Finalize statement

    Author: SQLCommit
    Version: 1.2.1
]]--

require 'common';

local os_time = os.time;

local db = {};
db.conn = nil;
db.path = nil;
db.char_name = nil;  -- character folder this DB belongs to

-- Running counters (O(1) counts instead of COUNT(*) scans)
db._player_count = 0;
db._note_count = 0;

-- Cache dirty flags
db.players_dirty = true;
db.notes_dirty = true;
db.search_dirty = true;

-- In-memory caches
db.players_cache = nil;
db.players_sort = nil;
db.notes_cache = {};
db.search_cache = nil;
db.search_cache_term = '';
db.player_lookup_cache = {};
db.player_miss_cache = {};  -- negative cache: names confirmed not in DB
db.note_counts_cache = {};
db.tag_cache = nil;
db.tag_cache_tag = '';

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

function db.init(base_path, char_folder)
    if (db.conn ~= nil) then return; end  -- already initialized

    local sqlite3 = require 'sqlite3';

    -- Per-character subdirectory: config/addons/playernotes/<CharName>_<ServerId>/
    db.char_name = char_folder;
    local char_dir = base_path .. '\\' .. char_folder;
    ashita.fs.create_directory(char_dir);

    local new_db_path = char_dir .. '\\playernotes.db';

    -- Migrate from old shared DB location (pre-per-character)
    local old_db_path = base_path .. '\\playernotes.db';
    local old_f = io.open(old_db_path, 'r');
    if (old_f ~= nil) then
        old_f:close();
        -- Only migrate if new per-character DB doesn't already exist
        local new_f = io.open(new_db_path, 'r');
        if (new_f == nil) then
            os.rename(old_db_path, new_db_path);
            -- Also move WAL/SHM companion files if they exist
            os.rename(old_db_path .. '-wal', new_db_path .. '-wal');
            os.rename(old_db_path .. '-shm', new_db_path .. '-shm');
        else
            new_f:close();
        end
    end

    db.path = new_db_path;
    db.conn = sqlite3.open(db.path);

    -- WAL mode for concurrent read safety, busy_timeout for rare write contention
    db.conn:exec('PRAGMA journal_mode=WAL;');
    db.conn:exec('PRAGMA foreign_keys=ON;');
    db.conn:exec('PRAGMA busy_timeout=3000;');

    db.conn:exec([[
        CREATE TABLE IF NOT EXISTS players (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            player_name TEXT NOT NULL UNIQUE COLLATE NOCASE,
            rating INTEGER NOT NULL DEFAULT 0,
            tags TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_players_name ON players(player_name);
        CREATE INDEX IF NOT EXISTS idx_players_rating ON players(rating);
        CREATE INDEX IF NOT EXISTS idx_players_updated ON players(updated_at);

        CREATE TABLE IF NOT EXISTS notes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            player_id INTEGER NOT NULL,
            note TEXT NOT NULL,
            zone_name TEXT NOT NULL DEFAULT '',
            job TEXT NOT NULL DEFAULT '',  -- vestigial: kept for existing DB compat, never populated
            created_at INTEGER NOT NULL,
            FOREIGN KEY (player_id) REFERENCES players(id) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_notes_player ON notes(player_id);
    ]]);

    -- Schema migration: add pinned column (silently ignored if already exists)
    pcall(function()
        db.conn:exec('ALTER TABLE notes ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;');
    end);
    db.conn:exec('CREATE INDEX IF NOT EXISTS idx_notes_pinned ON notes(player_id, pinned);');

    -- Initialize running counters from existing data
    for row in db.conn:nrows('SELECT COUNT(*) as c FROM players') do
        db._player_count = row.c;
    end
    for row in db.conn:nrows('SELECT COUNT(*) as c FROM notes') do
        db._note_count = row.c;
    end
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

--- Escape SQL LIKE wildcards (% and _) in search terms using backslash.
local function escape_like(term)
    return term:gsub('[%%_\\]', '\\%1');
end

local function invalidate_all()
    db.players_dirty = true;
    db.notes_dirty = true;
    db.search_dirty = true;
    db.player_lookup_cache = {};
    db.player_miss_cache = {};
    db.player_id_cache = {};
    db.note_counts_cache = {};
    db.tag_cache = nil;
end

-------------------------------------------------------------------------------
-- Player CRUD
-------------------------------------------------------------------------------

function db.add_player(name, rating, tags)
    if (db.conn == nil or name == nil or name == '') then return nil; end

    local now = os_time();
    local tag_str = '';
    if (tags ~= nil and type(tags) == 'table') then
        tag_str = table.concat(tags, ',');
    elseif (tags ~= nil and type(tags) == 'string') then
        tag_str = tags;
    end

    local stmt = db.conn:prepare([[
        INSERT OR IGNORE INTO players (player_name, rating, tags, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
    ]]);
    if (stmt == nil) then return nil; end
    local ok, err = pcall(function()
        stmt:bind_values(name, rating or 0, tag_str, now, now);
        stmt:step();
    end);
    stmt:finalize();
    if (not ok) then return nil; end

    -- If INSERT OR IGNORE skipped (player exists), changes() returns 0
    if (db.conn:changes() == 0) then
        local p = db.get_player_by_name(name);
        if (p ~= nil) then return p.id; end
        return nil;
    end

    local id = db.conn:last_insert_rowid();
    db._player_count = db._player_count + 1;

    invalidate_all();
    return id;
end

function db.update_player(id, rating, tags)
    if (db.conn == nil) then return; end

    local tag_str = '';
    if (tags ~= nil and type(tags) == 'table') then
        tag_str = table.concat(tags, ',');
    elseif (tags ~= nil and type(tags) == 'string') then
        tag_str = tags;
    end

    local now = os_time();
    local stmt = db.conn:prepare('UPDATE players SET rating = ?, tags = ?, updated_at = ? WHERE id = ?');
    if (stmt == nil) then return; end
    local ok = pcall(function()
        stmt:bind_values(rating or 0, tag_str, now, id);
        stmt:step();
    end);
    stmt:finalize();

    if (ok) then invalidate_all(); end
end

function db.delete_player(id)
    if (db.conn == nil) then return; end

    -- Count notes for this player before deletion (for running counter)
    local note_count = db.get_note_count(id);

    -- Foreign keys with ON DELETE CASCADE handle notes
    local stmt = db.conn:prepare('DELETE FROM players WHERE id = ?');
    if (stmt == nil) then return; end
    local ok = pcall(function()
        stmt:bind_values(id);
        stmt:step();
    end);
    stmt:finalize();

    if (ok) then
        db._player_count = math.max(0, db._player_count - 1);
        db._note_count = math.max(0, db._note_count - note_count);
        invalidate_all();
    end
end

-------------------------------------------------------------------------------
-- Player Queries (cached)
-------------------------------------------------------------------------------

--- Get all players sorted by column ID and direction.
--- Column IDs: 0=Name, 1=Rating, 4=Last Seen (2=Tags, 3=Notes not sortable).
function db.get_players(sort_col, sort_asc)
    if (db.conn == nil) then return T{}; end

    local sort_key = tostring(sort_col or 0) .. '_' .. tostring(sort_asc);
    if (not db.players_dirty and db.players_cache ~= nil and db.players_sort == sort_key) then
        return db.players_cache;
    end

    local order = 'player_name ASC';
    if (sort_col == 0) then
        order = sort_asc and 'player_name ASC' or 'player_name DESC';
    elseif (sort_col == 1) then
        order = sort_asc and 'rating ASC, player_name ASC' or 'rating DESC, player_name ASC';
    elseif (sort_col == 4) then
        order = sort_asc and 'updated_at ASC' or 'updated_at DESC';
    end

    local results = T{};
    for row in db.conn:nrows('SELECT * FROM players ORDER BY ' .. order) do
        results:append(row);
    end

    db.players_cache = results;
    db.players_sort = sort_key;
    db.players_dirty = false;

    return results;
end

function db.get_player_by_name(name)
    if (db.conn == nil or name == nil) then return nil; end

    local key = name:lower();
    if (db.player_lookup_cache[key] ~= nil) then
        return db.player_lookup_cache[key];
    end

    -- Negative cache: skip DB query for names we already know aren't tracked
    if (db.player_miss_cache[key]) then
        return nil;
    end

    local result = nil;
    local stmt = db.conn:prepare('SELECT * FROM players WHERE player_name = ? COLLATE NOCASE LIMIT 1');
    if (stmt == nil) then return nil; end
    pcall(function()
        stmt:bind_values(name);
        for row in stmt:nrows() do
            result = row;
        end
    end);
    stmt:finalize();

    if (result ~= nil) then
        db.player_lookup_cache[key] = result;
    else
        db.player_miss_cache[key] = true;
    end

    return result;
end

function db.get_player_by_id(id)
    if (db.conn == nil) then return nil; end

    -- Check cache first (called per-frame when detail panel is open)
    if (db.player_id_cache == nil) then db.player_id_cache = {}; end
    if (db.player_id_cache[id] ~= nil) then
        return db.player_id_cache[id];
    end

    local result = nil;
    local stmt = db.conn:prepare('SELECT * FROM players WHERE id = ?');
    if (stmt == nil) then return nil; end
    pcall(function()
        stmt:bind_values(id);
        for row in stmt:nrows() do
            result = row;
        end
    end);
    stmt:finalize();

    if (result ~= nil) then
        db.player_id_cache[id] = result;
    end
    return result;
end

function db.search_players(term)
    if (db.conn == nil or term == nil or term == '') then return T{}; end

    if (not db.search_dirty and db.search_cache ~= nil and db.search_cache_term == term) then
        return db.search_cache;
    end

    local results = T{};
    local like = '%' .. escape_like(term) .. '%';
    local stmt = db.conn:prepare([[
        SELECT * FROM players
        WHERE player_name LIKE ? ESCAPE '\' OR tags LIKE ? ESCAPE '\'
        ORDER BY player_name ASC
        LIMIT 100
    ]]);
    if (stmt == nil) then return results; end
    pcall(function()
        stmt:bind_values(like, like);
        for row in stmt:nrows() do
            results:append(row);
        end
    end);
    stmt:finalize();

    db.search_cache = results;
    db.search_cache_term = term;
    db.search_dirty = false;

    return results;
end

-------------------------------------------------------------------------------
-- Note CRUD (per player)
-------------------------------------------------------------------------------

function db.add_note(player_id, note, zone_name)
    if (db.conn == nil or player_id == nil) then return nil; end

    local now = os_time();
    local stmt = db.conn:prepare([[
        INSERT INTO notes (player_id, note, zone_name, created_at)
        VALUES (?, ?, ?, ?)
    ]]);
    if (stmt == nil) then return nil; end
    local ok = pcall(function()
        stmt:bind_values(player_id, note or '', zone_name or '', now);
        stmt:step();
    end);
    stmt:finalize();
    if (not ok) then return nil; end

    -- Update player's updated_at
    local stmt2 = db.conn:prepare('UPDATE players SET updated_at = ? WHERE id = ?');
    if (stmt2 ~= nil) then
        pcall(function()
            stmt2:bind_values(now, player_id);
            stmt2:step();
        end);
        stmt2:finalize();
    end

    db._note_count = db._note_count + 1;
    db.notes_dirty = true;
    db.notes_cache[player_id] = nil;
    db.note_counts_cache[player_id] = nil;
    db.players_dirty = true;
    db.search_dirty = true;
    db.tag_cache = nil;
    db.player_lookup_cache = {};

    return db.conn:last_insert_rowid();
end

function db.update_note(id, note)
    if (db.conn == nil) then return; end

    local stmt = db.conn:prepare('UPDATE notes SET note = ? WHERE id = ?');
    if (stmt == nil) then return; end
    local ok = pcall(function()
        stmt:bind_values(note or '', id);
        stmt:step();
    end);
    stmt:finalize();

    if (ok) then
        db.notes_dirty = true;
        db.notes_cache = {};
        db.search_dirty = true;
        db.player_lookup_cache = {};
    end
end

function db.delete_note(id)
    if (db.conn == nil) then return; end

    local stmt = db.conn:prepare('DELETE FROM notes WHERE id = ?');
    if (stmt == nil) then return; end
    local ok = pcall(function()
        stmt:bind_values(id);
        stmt:step();
    end);
    stmt:finalize();

    if (ok) then
        db._note_count = math.max(0, db._note_count - 1);
        db.notes_dirty = true;
        db.notes_cache = {};
        db.note_counts_cache = {};
        db.search_dirty = true;
        db.tag_cache = nil;
        db.player_lookup_cache = {};
    end
end

function db.get_notes(player_id)
    if (db.conn == nil) then return T{}; end

    if (not db.notes_dirty and db.notes_cache[player_id] ~= nil) then
        return db.notes_cache[player_id];
    end

    local results = T{};
    local stmt = db.conn:prepare('SELECT * FROM notes WHERE player_id = ? ORDER BY pinned DESC, created_at DESC');
    if (stmt == nil) then return results; end
    pcall(function()
        stmt:bind_values(player_id);
        for row in stmt:nrows() do
            results:append(row);
        end
    end);
    stmt:finalize();

    db.notes_cache[player_id] = results;
    db.notes_dirty = false;

    return results;
end

--- Get note count for a player (cached per-player, lightweight).
--- Cache is invalidated per-player by setting note_counts_cache[id] = nil on mutation.
function db.get_note_count(player_id)
    if (db.conn == nil) then return 0; end

    -- Check dedicated count cache first
    if (db.note_counts_cache[player_id] ~= nil) then
        return db.note_counts_cache[player_id];
    end

    -- Reuse full notes cache if available
    if (db.notes_cache[player_id] ~= nil) then
        local c = #db.notes_cache[player_id];
        db.note_counts_cache[player_id] = c;
        return c;
    end

    local count = 0;
    local stmt = db.conn:prepare('SELECT COUNT(*) as c FROM notes WHERE player_id = ?');
    if (stmt == nil) then return 0; end
    pcall(function()
        stmt:bind_values(player_id);
        for row in stmt:nrows() do
            count = row.c;
        end
    end);
    stmt:finalize();

    db.note_counts_cache[player_id] = count;
    return count;
end

--- Toggle pin on a note. Only one note per player can be pinned.
--- If the target note is already pinned, it gets unpinned.
--- Otherwise, unpin all notes for this player, then pin the target.
function db.pin_note(note_id, player_id)
    if (db.conn == nil) then return; end

    -- Check if this note is already pinned
    local is_pinned = 0;
    local stmt = db.conn:prepare('SELECT pinned FROM notes WHERE id = ?');
    if (stmt ~= nil) then
        pcall(function()
            stmt:bind_values(note_id);
            for row in stmt:nrows() do
                is_pinned = row.pinned;
            end
        end);
        stmt:finalize();
    end

    if (is_pinned == 1) then
        -- Already pinned: unpin it
        local ustmt = db.conn:prepare('UPDATE notes SET pinned = 0 WHERE id = ?');
        if (ustmt ~= nil) then
            pcall(function()
                ustmt:bind_values(note_id);
                ustmt:step();
            end);
            ustmt:finalize();
        end
    else
        -- Unpin all notes for this player, then pin the target
        local ustmt = db.conn:prepare('UPDATE notes SET pinned = 0 WHERE player_id = ?');
        if (ustmt ~= nil) then
            pcall(function()
                ustmt:bind_values(player_id);
                ustmt:step();
            end);
            ustmt:finalize();
        end
        local pstmt = db.conn:prepare('UPDATE notes SET pinned = 1 WHERE id = ?');
        if (pstmt ~= nil) then
            pcall(function()
                pstmt:bind_values(note_id);
                pstmt:step();
            end);
            pstmt:finalize();
        end
    end

    db.notes_dirty = true;
    db.notes_cache[player_id] = nil;
end

--- Get the pinned note for a player, or nil if none pinned.
function db.get_pinned_note(player_id)
    if (db.conn == nil) then return nil; end

    local result = nil;
    local stmt = db.conn:prepare('SELECT * FROM notes WHERE player_id = ? AND pinned = 1 LIMIT 1');
    if (stmt == nil) then return nil; end
    pcall(function()
        stmt:bind_values(player_id);
        for row in stmt:nrows() do
            result = row;
        end
    end);
    stmt:finalize();

    return result;
end

-------------------------------------------------------------------------------
-- Counts (for status bar)
-------------------------------------------------------------------------------

--- Get total player and note counts (O(1) via running counters).
function db.get_counts()
    if (db.conn == nil) then return 0, 0; end
    return db._player_count, db._note_count;
end

-------------------------------------------------------------------------------
-- Players by Tag
-------------------------------------------------------------------------------

function db.get_players_by_tag(tag)
    if (db.conn == nil or tag == nil or tag == '') then return T{}; end

    if (not db.players_dirty and db.tag_cache ~= nil and db.tag_cache_tag == tag) then
        return db.tag_cache;
    end

    -- Use boundary-aware patterns to avoid substring matches
    -- Matches: tag at start, end, middle of comma-separated list, or as sole value
    local results = T{};
    local stmt = db.conn:prepare([[
        SELECT * FROM players
        WHERE tags = ? OR tags LIKE ? OR tags LIKE ? OR tags LIKE ?
        ORDER BY player_name ASC
    ]]);
    if (stmt == nil) then return results; end
    pcall(function()
        stmt:bind_values(tag, tag .. ',%', '%,' .. tag, '%,' .. tag .. ',%');
        for row in stmt:nrows() do
            results:append(row);
        end
    end);
    stmt:finalize();

    db.tag_cache = results;
    db.tag_cache_tag = tag;

    return results;
end

-------------------------------------------------------------------------------
-- Export / Import
-------------------------------------------------------------------------------

--- Export all players and their notes for JSON serialization.
--- Returns a table with a players array (each entry has nested notes array).
function db.export_all()
    if (db.conn == nil) then return { players = {} }; end

    local players = {};
    pcall(function()
        for row in db.conn:nrows('SELECT * FROM players ORDER BY player_name ASC') do
            local notes = {};
            local stmt = db.conn:prepare('SELECT note, zone_name, created_at, pinned FROM notes WHERE player_id = ? ORDER BY created_at DESC');
            if (stmt ~= nil) then
                stmt:bind_values(row.id);
                for nrow in stmt:nrows() do
                    notes[#notes + 1] = {
                        note       = nrow.note,
                        zone_name  = nrow.zone_name,
                        created_at = nrow.created_at,
                        pinned     = nrow.pinned or 0,
                    };
                end
                stmt:finalize();
            end

            players[#players + 1] = {
                player_name = row.player_name,
                rating      = row.rating,
                tags        = row.tags,
                created_at  = row.created_at,
                updated_at  = row.updated_at,
                notes       = notes,
            };
        end
    end);

    return { players = players };
end

--- Import players and notes, merging with existing data.
--- Returns a summary table: { players_added, players_updated, notes_added, notes_skipped }.
function db.import_data(players_data)
    if (db.conn == nil or players_data == nil) then
        return { players_added = 0, players_updated = 0, notes_added = 0, notes_skipped = 0 };
    end

    local added, updated, notes_added, notes_skipped = 0, 0, 0, 0;

    -- Wrap entire import in a transaction for performance (single fsync)
    db.conn:exec('BEGIN TRANSACTION;');

    local ok, err = pcall(function()
        for _, entry in ipairs(players_data) do
            if (entry.player_name ~= nil and entry.player_name ~= '') then
                local existing = db.get_player_by_name(entry.player_name);

                if (existing == nil) then
                    -- New player: insert with imported timestamps
                    local tag_str = entry.tags or '';
                    local rating = entry.rating or 0;
                    local created = entry.created_at or os_time();
                    local updated_at = entry.updated_at or os_time();

                    local stmt = db.conn:prepare([[
                        INSERT INTO players (player_name, rating, tags, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?)
                    ]]);
                    if (stmt ~= nil) then
                        stmt:bind_values(entry.player_name, rating, tag_str, created, updated_at);
                        stmt:step();
                        stmt:finalize();

                        local player_id = db.conn:last_insert_rowid();
                        added = added + 1;

                        -- Insert all notes
                        if (entry.notes ~= nil) then
                            for _, n in ipairs(entry.notes) do
                                local nstmt = db.conn:prepare([[
                                    INSERT INTO notes (player_id, note, zone_name, created_at, pinned)
                                    VALUES (?, ?, ?, ?, ?)
                                ]]);
                                if (nstmt ~= nil) then
                                    nstmt:bind_values(player_id, n.note or '', n.zone_name or '', n.created_at or os_time(), n.pinned or 0);
                                    nstmt:step();
                                    nstmt:finalize();
                                    notes_added = notes_added + 1;
                                end
                            end
                        end
                    end
                else
                    -- Existing player: merge
                    local new_rating = math.max(existing.rating or 0, entry.rating or 0);

                    -- Tags: union merge
                    local existing_tags = {};
                    if (existing.tags ~= nil and existing.tags ~= '') then
                        for tag in existing.tags:gmatch('[^,]+') do
                            existing_tags[tag:match('^%s*(.-)%s*$')] = true;
                        end
                    end
                    if (entry.tags ~= nil and entry.tags ~= '') then
                        for tag in entry.tags:gmatch('[^,]+') do
                            existing_tags[tag:match('^%s*(.-)%s*$')] = true;
                        end
                    end
                    local merged_parts = {};
                    for tag in pairs(existing_tags) do
                        if (tag ~= '') then
                            merged_parts[#merged_parts + 1] = tag;
                        end
                    end
                    table.sort(merged_parts);
                    local merged_tags = table.concat(merged_parts, ',');

                    -- Timestamps: earlier created_at, later updated_at
                    local new_created = math.min(existing.created_at or os_time(), entry.created_at or os_time());
                    local new_updated = math.max(existing.updated_at or 0, entry.updated_at or 0);

                    local ustmt = db.conn:prepare('UPDATE players SET rating = ?, tags = ?, created_at = ?, updated_at = ? WHERE id = ?');
                    if (ustmt ~= nil) then
                        ustmt:bind_values(new_rating, merged_tags, new_created, new_updated, existing.id);
                        ustmt:step();
                        ustmt:finalize();
                        updated = updated + 1;
                    end

                    -- Merge notes: skip duplicates matched by note text + created_at
                    if (entry.notes ~= nil) then
                        for _, n in ipairs(entry.notes) do
                            local count = 0;
                            local cstmt = db.conn:prepare('SELECT COUNT(*) as c FROM notes WHERE player_id = ? AND note = ? AND created_at = ?');
                            if (cstmt ~= nil) then
                                cstmt:bind_values(existing.id, n.note or '', n.created_at or 0);
                                for crow in cstmt:nrows() do
                                    count = crow.c;
                                end
                                cstmt:finalize();
                            end

                            if (count == 0) then
                                local nstmt = db.conn:prepare([[
                                    INSERT INTO notes (player_id, note, zone_name, created_at, pinned)
                                    VALUES (?, ?, ?, ?, ?)
                                ]]);
                                if (nstmt ~= nil) then
                                    nstmt:bind_values(existing.id, n.note or '', n.zone_name or '', n.created_at or os_time(), n.pinned or 0);
                                    nstmt:step();
                                    nstmt:finalize();
                                    notes_added = notes_added + 1;
                                end
                            else
                                notes_skipped = notes_skipped + 1;
                            end
                        end
                    end
                end
            end
        end
    end);

    if (ok) then
        db.conn:exec('COMMIT;');
        -- Update running counters (only on successful commit)
        db._player_count = db._player_count + added;
        db._note_count = db._note_count + notes_added;
    else
        db.conn:exec('ROLLBACK;');
    end

    invalidate_all();

    return {
        players_added   = added,
        players_updated = updated,
        notes_added     = notes_added,
        notes_skipped   = notes_skipped,
    };
end

-------------------------------------------------------------------------------
-- Cleanup
-------------------------------------------------------------------------------

function db.close()
    if (db.conn ~= nil) then
        db.conn:close();
        db.conn = nil;
    end
end

return db;
