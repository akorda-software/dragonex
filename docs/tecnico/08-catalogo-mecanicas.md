# Catálogo de mecánicas 5e (M1–M29)

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
- **Simplificación**: empate por **DEX score** desc, luego **nombre** asc;
  sin d20 de desempate (D39). El roll-off extra rompería rollers fijos.
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
- **Sneak Attack (D41)**: `Progression.sneak_attack_dice/2` + primer hit
  de `Actions.attack`. Arma `finesse` o `ranged`; circunstancia
  `:advantage` o aliado consciente (mismo `side`, hp>0, no incapacitado);
  `:disadvantage` bloquea. Crítico tira 2N d6 (roller inyectado). Mismo
  `damage_type` del arma (`apply_damage/3`). Sin grid. El string
  `sneak_attack` del catálogo L1 no es la fuente de verdad.
- **Rage (D42)**: `Progression.rage_damage/1` + bonus en cada hit melee
  (`weapon.ranged != true`) si `attacker.raging`. Overlay B/P/S en
  `incoming_damage/3`. Ver M26.
- **Reckless Attack (D44)**: `attacker.reckless` + melee STR → ventaja;
  `target.reckless` → ventaja en cualquier ataque. Ver M28.
- **Tests**: `test/dragonex/rules/combat_test.exs`, `actions_test.exs`,
  `sneak_attack_test.exs`, `rage_test.exs`, `reckless_attack_test.exs`.

### M04 — Daño y críticos
- **Dónde**: `Rules.Combat.damage_roll/4`.
- **5e**: dados del arma + mod de aptitud; crítico **dobla los dados** (no el
  mod). El daño floor-0 en el world (M22).
- **Tests**: `rules/combat_test.exs`, `actions_test.exs`.

### M05 — Ventaja/desventaja (cancelación 5e)
- **Dónde**: `Rules.Conditions.combine/2` (fuentes: condiciones + `mode`
  pedido por el modelo + Reckless D44). `Actions` lo aplica en ataque,
  salvación y chequeo.
- **5e**: cualquier ventaja + cualquier desventaja = normal.
- **Tests**: `test/dragonex/rules/conditions_test.exs`, `conditions_test.exs`,
  `reckless_attack_test.exs`.

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
  `Actions.spell` consume si `level > 0`; tabla por clase (full/half-caster
  + Pact Magic warlock D40) en `spell_slots.ex`.
- **Compat**: caster **no trackeado** (bestiario, partidas viejas) → los
  hechizos SIEMPRE funcionan (backward-compat deliberado).
- **Pact Magic (D40)**: el brujo gasta un hueco de pacto (todos del mismo
  nivel, 1º–5º); short rest los restaura. Sin Mystic Arcanum ni upcast.
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
  Recarga Second Wind (`second_wind_used = false`, D45) y Action Surge
  (`action_surge_used = false`, D47).
- **Tests**: `test/dragonex/rest_test.exs`, `second_wind_test.exs`,
  `action_surge_test.exs`.

### M17 — Long rest
- **Dónde**: `Actions.long_rest/2` — PG completos + `restore_slots`.
  Recarga Second Wind (`second_wind_used = false`, D45) y Action Surge
  (`action_surge_used = false`, D47).
- **Tests**: `rest_test.exs`, `second_wind_test.exs`, `action_surge_test.exs`.

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
- **5e/simplif**: XP 5e (D43; D10 SUPERSEDED); el DM otorga con `grant_xp`
  (no auto-level, no calculadora CR); PG = dado medio+CON+racial con
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
- **Dónde**: `World.apply_damage/2` (y `/3` tras D38) absorbe `temp_hp`
  primero sobre el amount ya modificado (nunca negativo), resto a `hp`
  (floor 0). `World.apply_temp_hp/2` otorga sin
  apilar (`max(actual, nuevo)`); amount ≤ 0 → error. Tool `grant_temp_hp`
  (DM cualquiera; PC sólo sí mismo). `heal` no escribe el campo. Death
  saves / `down?` miran `hp`. Sin reloj de duración; `long_rest` no wipe.
  False Life SRD (`dice` nil): `Actions.spell` tira 1d4+4 al caster.
