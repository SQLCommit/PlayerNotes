# PlayerNotes Changelog

## v1.0.0

Initial release.

### Features
- **Player Profiles** - Star ratings (0-5), 9 color-coded tags, and unlimited timestamped notes per player
- **Pin Notes** - Pin one note per player to keep it at the top and show it in alert toasts
- **Journal-Style Notes** - Card-based note display with accent bars, zone names, and timestamps in a scrollable region
- **Multiline Notes** - Add and edit notes with multiline input and placeholder text when empty
- **Toast Alerts** - 6 configurable on-screen notification types with per-type colors, sounds, and toggles
- **Avoid Warnings** - Red row highlighting and warning toasts for players tagged Avoid
- **Friend Detection** - Party join and proximity alerts for Friend-tagged players
- **Disband Popup** - Prompts to rate and add notes about each party member after disbanding (bubble-style cards)
- **Sortable Table** - Click column headers to sort by Name, Rating, or Last Seen; resizable with drag bar
- **Tag Filtering** - Dropdown filter to view only players with a specific tag
- **Quick Commands** - Add notes, set ratings, and toggle tags via `/pn` chat commands
- **Per-Character Database** - Each character gets isolated SQLite storage (multi-box safe)
- **Import/Export** - JSON export shared across characters for data portability (pinned status preserved)
- **From Target** - Fill player name from your current in-game target (rejects NPCs)
- **Name Validation** - Letters only, 3-15 characters, auto-formatted (Firstname), self-tracking blocked
- **Customizable Toasts** - Per-type colors, sounds, fade/slide/bounce animations, stacking, positioning
- **Collapsible Settings** - Advanced toast settings organized into collapsible sections
- **Toast Test** - Cycle through all 6 toast types from the settings menu
- **Bubble UI** - Visual separation between player detail and notes sections with rounded panel boxes
- **Tooltips** - Every interactive element has a descriptive tooltip on hover
- **Trust Filtering** - Entity type scan identifies trusts (type != 0) and caches names across zone transitions
- **Town Filtering** - Friend nearby alerts suppressed in town zones by default (configurable)
- **Zone Change Cooldown** - 15-second cooldown after zoning prevents false disband popups

### Technical
- Dirty-flag caching for all DB queries with per-player note caches
- Negative lookup cache for untracked player names during entity scans
- Running counters for O(1) status bar counts
- Pre-computed star display strings and cached ImU32 colors
- Two-pass height measurement for note cards and panel bubbles
- Zone name and player name caching
- Entity scan ranges: PCs at 1024-1791, trusts at 1024-2303
- WAL mode SQLite with busy timeout and transaction-wrapped imports
- Cache cleanup on addon unload via `context.clear_player_cache()`
