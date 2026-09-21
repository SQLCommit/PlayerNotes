-- PlayerNotes per-character SQLite persistence and caches.
-- Author: SQLCommit

require 'common';

local chat    = require 'chat';
local sqlite3 = require 'sqlite3';
local os_time = os.time;

local schema   = require 'db_schema';
local backfill = require 'db_backfill';

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
db.tag_dirty = true;

-- In-memory caches
db.players_cache = nil;
db.players_sort = nil;
db.notes_cache = {};
db.search_cache = nil;
db.search_cache_term = '';
db.player_lookup_cache = {};
db.player_miss_cache = {};  -- negative cache: names confirmed not in DB
db.player_id_cache = {};
db.note_counts_cache = {};
db.tag_cache = nil;
db.tag_cache_tag = '';

-- Initialization

-- Failed initialization stays closed until reload or character switch. Do not run detection
-- without a connection, or promise an automatic retry.
function db.init(base_path, char_folder)
    if (db.conn ~= nil) then return; end  -- already initialized

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
    if (db.conn == nil) then
        print(chat.header('playernotes'):append(chat.error(
            'Database failed to open (' .. tostring(db.path) .. '). Notes disabled this session.')));
        return;
    end

    -- WAL mode for concurrent read safety, busy_timeout for rare write contention
    db.conn:exec('PRAGMA journal_mode=WAL;');
    db.conn:exec('PRAGMA foreign_keys=ON;');
    -- Writes run on the render thread; keep lock waits short and report contention.
    db.conn:exec('PRAGMA busy_timeout=250;');
    -- Apply additive schema, then data migrations, then indexes and counters.
    -- Existing-row rewrites belong in db_backfill; counters must reflect the final schema.
    if (not schema.create_tables(db.conn)) then
        print(chat.header('playernotes'):append(chat.error(
            'Database tables could not be created (' .. tostring(db.path) .. '). Notes disabled this session.')));
        pcall(function() db.conn:close(); end);
        db.conn = nil;
        return;
    end
    schema.migrate_columns(db.conn);

    -- A failed migration leaves the database closed until the next load retries it.
    if (not backfill.apply(db.conn, db.path)) then
        print(chat.header('playernotes'):append(chat.error(
            'Database upgrade did not complete; your notes are untouched. Reload the addon to try again -- /addon reload playernotes.')));
        pcall(function() db.conn:close(); end);
        db.conn = nil;
        return;
    end

    schema.migrate_indexes(db.conn);
    backfill.maintenance(db.conn);

    -- Initialize running counters from existing data
    for row in db.conn:nrows('SELECT COUNT(*) as c FROM players') do
        db._player_count = row.c;
    end
    for row in db.conn:nrows('SELECT COUNT(*) as c FROM notes') do
        db._note_count = row.c;
    end
end

-- Helpers

--- Escape SQL LIKE wildcards (% and _) in search terms using backslash.
local function escape_like(term)
    return term:gsub('[%%_\\]', '\\%1');
end

-- Preserve negative lookups only for writes that cannot add or remove player rows.
local function invalidate_all(keep_miss)
    db.players_dirty = true;
    db.notes_dirty = true;
    db.search_dirty = true;
    db.tag_dirty = true;
    db.player_lookup_cache = {};
    if (not keep_miss) then db.player_miss_cache = {}; end
    db.player_id_cache = {};
    db.note_counts_cache = {};
    db.notes_cache = {};        -- else get_notes serves pre-mutation notes: one lookup clears the
                                -- global notes_dirty flag and every other player stays stale
    db.tag_cache = nil;
end

-- Player CRUD

-- Accept tag tables from the UI or serialized tags from storage/import.
local function normalize_tags(tags)
    if (tags ~= nil and type(tags) == 'table') then return table.concat(tags, ','); end
    if (tags ~= nil and type(tags) == 'string') then return tags; end
    return '';
end

