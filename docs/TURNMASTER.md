# Dragonex — TurnMaster: el intermediario como agente

> **Tipo:** spec técnico de diseño (Fase 5). **Referencia de diseño** — la
> implementación vive en código (`lib/dragonex/turn_master*.ex`, `game.ex`) y en
> [`tecnico/01-bucle-del-agente.md`](tecnico/01-bucle-del-agente.md) /
> [`FLUJO_PARTIDA.md`](FLUJO_PARTIDA.md). La decisión (el *porqué*) es
> **`decisions.md` → D25** (estado: **Implementada**).
>
> **Discrepancias documentadas (spec vs código):**
>
> 1. **§8 `acted_this_round`:** el spec decía que la tool `give_turn_to` marca
>    el set. Eso violaría single-writer (D6). En código **el Game** marca
>    `acted_this_round` al cerrar el beat del actor (main turn), vía
>    `World.mark_acted/1` + `Session.update_state/3`. Las tools del TurnMaster
>    **solo registran** la decisión.
> 2. **Handoff a monstruos (D34):** `Session.handoff` opera sobre ids de
>    participante (`dm`, nombres de PC). Si el TurnMaster elige un monstruo
>    por nombre, el Game resuelve el controlador a `"dm"` y escribe
>    `World.current_combatant` con el nombre bruto.
> 3. **Intenciones humanas (D27):** `turnmaster_brief/4` recibe `games.intents`.
>    Un `declare/3` off-turn mientras otro humano espera re-evalúa al TM; si
>    esa re-eval no decide, el floor se queda en el waiter (no WorldDriven).

---

## 1. Visión y problema

Hoy el "intermediario" es `Dragonex.TurnPolicy.WorldDriven`
(`lib/dragonex/turn_policy/world_driven.ex`): un `TurnPolicy` **determinista**
que mantiene un cursor sobre una lista fija y lo recorre. La iniciativa se
decide una sola vez (`roll_initiative` → `World.begin_combat`, `world.ex:1564`) y
desde ahí `WorldDriven` solo avanza el índice; `Session.end_turn` hace avanzar
el cursor sincrónicamente (`game/settlement.ex:285`). Quién participa lo fija el wizard,
no el runtime.

Esto hace la partida **cuadriculada**:

- orden inmutable (sin reacciones, interrupciones, acciones preparadas),
- un turno por participante y ronda, siempre al mismo ritmo,
- el DM no puede ceder la palabra; un PC no puede "tomar la iniciativa",
- en exploración el round-robin ignora quién tiene algo que decir.

**Objetivo**: que el reparto de turnos lo decida un agente (`TurnMaster`) que
encadena turnos con tools, para que la partida tenga ritmo variable,
interacciones raras, reacciones e iniciativa robada. Prioridad absoluta: **que
sea divertida** (se asume el coste de un beat extra por turno con un modelo
barato/rápido).

## 2. Decisiones confirmadas

- **Roles**: máster (DM) + jugadores (humanos o IA PCs). TurnMaster **no** es un
  personaje; es el orquestador de turnos que se suma al DM y los jugadores.
- **Combate**: respeta el orden de iniciativa por defecto, con **excepciones**
  explícitas (reacciones, acciones preparadas, interrupciones dramáticas).
- **Cadencia**: un beat de TurnMaster antes de cada beat de actor. Se prioriza
  la fluidez sobre ahorrar tokens; el TurnMaster usa un modelo barato/rápido.
- **`WorldDriven` se conserva como red de seguridad** (fallback determinista).
- Nombre del módulo: `Dragonex.TurnMaster`.

## 3. Arquitectura — qué cambia, qué queda

| Responsabilidad | Hoy | Con TurnMaster |
|---|---|---|
| Quién actúa | `WorldDriven` (cursor) | `TurnMaster` (agente + tools) |
| Resolver la acción | motor de reglas + `controlled_by?` | **idéntico** |
| Avance del cursor | `Session.end_turn` | `Session.handoff(decision)` |
| Fallback si falla | — | `WorldDriven` (orden determinista) |

