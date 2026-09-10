# Catálogo de mecánicas 5e (M1–M22)

> **Técnico.** Cada mecánica implementada, con identificador estable `Mxx`,
> dónde vive (módulo:función), qué regla 5e aplica, sus simplificaciones (ADR)
> y qué tests la vigilan. Es el "oráculo" de referencia: si una mecánica cambia
> de sitio o comportamiento, este doc se actualiza en el mismo commit.

Principio rector (D1): **el motor calcula, el LLM narra.** Todas las funciones
de `Rules`/`Actions` son deterministas con `roller` inyectado; los tests usan
`seq([...])`/`always(n)`. Ver estrategia de pruebas en
[`09-estrategia-pruebas.md`](09-estrategia-pruebas.md).

---

## Atributos y modificadores

### M01 — Modificadores y competencia
- **Dónde**: `Rules.Ability` (`rules/ability.ex`) — modifier, proficiency.
- **5e**: mod = floor((score−10)/2); competencia por nivel de personaje.
- **Tests**: `test/dragonex/rules/ability_test.exs`.

## Combate

### M02 — Iniciativa
- **Dónde**: `Actions.initiative/3` + `World.begin_combat/1`.
- **5e**: d20+dex por combatiente consciente; orden desc.
- **Simplificación**: empate rompe por **nombre**, no dex+roll-off (D15).
- **Extras**: `join_initiative/1` para monstruos que entran tarde (composición
  segura en exploración); `acted_this_round` para mini-turnos del TurnMaster.
- **Tests**: `actions_test.exs`, `turn_master_loop_test.exs`.

### M03 — Tirada de ataque
- **Dónde**: `Rules.Combat.attack_roll/5`; la Acción de Ataque la orquesta
  `Actions.attack/7`.
- **5e**: d20 (ventaja/desventaja = 2 dados, el mejor/peor) + prof + mod vs AC
  del defensor; nat 20 = crítico, nat 1 = fallo.
- **Extra Attack (D35)**: `Actions.attack` resuelve N tiradas contra el mismo
  objetivo (`Progression.attack_count/2`). Si el objetivo cae (hp ≤ 0), se
  omiten el resto; no hay retarget. `cast_spell` no aplica Extra Attack.
  Economía de acciones (cuántas veces el LLM llama `make_attack`) sigue fuera.
- **Tests**: `test/dragonex/rules/combat_test.exs`, `actions_test.exs`.

### M04 — Daño y críticos
- **Dónde**: `Rules.Combat.damage_roll/4`.
- **5e**: dados del arma + mod de aptitud; crítico **dobla los dados** (no el
  mod). El daño floor-0 en el world (M22).
- **Tests**: `rules/combat_test.exs`, `actions_test.exs`.

### M05 — Ventaja/desventaja (cancelación 5e)
- **Dónde**: `Rules.Conditions.combine/2` (dos fuentes: condiciones + `mode`
  pedido por el modelo). `Actions` lo aplica en ataque, salvación y chequeo.
- **5e**: cualquier ventaja + cualquier desventaja = normal.
- **Tests**: `test/dragonex/rules/conditions_test.exs`, `conditions_test.exs`.

### M06 — Condiciones → ataque / salvación / chequeo
- **Dónde**: `Rules.Conditions` (`attack_mode/3`, `save_mode/3`, `check_mode/3`);
  `Actions.attack`, `Actions.check`, `Actions.spell` (`:attack` y `:save`).
- **5e (tabla; claves de `apply_condition`)**:

  | Condición | Ataque (actor) | Ataque vs objetivo | Salvación | Chequeo |
  |---|---|---|---|---|
  | `poisoned` | desventaja | — | — | desventaja |
  | `frightened` | desventaja | — | — | desventaja |
  | `blinded` | desventaja | ventaja | — | — |
  | `restrained` | desventaja | ventaja | DEX desventaja | — |
  | `prone` | desventaja | melee ventaja / ranged desventaja | — | — |
  | `paralyzed` / `stunned` / `unconscious` / `petrified` | — | ventaja | STR/DEX auto-fallo | — |
  | `invisible` | ventaja | desventaja | — | — |

