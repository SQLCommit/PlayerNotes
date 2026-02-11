# PlayerNotes v1.0.0 - Player Tracking for Ashita v4

Remember every player you meet in FFXI. Track players with star ratings, color-coded tags, and detailed notes. Get toast alerts when tracked players appear nearby or join your party.

## Features

- **Player Profiles** - Star ratings (1-5), color-coded tags, and multiple individual notes per player
- **Sortable Table** - Click column headers to sort by name, rating, or last seen (ascending/descending)
- **Tag System** - 8 predefined tags with dropdown filter: Healer, Tank, DPS, Support, Crafter, Friend, Avoid, Mentor
- **6 Alert Types** - Distinct toast alerts for party joins and nearby detection, routed by tag (Friend, Avoid, or generic)
- **Avoid Warnings** - Avoid-tagged players get highlighted rows and red warning toasts when they join your party or are nearby
- **Town Zone Filtering** - Suppress Friend and/or Avoid nearby alerts in town zones (configurable per-type)
- **Party Disband Prompt** - After your party disbands, prompts you to rate and note each party member
- **Search** - Filter players by name or tag with instant results
- **Add from Target** - One click to fill player name from your current target
- **Quick Commands** - Add notes, set ratings, and toggle tags from chat
- **SQLite Persistence** - All data stored in a local database with dirty-flag caching

## Requirements

- Ashita v4.30+ (uses built-in LuaSQLite3)
	- This release has only been tested with Ashita v4.30

## Installation

1. Copy the `playernotes` folder to your Ashita `addons` directory
2. Load with `/addon load playernotes`

## Commands

| Command | Description |
|---------|-------------|
| `/pn` | Toggle the PlayerNotes window |
| `/pn show` / `hide` | Show or hide the window |
| `/pn <name> <note>` | Quick note on a player |
| `/pn rate <name> <1-5>` | Set player rating |
| `/pn tag <name> <tag>` | Toggle tag on a player |
| `/pn search <term>` | Search players by name or tag |
| `/pn export` | Export all players and notes to a timestamped JSON file |
| `/pn import [file]` | Import from the latest (or named) export file, merging with existing data |
| `/pn resetui` / `reset` | Reset window size, position, and column widths |
| `/pn help` | Show all commands |

## Alert System
**These are placeholder sound files**
PlayerNotes uses 6 distinct alert types with priority and suppression logic:

| Type | Trigger | Default Color | Default Sound |
|------|---------|---------------|---------------|
| Player Alert | Tracked player joins party (not Friend/Avoid) | Cyan | `player_alert.wav` |
| Friend Alert | Friend-tagged player joins party | Green | `friend_alert.wav` |
| Friend Nearby | Friend-tagged player nearby (not in party) | Dim green | `friend_nearby.wav` |
| Avoid Alert | Avoid-tagged player joins party | Red | `avoid_alert.wav` |
| Avoid Nearby | Avoid-tagged player nearby (not in party) | Orange | `avoid_nearby.wav` |
| Party Disband | Party disbanded | Cyan | `disband.wav` |

### Priority Rules
- **Party alerts**: Avoid > Friend > Player (one alert per player per zone)
- **Nearby alerts**: Avoid and Friend only (no generic nearby for untagged players)
- **Cross-source**: Party alert suppresses nearby alert for the same player

### Town Zone Filtering
Nearby alerts can be suppressed in town zones (separately for Friend and Avoid):
- **Friend nearby in town**: Off by default (towns are noisy)
- **Avoid nearby in town**: On by default (always want to know about Avoid players)

Town zones: San d'Oria, Bastok, Windurst, Jeuno, Rabao, Selbina, Mhaura, Kazham, Norg, Tavnazian Safehold, Al Zahbi, Whitegate, Nashmau, Adoulin.

## Import / Export

PlayerNotes supports full data export to JSON and import with intelligent merging.

### Export (`/pn export`)

Exports all players and notes to a timestamped JSON file in `config/addons/playernotes/exports/`. The file includes a metadata block with addon version, timestamp, and counts.

### Import (`/pn import [file]`)

Imports from the most recent export file (or a named file). Merges with existing data using these rules:

- **New players**: Inserted with all their notes
- **Existing players**: Higher rating wins, tags are union-merged, timestamps preserved (earliest `created_at`, latest `updated_at`)
- **Duplicate notes**: Skipped (matched by note text + timestamp)

