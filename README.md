# PlayerNotes v1.0.0 - Player Tracking Addon for Ashita v4.3

Player tracking addon for Ashita v4.3. Rate, tag, and take notes on players you meet in Final Fantasy XI. Get toast alerts when tracked players appear nearby or join your party.

## Features

- **Player Profiles** - Star ratings (0-5), 9 color-coded tags, and unlimited timestamped notes per player
- **Pin Notes** - Pin one note per player to keep it at the top and show it in alert toasts
- **Journal-Style Notes** - Card-based note display with accent bars, zone names, and timestamps in a scrollable region
- **Multiline Notes** - Add and edit notes with multiline input (placeholder text when empty)
- **Toast Alerts** - Configurable on-screen notifications when tracked players are detected
- **Avoid Warnings** - Red row highlighting and warning toasts for players tagged Avoid
- **Friend Detection** - Party join and proximity alerts for Friend-tagged players
- **Disband Popup** - After your party disbands, prompts to rate and add notes about each member (bubble-style cards)
- **Sortable Table** - Click column headers to sort by Name, Rating, or Last Seen; resizable with drag bar
- **Tag Filtering** - Dropdown filter to view only players with a specific tag
- **Quick Commands** - Add notes, set ratings, and toggle tags via chat commands
- **Per-Character Database** - Each character gets isolated SQLite storage (multi-box safe)
- **Import/Export** - JSON export shared across characters for data portability (pinned status preserved)
- **From Target** - Fill player name from your current in-game target (rejects NPCs)
- **Name Validation** - Letters only, 3-15 characters, auto-formatted (Firstname), self-tracking blocked
- **Customizable Toasts** - Per-type colors, sounds, fade/slide/bounce animations, stacking, positioning
- **Collapsible Settings** - Advanced toast settings organized into collapsible sections (Timing, Animation, Layout, Appearance, Text Colors, Alert Types)
- **Toast Test** - Cycle through all 6 toast types from the settings menu
- **Bubble UI** - Visual separation between player detail and notes sections with rounded panel boxes
- **Tooltips** - Every interactive element has a descriptive tooltip on hover

## Requirements

- Ashita v4.3.0.2 (uses built-in LuaSQLite3 and ImGui Tables API)
	- This release has only been tested with Ashita v4.3.0.2	
	
## Installation

1. Copy the `playernotes` folder to your Ashita `addons` directory
2. Load with `/addon load playernotes`

## Commands

| Command | Description |
|---------|-------------|
| `/pn` | Toggle the PlayerNotes window |
| `/pn show` / `hide` | Show or hide the window |
| `/pn <name> <note>` | Quick-add a note on a player (creates profile if needed) |
| `/pn rate <name> <0-5>` | Set player rating (0 to clear) |
| `/pn tag <name> <tag>` | Toggle a tag on a player |
| `/pn search <term>` | Search players by name or tag |
| `/pn export` | Export all data to JSON |
| `/pn import` | Import from the most recent export file |
| `/pn import <file>` | Import from a specific export file |
| `/pn import list` | List all available export files |
| `/pn resetui` | Reset window size, position, and columns |
| `/pn help` | Show available commands |

Also accepts `/playernotes` as the command prefix.

## Player Detection

PlayerNotes periodically scans the entity array (configurable interval, default 10s) for nearby player characters and checks your party roster.

### Alert Priority

1. **Party alerts** fire first: Avoid > Friend > generic tracked player
2. **Nearby alerts** fire only for Friend and Avoid tags (untagged players only trigger on party join)
3. Party alerts suppress nearby alerts for the same player
4. One alert per player per zone (resets on zone change)

### Town Filtering

- Friend nearby alerts are suppressed in town zones by default (configurable)
- Avoid nearby alerts are active everywhere by default (configurable)

### Alert Types

| Type | Trigger | Default Sound |
|------|---------|---------------|
| Player Alert | Tracked player joins party | `player_alert.wav` |
| Friend Alert | Friend-tagged player joins party | `friend_alert.wav` |
| Friend Nearby | Friend-tagged player detected nearby | `friend_nearby.wav` |
| Avoid Alert | Avoid-tagged player joins party | `avoid_alert.wav` |
| Avoid Nearby | Avoid-tagged player detected nearby | `avoid_nearby.wav` |
| Disband | Party disbanded | `disband.wav` |

Each type can be individually enabled or disabled. Sound is controlled separately per type by clearing the filename to mute. Text colors are also configurable per type.

## Tags

