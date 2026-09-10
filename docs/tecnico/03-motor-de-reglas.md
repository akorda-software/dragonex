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

- **`Rules.Ability`** (`rules/ability.ex`) y **`Rules.Combat`** (`rules/combat.ex`)
  son **funciones puras** sin estado. Reciben un `roller` **inyectado** → los tests
  son deterministas (`seq([...])` / `always(n)`).
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

## Qué sabe resolver `Rules.Combat`

| Función | Resuelve |
|---|---|
| `roll_initiative/2` | d20 + dex, por combatiente |
| `attack_roll/5` | d20 (con ventaja/desventaja) + prof + mod vs AC → `:crit/:hit/:miss` |
| `damage_roll/4` | dados del arma × multiplicador de crítico + mod de aptitud |
| `spell_save_dc/2` | 8 + prof + mod de aptitud de conjuración |
| `spell_attack_bonus/2` | prof + mod de aptitud de conjuración |
| `saving_throw/5` | d20 + mod + prof (si la salva) vs DC |
| `ability_check/6` | d20 + mod + prof vs DC |
| `death_save/1` | d20 → `:revive` (nat 20) / `:crit_fail` (nat 1 = 2 fallos) / `:success` / `:fail` |

`Rules.Conditions` no tira dados: calcula el modo (`:normal` / `:advantage` /
`:disadvantage`) o `:auto_fail` a partir de las condiciones del personaje y
del `mode` que pida el modelo. Tabla en M06.

## Qué hace de puente `Actions`

Cada función de `Actions` sigue el patrón `(...params, roller, roll_log) → result`
donde `result = {:ok, msg, change_fn} | {:error, reason}`. El `roll_log` graba
cada tirada para el dado modal (`RollLog`).

| Acción | Notas |
|---|---|
| `attack/7` | arma vs objetivo; ajusta modo por `Rules.Conditions.attack_mode/3` |
| `spell/6` | rama por `spell.kind`: `:automatic` (magic missile), `:attack` (fire bolt, crit dobla dados, modo por condiciones, se trata como ranged), `:save` (mitad en éxito; DEX restrained = desventaja; STR/DEX auto-fallo si paralizado/aturdido/inconsciente/petrificado). Consume slot si `level > 0`. |
| `initiative/3` | tira iniciativa para todos los conscientes, ordena desc con tiebreak por nombre (`D15`) |
| `death_save/4` | rechaza muertos (3 fails), estables (3 éxitos) y no-caídos |
| `heal/5` | parsea la expresión (p.ej. `1d8+3`), tope max_hp; resetea death_saves |
| `short_rest/4` / `long_rest/2` | descanso; `long_rest` restaura slots |
| `check/8` | chequeo de aptitud vs DC; modo por `Rules.Conditions.check_mode/3` |
| `roll/5` | tirada libre NdM |

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
- **Personajes**: `add_character/1`, `apply_damage/2` (absorbe `temp_hp`
  primero, D36), `heal/2` (no toca `temp_hp`), `apply_temp_hp/2`.
- **Combate**: `begin_combat/1` (pide orden de iniciativa), `end_combat/0`,
  `join_initiative/1`, `apply_death_save/2`, `apply_condition/2`, `remove_condition/2`.
- **Nivel**: `level_up/2`.
- **Spell slots**: `has_slot?/3`, `consume_slot/2`, `restore_slots/1`.
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

Ver [`../progress.md`](../progress.md) § 🔴 y [`../producto/00-vision-y-alcance.md`](../producto/00-vision-y-alcance.md) § Fuera de alcance:
concentración, resistencias/vulnerabilidades, reacciones.
Son **simplificaciones v1 asumidas**, no bugs. Iniciativa individual por
monstruo: D34. `temp_hp`: D36.

## Lectura siguiente

- [`04-agentes-dm-y-pc.md`](04-agentes-dm-y-pc.md) — cómo el LLM llama a estas tools.
- [`01-bucle-del-agente.md`](01-bucle-del-agente.md) — dónde encaja el motor en el beat.
- [`../decisions.md`](../decisions.md) — `D1` (motor = verdad), `D15` (iniciativa), `D16` (facts).
