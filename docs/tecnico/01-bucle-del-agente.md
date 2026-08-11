# El bucle del agente

> **Técnico.** El corazón de Dragones: qué pasa exactamente desde que un jugador
> declara una acción hasta que la narración llega al feed. Es la referencia
> normativa del runtime; para una versión narrativa punta-a-punta ver
> [`../FLUJO_PARTIDA.md`](../FLUJO_PARTIDA.md). Todas las `archivo:línea`
> apuntan al código real.

## Vista de 30 segundos

```
jugador declara
     │  Game.declare/3            (game.ex:197)
     ▼
Game GenServer encola/resuelve la intención y hace tick
     │  advance/1                 (game.ex:717)
     ▼
¿de quién es el turno?  ← TurnPolicy.WorldDriven (turn_policy/world_driven.ex)
     │
     ├─ DM / PC IA  → run_beat/6  (game.ex:1113)  en un Task aparte (no bloquea el GenServer)
     │                     │
     │                     ├─ Brief.turn_prompt   (brief.ex)   + History.from_events (history.ex)
     │                     ├─ ExAgent.Server.chat → modelo LLM
     │                     │       │
     │                     │       └─ el modelo emite tool_calls → Tools.* (tools.ex)
     │                     │              │
     │                     │              └─ Actions.* (actions.ex) → Rules.* (rules/) 
     │                     │                     │
     │                     │                     └─ propone cambio → SharedState.propose_change (tools.ex:357)
     │                     │                            │
     │                     │                            └─ World muta (world.ex)   ← single-writer
     │                     │
     │                     ├─ Events (events.ex): cada chunk de texto → Text.scrub → :narration event
     │                     └─ RollLog (roll_log.ex): cada tirada → :dice event + PubSub en vivo
     │
     └─ Humano → :waiting (idle hasta que declare/3 resuelva su intención)
                              │
                              ▼
        handle_beat_result/2 (game.ex:868): avanza turno, maybe_end_combat,
        maybe_advance_round, persist, broadcast, otro tick
```

## Paso a paso

### 1. El jugador declara — `Game.declare/3`

La LiveView (`GameLive.Show.handle_event("declare")`, `show.ex:~200`) llama a
`Game.declare(pid, viewer, text)`. El GenServer (`game.ex:197`):

1. **Rechaza** si `viewer` no es un participante humano.
2. **Persiste la intención** en `games.intents` (`Games.save_intents`) — sobrevive
   a un restart.
3. Si **es el turno** de ese humano y no hay nada en vuelo → resuelve ahora:
   añade un marcador `:turn` al timeline (`append_turn_marker`, `game.ex:829`),
   consume la intención, hace broadcast.
4. Si no → `{:ok, :queued}`; el bucle la consumirá cuando llegue su turno.

### 2. El tick — `advance/1`

Cada beat se dispara desde `handle_info(:advance)` → `advance/1` (`game.ex:717`).
Un tick = un paso; **nunca encadena más de un beat por tick** (anti-luviosidad).

- Si `status != :running` → no-op.
- Si `busy != nil` (hay beat en vuelo o aparcado para retry) → no-op.
- `Session.current` dice de quién es el turno:
  - **`nil`** → la partida terminó: `persist(:ended)`, status `:ended`.
  - **PC IA** (incluye humanos con auto-play) → marcador `:turn`; instrucción base
    de `PCAgent.instruction/3`; se le cose el anti-loop
    (`Guardrails.with_pc_anti_loop/3`); `run_beat`.
  - **Humano** → si tiene intención encolada, la consume; si no, `persist(:waiting)`
    y se idlea.
  - **DM** → marcador `:turn`; instrucción según estado
    (`dm_post_combat_instruction` / `dm_advance_instruction` / `dm_instruction`);
    se cosen los guardrails en orden: `with_dm_no_puppet_nudge`,
    `with_dm_anti_repeat`, `with_dm_unspawned_hostile_nudge`, `with_dm_spanish_nudge`
    (`game.ex:~804`); `run_beat`.

### 3. Construcción del beat — `run_beat/6`

`game.ex:1113`. El GenServer **se queda responsive**: el beat corre en
`Task.Supervisor.async_nolink(ExAgent.TaskSupervisor, …)` — un Task **no linkeado**,
así un crash del modelo se reporta como `:DOWN` y no se lleva el GenServer por delante.

1. **Elige el agente** (`agent_for`, `game.ex:~1241`): PCAgent si existe en
   `pc_agents[name]`, si no el DM.
2. **Construye el prompt**: `Brief.turn_prompt(world, participant, instruction, "dm", kinds)`
   = `"WORLD:\n<world_brief>\n\n<instruction>"`. El `world_brief` es un snapshot
   compacto y legible (fase, turno, control, hechos, escena, una línea por
   personaje con hp/ac/armas/slots).
