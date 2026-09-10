# Contrato de tools (LLM ↔ motor)

> **Técnico.** La especificación exacta de las herramientas `deftool` que el
> LLM puede invocar: firmas, quién las tiene, guardas, semántica de errores y
> reglas transversales. Es el equivalente al "contrato con el solver": si una
> tool cambia de firma o comportamiento, **este doc cambia en el mismo commit**.

Fuente canónica del código: `lib/dragonex/tools.ex` (S5), sets por agente en
`dm.ex`/`pc_agent.ex`/`turn_master/tools.ex` (S6). Las mecánicas que resuelven:
[`08-catalogo-mecanicas.md`](08-catalogo-mecanicas.md).

---

## 1. Reglas transversales (todas las tools)

1. **`ctx.deps`** — toda tool recibe el contexto del beat con:
   - `:state` — handle de `ExAgent.Session.SharedState` (proponer cambios),
   - `:roller` — fn `sides -> value` inyectada (`Dice` en prod, fija en tests),
   - `:roll_log` (opcional) — `RollLog` para el dado modal,
   - `:human_pcs` — `MapSet` de nombres de PCs humanos (lo inyecta el Game).
2. **Single-writer** (D6): una tool **nunca** muta el world; propone un
   change_fn vía `SharedState.propose_change/2`. Quien aplica es el Session.
3. **El modelo sólo ve el mensaje**: las tools devuelven `{:ok, texto}` o
   `{:error, motivo}`. El cálculo (dados, AC, HP) vive en `Rules`/`Actions`;
   el texto devuelto es factual.
4. **Guarda de control** (`assert_controls`): en las tools con actor, el actor
   debe estar **controlado por el participante actual** (`World.controlled_by?`).
   El error es **directivo** — dice exactamente quién debe actuar y cómo
   reemitir, para que el modelo se autocorrija en el retry.
5. **Sanitización** (D7): todo texto del modelo que se persiste en el world
   (`set_scene`, `establish_fact`) pasa por `Text.scrub` ANTES de proponer.
6. **Sin `:rand`** en el camino de una tool: siempre `deps.roller`.

---

## 2. Catálogo de tools de juego (`Dragonex.Tools`)

### Narrativa y mundo (DM)

| Tool | Firma | Efecto |
|---|---|---|
| `set_scene` | `(narration: String)` | Escena actual del world; scrubbed; se muestra a todos los agentes cada turno |
| `establish_fact` | `(fact: String)` | Hecho durable canónico (D16): idempotente, cap 30, scrubbed |
| `spawn_monster` | `(kind: String, name: String)` | Añade monstruo del bestiario (`Monsters`) y lo une a la iniciativa si hay combate; si `kind` no existe, lista los disponibles |

### Resolución de reglas (DM y, según tool, PC)

| Tool | Firma | Guarda | Resuelve |
|---|---|---|---|
| `roll_initiative` | `()` | — | Iniciativa de todos los conscientes + `begin_combat` (M2) |
| `make_attack` | `(attacker, target, weapon, mode)` | `assert_controls(attacker)` | Acción de Ataque: N golpes vs el mismo objetivo (Extra Attack D35 / M3); d20(+adv/dis) + prof + mod vs AC; crítico dobla dados (M3–M6) |
| `cast_spell` | `(caster, spell, target)` | `assert_controls(caster)` | Por `kind`: `:automatic` / `:attack` (crit dobla) / `:save` (mitad en éxito); consume slot si nivel > 0 (M7–M11) |
| `ability_check` | `(who, ability, dc, mode)` | `assert_controls(who)` | d20 + mod (+ prof si el DM la afirma) vs DC del DM (5/10/15/20) |
| `make_death_save` | `(character)` | `assert_controls(character)` | Death save: nat20 revive, nat1 doble fallo, 3/3 (M14) |
| `heal` | `(target, dice)` | — | Curación por expresión (`1d8+3`), cap max_hp, resetea death saves (M15). No toca `temp_hp` |
| `grant_temp_hp` | `(who, amount)` | DM cualquiera; PC sólo sí mismo | Otorga pg temporales sin apilar (`max` actual vs nuevo) (M23 / D36) |
| `short_rest` | `(target)` | — | Hit die, fuera de combate (M16) |
| `long_rest` | `(target)` | — | PG completos + slots restaurados (M17) |
| `roll_dice` | `(count, sides)` | — | Tirada libre NdM para el modelo |
| `end_combat` | `()` | — | Vuelve a `:exploration` (llamada del DM) |

