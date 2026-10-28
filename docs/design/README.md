# Design

UI design of the SoulLink & Nuzlocke plugin: screens 5a-5i from the Claude Design handoff (Turn 6, part 1 and 2) and the correction pass of 2026-10-11 (Turn 7, ids with `-2`). Accepted by Fabio on 2026-10-11. At the time of the handoff plugin API v1 was planned (0.11) and not implemented; this is design, not a description of working code.

Platform design (tokens, slots, blocks, component sheet, app and server shell, hotkeys, notices): https://github.com/phabioo/uzume/tree/main/docs/design. The screens here use only platform blocks; the platform components they import (`game-header`, `game-panel`, `settings-row`, `block-sheet`, `plugin-settings-screen`, `uzume-mark`, `diag-overlay`) are not copied here.

All names are fictional placeholders: game "Coral Saga: Ember / Tide", region "Marisol", creatures such as "Tidepup" (drawn by `creature-icon` as colored shapes), places, characters and items. No game assets, no real creature, place or character names, no hosts except `hub.example.com`. "Nintendo 3DS" and "Azahar" appear only as platform and core names.

## Source

Files in `source/` are unchanged copies of the handoff (only renamed, `dc-import name=` set to kebab-case, the old product name replaced by Uzume on 2026-10-28, and one real creature name in the round-2 change list replaced by a generic phrase). They do not render standalone: the runtime `support.js` and the platform components are missing. Mock values (user names Max, Lena, Jonas, Sam, run "Ember & Tide", versions, `hub.example.com`) are illustrative.

| File | Content |
|---|---|
| `source/soullink-5a-5i.dc.html` | Round 1: 5a, 5ah, 5b, 5c, 5d, 5f, 5h, 5i (313 lines) |
| `source/soullink-5e-5g-run.dc.html` | Round 1: 5e run screen, 5gh Hub board, 5gs stream view, handoff table with the open questions (120 lines) |
| `source/plugins-round-2.dc.html` | Round 2: `-2` artboards (platform and SoulLink), component sheet, change list (488 lines) |
| `source/soullink-panel.dc.html` | In-game panel tab (5b) |
| `source/run-screen.dc.html` | Run screen, app and server shell (5e, 5gh) with the mock data of the run |
| `source/hub-run-wizard.dc.html` | Hub web wizard (5ah-2) |
| `source/region-map.dc.html` | Region map with markers, filters, popover, empty state |
| `source/creature-icon.dc.html` | Placeholder creature icons: sizes mini 24x18, box 40x30, sprite 68x56; states alive, dead, missed, empty; owner dot |

Content changes: one replacement, `plugins-round-2.dc.html` line 481 (a real creature name in the change list of round 2, now replaced by a generic phrase). Checked by grep, nothing else found: real game, creature, place or character names, GPU names, private hosts or IPs. `uploads/` of the handoff was not copied.

## Reading note

Read only the spec of the screen you build (`soullink.md`), then the source lines given there. Line ranges refer to the file named in the table; anchors are `id` or `data-screen-label` values. Where a round-1 artboard has a `-2` id, the `-2` artboard wins. Round-1 files carry colors, versions and names already fixed in place; their layout is not.

## Screens

Status: planned, nothing built. Spec in [soullink.md](soullink.md).

