# Handoff — Revisión profunda del Level-Up (Dragonex)

Eres un agente que continúa **Dragonex** (D&D 5e con DM por IA sobre exAgent /
Phoenix 1.8 / Elixir 1.20). Tu tarea: **revisar a fondo la mecánica de subida
de nivel**, cubrir todos los escenarios y side-effects, y probarla (automatizada
+y en vivo con LLM). El usuario quiere cerrar esta feature con confianza.

Stack: package manager **mix** (NUNCA npm). Tests: `MIX_ENV=test mix test`.
Arranque: `docker compose -f compose.dev.yml up -d` (Postgres + app en
`http://localhost:4035`, source montado en `.:/app` con `code_reloader: true`
→ los cambios se aplican al refrescar el navegador).

**Estado actual: worktree limpio, `mix compile` ok, 517 passed / 3 excluded.**

---

## 0) Qué se ha hecho en esta sesión (commits sobre `b0b8b48`)

```
c9808b5 feat(custom-content): richer list (detail columns) + named delete confirm
61e9f38 fix(custom-content): rewrite form to stop resetting / losing the name
0c94c6e fix(level-up): half-caster casting, AC sync, ASI/spell guards   ← LEVEL-UP
84c8b64 fix(custom-content): form UX + move "Crear contenido" button
582c454 feat(dev): runtime model selector + reasoning catalogue
3d24005 feat(game): in-game level-up with milestone progression          ← LEVEL-UP
81ffc08 feat(heroes): user custom content library
```

Tres features grandes (contenido custom por usuario, level-up en partida,
selector de modelo en runtime) + pulido de UI. **Tu foco es el level-up.**

---

## 1) Modelo de progresión elegido: MILESTONE

El level-up es **por hito** (no por XP). El DM decide "subes de nivel"; el
jugador humano lo ejecuta desde la **ficha del héroe** (`/heroes/:id/level-up`),
disponible siempre que `level < 20` (sin gate de XP). Los PCs de IA los sube el
DM con la tool `level_up`.

Consecuencias importantes (no bugs, decisiones):
- **No hay fuente de XP en partida.** Se eliminaron los botones "Simular XP".
  Se conserva la infraestructura de XP (`Accounts.grant_xp/3`, campo `Character.xp`,
  `Progression.can_level_up?/2`) pero **sin callers en la UI**.
- **El banner de level-up dentro de la mesa** (`GameLive.Show:viewer_level_up`)
  sigue gateado por `Progression.can_level_up?(level, xp)`. Como no hay fuente de
  XP, es **inerte** bajo milestone: nunca se muestra. No rompe nada; queda latente
  para cuando se wiree a un "DM grant trigger". (Abierto: ver §5.)

---

## 2) Arquitectura del level-up (el mapa)

```
Fuente de verdad del héroe (biblioteca)         Partida viva (GenServer)
─────────────────────────────────────           ─────────────────────────
Hero.sheet (jsonb)                               games.world (jsonb, Character vivo)
  │ Accounts.level_up_hero/3                       │
  │  → Heroes.apply_level_up/2  (delega)           │ World.level_up/2  (path DM)
  │  → Heroes.LevelUp.apply/2  ◄── núcleo ──►      │  → Heroes.LevelUp.apply/2
  │  persiste en heroes.sheet                      │  + refresca spell_slots
  │                                                │
  └─ HeroLive.LevelUp (UI): al confirmar ─────────┤ sync_hero_level_up/2
     elige spells/ASI, luego sincroniza a partidas │  · Game.sync_hero_level_up (GenServer vivo)
     donde esté el héroe (Games.games_using_hero)  │  · Games.sync_hero_level_up (si no hay proceso)
                                                    └─ merge_character_level_up: aplica deltas
                                                       al Character vivo SIN pisar transitorio
```