**Invariante preservado (crítico)**: solo el participante que tiene el turno
accede a las tools de resolución (`make_attack`, `cast_spell`, …). El guardia
`assert_controls` / `controlled_by?` (`tools.ex:1087`, `world.ex:205`) **no se
toca**. TurnMaster decide a quién se entrega; a partir de ahí el flujo es el
mismo de hoy.

**Otro invariante respetado: single-writer (`D6`)**. TurnMaster **nunca muta el
`World`**: sus tools solo *registran* una decisión en un recorder del beat. Es
el **`Game`** quien la ejecuta — `Session.handoff/2` para entregar el turno,
`Session.update_state/3` para cambios de escena —, exactamente el mismo patrón
que hoy usan `maybe_end_combat` y `maybe_force_combat` (`game.ex`).

**Subsistemas** (ver `tecnico/00-arquitectura.md`): TurnMaster es un agente más
en **S6** (`lib/dragonex/turn_master.ex`), con sus propias tools de orquestación
(**no** en `Dragonex.Tools`/S5, que son de resolución 5e); el reparto de turnos
pasa de ser sólo **S3** (`WorldDriven`) a S3-asistido-por-S6, con `WorldDriven`
relegado a fallback; el modelo vive en **S10** (`Models.turnmaster/0`).

```
UI           DragonexWeb.GameLive.Show                              (S1)
App          Dragonex.Game — bucle actor → turnmaster → handoff     (S2)
Motor        ExAgent.Session + TurnMaster (decide) + WorldDriven (fallback)  (S3)
Reglas       Dragonex.{Rules, World, Actions, Tools}  (sin cambios) (S4–S5)
Agentes      Dragonex.{DM, PCAgent} + Dragonex.TurnMaster           (S6)
Modelos      Dragonex.Models (rol :turnmaster)                      (S10)
Datos        Postgres (games/.../game_events) + world jsonb         (S7)
```

## 4. El agente TurnMaster

`Dragonex.TurnMaster.new(model, opts) :: ExAgent.t()` (espejo de `DM.new/2`,
`dm.ex:46`):

- **System prompt** corto y estricto: rol de director de escena. Reglas:
  1. Tu única salida es decidir quién actúa (llama a una tool), nunca narrar
     ficción ni resolver tiradas.
  2. En **combate**, sigue el `initiative_order` del brief; cede a cada
     combatiente una vez por ronda; permite excepciones solo con `cut_in` /
     `react` cuando el contexto las justifica (ataque de oportunidad, acción
     preparada, un PC interrumpiendo).
  3. En **exploración**, reparte la palabra con criterio dramático: quien tenga
     algo que decir o hacer, quien reaccione a lo último; evita el round-robin
     plano. Cede al DM para abrir/cerrar escena o narrar entorno.
  4. Equidad: no repitas al mismo actor sin motivo; no dejes a nadie sin turno.
  5. Nunca elijas a un participante inexistente, caído o ya fuera de combate.
  6. Formato: una sola tool-call por beat; sin prosa al jugador.
- **Capabilities**: publica su decisión como evento `:system` (vía una
  capability ligera tipo `Events`, `actor: "turnmaster"`). **Sin** `Events` de
  narración visible (no narra ficción). Compaction opcional (igual que el DM).
- **Modelo**: `Models.turnmaster/0` (nuevo, ver §10). Prefijo cacheable (system
  prompt estable); cola volátil = brief del turno.

## 5. Tools del TurnMaster

Definidas con `use ExAgent.Tools` (patrón de `tools.ex`). **No** proponen
cambios del `World` de combate/resolución: solo **registran la decisión**, que
el Game lee al cerrar el beat (mismo patrón que `RollLog`: un recorder por beat
direccionado por pid; patrón `RollLog` en `game/beats.ex:152`, el del TurnMaster en `:236`). 

