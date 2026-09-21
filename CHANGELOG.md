# Changelog

[Back to PlayerNotes](README.md)

## v1.0.1

### Improved

- Separated schema changes and data migrations for maintainability. The identity migration preserves a `.v1-backup` beside the database.

### Fixed

- Trusts appearing in the disband review, including during summoning and zoning.
- Failed note, rating, or profile writes being treated as successful. Editors now retain your input and report the failure.
- Partial or empty imports reporting success. A failed statement now rolls back the whole import.
- Temporary database read failures permanently suppressing a player's alerts.
- Queued alerts expiring before becoming visible, and nearby alerts firing for departed players.
- Logout leaving the previous character's database open or showing a disband popup at character selection.
- Incorrect deletion counters after a refused write.
- Imports creating a profile about your own character.

## v1.0.0

Initial release.