3. **Reconstruye el historial compartido** (`game.ex:~1175`):
   `Games.list_events(game_id) |> History.from_events()`. **Esto pisa** la
   acumulación por-agente de la `Session` — es la decisión `D19` y la fuente de
   coherencia entre DM y PCAgent.
4. **Cablea callbacks**:
   - `on_roll_closed` (`game.ex:~1144`): en cuanto cierra un grupo de tiradas,
     persiste un evento `:dice` y hace broadcast `:dice_group` + `:game_updated`
     (el dado modal se anima en tiempo real).
   - `on_text_delta` (`game.ex:~1156`): broadcast de cada chunk de texto → la
     burbuja de streaming token-a-token.
5. **Construye `deps`**: `%{state: SharedState.new(session, participant), roller,
   roll_log, beat, on_text_delta, human_pcs}`.
6. **Arranca el `RollLog`** del beat (un `Agent` que graba cada dado).
7. **Lanza**: `Server.chat(agent, prompt, deps:, stream_text:, message_history:)`.
   El streaming de texto sólo se habilita para proveedores reales.
8. **`state.busy`** = `%Beat{ref, participant, phase, turn_id, instruction, retries,
   enemies_before: World.living_enemies(world)}`. `enemies_before` es para el
   combate fantasma (`D18`).

### 4. Dentro de `Server.chat` — cómo se resuelve una tool

`ExAgent.Server.chat` (en la dep `exAgent`) driva el agente contra el modelo:

1. Construye el request: system prompt (las 16 reglas del DM + story bible horneada,
   o la personalidad del PCAgent) + el user prompt (`Brief.turn_prompt`) +
   `message_history` (la reconstrucción compartida).
2. Llama al proveedor (OpenRouter u OpenCode) vía `ExAgent.Models.*`.
3. Cuando el modelo emite un `tool_call`, ExAgent lo ejecuta (con `deps` pasado).
   Ejemplo `make_attack` (`tools.ex:~102`):
   - llama `Dragones.Actions.attack/7` (`actions.ex:69`), que computa con
     `Rules.Combat` usando el **roller inyectado** (determinismo).
   - `Actions.attack` devuelve `{:ok, mensaje_factual, change_fn}`.
   - el tool **propone** el cambio: `SharedState.propose_change(state, change_fn)`
     (`tools.ex:~357`). La `Session` lo serializa contra su `shared_state` (el `World`).
   - el **control guard** `assert_controls/2` (`tools.ex:~341`) puede rechazar con
     un error *directivo* si, p.ej., un monstruo intenta actuar en el turno del PC,
     dando al modelo `max_retries: 3` para autocorregirse.
4. Cada tirada la captura el `RollLog`: el roller que devuelve `RollLog.open/5`
   graba cada dado en su grupo; `RollLog.close/5` finaliza el grupo y dispara
   `on_close` → `:dice` event + PubSub.
5. Cada chunk de texto dispara `Events.after_model_request/2` (`events.ex:37`) →
   `Text.scrub(text, actor)` (`events.ex:64`) → persiste un evento `:narration` +
   PubSub. **`Text.scrub` es el cuello de botella de sanitización** (`D7`): se
   aplica *antes* de persistir.
6. El bucle sigue hasta que el modelo devuelve una respuesta **sin** tool_calls:
   esa es la narración final, también persistida por `Events`.

### 5. Resolución del beat — `handle_beat_result/2`

`game.ex:868`. Recibe `{:ok, narration, rolls, usage}` o `{:error, reason}`,
desde `handle_info({ref, result})` (`game.ex:659`) o `handle_info({:DOWN,…})` (crash,
`game.ex:672`).

**En éxito** (`game.ex:~882`):
- `Session.end_turn(session, current)` — avanza el turno.
- Los dados ya se persistieron en vivo; la narración ya la persistió `Events`.
- `log_token_usage` (métrica de prompt-caching).
- **Combate fantasma** (`maybe_force_combat/2`, `game.ex:~1303`, `D18`): si este
  beat introdujo un enemigo vivo en exploración (compara `enemies_before` vs
  después), el **motor** tira iniciativa él mismo y emite una nota de sistema.
- **Fin de combate** (`maybe_end_combat/1`, `game.ex:~1277`): si
  `World.combat_over?/1`, pasa a exploración + nota "⚔ El combate termina."
- **Avance de ronda** (`maybe_advance_round/3`, `game.ex:~1347`).
- Respeta una pausa pedida a mitad de beat.
- Reset `fallback_streak = 0`.
- `persist(state, next_status)` + broadcast + `send(self(), :advance)`.

**En error** (`game.ex:~927`) hay **tres** ramas con dos presupuestos de retry
**independientes** que se hilvanan a través de los reintentos:

