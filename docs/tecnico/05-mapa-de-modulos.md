# Mapa de módulos

> **Técnico · referencia.** Cada módulo con una línea de responsabilidad, agrupado
> por subsistema (ver [`00-arquitectura.md`](00-arquitectura.md)). Para la
> "forma" de structs y datos, [`02-modelo-de-datos.md`](02-modelo-de-datos.md).

## S1 · Web / LiveView — `lib/dragonex_web/`

| Módulo | Responsabilidad |
|---|---|
| `DragonexWeb.Router` | Rutas públicas (auth/lobby) + autenticadas (heroes/games/custom) |
| `DragonexWeb.UserAuth` | Plugs de auth por cookie de sesión + hooks `on_mount` |
| `DragonexWeb.UserSessionController` | Register / login / logout (controller clásico) |
| `GameLive.Index` | Lobby `/`: tus partidas + slots abiertos + borrar |
| `GameLive.New` | Wizard `/games/new`: escenario + roster + compañeros |
| `GameLive.Show` | **La mesa** `/games/:id`: feed, dados, streaming, Ajustes, sala de espera |
| `GameLive.Components` | Componentes HEEx compartidos de la mesa |
| `GameLive.RollFormat` | Formatea entradas de `RollLog` para el dado modal |
| `HeroLive.Index` / `New` / `Show` / `LevelUp` | Galería / creador 5 pasos / ficha / subida de nivel |
| `CustomContentLive` | CRUD `/mi-contenido` (armas/hechizos/objetos) |

## S2 · Partida / Game GenServer — `lib/dragonex/game.ex` + `lib/dragonex/game/`

| Módulo | Responsabilidad |
|---|---|
| `Dragonex.Game` | **El dueño de la partida.** Un `:transient` GenServer por `game_id` (Registry). Único escritor del `World`. Lanza beats como Task, persiste tras cada uno. |
| `Dragonex.Game.Supervisor` | `DynamicSupervisor` + lookup por `game_id` |
| `Dragonex.Game.Beat` | Struct del beat en vuelo + política de retry (backoff, max_tokens, transient) |
| `Dragonex.Game.PendingRetry` | Struct de un beat aparcado esperando backoff |
| `Dragonex.Game.Guardrails` | Heurísticas puras: anti-puppet, anti-repeat, anti-loop (PC), limbo, español |
| `Dragonex.Game.Instructions` | Builders de instrucciones por turno (humano/DM/post-combate/avance) |

## S3 · Motor de agentes — `ExAgent.Session` + `lib/dragonex/turn_policy/`

| Módulo | Responsabilidad |
|---|---|
| `Dragonex.TurnPolicy.WorldDriven` | `ExAgent.Session.TurnPolicy` de fallback (D25). Round-robin en exploración, iniciativa en combate. El camino principal es el TurnMaster (S6). |

(`ExAgent.Session`, `ExAgent.Server`, `ExAgent.Models.*`, `ExAgent.Tools`,
`ExAgent.Capability`, `ExAgent.Compaction` vienen de la dep `exagent`,
GitHub `kukapu/exagent` branch `main`.)

## S4 · Reglas 5e — `lib/dragonex/rules/` + `actions.ex` + `world.ex`

| Módulo | Responsabilidad |
|---|---|
| `Dragonex.Rules.Ability` | Matemática pura: modificadores y competencia por nivel |
| `Dragonex.Rules.Combat` | Resolución pura de combate (roller inyectado) |
| `Dragonex.Rules.Conditions` | Condición → ventaja/desventaja/auto-fallo en ataque, salva y chequeo (M06) |
| `Dragonex.Actions` | Puente intent→world: `attack`, `spell`, `initiative`, `death_save`, `heal`, `second_wind`, `action_surge`, `lay_on_hands`, `short_rest`, `long_rest`, `check`, `roll` (Divine Smite D46 en `attack`) |
| `Dragonex.World` | Estado + máquina de combate + mutadores (change fns) + spell slots + facts |

## S5 · Tools (API del LLM) — `lib/dragonex/tools.ex`

| Módulo | Responsabilidad |
|---|---|
| `Dragonex.Tools` | `deftool`s que el modelo invoca → `Actions`/`World` vía `SharedState.propose_change`. Guard `assert_controls/2`. |

Tools reales: `set_scene`, `establish_fact`, `roll_dice`, `roll_initiative`,
`make_attack`, `cast_spell`, `make_death_save`, `end_combat`, `short_rest`,
`long_rest`, `spawn_monster`, `heal`, `grant_temp_hp`, `grant_xp`, `drop_concentration`, `start_rage`, `end_rage`, `start_reckless`, `end_reckless`, `second_wind`, `action_surge`, `divine_smite`, `end_smite`, `lay_on_hands`, `ability_check`, `apply_condition`,
`remove_condition`, `level_up`.
Stubs legacy (sólo para tests del framework exAgent): `attack/2`, `roll/1`,
`spawn_character/2`, `next_round/0`.

## S6 · Agentes — `lib/dragonex/{dm,pc_agent,turn_master,agent,events,brief,history}.ex`

