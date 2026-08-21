# Handoff — Dragonex: Fase de pulido y bug-fixing

Eres un agente que continúa **Dragonex**, un juego de D&D 5e con DM por IA sobre
**exAgent** (Elixir/Phoenix). El juego está funcional pero necesita pulido.

---

## 0) Arranque

```sh
cd /home/kukapu/dev/projects/dragonex
docker compose -f compose.dev.yml up -d   # Postgres + app en http://localhost:4035
MIX_ENV=test mix test                      # DB_PORT=5457 vía .env (runtime.exs)
```

Si la DB se cae tras un reinicio: `docker compose -f compose.dev.yml up -d` (el volumen externo `infra_postgres-data` conserva los datos).

---

## 1) Arquitectura (capas)

```
UI           DragonexWeb.LiveView — vista + input (GameLive, HeroLive)
Auth         Dragonex.Accounts + UserAuth plugs (bcrypt, session cookies)
Applicación  Dragonex.Game (GenServer por partida) — bucle, AI, espera, pausa
Motor        ExAgent.Session + Dragonex.{Rules, World, Actions, Tools, DM, TurnPolicy}
Datos        Postgres — games/characters/participants/game_events/heroes/users
Creador      Dragonex.Heroes (builder puro) — choices → Character 5e
```

**Stack:** Elixir 1.20, Phoenix 1.7/1.8, LiveView 1.2.3, Ecto 3.14, Bandit, Postgres.
Package manager: **mix** (NUNCA npm). Tests: `MIX_ENV=test mix test`.

---

## 2) Flujo del juego (end-to-end)

1. **Registro/Login** → session cookie (`/login`, `/register`, controllers)
2. **Crear héroe** (`/heroes/new`) → wizard multi-paso → `Heroes.build/1` → `Accounts.save_hero/2`
3. **Crear partida** (`/games/new`) → wizard 2 tabs:
   - Tab 1: Escenario (5 presets + custom)
   - Tab 2: Tu héroe + hasta 5 companions (IA o 🔓 abiertos)
4. **Sala de espera** (`/games/:id` con status `:configuring`):
   - Si hay slots abiertos → sala de espera con share link
   - Otros jugadores entran, eligen héroe, se unen
   - El creador pulsa "Empezar" → status `:running` → todos recargan
   - Si NO hay slots abiertos → entra directo a la mesa
5. **Mesa** (status `:running`): el DM narra, los PCs actúan en turnos, combate, exploración
6. **Pausa/Reanuda** + durable (rehidrata tras crash por `game_id`)

---

## 3) Bugs conocidos y cosas rotas

### NO arreglado todavía:
- **La partida en sí (el DM + combate)** no se ha probado apenas con LLM real. Los
  primeros errores aparecerán cuando el DM intente narrar y usar tools.
- **El DM puede confundirse** sobre quién actúa (proponer como el participante
  equivocado). El guardapolvo `controlled_by?` lo rechaza con error directivo,
  pero a veces el LLM loop falla.
- **Hechizos de curación** ahora funcionan (cure_wounds sana), pero faltan tests
  de integración completos del flujo heal → spell slot consume.
- **Auto-play**: el botón 🤖 existe pero no se ha probado en vivo.
- **El dice modal** se dispara pero no siempre se ve bien.
- **La condición `:attack` como spell kind** puede causar problemas si el hechizo
  falla (miss). Revisar `Actions.resolve_spell`.

### Cosas que medio funcionan:
- El DM narrando requiere `OPENROUTER_API_KEY` en `.env`. Sin ella usa TestModel
  (que hace lo que el script le diga, no narra de verdad).
- Los PCs IA tienen personalidades pero pueden no respetar siempre las reglas de
  "solo tú puedes actuar".
- El `world_brief` ahora muestra spell slots, condiciones y nivel, pero puede ser
  demasiado largo para algunos modelos.

### Lo que SÍ funciona bien (probado):
- Registro/login/heroes/wizard/sala de espera todo funciona.
- Crear partida con/sin slots abiertos funciona.
- Otro usuario puede unirse vía link, elegir héroe, aparecer en la sala.
- El creador puede empezar → ambos recargan a la mesa.
- Los 267 tests pasan (offline, sin LLM).

---

## 4) Módulos clave y dónde buscar

