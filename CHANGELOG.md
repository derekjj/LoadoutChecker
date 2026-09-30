# Changelog

## v1.1.0

- New: The mismatch popup lists your saved loadouts that match (e.g. "M+" and "M+ AoE"). Click one to switch to it
- New: Redesigned popup with a modern, flat look, your spec icon, and buttons that highlight in your class color
- New: Settings panel (/lc) with custom keywords, per-content toggles, and alert options
- New: Delve & scenario support
- New: /lc check to test your loadout any time
- Fixed: Arenas were being checked against M+ keywords instead of PvP
- Fixed: Raid ready checks outside the instance (e.g. in town) expected an M+ loadout
- Fixed: Lua errors with no spec selected, Starter Build, or unsaved loadouts
- Changed: "Valid loadout" chat message is now off by default
- Changed: Renamed to "Loadout Checker" (folder LoadoutChecker, /loadoutchecker) to avoid clashing with a different addon called LoadoutCheck. /lc still works.
- Updated for 12.1.0

## v1.0.0

- Initial release: checks your talent loadout name on ready check for M+, Raid and PvP
