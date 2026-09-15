# Motor de reglas 5e

> **Técnico.** Cómo se resuelve la parte *determinista* de D&D: tiradas, ataques,
> daño, salvaciones, condiciones, turnos. El invariante fundacional es `D1`: **el
> motor es la fuente de verdad, el LLM sólo narra.**

## La arquitectura en tres capas

```
Dragonex.Tools          (tools.ex)        ← lo que el LLM invoca (deftools)
      │ llama a
      ▼
Dragonex.Actions        (actions.ex)      ← puente: intent → mensaje + change_fn
      │ llama a
      ▼
Dragonex.Rules.*        (rules/)          ← matemática PURA sin estado
      │
      ▼
Dragonex.World          (world.ex)        ← estado + mutadores (change_fns)
```

- **`Rules.Ability`** (`rules/ability.ex`), **`Rules.Combat`** (`rules/combat.ex`),
  **`Rules.Skills`** (`rules/skills.ex`) y **`Rules.Upcast`** (`rules/upcast.ex`)
  son **funciones puras** sin estado. Reciben un `roller` **inyectado** → los tests
  son deterministas (`seq([...])` / `always(n)`). `Rules.Skills` es la tabla de
  las 18 skills SRD → característica (D60, normalización de input del modelo);
  `Rules.Upcast` es la tabla curada de escalado por casilla superior (D74, M58) —
  son **datos de reglas**, no orquestación, y por eso viven en `Rules`.
- **`Actions`** (`actions.ex`) es el puente: dado un *intent* (atacar, conjurar,
  curar…), lo resuelve vía `Rules` y devuelve `{:ok, mensaje_factual, change_fn}`.
  El `mensaje_factual` es lo único que el LLM ve del cálculo.
- **`World`** (`world.ex`) es el estado y sus mutadores. Cada mutador es una
  **change function** `world → {:ok, world} | {:error, reason}`, que compone
  directamente con `SharedState.propose_change/2`.

## Por qué importa el roller inyectado

El LLM no tira dados; el motor sí, pero con un `roller` que viene en `deps`. En
producción es `Dice` (vía `dic_ex`); en tests es una función que devuelve valores
fijos. Así un test puede decir "el d20 sale 20 → crítico" y afirmar el resultado
exacto. **Nunca** introduzcas un `:rand` directo en `Rules`/`Actions`/`World`:
romperías el determinismo.

La **gramática de expresiones de dados** (`NdM±K`) tiene un único parser público:
`Dice.parse_expr/1` → `{count, sides, mod}` (D77). Lo reusan `Dice.roll_expr`,
`Dice.valid?`, `Rules.Upcast` y `Actions` — nunca repliques la regex.

## Qué sabe resolver `Rules.Combat`

| Función | Resuelve |
|---|---|
| `roll_initiative/2` | d20 + dex, por combatiente |
| `attack_roll/5` | d20 (con ventaja/desventaja) + prof + mod vs AC → `:crit/:hit/:miss`; archery D48 +2 si ranged |
| `damage_roll/4` | dados del arma × multiplicador de crítico + mod de aptitud; dueling D48 +2 si melee |
| `spell_save_dc/2` | 8 + prof + mod de aptitud de conjuración |
| `spell_attack_bonus/2` | prof + mod de aptitud de conjuración |
| `saving_throw/5` | d20 + mod + prof (si la salva) vs DC; variantes `*_tagged` devuelven el desglose para el RollLog |
| `ability_check/6` | d20 + mod + prof vs DC (misma fuente de ventaja por condiciones) |
| `check_proficiency/3` | bonus de competencia de un check: expert (×2, D73) → prof → Jack of All Trades (½, bardo L2+, D60) → 0 |
| `death_save/2` | d20 (+ bonus plano, p. ej. Aura D61) → `:revive` (nat 20) / `:crit_fail` (nat 1 = 2 fallos) / `:success` / `:fail` |

`Rules.Conditions` no tira dados: calcula el modo (`:normal` / `:advantage` /
`:disadvantage`) o `:auto_fail` a partir de las condiciones del personaje y
del `mode` que pida el modelo. Tabla en M06.

