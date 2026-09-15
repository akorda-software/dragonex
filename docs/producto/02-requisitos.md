# Requisitos del producto

> **Producto.** El **contrato de iteración** de Dragonex: qué debe hacer la
> aplicación, con identificadores estables y criterios de aceptación verificables.
> Los agentes (y humanos) trabajan contra este doc: una feature está **hecha**
> cuando sus `AC` pasan y el estado pasa a ✅ en [`../progress.md`](../progress.md).

Convenciones:

- **`Rxx`** — identificador estable del requisito (no se renumera; si se
  descarta, se tacha con nota, no se borra).
- **`AC-x`** — criterio de aceptación verificable. Cada AC nombra **cómo se
  verifica** (test determinista, smoke, inspección) — nunca "funciona".
- **Estado** — ✅ hecho y probado · 🟡 simplificación asumida (con ADR) ·
  🔴 pendiente. El estado vivo vive en [`../progress.md`](../progress.md);
  aquí se refleja para contexto.
- Prioridad de producto (orden de importancia): **1** motor correcto ·
  **2** bucle de partida robusto · **3** creador de héroes fiel al SRD ·
  **4** mesa usable · **5** multiplayer · **6** pulido (mobile, UX).

Fuente de verdad complementaria: los ADR de [`../decisions.md`](../decisions.md)
(`D1`–`D77`), las mecánicas `M1`–`M60` de
[`../tecnico/08-catalogo-mecanicas.md`](../tecnico/08-catalogo-mecanicas.md) y
el contrato de tools de [`../tecnico/07-contrato-tools.md`](../tecnico/07-contrato-tools.md).

---

## Área A — Cuenta y héroes

### R01 — Cuenta de usuario ✅
Registro, login y logout con email + contraseña (bcrypt, session cookies).

- AC-1.1: registro → login → sesión persistente → logout, test en
  `test/dragonex/accounts_test.exs`.
- AC-1.2: rutas protegidas redirigen a login sin sesión (`test/support/conn_case.exs`).

### R02 — Galería de héroes ✅
`/heroes` lista los héroes del usuario; cada héroe es un personaje 5e reusable
entre partidas (persistido como snapshot en `heroes`).

- AC-2.1: la galería muestra sólo los héroes del usuario logueado.
- AC-2.2: un héroe borrado no rompe partidas pasadas (la partida guarda su
  propia copia en `participants`/world).

### R03 — Creador de héroes en 5 pasos ✅
`/heroes/new` wizard: identidad (raza+subraza, clase) → linaje (background) →
equipo (grupos con opciones) → atributos (standard array / point buy /
explícito) → detalles (hechizos si es caster, backstory).

- AC-3.1: cada clase SRD del catálogo puede crear un héroe válido nivel 1
  (`test/dragonex/wizard_create_test.exs` y parámetricos por clase).
- AC-3.2: atributos inválidos (point buy fuera de presupuesto, array repetido)
  se rechazan server-side (`test/dragonex/heroes/heroes_validation_test.exs`).
- AC-3.3: el builder no toca DB — contexto custom inyectado, tests `async: true`
  (D9).

### R04 — Catálogos SRD en español ✅
9 razas con subrazas, 12 clases, backgrounds, equipo (armas simple/martial,
armaduras light/medium/heavy, escudos, gear), skills, idiomas y **319 hechizos**
SRD (`priv/srd/spells.es.json`, regenerable con `scripts/import_srd_spells.py`).

- AC-4.1: el catálogo mezcla builtin + SRD + custom del usuario con
  `source: :builtin | :srd | :custom` (`Catalog`, test `catalog_test.exs`).
- AC-4.2: la cuenta de hechizos SRD cargados es 319 (`srd_spells_test.exs`).
- AC-4.3: i18n ES/EN de catálogo y tipos de daño (`Translations`).

### R05 — Derivados nivel 1 correctos ✅
HP (dado de golpe + CON), AC (armadura + dex, con límites), iniciativa,
proficiencias, save DC, modifiers — calculados por `Heroes.build`.

- AC-5.1: ficha de un guerrero humano con array estándar y cota de malla da
  los números del SRD (test de humo en `heroes_integration_test.exs`).

### R06 — Edición de héroe ✅
Un héroe editable mientras no esté en partida activa; los cambios no afectan
partidas ya creadas (snapshot, D22 mismo principio).

### R07 — Contenido custom por usuario ✅
CRUD en `/mi-contenido` de armas, hechizos y objetos propios, con validación
server-side de mecánicas (dados parseables, kind de spell válido, ability
válida, classes conocidas). Único por `(user, kind, key)`; no compartido entre
usuarios (D22).