**Módulos clave:**
| Archivo | Qué hace |
|---|---|
| `lib/dragonex/heroes/progression.ex` | Tablas puras: XP, niveles ASI `[4,8,12,16,19]`, `max_spell_level/2`, `features_at/2`. **Fuente de verdad.** |
| `lib/dragonex/heroes/level_up.ex` | `LevelUp.apply/2` — el núcleo: nivel+1, PG (dado medio+CON), **retro-CON**, ASI (cupo+cap 20), AC recalculada, hechizos nuevos, features. |
| `lib/dragonex/heroes.ex` | `Heroes.apply_level_up/2` — thin delegate a `LevelUp.apply/2`. |
| `lib/dragonex/world.ex` | `World.level_up(name, choices \\ %{})` — aplica al Character vivo + refresca slots. Path del DM. |
| `lib/dragonex/tools.ex` | `deftool level_up(ctx, target, opts)` — el DM la llama; `normalize_level_up_opts/1` mapea el JSON del LLM (`spells`/`asi`) a choices. Rechaza PCs humanos. |
| `lib/dragonex/games.ex` | `sync_hero_level_up/3` + `merge_character_level_up/3` — sync a partida (preserva hp dañado/conditions/slots). |
| `lib/dragonex/game.ex` | `Game.sync_hero_level_up/3` (call al GenServer, single-writer) + `handle_call`. |
| `lib/dragonex/accounts.ex` | `level_up_hero/3` + `grant_xp/3` (este último sin caller UI). |
| `lib/dragonex/dm.ex` | Prompt del DM: explica `level_up("nombre", {spells/asi})`. |
| `lib/dragonex_web/live/hero_live/level_up.ex` | UI de subida (ASI stepper + spell picker). |
| `lib/dragonex_web/live/hero_live/show.ex` | Ficha: callout "Subir de nivel" cuando `level < 20`. |

`Codec` serializa el `Character` (incluido `xp`) a/desde jsonb — cualquier campo
nuevo al Character debe ir al `encode/decode` o no sobrevive.

---

## 3) Verificado y correcto (no lo repitas)

- **Tabla XP** coincide exactamente con SRD 5.1.
- **HP del nivel nuevo** = `div(hit_die,2)+1` + CON + bono racial (hill dwarf +1). Correcto.
- **Retro-CON** = `(new_mod − old_mod) * c.level` aplicado a max_hp y hp. Correcto 5e.
- **ASI** a `[4,8,12,16,19]`, 2 puntos, cap 20.
- **`max_spell_level`**: full-caster `min(div(level+1,2),9)`; half-caster L2=1…L17+=5; L1=0 (no lanza). Correcto.
- **AC recompute** en `LevelUp.apply` cubre sin armadura / ligera / media / pesada + escudo + Defensa sin Armadura (monje/barbarian).
- **Single-writer**: la sync viva va por call al GenServer; `persist` lee de `Session.read_state`, así que una sync aplicada sobrevive a la siguiente persistencia de beat. La carrera advertida en docs está mitigada.

---

## 4) Bugs ya arreglados en `0c94c6e` (para que no los repitas)

- **HIGH-1**: paladín/ranger recibían hechizos con `casting_ability: nil` al subir a L2 (`Classes` no declara `spellcasting` para half-casters a L1) → crasheaba el beat al lanzarlos. Fix: `casting_ability_for/1` + `half_caster_ability/1` (paladín→`:cha`, ranger→`:wis`). Tests `H1`/`H1b`.
- **HIGH-2**: la sync a partida viva **no propagaba la AC** tras un ASI de DEX/CON/WIS (el merge descartaba `new_sheet.ac`). Fix: añadido `ac:` en `merge_character_level_up`. Test `H2`.
- **MEDIA-3**: ASI negativo permitía al LLM saltarse el cupo (`%{"str"=>3,"con"=>-1}`). Fix: `apply_asi` ignora `delta <= 0`; `asi_used` filtra `> 0`.
- **MEDIA-4**: el motor no validaba nivel de hechizo ≤ `max_spell_level`. Fix: `apply/2` computa `max_sl` y rechaza hechizos por encima (y no añade spells a no-casters).
- **LOW-7**: hechizos duplicados entre subidas. Fix: `Enum.uniq_by(c.spells ++ new_spells, & &1.name)`.