- **Auto-fallo**: STR/DEX de paralizado/aturdido/inconsciente/petrificado no
  tira; el hechizo `:save` aplica daño completo.
- **Simplificaciones v1**: `frightened` siempre (sin línea de visión a la
  fuente); cegado/sordo no auto-fallan chequeos (el motor no sabe si el
  chequeo exige vista/oído); ataques de hechizo se tratan como a distancia
  para `prone`; las death saves no son salvaciones de aptitud.
- **Tests**: `test/dragonex/rules/conditions_test.exs` (un caso por
  condición), `test/dragonex/conditions_test.exs` (cableado en Actions).

## Hechizos

### M07 — Hechizo `:automatic`
- **Dónde**: `Actions.spell/6` rama `:automatic` (p.ej. magic missile).
- **5e**: sin tirada de ataque ni salva: daño automático (dados).
- **Tests**: `actions_test.exs`, `flows/combat_loop_test.exs`.

### M08 — Hechizo `:attack`
- **Dónde**: rama `:attack` (p.ej. fire bolt) — usa `spell_attack_bonus`.
- **5e**: d20+bonus vs AC; **crítico dobla dados** (regla RAW; bug corregido,
  hay test de regresión).
- **Tests**: `actions_test.exs`.

### M09 — Hechizo `:save`
- **Dónde**: rama `:save` — `spell_save_dc` + `saving_throw`.
- **5e**: el objetivo salva; éxito = mitad de daño (si el spell lo dice).
- **Tests**: `actions_test.exs`, `flows/narration_test.exs`.

### M10 — Spell slots
- **Dónde**: `World.has_slot?/3`, `consume_slot/2`, `restore_slots/1`;
  `Actions.spell` consume si `level > 0`; tabla por clase (full/half-caster)
  en `spell_slots.ex`.
- **Compat**: caster **no trackeado** (bestiario, partidas viejas) → los
  hechizos SIEMPRE funcionan (backward-compat deliberado).
- **Simplificación**: warlock = tabla full-caster, sin Pact Magic (D12).
- **Tests**: `test/dragonex/spell_slots_test.exs`, `multi_level_test.exs`.

### M11 — Save DC y spell attack
- **Dónde**: `Rules.Combat.spell_save_dc/2`, `spell_attack_bonus/2`.
- **5e**: DC = 8+prof+mod de aptitud de conjuración del caster.
- **Tests**: `rules/combat_test.exs`.

## Salvaciones, checks y muerte

### M12 — Salvaciones
- **Dónde**: `Rules.Combat.saving_throw/5` — d20+mod(+prof si salva) vs DC.
  El modo lo decide `Rules.Conditions.save_mode/3` (M06) antes de tirar.
- **Tests**: `rules/combat_test.exs`, `conditions_test.exs`.

### M13 — Chequeos de aptitud
- **Dónde**: `Rules.Combat.ability_check/6` + `Actions.check/8` — el DM fija
  DC (5/10/15/20) y afirma competencia. El modo lo decide
  `Rules.Conditions.check_mode/3` (M06).
- **Tests**: `rules/combat_test.exs`, `conditions_test.exs`, `flows/*`.

### M14 — Death saves
- **Dónde**: `Rules.Combat.death_save/1`, `Actions.death_save/4`,
  `World.apply_death_save/2`.
- **5e**: nat 20 = revive con 1 PG; nat 1 = **2 fallos**; 3 éxitos = estable;
  3 fallos = muerto. Tracker en el world. Guards: rechaza muertos, estables y
  no-caídos.
- **Tests**: `actions_test.exs`, `world_test.exs`.

## Curación y descansos

### M15 — Curación
- **Dónde**: `Actions.heal/5` — parsea expresión (`1d8+3`), cap `max_hp`,
  **resetea death saves** al curar.
- **Tests**: `test/dragonex/healing_and_bestiary_test.exs`.