- AC-7.1: un arma custom inválida (daño no parseable) se rechaza con error
  accionable (`custom_content_test.exs`).
- AC-7.2: el contenido custom aparece en el builder y en la mesa con la misma
  mecánica que el builtin (consume structs, no JSON crudo).

### R08 — Subida de nivel (XP 5e, D43) ✅
El DM otorga XP en partida (`grant_xp`); no hay auto-level-up (D43;
D10 SUPERSEDED). La subida sigue explícita: `/heroes/:id/level-up`
(humano) o tool `level_up` (IA). Ficha humana: cuando `level < 20`.
`LevelUp.apply`: +1 nivel, PG (dado medio + CON + racial), retro-CON, **RAW no
cura** (D11), ASI 2 puntos en `[4,8,12,16,19]` cap 20 (D13), AC recalculada,
hechizos nuevos respetando `max_spell_level`, half-casters desde nivel 2.

- AC-8.1: subir de nivel no cambia `hp` actual si hay daño (conserva déficit).
- AC-8.2: ASI fuera de niveles ASI se ignora; cap 20 por característica.
- AC-8.3: un paladín nivel 2 gana slots de nivel 1; un wizard nivel 3 gana
  slots de nivel 2 (`test/dragonex/heroes/level_up_test.exs`).
- AC-8.4: la subida se **sincroniza a partida viva** vía single-writer
  (`Game.sync_hero_level_up`) preservando hp dañado/conditions/slots/AC
  (`game_sync_genserver_test.exs`).

### R09 — Fidelidad de clase (simplificaciones declaradas) 🟡
- Pact Magic del warlock entregado (D40); upcasting RAW con tabla curada
  entregado (D74). Queda fuera Mystic Arcanum (6º–9º 1/long rest).
- Sin feats; ASI = 2 puntos (D13).
- `spells_known` sin tope modelado (D14).
- Features de clase por nivel: el núcleo SRD del lote D35–D76 está entregado —
  Extra Attack (D35), Sneak Attack (D41), Rage con usos y Furia implacable
  (D42/D72), Reckless Attack (D44), Second Wind (D45), Divine Smite (D46),
  Action Surge (D47), Fighting Style (D48), Lay on Hands (D49), Bardic
  Inspiration (D50), Arcane Recovery (D51), Divine Sense (D52), Turn Undead
  (D53), Ki/Flurry of Blows (D54), Hunter's Mark (D55), Font of Magic (D56),
  Cunning Action: Hide (D57), Danger Sense (D58), Evasión (D59), skills +
  Jack of All Trades (D60), auras de paladín (D61/D62), Wild Shape (D63),
  Uncanny Dodge (D64), Metamagic (D65), Lucky (D66), Resistencia implacable
  (D67), Indomitable (D68), Savage Attacks (D69), Expertise (D73) — y
  spellcasting de paladín/ranger a L2. Fuera siguen, p. ej.: Mystic Arcanum,
  Action Surge a L17 (2 usos), Inspiración bárdica > d6, Font of Inspiration,
  colleges/arquetipos de subclase. Cada ADR declara sus recortes exactos.
- Empate de iniciativa por DEX score y luego nombre; sin roll-off extra (D39).

> **No son bugs.** Cambiar cualquiera exige un ADR que reemplace al vigente.

---

## Área B — Crear una partida

### R10 — Wizard de nueva partida ✅
`/games/new` en 2 tabs: detalles (escenario predefinido con story bible, o
custom con título/escena inicial/estilo de DM) + personajes.

- AC-10.1: cada escenario predefinido (`Scenarios.all`) arranca una partida
  con su story bible horneada en el system prompt (D20).

### R11 — Compañeros: héroes, arquetipos y monstruos ✅
El creador añade sus héroes, arquetipos predefinidos (guerrero/maga/pícaro) o
monstruos del bestiario. Cada compañero es **humano** o **IA**.

- AC-11.1: un compañero IA tiene su propio `PCAgent` con personalidad por
  clase y tools restringidas (`pc_agent_test.exs`).

### R12 — Multiplayer con slots abiertos ✅
Partida con slots abiertos arranca en **sala de espera**: link compartido,
otros usuarios se unen con su héroe, el creador pulsa **Empezar**.

- AC-12.1: `join_game` valida slot libre y añade participante
  (`games_context_smoke_test.exs`; las guardas de estado en el mismo archivo).
