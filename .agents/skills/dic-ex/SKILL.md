---
name: dic-ex
description: >
  Use this skill when the user wants to use the `dic_ex` Hex package — the
  pixel-art 3D dice roller for Phoenix LiveView — in an Elixir/Phoenix app.
  Triggers: rolling dice, D&D notation (NdS, advantage kh1, drop dl1, explode !,
  reroll r1), integrating DicEx / DicExWeb.DiceRoller, seeding or testable
  rolls, DicEx.Result, or wiring the Three.js dice component into a LiveView.
  Also use when the user mentions dicEx, dic_ex, dice roller, tirada de dados,
  or rolling d20/d6 with modifiers.
---

# dic_ex — D&D Dice Roller for Phoenix LiveView

`dic_ex` computes D&D-style dice rolls in pure Elixir and ships an optional
Three.js + Rapier LiveView component. The roll is computed in Elixir; the 3D
tumble is theatre (or, in 3D mode, physics-is-truth).

## Setup

```elixir
# mix.exs
{:dic_ex, "~> 0.1.0"}
```

Pure rolling needs **no web deps**. The LiveView component additionally needs
`phoenix_live_view` + `jason` (both optional in dic_ex).

## Rolling (core API)

```elixir
DicEx.roll("2d20kh1 + 5")                        # %DicEx.Result{total: 23, ...} — raises on bad input
DicEx.roll_e(prompt_from_llm)                    # {:ok, result} | {:error, reason} — for untrusted input
DicEx.roll_dice(1, 20, mod: 5, advantage: true)  # programmatic (count, sides, opts)
DicEx.format(result)                             # "2d20kh1 + 5 = 23"
```

### Options

| opt | value | effect |
| --- | --- | --- |
| `:seed` | integer | reproducible sequence (private state; caller's `:rand` untouched) |
| `:rng` | module \| `{module, state}` | `DicEx.RNG.Default` (default), `DicEx.RNG.Entropy` (crypto), or `{DicEx.RNG.Deterministic, [outcomes]}` (tests) |

| `:max_dice` / `:max_sides` / `:max_length` | pos integer | parse limits (defaults 100 / 1000 / 256) |

`roll_dice/3` also takes `:mod`, `:advantage`, `:disadvantage`.

### Notation

| token | meaning |
| --- | --- |
| `NdS` | N dice of S sides (`d20` == `1d20`; `d%` == `d100`) |
| `kh[n]` / `kl[n]` | keep highest / lowest n (advantage / disadvantage) |
| `dh[n]` / `dl[n]` | drop highest / lowest n |
| `!` / `!p` | explode / explode & penetrate |
| `r<op>n` | reroll (`< <= = >= >`); `ro` = once; bare `r1` ⇒ `<=` |
| `+` / `-` | add / subtract pools or modifiers |

Only `+`/`-` compose — **no** `*`, `/`, or parentheses; a sign only before the
first term (`-1d4+5`). One reroll per pool. Examples: `8d6!dl1`, `1d20r1`,
`1d8+2d6+2`, `4d6kh2`. Rejected as never-ending: `1d6r<=6`, `1d1!`.

### Result

```elixir
%DicEx.Result{expression: "2d20kh1+5", total: 23, groups: [
  %{kind: :dice, sides: 20, subtotal: 18, modifiers: [{:keep_high, 1}],
    rolls: [%{value: 18, kept: true, exploded: false},
            %{value: 7,  kept: false, exploded: false}]},
  %{kind: :modifier, sides: nil, subtotal: 5, modifiers: [], rolls: []}
]}
```

- `DicEx.Result.to_map(result)` — JSON-ready map for LLM / client.
- `DicEx.Result.to_roll_event(result)` — exact payload the JS hook consumes.
- `DicEx.Result.kept_values(result)` — flat list of kept die values.

## LiveView component

Install assets into the host app (Phoenix 1.8 serves only bundled assets):

```bash
mix dic_ex.install   # -> assets/vendor/dic_ex.min.js, assets/css/dic_ex.css
```

Wire `assets/js/app.js` and `assets/css/app.css`:

```js
import "../vendor/dic_ex.min.js"        // sets window.DicExHooks = {DiceRoller, DiceRoller2D}
const hooks = { ...(window.DicExHooks || {}) }
```

```css
@import "./dic_ex.css";
```

Drop in and receive rolls:

```heex
<.live_component module={DicExWeb.DiceRoller} id="roller" on_roll={self()} />
```

```elixir
def handle_info({:dic_ex_rolled, %{result: result, component: id}}, socket) do
  # result is a %DicEx.Result{} — feed DicEx.Result.to_map(result) to an LLM, etc.
  {:noreply, socket}
end
```

### Component options

| opt | default | |
| --- | --- | --- |
| `:default` | `"1d20"` | initial expression |
| `:theme` | `"obsidian"` | `"obsidian"` / `"arcane"` / `"dnd"`, or a palette map (atom or string keys) |
| `:engine` | `"3d"` | `"3d"` (Three.js + Rapier) or `"2d"` (canvas); both server-authoritative |
| `:physics` | `false` | `true` ⇒ 3D landed faces become the result (client-decided, cheatable) |
| `:rng` | `nil` | RNG module or `{module, state}`; `nil` ⇒ `DicEx.RNG.Default` |
| `:limits` | `[]` | `max_dice` / `max_sides` / `max_length` |
| `:labels` | English | `%{add:, clear:, roll:, rolling:, placeholder:, input:}` |
| `:reveal_timeout` | `6000` | ms fallback reveal if the dice never settle |
| `:on_roll` | `nil` | pid / name / `{name, node}` / `{:global, _}` / `{:via, _, _}` |

## Gotchas

- **Server-authoritative by default.** Only `physics={true}` lets the 3D landed
  faces become the result, and only for d4–d20 pools without explode/reroll;
  the client then decides the outcome, so never use it where cheating matters.
- **Re-run `mix dic_ex.install` after upgrading** so the vendored JS matches the
  component (nonce/authoritative contract). For 2D-only apps import
  `dic_ex_2d.min.js` (a few KB) instead of the ~2.7 MB full bundle.
- **`roll_dice/3` advantage/disadvantage only applies when `count == 1`**; with
  a larger pool it is silently ignored (no error).
- **`Deterministic` RNG must be threaded as a tuple** —
  `{DicEx.RNG.Deterministic, [outcomes]}`; calling `.roll/1` directly raises.
  When the outcome list runs out, further rolls return `1`.
- **`mix dic_ex.install` copies to `assets/vendor` + `assets/css`**, NOT
  `priv/static`.
- **Component needs Jason.** If the host has `phoenix_live_view` but no
  `jason`, `DicExWeb.DiceRoller` is not defined — add `:jason` to the host deps.
- **Per-group `notation` is always `nil`**; only the top-level
  `result.expression` is populated.

## Rebuilding assets (package repo only)

```bash
mix dic_ex.build    # bundles assets/src -> priv/static/dic_ex.min.js
```

Consumers of the published package do not have `assets/`; run this only inside
the dic_ex repo after editing the JS source.
