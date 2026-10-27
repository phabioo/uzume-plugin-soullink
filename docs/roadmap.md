# Roadmap

Status: v0.9.0 (manifest `recap` block, `soullink.badge` run event, "Demo data" tag in the panel header); v0.8.3 (shows the run's randomizer from the optional `fb.run.current().randomizer` of Uzume 0.21: a fact line "Randomized · each person their own world · <preset>" in the run tab header and run board, a "Randomized" badge in the in-game panel, "own variant" next to people with `variant_kind` "own"; display only, no rule changes, seeds and settings never shown); v0.8.2 (save snapshot "before Gym N" through `fb.save.snapshot` (Uzume 0.20) when a gym leader battle starts: a trainer battle in which a foe reaches the level cap of the next gym, since pokemon-core marks no boss battles; once per gym and session, guarded for older apps without `fb.save`); v0.8.1 (icon cache keyed by pokemon-core `info().icon_rev`); v0.8.0 (Uzume design boards 5b, 5e, 5f: panel, HUD, run tab and corrections follow the boards as far as the fb.ui blocks allow); v0.7.1 (Uzume wording in texts and comments); v0.7.0 (new plugin ids uzume.soullink and uzume.soullink-core; the screen slot is the run tab of the Uzume app; v0.6.2: map from the game files or the game picture, full-screen default crop, Game data block with every key; place picker with every place, compact panel, run screen opened from the game, detection from pokemon-core 0.3.1). Depends on Uzume plugin API v1 (0.11); see https://github.com/phabioo/uzume `docs/roadmap.md`.

## v0.1 MVP on Omega Ruby / Alpha Sapphire

- Run rules as switches: first encounter per route, dupes and shiny clause, defeated = dead, SoulLink pairs per route, optional shared-type and team-pair rules, nickname and level-cap hints. Horde encounters do not count as first encounter by default (switchable).
- Detection via `uzume-plugin-soullink-core`: location, encounter (kind), catch, team, box change, death, badges.
- Manual correction of everything (encounter does not count, undo death, change pairing, add Pokémon); every change is in the event log with the user name.
- Views: in-game tab (team, location status, partner of the route, graveyard), HUD, Multiview tile overlay, run screen (routes table routes x players, map, log, graveyard), run board and session view (also as OBS source).
- Design screens 5a to 5i (Claude Design handoff, accepted 2026-10-11): done, see [design/README.md](design/README.md). Open design questions are listed there.
- Playtest with the group, then feedback into platform and plugin.

## v0.4.0 panel, run screen, detection from pokemon-core 0.3

- Panel per design 5b at about 300 px (run header, location card, encounter hint, team with partners, graveyard, footer); the full run screen (5e, all corrections) opens with `fb.ui.open("screen")` (button, toast action, Ctrl+R); without that call the panel says to update Uzume.
- Routes are the encounter areas of the game (`areas()`, key `loc:<location id>`), names read from the game and stored short in the own run state so other players, the tile strip and the server show names; old `route-N` keys still render.
- Detection: `encounters()` seq (first per area, hordes, shiny and dupes clause), catch by team/box diff, death by live hp 0 or battle hp 0, badges from `badges()`, pairs-differ-primary-type via `species_info`.
- Map tab: the map is captured from the 3DS bottom screen ("Take map from screen", `fb.video.capture`, permission `video.capture`). Needs an app with the game picture API; older apps show an update hint. (0.6.0 adds the second source, see below.)
- Open: level caps and map positions of the areas are recorded with the real game; see `docs/architecture.md` open points.

## v0.4.1 fixes from the first playtest

- Place select and Routes list use all places of the game (`areas()` + `locations()`: towns, caves), current place preselected; no more naming places by hand.
- A finished wild battle stays pending until the mon shows up (caught) or the player moves on / the next wild battle / 60 s (missed); deaths only from the party record.
- No "No place yet" events for transient reads; species and place names are resolved at render time when they were unknown at posting time.
- Run screen: first tab selected by default and tracked by id; rules collapsed to a summary.

## v0.6.0 map from the game files

- Map tab source choice: "Take map from screen" (default crop is the full screen, the estimated ORAS crop was wrong and is gone) or "From game files": browse the images pokemon-core found in the player's own RomFS (`map_candidates()`, preview from `map_image(id)`, "Image n of N", previous / next, "Use this map", "still searching" while the core scans). The chosen id is stored per game with the map; positions are rescaled when the source or crop changes. Hidden for a core without these functions.
- Game data block: every diagnostics key, grouped by prefix (one wrapped line per group); closed by default in 0.6.1, chip "Show game data" / "Hide game data", state kept across refreshes.

## v0.6.1 Game data closed by default

- The "Game data" block is closed by default again; the chip "Show game data" opens it and the choice is kept across refreshes. Grouping by key prefix and the no-cap behaviour are unchanged.
## v0.8.3 Randomized runs shown

- `model.view` `V.randomizer(run)` reads the optional `fb.run.current().randomizer` (`mode` "each" | "same", `preset_id`, `preset_label`; Uzume 0.21) nil-safe; an absent field or an unknown mode means no randomizer. Participants with `variant_kind` "own" get `own_variant` in the view. Seeds, settings and tool version are never kept or shown.
- Display only: eyebrow-style fact "Randomized · each person their own world · <preset>" (or "same world for everyone") in the run tab header (`head-randomizer`) and on the run board (`b-randomizer`), a "Randomized" badge in the in-game panel header, "own variant" under the name in the Team tab and in the board player list. No rule changes: SoulLink links by route, so different species per person are fine. Detection is unchanged (names and encounters come from the running game).
- Open: not yet run against a real Uzume 0.21; written against the announced field shape.

## v0.8.2 Save snapshot before gym battles

- `model.gym` + `App:gym_snapshot`: when `battle()` reports an active trainer battle and a foe is at or above `oras.level_cap(badges)` (the leader's strongest creature), the plugin calls `fb.save.snapshot("before Gym N")` (label in the app: "SoulLink & Nuzlocke: before Gym N"; at most one per minute per plugin, so a refusal is retried on the next 5 polls of the same battle). Once per gym and session; never in the run view; `fb.save` missing (app older than 0.20) or throwing is ignored.
- Open: pokemon-core reports no gym or boss marker, so this is a heuristic on the level cap table (itself marked "verify locally"); the Elite Four and champion (all badges) are not covered; a lost gym fight is not snapshotted again in the same session; no run rule switches it off.

## v0.8.1 Icon cache by revision

- Creature icons are cached as `icons/<rev>/<species>-<form>.png` with `<rev>` = `info().icon_rev` of pokemon-core (>= 0.4.2), so icons that an older core decoded wrongly are fetched again. The revision is read once (only `[%w%-_.]`, at most 32 chars) and retried after 10 s while `info()` fails; a core without a valid `icon_rev` keeps `icons/<species>-<form>.png`. Old cache files are not deleted.

## v0.8.0 Uzume design boards

- Panel (5b-1): no own eyebrow (the app draws "Drawn by SoulLink"), one "Open run" in the header, encounter card with "first on this route" and "Doesn't count" plus the default key hint (Ctrl+D, only the keys the manifest declares), "Linked with" over the partners, footer "Graveyard n · Badges n / 8 · next cap Lv n".
- HUD (5b-2): "SL · <place>" and a toned status badge (No encounter yet, Encounter now, Caught, Missed, Not a route); no own badge or dot.
- Run tab (5e): summary eyebrow "Deaths n · Routes a / b · Badges n" instead of name, players and stat cards; rules and Game data moved below the tabs (Game data still closed behind its chip); plain tab names; map eyebrow naming the source and the route card (`popover`: people and state); Routes chips "All · n / Open · n / Complete · n"; Team & box with avatar, current route, team grid and box images; Graveyard grouped by link group with time and "Undo…"; Event log with "Manual · n", a people select and the time (UTC) instead of #seq.
- Corrections (5f-1): board titles and bodies, action button before Cancel, a "who sees it" line.
- Skipped, needs app features or data the plugin does not have: game version name in the Team & box eyebrow, region name in the map eyebrow, creature images inside table cells (Routes), Export, the event source column ("Lena's app"), zoom buttons and D-pad hints (drawn by the map block), species `Select` in "Add by hand", exact "today 22:41" times (event time is UTC, no wall clock in the sandbox).

## v0.7.1 Uzume wording

- Texts and comments say "the app" and "the server" instead of the old product names Player and Hub (ADR 0030 D1). Changed strings: `source_hub` (en "hub" -> "server", de "Hub" -> "Server"), `map_err_unsupported` and `map_err_denied` (en "Player" -> "app", de "Player" -> "App"). No key renamed, `{player}` placeholders unchanged, the event source value `hub` in run data unchanged.

## v0.7.0 Uzume plugin ids

- New plugin ids for Uzume (ADR 0030 D7 of the Uzume app): `uzume.soullink` (this plugin) and `uzume.soullink-core` (requires `>=0.4.0`). No migration and no compatibility alias; run settings are read under the new id. The Uzume app has no sidebar screen any more: the `screen` slot is the plugin tab in the run view ("run tab"), and in a game `fb.ui.open("screen")` still opens the sheet. Behaviour is unchanged.


## v0.6.2 corrections and detection agree, icon check

- Fix (found in a real Omega Ruby run): "Doesn't count" on a route only changed the view; detection kept the first encounter (missed / encounter) and rejected the next encounter as "used" and the catch as "extra". Now the effective corrections (`doesnt_count`, `mark_missed`, `add`, with reverts) are passed to detection as route overrides, so a later encounter on a reopened route is the first one and its catch counts; the view and detection use the same function (`corrections.route_overrides`). Entries created after a correction carry the correction seq (`rs`), older stored states load unchanged. The dupes clause ignores mons that "don't count".
- Game data block: "Icon check" with the 4 variants from pokemon-core `icon_variants(species, form?)` (>= 0.3.4) for the first team creature, asked once per opening; hidden with an older core.

## Later

Follows the games supported by `uzume-plugin-soullink-core`: Gen 7, Gen 4/5, Gen 3, Gen 1/2.

Requires plugin API v1 (since Uzume 0.11) and `uzume-plugin-soullink-core`.