---

## 5) ABIERTOS — revisa y decide

### A. Defectos declarados (LOW, pendiente de decisión del usuario)

- **LOW-5 — Subir de nivel cura / revive a un caído.** `LevelUp.apply` hace
  `hp: c.hp + hp_gain + con_retro`; `merge_character_level_up` hace
  `hp: max(0, live.hp + hp_delta)`.
  - Para un personaje **dañado**, el déficit se conserva (correcto: `new_hp = new_max − daño`).
  - Para un personaje **caído (0 hp)**, `new_hp = hp_gain > 0` → **revive**. 5e no cura por subir nivel.
  - **Pregunta abierta**: ¿"subir cura" es regla de casa querida o un bug? Hoy cura siempre. Decidir y, si es bug, no sumar `hp_gain` al hp actual (solo al max_hp) en rama biblioteca, y en el merge dejar el déficit (que ya lo hace salvo el caso 0 hp).

- **LOW-6 — Warlock modelado como full-caster.** `progression.ex:55,114` +
  `spell_slots.ex`. Pact Magic real es distinto (huecos 1º–5º, short rest, 1 Mystic
  Arcanum por nivel 6º–9º). Aquí recibe la tabla full-caster con 6º–9º. `spell_slots.ex`
  lo documenta como simplificación; `progression.ex` no. Impacto bajo a niveles típicos.

### B. Cobertura de tests que FALTA (la review anterior las listó; añádelas)

- **Preservación explícita de `temp_hp`, `death_saves`, `conditions`** a través de
  `merge_character_level_up` (estructuralmente se conservan con `%{live | …}`, pero
  **no hay aserción**). `multi_level_test.exs` cubre conditions solo en `World.level_up`.
- **Cupo ASI con negativos** (MEDIA-3 arreglado pero sin test directo).
- **Validación de nivel de hechizo en el motor** (MEDIA-4 arreglado pero sin test: un mago L1 no debería ganar un hechizo de 9º).
- **Tope nivel 20 en la sync** (path directo `Games.sync_hero_level_up` sobre un héroe ya a 20).
- **GenServer sync preservando hp dañado**: `game_sync_genserver_test.exs` solo afirma `level==2`, NO que el daño sufrido se conserva (a diferencia del test de `Games.sync_hero_level_up` que sí). Añadir esa aserción al path vivo.
- **Warlock subiendo de nivel** (escala de slots / max_spell_level).

### C. UX / producto

- **Banner in-game inerte** bajo milestone (§1). Si se quiere un nudge en la mesa,
  wirear `viewer_level_up` a un flag "DM granted" en vez de a XP. No es bloqueante.
- **Spell nuevo por defecto**: `blank_editing` arranca `spell_kind: "save"` con
  `save_ability: ""` → un hechizo nuevo falla validación hasta elegir salvación (o
  cambiar el kind). Mensaje claro, pero es una pequeña fricción.

---

## 6) Escenarios a revisar/probar (checklist)

**Mecánica 5e (`LevelUp.apply` + `Progression`):**
- [ ] Fighter 1→2 (solo PG), 3→4 con ASI (+2 / +1+1), cap 20.
- [ ] Mago 2→3 puede añadir hechizos de **nivel 2**; mago 1→2 solo nivel 1 y trucos.
- [ ] Paladín 1→2: gana `spellcasting` + hechizos lanzables (`casting_ability :cha`). Ranger 1→2 (`:wis`).
- [ ] Retro-CON al subir CON vía ASI a nivel 4 (verifica el multiplicador por niveles previos).
- [ ] AC tras ASI de DEX (ligera/sin armadura sube; pesada no) y de WIS/CON (Defensa sin Armadura).
- [ ] Hechizo de nivel > max_spell_level se **rechaza**; no-caster no gana hechizos.
- [ ] Nivel 20: se rechaza la subida (biblioteca y sync).
- [ ] LOW-5: comportamiento al subir un personaje dañado y un caído (decide cura sí/no).