- AC-12.2: la partida no arranca hasta "Empezar"; tras arrancar no se admiten
  uniones.

---

## Área C — La mesa (`/games/:id`)

### R13 — Feed narrativo agrupado por turnos ✅
La narración del DM y las acciones se agrupan por turno/asalto, con autor y
paginación "cargar más" (tope ~400 bloques, ventana inicial ~200 eventos).

- AC-13.1: los eventos llegan ordenados por `seq` append-only (`game_events`).
- AC-13.2: "cargar más" pagina hacia atrás sin saltos ni duplicados
  (`game_live_test.exs`).

### R14 — Dado modal con desglose ✅
Cada tirada (ataque, daño, salvación, chequeo) muestra dados animados (2D/3D,
conmutable) y el desglose: `d20 + 5 vs CA 14 → ACIERTO` (FSM del modal,
`roll_format.exs`).

- AC-14.1: el desglose del modal coincide exactamente con el `RollLog`
  estructurado del motor (`roll_format_test.exs`).

### R15 — Panel de personaje vivo ✅
Ficha viva: atributos, HP, AC, condiciones, armas, hechizos, slots. Identidad
por humano (`?as=<name>` + overlay); "Ver como DM" para el creador.

### R16 — Streaming token a token ✅
La narración llega en streaming con anti-duplicación; si el modelo falla:
reintento con backoff y, si insiste, pausa con nota — nunca feed roto.

- AC-16.1: chunks duplicados (reintento) no aparecen dos veces en el feed
  (`game_live_test.exs`).

### R17 — Declarar el turno ✅
Cuando es el turno de un humano, la mesa muestra "Es tu turno" + input. La
declaración viaja `LiveView → Game.declare/3` (nunca Repo directo, D6).

- AC-17.1: declarar fuera de turno encola la intención en `games.intents` y
  se consume al llegar el turno (`game_phase0_test.exs`).
- AC-17.2: si la partida está `:waiting` en **otro** humano, encolar despierta
  al TurnMaster (D27) para que pueda priorizar esa iniciativa
  (`turn_master_loop_test.exs`).

### R18 — Auto-play del PC humano ✅
Toggle 🤖 crea un `PCAgent` que juega el personaje cuando le toca; se puede
desactivar. El humano siempre puede retomar.

### R19 — Pausa / reanudar durables ✅
Pausa en cualquier momento (`:paused`), persistida; reanudar continúa el bucle
exactamente donde estaba (incluso tras kill del proceso).

- AC-19.1: matar el GenServer y reabrir la partida rehidrata estado + historial
  y el turno en curso (`game_sync_genserver_test.exs`).

### R20 — Mesa responsive ✅
A ≤720px la mesa apila: feed + input primero, ficha en un drawer CSS
(`#sheet-drawer`), sin scroll horizontal. Dados ya son overlay. ≥1024px
sigue el grid 3-col. Estilos en `priv/static/assets/game.css`.

- AC-20.1: a 375px el input queda visible y no hay overflow-x; la ficha
  se abre/cierra con el control «Ficha».
- AC-20.2: tests LiveView de la mesa siguen verdes.

---

## Área D — Motor 5e (la mitad del D1)

### R21 — El motor es la fuente de verdad ✅
El LLM **nunca** calcula: llama a `deftool`s que resuelven por `Rules`/`Actions`
y proponen cambios en el `World` (D1). El turno tampoco lo decide el modelo.

- AC-21.1: un HP/daño/AC mostrado al jugador siempre coincide con el `World`,
  nunca con texto del modelo (los tests de flows asertan sobre world).
- AC-21.2: ninguna tool permite al modelo escribir HP/daño libremente (los
  stubs legado `attack`/`spawn_character` están restringidos al framework
  test, ver `07-contrato-tools` § legado).

### R22 — Combate completo ✅
Iniciativa (tirada por el motor, orden imparcial), ataque con ventaja/
desventaja y cancelación 5e, críticos (nat 20, dados doblados), daño (floor 0),
salvaciones, chequeos, death saves (nat 20 revive / nat 1 doble fallo / 3-3).

- AC-22.1..n: ver mecánicas `M2`–`M6`, `M12`–`M14` en
  `08-catalogo-mecanicas` con sus tests.

### R23 — Hechizos ✅
Tres kinds (`:automatic`, `:attack`, `:save` con mitad en éxito), consumo de
slot (nivel > 0), save DC y spell attack por aptitud de conjuración.