- **Tests**: `world_test.exs`, `healing_and_bestiary_test.exs`.

### M24 — Concentración (`concentrating`, D37)
- **Dónde**: `Character.concentrating` (Codec, default nil). Catálogo
  `Heroes.Spells.concentration?/1`. `Actions.spell` fija el campo al
  lanzar; `Actions.attack`/`spell` (daño) tira salvación CON
  DC = `max(10, div(damage, 2))` por golpe. `World.clear_concentration/1`,
  `World.set_concentration/2`. `apply_condition` de unconscious /
  incapacitated / stunned / paralyzed / petrified rompe sin tirada. hp a
  0 rompe. Tool `drop_concentration`. Sin reloj de duración; el LLM narra
  el buff.
- **Tests**: `concentration_test.exs`, `codec_test.exs`, `world_test.exs`.

### M25 — Resistencia, vulnerabilidad e inmunidad (D38)
- **Dónde**: `Character.damage_resistances` /
  `damage_vulnerabilities` / `damage_immunities` (Codec, default `[]`).
  `Character.incoming_damage/3` escala el amount. `World.apply_damage/3`
  aplica el tipo y **después** absorbe `temp_hp`. Sin tipo = daño plano.
  Orden: inmunidad → 0; resist+vuln mismo tipo se cancelan; solo resist
  `div/2`; solo vuln `*2`. `Actions.attack`/`spell` pasan
  `weapon.damage_type` / `spell.damage_type`. Skeleton SRD: vuln
  bludgeoning, immune poison. Tiefling `hellish_resistance` = fire.
  Concentración usa el daño post-resist. Sin magic vs mundane.
- **Tests**: `world_test.exs`, `actions_test.exs`, `codec_test.exs`,
  `healing_and_bestiary_test.exs`, `concentration_test.exs`.

### M26 — Rage (`raging`, D42)
- **Dónde**: `Character.raging` (Codec, default false).
  `World.start_rage/1` (sólo `class == "barbarian"`; suelta concentración),
  `World.end_rage/1`, `World.set_raging/2`. `end_combat` apaga raging en
  todos; hp a 0 y `unconscious` también. Bonus melee
  `Progression.rage_damage/1` en cada hit de `Actions.attack`. Overlay
  B/P/S en `incoming_damage/3` (no muta listas; combina D38).
  `Actions.spell` error si el caster está raging. Chequeo STR con
  ventaja. Tools `start_rage`/`end_rage`. Sin usos/día, sin reloj de
  1 minuto. Reckless es M28 / D44. El string `"rage"` del catálogo L1
  no es la fuente de verdad.
- **Tests**: `rage_test.exs`, `codec_test.exs`, `heroes/progression_test.exs`.

### M27 — Otorgar XP (`grant_xp`, D43)
- **Dónde**: `World.grant_xp/2`; tool `grant_xp` (solo DM).
- **5e**: suma `amount` > 0 a `Character.xp`. No sube de nivel, no toca
  hp/slots. Umbral PHB en `Progression` (`xp_threshold`, `can_level_up?`).
  El mensaje factual incluye total, umbral del siguiente nivel y si
  puede subir. Sin calculadora de encuentro/CR: el DM decide cuánto.
  `Accounts.grant_xp/3` (ficha persistida) no se rediseña.
- **Tests**: `world_test.exs`, `grant_xp_test.exs`.

### M28 — Reckless Attack (`reckless`, D44)
- **Dónde**: `Character.reckless` (Codec, default false).
  `World.start_reckless/1` (sólo `class == "barbarian"`),
  `World.end_reckless/1`, `World.set_reckless/2`.
  `set_current_combatant(name)` apaga reckless de ese name (inicio de
  su turno). `end_combat` apaga reckless en todos; hp a 0 y
  `unconscious` también. `Conditions.attack_mode`: melee STR del
  atacante reckless → ventaja; cualquier ataque vs target reckless →
  ventaja; `combine/2` con condiciones. Finesse con DEX mayor y ranged
  no dan ventaja al atacante. Tools `start_reckless`/`end_reckless`.
  El LLM no pasa mode a `make_attack`. Extra Attack: mismo
  `effective_mode` en todos los swings. Sin cupo/día.
