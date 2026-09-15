# Dragonex — progreso y estado

Estado canónico por feature. **Esta es la fuente de la verdad sobre qué está
hecho, qué falta y qué se simplificó.** Si el `ROADMAP.md` o cualquier handoff
histórico (`docs/historical/`) discrepan con esto, manda este doc.

- Verde de referencia: **1429 tests passed** (`MIX_ENV=test mix test`), compile
  limpio sin warnings.
- **Qué falta y en qué orden** → [`producto/03-plan-fases.md`](producto/03-plan-fases.md)
  (backlog F6/F7 accionable). **El contrato de requisitos** (con criterios de
  aceptación) → [`producto/02-requisitos.md`](producto/02-requisitos.md).
- Arquitectura y porqués → `docs/decisions.md`.
- Cómo funciona el bucle de una partida en detalle → `docs/FLUJO_PARTIDA.md`.
- Cómo se verifica cada cambio → `docs/tecnico/09-estrategia-pruebas.md`.

---

## ✅ Hecho y probado

### Motor y reglas 5e
- `Rules.Ability` (modificadores, competencia) + `Rules.Combat` (ataques,
  daño, críticos, salvaciones, chequeos, death saves, ventaja/desventaja).
- `World` — máquina de estados `:exploration`/`:combat`, change-fns puras,
   invariantes (damage floor 0, resist/vuln/immune D38, overlay Rage B/P/S D42,
   `temp_hp` absorbe primero D36, concentración D37, `controlled_by?/3`), `facts` durables
   (D16), condiciones, spell slots,
  `level_up`.
- `Rules.Conditions` — tabla M06: condición → ventaja/desventaja/auto-fallo
  en ataque, salvación y chequeo (cancelación 5e).
- Rasgos raciales y de clase automáticos (D66/D67/D68/D69/D71, pasivas
   sin tool — el motor lee `Character.race`/`class` del builder D52): Lucky
   del mediano M50 (d20 efectivo 1 en ataque/salvación/chequeo → un reroll
   y se usa el nuevo; etiqueta "(Lucky: 1→N)" en el desglose; variantes
   `*_tagged` en `Rules.Combat` mantienen las firmas públicas), Resistencia
   implacable del semi-orco M51 (hook en `World.apply_damage/3` tras el
   auto-revert D63: hp 0 → 1 una vez por descanso largo; `long_rest`
   recarga, `short_rest` no), Indomitable del guerrero L9+ M52 (reroll de
   una salvación fallida —hechizo :save, turn_undead SAB, concentración
   CON, aliento D70— una vez por descanso largo, se usa el nuevo resultado;
   etiqueta "(Indomitable: X→Y)"; `long_rest` recarga), Savage Attacks del
   semi-orco M53 (en `Combat.damage_roll`, crítico melee de arma → UN dado
   del tamaño del arma extra, " (+N Savage)" en el desglose; distancia y
   hechizos no) y Astucia gnoma del gnomo M55 (ventaja en salvaciones
   INT/SAB/CAR contra magia — equivalencia: toda salvación de `cast_spell`
   :save y `turn_undead`; inyectada como fuente extra en
   `Conditions.save_mode/4`, `combine/2` la cancela contra Heightened
   D65/condiciones; etiqueta "(Astucia gnoma: ventaja)"; sin campos ni
    rests). Aliento de dragón del dragontino D70/M54: rasgo racial CON tool
    y campo `breath_weapon_used` — ver `Actions.breath_weapon` y la tool
    `breath_weapon` más abajo. Usos de Furia + Furia implacable del
    bárbaro D72/M56: `start_rage` gasta (`rage_uses_used`, tope
    `Progression.rage_count/1`, recarga sólo en long rest) y al caer a
    0 pg en furia un bárbaro L11+ salva CON vs `10 + 5 × éxitos`
    (`relentless_rage_successes`, aura D61 suma) para quedarse a 1 —
    ver más abajo.
 - `Actions` — puente intent→world (`attack` con Extra Attack 5e / D35,
       Sneak Attack D41, Rage D42 y Divine Smite D46, Hunter's Mark D55, Font of Magic D56, Cunning Action Hide D57, Danger Sense D58 y Evasión D59 (pasivas del motor en salvaciones), auras de paladín D61/D62 (pasivas: +CHA a salvaciones del side, inmunidad al miedo), Uncanny Dodge D64 (postura armable que mitiga el próximo daño), Metamagic D65 (armable: Empowered/Heightened/Twinned aplicadas y consumidas por el próximo hechizo que califique), `spell` automatic/attack/save + consumo de slot, False Life → temp_hp D36,
    concentración D37, resist/vuln/immune D38, `initiative`, `death_save`, `heal`,
     `second_wind`, `action_surge`, `flurry_of_blows`, `create_spell_slot`, `convert_to_sorcery_points`, `lay_on_hands`, `divine_sense`, `turn_undead`, `bardic_inspiration`,       `arcane_recovery`, `wild_shape`, `end_wild_shape`, `start_uncanny_dodge`, `breath_weapon` (D70: aliento racial del dragontino con salvación DES y daño de fuego por nivel, 1/descanso — short y long recargan), `short_rest`, `long_rest`, `check` — acepta skills con prof de ficha + JoaT D60). Con `RollLog` para dados estructurados.
 - `Tools` — `deftool`s que el LLM invoca: `make_attack`, `cast_spell`,
    `roll_initiative`, `make_death_save`, `heal`, `grant_temp_hp`, `grant_xp`, `drop_concentration`, `start_rage`, `end_rage`, `start_reckless`, `end_reckless`,    `second_wind`, `action_surge`, `flurry_of_blows`, `hunters_mark`, `cunning_action_hide`, `create_spell_slot`, `convert_to_sorcery_points`, `divine_smite`, `end_smite`, `lay_on_hands`, `divine_sense`, `turn_undead`, `bardic_inspiration`, `arcane_recovery`, `ability_check`, `end_combat`,
   `short_rest`, `long_rest`, `spawn_monster`, `apply_condition`,
   `remove_condition`, `set_scene`, `establish_fact`, `level_up`, `roll_dice`, `wild_shape`, `end_wild_shape`, `start_uncanny_dodge`, `arm_metamagic`, `breath_weapon`.
