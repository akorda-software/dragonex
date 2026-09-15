# Catálogo de mecánicas 5e (M1–M43)

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
- **Fighting Style (D48)**: archery +2 al total si `weapon.ranged`;
  defense +1 CA efectiva del objetivo de `Actions.attack` (no muta
  `Character.ac`); dueling +2 al daño si melee. Ver M32.
- **Tests**: `test/dragonex/rules/combat_test.exs`, `actions_test.exs`,
  `sneak_attack_test.exs`, `rage_test.exs`, `reckless_attack_test.exs`,
  `fighting_style_test.exs`.

### M04 — Daño y críticos
- **Dónde**: `Rules.Combat.damage_roll/4`.
- **5e**: dados del arma + mod de aptitud; crítico **dobla los dados** (no el
  mod). El daño floor-0 en el world (M22). Dueling (D48): +2 si melee.
- **Tests**: `rules/combat_test.exs`, `actions_test.exs`, `fighting_style_test.exs`.

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
  | `hidden` (D57) | ventaja | — | — | — |

- **Auto-fallo**: STR/DEX de paralizado/aturdido/inconsciente/petrificado no
  tira; el hechizo `:save` aplica daño completo.
- **Danger Sense (D58 / M42)**: fuente de ventaja no-condición que entra en
  `save_mode` — bárbaro L2+ → ventaja en salvaciones de DES (cancelable por
  desventaja de condición vía `combine`); el auto-fallo de arriba es el corte
  de incapacitación.
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
  **Evasión (D59 / M43)**: pícaro L7+ → éxito = 0 daño, fallo = mitad
  (sólo saves de DES; el desglose añade "(Evasión: …)").
- **Tests**: `actions_test.exs`, `flows/narration_test.exs`, `evasion_test.exs`.

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
  DC (5/10/15/20). El modo lo decide `Rules.Conditions.check_mode/3` (M06).
  Desde D60/M44 el tercer parámetro acepta un SKILL ("stealth",
  "Animal Handling"…): el motor mapea la característica y aplica la prof de
  la ficha (+ JoaT del bardo L2+ en no entrenadas).
- **Tests**: `rules/combat_test.exs`, `conditions_test.exs`, `flows/*`,
  `skill_checks_test.exs`.

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
  Recarga Second Wind (`second_wind_used = false`, D45), Action Surge
  (`action_surge_used = false`, D47) y Channel Divinity
  (`channel_divinity_used = false`, D53). No recarga Lay on Hands (D49)
  ni Divine Sense (D52).
- **Tests**: `test/dragonex/rest_test.exs`, `second_wind_test.exs`,
  `action_surge_test.exs`, `lay_on_hands_test.exs`, `divine_sense_test.exs`,
  `turn_undead_test.exs`.

### M17 — Long rest
- **Dónde**: `Actions.long_rest/2` — PG completos + `restore_slots`.
  Recarga Second Wind (`second_wind_used = false`, D45), Action Surge
  (`action_surge_used = false`, D47) y Channel Divinity
  (`channel_divinity_used = false`, D53). Recarga Lay on Hands del paladín
  a `5 * level` (D49) y Divine Sense a `max(1, 1 + cha_mod)` (D52); no
  lo hace `compose_rest/3` a ciegas.
- **Tests**: `rest_test.exs`, `second_wind_test.exs`, `action_surge_test.exs`,
  `lay_on_hands_test.exs`, `divine_sense_test.exs`, `turn_undead_test.exs`.

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
  ventaja. Tools `start_rage`/`end_rage`. Cupo por descanso largo en
  **M56 / D72** (`rage_uses_used`); sigue sin reloj de 1 minuto.
  Reckless es M28 / D44. El string `"rage"` del catálogo L1
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
   `long_rest` ponen used=false. Sin L17 (2 usos). Sin Indomitable.
   Sin Dash/Dodge/cast vía surge.
- **Tests**: `action_surge_test.exs`, `codec_test.exs`, `progression_test.exs`.

### M32 — Fighting Style (`fighting_style`, D48)
- **Dónde**: `Character.fighting_style` (`nil | "archery" | "defense" |
  "dueling"`). Codec string de esos tres o null; jsonb viejo → nil.
  Defaults nil en monsters/archetypes. `Heroes.build` fighter →
  `"defense"` si no viene (sin picker de UI).
  `"archery"`: +2 al total de `Combat.attack_roll` si `weapon.ranged`.
  `"defense"`: +1 CA efectiva cuando este personaje es el objetivo de
  `Actions.attack` (`t.ac + 1`); no muta `Character.ac`.
  `"dueling"`: +2 al daño de `Combat.damage_roll` si melee (`ranged !=
  true`); no comprueba mano vacía ni two-handed.
  `nil` u otro valor: sin bonus. Paladín/ranger fuera. Sin Protection,
  TWF, GWF, Superior Technique, Blind Fighting.
- **Tests**: `fighting_style_test.exs`, `codec_test.exs`.

### M33 — Lay on Hands (`lay_on_hands_pool`, D49)
- **Dónde**: `Character.lay_on_hands_pool` (integer restantes, Codec,
  default 0; jsonb viejo → 0). Máximo `5 * level`. `Heroes.build`
  paladín → `5 * level`. `Actions.lay_on_hands/4` calcula
  `applied = min(amount, pool, max(0, max_hp - hp))` y gasta `applied`.
  `World.lay_on_hands/3` resta pool + `heal/2` al target (cap max_hp,
  death saves si hp>0). Solo `class == "paladin"`. Target puede ser
  otro personaje. No toca `temp_hp`. Errores no gastan: missing,
  no paladín, amount < 1, pool 0 / amount > pool, applied 0, race
  `"undead"`/`"construct"`. Tool `lay_on_hands(who, target, amount)`
  (DM cualquiera; PC sólo `who` sí mismo). `long_rest` recarga a
  `5 * level`; `short_rest` no. Level-up no resetea remaining.
  Sin enfermedad/veneno, Divine Sense, feats, multiclase.
- **Tests**: `lay_on_hands_test.exs`, `codec_test.exs`.