### M16 — Short rest
- **Dónde**: `Actions.short_rest/4` — gasta hit die; fuera de combate.
- **Tests**: `test/dragonex/rest_test.exs`.

### M17 — Long rest
- **Dónde**: `Actions.long_rest/2` — PG completos + `restore_slots`.
- **Tests**: `rest_test.exs`.

## Mundo y meta

### M18 — Ciclo de combate (y combate fantasma)
- **Dónde**: `World.begin_combat/1` (exige `:exploration` + combatientes),
  `end_combat/0`, `join_initiative/1`; `Game.maybe_force_combat` (D18).
- **Seguridad de red**: un beat que INTRODUCE un enemigo vivo en exploración →
  el motor tira iniciativa él mismo (compara enemies before/after para no
  disparar en el beat de setup).
- **Tests**: `test/dragonex/ghost_combat_test.exs`, `world_test.exs`.

### M19 — Escenas y hechos durables
- **Dónde**: `World.set_scene/1`, `add_fact/1` — hechos: idempotentes, cap 30,
  scrubbed (D7), visibles en el world_brief de todos los agentes (D16).
- **Tests**: `test/dragonex/world_facts_test.exs`.

### M20 — Condiciones
- **Dónde**: `World.apply_condition/2`, `remove_condition/2`; efecto en
  ataque/salva/chequeo vía M06.
- **Tests**: `conditions_test.exs`, `rules/conditions_test.exs`.

### M21 — Subida de nivel
- **Dónde**: `LevelUp.apply/2` (ficha) y `World.level_up/2` (mesa);
  `Games.sync_hero_level_up` + `Game.sync_hero_level_up` (sync a partida viva,
  D6) + `merge_character_level_up` (preserva hp dañado/conditions/slots/AC).
- **5e/simplif**: milestone sin XP (D10); PG = dado medio+CON+racial con
  retro-CON; **RAW no cura** (D11); ASI 2 pts en `[4,8,12,16,19]` cap 20, sin
  feats (D13); hechizos nuevos respetando `max_spell_level`; half-casters
  desde L2.
- **Tests**: `test/dragonex/heroes/level_up_test.exs`,
  `test/dragonex/accounts/level_up_test.exs`, `tools_level_up_test.exs`,
  `multi_level_test.exs`, `game_sync_genserver_test.exs`.

### M22 — Invariantes del world
- **Dónde**: `world.ex` — daño floor 0; no dañar/curar desconocidos;
  `begin_combat` exige fase válida; `controlled_by?/3` (quién controla a
  quién) es la base de las guardas de tools.
- **Tests**: `world_test.exs` + transversales.

### M23 — Puntos de golpe temporales (`temp_hp`, D36)
- **Dónde**: `World.apply_damage/2` absorbe `temp_hp` primero (nunca
  negativo), resto a `hp` (floor 0). `World.apply_temp_hp/2` otorga sin
  apilar (`max(actual, nuevo)`); amount ≤ 0 → error. Tool `grant_temp_hp`
  (DM cualquiera; PC sólo sí mismo). `heal` no escribe el campo. Death
  saves / `down?` miran `hp`. Sin reloj de duración; `long_rest` no wipe.
  False Life SRD (`dice` nil): `Actions.spell` tira 1d4+4 al caster.
- **Tests**: `world_test.exs`, `healing_and_bestiary_test.exs`.

---

## Declarado NO implementado (no son bugs — R28)

Concentración · resistencias/vulnerabilidades ·
reacciones como mecánica formal (TurnMaster da interrupciones narrativas) ·
multiclase · feats · Pact Magic. Iniciativa individual por monstruo: **D34**.
`temp_hp`: **D36 / M23**.

Para que una de estas entre: ADR nuevo + mecánica `M24+` en este catálogo +
tests.

## Dados

- `Dice` (`dice.ex`) — RNG inyectable vía `dic_ex`; `roll_expr/2` parsea
  `NdM±K`. `RollLog` estructura cada tirada para el dado modal.
- **Tests**: `flows/dice_test.exs`, `roll_log_test.exs`.