| Módulo | Responsabilidad |
|---|---|
| `Dragonex.DM` | Factory del DM + system prompt de 16 reglas + bible horneada (cacheable, `D20`) |
| `Dragonex.PCAgent` | Un agent por PC IA (+ auto-play); personalidad por clase; tools restringidas; `instruction/3` adaptativa |
| `Dragonex.TurnMaster` | Orquestador de turnos (D25): `new/2`, prompt, instruction; **no muta World** |
| `Dragonex.TurnMaster.Tools` | `give_turn_to` / `cut_in` / `react` / `pass_to_dm` / `end_scene` (registran decisión) |
| `Dragonex.TurnMaster.Decision` | Recorder por beat (patrón `RollLog`) de la decisión del TurnMaster |
| `Dragonex.Agent` | Plomería compartida de compactación (summarizer) |
| `Dragonex.Events` | `Capability`: publica cada chunk de texto → `Text.scrub` → `:narration` event + PubSub |
| `Dragonex.Brief` | Snapshot del mundo (`world_brief`, `turn_prompt`, `turnmaster_brief`) |
| `Dragonex.History` | Reconstruye el contexto compartido `[Message.t()]` desde `game_events` (`D19`) |

## S7 · Persistencia — `lib/dragonex/games.ex` + `games/` + `codec.ex` + `store/`

| Módulo | Responsabilidad |
|---|---|
| `Dragonex.Games` | **Único contexto que toca Repo para datos de partida.** CRUD games, join, save_state, append_event, sync_hero_level_up (path DB) |
| `Dragonex.Games.Game` / `Participant` / `Character` / `GameEvent` | Esquemas Ecto |
| `Dragonex.Codec` | `World ↔ jsonb` simétrico, campo a campo. `String.to_atom` aquí sí (`D8`); re-integeriza `spell_slots` |
| `Dragonex.Store.Coded` | Envoltorio `Codec` sobre ETS para `ExAgent.Store` (apenas usado; el `Game` es la durabilidad, `D3`) |

## S8 · Creador de héroes — `lib/dragonex/heroes.ex` + `heroes/`

| Módulo | Responsabilidad |
|---|---|
| `Dragonex.Heroes` | Builder PURO y offline (`D9`): choices 5e → `Character` nivel 1. Custom **inyectado** |
| `Dragonex.Heroes.Races` | 9 razas + subrazas, bonus, velocidad, rasgos |
| `Dragonex.Heroes.Classes` | 12 clases SRD: dado de golpe, aptitud primaria, saves, equipo, spellcasting |
| `Dragonex.Heroes.Backgrounds` | Backgrounds SRD (skills, idiomas, equipo, feature) |
| `Dragonex.Heroes.Scoring` | Standard array / point buy / puntuaciones explícitas |
| `Dragonex.Heroes.Equipment` | Catálogo SRD armas/armaduras/gear + `compute_ac` |
| `Dragonex.Heroes.Spells` | 42 hechizos builtin + merge con SRD |
| `Dragonex.Heroes.SRDSpells` | Carga `priv/srd/spells.es.json` (319) en compilación (`@external_resource`) |
| `Dragonex.Heroes.Catalog` | Capa display/consulta: builtin + SRD + **custom inyectado**, con `source:`. Localizado |
| `Dragonex.Heroes.LevelUp` | Subida de nivel (RAW no cura, `D11`; ASI, hechizos nuevos) |
| `Dragonex.Heroes.Progression` | Tablas puras: XP, niveles ASI `[4,8,12,16,19]`, `max_spell_level`, features |
| `Dragonex.Heroes.Translations` | i18n ES/EN del catálogo |

## S9 · Auth — `lib/dragonex/accounts.ex` + `accounts/`

| Módulo | Responsabilidad |
|---|---|
| `Dragonex.Accounts` | Users (bcrypt + timing guard), heroes (save/list/get/update/level_up), `grant_xp` (ficha persistida), custom content CRUD con **validación server-side** |
| `Dragonex.Accounts.User` / `Hero` / `CustomContent` | Esquemas. `CustomContent` expone abilities/kinds como fuente única de validación |

## S10 · Config / Modelos / Misc — `lib/dragonex/`

| Módulo | Responsabilidad |
|---|---|
| `Dragonex.Application` | Árbol de supervisión (Repo, PubSub, ModelConfig, Registry, Game.Supervisor, Endpoint) |
| `Dragonex.Models` | **Dos providers** (`openrouter`, `opencode`); modelo por rol (`dm`, `summarizer`); reasoning; catálogo live |
| `Dragonex.ModelConfig` | GenServer con overrides runtime (provider/model/reasoning) seteados desde el modal Ajustes. Efímero + app-global |
| `Dragonex.Text` | Scrubber determinista (`D7`) + `sanitize_utf8` (UTF-8 válido garantizado para Jason) |
| `Dragonex.Dice` | RNG vía `dic_ex`; `roll_expr/2` (parser NdM±K); `always/1` (test) |
| `Dragonex.RollLog` | `Agent` por beat que graba cada dado en grupos y publica en vivo |
| `Dragonex.Character` / `Weapon` / `Spell` / `Item` | Structs (la "forma" congelada, `D4`) |
| `Dragonex.Monsters` | Bestiario: 8 SRD + 2 dianas de entrenamiento |
| `Dragonex.Archetypes` | 3 PCs hardcoded (fighter Thane, wizard Lyra, rogue Vex) — fallback del roster |
| `Dragonex.Roster` | Catálogo de seleccionables para el wizard |
| `Dragonex.Scenarios` | 6 story scenarios (taberna, cripta, asedio, torre, bosque, arena) — cada uno una story bible |
| `Dragonex.I18n` | Locale global (`:es` por defecto) |
| `Dragonex.Release` | Tareas de release (migrate/rollback sin Mix) |
| `Dragonex.MapUtil` | Normalización segura de atom keys |
| `Dragonex.Repo` | Ecto repo |