### M34 — Bardic Inspiration (`bardic_inspiration_uses`, `inspired`, D50)
- **Dónde**: `Character.bardic_inspiration_uses` (integer restantes,
  Codec, default 0; jsonb viejo → 0) y `Character.inspired` (boolean,
  default false; jsonb viejo → false). `Heroes.build` bardo →
  `max(1, cha_mod)`. Solo `class == "bard"` gasta usos; cualquier
  personaje puede estar `inspired`. `Actions.bardic_inspiration/3` +
  `World.spend_bardic/2`: gasta 1 uso, marca target inspired. Errores
  no gastan: missing, no bardo, 0 uses, ya inspired (no stack). El
  motor aplica 1d6 (siempre d6) al primer roll: attack (primer swing,
  hit o miss, no daño), check, saving throw, death save; luego
  `inspired = false`. Tool `bardic_inspiration(who, target)` (DM
  cualquiera; PC sólo `who` sí mismo). `long_rest` recarga usos del
  bardo y pone `inspired = false` en quien descansa; `short_rest` no.
  Level-up no resetea. Sin escala L5/10/15, Font of Inspiration,
  colleges, Cutting Words.
- **Tests**: `bardic_inspiration_test.exs`, `codec_test.exs`.

### M35 — Arcane Recovery (`arcane_recovery_used`, D51)
- **Dónde**: `Character.arcane_recovery_used` (boolean, Codec,
  default false; jsonb viejo → false). Solo `class == "wizard"`.
  `Actions.arcane_recovery/2` + `World.arcane_recovery_plan/2` +
  `World.apply_arcane_recovery/2`. Presupuesto `div(level + 1, 2)`.
  Restaura huecos GASTADOS (`current < max` de
  `SpellSlots.for_class`), greedy de más alto a más bajo; ningún
  hueco de nivel > 5. Restaurar un hueco de nivel N consume N.
  Errores no marcan used: missing, no mago, combate, already used,
  ningún hueco gastado restaurable. Tool `arcane_recovery(who)` (DM
  cualquiera; PC sólo sí mismo). `long_rest` pone
  `arcane_recovery_used = false`; `short_rest` no. Level-up no
  resetea. Sin Signature Spells, Spell Mastery, ritual_casting como
  tool, feats, multiclase.
- **Tests**: `arcane_recovery_test.exs`.

### M36 — Divine Sense (`divine_sense_uses`, D52)
- **Dónde**: `Character.divine_sense_uses` (integer restantes, Codec,
  default 0; jsonb viejo → 0). Máximo `max(1, 1 + cha_mod)`.
  `Heroes.build` paladín → ese máximo (CHA 16 → 4). Solo
  `class == "paladin"`. `Actions.divine_sense/2` +
  `World.spend_divine_sense/1`: gasta 1 uso y reporta. Escanea todos
  los demás personajes (incluidos hp ≤ 0) cuya `race` downcase esté
  en `celestial` / `fiend` / `undead`. No incluye a `who`. Combate
  permitido. Gasta aunque el scan esté vacío. Errores no gastan:
  missing, no paladín, 0 usos. Tool `divine_sense(who)` (DM
  cualquiera; PC sólo sí mismo). `long_rest` recarga al máximo;
  `short_rest` no. Level-up no resetea remaining. Mensaje ES:
  celestial → “celestial”, fiend → “infernal”, undead → “no-muerto”.
  Sin Channel Divinity, Turn the Unholy, Improved Divine Sense,
  60 ft, cobertura, lugares consagrados/desecrados, feats, multiclase.
- **Tests**: `divine_sense_test.exs`, `codec_test.exs`.

### M37 — Turn Undead (`channel_divinity_used`, D53)
- **Dónde**: `Character.channel_divinity_used` (boolean, Codec,
  default false; jsonb viejo → false). Solo `class == "cleric"` y
  `level >= 2`. `Actions.turn_undead/3` +
  `World.set_channel_divinity_used/2`: gasta 1 uso. Objetivos: demás
  personajes con `race` downcase `"undead"` y hp > 0. Cada uno tira
  salvación de Sabiduría vs DC `8 + prof + wis`. Fallo →
  `apply_condition("frightened")` (Turned ≈ frightened, M06). Combate
  permitido; también fuera. Gasta aunque no haya no-muertos. Errores
  no gastan: missing, no clérigo, L1, already used. Tool
  `turn_undead(who)` (DM cualquiera; PC sólo sí mismo).
  `short_rest` y `long_rest` recargan (`compose_rest`). Level-up no
  resetea. Sin Destroy Undead, Channel de dominio, Turn the Unholy,
  30 ft, cobertura, reloj 1 minuto, feats, multiclase.
- **Tests**: `turn_undead_test.exs`, `codec_test.exs`.

### M38 — Ki + Flurry of Blows (`ki`, D54)
- **Dónde**: `Character.ki` (integer restantes, Codec, default 0;
  jsonb viejo → 0). Máximo `Progression.ki_points/2`: monk L2+ →
  `level`; L1 y otras clases → 0 (`Heroes.build` monje L2+ → nivel).
  Solo `class == "monk"` y `level >= 2`. `Actions.flurry_of_blows/5` +
  `World.spend_ki/2`: gasta 1 ki y resuelve 2 golpes sin armas con un
  `Weapon` sintético (`unarmed strike`, dado
  `Progression.martial_arts_die/1` — L1–4 1d4, L5–10 1d6, L11–16 1d8,
  L17–20 1d10 —, contundente, DEX/finesse) que no hace falta en
  inventory. N=2 fijo: sin Sneak, sin Smite, sin Extra Attack; reusa
  `resolve_swings` (omite el segundo swing si el objetivo cae).
  Combate permitido. Gasta aunque ambos golpes fallen. Errores no
  gastan: missing who/target, caído (hp ≤ 0), no monje, L1, ki 0. Tool
  `flurry_of_blows(who, target, mode)` (DM cualquiera; PC sólo `who`
  sí mismo; mode como `make_attack`). `short_rest` y `long_rest`
  recargan al máximo (`compose_rest`); otras clases no-op. Level-up no
  resetea remaining. Sin Patient Defense, Step of the Wind, Stunning
  Strike, Deflect Missiles, golpe extra de Martial Arts, Unarmored
  Movement, feats, multiclase.
- **Tests**: `flurry_of_blows_test.exs`.

