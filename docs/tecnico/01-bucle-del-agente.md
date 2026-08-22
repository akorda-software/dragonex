# El bucle del agente

> **Técnico.** El corazón de Dragonex: qué pasa exactamente desde que un jugador
> declara una acción hasta que la narración llega al feed. Es la referencia
> normativa del runtime; para una versión narrativa punta-a-punta ver
> [`../FLUJO_PARTIDA.md`](../FLUJO_PARTIDA.md). Todas las `archivo:línea`
> apuntan al código real.

## Vista de 30 segundos

```
jugador declara
     │  Game.declare/3            (game.ex)
     ▼
Game GenServer encola/resuelve la intención y hace tick
     │  advance/1                 (game.ex)
     ▼
¿fase del par?  ← micro-máquina D25 (:actor | :turnmaster)
     │
     ├─ :turnmaster → beat TurnMaster (decide quién actúa)
     │                     │
     │                     ├─ tools give_turn_to / cut_in / react / pass_to_dm / end_scene
     │                     │       └─ registran decisión (Decision recorder) — NO mutan World
     │                     ▼
     │               Game aplica: Session.handoff / update_state
     │               (fallback WorldDriven si no hay decisión válida)
     │               fase := :actor, tick
     │
     └─ :actor → ¿de quién es el turno?  ← Session.current (tras handoff)
           │
           ├─ DM / PC IA  → run_beat/6  en Task (no bloquea el GenServer)
           │                     │
           │                     ├─ Brief.turn_prompt + History.from_events
           │                     ├─ ExAgent.Server.chat → modelo LLM
           │                     │       └─ tool_calls → Tools.* → Actions → World (single-writer)
           │                     ├─ Events: Text.scrub → :narration
           │                     └─ RollLog: :dice + PubSub en vivo
           │
           └─ Humano → :waiting (idle hasta declare/3)
                                │
                                ▼
          handle_beat_result (actor): NO end_turn;
          mark_acted / maybe_end_combat / maybe_advance_round;
          fase := :turnmaster, tick
```

## Paso a paso

### 1. El jugador declara — `Game.declare/3`

La LiveView (`GameLive.Show.handle_event("declare")`) llama a
`Game.declare(pid, viewer, text)`. El GenServer:

1. **Rechaza** si `viewer` no es un participante humano.
2. **Persiste la intención** en `games.intents` (`Games.save_intents`).
3. Si **es el turno** de ese humano y no hay nada en vuelo → resuelve ahora.
4. Si no → `{:ok, :queued}`. Si la partida está `:waiting` en **otro** humano
   y el texto es distinto al último que disparó una re-eval → despierta al
   TurnMaster (`loop_phase: :turnmaster`, `tm_reeval: true`, D27). Mismo texto
   dos veces = no-op (anti-spam). Si el waiter declara mientras el TM re-evalúa,
   al aparcar se consume su intent (`park_or_consume_waiter/1`).

### 2. El tick — `advance/1`

Cada beat se dispara desde `handle_info(:advance)` → `advance/1`. Un tick = un
paso; **nunca encadena más de un beat por tick**.

- Si `status != :running` o `busy != nil` → no-op.
- Si `loop_phase == :turnmaster` → lanza el beat del **TurnMaster** (D25) y sale.
- Si `loop_phase == :actor` → mira `Session.current`:
  - **`nil`** → partida terminada.
  - **PC IA** → `run_beat` del PCAgent (+ anti-loop).
  - **Humano** → consume intent o `persist(:waiting)`.
  - **DM** → `run_beat` del DM (+ guardrails).

### 3. Beat del TurnMaster

`run_turnmaster_beat/4`:

1. Brief compacto (`Brief.turnmaster_brief/4`, incluye intents humanos
   scrubbed) + `TurnMaster.instruction/3` (`pending_intents`).
2. `Decision.start/0` (recorder por beat, patrón `RollLog`).
3. `Server.chat(turnmaster, prompt, deps: %{decision, world, participants})`.
4. Al cerrar: `handle_turnmaster_result` lee la decisión y el **Game** la aplica:
   - `give_turn_to` / `pass_to_dm` → `Session.handoff/2`
   - `cut_in` / `react` → handoff + `pending_mini` (mini-turno; no marca
     `acted_this_round`). Un segundo `cut_in`/`react` al mismo actor seguido
     cae a fallback (anti-loop).
   - `end_scene` → `World.end_combat()` + handoff al DM
5. Append evento `:system` `actor: "turnmaster"` (texto legible en UI).
6. Si no hay decisión válida / error duro:
   - **re-eval (D27)** (`tm_reeval: true`): **no** avanza WorldDriven; el
     waiter conserva el floor (o se consume su intent si declaró a mitad).
   - **resto**: fallback `WorldDriven` (`Session.end_turn`) + nota de sistema.
     Circuit breaker si fallan N veces seguidas por error de proveedor.
7. `loop_phase := :actor`, tick (salvo que la re-eval haya vuelto a `:waiting`).

**Arranque**: partida nueva (`current_participant == nil`) abre en `:turnmaster`.
En exploración el primer tick **no** llama al TM: `pass_to_dm` (o un humano
con intent pendiente) y nota «El turno pasa al DM.» (D29). Rehidratación con
current ya fijado abre en `:actor`.

### 4. Beat del actor — `run_beat/6`

Igual que antes: Task no linkeado, `Brief.turn_prompt`, historial compartido
(`History.from_events`, D19), `RollLog`, `Events` + `Text.scrub` (D7).

### 5. Resolución del beat de actor

**En éxito**:

- **No** llama a `Session.end_turn` — el reparto lo hace el TurnMaster.
- `maybe_force_combat` / `maybe_end_combat` (motor).
- `mark_acted` si no es mini-turno → `world.acted_this_round`.
- `maybe_advance_round` cuando `acted_this_round` cubre el ciclo de combate
  (fallback al “último del ciclo” si el set está vacío).
- `loop_phase := :turnmaster`, persist, tick.

**En error**: retries transient / max_tokens como antes; soft fallback sigue
haciendo `end_turn` (avanza el cursor) y deja `loop_phase: :actor`.

### 6. Invariantes que no se tocan

- **Single-writer (D6)**: TurnMaster **nunca** muta el World; solo el Game.
- **`controlled_by?`**: solo el actor en turno usa tools de resolución.
- **`WorldDriven`**: sigue siendo la policy del Session y la red de seguridad.

## Resumen

> Un par **actor → turnmaster → handoff** por turno. El LLM del actor narra y
> propone acciones; el TurnMaster solo decide **quién sigue**; el motor resuelve
> reglas y aplica el World. Si el TurnMaster falla, `WorldDriven` toma el relevo.
