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
| `ability_check` | `(who, ability, dc, mode)` | `assert_controls(who)` | d20 + mod vs DC del DM (5/10/15/20). `ability` acepta un SKILL (`"stealth"`, `"Animal Handling"`… — normalizado): el motor mapea la característica, aplica la prof de la ficha y JoaT del bardo L2+ en no entrenadas (D60 / M44); ability cruda sin prof de ficha (compat) |
| `make_death_save` | `(character)` | `assert_controls(character)` | Death save: nat20 revive, nat1 doble fallo, 3/3 (M14) |
| `heal` | `(target, dice)` | — | Curación por expresión (`1d8+3`), cap max_hp, resetea death saves (M15). No toca `temp_hp` |
| `grant_temp_hp` | `(who, amount)` | DM cualquiera; PC sólo sí mismo | Otorga pg temporales sin apilar (`max` actual vs nuevo) (M23 / D36) |
| `grant_xp` | `(who, amount)` | DM | Suma XP 5e; no sube de nivel; amount > 0 (M27 / D43) |
| `drop_concentration` | `(who)` | DM cualquiera; PC sólo sí mismo | Suelta la concentración actual (M24 / D37) |
| `start_rage` | `(who)` | DM cualquiera; PC sólo sí mismo | Entra en furia (bárbaro). Rompe concentración (M26 / D42) |
| `end_rage` | `(who)` | DM cualquiera; PC sólo sí mismo | Sale de furia (M26 / D42) |
| `start_reckless` | `(who)` | DM cualquiera; PC sólo sí mismo | Reckless Attack (bárbaro). El motor aplica ventaja (M28 / D44) |
| `end_reckless` | `(who)` | DM cualquiera; PC sólo sí mismo | Sale de Reckless Attack (M28 / D44) |
| `second_wind` | `(who)` | DM cualquiera; PC sólo sí mismo | Segundo aliento (fighter): 1d10+level, 1/rest (M29 / D45) |
| `action_surge` | `(who, target, weapon, mode)` | DM cualquiera; PC sólo sí mismo | Oleada de acción (fighter L2+): 1 Acción de Ataque extra, Extra Attack D35 incluido, 1/rest (M31 / D47) |
| `flurry_of_blows` | `(who, target, mode)` | DM cualquiera; PC sólo sí mismo | Ráfaga de golpes (monje L2+): gasta 1 ki; el motor resuelve 2 golpes sin armas con el dado de artes marciales (M38 / D54) |
| `hunters_mark` | `(who, target)` | DM cualquiera; PC sólo sí mismo | Marca del cazador (explorador L2+): gasta 1 casilla de nivel 1 y concentra; el motor suma +1d6 por impacto de arma contra la presa, crit dobla (M39 / D55) |
| `cunning_action_hide` | `(who)` | DM cualquiera; PC sólo sí mismo | Astucia de pícaro (pícaro L2+): el motor tira Sigilo (1d20+DES+prof) vs la máxima percepción pasiva de enemigos conscientes (DC 10 sin enemigos); éxito → condición `hidden` (ventaja en su próximo ataque, que lo revela) (M41 / D57) |
| `create_spell_slot` | `(who, level)` | DM cualquiera; PC sólo sí mismo | Fuente de magia (hechicero L2+): convierte puntos de hechicería (coste 2/3/5/6/7) en 1 casilla de nivel 1..5 (M40 / D56) |
| `convert_to_sorcery_points` | `(who, level)` | DM cualquiera; PC sólo sí mismo | Fuente de magia (hechicero L2+): drena 1 casilla de nivel 1..5 y recupera esos puntos de hechicería, con cap al máximo (M40 / D56) |
| `divine_smite` | `(who, slot_level)` | DM cualquiera; PC sólo sí mismo | Castigo divino (paladín): arma `smite_slot` 1..5; no gasta casilla aún (M30 / D46) |
| `end_smite` | `(who)` | DM cualquiera; PC sólo sí mismo | Retira Castigo divino pendiente; no gasta casilla (M30 / D46) |
| `lay_on_hands` | `(who, target, amount)` | DM cualquiera; PC sólo `who` sí mismo (target puede ser aliado) | Manos impositoras (paladín): gasta pool, cura al target (M33 / D49) |
| `divine_sense` | `(who)` | DM cualquiera; PC sólo sí mismo | Sentido divino (paladín): gasta 1 uso y reporta celestial/fiend/undead (M36 / D52) |
| `turn_undead` | `(who)` | DM cualquiera; PC sólo sí mismo | Expulsar no-muertos (clérigo L2+): gasta Canalizar divinidad; no-muertos tiran Sabiduría o frightened (M37 / D53) |
| `bardic_inspiration` | `(who, target)` | DM cualquiera; PC sólo `who` sí mismo (target puede ser aliado) | Inspiración bárdica (bardo): gasta 1 uso, marca target inspired; el motor aplica 1d6 al primer roll (M34 / D50) |
| `arcane_recovery` | `(who)` | DM cualquiera; PC sólo sí mismo | Recuperación arcana (mago): restaura huecos gastados greedy, 1/long rest, fuera de combate (M35 / D51) |
| `wild_shape` | `(who, beast)` | DM cualquiera; PC sólo sí mismo | Forma salvaje (druida L2+): transforma en bestia del catálogo fijo `"cat"` (ND 0) / `"wolf"` (ND 1/4) / `"black_bear"` (ND 1/2, L4+); gasta 1 uso (2/rest); el motor guarda la forma original, aplica stats/armas de la bestia y conserva mental/identidad/concentración; sin conjuros en forma animal; si la bestia cae a 0 pg el motor auto-revierte con sólo el exceso de daño (M47 / D63) |
| `end_wild_shape` | `(who)` | DM cualquiera; PC sólo sí mismo | Vuelve a la forma original con los pg exactos al transformarse (M47 / D63) |
| `start_uncanny_dodge` | `(who)` | DM cualquiera; PC sólo sí mismo | Esquiva asombrosa (pícaro L5+): arma la postura; el motor reduce a la mitad (floor) el próximo daño que reciba — cualquier fuente, antes de resistencias y pg temporales — y consume la flag; armar es gratis y los descansos no la gestionan (M48 / D64) |
| `short_rest` | `(target)` | — | Hit die, fuera de combate; recarga Second Wind, Action Surge, Channel Divinity, Ki y Forma salvaje; no recarga Lay on Hands, Divine Sense, Bardic Inspiration, Arcane Recovery ni puntos de hechicería (M16 / D45 / D47 / D49 / D50 / D51 / D52 / D53 / D54 / D56 / D63) |
| `long_rest` | `(target)` | — | PG completos + slots restaurados; recarga Second Wind, Action Surge, Channel Divinity, Ki, Lay on Hands, Divine Sense, Bardic Inspiration, Arcane Recovery, puntos de hechicería y Forma salvaje; quita `inspired` (M17 / D45 / D47 / D49 / D50 / D51 / D52 / D53 / D54 / D56 / D63) |
| `roll_dice` | `(count, sides)` | — | Tirada libre NdM para el modelo |
| `end_combat` | `()` | — | Vuelve a `:exploration`; apaga raging, reckless y smite_slot en todos (D42 / D44 / D46) |

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
| **PCAgent** | `make_attack`, `cast_spell`, `ability_check`, `make_death_save`, `short_rest`, `long_rest`, `drop_concentration`, `start_rage`, `end_rage`, `start_reckless`, `end_reckless`, `second_wind`, `action_surge`, `flurry_of_blows`, `hunters_mark`, `cunning_action_hide`, `start_uncanny_dodge`, `create_spell_slot`, `convert_to_sorcery_points`, `divine_smite`, `end_smite`, `lay_on_hands`, `divine_sense`, `turn_undead`, `bardic_inspiration`, `arcane_recovery`, `wild_shape`, `end_wild_shape` | `make_attack`/`cast_spell` con `max_retries: 3`. **Nunca**: escenas, monstruos, condiciones, nivel, XP, iniciativa, end_combat |
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
