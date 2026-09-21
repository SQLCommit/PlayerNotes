-- Additive, idempotent schema changes. Existing-row rewrites and table rebuilds belong in db_backfill.

local schema = {};

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
schema.exec_ok = exec_ok;

function schema.has_column(conn, tbl, col)
    local found = false;
    for row in conn:nrows(('PRAGMA table_info(%s);'):format(tbl)) do
        if (row.name == col) then found = true; end
    end
    return found;
end

-- Add missing columns without rewriting existing rows.
function schema.add_column(conn, tbl, col, decl)
    if (schema.has_column(conn, tbl, col)) then return true; end
    return exec_ok(conn, ('ALTER TABLE %s ADD COLUMN %s %s;'):format(tbl, col, decl));
end

-- Key players by (player_name, server_id); zero is unverified.
-- Legacy name-only uniqueness is removed by the generation-1 rebuild.
function schema.create_tables(conn)
    local ok = exec_ok(conn, [[
        CREATE TABLE IF NOT EXISTS players (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            player_name TEXT NOT NULL COLLATE NOCASE,
            server_id INTEGER NOT NULL DEFAULT 0,
            rating INTEGER NOT NULL DEFAULT 0,
            tags TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            UNIQUE(player_name, server_id)
        );

        CREATE TABLE IF NOT EXISTS notes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            player_id INTEGER NOT NULL,
            note TEXT NOT NULL,
            zone_name TEXT DEFAULT '',
            created_at INTEGER NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY (player_id) REFERENCES players(id) ON DELETE CASCADE
        );
    ]]);
    return ok;
end

-- Columns added after the initial schema.
function schema.migrate_columns(conn)
    local ok = true;
    ok = schema.add_column(conn, 'notes', 'pinned', 'INTEGER NOT NULL DEFAULT 0') and ok;
    return ok;
end

-- Create indexes after migrations that may rebuild their columns.
function schema.migrate_indexes(conn)
    local ok = true;
    -- Redundant once the UNIQUE(player_name, server_id) index exists.
    ok = exec_ok(conn, 'DROP INDEX IF EXISTS idx_players_name;') and ok;
    -- Remove the unused legacy schema.
    ok = exec_ok(conn, 'DROP TABLE IF EXISTS encounters;') and ok;
    ok = exec_ok(conn, 'CREATE INDEX IF NOT EXISTS idx_players_rating ON players(rating);') and ok;
    ok = exec_ok(conn, 'CREATE INDEX IF NOT EXISTS idx_players_updated ON players(updated_at);') and ok;
    ok = exec_ok(conn, 'CREATE INDEX IF NOT EXISTS idx_notes_player ON notes(player_id);') and ok;
    ok = exec_ok(conn, 'CREATE INDEX IF NOT EXISTS idx_notes_created ON notes(created_at);') and ok;
    ok = exec_ok(conn, 'CREATE INDEX IF NOT EXISTS idx_notes_pinned ON notes(player_id, pinned);') and ok;
    return ok;
end

return schema;