- AC-23.1: ver `M7`–`M11`; crítico de spell attack dobla dados (test de
  regresión).

### R24 — Condiciones ✅
`apply/remove_condition` persisten; `Rules.Conditions` aplica ventaja/
desventaja/auto-fallo por condición en **ataques, salvaciones y chequeos**
(tabla M06). Cancelación 5e (ventaja+desventaja=normal) en todos los caminos.

- AC-24.1: cada condición de la tabla M06 tiene test de ataque/salva/chequeo
  en `test/dragonex/rules/conditions_test.exs`.
- AC-24.2: `Actions.check` y `Actions.spell` (`:save` / `:attack`) leen el
  modo efectivo; paralizado auto-falla STR/DEX sin tirar
  (`conditions_test.exs`).
- AC-24.3: cancelación 5e se mantiene cuando se cruzan condición y `mode` del
  modelo.

### R25 — Escenas y hechos durables ✅
`set_scene` (escena actual, scrubbed) y `establish_fact` (hechos canónicos,
idempotentes, cap 30, visibles para todos los agentes cada turno — D16).

- AC-25.1: un hecho sobrevive compresión del historial (vive en el world).

### R26 — Descansos y curación ✅
`heal` (expresión de dados, cap max_hp, resetea death saves), `short_rest`
(hit die), `long_rest` (PG + slots). Fuera de combate.

