# PlayerNotes Changelog

## v1.2.1

### New Features
- **Mage tag**: New purple tag for BLM, SMN, etc. (removed BLM from DPS tag tips)
- **Slide animation**: Independent slide in/out with configurable timing and 4 directions (left, right, top, bottom)
- **Bounce effect**: Elastic ease-out on slide-in for a bouncy feel, with configurable oscillation speed
- **Collapsible sections**: Advanced Toast Settings organized into 6 collapsible sections (Timing, Animation, Layout, Appearance, Text Colors, Alert Types) using TreeNodeEx with colored headers
- **Corner rounding**: Configurable rounded corners for toast windows
- **Border customization**: Configurable border size and color for toasts

### UI Polish
- Click to dismiss moved to main settings page (next to Enable sound)
- Tag tooltips standardized to consistent format with 2 job examples and "etc."
- Tag tooltip text now renders in the tag's color instead of default white
- Status bar bottom padding added so buttons don't look clipped
- Resize bar double-click to reset now works reliably (check moved before drag handler)

### Bug Fixes
- **`/pn tag` command**: Mage tag now recognized by command validation (`valid_tags` table updated)
- **Help text**: `/pn help` and error messages now list all 9 tags including Mage
- **Notes cache performance**: `db.notes_dirty` flag now resets after query (was stuck true, causing SQLite re-query every frame when detail panel was open)
- **Redundant DB query**: `maybe_append_note()` no longer calls `get_pinned_note()` separately — `get_notes()` already returns pinned notes first
- **Dead ternary**: Pin button label simplified from redundant conditional to static string

## v1.2.0

- **Pin notes**: Pin one note per player — pinned notes sort first with a gold accent bar and `[Pinned]` badge
- **Pinned note in alerts**: Toast notifications prefer the pinned note over the most recent note
- **Journal-style note cards**: Notes rendered as cards with ImDrawList backgrounds, left accent bars (gold for pinned, gray for others), zone name + timestamp headers
- **Multiline note input**: Add and edit notes with multiline text areas (replaces single-line input)
- **Placeholder text**: "Write a note..." placeholder in the add note input when empty
- **Scrollable notes**: Notes section uses a scrollable child region for players with many notes
- **Bubble box UI**: Player detail and notes sections wrapped in rounded panel boxes with soft shadows for visual separation
- **Resizable player table**: Drag bar below the table to resize height; double-click to reset to auto
- **Name validation**: Strict validation on save — letters only, 3-15 characters, cannot track yourself; shows error messages instead of silently stripping
- **Disband popup cards**: Each party member in the disband popup gets their own bubble box (green tint when saved)
- **Toast test button**: Test button in settings cycles through all 6 toast types on each click
- **Dynamic screen resolution**: Toast X/Y position sliders use actual display resolution instead of hardcoded 1920x1080
- **Comprehensive tooltips**: Every interactive button, slider, checkbox, and color picker has a descriptive tooltip
- **Edit toggle**: Clicking Edit on a note toggles the editor open/closed
- **Trailing whitespace trim**: Notes are trimmed of trailing whitespace and empty lines on save
- **Schema migration**: `pinned` column added to notes table via `pcall` (safe on repeated loads)
- **Export/import**: Pinned status included in exports and preserved during imports (backward compatible)
- **Per-type alert toggles**: Checkboxes in Advanced Toast Settings now disable the entire alert (visual + sound), not just the sound. Clear the filename to mute just the sound.
- **Trust filtering**: Disband popup no longer triggers when dismissing trusts; entity type scan identifies trusts (type != 0) by name and caches them across zone transitions
- **Zone change cooldown**: 15-second cooldown after zoning prevents false disband popups; state preserved during cooldown so real disbands are still detected

## v1.1.2

- Replaced `PushStyleVar(Alpha, 0.4)` + click guards on detection sub-options with `BeginDisabled/EndDisabled` (native ImGui disabled-state API)
- Added `InputTextWithHint` placeholder text to Add Player name input

## v1.1.1

- Zone name caching in `context.get_zone_name()` (avoids per-frame `GetString` calls)
- Player name caching in `context.get_player_name()` with `clear_player_cache()` on logout
- Deduplicated `parse_tags()` call in detail panel (was parsing twice per render)
- Disband popup caches `get_player_by_name()` per member instead of querying per frame

## v1.1.0

- Per-character database storage (multi-box safe)
- Auto-migration from shared DB to per-character folder
- Export/import system with JSON format and merge logic
- Export filenames include character name
- `/pn import list` command to list available exports
- `PRAGMA busy_timeout=3000` for write contention safety
- Transaction-wrapped imports (single fsync for bulk operations)
- pcall safety around all prepared statement operations including export
- O(1) running counters for status bar counts
- Negative lookup cache for untracked player names during scans
- Boundary-aware tag LIKE queries (no substring false matches)
- Pre-computed star display strings for table rendering
- Cached math/string function references for render loop
- `update_player` now touches `updated_at` timestamp
- LuaSQLite3 API reference in db.lua header
- Cross-addon convention alignment (metadata, headers, .gitignore)

## v1.0.0

- Initial release
- Player profiles with star ratings, tags, and notes
- 6 toast alert types with per-type sounds and colors
- Sortable table with tag filtering
- Disband popup with per-member rating and notes
- Add Player popup with From Target button
- Settings window with advanced toast configuration