**Side-effects / sync a partida:**
- [ ] Héroe en partida viva: subir desde la ficha → el Character vivo sube nivel, max_hp, **AC**, spells, features; y **conserva** hp dañado (déficit), condiciones, death_saves, temp_hp, slots usados.
- [ ] Sync por GenServer vivo (`Game.sync_hero_level_up`) Y por DB (`Games.sync_hero_level_up` cuando no hay proceso).
- [ ] Carrera: si el Game está procesando un beat, la sync no se pierde (se reaplica en el próximo beat/persist).
- [ ] Rehidratación tras "crash": el estado subido sobrevive (`games.world` jsonb).

**Tool del DM (`Tools.level_up`):**
- [ ] PC humano → rechazo con mensaje ("sube desde su ficha").
- [ ] PC IA con `opts` `{"asi":{"str":2}}` a nivel 4 → aplica; en otro nivel → ignora ASI.
- [ ] `opts` `{"spells":["bless"]}` → añade con casting_ability correcto.
- [ ] `opts` basura del LLM (claves raras, asi negativo, spells inexistentes) → no rompe, se normaliza a seguro.

---

## 7) Cómo probar

**Automatizada:** `MIX_ENV=test mix test`. Ficheros relevantes:
`test/dragonex/heroes/{level_up,progression}_test.exs`,
`test/dragonex/tools_level_up_test.exs`,
`test/dragonex/{games_sync,game_sync_genserver,multi_level}_test.exs`,
`test/dragonex/accounts/level_up_test.exs`,
`test/dragonex_web/hero_level_up_live_test.exs`.

Para tests deterministas con mundo/sesión real, mira el patrón de
`test/dragonex/tools_level_up_test.exs` (`start_session` + `Session.start` +
`SharedState.new` + `Tools.level_up`) y `test/support/harness.ex`.

**En vivo (LLM real):** necesita `OPENROUTER_API_KEY` en `.env.dev`. Flujo:
1. Crea/usa un héroe en `/heroes`; abre su ficha (`/heroes/:id`) → callout **"Subir de nivel"** (visible si `level < 20`).
2. Elige hechizos/ASI → Confirmar. Vuelve a la ficha: nivel/PG/AC/spells actualizados.
3. Para la **sync a partida**: crea una partida con ese héroe, súbelo desde la ficha en otra pestaña, vuelve a la mesa → el Character vivo refleja la subida.
4. Para PCs de IA: en una partida con un PC IA, induce al DM a conceder `level_up("nombre", {asi/spells})` en un hito narrativo y observa que aplica.

---

## 8) Convenciones (no las rompas)

- **No cambiar la forma** de `Character`/`Weapon`/`Spell`/`Item`. Campos nuevos → `Codec`.
- **Single-writer**: el `World` se muta solo vía el GenServer/Session; la sync viva enruta por `Game.sync_hero_level_up`, nunca escritura directa a `games.world` desde la LiveView.
- **Builder offline**: `Heroes.build` y `Catalog` no tocan DB (tests `async: true`). El contexto custom se **inyecta**, no se consulta dentro.
- `String.to_atom` en el codec (no `to_existing_atom`). Fuera del codec, usa `to_existing_atom`.
- Estilo: `mix format` antes de commit; mensajes tipo `fix(level-up): …`.

Al terminar, deja `MIX_ENV=test mix test` en verde y resume qué decidiste sobre LOW-5/LOW-6, qué tests añadiste, y qué encontraste probando en vivo.