### M39 — Hunter's Mark (`concentrating`, D55)
- **Dónde**: reusa `Character.concentrating` (string, D37) con la clave
  `"hunter's mark:<presa>"` y `World.spell_slots` de nivel 1 (D46);
  sin campos nuevos ni cambios de Codec. Solo `class == "ranger"` y
  `level >= 2`. `Actions.hunters_mark/5`: valida who/target existen,
  who no caído (hp > 0), ranger L2+, target vivo (hp > 0),
  `has_slot?(who, 1)` y `concentrating == nil`; entonces
  `consume_slot(who, 1)` + `set_concentration(who,
  "hunter's mark:<target>")`. Errores no gastan ni tocan
  concentración. Tool `hunters_mark(who, target)` (DM cualquiera; PC
  sólo `who` sí mismo). Daño: en `Actions.attack`, si el atacante
  concentra la marca y el objetivo es la presa (match exacto
  case-insensitive, sin fuzzy) → +1d6 por impacto, tipo de daño = el
  del arma (como Sneak D41); crítico dobla los d6; roller
  determinista dentro de la entrada de daño del RollLog. NO aplica en
  spells ni en Flurry. Fin de la marca: sólo las rutas existentes de
  concentración (drop_concentration, condiciones
  `@breaks_concentration`, rage, 0 hp). Rests: nada nuevo (las
  casillas ya se recargan; la concentración persiste — RAW). Sin bonus
  action economy, ventajas de tracking, múltiples presas, transferir,
  Branding Smite, feats, multiclase.
- **Tests**: `hunters_mark_test.exs`.

### M40 — Font of Magic (`sorcery_points`, D56)
- **Dónde**: `Character.sorcery_points` (integer restantes, Codec,
  default 0; jsonb viejo → 0, patrón `ki` M38). Máximo
  `Progression.sorcery_points/2`: sorcerer L2+ → `level`; L1 y otras
  clases → 0 (`Heroes.build` hechicero L2+ → nivel). Solo
  `class == "sorcerer"` y `level >= 2`. Dos tools con validación en
  cadena (`Actions.create_spell_slot/3`,
  `Actions.convert_to_sorcery_points/3`):
  `create_spell_slot(who, level)` — `level` 1..5, coste RAW
  `Progression.sorcery_slot_cost/1` (1º=2, 2º=3, 3º=5, 4º=6, 5º=7),
  resta puntos (`World.spend_sorcery_points/2`) y suma 1 casilla de
  ese nivel (`World.gain_slot/2`, puede superar el máximo diario —
  RAW); `convert_to_sorcery_points(who, level)` — `level` 1..5
  (coherente con create), requiere `has_slot?(who, level)`, gasta 1
  casilla (`consume_slot`) y gana `level` puntos
  (`World.gain_sorcery_points/2`) con cap silencioso al máximo: el
  exceso se pierde (no es error) y el mensaje muestra el resultado
  real. Combate permitido (bonus action RAW; economía de acciones
  fuera). Errores no mutan: missing who, caído (hp ≤ 0), no hechicero,
  L1, nivel de casilla inválido (no entero o fuera de 1..5), puntos
  insuficientes (create), sin casillas de ese nivel (convert). Ambas:
  DM cualquiera; PC sólo `who` sí mismo (patrón divine_smite M30).
  Rests: SOLO `long_rest` rellena al máximo (`compose_long_rest`,
  `World.restore_sorcery_points/1`) — RAW long rest, distinto del ki
  M38 que recarga en ambos; `short_rest` no toca el pool. Level-up no
  resetea remaining. Sin sorcerous restoration, casillas > 5º, feats,
  multiclase (el gasto de puntos en Metamagic entró en **D65 / M49**).
- **Tests**: `font_of_magic_test.exs`.

### M41 — Cunning Action: Hide (`conditions: "hidden"`, D57)
- **Dónde**: reusa `Character.conditions` (M06/M20) con la clave
  `"hidden"` aplicada por `World.apply_condition/2`; sin campos nuevos
  ni cambios de Codec. Solo `class == "rogue"` y `level >= 2`.
  `Actions.cunning_action_hide/4`: valida who existe, who no caído
  (hp > 0), pícaro L2+ y no ya oculto; entonces tira el chequeo
  determinista — `1d20 + mod DEX + prof` si `"stealth"` está en
  `skill_proficiencies`, modo vía `Conditions.check_mode(a, :dex,
  :normal)` — contra la máxima percepción pasiva de enemigos conscientes
  (`side != who.side`, hp > 0): `10 + mod SAB + prof` si `"perception"`
  entrenada (`Actions.passive_perception/1`); sin enemigos conscientes
  DC 10. Éxito (≥ DC) → `apply_condition(who, "hidden")`; fallo → sin
  condición. Errores no mutan nada. Registro en RollLog (patrón
  ability_check). Mensaje ES con desglose: "X se esconde:
  1d20(12)+3+2=17 vs 15 — oculto" / "— falla y sigue a la vista".
- **Ventaja**: "hidden" en `@attack_self_advantage` de
  `Rules.Conditions` (junto a `invisible`) → `make_attack` del oculto
  con ventaja efectiva (cancelación 5e vía `combine`); `sneak_opts`
  ve `:advantage` → Sneak Attack D41 gratis sin aliado. Los hechizos de
  ataque (`cast_spell` kind `:attack`) pasan por `attack_mode`: la
  ventaja aplica gratis (decisión D57).
- **Limpieza**: `make_attack` del oculto (hit o miss, todos los swings)
  y el hechizo de ataque quitan "hidden" (atacar revela; composition en
  el change_fn, patrón inspired). Re-esconderse oculto → error. Si el
  oculto cae incapacitado, "hidden" NO se arrastra (fuera D57,
  documentado; el DM tiene `remove_condition`).
- Tool `cunning_action_hide(who)` (DM cualquiera; PC sólo sí mismo).
  Combate permitido (bonus action RAW; economía de acciones fuera).
  Sin Dash/Disengage (sin grid ni opportunity attacks), visibilidad/
  posición, sigilo sostenido, ocultarse de aliados, Sigilo fuera de
  combate (usa `ability_check`), Uncanny Dodge, feats, multiclase.
- **Tests**: `cunning_action_hide_test.exs`.

### M42 — Danger Sense (`save_mode`, D58)
- **Dónde**: `Rules.Conditions.save_mode/3` (helper privado
  `danger_sense?/2`); sin campos nuevos ni cambios de Codec. Solo
  `class == "barbarian"` y `level >= 2`. Pasiva: no hay tool ni
  intervención del LLM — el motor aplica ventaja en TODAS las
  salvaciones de DES del bárbaro que pasen por `save_mode` (spells con
  save dex hoy). Combinada vía `combine/2`: la desventaja de condición
  (restrained) se cancela a normal; la ventaja pedida por el modelo se
  mantiene. Corte de incapacitación = `@auto_fail_saves` (paralyzed/
  stunned/unconscious/petrified incapacitan y auto-fallan DES
  cortocircuitando antes de computar la ventaja; una condición
  "incapacitated" suelta no corta — simplificación v1, D58). El
  `mode_tag(:advantage)` existente muestra "(ventaja)" en el mensaje;
  nada nuevo que escribir. WIS/otros saves no cambian. Sin aplicar prof
  a ability_check, Uncanny Dodge, Indomitable, Relentless Rage, feats,
  multiclase.