| Screen | Spec | Source (file, lines) | Notes |
|---|---|---|---|
| 5a Start a run, steps 5a-1..5a-5 (Player) | [5a](soullink.md#5a-start-a-run) | 5a-5i `#5a-1`..`#5a-5`, 28-89 | valid; colors fixed in place |
| 5ah Hub wizard | [5ah](soullink.md#5ah-hub-wizard) | round 2 `5ah-2-1`..`5ah-2-5`, 292-300; `hub-run-wizard` | `-2` shows all five steps. Round-1 `5ah` (5a-5i 91-112) is reference only |
| 5b In-game panel, 1440 | [5b](soullink.md#5b-in-game-panel) | round 2 `5b-2`, 306-317; `soullink-panel` | 3DS, dark only. Round-1 `5b 1440` (5a-5i 118-129) reference only: DS screens, old colors, light variant |
| 5b In-game panel, 1280 | [5b](soullink.md#5b-in-game-panel) | round 2 `5b-1280-2`, 319-329 | Round-1 `5b 1280` (131-140) reference only |
| 5b location states | [5b](soullink.md#location-card-states) | 5a-5i `5b location states`, 142-146 | valid |
| 5c HUD widget | [5c](soullink.md#5c-hud-widget) | round 2 `5c-2`, 331-341 | Round-1 `5c` (5a-5i 152-164) reference only: red flash |
| 5d Tile overlay | [5d](soullink.md#5d-multiview-tile-overlay) | round 2 `5d-2`, 343-358 | Round-1 `5d` (166-187) reference only: DS tile |
| 5e Run screen: map, routes, log | [5e](soullink.md#5e-run-screen) | round 2 `5e-map-2`, `5e-map-light-2`, `5e-routes-2`, `5e-log-2`, 383-387; `run-screen` | `-2`; round-1 `5e-map`, `5e-map-light`, `5e-routes`, `5e-log` reference only |
| 5e Run screen: team, graveyard | [5e](soullink.md#5e-run-screen) | 5e-5g `5e-team`, `5e-grave`, 28-36 | valid (no `-2`) |
| 5f-1 Doesn't count | [5f](soullink.md#5f-manual-correction) | 5a-5i `5f-1`, 203-209 | valid |
| 5f-2 Undo death | [5f](soullink.md#5f-manual-correction) | round 2 `5f-2-2`, 362-369 | Round-1 `5f-2` (211-217) reference only: group 7, old text |
| 5f-3 Change link group | [5f](soullink.md#5f-manual-correction) | round 2 `5f-3-2`, 370-377 | Round-1 `5f-3` (219-224) reference only |
| 5f-4 Add by hand, 5f-5 Mark missed | [5f](soullink.md#5f-manual-correction) | 5a-5i `5f-4`, `5f-5`, 226-239 | valid |
| 5gh Hub run board | [5g](soullink.md#5gh-hub-run-board) | 5e-5g `5gh`, 33 (`tab=map`, `shell=hub`) | valid, light, Hub shell |
| 5gs Stream view 1920 x 1080 and 480 x 1080 | [5g](soullink.md#5gs-stream-view) | 5e-5g `5gs`, 42-58 and 60-71 | valid |
| 5h Notices | [5h](soullink.md#5h-notices) | 5a-5i `5h`, 189-198 | valid. Platform toast spec: 4g, 4g-2 |
| 5i Settings | [5i](soullink.md#5i-settings) | 5a-5i `5i`, 246-257 | valid; generated from the plugin schema |
| Handoff table (purpose, states, blocks, open) | - | 5e-5g, 73-79 (data 105-114) | source of the open questions |
| Component sheet, change list (round 2) | platform | round 2, 391-392 and 398 (data 475-487) | platform sheet in the Uzume repository |

Stale wording in the source: the handoff table row 5c/5d (5e-5g line 108) still says "death flash"; the decision below applies. The row 5b still says "light" (light variant removed in round 2). `soullink-panel` still has an unused `theme: light` option.

## Decisions

Fabio, 2026-10-11 (accepted corrections of round 2):

- Player colors are identity only and never carry status. Dark / light: Max `#6f9cff` / `#2f5fd0`, Lena `#f07ab8` / `#b8327a`, Jonas `#a6d65a` / `#4d7a14`, Sam `#b39cf5` / `#6a4fc4` (verified against `run-screen`, `region-map`, `soullink-panel` and the round-2 legend). Light values at least 4.5:1 on `#f6f5f2`. Cyan (`#3cbfd8`) is for open, selection and focus.
- Death is grey + x mark, never red; no red flash. A death in your link groups expands the HUD widget for 3 s (off with Reduce motion), then the notice carries the detail. Red stays for danger actions and low HP.
- In-game views (panel, HUD, tiles, header) stay dark in both themes. Light applies to Library, Settings, the run screen and the Hub.
- Ctrl+H shows or hides the plugin's HUD widget and does nothing else. Expanding is click or controller A. Plugin hotkeys here: Ctrl+H, Ctrl+D (encounter doesn't count), Ctrl+R (open run); Uzume keys always win, a conflicting plugin key stays unassigned (platform 3f-4).
- Amber is the warning tone (unverified, paused, pending, manual, mid HP). Plugins pick a tone, never a hex.
- The game is a Nintendo 3DS title played with the core Azahar (top screen 400 x 240, bottom 320 x 240).

Drawn defaults for open questions of the SoulLink screens. They are what the design shows, not decided; each needs confirmation before it is built:

| | Question | Drawn default |
|---|---|---|
| A | Can rules change after the start (vote of all players) or never? | Not drawn. 5a-1 says the mode cannot be switched after the start; 5i says "running runs keep theirs". Rule changes in a running run: open, nothing designed. |
| B | Tap on a team row: 5f actions inline or run screen? | Not drawn inline. The panel shows "Run screen ->" and the tile overlay is read only ("changes go through the run screen"). Open. |
| C | Do corrections need another player's approval? | Not required. Every correction applies at once, is logged as `manual` and visible to all, and others can undo. One log row shows "Lena approved" (5e log); no approval flow is drawn. Open. |
| D | Stream view access: public read-only link with token, or Hub login? | Token link, revocable in the run settings. Security decision, open; do not build before it is decided. |
| E | Linked death while in fullscreen: toast or only the HUD? | HUD widget expands for 3 s, and the important toast with "Open run" and "Undo death..." (5h) is drawn. Whether the toast also interrupts fullscreen: open. |
| F | Game without a region map | Routes tab first, Map tab hidden. The map image is read from the player's game file at runtime (empty state in `region-map`: "Reading the map from your game file..."). |
| G | Round-1 colors: Lena close to danger red | Resolved by the new color set above. |

Mock data only (no behavior to implement):

- Route 121: the map and the routes table show it without a group ("no link", "Broken · missed"), while 5f-3-2 moves "Flurry" into "Group 6 · Route 121", and the table has no group 6 row. Route 105 / group 4 is in the table but not on the map.
- Dupes clause is on, yet Lena (Route 104) and Jonas (Route 110) hold creatures of lines they already own, and two catches of one species appear in a team. Illustration; do not derive rule logic from it.
- Numbers like "Deaths 7", "214 events", "Routes 9 / 31", the group number in the undo dialog (3 in 5f-2-2, 7 in round 1) and the plugin versions are mock values.