Import prints a summary: players added/updated, notes added/skipped.

### Export/Import via Settings UI

The Settings window includes **Export All** and **Import** buttons that invoke the same commands.

## UI Layout

Single-page view with toolbar, sortable table, and expandable detail panel:

### Toolbar
- **Search box** - Filter by name or tag (with placeholder hint)
- **Tags dropdown** - Filter player list by a single tag category
- **+ Add button** - Opens popup window to create a new player profile

### Player Table
Sortable, scrollable table (max 10 visible rows with frozen header):
- **Player** - Name (click row to expand detail panel, sortable)
- **Rating** - Star display (sortable)
- **Tags** - Color-coded tag chips (not sortable)
- **Notes** - Note count (not sortable)
- **Updated** - Date of player creation or last note added (sortable)

Avoid-tagged players are highlighted with a red row background.

### Detail Panel
Expanded below the table when a player row is clicked:
- Editable star rating (click to change, click same star to clear)
- Tag toggle buttons (colored when active, outlined when off)
- Add new note input (above the notes list, matching newest-on-top order)
- Individual notes with zone and timestamp metadata
- Edit and delete notes inline
- Delete player button (with confirmation)

### Settings
Opens as a separate popout window via the **Settings** button in the status bar.

## Tags

| Tag | Color | Use Case |
|-----|-------|----------|
| Healer | Green | WHM, SCH, etc. |
| Tank | Blue | PLD, RUN, etc. |
| DPS | Red | DD jobs |
| Support | Purple | BRD, COR, GEO |
| Crafter | Orange | Crafting partners |
| Friend | Cyan | People you like |
| Avoid | Dark Red | Problem players (highlighted row + red warning toast) |
| Mentor | Gold | Helpful teachers |

## Settings

Per-character settings are saved automatically. Organized into two sections:

### Main Settings

| Section | Setting | Default | Description |
|---------|---------|---------|-------------|
| General | Open on load | true | Open window when addon loads |
| Player Alerts | Prompt on disband | true | Show note prompt after party disbands (alliances skipped) |
| Player Alerts | Enable player detection | true | Master toggle for entity scan and all alert toasts |
| Player Alerts | Friend nearby in town | false | Allow Friend nearby alerts in town zones |
| Player Alerts | Avoid nearby in town | true | Allow Avoid nearby alerts in town zones |
| Toasts | Enable sound | true | Master toggle for all alert sounds |
| Toasts | Duration | 5 sec | How long toasts stay on screen (2-15) |
| Toasts | X position | 10 | Toast horizontal position (0-1920) |
| Toasts | Y position | 40 | Toast vertical position (0-1080) |

### Advanced Toast Settings

| Section | Setting | Default | Description |
|---------|---------|---------|-------------|
| Timing | Check interval | 10 sec | Seconds between entity scans (5-60) |
| Animation | Fade enabled | true | Enable fade in/out for toasts |
| Animation | Fade in | 0.0 sec | Fade-in duration (0-3) |
| Animation | Fade out | 1.0 sec | Fade-out duration (0-3) |
| Interaction | Click to dismiss | false | Click on a toast to dismiss it immediately |
| Layout | Stack direction | Down | Stack new toasts downward or upward |
| Layout | Stack spacing | 40 px | Vertical spacing between stacked toasts |
| Layout | Max visible | 10 | Maximum simultaneous toasts on screen |
| Appearance | Background opacity | 0.8 | Toast background transparency |
| Appearance | Background color | Dark gray | Toast background color |
| Text Colors | (6 pickers) | Varies | Per-type text color for each alert type |
| Alert Types | (6 rows) | All on | Per-type sound toggle, test button, and sound filename |

## File Structure

```
playernotes/
  playernotes.lua   -- Entry point, events, commands
  db.lua            -- SQLite persistence, 2 tables, dirty-flag caching
  context.lua       -- Game context (zone, party, entity scan, target, town zones)
  ui.lua            -- ImGui single-page UI rendering + alert system
  sounds/
    player_alert.wav   -- Generic tracked player alert
    friend_alert.wav   -- Friend joins party
    friend_nearby.wav  -- Friend detected nearby
    avoid_alert.wav    -- Avoid player joins party
    avoid_nearby.wav   -- Avoid player detected nearby
    disband.wav        -- Party disbanded
  exports/             -- JSON export files (gitignored)
  README.md          -- This file
  LICENSE            -- MIT License
  .gitignore         -- Runtime file exclusions
```

