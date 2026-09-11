# Los agentes: DM y PCAgent

> **Técnico.** Cómo se construyen los dos agentes LLM, qué tools tienen, qué
> reglas siguen y cómo se mantienen coherentes entre ellos. Para el trace de
> cuándo se invocan, [`01-bucle-del-agente.md`](01-bucle-del-agente.md).

## Los tres agentes

| | **DM** (`dm.ex`) | **PCAgent** (`pc_agent.ex`) | **TurnMaster** (`turn_master.ex`) |
|---|---|---|---|
| **Cuántos** | uno por partida | uno por PC IA + auto-play | uno por partida |
| **Se construye en** | `rehydrate` | creación / `enable_auto_play` | `rehydrate` |
| **Tools** | **todas** (resolución 5e) | **restringidas** | orquestación (`give_turn_to`…) |
| **Personalidad** | 16 reglas + bible | por clase | director de escena (estricto) |
| **Lleva** | escena, PNJs, monstruos | a su personaje | **quién actúa** (no narra) |
| **Mutates World?** | vía tools de resolución | vía tools de resolución | **nunca** (solo registra) |

No comparten proceso: cada `ExAgent.Server` es independiente. La coherencia entre
ellos es **estructural**, no por charla entre agentes (ver § Coherencia). Detalle
del bucle actor→turnmaster: [`01-bucle-del-agente.md`](01-bucle-del-agente.md),
D25.

## El DM — `Dragonex.DM`

### System prompt (`dm.system_prompt/1`)

16 reglas en español. Las que más impacto tienen en el contrato:

- **#1–#2** — nunca decidas el resultado de una tirada; las tools son la única
  fuente de verdad. (`D1`.)
- **#3** — quién actúa lo decide el turno (lo impone el motor); las tools de escena
  (`roll_initiative`, `spawn_monster`, `set_scene`, `level_up`, `end_combat`) están
  exentas de la regla "sólo actúa en tu turno".
- **#5** — el combate es urgente: llama `roll_initiative` en cuanto estalla una
  pelea (con fallback del motor, `D18`, si se le olvida).
- **#10** — coherencia cura/mundo: narrar una curación **sin** llamar `heal` deja
  al personaje clavado en 0 PG.
- **#11** — avance de escena + `establish_fact` para hechos durables (`D16`).
- **#14** — narra **sólo** tu turno y tus monstruos/PNJs; nunca hagas actuar a un PC.
- **#15** — nunca reveles stats (HP/AC) a los jugadores.
- **#16** — la salida es prosa pura, sin tags `[Actor]:`, sin tablas markdown, sin
  tokens DSML.

La **story bible va horneada al final** del system prompt (`bible_section/1`,
`D20`) para que viva en el **prefijo cacheable** (los system prompts son estables;
lo que cambia cada turno es el `Brief` y el historial). Medición en su momento:
44–85% de ahorro de tokens con prompt caching (rol/providers dependientes).

### Tools del DM (`dm.tools/0`)

**Todas** las de `Dragonex.Tools`. El set de **resolución**
(`make_attack`, `cast_spell`, `ability_check`, `make_death_save`, `heal`,
`roll_initiative`) lleva `max_retries: 3` → si el modelo emite un intento inválido
(p.ej. un monstruo intentando actuar en turno de PC), el control guard
`assert_controls/2` (`tools.ex`) devuelve un error **directivo** que le dice cómo
re-emitir, y tiene hasta 3 intentos para autocorregirse.

## El PCAgent — `Dragonex.PCAgent`

### System prompt (`pc_agent.system_prompt/1`)

Identidad (nombre, raza, clase, sexo) + **personalidad por clase**
(`class_personality/1`: bárbaro = fiero, mago = curioso, pícaro = astuto, druida =
sabio, …; una cláusula por cada una de las 12 clases) + atributos + equipo + un
contrato de 11 reglas (más cortas que las del DM).

### Tools del PCAgent (`pc_agent.tools/0`)

**Restringidas**: `make_attack`, `cast_spell`, `ability_check`, `make_death_save`,
`short_rest`, `long_rest`, `drop_concentration`, `start_rage`, `end_rage`,
`start_reckless`, `end_reckless`, `second_wind`, `action_surge`, `divine_smite`, `end_smite`, `lay_on_hands`, `divine_sense`, `turn_undead`, `bardic_inspiration`, `arcane_recovery`. **No** tiene `spawn_monster`, `roll_initiative`,
`end_combat`, `set_scene`, `establish_fact`, `level_up` — un PC **actúa**, no
**arbitra**. `make_attack`/`cast_spell` llevan `max_retries: 3`.