## Qué hace de puente `Actions`

Cada función de `Actions` sigue el patrón `(...params, roller, roll_log) → result`
donde `result = {:ok, msg, change_fn} | {:error, reason}`. El `roll_log` graba
cada tirada para el dado modal (`RollLog`).

| Acción | Notas |
|---|---|
| `attack/7` | arma vs objetivo; ajusta modo por `Rules.Conditions.attack_mode/3`; Divine Smite D46 en el primer hit melee; defense D48 +1 CA efectiva del objetivo; Bardic Inspiration D50 en el primer swing; objetivo `hidden` → ventaja y se revela (D57); Hunter's Mark D55 +1d6 vs presa; sneak attack D41 |
| `spell/7` | rama por `spell.kind`: `:automatic` (magic missile), `:attack` (fire bolt, crit dobla dados, modo por condiciones, se trata como ranged), `:save` (mitad en éxito; DEX restrained = desventaja; STR/DEX auto-fallo si paralizado/aturdido/inconsciente/petrificado). Consume slot si `level > 0`. `cast_level` opcional → upcasting RAW vía `Rules.Upcast` (D74); aplica y consume metamagic armada (D65); Evasión D59 y resistencia/inmunidad del objetivo escalan el daño |
| `initiative/3` | tira iniciativa para todos los conscientes, ordena desc con tiebreak DEX luego nombre (`D39`) |
| `death_save/4` | rechaza muertos (3 fails), estables (3 éxitos) y no-caídos |
| `heal/5` | parsea la expresión (p.ej. `1d8+3`, gramática `Dice.parse_expr`), tope max_hp; resetea death_saves |
| `second_wind/4` | fighter: 1d10+level, 1/rest (D45); recarga en short/long rest |
| `action_surge/7` | fighter L2+: 1 Acción de Ataque extra (D47, Extra Attack D35); 1/rest |
| `flurry_of_blows/6` | monje L2+: 2 golpes sin armas por 1 ki (D54) |
| `hunters_mark/5` | ranger L2+: gasta casilla de nivel 1, concentra; +1d6 vs presa (D55) |
| `cunning_action_hide/4` | pícaro L2+: Sigilo (con expertise D73) vs percepción pasiva máxima enemiga → `hidden` (D57) |
| `start_uncanny_dodge/2` | pícaro L5+: arma la postura (mitad del próximo daño, D64) |
| `create_spell_slot/3` / `convert_to_sorcery_points/3` | hechicero L2+ Font of Magic (D56): puntos→casilla y casilla→puntos |
| `arm_metamagic/4` | hechicero L3+: arma UNA opción (empowered/heightened/twinned) gastando puntos (D65) |
| `wild_shape/3` / `end_wild_shape/2` | druida L2+: stats de la bestia (cat/wolf/black_bear, ND por nivel), revert con exceso (D63) |
| `breath_weapon/5` | dragontino racial: 1/descanso, salva DES → mitad (D70) |
| `gain_expertise/3` | pícaro L1+/bardo L3+: dobla competencia en una skill entrenada, cupo por nivel (D73) |
| `lay_on_hands/4` | paladín: gasta pool `5*level`, cura target (D49); recarga solo en long rest |
| `divine_sense/2` | paladín: gasta 1 uso y reporta celestial/fiend/undead (D52); recarga solo en long rest |
| `turn_undead/3` | clérigo L2+: gasta Canalizar divinidad; undead tiran Sabiduría o frightened (D53); recarga en short/long rest |
| `bardic_inspiration/3` | bardo: gasta 1 uso, marca target inspired (D50); el d6 se aplica en el primer roll |
| `arcane_recovery/2` | mago: restaura huecos gastados greedy, 1/long rest, fuera de combate (D51) |
| `short_rest/4` / `long_rest/2` | descanso; `short_rest` recarga ki (D54), Canalizar divinidad y aliento (D70); `long_rest` restaura slots, Lay on Hands, Divine Sense, Bardic Inspiration (y quita inspired), Arcane Recovery, usos de furia/furia implacable (D72) y Resistencia implacable (D67); ambos recargan Second Wind, Action Surge y Channel Divinity |
| `check/8` | chequeo de aptitud vs DC; modo por `Rules.Conditions.check_mode/3`; skill por nombre (tabla `Rules.Skills`, D60) con competencia/expertise/JoAT; Bardic Inspiration D50 |
| `passive_perception/1` | 10 + mod SAB (+ prof si entrenada) — la usa `cunning_action_hide` |
| `roll/5` | tirada libre NdM |