- **Tests**: `reckless_attack_test.exs`, `codec_test.exs`.

### M29 — Second Wind (`second_wind_used`, D45)
- **Dónde**: `Character.second_wind_used` (Codec, default false).
  `Actions.second_wind/4` tira 1d10+level; `World.second_wind/2` aplica
  el amount (mismo path que `heal/2`: cap max_hp, death saves si hp>0)
  y marca used. Solo `class == "fighter"`. Already used → error.
  No toca `temp_hp`. Tool `second_wind` (DM cualquiera; PC sólo sí
  mismo). `short_rest`/`long_rest` ponen used=false en quien descansa.
  Sin economía de acciones (bonus action = la tool, 1/descanso).
- **Tests**: `second_wind_test.exs`, `codec_test.exs`.

### M30 — Divine Smite (`smite_slot`, D46)
- **Dónde**: `Character.smite_slot` (`nil | 1..5`, Codec, jsonb viejo → nil).
  `World.start_smite/2` (sólo `class == "paladin"`, slot 1..5, `has_slot?`);
  no consume casilla. `World.end_smite/1` idempotente.
  `Actions.attack`: primer hit melee (`weapon.ranged != true`) gasta el
  pendiente; `consume_slot` + `apply_damage` tipo `"radiant"`:
  `2d8+(slot-1)d8` (tope 5d8); `target.race` `"undead"`/`"fiend"` +1d8
  (máx 6d8). Extra Attack: solo el primer swing que acierte. Miss /
  ranged / hechizo: pendiente sigue. Expira: `end_smite`;
  `set_current_combatant(who)`; `end_combat`; hp 0; unconscious.
  Tools `divine_smite`/`end_smite` (DM cualquiera; PC sólo sí mismo).
  Sin Improved Divine Smite. Sin Great Weapon Fighting.
- **Tests**: `divine_smite_test.exs`, `codec_test.exs`.

### M31 — Action Surge (`action_surge_used`, D47)
- **Dónde**: `Character.action_surge_used` (Codec, default false).
  `Actions.action_surge/7` resuelve UNA Acción de Ataque extra vía
  `Actions.attack` (N swings Extra Attack D35). Solo `class == "fighter"`
  y nivel ≥ 2. Hit o miss marca used; error (no existe, 0 hp, sin arma,
  no fighter, L1, ya usado) no marca. Tool `action_surge(who, target,
  weapon, mode)` (DM cualquiera; PC sólo sí mismo). `short_rest`/
  `long_rest` ponen used=false. Sin L17 (2 usos). Sin Fighting Style.
  Sin Indomitable. Sin Dash/Dodge/cast vía surge.
- **Tests**: `action_surge_test.exs`, `codec_test.exs`, `progression_test.exs`.

---

## Declarado NO implementado (no son bugs — R28)

reacciones como mecánica formal (TurnMaster da interrupciones narrativas) ·
multiclase · feats. Pact Magic: **D40**. Sneak Attack: **D41**. Rage: **D42**.
Reckless Attack: **D44 / M28**. Second Wind: **D45 / M29**. Divine Smite:
**D46 / M30**. Action Surge: **D47 / M31**. XP en partida:
**D43 / M27**.
Iniciativa individual por monstruo: **D34**.
`temp_hp`: **D36 / M23**. Concentración: **D37 / M24**. Resistencias:
**D38 / M25**. Cupo de Rage/día y segundo uso de Action Surge a L17
siguen fuera.

Para que una de estas entre: ADR nuevo + mecánica `M31+` en este catálogo +
tests.

## Dados

- `Dice` (`dice.ex`) — RNG inyectable vía `dic_ex`; `roll_expr/2` parsea
  `NdM±K`. `RollLog` estructura cada tirada para el dado modal.
- **Tests**: `flows/dice_test.exs`, `roll_log_test.exs`.