- `TurnPolicy.WorldDriven` — turno leído del World; un beat por monstruo
  (D34); el LLM no puede saltar/reordenar.
- `Codec` + `Store.Coded` — `World ↔ jsonb` simétrico (D8).
- `Dice` — RNG inyectable (`dic_ex`), `roll_expr/2` parser NdM±K.

### Partida (`Dragonex.Game`)
- GenServer on-demand por `game_id` (D5); rehidrata de Postgres, persiste
  tras cada beat (D3, D4).
- Bucle por turno: AI en `Task`s (no bloquea el GenServer), `:waiting` para
  humanos, `:paused`, `:ended`.
- **Robustez**: retries transient con backoff exponencial (1s→3s→10s, máx 3),
  retry `max_tokens` con nudge "SÉ BREVE", circuit breaker (D17), combate
  fantasma v1+v2 (D18), anti-loop PCs (Jaccard), anti-puppet DM (regla #14),
  anti-repetición DM, limbo de exploración, guardián de español, UTF-8 sanitize.
- Auto-play de PCs humanos (toggle 🤖 crea un `PCAgent`).
- Pausa/reanuda durable; rehidrata tras kill del proceso.

### Agentes
- `DM` — system prompt de 16 reglas, story bible horneada (prefijo cacheable,
  D20), tools con `max_retries: 3`, capabilities `Events` + `Compaction.Summary`.
- `PCAgent` — un agent por PC IA, personalidad por clase, tools restringidas,
  `instruction/3` adaptativa (caído→death_save, combate→targets, exploración).
- **`TurnMaster` (D25 + D27)** — orquesta turnos (`give_turn_to` / `cut_in` /
  `react` / `pass_to_dm` / `end_scene`). Micro-máquina `actor → turnmaster →
  handoff`. **No muta el World**. `WorldDriven` = fallback + circuit breaker.
  El brief lista **intenciones humanas pendientes**; un declare off-turn en
  `:waiting` ajeno re-evalúa al TM sin robar el floor si no decide. Combate
  con `acted_this_round` + mini-turnos. Modelo `Models.turnmaster/0` (barato,
  `max_tokens` 256). Spec: `TURNMASTER.md`.
- `History` — reconstruye contexto compartido desde `game_events` (D19);
  compresión de narraciones viejas, coalescing mismo-actor.
- `Brief` + `Instructions` — `world_brief` + instruction por turno.
- `Models` + `ModelConfig` — modelo-por-rol + selector runtime (D21).

### Creador de personajes (`Dragonex.Heroes`) — ex-"Fase 4"
- Builder nivel-1 → `Dragonex.Character`: razas + subrazas, clases,
  backgrounds, puntuaciones (standard array / point buy / explícito),
  equipment (grupos SRD + custom), spells (casters), skills, languages.
- Catálogos SRD: `Classes`, `Races`, `Backgrounds`, `Scoring`, `Equipment`
  (armas simple/martial, armaduras light/medium/heavy, escudos, gear),
  `Spells` (42 builtin), `SRDSpells` (**319** cargados de
  `priv/srd/spells.es.json`, generados por `scripts/import_srd_spells.py`).
- `Catalog` — capa de display/consulta: mezcla builtin + SRD + **custom**
  inyectado con `source: :builtin | :srd | :custom` (offline-safe).
- `Translations` — i18n ES/EN de todo el catálogo + tipos de daño/habilidades.
- `LevelUp` + `Progression` — subida 5e (más abajo).
- ✅ Golden SRD del creador (F6.5): 12 clases × L1/L3/L5 en
  `test/dragonex/heroes/srd_golden_test.exs`. Oráculos a mano; sin bugs
  de HP/AC/slots/saves vs SRD. Pact Magic (D40) y Sneak Attack (D41) en ✅.
     Feats / features por nivel (salvo Extra Attack D35, Pact Magic D40,
     Sneak Attack D41, Rage D42, Reckless Attack D44, Second Wind D45,
      Divine Smite D46, Action Surge D47, Fighting Style D48, Lay on Hands
      D49, Bardic Inspiration D50, Arcane Recovery D51, Divine Sense D52, Hunter's Mark D55, Font of Magic D56, Cunning Action Hide D57, Danger Sense D58, Evasión D59, Aura of Protection D61, Aura of Courage D62, Wild Shape D63, Uncanny Dodge D64, Metamagic D65, Indomitable D68 y spellcasting paladín/ranger L2) siguen en 🟡. Rasgos
      raciales: Lucky (D66), Resistencia implacable (D67) y Savage
      Attacks (D69) en ✅; Brave, Halfling Nimbleness, Darkvision y demás
      siguen 🟡.

### Contenido custom por usuario
- CRUD `custom_contents` (weapon/spell/item, unique por usuario) con
  **validación server-side** de mecánicas (dados parseables, kind de spell
  válido, ability válida, classes conocidas).
- LiveView `/mi-contenido` (3 pestañas, CRUD inline).
- Merge en `Catalog` con `source: :custom`; builder lo consume vía
  `custom: %{...}` + `extra_equipment`.

### Subida de nivel (XP 5e, D43)
- `World.grant_xp/2` + tool `grant_xp` (DM): suma XP, no sube de nivel,
  no toca hp/slots. D10 SUPERSEDED. Sin calculadora CR.
- `LevelUp.apply/2` — nivel+1 (tope 20), PG (dado medio + CON + racial),
  retro-CON, **RAW no cura** (D11), ASI a `[4,8,12,16,19]` cap 20 (D13),
  AC recalculada, hechizos nuevos (respeta `max_spell_level`), features.
- `World.level_up/2` (path DM) + `Tools.level_up` (excluye PCs humanos).
- Sync a partida viva: `Games.sync_hero_level_up` (DB) +
  `Game.sync_hero_level_up` (GenServer single-writer, D6) +
  `merge_character_level_up` (preserva hp dañado/conditions/slots/AC).
- UI: `HeroLive.LevelUp` (`/heroes/:id/level-up`) con ASI stepper + spell
  picker; `HeroLive.Show` callout si `Progression.can_level_up?/2` (tabla
  PHB; leftover UI D43 cerrado).

### Web / producto
- **Auth** — registro/login/logout (bcrypt, session cookies) vía
  `Accounts` + `UserAuth` plugs.
- **Heroes** — `/heroes` (galería), `/heroes/new` (creator 5 pasos),
  `/heroes/:id` (ficha), `/heroes/:id/edit`, `/heroes/:id/level-up`.
- **Partidas** — `/` (lobby: tuyas + con slots abiertos), `/games/new`
  (wizard 2 tabs), `/games/:id` (mesa + sala de espera multiplayer).
- **Mesa** (`GameLive.Show`): feed agrupado por turnos, dice modal (FSM),
  streaming token-a-token con anti-duplicación, paginación del log (tope 400
  bloques), modal Ajustes (provider/model/reasoning con restart), identidad
  por humano (`?as=<name>` + overlay), "Ver como DM". Responsive ≤720px
  (feed primero, ficha en drawer CSS).
- **Multiplayer** — `join_game` con slots abiertos, waiting room con share
  link, el creador pulsa "Empezar".

### Mejoras transversales (ROADMAP) — todas hechas
- ✅ Cola de intenciones (`declare/3` off-turn, persiste en `games.intents`)
  **y alimenta al TurnMaster** (D27 + D28): brief + re-eval + anti-spam;
  fase en el intent; UI declara durante un beat; `cut_in` de reacción.
- ✅ Recorte estructural D29/D30 (voz PNJ, headers mid-prosa, pregunta del
  DM retiene el floor — cableado en `Game.Turnmaster`).
- ✅ Biblia siembra facts + PC IA no ejecuta solo en exploración (D32).
- ✅ **Refactor estructural D31** — `Game` 2273→~780 con satélites
  `Game.{Bootstrap,Beats,Settlement,Turnmaster,Combat,Persistence,Participants}`;
  `GameLive.Show` 1772→~440 (`Chat`, `Settings`, `Dice`, `Snapshot`,
  `Components`); `HeroLive.New` 1291→~500 (`Heroes.Draft` +
  `New.Components`). Sin cambio de comportamiento; suite al mismo verde que
  la recepción (605/606, el fallo es el D30 pendiente).
- ✅ Robustez del DM (`controlled_by?` directivo + `max_retries: 3`).
- ✅ Caching de prefijo (D20, medido 44–85%).
- ✅ Modelo-por-rol + `max_tokens` (D21).
- ✅ Compactación (`Compaction.Summary`, umbral 250k → efectivamente off con
  modelos de 1M; cableado y funcional).
- ✅ Iniciativa individual por monstruo (D34 / F6.4): un beat por
  combatiente; `World.current_combatant`; DM sigue como controlador.
- ✅ Concentración 5e (D37 / M24): `Character.concentrating` + Codec;
  CON save al daño; rotura a 0 hp / incapacitated-class; tool
  `drop_concentration`. Sin reloj ni efecto de Bless.
- ✅ Resistencias 5e (D38 / M25): tres listas en `Character` + Codec;
  `apply_damage/3`; skeleton SRD; hellish resistance. Concentración
  post-resist; `temp_hp` sobre el amount modificado. Sin magic vs mundane.
- ✅ Pact Magic del warlock (D40): tabla PHB 5.1 (huecos 1º–5º del mismo
  nivel); consume el hueco de pacto, no el del hechizo; short rest
  restaura solo al brujo. Sin Mystic Arcanum ni upcast de daño.
- ✅ Sneak Attack del rogue (D41): `div(level+1, 2)` d6; arma finesse o
  ranged; advantage o aliado consciente; disadvantage bloquea; primer
  hit de `Actions.attack`; crítico 2N d6. Sin grid ni once-per-turn
  entre varias llamadas.
- ✅ Rage del bárbaro (D42): `Character.raging` + Codec; melee
  `rage_damage/1` en cada hit; overlay B/P/S; no spells; STR check
  ventaja; termina en `end_rage` / 0 hp / unconscious / `end_combat`.
  Sin usos/día, sin reloj de 1 minuto.
- ✅ Reckless Attack del bárbaro (D44): `Character.reckless` + Codec;
  melee STR ventaja; cualquier ataque vs el bárbaro ventaja; expira
  al inicio de su turno (`set_current_combatant`); también
  `end_reckless` / 0 hp / unconscious / `end_combat`. Sin cupo/día.
- ✅ Second Wind del fighter (D45): `Character.second_wind_used` + Codec;
  `1d10+level` 1/rest; tool `second_wind`; `short_rest`/`long_rest`
  recargan.
- ✅ Action Surge del fighter (D47): `Character.action_surge_used` + Codec;
  tool `action_surge` = 1 Acción de Ataque extra (Extra Attack D35
  incluido) 1/rest desde L2; hit o miss gasta el uso; rest recarga.
  Sin L17 (2 usos). Sin Indomitable.
- ✅ Fighting Style del fighter (D48): `Character.fighting_style` + Codec
  (`archery` / `defense` / `dueling`); motor suma el bonus (D1); builder
  default `"defense"` sin picker. Sin Protection, TWF, GWF.
- ✅ Divine Smite del paladín (D46): `Character.smite_slot` + Codec;
  tool `divine_smite` arma pendiente (no gasta casilla); primer hit
  melee de `Actions.attack` consume el hueco y tira radiante
  (`2d8+(slot-1)d8`, tope 5d8; undead/fiend +1d8). Extra Attack: solo
  el primer swing que acierte. Sin Improved Divine Smite.
- ✅ Lay on Hands del paladín (D49): `Character.lay_on_hands_pool` +
  Codec; pool `5 * level`; tool `lay_on_hands(who, target, amount)`
  gasta `applied` y cura (self o aliado); long rest recarga, short
  rest no; undead/construct bloqueados. Sin enfermedad/veneno.
- ✅ Bardic Inspiration del bardo (D50): `Character.bardic_inspiration_uses`
  + `inspired` + Codec; usos `max(1, cha_mod)`; tool
  `bardic_inspiration(who, target)` gasta 1 uso y marca inspired;
  el motor aplica 1d6 al primer attack/check/save/death save (primer
  swing, hit o miss); long rest recarga usos y quita inspired, short
  rest no. Siempre d6. Sin Font of Inspiration ni colleges.
- ✅ Arcane Recovery del mago (D51): `Character.arcane_recovery_used` +
  Codec; tool `arcane_recovery(who)` restaura huecos gastados greedy
  (presupuesto `div(level+1, 2)`, ningún hueco > 5º); fuera de combate,
  1/long rest; short rest no recarga. Sin Signature Spells ni Spell
  Mastery.
- ✅ Divine Sense del paladín (D52): `Character.divine_sense_uses` +
  Codec; usos `max(1, 1 + cha_mod)`; tool `divine_sense(who)` gasta 1
  uso y reporta celestial/fiend/undead por `race`; combate permitido;
  long rest recarga, short rest no. Sin Channel Divinity ni 60 ft.
- ✅ Turn Undead del clérigo (D53): `Character.channel_divinity_used` +
  Codec; clérigo L2+ 1/rest; tool `turn_undead(who)` gasta y aplica
  frightened a no-muertos (`race`) que fallen Sabiduría vs DC
  `8+prof+wis`; combate y exploración; short y long rest recargan.
  Sin Destroy Undead, sin dominio, sin 30 ft.
- ✅ Ki + Flurry of Blows del monje (D54): `Character.ki` + Codec;
  máximo `level` (monk L2+, L1 → 0); tool `flurry_of_blows(who,
  target, mode)` gasta 1 ki y resuelve 2 golpes sin armas con el dado
  de artes marciales (`martial_arts_die/1`: 1d4/1d6/1d8/1d10 por
  tramo); combate permitido; short y long rest recargan al máximo.
  Sin Patient Defense, Step of the Wind, Stunning Strike, Deflect
  Missiles ni golpe extra de Martial Arts.
- ✅ Hunter's Mark del explorador (D55): sin campos nuevos — la marca
   vive en `concentrating` (`"hunter's mark:<presa>"`, D37) y gasta 1
   casilla de nivel 1 (`spell_slots`); tool `hunters_mark(who, target)`
   (ranger L2+, DM cualquiera, PC sólo sí mismo) valida who/target,
   caídos, ranger L2+, casilla y no-concentración antes de gastar; el
   motor suma +1d6 por impacto de arma contra la presa (crit dobla,
   tipo del arma, RollLog patrón sneak; spells y Flurry nunca; match
   exacto case-insensitive); fin sólo por las rutas existentes de
   concentración; rests sin cambios (RAW la marca persiste). Sin
   bonus action economy, tracking, múltiples presas, transferir ni
   Branding Smite.
 - ✅ Font of Magic del hechicero (D56): `Character.sorcery_points` +
    Codec (jsonb viejo → 0); máximo `level` (sorcerer L2+, L1 → 0);
    tools `create_spell_slot(who, level)` (nivel 1..5, coste RAW
    2/3/5/6/7 vía `sorcery_slot_cost/1`, puede superar el máximo
    diario) y `convert_to_sorcery_points(who, level)` (drena 1 casilla
    1..5 y recupera esos puntos con cap silencioso al máximo; el
    mensaje muestra el resultado real); DM cualquiera, PC sólo sí
    mismo; combate permitido; errores no mutan (missing who, caído, no
    hechicero, L1, nivel inválido, puntos insuficientes, sin casillas);
    SOLO long rest rellena al máximo (distinto del ki D54); level-up no
    resetea. Sin sorcerous restoration (Metamagic entró en D65).
 - ✅ Cunning Action (Hide) del pícaro (D57 / M41): sin campos nuevos —
    "hidden" vive en `conditions` (`apply_condition`, M06 le añade
    ventaja al atacar); tool `cunning_action_hide(who)` (rogue L2+, DM
    cualquiera, PC sólo sí mismo) valida who, caído, clase/nivel y no
    ya oculto antes de tirar; el motor resuelve 1d20 + DES + prof (si
    "stealth" entrenado; modo vía `check_mode`) vs la máxima
    percepción pasiva de enemigos conscientes (10 + SAB + prof si
    "perception" entrenada; DC 10 sin enemigos); éxito → "hidden" →
    ventaja en `make_attack` (cancela con desventaja, habilita Sneak
    Attack D41 sin aliado); el ataque (o hechizo de ataque) revela y
    quita "hidden" (hit o miss); RollLog patrón ability_check; errores
    no mutan. Sin Dash/Disengage (sin grid), sigilo sostenido,
    Uncanny Dodge, feats ni multiclase.
 - ✅ Danger Sense del bárbaro (D58 / M42): pasiva sin tool ni campos
    nuevos — `Rules.Conditions.save_mode/3` da ventaja en TODAS las
    salvaciones de DES del bárbaro L2+ (combinada vía `combine`: la
    desventaja de condición —restrained— se cancela a normal); corte de
    incapacitación = `@auto_fail_saves` (paralyzed/stunned/unconscious/
    petrified auto-fallan DES antes de computar la ventaja); el
    `mode_tag` existente muestra "(ventaja)"; WIS y otros saves no
    cambian.
  - ✅ Evasión del pícaro (D59 / M43): pasiva sin tool ni campos nuevos
     — en la rama `:save` de `cast_spell`, un pícaro L7+ ante un hechizo
     con salvación de DES recibe 0 daño si supera la salvación (aunque
     mitigara a mitad) y `div(full, 2)` si falla (aunque fuera daño
     completo); hechizo que ya haría 0 sigue en 0; inspiración bárdica
     aplicada antes activa Evasión; desglose "(Evasión: sin daño)" /
     "(Evasión: mitad)"; pícaro incapacitado auto-falla y no llega a
     aplicar Evasión; saves no-DES y daño sin save ignoran Evasión.
  - ✅ Proficiency de skills en ability_check + Jack of All Trades
     (D60 / M44): arregla el hueco v1 (la tool ignoraba
     `skill_proficiencies`). Nueva tabla `Rules.Skills` (18 skills SRD →
     característica, normalización espacios/guiones/mayúsculas,
     detección skill-primera — "intimidation" es CAR, no `int`); la tool
     `ability_check` mantiene arity y nombre de parámetro (compat:
     exAgent bindea args por nombre); skill entrenado → prof completa
     desde la ficha; sin entrenar y bardo L2+ → mitad (JoaT, floor);
     ability cruda → flag del caller (formato v1); mensaje ES con
     desglose ("chequeo de Sigilo (DES): 1d20(11) + DES 3 + prof 2…",
     "+ JoaT 1"); error directivo con ejemplos en desconocidos. Sin
     campos nuevos ni Codec; `cunning_action_hide` D57 intacta. Sin
      Expertise, tools/instrumentos, Reliable Talent, feats, multiclase.
   - ✅ Aura of Protection del paladín (D61 / M45): pasiva sin tool ni
      campos nuevos — todo paladín L6+ consciente suma
      `modifier(cha)` a TODAS las salvaciones de su `side` (él
      incluido): rama `:save` de `cast_spell`, `turn_undead` (SAB),
      death saves (RAW aplica; desplaza el umbral 10 sin tocar nat
      1/20 vía `Combat.death_save/2`) y concentración (CON al daño);
      varios paladines apilan; CHA < 10 → bonus negativo sin piso;
      se aplica antes de la inspiración bárdica (D50 re-deriva del
      total); desglose "+3 aura" / "(-1 aura)" en el mensaje; sin
      radio (simplificación sin-grid por side, regla genérica: un
      no-muerto aliado también lo recibe). NO a checks ni attack
      rolls. Sin Aura of Devotion/Hate, Improved Divine Smite.
    - ✅ Aura of Courage del paladín (D62 / M46): pasiva sin tool ni
       campos nuevos — `World.apply_condition` NO aplica
       "frightened" a quien comparte side con un paladín L10+
       consciente (él incluido): `{:ok, world}` sin mutar
       (inmunidad ≠ error); `Tools.apply_condition` (DM) devuelve "X
       es inmune al miedo (Aura de Coraje)" y `turn_undead` particiona
       sus fallidos en asustados/inmunes con la misma frase (doble
       hook: defensa en profundidad); regla genérica por side (un
       no-muerto aliado de un paladín L10+ es inmune, documentado);
       idempotencia y `remove_condition` intactos. Sin radio, sin
       inmunidad a charm (Aura of Devotion, futuro).
    - ✅ Wild Shape del druida (D63 / M47): `Character.wild_shape_uses`
       + `wild_shape` (mapa de forma guardada) + Codec (jsonb viejo →
       0/nil); catálogo fijo `Monsters.wild_shape_beasts/0` (cat ND 0,
       wolf ND 1/4, black_bear ND 1/2 — cat y black_bear nuevos en
       `Monsters`, también spawnables); tools `wild_shape(who, beast)`
       / `end_wild_shape(who)` (druida L2+, DM cualquiera, PC sólo sí
       mismo, errores NO mutan); al transformar gasta 1 uso SIEMPRE
       (2/rest), guarda str/dex/con/hp/max_hp/ac/weapons y aplica los
       de la bestia conservando mental/identidad/profs/condiciones/
       concentración (RAW); inventario intacto siempre; gate de CR
       L2–3 → 1/4, L4+ → 1/2; `cast_spell` bloqueado en forma (todo lo
       demás igual); revert manual restaura TODO con PG = orig exacto;
       auto-revert en `World.apply_damage/3` (cuello único): exceso =
       daño que sobra tras la bestia → `hp = max(0, orig_hp − exceso)`
       (temp_hp y resist como siempre) con nota en el log para la
        narración; short Y long rest recargan usos (como ki D54, sin
        forzar revert); level-up no toca usos ni forma. Sin duración,
        Circle of the Moon, formas volar/nadar, equipment merge.
    - ✅ Uncanny Dodge del pícaro (D64 / M48): `Character.uncanny_dodge`
       (boolean, default false; Codec tolerante a jsonb viejo) + tool
       `start_uncanny_dodge(who)` (pícaro L5+, DM cualquiera, PC sólo
       sí mismo, errores NO mutan: who inexistente, caído, no pícaro,
       L4–, ya armada); postura armable gratis en cualquier momento
       (sin reacciones ni rondas en el motor, patrón `inspired`/
       `reckless`); en `World.apply_damage/3` (cuello único): armada y
       amount > 0 → `div(amount, 2)` (floor) sobre el amount de
       entrada — antes de resistencias D38 y temp_hp D36 (orden fijado
       en D64) — y consume la flag; CUALQUIER fuente de daño; amount
       ≤ 0 no consume; apila con Evasión D59 (mitad de mitad = cuarto,
       floor); auto-revert D63 intacto (corre tras la mitigación);
        descansos NO gestionan la flag; rearmar tras consumir es
        gratis. Sin economía de reacción/ronda (1 uso por daño),
        resistencias dañinas, Deflect Missiles, feats, multiclase.
    - ✅ Metamagic del hechicero (D65 / M49): `Character.metamagic`
       (nil | `%{option, target}`, claves átomo en memoria/strings en
       Codec, jsonb viejo → nil) + tool `arm_metamagic(who, option,
       target)` (hechicero L3+, DM cualquiera, PC sólo sí mismo, UNA
       opción, SIN un-arm ni reembolso; errores NO mutan: who
       inexistente, caído, no hechicero, L2–, opción desconocida, ya
       armada, puntos insuficientes con coste exacto, heightened sin
       target, twinned sin target/inexistente/self); armar gasta 1/3/2
       puntos vía `spend_sorcery_points` (D56) y fija el mapa;
       aplicación y consumo SÓLO en `Actions.spell/5` → `resolve_spell`:
       Empowered (dados de daño — los primeros `max(1, CAR)` dados se
       tiran dos veces conservando el mayor, dos draws del roller por
       dado; crit dobla la base sin duplicar rerolls; fallo de :attack
       también consume; curación/utilidad nunca califican; etiqueta
       "(Metamagia: Empowered)"), Heightened (hechizo :save al target
       armado → salvación con desventaja como `requested` en
       `save_mode`, combinada por capas con D58-D62; otro objetivo → no
       aplica ni consume; etiqueta "(Metamagia: Heightened)"), Twinned
       (hechizo contra target ≠ lanzador → misma resolución también
       contra el segundo target armado, dados propios por resolución,
       bloque por objetivo, UNA casilla y UNA concentración; self-buff o
       twin desaparecido → no aplica ni consume); consumo-on-apply
       (divergencia menor de RAW documentada); rests y level-up NO tocan
       la metamagia (los puntos ya se recargan en long rest D56). Sin
       Quickened, Distant, Extended, Subtle, Careful (sin efecto en este
       motor), Sorcerous Restoration, Metamagic Adept, feats,
       multiclase.
    - ✅ Lucky del mediano (D66 / M50, pasiva racial sin tool): en las
       tres tiradas de d20 con personaje de `Rules.Combat`
       (`attack_roll`, `saving_throw`, `ability_check`), si el d20
       EFECTIVO (conservado tras ventaja/desventaja) es 1 → UN reroll
       y se USA el nuevo resultado (RAW "must use the new roll"; no
       keep-best; nat-1/20 del ataque sobre el dado final); el reroll
       pasa por el mismo roller (RollLog registra ambos dados);
       firmas públicas intactas vía variantes `*_tagged` que devuelven
       la etiqueta "(Lucky: 1→N)" pintada tras el dado en todos los
       desgloses (ataque, salvación de hechizo, concentración, chequeo,
       Sigilo); death saves no aplican; monstruos medianos también.
       Sin Brave/Halfling Nimbleness, feats, multiclase.
     - ✅ Resistencia implacable del semi-orco (D67 / M51, pasiva racial
        sin tool): `Character.relentless_endurance_used` (default false,
        jsonb viejo → false) + hook en `World.apply_damage/3` con orden
        de capas fijado (Uncanny Dodge D64 mitiga amount → resist D38 →
        temp_hp D36 → hp → auto-revert Wild Shape D63 → RE: hp 0 → 1
        con nota en el log "la furia semi-orca mantiene a X en pie con
        1 pg (Resistencia implacable)" → death saves); 1 uso por
        descanso largo (`long_rest` recarga vía
        `World.set_relentless_endurance/2`, `short_rest` no); ya gastada
        → 0 pg normal; al salvar a 1 no se limpian flags de caído.
        Sin Savage Attacks, Darkvision, feats, multiclase.
     - ✅ Indomitable del guerrero (D68 / M52, pasiva de clase sin tool):
        `Character.indomitable_used` (default false, jsonb viejo →
        false) + helper `maybe_indomitable/7` en `Actions` aplicado en
        los TRES sitios donde el personaje salva (hechizo `:save`,
        `turn_undead` SAB, concentración CON): fallo FINAL de un
        guerrero L9+ con el uso disponible → UN reroll con la misma
        llamada `Combat.saving_throw_tagged/5` (mismo modo de
        Heightened/Danger Sense/condiciones; el aura D61 se re-suma; el
        d6 bárdico se gastó en el primer intento; Lucky D66 puede
        dispararse gratis en el reroll) y se USA el nuevo resultado (RAW,
        no keep-best); marca `indomitable_used` vía
        `World.set_indomitable/2` (el struct actualizado viaja a la
        simulación de concentración y se hilva entre golpes de una misma
        acción — sin doble gasto); etiqueta "(Indomitable: X→Y)" en el
        desglose (totales; en turn_undead pegada al nombre); 1 uso por
        descanso largo (`long_rest` recarga, `short_rest` no); death
        saves y auto-fails fuera (no hay dado). Sin usos L13/L17,
        checks/attack rolls, feats, multiclase.
     - ✅ Savage Attacks del semi-orco (D69 / M53, pasiva racial sin
        tool, sin campos ni rests): hook en `Combat.damage_roll/4` vía
        nueva variante pública `damage_roll_tagged/4` que devuelve
        `{total, savage_die}` (firma de `damage_roll/4` intacta, patrón
        `*_tagged` D66) — `race == "half-orc"` + arma melee
        (`ranged != true`) + `:crit` → UN dado del TAMAÑO del arma (un
        2d6 añade 1d6, no otra tirada completa; nunca doblado); NO a
        distancia, hechizos ni no-críticos; apila con sneak D41 / smite
        D46 / mark D55 / rage D42; el golpe sin armas de Flurry D54
         también aplica; desglose " (+N Savage)" en el swing (patrón
         sneak). Sin Darkvision, feats, multiclase.
      - ✅ Usos de Furia + Furia implacable del bárbaro (D72 / M56):
         `Character.rage_uses_used` y `relentless_rage_successes`
         (integer default 0, Codec tolerante a jsonb viejo) +
         `Progression.rage_count/1` (L1–2 2, L3–5 3, L6–11 4, L12–16 5,
         L17+ 6). `World.start_rage/1` exige usos disponibles ("no le
         quedan furias hoy (N/N usadas)" sin mutar) y gasta 1 al ENTRAR;
         `end_rage` NO devuelve el uso; ya raging → idempotente sin
         gasto extra; sólo `long_rest` recarga. Furia implacable: hook
         `maybe_relentless_rage/4` en `World.apply_damage/4` (nuevo
         parámetro opcional `roller`, hilvanado por
         `Actions.pipe_damage`), bárbaro L11+ raging a 0 pg →
         salvación CON vs `10 + 5 × successes` vía
         `Rules.Combat.saving_throw` (prof de CON + Lucky D66) + aura
         D61 (`World.aura_save_bonus/2`, movida de Actions); éxito →
         1 pg, successes+1 y nota en el log del world (sin RollLog a
         esa profundidad — la nota ES el registro); fallo → cae al
         siguiente check (RE racial D67 si semi-orco: ambas capas, el
         éxito de clase no consume la racial); orden de capas fijado
         Uncanny Dodge → resist → temp_hp → hp → revert → Furia
         implacable → RE. Sin duración/reloj, bonus action, Paths,
         Persistent Rage L20, feats, multiclase.
  - ✅ XP 5e en partida (D43): `World.grant_xp/2` + tool `grant_xp` (DM).
  Suma XP; no auto-level-up. Subida explícita (ficha / `level_up`).
  D10 SUPERSEDED. Sin calculadora CR/encuentro.

---

## 🟡 Simplificaciones v1 documentadas (deudas técnicas asumidas)

| Ítem | Decisión | Ref |
|---|---|---|
| Dotes | Fuera; ASI = +2 fijo | D13 |
| `spells_known` | `nil` (sin cap estricto por clase) | D14 |
| Features por nivel | Extra Attack D35 + Sneak Attack D41 + Rage D42 (+ usos/Furia implacable D72) + Reckless Attack D44 + Second Wind D45 + Divine Smite D46 + Action Surge D47 + Fighting Style D48 + Lay on Hands D49 + Bardic Inspiration D50 + Arcane Recovery D51 + Divine Sense D52 + Turn Undead D53 + Ki/Flurry of Blows D54 + Hunter's Mark D55 + Font of Magic D56 + Cunning Action Hide D57 + Danger Sense D58 + Evasión D59 + Jack of All Trades D60 + Aura of Protection D61 + Aura of Courage D62 + Wild Shape D63 + Uncanny Dodge D64 + Metamagic D65 + Indomitable D68 + spellcasting paladín/ranger L2; el resto 🟡 | D35, D41, D42, D44, D45, D46, D47, D48, D49, D50, D51, D52, D53, D54, D55, D56, D57, D58, D59, D60, D61, D62, D63, D64, D65, D68, D72 |
| Rasgos raciales | Lucky D66 + Resistencia implacable D67 + Savage Attacks D69 + Astucia gnoma D71 (automáticos, sin tool) + Aliento de dragón D70 (tool racial); Brave, Halfling Nimbleness, Darkvision y demás 🟡 | D66, D67, D69, D70, D71 |
| Empate iniciativa | DEX score desc, luego nombre; sin roll-off extra | D39 |
| Banner level-up in-game | Eliminado (D33); subida desde la ficha | D33 |
| Stub legado en `Tools` | `attack`/`roll`/`spawn_character`/`next_round` mantenidos para tests del framework exAgent | `tools.ex:31-72` |

---

## 🔴 Pendiente / fuera de v1

- **Multi-nodo** (`Horde`) — pausado (D24).

---

## Cómo se mide "hecho"

Una feature entra en ✅ cuando:
1. Tiene tests deterministas (o smoke test si toca LLM).
2. `MIX_ENV=test mix test` está verde.
3. Su decisión de diseño (si la hay) está en `docs/decisions.md`.
4. No deja `TODO`/`FIXME` sin dirección en `lib/`.

No se marca hecha por "el commit existe" sino por "se verifica".
