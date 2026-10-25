# Optional browser journeys

These tests run Chromium through Python Playwright against the real Phoenix
Endpoint on an ephemeral **loopback-only** port. They use the SQL Sandbox,
`ExAgent.Models.Test`, and exact dice, with no LLM or external HTTP requests.
They add no application routes and are excluded from the normal test suite.

Prerequisites: `python3`, the Python `playwright` package, and its Chromium
browser already installed. No npm or frontend build is needed. Opt in with:

```sh
MIX_ENV=test bin/dev test --include browser test/browser/death_save_journey_test.exs
```

Run this with exclusive access to `dragonex_test`, just like the other DB
gates. Screenshots, a browser trace, and the assertion summary are retained in
the printed `/tmp/dragonex-browser-death-save-*` directory, including on failure.
`DRAGONEX_BROWSER_ARTIFACTS` can select another output directory.

The journey signs in through the normal form, opens a human at zero HP,
rejects a premature resolver closure, rolls a natural twenty, and pauses on a
scripted provider failure after the paid save. Reload and a real Game restart
preserve the one-HP result. Resuming through the browser replays the save
without another roll, heals with Second Wind, then checks pause, reload and a
second Game restart without duplicating dice, resources or the player's voice.

The starting injury and provider failure are controlled fixtures. This proves
the browser/LiveView/Game/persistence path, not real-provider obedience.