### R27 — Level-up in-game ✅
El DM sube nivel a NPCs/enemigos/**PCs IA** con la tool `level_up`; los PCs
humanos **siempre** desde su ficha (la tool los rechaza con mensaje directivo).

- AC-27.1: `level_up` sobre un PC humano devuelve instrucción de ir a la
  ficha, no aplica cambios (`tools_level_up_test.exs`).

### R28 — Declarado fuera de v1 (no bugs)
Las features que esta sección listaba como "fuera" entraron por ADR durante el
lote D35–D76: Sneak Attack (**D41**; sin grid ni once-per-turn entre varias
llamadas `make_attack`), Rage (**D42/D72**; bonus melee, overlay B/P/S, usos
por descanso y Furia implacable; sin reloj de 1 minuto), Reckless Attack
(**D44**; expira al inicio de su turno, sin cupo/día), Second Wind (**D45**),
Action Surge (**D47**; sin L17 2 usos), Fighting Style (**D48**; sin
Protection/TWF/GWF ni picker), Lay on Hands (**D49**; sin enfermedad/veneno),
Bardic Inspiration (**D50**; siempre d6, sin Font of Inspiration ni colleges),
Arcane Recovery (**D51**), Divine Sense (**D52**; sin 60 ft), Divine Smite
(**D46**; sin Improved), `temp_hp` (**D36**), Concentración (**D37**; sin reloj
ni efecto de Bless), Resistencias/vulnerabilidades/inmunidades (**D38**; sin
magic vs mundane), además de todo el lote D53–D76 (ver R09 y el
[`08-catalogo-mecanicas`](../tecnico/08-catalogo-mecanicas.md)).
Siguen fuera: reacciones como mecánica formal (el TurnMaster da interrupciones
narrativas, no la mecánica 5e), multiclase, feats (D13) y escalados de upcast
multi-objetivo (exclusión documentada en D74). Cada una requiere ADR propio
para entrar.
Iniciativa individual por monstruo → **D34 / F6.4**.

---

## Área E — Orquestación de turnos

### R29 — Turno impuesto por el motor ✅
Quién actúa lo decide `TurnMaster` (camino principal) con **fallback
determinista** `WorldDriven`; el LLM no puede saltarse ni reordenar turnos.
La invariante `controlled_by?` restringe las tools al participante actual.

- AC-29.1: si TurnMaster falla/buclea/elige inválido, el Game cae a la policy
  sin deadlock (`turn_master_loop_test.exs`).
- AC-29.2: un participante no puede usar tools de resolución en turno ajeno
  (error directivo, `dm_puppet_pc_test.exs`).

### R30 — TurnMaster dramático ✅ (D25, D27)
En combate respeta `initiative_order` con excepciones explícitas (`cut_in`,
`react`); en exploración reparte con criterio dramático (`give_turn_to`,
`pass_to_dm`, `end_scene`). Mini-turnos que **vuelven** al actor interrumpido.
`acted_this_round` evita dobles turnos. El brief incluye **intenciones humanas
pendientes** (D27): el TM las considera; no las resuelve.

- AC-30.1: el catálogo de tools del TM es exactamente
  `{give_turn_to, cut_in, react, pass_to_dm, end_scene}` y **ninguna muta el
  World** (sólo registran; aplica el Game — D6).
- AC-30.2: un `cut_in` devuelve el turno al actor interrumpido al terminar.
- AC-30.3: `Brief.turnmaster_brief` lista intents humanos scrubbed; sin
  intents no aparece el bloque (`brief_test.exs`).
- AC-30.4: un declare off-turn puede hacer que el TM entregue el turno a ese
  humano; si el TM mantiene al waiter, el intent sigue encolado; si el TM
  falla en la re-eval, **no se roba** el turno del waiter.

### R31 — DM con tres sombreros ✅ (D23, D34)
Árbitro + controlador de monstruos (un beat por monstruo, D34) + director
narrativo. System prompt de 16 reglas, story bible horneada cacheable (D20),
budget de retries ampliado en tools de resolución.

- AC-31.1: el DM nunca narra números que contradigan el motor (guardrails +
  scrub D7; `dm_anti_repeat_test.exs`, `dm_test.exs`).

### R32 — PCAgent con personalidad ✅
Un agente por PC IA: voz por clase, tools restringidas (sin escenas/monstruos/
condiciones/nivel), `instruction/3` adaptativa (caído→death_save,
combate→targets, exploración), anti-loop Jaccard.

---

## Área F — Robustez y persistencia

### R33 — Persistencia por beat ✅
Tras cada beat: `games.world` (jsonb vía `Codec`, D4/D8) + evento append-only
en `game_events`. La partida se reconstruye por `game_id` (D3, D5).

- AC-33.1: world round-trips struct→jsonb→struct sin pérdida (campos nuevos
  de `Character` requieren `Codec.encode/decode` o **no sobreviven**).
- AC-33.2: reinicio del server + abrir partida = mismo mundo, turno e historial.

### R34 — Single-writer ✅ (D6)
El `World` vivo se muta **sólo** vía el GenServer `Game`. La LiveView nunca
escribe Repo/world; enruta (`declare`, `sync_hero_level_up`, pausa, auto-play).

### R35 — Degradación elegante ✅
Retries transient con backoff (1s→3s→10s, máx 3), retry `max_tokens` con nudge
"SÉ BREVE", circuit breaker que **pausa** tras 4 fallbacks seguidos (D17),
combate fantasma forzado (D18), UTF-8 sanitize + guardián de español (D7).

- AC-35.1: provider caído → racha de fallbacks → partida `:paused` con nota
  `:system`, no bucle infinito (`game_retry_test.exs`).
- AC-35.2: un beat que introduce enemigo vivo en exploración arranca combate
  aunque el DM olvide `roll_initiative` (`ghost_combat_test.exs`).

### R36 — Sin API key = TestModel ✅
Sin `OPENROUTER_API_KEY`, los beats usan `TestModel` (no narran, no consumen
créditos). Los tests de la suite son 100% offline.

### R37 — Modelo-por-rol y coste ✅ (D20, D21)
`Models`: `dm/0` (adherencia), `summarizer/0` (barato), `turnmaster/0` (barato,
256 tokens). Selector runtime vía modal Ajustes (ephemeral, restart).
Prefijo cacheable medido 44–85% de input cacheado.

---

## No funcionales (NFR)

| # | Requisito | Estado |
|---|---|---|
| NFR-1 | Determinismo del motor: roller inyectado, nunca `:rand` en `Rules`/`Actions`/`World` | ✅ |
| NFR-2 | Suite offline verde: `MIX_ENV=test mix test` (1511 passed / 3 excluded) sin red ni API key | ✅ |
| NFR-3 | `mix compile` sin warnings; `mix format` limpio | ✅ |
| NFR-4 | Sanitización determinística en TODO texto persistido (D7) | ✅ |
| NFR-5 | Latencia: streaming token-a-token; GenServer nunca bloquea en LLM (Task) | ✅ |
| NFR-6 | Partida sobrevive restart de proceso y de server (D3/D5) | ✅ |
| NFR-7 | Coste: caching de prefijo (D20), modelo barato para TurnMaster (D25) | ✅ |

---

## Lectura siguiente

- Qué falta y en qué orden → [`03-plan-fases.md`](03-plan-fases.md).
- Cómo se implementa cada mecánica → [`../tecnico/08-catalogo-mecanicas.md`](../tecnico/08-catalogo-mecanicas.md).
- Cómo se verifica → [`../tecnico/09-estrategia-pruebas.md`](../tecnico/09-estrategia-pruebas.md).