## Data Storage

- **Per-character settings** (show on load, alert options, toast config) are saved by Ashita's settings module under `config/addons/playernotes/<CharName>_<ID>/settings.lua`
- **Shared data** (players, notes) is stored in `config/addons/playernotes/playernotes.db` (SQLite, auto-created)
- SQLite uses WAL mode which creates companion `-wal` and `-shm` files (normal, auto-managed)

## Database Schema

Two tables with foreign key cascading:

- **players** - One row per player (name, rating, tags, timestamps)
- **notes** - Multiple notes per player (text, zone, timestamp), CASCADE delete

## Technical Notes

### Performance
- **Dirty-flag caching** - All DB-backed data uses dirty flags (`players_dirty`, `notes_dirty`, `search_dirty`) -- UI reads from memory cache, only re-queries on mutation
- **Dedicated count queries** - Note counts use `SELECT COUNT(*)` instead of loading full note rows
- **Cached ImU32 colors** - `ColorConvertFloat4ToU32` called once, not per-frame
- **Column-based sort** - `get_players(sort_col, sort_asc)` with sort-key cache matches ImGui TableGetSortSpecs
- **Deferred saves** - UI sets `settings_dirty` flag, d3d_present handler processes it (decouples rendering from I/O)
- **Lookup tables** - Toast type-to-setting mapping uses static tables instead of per-call string building

### Alert Architecture
- `check_party_alerts()` runs first, marking `alerted_players[name] = true` — party alerts always take priority
- `check_nearby_alerts()` runs second, skipping already-alerted players — prevents duplicate alerts
- Nearby alerts fire only for Friend and Avoid tags (untagged tracked players only fire on party join)
- Town zone filtering is per-type: `toast_friend_nearby_in_town` and `toast_avoid_nearby_in_town`
- `nil` toast type produces a visual-only toast with no sound (used for note saved confirmations)
- Master sound toggle (`toast_sound_enabled`) gates all per-type sound toggles

### ImGui Patterns
- Sortable table with `ImGuiTableFlags_Sortable` + `TableGetSortSpecs()` + `TableSetupScrollFreeze(0, 1)` (same as MemScope)
- Tag dropdown via `OpenPopup` / `BeginPopup` / `MenuItem` with colored text
- Toast system with 6 typed alerts, configurable position, per-type sounds/colors, and fade-out alpha
- `InputTextWithHint` for search and note input placeholder text
- `TableSetBgColor(ImGuiTableBgTarget_RowBg1, ...)` for Avoid row highlighting
- `PushStyleVar(ImGuiStyleVar_Alpha, 0.4)` for greying out dependent controls
- Separate popup windows for Add Player, Settings, and Advanced Toast Settings
- Stack direction via `imgui.Combo` dropdown (Stack down / Stack up)

## Version History

### v1.0.0
- Single-page layout: toolbar + sortable table + detail panel (no tabs)
- Sortable columns with click-to-sort headers (Player, Rating, Updated)
- Tag dropdown filter with colored menu items
- Add Player popup window with From Target button
- 6 alert types with priority/suppression: Player Alert, Friend Alert, Friend Nearby, Avoid Alert, Avoid Nearby, Disband
- Town zone filtering for nearby alerts (per-type: Friend and Avoid)
- Avoid-tagged player row highlighting (red background)
- Colored toast system with per-type sounds, colors, and test buttons
- Master sound toggle + per-type sound toggles in Advanced settings
- 8 color-coded tags: Healer, Tank, DPS, Support, Crafter, Friend, Avoid, Mentor
- Star rating widget (1-5, click same star to clear)
- Party disband prompt with per-member rating
- SQLite persistence via Ashita v4.30 LuaSQLite3
- Dirty-flag caching for all DB-backed data
- Per-character settings via Ashita's settings module
- Settings organized into Main (Player Alerts + Toasts) and Advanced Toast Settings
- 6 distinct sound files for toast notifications (one per alert type)

## Thanks

- **Ashita Team** - atom0s, thorny, and the [Ashita Discord](https://discord.gg/Ashita) community

## License

MIT License - See LICENSE file