- `give_turn_to(participant :: String.t())` — entrega la palabra/iniciativa al
  participante. Validación: existe, está vivo/consciente (o es el DM). Es la
  herramienta por defecto.
- `cut_in(participant :: String.t())` — **interrupción** (combate): el
  participante interrumpe al actor actual; recibe un mini-turno y luego el flujo
  vuelve a quien tenía la palabra. Solo si el contexto lo justifica.
- `react(participant :: String.t())` — **reacción** (p.ej. ataque de
  oportunidad, `shield` reactivo). Mini-turno fuera de orden.
- `pass_to_dm()` — cede explícitamente al máster (abrir/cerrar escena,
  entorno, voz de PNJ).
- `end_scene()` — cierra el encuentro/escena y deja el grupo en exploración.

La decisión se materializa así: la tool escribe en el recorder del beat
`%{action: :give_turn_to, to: "Lyra"}` (o `:cut_in`, `:react`, …). El Game, al
cerrar el beat de TurnMaster, lee esa decisión y aplica la transición de turno
(§6). Si el beat termina sin decisión válida → fallback (§7).

**Las tools sólo leen el `World`** (vía `ctx.deps`) para validar que el
participante existe y está consciente; **no** usan `SharedState.propose_change`.
`end_scene`/`pass_to_dm` no mutan nada ellas mismas: el Game traduce
`end_scene` a un `Session.update_state(... , World.end_combat())` (como hace hoy
`maybe_end_combat`), y `pass_to_dm` a un `Session.handoff(session, "dm")`.

## 6. Bucle nuevo — `advance/1`

El `Game` pasa a una micro-máquina de **dos fases por turno** (actor →
turnmaster). Nunca más de un beat en vuelo a la vez (invariante actual,
`game.ex:89`).

```
# estado nuevo en Game: a que fase del par estamos (:actor | :turnmaster)
advance(state):
  status != :running o busy != nil  → no-op

  current = Session.current

  if fase == :actor:
    current == nil                   → persist :ended
    ai_pc?(current)                  → beat PCAgent
    human?(current)                  → :waiting / consume intent
    true                             → beat DM
    # al cerrar OK: NO Session.end_turn; lanzar beat TurnMaster, fase := :turnmaster

  if fase == :turnmaster:
    → beat TurnMaster ("acaba de actuar <current>, decide quién sigue")
    # al cerrar OK: leer decision del recorder:
    #   give_turn_to(X) / cut_in(X) / react(X) → Session.handoff(session, X)
    #   pass_to_dm                             → Session.handoff(server, "dm")
    #   end_scene                              → World.end_combat() + handoff dm
    # append evento :system (actor "turnmaster", visible "all")
    #   p.ej. "El turno pasa a Lyra."
    # fase := :actor, next tick
```

**Primer turno / arranque**: la partida abre con un beat de TurnMaster
(`pass_to_dm` implícito o `give_turn_to` al DM) para que el máster sitúe la
escena, igual que hoy el DM auto-actúa al abrir (`rehydrate`, `game/bootstrap.ex:17`).

**Humanos**: cuando TurnMaster hace `give_turn_to` a un humano, el Game cae a
`:waiting` y espera `declare/3`. Las `intents` off-turno **no son solo un
buzón** (D27): van en el brief del TM; un declare mientras otro humano espera
re-evalúa al TM. Si esa re-eval no decide, el waiter conserva el floor. Mismo
texto dos veces no dispara otra re-eval. Un `cut_in`/`react` repetido al
mismo actor cae a fallback.

## 7. Fallback y robustez

`WorldDriven` permanece registrado como policy del `Session`; el Game la usa
**solo como cálculo de respaldo**:

