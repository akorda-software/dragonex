# AGENTS.md — Dragones

Guía para agentes automatizados (y humanos) que trabajan en este repo.
Léela antes de tocar nada.

## Qué es

D&D 5e con DM por IA. Elixir/Phoenix LiveView + Postgres + `exAgent` (GitHub dep
`kukapu/exagent`, branch `main`). El LLM **solo narra**; las reglas las resuelven `deftool`s.

**Lee primero**: [`docs/progress.md`](docs/progress.md) (estado),
[`docs/decisions.md`](docs/decisions.md) (porqués),
[`docs/FLUJO_PARTIDA.md`](docs/FLUJO_PARTIDA.md) (cómo funciona el bucle).

## Comandos

```sh
docker compose -f compose.dev.yml up -d   # Postgres + app en http://localhost:4035
MIX_ENV=test mix test                     # suite (543 passed). SIEMPRE con MIX_ENV=test
mix format                                # obligatorio antes de commit
mix compile                               # sin warnings
docker logs -f dragones-app               # logs
```

- **Package manager: `mix`** (NUNCA npm/npx — no hay frontend JS build propio;
  los assets de dados vienen de `dic_ex`, ya vendored en `priv/static/assets/`).
- DB para `mix phx.server` en host: `DB_PORT=5455` (`.env.dev`). App dev: **4035**, Postgres dev: **5455**.
- Sin `OPENROUTER_API_KEY` en `.env.dev`, los beats usan `TestModel` (no narran).
  Live: `DRAGONES_RUN_LIVE=1 OPENROUTER_API_KEY=... mix test --include integration`.

## Convenciones que NO se rompen

- **Single-writer**: el `World` se muta **solo** vía el `Game` GenServer
  (`declare/3`, `sync_hero_level_up/3`, …). La LiveView **nunca** escribe en
  `Repo` ni en `games.world`. Ver [`docs/decisions.md`](docs/decisions.md) D6.
- **No cambies la forma** de `Character`/`Weapon`/`Spell`/`Item`. Campos nuevos
  al `Character` → van a `Codec.encode/decode` o **no sobreviven** al jsonb. (D4, D8)
- **`Codec` usa `String.to_atom`** (no `to_existing_atom` — los átomos pueden no
  estar cargados). Fuera del codec, usa `to_existing_atom`. (D8)
- **Builder offline**: `Dragones.Heroes` y `Heroes.Catalog` **no tocan DB** (tests
  `async: true`). El contexto custom se **inyecta** (`opts[:custom]`), no se
  consulta dentro. (D9)
- **El motor es fuente de verdad**: la IA no calcula resultados. Lógica nueva de
  reglas va en `Rules`/`Actions`/`World`, y `Tools` la expone al LLM. (D1)
- **Sanitización determinística**: cualquier texto del modelo que se persista o
  se mande al history pasa por `Text.scrub`. No confíes en que el modelo obedezca
  el prompt. (D7)

## Estructura rápida

```
lib/dragones/           motor + dominio (Rules, World, Actions, Tools, DM,
                        PCAgent, Game GenServer, Games DB, Heroes creador, Accounts)
lib/dragones_web/       LiveViews (Game, Hero, CustomContent), router, auth
priv/repo/migrations/   8 migraciones
priv/srd/spells.es.json 319 hechizos SRD (regenerable: scripts/import_srd_spells.py)
docs/                   progress, decisions, FLUJO_PARTIDA, historical/
```

## Cómo se trabaja aquí

- **Estilo**: mensajes de commit tipo `fix(level-up): …` / `feat(heroes): …`.
  `mix format` antes de commit.
- **Tests**: añade tests deterministas para toda lógica nueva. Si toca LLM,
  un smoke test con `TestModel` + (opcional) uno `--include integration`.
- **Decisiones nuevas**: si tomas una decisión de diseño no trivial, añádela a
  [`docs/decisions.md`](docs/decisions.md) (formato ADR, estado Aceptada).
- **Estado de features**: al terminar una feature, actualiza
  [`docs/progress.md`](docs/progress.md) (mover entre ✅/🟡/🔴).
- **No toques** `docs/historical/` — es archivo de handoffs pasados.