- **Tests**: `danger_sense_test.exs`.

### M43 — Evasión (`cast_spell` rama `:save`, D59)
- **Dónde**: `Actions.resolve_save_spell` (rama `{:roll, _}`, helper
  privado `evasion?/2`); sin campos nuevos ni cambios de Codec. Solo
  `class == "rogue"` y `level >= 7`, y sólo hechizos con
  `save_ability: :dex`. Pasiva: no hay tool ni intervención del LLM.
  Tras `Combat.saving_throw`: éxito ⇒ daño 0 (aunque el hechizo
  mitigara a mitad en éxito); fallo ⇒ `div(full, 2)` redondeando hacia
  abajo (aunque el hechizo hiciera daño completo en fallo); hechizo que
  ya haría 0 en éxito sigue en 0. Inspiración bárdica (D50) se aplica
  antes: un éxito por inspiración también activa Evasión. Mensaje:
  "(Evasión: sin daño)" / "(Evasión: mitad)" en el desglose. Corte de
  incapacitación (RAW 5e14): mismo `@auto_fail_saves` que D58 — el
  pícaro incapacitado auto-falla DES en `save_mode` y nunca llega a la
  rama que aplica Evasión. No aplica a saves no-DES ni a daño sin save
  (ni a `:attack`); el aliento de dragón (D70) SÍ aplica (mismo helper
  `evasion?/2` con un mapa `save_ability: :dex` — RAW: cualquier efecto
  de salvación DES con mitad de daño). Sin Uncanny Dodge, Indomitable,
  Jack of All Trades, feats, multiclase.
- **Tests**: `evasion_test.exs`.

### M44 — Proficiency de skills en checks + Jack of All Trades (`ability_check`, D60)
- **Dónde**: `Rules.Skills` (tabla 18 skills SRD → característica,
  `normalize/1` espacios/guiones/mayúsculas, `known?/1`, `ability/1`;
  claves string, sin átomos de input del modelo) + `Rules.Combat.check_proficiency/2`
  (público: el mensaje muestra el mismo desglose que la tirada) +
  `Actions.check/8` (detección skill-vs-ability; `Tools.ability_check`
  pasa el input crudo). Arregla el hueco v1: la tool ignoraba
  `Character.skill_proficiencies`.
- **Detección skill-PRIMERO**: "intimidation" es un skill de CAR, no la
  característica `int` (el parse de ability es por prefijo).
- **Resolución**: skill entrenado → prof completa; sin entrenar y bardo
  L2+ → `div(prof, 2)` (JoaT, floor); resto → 0 como v1. Nunca ambos
  (RAW: JoaT sólo cubre checks sin prof). JoaT también aplica a checks
  con característica cruda de un bardo L2+ (RAW). Skill pasado por
  nombre → prof desde la ficha (membresía normalizada) y pisa el flag
  del caller; ability cruda → flag del caller (compat hacia atrás,
  mismo arity y mismo nombre de parámetro `ability` en el esquema).
- **Mensajes**: skill → "X hace un chequeo de Sigilo (DES): 1d20(11) +
  DES 3 + prof 2 = 16 vs CD 15 — éxito" (JoaT: "+ JoaT 1"); ability
  cruda → formato v1 sin cambios. Etiquetas ES de
  `Heroes.Translations`.
- **Sin campos nuevos ni Codec**. `cunning_action_hide` (M41/D57) no
  cambia (ya suma prof de stealth; sin multiclase JoaT no le aplica).
- Sin Expertise (entró en **D73 / M57**), prof de tools/instrumentos, checks
  pasivos distintos de perception, Reliable Talent, feats, multiclase.
- **Tests**: `skill_checks_test.exs`.

### M45 — Aura of Protection (`saving_throw` + `death_save`, D61)
- **Dónde**: `Actions.aura_save_bonus/2` (privado) +
  `World.paladins_conscious/3` (público, compartido con M46) +
  `Combat.death_save/2` (parámetro `bonus \\ 0`); sin campos nuevos
  ni cambios de Codec. Solo `class == "paladin"`, `level >= 6`,
  `hp > 0`. Pasiva: no hay tool ni intervención del LLM.
- **Bonus**: `modifier(paladín, :cha)` por paladín consciente L6+ del
  mismo `side` que quien salva (el paladín incluido). Varios
  paladines apilan (suma). CHA < 10 → negativo sin piso (RAW).
- **Simplificación sin grid**: sin radio de 10 pies — el aura cubre a
  TODO el `side` del paladín consciente (mismo criterio que
  `conscious_ally?` D41). Regla genérica por side: un no-muerto
  aliado también lo recibe.
- **Cobertura**: TODAS las salvaciones del motor — `cast_spell` rama
  `:save`, `turn_undead` (SAB), death saves (`make_death_save`; RAW
  aplica) y concentración (CON al daño). NO a ability checks ni
  attack rolls. Se suma al total tras `Combat.saving_throw` y ANTES
  de la inspiración bárdica (D50 re-deriva el éxito del total, así no
  se pierde); en death saves desplaza el umbral 10 sin tocar nat 1/20.
- **Mensaje**: desglose "13 vs CD 13 +3 aura" / "saca 7 (+3 aura)" /
  "(-1 aura)". `mode_tag` y demás formatos no cambian.
- Sin radio, Aura of Devotion (charm), Aura of Hate, Improved Divine
  Smite, feats, multiclase.
- **Tests**: `paladin_auras_test.exs`.

### M46 — Aura of Courage (`apply_condition` "frightened", D62)
- **Dónde**: `World.apply_condition/2` (hook +
  `World.courage_immune?/2`, alias de `paladins_conscious(w, side,
  10) != []`); sin campos nuevos ni cambios de Codec. Solo `class ==
  "paladin""`, `level >= 10`, `hp > 0`. Pasiva: no hay tool.
- **Efecto**: si `condition == "frightened"` y el objetivo comparte
  `side` con un paladín L10+ consciente (él incluido) → la condición
  NO se aplica: `{:ok, world}` sin mutar (inmunidad ≠ error). Los
  callers lo reportan: `Tools.apply_condition` (DM) devuelve "X es
  inmune al miedo (Aura de Coraje)"; `turn_undead` (D53) particiona
  sus fallidos en asustados/inmunes con la misma frase. Doble hook
  (Actions particiona, World no-op) = defensa en profundidad para
  callers viejos.