- **Beat TurnMaster falla por proveedor** (5xx/429/timeout): reintento
  transitorio con backoff (patrón existente, `schedule_transient_retry` en
  `game.ex`).
- **Agota reintentos, error no transitorio, o `max_tokens`**: el Game descarta
  la decisión y pide el siguiente a `WorldDriven` (`WorldDriven` ya sabe el
  orden: iniciativa en combate, round-robin en exploración) → `handoff` a ese.
  En **combate** se appenda `:system` "El motor toma el relevo del turno.".
  En **exploración** no: opener y post-PC son `pass_to_dm` («El turno pasa al
  DM.»); un TM mudo tras el DM avanza WorldDriven con la misma nota de
  cesión, nunca «relevo» (D29).
- **Anti-bucle TurnMaster**: si la decisión repite al mismo actor que acaba de
  actuar **2 veces seguidas** sin ser `cut_in`/`react` válido → fallback a
  `WorldDriven` + nudge en el siguiente beat del TurnMaster.
- **Circuit breaker**: la misma idea de `fallback_streak` (`game/settlement.ex:32`) — si
  TurnMaster cae al fallback N veces consecutivas, se pausa con nota
  `:system` (evita un bucle silencioso de relevo determinista).

Resultado: la partida **nunca** deadloquea por un TurnMaster confundido; en
peor caso vuelve al comportamiento actual (determinista).

## 8. Combate con excepciones

- El `World` gana un campo **`acted_this_round: MapSet.t(String.t())`**
  (codec round-trip, como `facts`). Lo actualizan: la tool `give_turn_to`
  marca al actor; `cut_in`/`react` **no** gastan el turno principal del
  reactor (son mini-turnos); al cerrar la ronda se limpia.
- **Brief del TurnMaster** (sección nueva en `Brief`, `brief.ex`): lista
  `initiative_order`, `acted_this_round`, vivos/caídos y quién tiene la palabra
  ahora. El TurnMaster encadena respetando el orden y gasta un `give_turn_to`
  por combatiente hasta cerrar la ronda.