`Actions` también resuelve **pasivas raciales/de clase** que se aplican
automáticamente dentro de las rutas de arriba (sin tool propia): Evasión
(monje/rogue L7+, D59), Danger Sense (bárbaro L2+, D58), Lucky (mediano, D66),
Astucia gnoma (D71), Savage Attacks (semi-orco, D69), Indomitable (guerrero,
D68), auras del paladín (D61/D62) y las pasivas del pipeline de daño (ver
mutadores abajo).

### Guards de consciencia

`attack`, `spell` y `check` **rechazan** a un actor caído (hp ≤ 0): el motor hace
cumplir RAW (un caído no actúa), no confía en que el modelo no intente atacar desde
0 PG. Los death saves van por su propio camino (`death_save`), que sí exige hp ≤ 0.

### Críticos de spell attack

Un `:attack` spell con d20 = 20 **dobla los dados** (se tiran dos veces), igual que
un arma. Regla 5e RAW. Antes se tiraba una sola vez — bug que ya se arregló; hay
test de regresión.

### Ventaja/desventaja con mode del modelo

`Rules.Conditions` combina **dos fuentes** y aplica el principio 5e
"cualquier ventaja cancela cualquier desventaja":

- condiciones (tabla M06: poisoned/blinded/restrained/prone/paralyzed/…),
- el `mode` que el modelo pida (`:advantage`/`:disadvantage`).

Ambas se suman a un cómputo `advantage?` / `disadvantage?`; si las dos, `:normal`.
Esto evita que una condición silenciosamente pise el `mode` del modelo (o al revés).
El mismo principio cubre ataques, salvaciones y chequeos.

## `World`: el estado y sus invariantes

`World` es a la vez el struct de estado y la máquina de transición. Los
**invariantes los hace cumplir la transición**, no el modelo:

- el daño **floreorea en 0** (nunca negativo),
- no se puede dañar/curar a un personaje que no existe,
- `begin_combat` requiere fase `:exploration` y combatientes conocidos,
- el death-save tracker resuelve muerto (3 fails) / estable (3 éxitos) / revive (nat 20).

### Mutadores clave (`world.ex`)

- **Escena/hechos**: `set_scene/1`, `add_fact/1` (idempotente, cap 30 — `D16`).
- **Personajes**: `add_character/1`, `apply_damage/2` (sin tipo = plano) y
  `apply_damage/3-4` con el **pipeline de capas fijas** (D77 lo documenta en
  `world.ex`): Esquiva asombrosa mitiga el daño entrante y consume la postura
  (D64) → inmunidad/resistencia/vulnerabilidad D38 (incl. resistencia al
  veneno enana D76 y overlay de furia B/P/S D42) → absorbe `temp_hp` (D36) →
  `hp` → auto-revert de Wild Shape con exceso (D63) → Furia implacable (salva
  CON, D72) → Resistencia implacable (semi-orco, hp 0→1, D67).
  `heal/2` (no toca `temp_hp`), `apply_temp_hp/2`,
  `start_rage/1` (gasta 1 uso, D72), `end_rage/1`, `set_raging/2`,
  `start_reckless/1`, `end_reckless/1`, `set_reckless/2`,
  `second_wind/2`, `set_second_wind_used/2`, `set_action_surge_used/2`,
  `lay_on_hands/3`, `set_lay_on_hands_pool/2`, `restore_lay_on_hands/1`,
  `spend_divine_sense/1`, `set_divine_sense_uses/2`, `restore_divine_sense/1`,
  `set_channel_divinity_used/2`,
  `spend_bardic/2`, `set_inspired/2`, `restore_bardic_inspiration/1`,
  `set_arcane_recovery_used/2`, `arcane_recovery_plan/2`,
  `apply_arcane_recovery/2`,
  `start_smite/2`, `end_smite/1`, `set_smite_slot/2`,
  `spend_ki/2`, `restore_ki/1` (D54),
  `spend_sorcery_points/2`, `gain_sorcery_points/1`, `restore_sorcery_points/1`,
  `gain_slot/2` (D56),
  `transform_wild_shape/3`, `revert_wild_shape/1`, `restore_wild_shape_uses/1`
  (D63),
  `set_uncanny_dodge/2` (D64), `set_metamagic/2` (D65),
  `set_relentless_endurance/2` (D67), `set_indomitable/2` (D68),
  `set_breath_weapon_used/2` (D70),
  `set_rage_uses_used/2`, `set_relentless_rage_successes/2` (D72),
  `add_expertise/2` (D73).