- **Regla genérica por side**: `apply_condition` la usa turn_undead —
  un no-muerto aliado de un paladín L10+ es inmune al fear del
  clérigo propio (aceptable, documentado en D62). Idempotencia y
  `remove_condition` intactos.
- Sin radio, inmunidad a charm (Aura of Devotion), feats, multiclase.
- **Tests**: `paladin_auras_test.exs`.

### M47 — Wild Shape (`wild_shape` / `end_wild_shape`, D63)
- **Dónde**: `Character.wild_shape_uses` + `Character.wild_shape`
  (mapa guardado, claves átomo; Codec strings, jsonb viejo → 0/nil) +
  `Monsters.cat/1` · `black_bear/1` · `wild_shape_beasts/0` +
  `World.transform_wild_shape/3` · `revert_wild_shape/1` ·
  `restore_wild_shape_uses/1` · hook en `apply_damage/3` +
  `Actions.wild_shape/3` · `end_wild_shape/2` + guard en
  `Actions.spell` + tools `wild_shape(who, beast)` /
  `end_wild_shape(who)` (DM cualquiera; PC sólo sí mismo).
- **Transformar** (druida L2+, 1 uso SIEMPRE, 2/rest): guarda
  str/dex/con/hp/max_hp/ac/weapons originales y aplica los de la
  bestia; conserva int/wis/cha, nombre, side, clase, nivel,
  proficiencies, skill_proficiencies, condiciones y concentración
  (RAW); el inventario NUNCA cambia (armas de bestia sintéticas).
  Catálogo fijo: cat (ND 0), wolf (ND 1/4), black_bear (ND 1/2).
  Gate: L2–3 → máx ND 1/4; L4+ → máx ND 1/2. Errores NO mutan: who
  inexistente/caído, no druida, L1, ya transformado, bestia
  desconocida, CR superior, 0 usos. Mensaje: "X adopta la forma de
  un lobo (usos de forma salvaje restantes: N)."
- **Revert manual**: restaura TODO con `hp = orig_hp` exacto;
  "X vuelve a su forma original (PG N)."