| Archivo | Qué hace | Notas |
|---|---|---|
| `lib/dragonex/game.ex` | GenServer del bucle de partida | El corazón. `advance/1` decide turnos. |
| `lib/dragonex/dm.ex` | System prompt + world_brief + tools del DM | Si el DM no narra bien, mira aquí. |
| `lib/dragonex/pc_agent.ex` | Agente de PC IA (personalidad por clase) | Tools restringidas (no DM tools). |
| `lib/dragonex/actions.ex` | Puente: intención → reglas → world | Ataques, spells (con slots), rest, conditions. |
| `lib/dragonex/tools.ex` | deftools que el LLM llama | make_attack, cast_spell, spawn_monster, rest, etc. |
| `lib/dragonex/world.ex` | Mundo + change functions + spell_slots | has_slot?, consume_slot, apply_condition, level_up |
| `lib/dragonex/heroes/` | Creador de personajes 5e (SRD) | Builder puro, sin DB ni UI. |
| `lib/dragonex/accounts.ex` | Users + heroes persistence | register, authenticate, save_hero, hero_sheet. |
| `lib/dragonex/games.ex` | Partidas en DB | create_game, create_from_wizard, join_game, list_games. |
| `lib/dragonex/scenarios.ex` | 5 escenarios predefinidos + nombres random | |
| `lib/dragonex/monsters.ex` | Bestiario (8 monstruos SRD) | goblin, kobold, bandit, skeleton, wolf, orc, hobgoblin, ogre. |
| `lib/dragonex/spell_slots.ex` | Tabla de progresión SRD 1-20 | Full + half casters. |
| `lib/dragonex/codec.ex` | World ↔ JSON | Usa `String.to_atom` (no to_existing_atom). |
| `lib/dragonex_web/live/game_live/show.ex` | La mesa + sala de espera + join | Archivo GIGANTE (~600 líneas). |
| `lib/dragonex_web/live/game_live/new.ex` | Wizard de partida (2 tabs) | |
| `lib/dragonex_web/live/hero_live/new.ex` | Creador de héroes (4 pasos) | Point-buy, spell picker. |
| `lib/dragonex_web/user_auth.ex` | Plugs + on_mount hooks | fetch_current_user, require_login. |

---

## 5) Modelo de datos

```
users:        id, email, password_hash, display_name
heroes:       id, user_id, name, race, class, level, sheet (jsonb via Codec)
games:        id, user_id, title, story_bible (jsonb), dm_style, world (jsonb),
              status (:configuring|:running|:paused|:waiting|:ended),
              round, current_participant, intents (map), open_slots (int)
participants: id, game_id, user_id (nullable), name, kind (:ai|:human), side
characters:   id, game_id, name, sheet (jsonb), kind (:ai|:human)
game_events:  id, game_id, seq, type, actor, visible_to, payload (jsonb), inserted_at
```

---

## 6) Convenciones importantes

- **NO** cambiar la forma de `Character`/`Weapon`/`Spell`/`Item` structs.
- **`String.to_atom`** en el codec (no `to_existing_atom` — los átomos pueden no estar cargados).
- Los `<select>` nativos en LiveView pierden estado al re-renderizar. Usar botones con `phx-click`.
- En function components HEEX, `@foo` solo ve los attrs pasados, no los socket assigns.
- El Game GenServer arranca con `Game.ensure_started(game_id)` y rehidrata de Postgres.
- `pc_agents` en el Game state: map de `name → pid` para PCs IA + auto-play.
- `advance/1` comprueba `ai_pc?` ANTES que `human?` (para que auto-play funcione).
- Spell slots son backward-compat: si no hay tracking, los hechizos funcionan libre.
- `open_slots > 0` → la partida se crea en `:configuring` (sala de espera).
- `open_slots == 0` → la partida arranca directo en `:running`.

---

## 7) Cómo depurar

- **Logs del server**: `mix phx.server` muestra todas las queries y eventos LiveView.
- **Tests**: `MIX_ENV=test mix test path/to/test.exs` para tests específicos.
- **iex**: `iex -S mix` para probar funciones directamente.
- **Demo de héroes**: `mix run priv/build_hero.exs` imprime un elf wizard y un dwarf fighter.
- **Live DM**: `DRAGONEX_RUN_LIVE=1 OPENROUTER_API_KEY=... mix test --include integration`

---

## 8) Prioridades de pulido

1. **Probar una partida real** con LLM (el DM narrando, combate, spells). Esto sacará
   la mayoría de bugs.
2. **Arreglar lo que el LLM haga mal** (confundirse de participante, no llamar tools,
   narrar números en vez de usar tools).
3. **Mejorar la UI de la mesa**: responsive, condition indicators, spell slot display.
4. **Mobile**: la mesa usa grid 3-col; en móvil habría que reflow.

---

## 9) Criterio de "MVP listo"

- Crear cuenta → crear héroe → crear partida → jugar con DM real → combate funciona →
  pausar → reanudar → todo persiste.
- Multiplayer: 2+ jugadores en la misma partida, cada uno con su héroe.
- PCs IA funcionan (personalidad + tools correctas + auto-play toggle).
- Spell slots, conditions, rest, level_up operativos durante la partida.

---

Tienes el prompt completo también en `BUGFIX_HANDOFF.md`. Arranca el stack, ejecuta los
tests, y empieza por jugar una partida real para ver qué se rompe.