-- Identity is (name, server_id); zero means the ID is not yet known.
function db.add_player(name, rating, tags, server_id)
    if (db.conn == nil or name == nil or name == '') then return nil; end

    local now = os_time();
    local tag_str = normalize_tags(tags);
    local sid = tonumber(server_id) or 0;

    local stmt = db.conn:prepare([[
        INSERT OR IGNORE INTO players (player_name, server_id, rating, tags, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
    ]]);
    if (stmt == nil) then return nil; end
    local ok, err = pcall(function()
        stmt:bind_values(name, sid, rating or 0, tag_str, now, now);
        stmt:step();
    end);
    stmt:finalize();
    if (not ok) then return nil; end

    -- If INSERT OR IGNORE skipped (player exists), changes() returns 0
    if (db.conn:changes() == 0) then
        local p = db.get_player_by_name(name, sid);
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

    local tag_str = normalize_tags(tags);

    local now = os_time();
    local stmt = db.conn:prepare('UPDATE players SET rating = ?, tags = ?, updated_at = ? WHERE id = ?');
    if (stmt == nil) then return; end
    local rc;
    local ok = pcall(function()
        stmt:bind_values(rating or 0, tag_str, now, id);
        rc = stmt:step();
    end);
    stmt:finalize();

    -- Check SQLite's result code: rejected writes do not throw.
    if (not ok or rc ~= sqlite3.DONE) then return false; end

    -- An update cannot invalidate cached absent names.
    invalidate_all(true);
    return true;
end

function db.delete_player(id)
    if (db.conn == nil) then return; end

    -- Count notes for this player before deletion (for running counter)
    local note_count = db.get_note_count(id);

    -- Foreign keys with ON DELETE CASCADE handle notes
    local stmt = db.conn:prepare('DELETE FROM players WHERE id = ?');
    if (stmt == nil) then return; end
    -- Only adjust counters after a confirmed delete; pcall alone does not check SQLite's result code.
    local rc;
    local ok = pcall(function()
        stmt:bind_values(id);
        rc = stmt:step();
    end);
    stmt:finalize();

    if (not (ok and rc == sqlite3.DONE and db.conn:changes() > 0)) then return false; end

    db._player_count = math.max(0, db._player_count - 1);
    db._note_count = math.max(0, db._note_count - note_count);
    invalidate_all();
    return true;
end

-- Player Queries (cached)

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

-- Resolve exact (name, id) first. Return unkeyed legacy rows as unverified; never bind on read.
-- Reject conflicting IDs and ambiguous name-only matches.
function db.get_player_by_name(name, server_id)
    if (db.conn == nil or name == nil) then return nil; end

    local sid = tonumber(server_id) or 0;
    local key = name:lower() .. '#' .. tostring(sid);
    if (db.player_lookup_cache[key] ~= nil) then
        return db.player_lookup_cache[key];
    end
    if (db.player_miss_cache[key]) then
        return nil;
    end

    local rows = {};
    local stmt = db.conn:prepare('SELECT * FROM players WHERE player_name = ? COLLATE NOCASE');
    if (stmt == nil) then return nil; end
    local queried = pcall(function()
        stmt:bind_values(name);
        for row in stmt:nrows() do
            rows[#rows + 1] = row;
        end
    end);
    stmt:finalize();

    -- Cache misses only after a successful query; read errors must remain retryable.
    if (not queried) then return nil; end

    local result, unkeyed = nil, nil;
    for _, row in ipairs(rows) do
        local rsid = tonumber(row.server_id) or 0;
        if (sid > 0 and rsid == sid) then
            result = row;
            break;
        elseif (rsid == 0) then
            unkeyed = unkeyed or row;
        end
    end

    if (result == nil and unkeyed ~= nil) then
        -- Return legacy notes as identity_unverified; bind only on an explicit write with the character
        -- present.
        result = unkeyed;
        -- Any non-exact ID match is unverified, including two unknown IDs.
        result.identity_unverified = true;
    elseif (result == nil and sid == 0) then
        if (#rows == 1) then
            result = rows[1];
            -- A missing encounter ID cannot confirm an identified row.
            if ((tonumber(result.server_id) or 0) ~= 0) then result.identity_unverified = true; end
        end
    end

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

-- Note CRUD (per player)

-- Bind an unkeyed row on an explicit write with the character present.
-- Skip absent IDs, already-bound rows and identities owned by another row.
function db.bind_identity(player_id, server_id)
    if (db.conn == nil or player_id == nil) then return false; end
    local sid = tonumber(server_id) or 0;
    if (sid == 0) then return false; end

    local stmt = db.conn:prepare([[
        UPDATE players SET server_id = ? WHERE id = ? AND server_id = 0
          AND NOT EXISTS (SELECT 1 FROM players p2
                          WHERE p2.player_name = players.player_name COLLATE NOCASE
                            AND p2.server_id = ?)
    ]]);
    if (stmt == nil) then return false; end
    local rc;
    local ok = pcall(function()
        stmt:bind_values(sid, player_id, sid);
        rc = stmt:step();
    end);
    stmt:finalize();
    if (not (ok and rc == sqlite3.DONE and db.conn:changes() > 0)) then return false; end

    -- Clear all lookup aliases and misses after binding; several name#id keys may reference an unkeyed row.
    invalidate_all();
    return true;
end

function db.add_note(player_id, note, zone_name)
    if (db.conn == nil or player_id == nil) then return nil; end

    local now = os_time();
    local stmt = db.conn:prepare([[
        INSERT INTO notes (player_id, note, zone_name, created_at)
        VALUES (?, ?, ?, ?)
    ]]);
    if (stmt == nil) then return nil; end
    local rc;
    local ok = pcall(function()
        stmt:bind_values(player_id, note or '', zone_name or '', now);
        rc = stmt:step();
    end);
    stmt:finalize();
    -- Check insert success before reading last_insert_rowid(), which otherwise retains an older row ID.
    if (not ok or rc ~= sqlite3.DONE) then return nil; end

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
    db.tag_dirty = true;
    db.search_dirty = true;
    db.player_lookup_cache = {};
    db.player_id_cache = {};   -- add_note bumps the player's updated_at; drop the cached row so the detail panel refreshes

    return db.conn:last_insert_rowid();
end

-- Return success only after SQLite confirms the update.
function db.update_note(id, note)
    if (db.conn == nil) then return false; end

    local stmt = db.conn:prepare('UPDATE notes SET note = ? WHERE id = ?');
    if (stmt == nil) then return false; end
    local rc;
    local ok = pcall(function()
        stmt:bind_values(note or '', id);
        rc = stmt:step();
    end);
    stmt:finalize();
    if (not (ok and rc == sqlite3.DONE and db.conn:changes() > 0)) then return false; end

    db.notes_dirty = true;
    db.notes_cache = {};
    db.search_dirty = true;
    db.player_lookup_cache = {};
    db.player_id_cache = {};
    return true;
end

function db.delete_note(id)
    if (db.conn == nil) then return; end

    local stmt = db.conn:prepare('DELETE FROM notes WHERE id = ?');
    if (stmt == nil) then return; end
    -- Adjust note counts only after a confirmed delete.
    local rc;
    local ok = pcall(function()
        stmt:bind_values(id);
        rc = stmt:step();
    end);
    stmt:finalize();

    if (not (ok and rc == sqlite3.DONE and db.conn:changes() > 0)) then return false; end

    db._note_count = math.max(0, db._note_count - 1);
    db.notes_dirty = true;
    db.notes_cache = {};
    db.note_counts_cache = {};
    db.search_dirty = true;
    db.tag_cache = nil;
    db.player_lookup_cache = {};
    db.player_id_cache = {};
    return true;
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

-- Note counts are cached and invalidated per player.
function db.get_note_count(player_id)
    if (db.conn == nil) then return 0; end

    if (db.note_counts_cache[player_id] ~= nil) then
        return db.note_counts_cache[player_id];
    end

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

-- Toggle the player's single pinned note; return whether the change succeeded.
function db.pin_note(note_id, player_id)
    if (db.conn == nil) then return false; end

    -- Do not treat a failed pin-state query as unpinned.
    local is_pinned = nil;
    local stmt = db.conn:prepare('SELECT pinned FROM notes WHERE id = ?');
    if (stmt == nil) then return false; end
    local read_ok = pcall(function()
        stmt:bind_values(note_id);
        for row in stmt:nrows() do
            is_pinned = row.pinned;
        end
    end);
    stmt:finalize();
    if (not read_ok or is_pinned == nil) then return false; end

    local function run(sql, arg)
        local st = db.conn:prepare(sql);
        if (st == nil) then return false; end
        local rc;
        local okr = pcall(function()
            st:bind_values(arg);
            rc = st:step();
        end);
        st:finalize();
        return okr and rc == sqlite3.DONE;
    end

    local wrote;
    if (is_pinned == 1) then
        wrote = run('UPDATE notes SET pinned = 0 WHERE id = ?', note_id);
    else
        -- Unpin before pinning. If the second write fails, zero pins is valid; two pins is not.
        wrote = run('UPDATE notes SET pinned = 0 WHERE player_id = ?', player_id)
            and run('UPDATE notes SET pinned = 1 WHERE id = ?', note_id);
    end
    if (not wrote) then return false; end

    db.notes_dirty = true;
    db.notes_cache[player_id] = nil;
    return true;
end

-- Counts (for status bar)

function db.get_counts()
    if (db.conn == nil) then return 0, 0; end
    return db._player_count, db._note_count;
end

-- Players by Tag

function db.get_players_by_tag(tag)
    if (db.conn == nil or tag == nil or tag == '') then return T{}; end

    -- Use a separate dirty flag: tag-filtered views never call get_players to clear players_dirty.
    if (not db.tag_dirty and db.tag_cache ~= nil and db.tag_cache_tag == tag) then
        return db.tag_cache;
    end

    -- Match whole comma-delimited tags, not substrings.
    local results = T{};
    local esc = escape_like(tag);
    local stmt = db.conn:prepare([[
        SELECT * FROM players
        WHERE tags = ? OR tags LIKE ? ESCAPE '\' OR tags LIKE ? ESCAPE '\' OR tags LIKE ? ESCAPE '\'
        ORDER BY player_name ASC
    ]]);
    if (stmt == nil) then return results; end
    pcall(function()
        stmt:bind_values(tag, esc .. ',%', '%,' .. esc, '%,' .. esc .. ',%');
        for row in stmt:nrows() do
            results:append(row);
        end
    end);
    stmt:finalize();

    db.tag_cache = results;
    db.tag_cache_tag = tag;
    db.tag_dirty = false;

    return results;
end

-- Export / Import

-- Export players with nested note arrays.
function db.export_all()
    if (db.conn == nil) then return { ok = false, players = {} }; end

    local players = {};
    local read_ok = pcall(function()
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
                -- Preserve character identity across imports.
                server_id   = row.server_id or 0,
                rating      = row.rating,
                tags        = row.tags,
                created_at  = row.created_at,
                updated_at  = row.updated_at,
                notes       = notes,
            };
        end
    end);

    -- Reject incomplete reads so callers cannot export truncated data as success.
    return { ok = read_ok, players = players };
end

-- Merge exported players and notes; skip self_name. Return added/updated/skipped counts.
function db.import_data(players_data, self_name)
    if (db.conn == nil or players_data == nil) then
        return { ok = false, error = 'database unavailable',
                 players_added = 0, players_updated = 0, notes_added = 0, notes_skipped = 0,
                 self_skipped = 0 };
    end

    local added, updated, notes_added, notes_skipped, self_skipped = 0, 0, 0, 0, 0;
    local self_key = (self_name ~= nil and self_name ~= '') and self_name:lower() or nil;

    -- Coerce imported values before binding to avoid leaking a prepared statement on a bind error.
    -- Return true only for a successful insert.
    local function insert_note(player_id, n)
        local nstmt = db.conn:prepare([[
            INSERT INTO notes (player_id, note, zone_name, created_at, pinned)
            VALUES (?, ?, ?, ?, ?)
        ]]);
        if (nstmt == nil) then return false; end
        nstmt:bind_values(player_id, tostring(n.note or ''), tostring(n.zone_name or ''),
                          tonumber(n.created_at) or os_time(), tonumber(n.pinned) or 0);
        local rc = nstmt:step();
        nstmt:finalize();
        return rc == sqlite3.DONE;
    end

    -- Abort the whole import on any statement failure.
    local function must(done, what)
        if (not done) then error('import: ' .. what .. ' was rejected by the database', 0); end
    end

    -- Wrap entire import in a transaction for performance (single fsync)
    db.conn:exec('BEGIN TRANSACTION;');

    local ok, err = pcall(function()
        for _, entry in ipairs(players_data) do
            if (self_key ~= nil and entry.player_name ~= nil
                and tostring(entry.player_name):lower() == self_key) then
                -- Your own character: never import a profile about yourself.
                self_skipped = self_skipped + 1;
            elseif (entry.player_name ~= nil and entry.player_name ~= '') then
                local entry_sid = tonumber(entry.server_id) or 0;
                -- Match import identities exactly: identified entries match their ID; unkeyed entries match
                -- only unkeyed rows.
                local existing = nil;
                do
                    local rows = {};
                    local rstmt = db.conn:prepare('SELECT * FROM players WHERE player_name = ? COLLATE NOCASE');
                    must(rstmt ~= nil, 'preparing the player lookup');
                    local rok = pcall(function()
                        rstmt:bind_values(tostring(entry.player_name));
                        for row in rstmt:nrows() do rows[#rows + 1] = row; end
                    end);
                    rstmt:finalize();
                    must(rok, 'looking up ' .. tostring(entry.player_name));

                    -- Keep identified and unkeyed rows separate so import order cannot change attribution.
                    for _, row in ipairs(rows) do
                        local rsid = tonumber(row.server_id) or 0;
                        if (rsid == entry_sid) then existing = row; break; end
                    end
                end

                -- Imports must not bind legacy rows to an ID. Only a confirmed encounter/write may bind
                -- them.
                if (existing == nil) then
                    -- New player: insert with imported timestamps
                    local stmt = db.conn:prepare([[
                        INSERT INTO players (player_name, server_id, rating, tags, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                    ]]);
                    must(stmt ~= nil, 'preparing the player insert');
                    if (stmt ~= nil) then
                        stmt:bind_values(tostring(entry.player_name), entry_sid, tonumber(entry.rating) or 0,
                                         tostring(entry.tags or ''), tonumber(entry.created_at) or os_time(),
                                         tonumber(entry.updated_at) or os_time());
                        local rc = stmt:step();
                        stmt:finalize();
                        must(rc == sqlite3.DONE, 'inserting player ' .. tostring(entry.player_name));

                        -- Confirm insertion before using the row ID; a failed insert leaves the previous ID
                        -- intact.
                        if (rc == sqlite3.DONE) then
                            local player_id = db.conn:last_insert_rowid();
                            added = added + 1;

                            -- Invalidate cached misses so duplicate import entries resolve to the newly
                            -- inserted row.
                            db.player_miss_cache[entry.player_name:lower() .. '#' .. tostring(entry_sid)] = nil;

                            if (entry.notes ~= nil) then
                                for _, n in ipairs(entry.notes) do
                                    must(insert_note(player_id, n), 'inserting a note for ' .. tostring(entry.player_name));
                                    notes_added = notes_added + 1;
                                end
                            end
                        end
                    end
                else
                    -- Existing player: merge
                    local new_rating = math.max(existing.rating or 0, tonumber(entry.rating) or 0);

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
                    local new_created = math.min(existing.created_at or os_time(), tonumber(entry.created_at) or os_time());
                    local new_updated = math.max(existing.updated_at or 0, tonumber(entry.updated_at) or 0);

                    local ustmt = db.conn:prepare('UPDATE players SET rating = ?, tags = ?, created_at = ?, updated_at = ? WHERE id = ?');
                    must(ustmt ~= nil, 'preparing the player update');
                    if (ustmt ~= nil) then
                        ustmt:bind_values(new_rating, merged_tags, new_created, new_updated, existing.id);
                        local urc = ustmt:step();
                        ustmt:finalize();
                        must(urc == sqlite3.DONE, 'updating player ' .. tostring(entry.player_name));
                        updated = updated + 1;
                        -- Invalidate the merged row before the next duplicate entry reads it.
                        db.player_lookup_cache[entry.player_name:lower() .. '#' .. tostring(entry_sid)] = nil;
                    end

                    -- Merge notes: skip duplicates matched by note text + created_at
                    if (entry.notes ~= nil) then
                        for _, n in ipairs(entry.notes) do
                            local count = 0;
                            -- Abort if the duplicate probe fails; assuming zero would insert the note
                            -- again.
                            local cstmt = db.conn:prepare('SELECT COUNT(*) as c FROM notes WHERE player_id = ? AND note = ? AND created_at = ?');
                            must(cstmt ~= nil, 'preparing the duplicate-note probe');
                            local counted = pcall(function()
                                cstmt:bind_values(existing.id, tostring(n.note or ''), tonumber(n.created_at) or 0);
                                for crow in cstmt:nrows() do
                                    count = crow.c;
                                end
                            end);
                            cstmt:finalize();
                            must(counted, 'checking for a duplicate note');

                            if (count == 0) then
                                must(insert_note(existing.id, n), 'inserting a note for ' .. tostring(entry.player_name));
                                notes_added = notes_added + 1;
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
        -- Keep the lowest-ID pin per player so an existing pin survives import.
        -- Abort if this invariant cannot be restored.
        local pinned_ok = pcall(function()
            assert(db.conn:exec([[
                UPDATE notes SET pinned = 0
                WHERE pinned = 1 AND id NOT IN (
                    SELECT MIN(id) FROM notes WHERE pinned = 1 GROUP BY player_id
                );
            ]]) == sqlite3.OK, 'pin cleanup');
        end);
        if (not pinned_ok) then
            pcall(function() db.conn:exec('ROLLBACK;'); end);
            invalidate_all();
            return { ok = false, error = 'restoring the one-pinned-note rule failed; nothing was saved',
                     players_added = 0, players_updated = 0, notes_added = 0, notes_skipped = 0,
                     self_skipped = self_skipped };
        end

        -- Some bindings return nil on exec success; reject only explicit non-OK results.
        local crc = db.conn:exec('COMMIT;');
        if (crc ~= nil and crc ~= sqlite3.OK) then
            pcall(function() db.conn:exec('ROLLBACK;'); end);
            ok = false;
            err = 'commit failed (sqlite code ' .. tostring(crc) .. ')';
        else
            db._player_count = db._player_count + added;
            db._note_count = db._note_count + notes_added;
        end
    else
        db.conn:exec('ROLLBACK;');
    end

    invalidate_all();

    -- A rolled-back import must report zero written rows.
    if (not ok) then
        return {
            ok = false, error = tostring(err or 'unknown error'),
            players_added = 0, players_updated = 0, notes_added = 0, notes_skipped = 0,
            self_skipped = self_skipped,
        };
    end

    return {
        ok              = true,
        players_added   = added,
        players_updated = updated,
        notes_added     = notes_added,
        notes_skipped   = notes_skipped,
        self_skipped    = self_skipped,
    };
end

-- Cleanup

function db.close()
    if (db.conn ~= nil) then
        db.conn:close();
        db.conn = nil;
    end

    -- Reset all caches, counters and identity fields before rebinding to another character.
    invalidate_all();
    db.players_cache     = nil;
    db.players_sort      = nil;
    db.search_cache      = nil;
    db.search_cache_term = '';
    db.tag_cache_tag     = '';
    db._player_count     = 0;
    db._note_count       = 0;
    db.char_name         = nil;
    db.path              = nil;
end

return db;
