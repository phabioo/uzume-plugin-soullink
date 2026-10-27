# Uzume Plugin: SoulLink

SoulLink/Nuzlocke runs for Uzume: rules, detection, team and route views, run board.

Status: **v0.8.2** (save snapshot before gym leader battles, needs Uzume 0.20). Before: **v0.8.1** (icon cache keyed by the pokemon-core icon revision). Before that: **v0.8.0** (Uzume design boards 5b, 5e and 5f: panel, HUD, run tab and corrections follow the boards as far as the fb.ui blocks allow). Before: **v0.7.1** (Uzume wording in the texts: "app" and "server" instead of Player and Hub; plugin ids `uzume.soullink` and `uzume.soullink-core`, needs SoulLink Core >= 0.4.0) for Omega Ruby / Alpha Sapphire: run rules, detection through `uzume-plugin-soullink-core` 0.3.1 (places and routes from the game, encounters, catches, deaths, badges), link groups, manual corrections, a compact in-game panel, the run screen (opened from the game; its Map tab takes the real game map from the 3DS bottom screen (full screen by default, adjustable crop, permission `video.capture`) or lets you pick it among the images of your own game files; "Place routes" offers every place of the game; a "Game data" block shows all pokemon-core diagnostics), HUD, tile strip, run view and run board. Details: [docs/architecture.md](docs/architecture.md).

Requires Uzume 0.11 or later (plugin API v1) and `uzume-plugin-soullink-core`, which the Start dialog adds to the run automatically (manifest `requires`). Part of [Uzume](https://github.com/phabioo/uzume); plugin interface: `docs/architecture/12-plugins.md` there. Plan: [docs/roadmap.md](docs/roadmap.md). UI design (screens 5a to 5i): [docs/design/](docs/design/README.md).

## Releasing

1. Bump `version` in `plugin/manifest.json` and merge.
2. Release `vX.Y.Z` (must equal the manifest version), either by pushing the tag or by running "Release" in Actions on `main` with the tag as input; the latter creates the tag at that commit. The `Release` workflow runs the checks, builds the unsigned `.fbplugin` (`python3 tools/package.py`) and attaches it to the GitHub release. Re-running with an existing tag replaces the asset. The release notes are collected from the `## Changelog` sections of the merged PRs since the previous tag (`tools/changelog.py`).
3. Run "Publish plugin" in phabioo/uzume with this repository and the tag; it downloads, signs and indexes the package.

License: GPL-3.0-or-later, see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md). Contributions under the [CLA](CLA.md).

Pokémon and Nintendo are trademarks of their owners. This project is not affiliated with them and contains no game content.