- **Combate**: `begin_combat/1` (pide orden de iniciativa), `end_combat/0` (apaga raging, reckless y smite_slot),
  `set_current_combatant/1` (apaga reckless y smite_slot de ese name, D44 / D46),
  `join_initiative/1`, `apply_death_save/2`, `apply_condition/2`, `remove_condition/2`.
- **Nivel**: `level_up/2`.
- **Spell slots**: `has_slot?/3`, `consume_slot/2`, `restore_slots/1`,
  Arcane Recovery parcial (D51).
  - Backward-compat: un caster **no trackeado** (no en `spell_slots`) → los
    hechizos **siempre funcionan**. Así el sistema es compatible con partidas
    viejas o bestiario sin slots.

### ¿Cómo se prueba el motor?

Sin LLM, sin DB, sin Process. Cada mutador es una función:
`World.apply_damage("goblin", 3).(world)`. Los tests de `Rules`/`Actions`/`World`
son `async: true` y deterministas con rollers fijos (`test/dragonex/rules/`,
`test/dragonex/actions_test.exs`, `test/dragonex/world_test.exs`).

## Quién decide el turno

El turno **no** lo decide el modelo. Lo decide `TurnPolicy.WorldDriven`
(`turn_policy/world_driven.ex`), una implementación de `ExAgent.Session.TurnPolicy`
que **lee el `World`**:

- **Exploración** — round-robin entre DM + PCs.
- **Combate** — cicla `initiative_order` un combatiente a la vez (D34),
  mapeando cada nombre a su controlador (PCs → ellos mismos, enemigos → DM).
  Tres monstruos seguidos → tres beats del DM.
- `can_act?/3` sólo admite al participante actual. El cursor se resetea al cambiar
  de fase.

Esto es la mitad del `D1`: el motor no sólo calcula, también **impone el orden**.
El LLM no puede saltarse ni reordenar turnos.

## Lo que NO resuelve el motor (declarado)

Ver [`../producto/00-vision-y-alcance.md`](../producto/00-vision-y-alcance.md)
§ Fuera de alcance (reacciones / "preparar acción"; multi-nodo pausado, `D24`).
Son **simplificaciones v1 asumidas**, no bugs. Iniciativa
individual por monstruo: D34. `temp_hp`: D36. Concentración: D37.
Resistencias: D38. Rage: D42. El índice mecánico completo (M01–M60), en
[`08-catalogo-mecanicas.md`](08-catalogo-mecanicas.md).

## Lectura siguiente

- [`04-agentes-dm-y-pc.md`](04-agentes-dm-y-pc.md) — cómo el LLM llama a estas tools.
- [`01-bucle-del-agente.md`](01-bucle-del-agente.md) — dónde encaja el motor en el beat.
- [`../decisions.md`](../decisions.md) — `D1` (motor = verdad), `D39` (iniciativa), `D16` (facts).
