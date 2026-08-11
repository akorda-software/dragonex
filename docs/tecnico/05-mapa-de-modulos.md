# Mapa de módulos

> **Técnico · referencia.** Cada módulo con una línea de responsabilidad, agrupado
> por subsistema (ver [`00-arquitectura.md`](00-arquitectura.md)). Para la
> "forma" de structs y datos, [`02-modelo-de-datos.md`](02-modelo-de-datos.md).

## S1 · Web / LiveView — `lib/dragones_web/`

| Módulo | Responsabilidad |
|---|---|
| `DragonesWeb.Router` | Rutas públicas (auth/lobby) + autenticadas (heroes/games/custom) |
| `DragonesWeb.UserAuth` | Plugs de auth por cookie de sesión + hooks `on_mount` |
| `DragonesWeb.UserSessionController` | Register / login / logout (controller clásico) |
| `GameLive.Index` | Lobby `/`: tus partidas + slots abiertos + borrar |
| `GameLive.New` | Wizard `/games/new`: escenario + roster + compañeros |
| `GameLive.Show` | **La mesa** `/games/:id`: feed, dados, streaming, Ajustes, sala de espera |
| `GameLive.Components` | Componentes HEEx compartidos de la mesa |
| `GameLive.RollFormat` | Formatea entradas de `RollLog` para el dado modal |
| `HeroLive.Index` / `New` / `Show` / `LevelUp` | Galería / creador 5 pasos / ficha / subida de nivel |
| `CustomContentLive` | CRUD `/mi-contenido` (armas/hechizos/objetos) |

## S2 · Partida / Game GenServer — `lib/dragones/game.ex` + `lib/dragones/game/`

| Módulo | Responsabilidad |
|---|---|
| `Dragones.Game` | **El dueño de la partida.** Un `:transient` GenServer por `game_id` (Registry). Único escritor del `World`. Lanza beats como Task, persiste tras cada uno. |
| `Dragones.Game.Supervisor` | `DynamicSupervisor` + lookup por `game_id` |
| `Dragones.Game.Beat` | Struct del beat en vuelo + política de retry (backoff, max_tokens, transient) |
| `Dragones.Game.PendingRetry` | Struct de un beat aparcado esperando backoff |
| `Dragones.Game.Guardrails` | Heurísticas puras: anti-puppet, anti-repeat, anti-loop (PC), limbo, español |
| `Dragones.Game.Instructions` | Builders de instrucciones por turno (humano/DM/post-combate/avance) |

## S3 · Motor de agentes — `ExAgent.Session` + `lib/dragones/turn_policy/`

| Módulo | Responsabilidad |
|---|---|
| `Dragones.TurnPolicy.WorldDriven` | `ExAgent.Session.TurnPolicy`. Decide el turno **leyendo el `World`** (round-robin en exploración, iniciativa en combate con enemigos plagados al DM). |

(`ExAgent.Session`, `ExAgent.Server`, `ExAgent.Models.*`, `ExAgent.Tools`,
`ExAgent.Capability`, `ExAgent.Compaction` vienen de la dep `exagent`,
GitHub `kukapu/exagent` branch `main`.)

## S4 · Reglas 5e — `lib/dragones/rules/` + `actions.ex` + `world.ex`

| Módulo | Responsabilidad |
|---|---|
| `Dragones.Rules.Ability` | Matemática pura: modificadores y competencia por nivel |
| `Dragones.Rules.Combat` | Resolución pura de combate (roller inyectado) |
| `Dragones.Actions` | Puente intent→world: `attack`, `spell`, `initiative`, `death_save`, `heal`, `short_rest`, `long_rest`, `check`, `roll` |
| `Dragones.World` | Estado + máquina de combate + mutadores (change fns) + spell slots + facts |

## S5 · Tools (API del LLM) — `lib/dragones/tools.ex`

| Módulo | Responsabilidad |
|---|---|
| `Dragones.Tools` | `deftool`s que el modelo invoca → `Actions`/`World` vía `SharedState.propose_change`. Guard `assert_controls/2`. |

Tools reales: `set_scene`, `establish_fact`, `roll_dice`, `roll_initiative`,
`make_attack`, `cast_spell`, `make_death_save`, `end_combat`, `short_rest`,
`long_rest`, `spawn_monster`, `heal`, `ability_check`, `apply_condition`,
`remove_condition`, `level_up`.
Stubs legacy (sólo para tests del framework exAgent): `attack/2`, `roll/1`,
`spawn_character/2`, `next_round/0`.

## S6 · Agentes — `lib/dragones/{dm,pc_agent,agent,events,brief,history}.ex`

| Módulo | Responsabilidad |
|---|---|
| `Dragones.DM` | Factory del DM + system prompt de 16 reglas + bible horneada (cacheable, `D20`) |
| `Dragones.PCAgent` | Un agent por PC IA (+ auto-play); personalidad por clase; tools restringidas; `instruction/3` adaptativa |
| `Dragones.Agent` | Plomería compartida de compactación (summarizer) |
| `Dragones.Events` | `Capability`: publica cada chunk de texto → `Text.scrub` → `:narration` event + PubSub |
| `Dragones.Brief` | Snapshot compacto legible del mundo para el LLM (`world_brief`, `turn_prompt`) |
| `Dragones.History` | Reconstruye el contexto compartido `[Message.t()]` desde `game_events` (`D19`) |