- **Auto-revert** (`apply_damage/3`, cuello único): transformado y hp
  resultante ≤ 0 → exceso = rest − hp de bestia (tras resist D38 y
  temp_hp D36 como hoy); revierte con `hp = max(0, orig_hp −
  exceso)`; daño exacto → sin exceso; si ≤ 0 → caído (death saves
  como siempre). Nota en el log del world ("la bestia cae y X vuelve
  a su forma (PG N)") para la narración.
- **Bloqueo**: `cast_spell` en forma → "X no puede conjurar en forma
  de bestia"; `make_attack` (armas de bestia), `ability_check` y
  rests funcionan igual. Short Y long rest recargan usos a 2
  (`compose_rest`, como ki D54); NO fuerza revert (RAW puedes
  descansar en forma); level-up no toca usos ni forma.
- Sin duración (sin reloj), componentes V/S (el bloqueo integral ya
  lo cubre), Circle of the Moon, formas volar/nadar, multiclase,
  feats.
- **Tests**: `wild_shape_test.exs`.

### M48 — Uncanny Dodge (`start_uncanny_dodge`, D64)
- **Dónde**: `Character.uncanny_dodge` (boolean, default false = no
  armada; Codec `== true`, jsonb viejo → false) +
  `World.set_uncanny_dodge/2` + hook en `World.apply_damage/3` +
  `Actions.start_uncanny_dodge/2` + tool `start_uncanny_dodge(who)`
  (DM cualquiera; PC sólo sí mismo).
- **Armar** (pícaro L5+, gratis, en cualquier momento):
  `uncanny_dodge = true`; mensaje "X se prepara para esquivar
  (Uncanny Dodge armado: el próximo daño se reduce a la mitad).";
  errores NO mutan: who inexistente, caído (hp≤0), no pícaro, L4–, ya
  armada. Rearmar tras consumir es gratis; los descansos NO gestionan
  la flag (no es recurso por descanso).
- **Mitigar** (`apply_damage/3`, cuello único): armada y `amount > 0`
  → `div(amount, 2)` (floor) sobre el amount de ENTRADA — antes de
  resistencias D38 y temp_hp D36 (orden fijado en D64) — y consume la
  flag (false). CUALQUIER fuente que pase por apply_damage (ataque,
  hechizo, trampa). amount ≤ 0 no consume. Apila con Evasión D59
  (mitad de mitad = cuarto, floor). Auto-revert D63 intacto (corre
  tras la mitigación, con el exceso ya mitigado).
- Sin economía de reacción/ronda (1 uso por daño, no por ronda),
  resistencias dañinas (D38 es otro sistema), Deflect Missiles,
  feats, multiclase.
- **Tests**: `uncanny_dodge_test.exs`.

### M49 — Metamagic (`arm_metamagic`, D65)
- **Dónde**: `Character.metamagic` (nil | `%{option, target}` — claves
  átomo en memoria, strings en Codec, jsonb viejo/ausente → nil;
  opción validada contra empowered/heightened/twinned en encode/decode) +
  `World.set_metamagic/2` + `Actions.arm_metamagic/4` + hooks en
  `Actions.spell/5` → `resolve_spell` (`empowered_count/2`,
  `heightened?/3`, `twinned_target/4`, `resolve_twinned/8`,
  `dice_with/3` con rerolls, `consume_metamagic/3`) + tool
  `arm_metamagic(who, option, target)` (DM cualquiera; PC sólo sí
  mismo).
- **Armar** (hechicero L3+, UNA opción, SIN un-arm ni reembolso): gasta
  1/3/2 puntos vía `spend_sorcery_points` (D56) y fija el mapa.
  Errores NO mutan: who inexistente/caído, no hechicero, L2–, opción
  desconocida (lista las tres), ya armada, puntos insuficientes (coste
  exacto), heightened sin target, twinned sin target/inexistente/self.
  Mensaje: "X arma Metamagia: OP (N punto(s) de hechicería, quedan M).
  El próximo hechizo que califique la aplicará."
- **Empowered** (hechizo con dice + damage_type): los primeros
  `max(1, mod CAR)` dados de daño se tiran dos veces conservando el
  mayor (dos draws del roller por dado mejorado; determinista y
  demostrable con roller de secuencia); crit dobla la base mejorada sin
  duplicar rerolls; un :attack que falla igualmente consume (califica
  por tipo, RAW elige al lanzar); curación/utilidad nunca califican.
  Etiqueta "(Metamagia: Empowered)".
- **Heightened** (hechizo :save cuyo target == armado): la salvación
  entra como `requested: :disadvantage` en `Conditions.save_mode` (se
  combina por capas con Danger Sense D58/Evasión D59/auras D61-D62);
  etiqueta "(Metamagia: Heightened)"; otro objetivo u otro kind → no
  aplica ni consume.
- **Twinned** (hechizo contra target ≠ lanzador): el mismo hechizo se
  resuelve también contra el segundo target armado — cada resolución
  tira sus propios dados; mensaje en bloque por objetivo ("… en A: …;
  en B: …"); UNA casilla y UNA concentración (compuestas una vez en
  `spell/5`); self-buff o twin desaparecido → no aplica ni consume.
- **Consumo-on-apply**: la opción se consume SÓLO cuando el hechizo
  califica (divergencia menor de RAW, documentada en D65); rests y
  level-up NO tocan `metamagic`.
- Fuera: Quickened, Distant, Extended, Subtle, Careful (sin efecto en
  este motor), Sorcerous Restoration, varias opciones simultáneas,
  un-arm, reembolsos, Metamagic Adept, feats, multiclase.
- **Tests**: `metamagic_test.exs`.

### M50 — Lucky (pasiva racial, D66)
- **Dónde**: `Rules.Combat.maybe_lucky/3` (privado) aplicado dentro de
  `attack_roll/5`, `saving_throw/5` y `ability_check/6` (que delegan
  en `attack_roll_tagged/5` / `saving_throw_tagged/5` /
  `ability_check_tagged/6` — mismas tiradas + 4º elemento
  `lucky_tag`, `nil` cuando no fired). Sin tool, sin prompt, sin
  allowlist: el motor lee `Character.race`.
- **Cuándo**: `race == "halfling"` y el d20 EFECTIVO (conservado tras
  ventaja/desventaja) es 1 → UN reroll y se USA el nuevo resultado
  (RAW "must use the new roll"; reroll a 1 se queda 1 — sólo un
  reroll). Nat-20/1 del ataque se evalúa sobre el dado final. El
  reroll pasa por el mismo roller (el RollLog registra ambos dados).
  NO aplica a death saves (sin personaje en la ruta); un monstruo con
  raza mediano también lo tiene.
- **Desglose**: etiqueta "(Lucky: 1→N)" tras el dado en todos los
  mensajes que muestran el d20 — ataque (single/multi), salvación de
  hechizo, concentración, `check` y Sigilo (patrón mode_tag).
- Fuera: Brave, Halfling Nimbleness, demás rasgos raciales.
- **Tests**: `racial_traits_test.exs`.

### M51 — Resistencia implacable (pasiva racial, D67)
- **Dónde**: `Character.relentless_endurance_used` (boolean, default
  false; Codec `== true`, jsonb viejo → false) + hook en
  `World.apply_damage/3` (tras el auto-revert D63) +
  `World.set_relentless_endurance/2` + recarga en
  `compose_long_rest` (Actions). Sin tool ni prompt.
- **Cuándo**: `race == "half-orc"`, hp final ≤ 0 y flag en false →
  `hp = 1`, flag `true`, nota en el log del world ("la furia semi-orca
  mantiene a X en pie con 1 pg (Resistencia implacable)"). Orden de
  capas de `apply_damage` (fijado en D67): Uncanny Dodge D64 mitiga el
  amount → resist D38 → temp_hp D36 → hp → revert Wild Shape D63 →
  RE → death saves. Al salvar a 1 no se limpian flags de caído.
- **Recarga**: sólo `long_rest` (`short_rest` no). Ya gastada y vuelve
  a caer → 0 pg normal.
- Fuera: Savage Attacks, Darkvision, demás rasgos raciales.
- **Tests**: `racial_traits_test.exs`.

### M52 — Indomitable (pasiva de clase, D68)
- **Dónde**: `Character.indomitable_used` (boolean, default false;
  Codec `== true`, jsonb viejo → false) + `World.set_indomitable/2` +
  helper privado `maybe_indomitable/7` en `Actions` usado en los TRES
  sitios donde el personaje salva: rama `:save` de hechizos
  (`resolve_save_spell`), SAB de `turn_undead` y CON de concentración
  (`one_hit_concentration`). Recarga en `compose_long_rest` (long rest
  only). Sin tool, sin prompt, sin allowlist: el motor lee
  `class == "fighter"` y `level >= 9`.
- **Cuándo**: tirada FINAL fallida (post aura D61 e inspiración D50) y
  `indomitable_used == false` → UN reroll con la MISMA llamada
  `Combat.saving_throw_tagged/5` (mismo modo —Heightened D58/D65— y
  mismo bonus plano —el aura se re-suma—; el d6 bárdico se gastó en el
  primer intento y no se re-tira) y se USA el nuevo resultado (RAW, no
  keep-best; puede fallar otra vez). El reroll pasa por el mismo roller
  (el RollLog registra ambos dados). Marca `indomitable_used = true`
  compuesto en el change del sitio; el struct actualizado viaja a la
  simulación de concentración y se hilva entre golpes de una misma
  acción (sin doble gasto).
- **Desglose**: etiqueta "(Indomitable: X→Y)" (totales) tras el dado
  (patrón Lucky D66); en `turn_undead` pegada al nombre. Lucky D66
  puede dispararse gratis en el reroll (la etiqueta se encadena).
- **Fuera**: death saves (ruta sin personaje), auto-fails (sin dado),
  ability checks, usos extra L13/L17, feats, multiclase.
- **Tests**: `indomitable_savage_test.exs`.

### M53 — Savage Attacks (pasiva racial, D69)
- **Dónde**: hook en `Combat.damage_roll/4` (vía nueva variante pública
  `damage_roll_tagged/4` que devuelve `{total, savage_die}`;
  `damage_roll/4` delega y dropea la etiqueta — patrón `*_tagged` D66,
  firmas intactas) + `swing.savage` y etiqueta " (+N Savage)" en
  `Actions.attack`/`flurry` (patrón " (+N sneak)"). Sin tool, sin
  campos, sin rests: el motor lee `Character.race`.
- **Cuándo**: `race == "half-orc"` + `weapon.ranged != true` + outcome
  `:crit` → UN dado del TAMAÑO del arma (`roller.(sides)`: un 2d6 añade
  1d6, no otra tirada completa; nunca doblado). NO a distancia, hechizos
  (no pasan por `damage_roll`) ni golpes no-críticos. Apila con sneak
  D41 / smite D46 / mark D55 / rage D42 (dados independientes en el
  mismo swing); el golpe sin armas de Flurry D54 también aplica (melee
  weapon attack RAW).
- **Tests**: `indomitable_savage_test.exs`.

### M54 — Aliento de dragón (tool racial, D70)
- **Dónde**: `Progression.breath_dice/1` (L1–4 "2d6", L5–10 "3d6",
  L11–16 "4d6", L17+ "5d6"), campo `Character.breath_weapon_used`
  (Codec tolerante a jsonb viejo, patrón D67/D68), `World.set_breath_weapon_used/2`,
  recarga en `compose_rest` (short Y long, patrón ki D54) y
  `Actions.breath_weapon/5` con tool `breath_weapon(who, target)`
  (DM cualquiera; PC sólo sí mismo). Allowlist PCAgent + línea de
  prompt dragontino (por RAZA) + una línea en el prompt del DM.
- **Cuándo**: `race == "dragonborn"` + uso disponible → salvación de
  DES del objetivo vs CD `8 + CON mod + proficiency` del dragontino;
  éxito → mitad (floor), fallo → completo. Daño SIEMPRE "fire"
  (sin ascendencia dracónica — ADR D70). Pasa por el stack completo de
  sitio de salvación (Danger Sense D58, Lucky D66, aura D61,
  inspiración D50, Indomitable D68, Evasión D59) y por el chequeo de
  concentración del objetivo (`with_conc_damage`). Roller + RollLog
  (patrón spell :save). El uso se gasta SIEMPRE que se resuelve;
  errores (who/target inexistentes, who caído, no dragontino, ya
  usado) no mutan. Combate permitido; target caído permitido; no es
  hechizo (sin casillas/concentración, funciona en Forma salvaje
  D63, no interactúa con Metamagic D65).
- **Tests**: `breath_gnome_test.exs`.

### M55 — Astucia gnoma (pasiva racial, D71)
- **Dónde**: `Conditions.save_mode/4` (opts opcional
  `gnome_advantage:` — `save_mode/3` intacta) + inyección en los DOS
  sitios de salvación mágica de `Actions`: rama `:save` de
  `resolve_save_spell` y SAB de `turn_undead` (divina = mágica; hoy
  inalcanzable en la práctica porque el objetivo de Expulsar exige
  `race == "undead"` y la raza es un campo único). Sin tool, sin
  campos, sin rests: el motor lee `Character.race`.
- **Cuándo**: `race == "gnome"` + ability `:int/:wis/:cha` en una
  salvación de `cast_spell`(:save)/`turn_undead` → fuente EXTRA de
  ventaja que `combine/2` combina: con desventaja de condición o
  Heightened D65 → normal. Etiqueta "(Astucia gnoma: ventaja)" cuando
  drove el modo (cancelada → sin etiqueta). NO aplica a checks, death
  saves, concentración (CON) ni DES. Indomitable D68 conserva la
  ventaja en el reroll (mismo modo). Danger Sense D58 no interactúa.
- **Tests**: `breath_gnome_test.exs`.

### M56 — Usos de Furia + Furia implacable (pasivas de clase, D72)
- **Dónde**: `Progression.rage_count/1` (L1–2 2, L3–5 3, L6–11 4,
  L12–16 5, L17+ 6) + campos `Character.rage_uses_used` y
  `Character.relentless_rage_successes` (integer default 0, Codec
  tolerante a jsonb viejo, patrón D67/D68) + `World.set_rage_uses_used/2`
  y `World.set_relentless_rage_successes/2` + recarga de AMBOS en
  `compose_long_rest` (Actions; long rest only) + hook
  `maybe_relentless_rage/4` en `World.apply_damage/4` (justo ANTES de
  la RE racial D67). Sin tools ni prompts: `start_rage`/`end_rage`
  existen desde D42.
- **Usos**: `start_rage/1` valida clase Y `rage_uses_used <
  rage_count(level)`; error "no le quedan furias hoy (N/N usadas)" sin
  mutar; gasta 1 al ENTRAR; `end_rage/1` NO devuelve el uso; ya raging
  → idempotente-OK sin gasto extra; `short_rest` no recarga.
- **Furia implacable**: `class == "barbarian"` + `level >= 11` +
  `raging == true` + hp final ≤ 0 → salvación CON vs
  `10 + 5 × relentless_rage_successes` vía
  `Rules.Combat.saving_throw/5` (prof de CON de la ficha + Lucky D66)
  + aura D61 (`World.aura_save_bonus/2`, movida de Actions para que el
  hook use el mismo bonus plano — RAW el aura cubre TODAS las saves);
  éxito → `hp = 1`, `successes + 1` (siguiente CD +5 más difícil) y
  nota "la furia mantiene a X en pie con 1 pg (Furia implacable:
  salvación CON d20 N: total vs CD M)"; fallo → nota de fallo y cae al
  siguiente check (RE racial D67 si semi-orco: ambas capas; el éxito de
  clase NO consume la RE ese golpe). Roller: `apply_damage/4` gana un
  4º parámetro opcional (`&Dice.roll/1` default); `Actions.pipe_damage`
  hilvana el suyo (mismo roller de la acción). Sin RollLog a esa
  profundidad: la nota del world log ES el registro (ADR D72).
  Indomitable NO aplica (guerrero-only).
- **Orden de capas en `apply_damage`**: Uncanny Dodge D64 → resist
  D38 → temp_hp D36 → hp → revert Wild Shape D63 → **Furia implacable
  (D72)** → Resistencia implacable (D67) → death saves.
- **Tests**: `rage_uses_test.exs`.

### M57 — Expertise de pícaro y bardo (tool elegida, D73)
- **Dónde**: campo `Character.expertise` (array de skills, default `[]`,
  Codec tolerante a jsonb viejo — patrón arrays) + cupo
  `Progression.expertise_count/2` (rogue L1+ 2 / L6+ 4; bard L3+ 2 /
  L10+ 4; resto 0) + tool `gain_expertise(who, skill)` (DM cualquiera,
  PC sólo sí mismo; `World.add_expertise/2` muta sin validar — la
  validación vive en `Actions.gain_expertise/3`) + resolución en
  `Combat.check_proficiency/3` (nuevo 3er parámetro opcional `skill`,
  nueva kind `:expert`: entrenado + expertised → `prof × 2`), hilvanado
  por `ability_check/7`/`ability_check_tagged/7` y consumido por las
  DOS rutas de checks con skill: `Actions.check` (desglose
  "prof 4 (experto)") y `cunning_action_hide` (D57: "+4 (experto)").
  Elección modelada como TOOL, no en el builder/level-up (ADR D73).
- **Cuándo**: pícaro (L1+) o bardo (L3+) elige una skill ENTRENADA una
  vez, en cualquier momento una vez elegible; sin rests (permanente).
  Errores (NO mutan), en orden: who inexistente, caído, clase sin
  Expertise ("sólo pícaros y bardos"), nivel insuficiente para el
  primer cupo (bardo L1–2), skill desconocida (directiva, ejemplos),
  skill sin competencia, skill ya elegida, cupo agotado (con el cupo
  actual por nivel y la lista). Éxito: "X profundiza su dominio de
  Sigilo (Expertise 1/2).". JoaT (M44) nunca aplica a una expertised
  (ya competente); ability cruda sin skill nunca dobla;
  `passive_perception` fuera (DC de hide sin cambios).
- **Tests**: `expertise_test.exs`.

### M58 — Upcasting 5e RAW (D74)
- **Dónde**: tabla curada `Rules.Upcast` (`extra_dice/3` +
  `scaled_spell/2`) consumida por `Actions.spell/7` vía el parámetro
  opcional `cast_level` (nil = nivel base, compat hacia atrás; tool
  `cast_spell` con 4º parámetro, coacciona strings numéricos). El dado
  extra se COMBINA con la expresión base antes de resolver
  (`"8d6"+"1d6" → "9d6"`): mismo RollLog (misma etiqueta, total
  combinado), mitad en :save sobre el TOTAL escalado, crit dobla los
  extra, Empowered (M49) boostea los combinados. CD y concentración
  sin cambios (RAW). Warlocks gastan su casilla de pacto (D40,
  `slot_level_for`).
- **Tabla (RAW 2014, auditada contra cada descripción)**:
  burning_hands +1d6/n s/1º · thunderwave +1d8/n s/1º · shatter
  +1d8/n s/2º · fireball +1d6/n s/3º · lightning_bolt +1d6/n s/3º ·
  blight +1d8/n s/4º · flame_strike +1d6/n s/5º (simplificación: RAW
  reparte fuego+radiante, el motor modela 4d6 fuego único) ·
  vampiric_touch +1d6/n s/3º · spiritual_weapon +1d8 cada dos niveles
  s/2º · magic_missile +1 dardo (+1d4+1)/n s/1º (mensaje con el nº
  real de dardos) · cure_wounds +1d8/n s/1º · healing_word +1d4/n
  s/1º · prayer_of_healing +1d8/n s/2º (SRD sin `dice` — sube sobre
  base sin modelar). Ausentes de la tabla: no escalan (consumen la
  casilla pedida sin dados extra).
- **Validaciones (NO mutan)**: cast_level entero entre nivel base y 9;
  menor que la base → error claro; > 9 → error; truco a nivel superior
  → error; `has_slot?` del nivel PEDIDO (mensaje lo cita). Mensaje ES:
  "(nivel N)" tras el nombre cuando cast_level > base.
- **Excluidos (ADR D74)**: heal (70 pg planos), mass_cure_wounds y
  sleep (motor sin dados reales / mal-modelado), escalados
  multi-objetivo y multi-rayo (scorching_ray), variantes 2024.
- **Tests**: `upcast_test.exs`.

---

## Declarado NO implementado (no son bugs — R28)

reacciones como mecánica formal (TurnMaster da interrupciones narrativas) ·
multiclase · feats. Pact Magic: **D40**. Sneak Attack: **D41**. Rage:
**D42** (usos/día y Furia implacable: **D72 / M56**).
Reckless Attack: **D44 / M28**. Second Wind: **D45 / M29**. Divine Smite:
**D46 / M30**. Action Surge: **D47 / M31**. Fighting Style: **D48 / M32**.
Lay on Hands: **D49 / M33**. Bardic Inspiration: **D50 / M34**.
Arcane Recovery: **D51 / M35**. Divine Sense: **D52 / M36**.
Turn Undead: **D53 / M37**. Ki + Flurry of Blows: **D54 / M38**.
Hunter's Mark: **D55 / M39**. Font of Magic: **D56 / M40**.
Cunning Action (Hide): **D57 / M41**. Danger Sense: **D58 / M42**.
Evasión: **D59 / M43**. Jack of All Trades (y prof de skills en
checks): **D60 / M44**. Aura of Protection: **D61 / M45**.
Aura of Courage: **D62 / M46**. Wild Shape: **D63 / M47**.
Uncanny Dodge: **D64 / M48**. Metamagic: **D65 / M49**.
XP en partida: **D43 / M27**.
Rasgos raciales automáticos: Lucky **D66 / M50**, Resistencia
implacable **D67 / M51**, Savage Attacks **D69 / M53**, Astucia gnoma
**D71 / M55**; Aliento de dragón del dragontino **D70 / M54** (tool
racial). Brave, Halfling Nimbleness, Darkvision y demás siguen fuera.
Indomitable del guerrero: **D68 / M52**.
Iniciativa individual por monstruo: **D34**.
`temp_hp`: **D36 / M23**. Concentración: **D37 / M24**. Resistencias:
**D38 / M25**. Cupo de Rage/día entró en **D72 / M56** (Furia implacable
con él); el segundo uso de Action Surge a L17 sigue fuera.
Protection / TWF / GWF siguen fuera. Curar
enfermedad/veneno con Lay on Hands (gastar 5) sigue fuera.
  Channel Divinity / Turn the Unholy / Improved Divine Sense siguen
  fuera. Dash / Disengage siguen fuera (sin grid ni ataques de
  oportunidad no tienen efecto mecánico — D57); Uncanny Dodge entró en
  **D64 / M48**. Metamagic (Quickened/Distant/Extended/Subtle/Careful y
  compañía) entró en   **D65 / M49** con las tres opciones con efecto real
  en este motor. Expertise (doble prof de skill) entró en
  **D73 / M57** (sólo skills, no tools/instrumentos). Upcasting de
  hechizos (dados extra con casilla superior) entró en **D74 / M58**
  (tabla curada; multi-objetivo/multi-rayo y escalados no-dados siguen
  fuera).

Para que una de estas entre: ADR nuevo + mecánica `M44+` en este catálogo +
tests.

## Dados

- `Dice` (`dice.ex`) — RNG inyectable vía `dic_ex`; `roll_expr/2` parsea
  `NdM±K`. `RollLog` estructura cada tirada para el dado modal.
- **Tests**: `flows/dice_test.exs`, `roll_log_test.exs`.