- `maybe_advance_round` (`game/combat.ex:110`) se ajusta para disparar cuando
  `acted_this_round` cubre a los combatientes conscientes (en vez del "último
  del ciclo"), reflejando que ahora TurnMaster, no el cursor, cierra la ronda.
- Reacciones/interrupciones: `cut_in`/`react` dan un mini-turno al reactor; al
  cerrarlo, el flujo vuelve al actor interrumpido (TurnMaster lo decide en su
  siguiente beat). El guardia `controlled_by?` cubre que solo el reactor use
  sus tools en ese mini-turno.

## 9. Persistencia e history

- **Decisiones como eventos**: cada handoff del TurnMaster appendea un
  `:system` `actor: "turnmaster"` `visible_to: "all"` con payload
  `%{to: "Lyra", kind: :give_turn_to}` y texto "El turno pasa a Lyra.". No hace
  falta un tipo nuevo: `:system` ya existe (`game_event.ex:22`). Opcionalmente
  `:turn` con `kind: :handoff` si se quiere agrupar visualmente.
- **History** (`lib/dragonex/history.ex`): `:system` ya se reconstruye como
  mensaje `user` `[sistema]:` (`history.ex:158`). Sin cambios: el TurnMaster
  aporta una línea breve por decisión. DM y PCs leen "el turno pasó a X" y
  mantienen coherencia.
- **Durabilidad**: la decisión vigente (current) ya se persiste en
  `games.current_participant`; el campo nuevo `acted_this_round` va dentro del
  `world` jsonb (vía `Codec`). Rehidrata sin pérdidas.

## 10. Modelos — `Models.turnmaster/0`

Nuevo rol `:turnmaster` en `lib/dragonex/models.ex`, enganchado al catálogo de
providers existente (no un env suelto):

- Una entrada `turnmaster: "<slug>"` en cada fila de `@providers` (openrouter +
  opencode), con un slug barato/rápido por defecto (flash/lite).
- `build(:turnmaster)` + `new_model(cfg, :turnmaster)` + `test_model(:turnmaster)`
  — el mismo patrón que `:dm` y `:summarizer` (`models.ex`). Cada mesa puede
  sustituirlo vía `games.ai` (como el DM, D242).
- `max_tokens` **no** vive en `Models` (que sólo expone `dm_max_tokens/0`); va
  en `TurnMaster.new/2` (~256: la salida es una tool-call, no prosa).

El prefijo (system prompt + reglas) es estable y cacheable; la cola volátil es
el brief del turno → aprovecha el prompt caching ya medido (`cached_tokens/1`).

## 11. Fases de implementación

- **Fase A — Agente TurnMaster (aislado)**: `Dragonex.TurnMaster` + tools + system
  prompt + `Models.turnmaster/0`. Tests offline con `ExAgent.Models.Test`
  (determinista, sin LLM real): las tools registran decisiones válidas/inválidas.
- **Fase B — Integración en el bucle**: micro-máquina actor→turnmaster en
  `Game.advance/1`; recorder de decisión; `Session.handoff`; **fallback
  `WorldDriven`** + anti-bucle + circuit-breaker. Tests del bucle (éxito,
  error de TurnMaster → fallback, humano en waiting).
- **Fase C — Combate con excepciones**: campo `acted_this_round` + codec; brief
  de combate del TurnMaster; `cut_in`/`react` (mini-turnos); ajuste de
  `maybe_advance_round`. Tests de combate con reacción e interrupción.
- **Fase D — Pulido y validación**: eventos `:system` legibles en la UI,
  `tecnico/01-bucle-del-agente.md` + `FLUJO_PARTIDA.md` reescritos al nuevo
  flujo, `progress.md` mueve el item a ✅, partida live de validación (ritmo,
  reacciones, ceder palabra).

## 12. Riesgos y mitigaciones

- **+1 llamada LLM por turno** → asumido por diseño (prioridad: diversión).
  Modelo barato, `max_tokens` ~256, prefijo cacheado. Latencia mitigable
  lanzando el beat en `Task` (el GenServer sigue responsive,
  `game/beats.ex:73`).
- **Deadlock / bucle del TurnMaster** → fallback `WorldDriven` + circuit-breaker
  (§7).
- **Inequidad en combate** → `acted_this_round` en el brief + regla de equidad
  del prompt + gasto obligatorio de un turno por combatiente antes de cerrar
  ronda.
- **Decisión inválida** (participante inexistente/caído) → la tool la rechaza;
  si el beat cierra sin decisión válida, fallback.
- **Regresión del motor determinista** → los 543 tests actuales siguen pasando
  porque `WorldDriven` y `controlled_by?` no se eliminan, solo se reordenan.

## 13. Tests

- **Offline (Fase A/B/C)**: con `Models.Test` scriptado. Decisiones válidas,
  rechazo de inválidas, handoff correcto, fallback al fallar TurnMaster,
  mini-turno de `react`/`cut_in` con retorno al actor, cierre de ronda por
  `acted_this_round`.
- **Bucle (Fase B)**: test del `Game` con TurnMaster + DM + 2 PCs, verify que
  el reparto sigue las decisiones del TurnMaster y cae a `WorldDriven` ante
  fallo inyectado.
- **Live (Fase D)**: `priv/live_game.exs` con una partida real: el DM narra,
  TurnMaster cede palabra con ritmo variable, un PC interrumpe en combate.

## 14. Fuera de alcance (por ahora)

- Multi-nodo (ya fuera; `ROADMAP.md`).
- TurnMaster con memoria larga propia (compaction basta mientras dure la
  partida; revisar en partidas muy largas).
- Exposición del "por qué" del TurnMaster al jugador (decisión opaca); futuro:
  mini-línea de "director" en la UI si aporta claridad.