### Instrucción por turno (`pc_agent.instruction/3`)

Es **adaptativa al estado** — es donde el motor *empuja* al PCAgent a hacer lo
correcto sin ordenárselo explícitamente:

- **Muerto** (3 fails) → narra el final, sin tools.
- **Caído** (0 hp) → sólo `make_death_save`.
- **Combate con enemigos vivos** → lista los objetivos válidos + armas/hechizos
  disponibles, y exige una tool.
- **Exploración** → actúa en personaje; tool sólo si hay riesgo real de fallo;
  nudges de proactividad, **ANTIBUCLE** y coordinación grupal.

## Guardrails (`Dragonex.Game.Guardrails`)

Funciones **puras** que cosen nudges sobre la instrucción del turno, en orden
definido dentro de `advance/1`. Son heurísticas defensivas que **no** cambian el
`World`, sólo enderezan al modelo:

| Guardrail | Qué evita |
|---|---|
| `with_dm_no_puppet_nudge` | que el DM haga actuar/hable a un PC (regla #14) |
| `with_dm_anti_repeat` | que el DM repita la misma narración |
| `with_dm_unspawned_hostile_nudge` | que el DM narre un enemigo que no está en el `World` |
| `with_dm_spanish_nudge` | que el DM se vaya al inglés |
| `with_pc_anti_loop` | que un PC IA repita la misma acción (similitud Jaccard) |
| `post_combat_limbo?` / `exploration_limbo?` | que la partida se quede estancada sin avanzar |

## Coherencia entre DM y PCAgent

No hablan entre sí. La coherencia la garantizan **tres mecanismos**:

1. **El `World`** es compartido (viven en la misma `Session`). Lo que uno muta, el
   otro lo ve en su próximo `Brief`.
2. **El historial se reconstruye** desde `game_events` en **cada** beat
   (`History.from_events/1`, `D19`) y se le pasa al agente que lleve el turno. Así
   ambos ven la misma "memoria" de lo narrado.
3. **`world.facts`** (`D16`) — hechos durables ("el mensajero entregó el pergamino",
   "Thane descubrió la puerta oculta") que se muestran en el `Brief` de **todos**
   los agentes cada turno, para que ganchos de la trama no se pierdan al truncar el
   historial.

### `Brief` y `History`

- **`Brief.world_brief/4`** (`brief.ex`) — snapshot compacto y legible del mundo
  para el LLM: fase, turno, quién controla, hechos, escena, y **una línea por
  personaje** con hp/ac/armas/slots. Es el "qué hay" ahora mismo.
- **`History.from_events/1`** (`history.ex`) — reconstruye el `[Message.t()]`
  compartido: los `:turn` cabeceras, las `:narration` Responses con `[actor]:`, las
  `:action` Requests humanas, los `:dice` como notas inline, los `:system` como
  `[sistema]:`. Coalescea runs del mismo actor; guarda 12 recientes verbatim y
  comprime las viejas a una línea.

### `Events` — la narración llega en vivo

`Dragonex.Events` (`events.ex`) es una `ExAgent.Capability`: el texto que el
modelo produce en cada request lo persiste vía `after_model_request/2` →
**`Text.scrub(text, actor)`** → `:narration` event + PubSub. El streaming
token-a-token del feed es un camino **separado** (`on_text_delta` en `run_beat`)
que sólo hace broadcast en vivo, no persiste — la persistencia la hace `Events` al
cerrar la request. Por eso `Text.scrub` (`D7`) es el cuello de botella: nada de
texto del modelo llega a disco sin pasar por él.

## Compactación

DM y PCAgent cablean `ExAgent.Compaction.Summary` cuando hay modelo summarizer
configurado (umbral 250k tokens, env `DRAGONEX_COMPACTION_THRESHOLD` → efectivamente
off con modelos de 1M ventana; `keep_recent: 12`). El summarizer es un modelo barato
flash/lite; el resumen real lo orquesta `Dragonex.Agent.summarize/5` (`agent.ex`).

## Resumen ejecutivo del contrato

> El **DM** narra y arbitra el mundo (con todas las tools). El **PCAgent** actúa
> en personaje (con tools restringidas). Ambos leen el mismo `World` + el mismo
> historial reconstruido, y ambos pasan por el mismo `Text.scrub` antes de
> persistir. El motor decide resultados y turnos; los agentes deciden **qué
> intentar** y **cómo contarlo**.