| Tag | Color | Purpose |
|-----|-------|---------|
| Healer | Green | WHM, SCH, etc. |
| Tank | Blue | PLD, RUN, etc. |
| DPS | Red | WAR, SAM, etc. |
| Mage | Purple | BLM, SMN, etc. |
| Support | Light Purple | BRD, COR, etc. |
| Crafter | Orange | Crafting partners |
| Friend | Cyan | Triggers party + nearby alerts |
| Avoid | Dark Red | Warning alerts + red row highlight |
| Mentor | Gold | Helpful teachers |

## Disband Detection

When your party goes from having members to empty (alliances are excluded), a popup appears listing each former party member in a bubble card with a star rating widget, note input, and save button. Saved members turn green.

Trusts are filtered out automatically — dismissing trusts won't trigger the disband popup. A 15-second cooldown after zoning also prevents false popups during zone transitions.

## Export / Import

**Export path**: `config/addons/playernotes/exports/playernotes_<CharName>_YYYYMMDD_HHMMSS.json`

Exports are shared across all characters (not per-character). Each export includes full player profiles with all notes, ratings, tags, and timestamps.

**Import merge logic**:
- New players are inserted with their original timestamps
- Existing players: higher rating wins, tags are union-merged, timestamps adjusted (earliest created, latest updated)
- Notes: duplicates detected by text + timestamp match, only new notes are added
- Pinned status is preserved during export/import (older exports without `pinned` default to unpinned)

## File Structure

```
playernotes/
  playernotes.lua  -- Main addon: metadata, events, commands, export/import
  db.lua           -- SQLite schema, CRUD, dirty-flag caching, running counters
  context.lua      -- Game API wrapper: zone, party, nearby players, target
  ui.lua           -- ImGui rendering: player table, detail panel, toasts, settings
  sounds/          -- 6 alert sound files (.wav)
```

## Data Storage

Each character gets their own SQLite database at:
```
config/addons/playernotes/<CharName>_<ServerId>/playernotes.db
```

This matches Ashita's per-character settings convention. WAL mode is enabled for safe concurrent reads.

### Schema

**players** - One row per tracked player
- `player_name` (UNIQUE, case-insensitive), `rating`, `tags` (comma-separated), `created_at`, `updated_at`

**notes** - Multiple notes per player
- `player_id` (FK with CASCADE delete), `note`, `zone_name`, `created_at`, `pinned` (0 or 1, one per player)

### Migration

If upgrading from an older version with a shared `playernotes.db` at the config root, the database is automatically moved to the first character's per-character folder on first load.

## Settings

Settings are saved per-character via Ashita's settings library.

### Main Settings
- Open window on load
- Enable player detection (master toggle for all alerts)
- Prompt on party disband
- Append pinned/latest note to alert toasts
- Friend/Avoid nearby alerts in town zones
- Toast test button (cycles through all 6 alert types)

### Toast Settings
- Master sound toggle
- Click to dismiss
- Duration, X/Y position
- Per-type alert toggles (disable the entire alert per type)
- Per-type sound files (clear filename to mute just the sound)
- Fade in/out animation
- Slide in/out animation (4 directions: left, right, top, bottom)
- Bounce effect (elastic ease-out on slide-in, configurable speed)
- Stack direction and spacing
- Corner rounding and border size/color
- Background color and opacity
- Per-type text colors
- Max visible toasts

## Technical Notes

### Performance
- **Dirty-flag caching**: All DB queries are cached and only re-executed after mutations
- **Negative lookup cache**: Untracked player names are cached to avoid repeated DB queries during entity scans
- **Running counters**: Status bar counts use O(1) in-memory counters instead of COUNT(*) queries
- **Pre-computed lookups**: Star display strings and color values are computed once, not per-frame
- **Cached function references**: Hot-path Lua standard library functions are localized
- **Cached ImU32 colors**: Panel and card colors converted to U32 once, not per-frame
- **Two-pass height caching**: Note cards and panel bubbles measure height on frame N, draw backgrounds on frame N+1
- **Zone name cache**: `get_zone_name()` caches the result per zone_id — avoids `GetString('zones.names', ...)` calls every frame
- **Player name cache**: `get_player_name()` caches after first successful read (name doesn't change during session)
- **Detail panel dedup**: `parse_tags()` called once per render for both rating and tag sections
- **Disband popup caching**: `get_player_by_name()` result cached per member (avoids SQLite query per frame)

## Version History

See [CHANGELOG.md](CHANGELOG.md) for full version history.

## Thanks

- **Ashita Team** - atom0s, thorny, and the [Ashita Discord](https://discord.gg/Ashita) community

## License

MIT License - See LICENSE file