## S7 · Persistencia — `lib/dragones/games.ex` + `games/` + `codec.ex` + `store/`

| Módulo | Responsabilidad |
|---|---|
| `Dragones.Games` | **Único contexto que toca Repo para datos de partida.** CRUD games, join, save_state, append_event, sync_hero_level_up (path DB) |
| `Dragones.Games.Game` / `Participant` / `Character` / `GameEvent` | Esquemas Ecto |
| `Dragones.Codec` | `World ↔ jsonb` simétrico, campo a campo. `String.to_atom` aquí sí (`D8`); re-integeriza `spell_slots` |
| `Dragones.Store.Coded` | Envoltorio `Codec` sobre ETS para `ExAgent.Store` (apenas usado; el `Game` es la durabilidad, `D3`) |

## S8 · Creador de héroes — `lib/dragones/heroes.ex` + `heroes/`

| Módulo | Responsabilidad |
|---|---|
| `Dragones.Heroes` | Builder PURO y offline (`D9`): choices 5e → `Character` nivel 1. Custom **inyectado** |
| `Dragones.Heroes.Races` | 9 razas + subrazas, bonus, velocidad, rasgos |
| `Dragones.Heroes.Classes` | 12 clases SRD: dado de golpe, aptitud primaria, saves, equipo, spellcasting |
| `Dragones.Heroes.Backgrounds` | Backgrounds SRD (skills, idiomas, equipo, feature) |
| `Dragones.Heroes.Scoring` | Standard array / point buy / puntuaciones explícitas |
| `Dragones.Heroes.Equipment` | Catálogo SRD armas/armaduras/gear + `compute_ac` |
| `Dragones.Heroes.Spells` | 42 hechizos builtin + merge con SRD |
| `Dragones.Heroes.SRDSpells` | Carga `priv/srd/spells.es.json` (319) en compilación (`@external_resource`) |
| `Dragones.Heroes.Catalog` | Capa display/consulta: builtin + SRD + **custom inyectado**, con `source:`. Localizado |
| `Dragones.Heroes.LevelUp` | Subida de nivel (RAW no cura, `D11`; ASI, hechizos nuevos) |
| `Dragones.Heroes.Progression` | Tablas puras: XP, niveles ASI `[4,8,12,16,19]`, `max_spell_level`, features |
| `Dragones.Heroes.Translations` | i18n ES/EN del catálogo |

## S9 · Auth — `lib/dragones/accounts.ex` + `accounts/`

| Módulo | Responsabilidad |
|---|---|
| `Dragones.Accounts` | Users (bcrypt + timing guard), heroes (save/list/get/update/level_up), `grant_xp` (latente), custom content CRUD con **validación server-side** |
| `Dragones.Accounts.User` / `Hero` / `CustomContent` | Esquemas. `CustomContent` expone abilities/kinds como fuente única de validación |

## S10 · Config / Modelos / Misc — `lib/dragones/`

| Módulo | Responsabilidad |
|---|---|
| `Dragones.Application` | Árbol de supervisión (Repo, PubSub, ModelConfig, Registry, Game.Supervisor, Endpoint) |
| `Dragones.Models` | **Dos providers** (`openrouter`, `opencode`); modelo por rol (`dm`, `summarizer`); reasoning; catálogo live |
| `Dragones.ModelConfig` | GenServer con overrides runtime (provider/model/reasoning) seteados desde el modal Ajustes. Efímero + app-global |
| `Dragones.Text` | Scrubber determinista (`D7`) + `sanitize_utf8` (UTF-8 válido garantizado para Jason) |
| `Dragones.Dice` | RNG vía `dic_ex`; `roll_expr/2` (parser NdM±K); `always/1` (test) |
| `Dragones.RollLog` | `Agent` por beat que graba cada dado en grupos y publica en vivo |
| `Dragones.Character` / `Weapon` / `Spell` / `Item` | Structs (la "forma" congelada, `D4`) |
| `Dragones.Monsters` | Bestiario: 8 SRD + 2 dianas de entrenamiento |
| `Dragones.Archetypes` | 3 PCs hardcoded (fighter Thane, wizard Lyra, rogue Vex) — fallback del roster |
| `Dragones.Roster` | Catálogo de seleccionables para el wizard |
| `Dragones.Scenarios` | 6 story scenarios (taberna, cripta, asedio, torre, bosque, arena) — cada uno una story bible |
| `Dragones.I18n` | Locale global (`:es` por defecto) |
| `Dragones.Release` | Tareas de release (migrate/rollback sin Mix) |
| `Dragones.MapUtil` | Normalización segura de atom keys |
| `Dragones.Repo` | Ecto repo |
