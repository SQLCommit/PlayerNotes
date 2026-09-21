-- Versioned data migrations and maintenance. Additive schema changes belong in db_schema.
-- Gate migrations on PRAGMA user_version; maintenance runs on every open.

local backfill = {};

backfill.VERSION = 1;   -- highest generation defined below

-- Check exec result codes; some bindings return nil on success.
local SQLITE_OK = 0;
do
    local ok, lib = pcall(require, 'lsqlite3');
    if (ok and lib ~= nil) then SQLITE_OK = lib.OK or SQLITE_OK; end
end

local function exec_ok(conn, sql)
    local rc = conn:exec(sql);
    return (rc == nil) or (rc == SQLITE_OK);
end

local function user_version(conn)
    local v = 0;
    for row in conn:nrows('PRAGMA user_version') do v = row.user_version or 0; end
    return v;
end

-- Stamp only from version-1 after every statement succeeds, so later migrations cannot skip a failed one.
local function stamp(conn, ok, version)
    if (not ok) then return false; end
    if (user_version(conn) ~= version - 1) then return false; end
    return exec_ok(conn, ('PRAGMA user_version = %d;'):format(version));
end

-- Best-effort backup before rebuilding; backup failure does not block migration.
local function backup_file(path, suffix)
    if (path == nil or path == '') then return; end
    local src = io.open(path, 'rb');
    if (src == nil) then return; end
    local blob = src:read('*a');
    src:close();
    local bak = io.open(path .. suffix, 'wb');
    if (bak == nil) then return; end
    bak:write(blob);
    bak:close();
end

-- Generation 1: replace name-only uniqueness with (name, server_id), preserving player IDs.
-- Disable foreign keys before rebuilding: DROP TABLE would otherwise cascade-delete notes.
-- Roll back if any note becomes orphaned.
local function generation_1(conn, path)
    local needs_rebuild = true;
    for row in conn:nrows('PRAGMA table_info(players);') do
        if (row.name == 'server_id') then needs_rebuild = false; end
    end
    if (not needs_rebuild) then return true; end

    -- Checkpoint WAL before copying the backup so it includes the latest notes.
    exec_ok(conn, 'PRAGMA wal_checkpoint(TRUNCATE);');
    backup_file(path, '.v1-backup');

    exec_ok(conn, 'PRAGMA foreign_keys=OFF;');
    local ok = pcall(function()
        assert(exec_ok(conn, 'BEGIN IMMEDIATE;'), 'begin');
        -- Drop a leftover staging table inside the transaction so interrupted rebuilds can retry.
        assert(exec_ok(conn, 'DROP TABLE IF EXISTS players_v2;'), 'clear stale');
        assert(exec_ok(conn, [[
            CREATE TABLE players_v2 (
                id INTEGER PRIMARY KEY,
                player_name TEXT NOT NULL COLLATE NOCASE,
                server_id INTEGER NOT NULL DEFAULT 0,
                rating INTEGER NOT NULL DEFAULT 0,
                tags TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                UNIQUE(player_name, server_id)
            );
        ]]), 'create');
        assert(exec_ok(conn, [[
            INSERT INTO players_v2 (id, player_name, server_id, rating, tags, created_at, updated_at)
            SELECT id, player_name, 0, rating, tags, created_at, updated_at FROM players;
        ]]), 'copy');
        assert(exec_ok(conn, 'DROP TABLE players;'), 'drop');
        assert(exec_ok(conn, 'ALTER TABLE players_v2 RENAME TO players;'), 'rename');

        local orphans = 0;
        for row in conn:nrows('SELECT COUNT(*) AS c FROM notes WHERE player_id NOT IN (SELECT id FROM players);') do
            orphans = row.c or 0;
        end
        assert(orphans == 0, 'orphaned notes: ' .. tostring(orphans));

        assert(exec_ok(conn, 'COMMIT;'), 'commit');
    end);
    if (not ok) then pcall(function() conn:exec('ROLLBACK;'); end); end
    exec_ok(conn, 'PRAGMA foreign_keys=ON;');

    if (not ok) then return false; end
    -- Verify the final schema as well as SQLite result codes.
    for row in conn:nrows('PRAGMA table_info(players);') do
        if (row.name == 'server_id') then return true; end
    end
    return false;
end


-- Apply pending generations in order; failure leaves the DB closed for retry on next load.
function backfill.apply(conn, path)
    if (conn == nil) then return false; end

    if (user_version(conn) < 1) then
        if (not stamp(conn, generation_1(conn, path), 1)) then return false; end
    end

    return true;
end

-- On every open, restore one pin per player without performing migrations.
function backfill.maintenance(conn)
    if (conn == nil) then return true; end
    return exec_ok(conn, [[
        UPDATE notes SET pinned = 0
        WHERE pinned = 1 AND id NOT IN (
            SELECT MIN(id) FROM notes WHERE pinned = 1 GROUP BY player_id
        );
    ]]);
end

return backfill;