### Estado de personajes (DM)

| Tool | Firma | Efecto |
|---|---|---|
| `apply_condition` | `(target, condition)` | Condición persistente (`prone`, `poisoned`, …) (M20) |
| `remove_condition` | `(target, condition)` | Quita la condición |
| `level_up` | `(target, opts)` | **Rechaza PCs humanos** (mensaje directivo → ficha). Para NPCs/PCs IA: `opts = %{"spells" => [keys], "asi" => %{"str" => 2}}`. Cupo validado por el motor (M21) |

### Stubs legado (SOLO framework tests — no usar)

`attack(target, damage)`, `roll(sides)`, `spawn_character(name, hp)`,
`next_round()`. Aplican efectos crudos sin tirar — **anulan D1** si un agente
los usa en producción. Se mantienen para los tests de capacidades de exAgent
(`tools.ex:36-77`). **Regla: jamás añadirlos al set de un agente real.**

---

## 3. Sets por agente (S6)

| Agente | Tools | Extras |
|---|---|---|
| **DM** | TODAS las de `Tools.tools()` | `make_attack`, `cast_spell`, `ability_check`, `make_death_save`, `heal`, `roll_initiative` con `max_retries: 3` (margen para autocorrección tras error directivo) |
| **PCAgent** | `make_attack`, `cast_spell`, `ability_check`, `make_death_save`, `short_rest`, `long_rest` | `make_attack`/`cast_spell` con `max_retries: 3`. **Nunca**: escenas, monstruos, condiciones, nivel, iniciativa, end_combat |
| **TurnMaster** | `{give_turn_to, cut_in, react, pass_to_dm, end_scene}` (propias, `turn_master/tools.ex`) | **Ninguna muta el world**: registran una `Decision`; el `Game` la aplica (`Session.handoff/2`/`update_state/3`). `end_scene` propone cambio de escena vía el Game, no directo |

### Semántica de las tools del TurnMaster

- `give_turn_to(participant)` — turno principal al nombrado.
- `cut_in(participant, reason)` — interrupción: mini-turno que **vuelve** al
  actor interrumpido al terminar.
- `react(participant, reason)` — reacción corta ídem.
- `pass_to_dm(reason)` — cede la palabra al DM.
- `end_scene(summary)` — cierra la escena (cambia fase/escena vía el Game).

Si el TurnMaster falla, buclea o elige un objetivo inválido → fallback
`WorldDriven` determinista + circuit breaker (D17/D25). La partida nunca
deadlockea.

**Intenciones humanas (D27):** el brief del TM incluye un bloque
`Intenciones humanas pendientes` con el texto scrubbed de `games.intents`.
No hay tool nueva: el TM usa `give_turn_to` / `cut_in` / `react` para honrarlas.
Una re-eval disparada por `declare/3` mientras otro humano espera, si el TM
no decide, **deja el floor en el waiter** (no se aplica WorldDriven).

---

## 4. Errores: taxonomía y retry

| Tipo | Ejemplo | Efecto en el agente |
|---|---|---|
| **Directivo** (guarda) | `RECHAZADO — es el turno de X…` | El modelo reemite corregido en el retry (por eso `max_retries: 3` en resolución) |
| **De mundo** | `{:error, :unknown_character}` de un change_fn | Mensaje factual; el modelo ajusta la intención |
| **De proveedor** | timeout / respuesta rota | No llega a la tool: lo maneja el beat (backoff 1s→3s→10s, máx 3; luego breaker D17) |

---

## 5. Cómo añadir una tool nueva (checklist)

1. `deftool` en `tools.ex` con **type annotations** (el JSON Schema se deriva
   de los `::`), doc clara en español para el modelo.
2. Si resuelve una mecánica: la lógica va en `Actions`/`Rules`/`World` (D1),
   la tool es sólo puente. Test determinista de la mecánica primero.
3. ¿Tiene actor? → `assert_controls`. ¿Persiste texto del modelo? → `Text.scrub`.
4. Añádela al set del agente que corresponda (`dm.ex`/`pc_agent.ex`) y decide
   su `max_retries`.
5. Actualiza ESTE doc y `08-catalogo-mecanicas` si introduce mecánica nueva.
6. Smoke test del flujo con `TestModel` si cambia el comportamiento de un beat.
