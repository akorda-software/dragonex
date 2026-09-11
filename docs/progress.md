# Dragonex — progreso y estado

Estado canónico por feature. **Esta es la fuente de la verdad sobre qué está
hecho, qué falta y qué se simplificó.** Si el `ROADMAP.md` o cualquier handoff
histórico (`docs/historical/`) discrepan con esto, manda este doc.

- Verde de referencia: **971 tests passed** (`MIX_ENV=test mix test`), compile
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
- `Actions` — puente intent→world (`attack` con Extra Attack 5e / D35,
  Sneak Attack D41, Rage D42 y Divine Smite D46, `spell` automatic/attack/save + consumo de slot, False Life → temp_hp D36,
  concentración D37, resist/vuln/immune D38, `initiative`, `death_save`, `heal`,
   `second_wind`, `action_surge`, `lay_on_hands`, `short_rest`, `long_rest`, `check`). Con `RollLog` para dados estructurados.
- `Tools` — `deftool`s que el LLM invoca: `make_attack`, `cast_spell`,
   `roll_initiative`, `make_death_save`, `heal`, `grant_temp_hp`, `grant_xp`, `drop_concentration`, `start_rage`, `end_rage`, `start_reckless`, `end_reckless`,    `second_wind`, `action_surge`, `divine_smite`, `end_smite`, `lay_on_hands`, `ability_check`, `end_combat`,
  `short_rest`, `long_rest`, `spawn_monster`, `apply_condition`,
  `remove_condition`, `set_scene`, `establish_fact`, `level_up`, `roll_dice`.
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
   D49 y spellcasting paladín/ranger L2) siguen en 🟡.

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
- ✅ XP 5e en partida (D43): `World.grant_xp/2` + tool `grant_xp` (DM).
  Suma XP; no auto-level-up. Subida explícita (ficha / `level_up`).
  D10 SUPERSEDED. Sin calculadora CR/encuentro.

---

## 🟡 Simplificaciones v1 documentadas (deudas técnicas asumidas)

| Ítem | Decisión | Ref |
|---|---|---|
| Dotes | Fuera; ASI = +2 fijo | D13 |
| `spells_known` | `nil` (sin cap estricto por clase) | D14 |
| Features por nivel | Extra Attack D35 + Sneak Attack D41 + Rage D42 + Reckless Attack D44 + Second Wind D45 + Divine Smite D46 + Action Surge D47 + Fighting Style D48 + Lay on Hands D49 + spellcasting paladín/ranger L2; el resto 🟡 | D35, D41, D42, D44, D45, D46, D47, D48, D49 |
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