| Tipo | Condición | Acción |
|---|---|---|
| `max_tokens` y `max_token_retries < 1` | la respuesta se cortó por tamaño | borra narraciones parciales del turno; reintenta **una vez** con un preamble "SÉ BREVE" (`Beat.brief_retry_instruction`) |
| Transitorio y `transient_retries < 3` | `Beat.transient_provider_error?/1` (HTTP 5xx, timeout…) | aparca como `%PendingRetry{}`, reintentos con backoff **1s → 3s → 10s** (`Beat.transient_backoff`) |
| Otro | cualquier otra cosa | `handle_non_max_token_error`: sube `fallback_streak`, nota `:system` sanitizada, narración fallback sólo si no hubo narración previa para ese turno; **circuit breaker**: si `streak >= 4`, `persist(:paused)` y nota (`D17`) |

La narración *fallback* (`Beat.fallback_narration/2`) es prosa in-fiction: *"X
titubea y el turno pasa de largo"*. Se **suprime** si `Events` ya persistió
narración para ese `turn_id`, para evitar la contradicción *"X dijo algo… luego X
titubea"*.

### 6. ¿Cómo muta el `World`? (single-writer, `D6`)

El **único** camino para que el modelo mute el `World` es
`SharedState.propose_change(state, change_fn)` (`tools.ex:~357`), donde `change_fn`
es un mutador puro de `World` (`world.ex:152+`). La `Session` serializa la
aplicación contra su `shared_state`.

El `Game` mismo también puede mutar el `World` vía
`Session.update_state(session, actor, change_fn)` (`game.ex:~617`) — lo usa
`sync_hero_level_up` y los cambios *del motor* (`maybe_end_combat`,
`maybe_force_combat`, `maybe_advance_round`).

`Games.save_state/6` (`games.ex:646`) se llama **solo** desde el proceso `Game`
(`game.ex:~1371`), leyendo el World vivo con `Session.read_state`. Esa es la
frontera del single-writer.

## Los dos agentes y el estado compartido

- **DM** (`dm.ex`): uno por partida, se construye en `rehydrate` (`game.ex:~334`).
  Lleva los monstruos (sus turnos se pliegan sobre el del DM) y arbitra la escena.
- **PCAgent** (`pc_agent.ex`): uno por PC IA **y** uno por humano con auto-play
  (se crea en `enable_auto_play`, `game.ex:~527`).

**No comparten proceso de agente**: cada `ExAgent.Server` es independiente. La
coherencia entre ellos viene de **tres** sitios:

1. **El historial compartido** se reconstruye desde `game_events` en cada beat
   (`D19`) y se le pasa a quien sea que lleve el turno actual.
2. **`world.facts`** (hechos durables, `D16`) se muestra en el `Brief` de todos los
   agentes cada turno.
3. **El turno lo impone el motor** (`WorldDriven`), no la "iniciativa" del modelo.

→ Detalle de prompts, tools y reglas de cada agente en
[`04-agentes-dm-y-pc.md`](04-agentes-dm-y-pc.md).

## Lifecycle del beat (resumen visual)

```
advance/1 ─► run_beat/6 (Task async_nolink)
                   │
                   ├─ Éxito ─► handle_beat_result ─► end_turn + persist + tick
                   │
                   └─ Error
                        ├─ max_tokens  ─► 1 reintento "SÉ BREVE"
                        ├─ transitorio ─► PendingRetry (backoff 1s/3s/10s, máx 3)
                        └─ otro        ─► fallback (+ circuit breaker a las 4)
```

Dos presupuestos de retry **separados** por beat (`game.ex:~1119`):
`max_token_retries` (tope 1) y `transient_retries` (tope 3). El `%PendingRetry{}`
aparca `busy` **sin** ref de Task, así `advance` no le discenta un competidor y los
`{ref,_}`/`:DOWN` estalados no pueden casar (`pending_retry.ex`).

## Estados de la partida

`:configuring` → `:running` ⇄ `:waiting` ⇄ `:paused` → `:ended`.

- **`:configuring`** — slots abiertos, sala de espera. El creador pulsa "Empezar"
  → `Games.start_game/1` lo pasa a `:running`.
- **`:running`** — el bucle auto-avanza los turnos IA.
- **`:waiting`** — turno de un humano; se idlea hasta que `declare/3` resuelve una
  intención. Se persiste (sobrevive a restart).
- **`:paused`** — pausa manual; los beats IA no auto-corren. `resume` vuelve a
  `:running` y manda un tick.
- **`:ended`** — `Session.current` devolvió `nil`.

Al `rehydrate`, `:running`/`:waiting` colapsan a `:running` para que una partida
reanudada arranque el bucle (`game.ex:~389`).
