# Decisiones de diseño — Dragonex

Registro canónico de decisiones confirmadas (estilo ADR ligero). Cada entrada
**no se rebate por la mitad**: si una futura implementación la contradice, se
abre una entrada nueva que la reemplaza y se marca la vieja como
**UPERSEDED**. El código es la verdad final, pero este doc explica el *porqué*
para no tener que reconstruirlo de los commits.

Estado: **Aceptada** salvo que se indique lo contrario. Fecha = sesión en que
se confirmó (aprox.).

---

## Arquitectura y motor

### D1 — El motor es la fuente de verdad, la IA solo narra
El LLM **nunca** calcula resultados: llama a `deftool`s que resuelven por las
reglas 5e (`Rules.Combat`, `Actions`). El modelo lee texto y teje prosa. Esto
evita que mienta con números (HP, daño, AC). Reflejado en `DM` (regla del
prompt) y en todo `Tools`.

### D2 — Reusar `ExAgent.Session` como motor
El framework (GitHub dep `kukapu/exagent`, branch `main`) provee `Session` con `TurnPolicy`,
`SharedState`, `Capabilities`, `Compaction`. El `Game` **ordena por encima**:
orquesta el bucle y la durabilidad, no reimplementa el motor. (Fase 0.)

### D3 — El `Game` es la capa de durabilidad (no un `ExAgent.Store`)
El `Session` corre **in-memory sin store**; el `Dragonex.Game` persiste a
Postgres tras cada beat (estado + evento append-only). Rehidratar = leer el
row, reconstruir el `Session` y hacer `handoff/2` al `current_participant`.
Evita doble persistencia y mantiene los `game_events` (que no son contrato de
`ExAgent.Store`) en una sola capa. (Fase 0.)

### D4 — World como jsonb + log append-only
`games.world` (jsonb vía `Codec`) = estado recreable actual. `game_events` =
línea temporal append-only para replay, contexto de agentes y chat. Ambos se
persisten en cada cambio → la partida se reconstruye/reanuda por `game_id`.

### D5 — `Dragonex.Game` es un GenServer on-demand, uno por partida
`:transient` bajo `DynamicSupervisor`, registro por `game_id` vía `Registry`.
Arranca al abrir la partida, para por idle con el estado a salvo en DB.

### D6 — Single-writer: el World se muta solo vía el GenServer
La LiveView **nunca** escribe en `Repo` ni en `games.world`. Toda mutación
viva enruta por `Dragonex.Game` (`declare/3`, `sync_hero_level_up/3`, …) que es el
único que toca el `Session`. `persist/1` lee de `Session.read_state`, así que
una sync aplicada sobrevive a la siguiente persistencia de beat.

### D7 — Sanitización determinística como cuello de botella
`Text.scrub/1-2` se aplica **antes** de persistir cualquier narración y al
reconstruir el history. Una sola regla cubre todos los puntos de consumo
(cajas, history, summarización) sin depender de que el modelo obedezca el
prompt (reglas #15/#16 del DM). Idempotente.

### D8 — `Codec` usa `String.to_atom`, no `to_existing_atom`
El world jsonb vuelve con claves string; el `Codec` las re-atomiza. Se permite
`String.to_atom` aquí (fuente controlada) porque los átomos pueden no estar
cargados aún. **Fuera del codec**, usar `to_existing_atom`.

### D9 — Builder offline: `Heroes.build` y `Catalog` no tocan DB
`Dragonex.Heroes` y `Heroes.Catalog` son derivación pura, sin Repo. El
contexto custom se **inyecta** (`opts[:custom]`), no se consulta dentro. Así
los tests corren `async: true` sin sandbox y el builder es reproducible.

---

## Mundo de juego y reglas 5e

### D10 — Progresión por **milestone**, no por XP
**SUPERSEDED** por D43.

El DM decide "subes de nivel"; el jugador humano lo ejecuta desde la ficha
(`/heroes/:id/level-up`), disponible siempre que `level < 20` (sin gate de
XP). Los PCs IA los sube el DM con la tool `level_up`. La infraestructura de
XP (`Accounts.grant_xp/3`, `Character.xp`, `Progression.can_level_up?/2`) se
conserva **latente** (sin callers en la UI) por si se cablea a un "DM grant
trigger" futuro.

### D11 — RAW: subir de nivel **no cura**
Reemplaza la regla de casa anterior ("subir cura"). `LevelUp.apply` suma
`hp_gain` solo al `max_hp`, no al `hp` actual; `merge_character_level_up`
conserva el déficit dañado. Un personaje caído (0 pg) **no revive** por subir.
Decidido en `1161f9e`.

### D12 — Warlock modelado como full-caster (simplificación v1)
**SUPERSEDED** por D40.

Pact Magic real (huecos 1º–5º, short rest, 1 Mystic Arcanum por nivel 6º–9º)
queda **fuera de v1**. El brujo recibe la tabla full-caster (con 6º–9º).
Documentado en `spell_slots.ex:9-12` y `progression.ex`. Impacto bajo a
niveles típicos de partida.

### D13 — ASI sin dotes en v1
A niveles `[4,8,12,16,19]`: 2 puntos a repartir en características, cap 20.
Las **dotes** (catálogo de feats) quedan fuera de v1. El ASI negativo se
ignora (`delta <= 0`) para que el LLM no salte el cupo.

### D14 — `spells_known` sin cap estricto en v1
`Progression.spells_known/2` devuelve `nil` para todas las clases. Los
preparadores (clérigo/druida/paladín) pueden ajustar su lista libremente al
subir; los de lista cerrada (bardo/hechicero) no tienen tope modelado. Por
simplificar; documentado en `progression.ex:14-28`.

### D15 — Iniciativa: empate rompe por nombre
**SUPERSEDED** por D39.

`Actions.initiative/3` desempata por nombre para determinismo (tests). 5e
usaría destreza y luego roll-off; queda como refinamiento futuro
(`actions.ex:349`).

### D16 — Hechos durables canónicos (`world.facts`)
El DM registraba ganchos solo en narración (truncable en el history) y los
abandonaba. Ahora `world.facts: [String]` es persistente (codec round-trip),
expuesto en el `world_brief` como "Hechos establecidos", y se registra con la
tool `establish_fact`. Todos los agentes lo leen cada turno.

---

## Robustez del bucle

### D17 — Circuit breaker: pausa automática tras fallbacks seguidos
Si una racha de beats cae al fallback blando (provider caído, rate-limit
persistente), `fallback_streak` llega a `@max_fallback_streak` (4 = 1 ronda de
4 participantes) y el loop **PAUSA** la partida con nota `:system`. Evita el
flujo infinito de *"X titubea y el turno pasa de largo"* que saturaba el
server. El usuario reanuda a mano.

### D18 — Combate fantasma forzado por el motor
Si un beat **introduce** un enemigo vivo mientras la fase es `:exploration`,
el motor tira iniciativa él mismo (`maybe_force_combat`), comparando
`enemies_before`/`after` para no disparar en el beat de setup. Red de
seguridad: aunque el DM olvide `roll_initiative`, el combate empieza.

### D19 — Contexto compartido reconstruido desde `game_events`
Cada beat reconstruye TODO el history desde `game_events` como `[Message.t()]`
y lo pasa como `:message_history` (override del `state.history` del `Server`).
Así DM + cada PC IA leen el MISMO contexto. `coalesce_assistant_runs` solo
colapsa runs del **mismo actor** (preserva atribución).

### D20 — Prompt caching: story bible en el prefijo estable
La `story_bible` se hornea en el **system prompt** (prefijo cacheable); el
volatile (`world_brief` + instruction) va solo en el último mensaje.
OpenRouter cachea el prefijo → medido en vivo **44–85% de tokens de entrada
cacheados** por beat.

### D21 — Modelo-por-rol + `max_tokens`
`Dragonex.Models` centraliza `dm/0` (mejor adherencia) + `summarizer/0`
(barato: flash/lite) + `dm_max_tokens/0`, todo env-overridable. Selector de
modelo en runtime vía `ModelConfig` GenServer + modal Ajustes (ephemeral,
app-global, con restart del proceso).

---

## Producto y alcance

### D22 — Contenido custom polimórfico en una sola tabla
`custom_contents` (kind weapon/spell/item, unique `(user_id, kind, key)`).
**No** compartido entre usuarios (no marketplace en v1). La sheet del héroe es
una **snapshot**: editar una definición custom *después* de que el héroe esté
en partida **no** la afecta (igual que cambiar un héroe no cambia partidas
activas). El motor consume structs, no el JSON crudo → sin cambios en
`Rules`/`Actions`/`Tools`.

### D23 — El DM es un participant `:ai` con `side: "dm"`
Los PCs pueden ser IA (su **propio agente** `PCAgent`, con personalidad +
tools restringidas) o humanos. El DM acumula tres sombreros: árbitro,
controlador de monstruos y director narrativo. El controlador sigue siendo
el DM; **un beat por monstruo** es D34 (antes los enemigos se plegaban en
un único slot).

### D24 — Multi-nodo fuera de alcance
Sin `Horde` ni replicación; `Registry` alcanza para single-node. Se reabre si
se necesita HA. (Pausada.)

### D25 — TurnMaster: el reparto de turnos por agente (Fase 5)
**Estado: Implementada.** Spec técnico de diseño en
[`TURNMASTER.md`](TURNMASTER.md). Reemplaza el reparto determinista implícito
(`WorldDriven`, `turn_policy/world_driven.ex`) como camino principal, y **resuelve
el pendiente "Coordinación real entre PCs auto"** + el pendiente de
**"Reacciones / preparar acción"** de `progress.md`.

Hoy el turno lo impone un `TurnPolicy` determinista (`WorldDriven`) que recorre
`initiative_order` / round-robin: predecible e imparcial, pero **rígido** — no
hay reacciones, interrupciones, acciones preparadas, ni ritmo variable, y el
round-robin de exploración ignora quién tiene algo que decir. La partida se
siente "cuadriculada" y pierde diversión. Con modelos baratos y capaces ya
viable, se introduce un **agente `Dragonex.TurnMaster`** que decide quién actúa
vía tools (`give_turn_to`, `cut_in`, `react`, `pass_to_dm`, `end_scene`) en un
beat extra antes del beat del actor; `Session.handoff/2` aplica la decisión.

- En **combate** respeta `initiative_order` por defecto con excepciones
  explícitas (reacciones, acciones preparadas, interrupciones dramáticas) vía
  `cut_in`/`react` (mini-turno que vuelve al actor interrumpido).
- En **exploración** reparte la palabra con criterio dramático (quien reacciona,
  quien tiene algo que decir), no round-robin plano.
- **`WorldDriven` se conserva como fallback determinista**: si TurnMaster falla,
  buclea o elige un actor inválido, el Game cae al orden calculado por la policy
  (+ circuit breaker `D17`). La partida nunca deadloquea.
- Invariante `controlled_by?` intacto: solo quien recibe el turno accede a las
  tools de resolución.
- **Respeta `D6` (single-writer)**: TurnMaster **no muta el `World`** — sus tools
  sólo *registran* la decisión; es el **`Game`** quien la ejecuta
  (`Session.handoff/2` para el turno, `Session.update_state/3` para escena), el
  mismo patrón que `maybe_end_combat`/`maybe_force_combat`.
- Subsistemas: agente nuevo en **S6** (`Dragonex.TurnMaster`), tools de
  orquestación propias (no en `Dragonex.Tools`/S5); reparto S3 asistido por S6;
  modelo en **S10** (`Models.turnmaster/0` vía catálogo provider).
- `Models.turnmaster/0` (barato/rápido, `max_tokens` ~256, prefijo cacheable
  `D20`). **Coste asumido** (+1 llamada/turno): la prioridad del producto es que
  sea divertido; la fluidez pesa más que ahorrar tokens.

Consecuencias (hechas): `docs/tecnico/01-bucle-del-agente.md` y
`docs/FLUJO_PARTIDA.md` describen el flujo actor → turnmaster → handoff;
`progress.md` mueve el item a ✅. Código: `lib/dragonex/turn_master*.ex`,
integración en `game.ex`, `acted_this_round` en `World`/`Codec`.

Alternativas descartadas: (a) emular excepciones con reglas en `WorldDriven`
(sigue rígido en exploración); (b) que el propio DM reparta turnos (mezcla
narración y orquestación, sesga imparcialidad); (c) TurnMaster sólo en puntos de
decisión (más barato, pero inconsistente — se prefiere fluidez).

### D26 — Switch de deps locales vía `DRAGONEX_LOCAL_DEPS`
`exagent` y `dic_ex` son deps propias que se iteran en paralelo al desarrollo
de dragonex. Para no andar haciendo `mix deps.update` tras cada cambio en esos
paquetes, `mix.exs` resuelve ambas con `local_dep/2`:

- `DRAGONEX_LOCAL_DEPS=1` → `{:exagent, path: "…/exagent"}` (idem `dic_ex`),
  resolviendo `DRAGONEX_DEPS_ROOT` (default `../`, siblings del repo).
- Sin la variable → GitHub `branch: main` (lo que usa prod, CI y docker).

**Caveat mix**: `mix.exs` se evalúa **antes** que `config/runtime.exs`, así que
Dotenvy todavía no ha cargado `.env.dev` y la variable debe estar en el shell.
`bin/dev` carga `.env.dev` antes de invocar `mix` para que se respete sin tener
que exportar a mano. Docker (`compose.dev.yml`) **siempre** usa GitHub: no hay
motivo para montar `../` dentro del contenedor y añade complejidad.

### D27 — Intenciones humanas alimentan al TurnMaster
Las declaraciones off-turn (`games.intents`) no son solo un buzón para el
turno propio: son **señales de iniciativa**. El brief del TurnMaster las
lista (scrubbed, D7, preview 200). En exploración el prompt prioriza a quien
tiene algo escrito; en combate justifican `cut_in`/`react` sin sustituir el
`initiative_order`.

Si la partida está `:waiting` en un humano A y B declara, el Game **re-evalúa**
al TM (un beat). Fallback de esa re-eval **no** avanza `WorldDriven` (no se
salta a A). Mismo texto dos veces no dispara otra re-eval. El TM elige; el
motor resuelve. Los bots no encolan.

### D28 — Intenciones con fase; la UI no tapa el buzón
Las intenciones se guardan con la fase en que se encolaron. Un `interrumpo`
de combate **no** se consume como acción de exploración cuando el combate
ya cerró (se descarta con nota de sistema). Un plan de exploración sí
sobrevive si arranca un combate.

El motor honra reacciones claras (`interrumpo`, `escudo`, `me pongo
  delante`…) con `cut_in` aunque el TurnMaster hubiera cedido a otro. En
  exploración, tras un PC el motor **pasa al DM** (sin beat TM): el mundo
  responde; un intent humano pendiente sigue teniendo prioridad. La
  LiveView **no** deshabilita el input mientras hay un beat en vuelo: el
  humano puede encolar; el TM lo ve al cerrar el beat (D27).

### D29 — Recorte estructural de fugas de mesa (no solo nudge)
El modelo desobedece el prompt (regla 14, time-skip, voz de PNJ). D7 ya
exige `Text.scrub` antes de persistir; D29 añade **recorte de cláusulas**
determinista, no un recordatorio al siguiente beat:

- **DM**: se tiran frases que empiezan por `<PC> <verbo de acción>`
  (`Lyra se acerca…`). Quedan estados pasivos (`Lyra está herida`,
  `Lyra cae herida`) y menciones que no son sujeto (`junto a Lyra, el
  tabernero abre`). El nudge de regla 14 se conserva para fugas
  mid-cláusula que el recorte no cubre.
- **PC** (humano o IA): se tiran frases de time-skip (`media hora
  después`) y diálogo atribuido a un tercero (`—… —dice el tabernero`).
  El diálogo propio del actor se conserva.
- **Opener / TM mudo en exploración**: cero «El motor toma el relevo».
  El primer tick cede al DM (`pass_to_dm`, nota «El turno pasa al DM.»)
  sin beat TM. «Relevo» solo si el TM está mudo **en combate**.

La LiveView no recorta: el persist (`Events`) es el cuello (D6/D7).

### D30 — Pregunta del DM al humano retiene el floor
Tras un beat del DM en exploración, si la última narración es una
pregunta dirigida a un PC humano (`¿` + nombre, «ante ti», «¿qué hace»,
o un `¿…?` suelto), el motor **entrega el turno a ese humano** (o al
último humano que habló, si no hay nombre). Un intent pendiente sigue
ganando (D27). No se pide al TurnMaster que lo recuerde.

El recorte de voz de PNJ en un beat de PC corta **desde el primer
atribuidor** (`baja la voz:`, `el posadero "…"`, `dice Borin`) y no
parte por `.` dentro de comillas. El diálogo propio (`—¿Qué se
cuece? —pregunto`) se conserva. Los headers de history
`[R2 · Turno de X]` y `[→ Name decide]` se tiran en cualquier sitio
(D7), no solo al inicio.

### D31 — Descomposición de los módulos monolito (refactor estructural)
Los tres mayores módulos se partieron en satélites con dependencias
**unidireccionales** (nunca cíclicas), sin cambio de comportamiento:

- `Dragonex.Game` (2273→~780 líneas) conserva el struct de estado, la API
  pública y los callbacks del GenServer + `advance/1`. Alrededor:
  `Game.Bootstrap` (rehydrate/agentes), `Game.Beats` (lanzar beats),
  `Game.Settlement` (asentar resultados y reintentos), `Game.Turnmaster`
  (aplicar decisiones TM + fallback WorldDriven), `Game.Combat`
  (combate/rounds), `Game.Persistence` (Postgres+PubSub) y
  `Game.Participants` (predicados del roster). Todos **corren dentro del
  proceso del Game** (single-writer D6 intacto): son funciones puras
  `state → state`, no procesos nuevos.
- `GameLive.Show` (1772→~440) queda como LiveView delgada; el view-model
  del chat en `GameLive.Chat`, el modal de Ajustes y sus eventos en
  `GameLive.Settings`, el FSM de dados en `GameLive.Dice`, la proyección
  snapshot→assigns en `GameLive.Snapshot` y el markup (mesa + sala de
  espera) en `GameLive.Components`.
- `HeroLive.New` (1291→~500) conserva eventos y máquina de pasos; el
  mapping form↔draft (puro, offline, D9) en `Dragonex.Heroes.Draft` y el
  markup de los pasos en `HeroLive.New.Components`.

Regla para el futuro: un módulo nuevo no supera ~500 líneas; cuando el
GenServer/LiveView anfitrión crezca, extraer otro satélite con esta misma
forma (delegación fina, estado como dato, sin procesos extra).

### D32 — La biblia siembra facts; el PC IA no cierra solo
Los PNJ y el lugar inicial de la story bible se copian a `world.facts`
en `Games.create_game`. El DM los lee cada turno (D16): el posadero
sigue siendo Borin. No hay tool nueva.

Un PC IA en exploración, con humano en mesa, no persiste cláusulas de
ejecución en solitario (`despliega el pergamino`, `coge el…`) — propone
y espera. Combate no se toca. Recorte en `Text.scrub` (D7/D29).

### D33 — Sin banner de level-up en la mesa
Bajo milestone (D10) no hay fuente de XP, así que el banner
`viewer_level_up` de la mesa (gateado por `Progression.can_level_up?/2`)
nunca se mostraba. Se elimina: el humano sube desde la ficha
(`/heroes/:id/level-up`, callout en `HeroLive.Show` si `level < 20`).
Cablear un flag "DM granted" en la mesa sería reabrir XP como fuente
(F7) — fuera de v1.

### D34 — Un beat por monstruo; el DM sigue como controlador
La iniciativa 5e es por combatiente. `World.initiative_order` ya listaba
nombres individuales; `WorldDriven` colapsaba enemigos consecutivos en un
solo slot del DM. Eso mezclaba tres sombreros de D23 (árbitro / controlador
/ narrador) con un único beat: el DM actuaba por todos los monstruos a la
vez y `acted_this_round` marcaba `"dm"`.

Semántica (F6.4):

- **Un beat por combatiente** en `initiative_order`. Tres goblins en
  fila → tres beats del DM. `cut_in`/`react` siguen siendo mini-turnos
  que no marcan `acted_this_round`.
- El **controlador** no cambia: `Session.current` en un slot de enemigo
  es `"dm"`; `controlled_by?` y las tools no se tocan.
- `World.current_combatant` nombra el slot vivo (persiste en Codec). El
  Game lo escribe en el handoff/fallback (D6). `mark_acted` usa ese
  nombre, no `"dm"`. Brief y UI resaltan solo a ese combatiente.
- `WorldDriven.combat_participants/2` ya no hace dedup consecutivo; el
  ciclo de ronda es `World.combat_cycle/1` (enemigos vivos + PCs, incluso
  caídos).

Alternativa descartada: un beat del DM que recorre todos los monstruos
internamente — barato en tokens, pero el TurnMaster no puede intercalar
`cut_in` entre enemigos y `acted_this_round` no distingue slots.

### D35 — Extra Attack 5e
Entra Extra Attack. No es Action Surge ni economía de acciones completa
(R28 reacciones siguen fuera). Un `make_attack` / `Actions.attack`
resuelve N tiradas de ataque contra **el mismo objetivo** (la Acción de
Ataque 5e). Si el objetivo cae (hp ≤ 0) a mitad, se omiten los golpes
restantes; no se retargetea en esta tool.

N lo calcula el motor (D1) según clase+nivel (`Progression.attack_count/2`),
no el string en `class_features`: partidas viejas L5+ sin el feature en
el jsonb siguen recibiendo el N correcto.

- fighter: L1–4 → 1; L5–10 → 2; L11–19 → 3; L20 → 4
- barbarian, paladin, ranger, monk: L5+ → 2; si no → 1
- resto → 1

`Progression.features_at/2` añade `"extra_attack"` al llegar a L5 en esas
cinco clases (ficha/UI). Fighter L11/L20 no necesitan otro string: N sale
del nivel.

No se limita cuántas veces el LLM llama `make_attack` en un beat: la
economía de acciones sigue fuera (deuda). `Actions.spell` no aplica Extra
Attack. No cambia `Character`/`Weapon`/`Spell`/`Item`.

R09 queda **parcial**: Extra Attack entra; el resto de features por nivel
sigue 🟡. D12–D15 intactos (no SUPERSEDED).

### D36 — Puntos de golpe temporales 5e
Estado: **Aceptada** — 2026-09-10.

El campo `Character.temp_hp` ya existía y el Codec lo round-trippea; no
había regla que lo consumiera. Entra RAW v1:

- El daño golpea primero `temp_hp`; el resto a `hp`. `temp_hp` nunca
  negativo. `World.apply_damage/2` es el único sitio que resta.
- No se acumulan: al otorgar, el personaje se queda con
  `max(temp_hp actual, cantidad nueva)` (no sumar).
- `heal` no toca `temp_hp`.
- Caer a 0 hp (death saves, `down?/2`, Extra Attack mid-action) mira
  `hp`, no `temp_hp`.
- Sin reloj de duración (False Life 1h etc. queda fuera). `long_rest`
  no borra `temp_hp`: hoy no limpia estado transitorio y no se inventa
  un wipe.
- Otorgar: `World.apply_temp_hp/2` + tool `grant_temp_hp` (DM a
  cualquiera; PC sólo sobre sí mismo). El LLM no escribe el campo a
  mano.
- No cambia `Character`/`Weapon`/`Spell`/`Item`. D12–D15 y D35 intactos.

False Life (key SRD `"false life"`, `dice` nil): `Actions.spell` tira
`1d4+4` con el roller inyectado, aplica `apply_temp_hp` al **caster**
y consume slot. No se retargetea a daño. Duración 1h no se modela.

### D37 — Concentración 5e
Estado: **Aceptada** — 2026-09-10.

Entra el **estado** de concentrar y **romperlo**. El LLM sigue narrando
el buff; el motor dice si se mantiene o se pierde (D1). No hay reloj de
duración ni efecto mecánico de Bless/Hold Person/+1d4.

- `Character.concentrating` : `String.t() | nil` — clave del hechizo, `nil`
  si no concentra. Codec encode/decode; jsonb viejo sin clave → `nil`
  (como `current_combatant` D34). Primer cambio de forma de `Character`
  de esta tanda (D4/D8).
- ¿Es de concentración? `Heroes.Spells.concentration?/1` lee el catálogo
  (`Spells.get/1` / SRD, `concentration: true`). Builtin sin flag = no
  concentración, salvo que el SRD traiga la clave (el SRD gana).
- Al lanzar un hechizo de concentración se reemplaza el anterior (no hay
  dos a la vez). Tool `drop_concentration(who)` para soltar a propósito
  (DM cualquiera; PC sólo sí mismo).
- Al recibir daño > 0 (el amount **original** del golpe, tras absorber
  `temp_hp` en hp): salvación CON DC = `max(10, div(damage, 2))`. Fallo →
  `concentrating` nil. Cada golpe de Extra Attack es un chequeo (RAW) si
  el concentrador sigue en pie. El roller no cabe en `World.apply_damage`
  (change_fn puro); el chequeo vive en `Actions`. `World.apply_damage`
  sigue solo hp/`temp_hp`. Helper `World.clear_concentration/1`.
- Condiciones que rompen sin tirada (al `apply_condition`): unconscious,
  incapacitated, stunned, paralyzed, petrified. hp a 0 rompe.
- No se cambia `Weapon`/`Spell`/`Item`. D35/D36 intactos.

### D38 — Resistencia, vulnerabilidad e inmunidad a daño
Estado: **Aceptada** — 2026-09-10.

Entra RAW v1 de resistencias 5e. El LLM no calcula el modificador (D1).

- Tres listas en `Character`: `damage_resistances`,
  `damage_vulnerabilities`, `damage_immunities` — arrays de strings
  (tipos 5e: `slashing`, `fire`, `poison`, …). Default `[]`. Codec
  encode/decode; jsonb viejo sin clave → `[]` (D4/D8).
- `World.apply_damage/2` sigue igual (sin tipo = daño plano). Tercer
  arg opcional: `apply_damage(name, amount, type)`; `type` nil/"" se
  comporta como hoy.
- Orden: inmunidad → 0; si resist **y** vuln del mismo tipo se cancelan
  (daño pleno); solo resist → `div(amount, 2)`; solo vuln → `amount * 2`.
  Floor 0. Luego `temp_hp` (D36) sobre el amount **ya modificado**.
  Concentración (D37) usa el daño que realmente entra (post-resist).
- `Actions.attack` pasa `weapon.damage_type`; `Actions.spell` pasa
  `spell.damage_type` si hay.
- Skeleton SRD: vuln `bludgeoning`, immune `poison`
  (`Monsters.skeleton/1`).
- Tiefling: si `racial_traits` incluye `hellish_resistance`, fire cuenta
  como resistencia (sin duplicar en la lista si ya está). El builder
  rellena `["fire"]` en héroes nuevos; el chequeo también mira el rasgo
  para fichas viejas.
- No magic vs mundane, no "resistance to all but …". D35–D37 intactos.
  No se cambia `Weapon`/`Spell`/`Item`.

### D39 — Iniciativa: empate por DEX luego nombre
Estado: **Aceptada** — 2026-09-10. SUPERSEDE D15.

RAW v1 de desempate, **sin** roll-off extra (un d20 extra rompería
rollers fijos de tests). Orden en `Actions.initiative/3`:

1. total (d20 + mod DEX) descendente
2. puntuación DEX descendente
3. nombre ascendente (determinista)

`sort_by({-total, -dex, name})`. Los tests Vex/Thane (totales distintos)
siguen verdes. No cambia `Character`/`Weapon`/`Spell`/`Item`. D12–D14 y
D35–D38 intactos.

Deuda: el roll-off 5e (d20 extra entre empatados) queda fuera para no
consumir el roller inyectado.

### D40 — Pact Magic del warlock
Estado: **Aceptada** — 2026-09-10. SUPERSEDE D12.

RAW v1 de Pact Magic (PHB 5.1). El brujo deja de usar la tabla full-caster.

- Tabla de huecos (solo 1º–5º, todos del mismo nivel):
  L1: 1×1º; L2: 2×1º; L3–4: 2×2º; L5–6: 2×3º; L7–8: 2×4º; L9–10: 2×5º;
  L11–16: 3×5º; L17–20: 4×5º.
- Al lanzar un hechizo de nivel ≥1 consume UN hueco de pacto (el único
  nivel que tiene), no un hueco del nivel del hechizo. Un brujo L5 que
  lanza magic missile (1º) gasta un hueco de 3º. `has_slot?` acepta
  `spell.level` si `spell.level ≤` nivel de pacto y queda al menos 1 hueco.
- No puede lanzar un hechizo cuyo nivel > nivel de pacto actual.
- Descanso corto restaura los huecos del brujo (además del dado de golpe).
  Wizard/clérigo no recuperan huecos en short rest.
- Descanso largo sigue restaurando todos (`restore_slots` ya usa `for_class`).
- `caster?(warlock)` true (slots desde L1). `full_caster?(warlock)` false.
- `max_spell_level` del warlock es el nivel de pacto, cap 5.

Deuda:
- **Mystic Arcanum** (hechizos 6º–9º 1/long rest) queda fuera.
- Escalado de daño por upcast (magic missile extra darts, etc.) no se
  implementa salvo que ya exista. El hueco gastado sí es el de pacto.

No cambia `Character`/`Weapon`/`Spell`/`Item`. D13/D14 intactos. D15 ya
SUPERSEDED por D39.

### D41 — Sneak Attack 5e
Estado: **Aceptada** — 2026-09-10.

RAW v1 sin posiciones. El daño extra lo calcula el motor (D1) según
clase+nivel (`Progression.sneak_attack_dice/2`), no el string
`"sneak_attack"` en `class_features`: partidas viejas L1 rogue sin el
feature en el jsonb siguen recibiendo los dados. El string L1 del
catálogo se queda (ficha/UI).

- Dados: `div(level + 1, 2)` d6 para rogue; 0 para el resto.
  L1=1, L3=2, L5=3, … L19=10.
- Arma cualificada: `weapon.finesse == true` O `weapon.ranged == true`.
  Longsword sin finesse NUNCA.
- Circunstancia (sin grid): se aplica si el modo efectivo del ataque
  (`Conditions.attack_mode`) es `:advantage`, O si hay un **aliado**
  consciente (hp>0, mismo `side` que el atacante, nombre distinto del
  atacante y del objetivo, sin condición incapacitante:
  unconscious/incapacitated/stunned/paralyzed/petrified). Si el modo
  efectivo es `:disadvantage`, NUNCA (aunque haya aliado).
- Una vez por llamada a `Actions.attack`: solo el **primer golpe que
  acierta** de la secuencia Extra Attack recibe los dados (el rogue no
  tiene Extra Attack hoy).
- Crítico: los dados de sneak se tiran dos veces (RAW), con el roller
  inyectado (2N d6), no se duplica el total a ciegas.
- El daño extra usa el mismo `damage_type` del arma y pasa por
  `apply_damage/3` (resistencias D38).

Deuda: "once per turn" vs múltiples `make_attack` en el mismo beat
(economía de acciones sigue fuera, como D35).

No Cunning Action, no Uncanny Dodge, no grid. No cambia
`Character`/`Weapon`/`Spell`/`Item`. D35–D40 intactos.

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41 y
spellcasting paladín/ranger L2; el resto de features por nivel sigue 🟡.

### D42 — Rage 5e
Estado: **Aceptada** — 2026-09-10.

Primer campo nuevo de `Character` de T12. El LLM no calcula el bonus
ni la resistencia (D1). Reckless Attack, cupo de usos/día y reloj de
1 minuto quedan fuera.

- `Character.raging` boolean, default `false`. Codec encode/decode;
  jsonb viejo sin clave → `false` (D4/D8).
- Solo `class == "barbarian"` puede entrar. Tools `start_rage(who)` /
  `end_rage(who)` (DM cualquiera; PC sólo sí mismo, mismo patrón que
  `drop_concentration`). El motor no depende del string `"rage"` del
  catálogo L1.
- Al entrar: `raging` true; si concentraba, se suelta (no se puede
  concentrar ni lanzar en furia). `Actions.spell` error si el caster
  está raging.
- Mientras raging:
  - Bonus de daño en golpes **cuerpo a cuerpo** (`weapon.ranged != true`):
    +2 L1–8, +3 L9–15, +4 L16–20 (`Progression.rage_damage/1`). Se suma
    al dmg del arma en **todos** los hits de Extra Attack. No se dobla
    en crítico.
  - Resistencia a bludgeoning/piercing/slashing: overlay en
    `Character.incoming_damage/3` si `c.raging` (no mutar las listas
    persistidas). Combina con D38 (si ya es vulnerable al mismo tipo,
    se cancelan).
  - `Actions.check` de STR en raging → ventaja (cancelación 5e con
    desventaja de condición). Salvaciones STR no.
- Termina: `end_rage`; hp a 0; `apply_condition` unconscious;
  `World.end_combat` apaga raging en todos. Sin cupo de usos (deuda).
  Sin minuto ni “si no atacas este turno”.

No Reckless Attack. No cambia `Weapon`/`Spell`/`Item`. D35–D41 intactos.

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42 y
spellcasting paladín/ranger L2; el resto de features por nivel sigue 🟡.

### D43 — XP 5e como fuente de progresión
Estado: **Aceptada** — 2026-09-10.

SUPERSEDE D10 (milestone). La tabla PHB ya vive en `Progression`
(`xp_threshold`, `can_level_up?`, `xp_to_next_level`); `Character.xp`
ya existe. El DM otorga XP en partida con `grant_xp(who, amount)` →
`World.grant_xp/2`. `amount` > 0; suma a `Character.xp`. No toca hp/slots.

No aplica `level_up` automáticamente (D11 intacto: subir no cura). La
subida sigue siendo explícita: ficha humana / tool `level_up`. El
mensaje factual incluye XP actual, umbral del siguiente nivel y si
`can_level_up?`.

`Accounts.grant_xp/3` (ficha persistida fuera de partida) no se
rediseña. No hay calculadora de XP por CR/encuentro: el DM decide
cuánto. D11/D13/D14 intactos. Sin feats, sin multiclase. D33 (sin
banner in-game) sigue: el humano sube desde la ficha.

### D44 — Reckless Attack 5e
Estado: **Aceptada** — 2026-09-10.

Cierra la deuda de Reckless dejada por D42 (Rage intacto). El LLM no
calcula la ventaja (D1): llama `start_reckless`; el motor la aplica en
`Conditions.attack_mode`. Cupo de usos/día de Rage y reloj de 1 minuto
siguen fuera. Sin feats.

- Solo `class == "barbarian"`. Tools `start_reckless(who)` /
  `end_reckless(who)` (DM cualquiera; PC sólo sí mismo, mismo patrón
  que Rage). `end_reckless` es idempotente.
- `Character.reckless` boolean, default `false`. Codec encode/decode
  (`== true`); jsonb viejo sin clave → `false` (D4/D8).
- Mientras reckless:
  - Ataques de arma **melee que usen STR** (`weapon.ranged != true` y
    el golpe usa Fuerza: `attack_ability` STR, o finesse con
    `mod STR ≥ mod DEX`) del bárbaro tienen ventaja.
  - Finesse con DEX mayor y armas ranged **no** dan ventaja al atacante.
  - **Cualquier** ataque contra ese personaje tiene ventaja.
  - Se combina con Conditions: adv+desv = normal (`combine/2`).
- No es un `mode` que el LLM pase a `make_attack`. Extra Attack (D35):
  todos los swings de esa llamada usan el mismo `effective_mode`.
  Sin guarda “solo el primer ataque del turno”: si `start_reckless`
  llega tarde, aplica a los ataques que queden.
- Expira al **empezar su siguiente turno**: `World.set_current_combatant(name)`
  apaga `reckless` de ese name. También apaga: `end_reckless`; hp a 0;
  `unconscious`; `World.end_combat` (todos).
- Sin cupo/día.

No cambia `Weapon`/`Spell`/`Item`. D42 intacto.

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44 y spellcasting paladín/ranger L2; el resto de
features por nivel sigue 🟡.

### D45 — Second Wind 5e
Estado: **Aceptada** — 2026-09-10.

RAW acotado del fighter. Extra Attack (D35) intacto. El LLM no calcula
la curación (D1): llama `second_wind`; el motor tira y aplica. Sin
economía de acciones (bonus action simplificada a una tool 1/descanso).
Sin feats.

- Solo `class == "fighter"`. Tool `second_wind(who)` (DM cualquiera;
  PC sólo sí mismo, mismo patrón que Rage).
- Cura `1d10 + level` PG, capped `max_hp`, mismo path que `heal`
  (death saves si hp>0). No toca `temp_hp`.
- 1 uso hasta `short_rest` o `long_rest`. `Character.second_wind_used`
  boolean, default `false`. Codec encode/decode (`== true`); jsonb
  viejo sin clave → `false` (D4/D8).
- Si already used → error. No fighter → error.
- `short_rest` y `long_rest` ponen `second_wind_used = false` en el
  personaje que descansa (aunque no gasten hit die / aunque long rest).

No Action Surge. No Indomitable. No Fighting Style. No cambia
`Weapon`/`Spell`/`Item`. D35 intacto.

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45 y spellcasting paladín/ranger L2;
el resto de features por nivel sigue 🟡.

### D46 — Divine Smite 5e
Estado: **Aceptada** — 2026-09-11.

RAW acotado del paladín. Extra Attack (D35) intacto. El LLM no calcula
dados ni gasta la casilla (D1): llama `divine_smite`; el motor aplica el
smite en el primer impacto melee. Sin Improved Divine Smite. Sin feats.
Sin Great Weapon Fighting. No cambia `Weapon`/`Spell`/`Item`.

- Solo `class == "paladin"`. Tool `divine_smite(who, slot_level)`: deja
  pendiente `Character.smite_slot = slot_level` (1..5). **No** consume el
  hueco todavía. Error si no paladín, `slot_level` fuera de 1..5, o
  `has_slot?` falso. Paladín L1 no tiene slots → error al armar (slots
  desde L2, R09).
- El motor aplica el smite en el **primer impacto melee** siguiente de
  `Actions.attack` (arma `ranged != true`). Extra Attack D35: el primer
  swing que acierte (o crítico) gasta el pendiente; los demás no.
- Fallo: el pendiente **sigue**. Ranged / hechizo: no aplica, pendiente
  sigue.
- Al impactar: `World.consume_slot(who, slot_level)` + daño radiante extra
  `2d8 + (slot_level-1)d8` (tope slot 5 → 5d8). Si `target.race` es
  `"undead"` o `"fiend"`, +1d8 (máx 6d8). Pasa por `apply_damage` tipo
  `"radiant"` (D38). Limpia `smite_slot`.
- Expira sin gastar: `end_smite`; `set_current_combatant(who)` (inicio de
  su turno); `end_combat`; hp 0; unconscious.
- DM cualquiera; PC sólo sí mismo. PCAgent paladín SÍ sobre sí.
- Campo: `Character.smite_slot` `nil | 1..5`. Codec: integer o null;
  jsonb viejo → nil (D4/D8).

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46 y spellcasting
paladín/ranger L2; el resto de features por nivel sigue 🟡.

### D47 — Action Surge 5e
Estado: **Aceptada** — 2026-09-11.

RAW acotado del fighter. El LLM no resuelve el ataque extra (D1): llama
`action_surge`; el motor ejecuta UNA Acción de Ataque extra
(`Actions.attack`, Extra Attack D35 incluido) y marca el uso. Economía
de acciones simplificada: la tool ES la acción extra (como D45
simplificó el bonus action). Sin Dash/Dodge/cast vía surge. Sin feats.

- Solo `class == "fighter"`. Desde **nivel 2** (RAW). L1 → error.
- Tool `action_surge(who, target, weapon, mode)`: misma firma útil que
  `make_attack` (mode "normal"/"advantage"/"disadvantage"). DM cualquiera;
  PC sólo sí mismo.
- Resuelve `Actions.attack` (N swings D35, sneak/rage/smite si aplicaran
  — un fighter no tiene sneak). Si el ataque se resuelve (hit o miss),
  marca `action_surge_used = true`. Si error (no existe, 0 hp, sin arma,
  no fighter, L1, ya usado) NO marca.
- 1 uso hasta `short_rest` o `long_rest`. `Character.action_surge_used`
  boolean, default `false`. Codec `== true`; jsonb viejo → false (D4/D8).
- `compose_rest` también pone `action_surge_used = false` (junto a
  second_wind_used).
- Ya usado → error. No fighter → error. L1 → error.
- `Progression.features_at("fighter", 2)` → `["action_surge"]`.
  Traducción en Catalog/Translations. L1 catalog sigue
  `fighting_style second_wind`.
- PCAgent: tool permitida; prompt fighter puede usarla EN EL MISMO
  turno tras `make_attack`.
- No L17 (2 usos). No Indomitable. No Fighting Style. No cambia
  `Weapon`/`Spell`/`Item`.

Campo: `Character.action_surge_used`. Defaults en Heroes/archetypes/
monsters. Codec. level_up no toca el flag (lista transitorios).

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46, Action Surge
D47 y spellcasting paladín/ranger L2; el resto de features por nivel
sigue 🟡.

### D48 — Fighting Style 5e
Estado: **Aceptada** — 2026-09-11.

RAW acotado del fighter L1+. El LLM no aplica el bonus (D1): el motor
lo suma en `Combat.attack_roll` / daño / CA. No cambia
`Weapon`/`Spell`/`Item` (D4). Paladín/ranger L2 fuera. Sin picker de
builder: default `"defense"` al forjar fighter.

Campo: `Character.fighting_style` `nil | "archery" | "defense" | "dueling"`.
Codec: string de esos tres o null; jsonb viejo → nil (D4/D8). Defaults
nil en monsters/archetypes; `Heroes.build` fighter → `"defense"` si no
viene.

Efectos (motor):
- `"archery"`: +2 al total de `Combat.attack_roll` si `weapon.ranged == true`.
- `"defense"`: +1 CA efectiva cuando ESTE personaje es el objetivo de
  `Actions.attack` (usa `t.ac + 1`). No muta `Character.ac`.
- `"dueling"`: +2 al daño de arma de `Combat.damage_roll` si
  `weapon.ranged != true`. Acotado: no comprobamos mano vacía ni
  two-handed (no hay flag en Weapon).
- `nil` u otro valor: sin bonus.

Fuera: Protection, Two-Weapon Fighting, Great Weapon Fighting,
Superior Technique, Blind Fighting. No Action Surge redo. Sin feats.

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46, Action Surge
D47, Fighting Style D48 y spellcasting paladín/ranger L2; el resto de
features por nivel sigue 🟡.

### D49 — Lay on Hands 5e
Estado: **Aceptada** — 2026-09-11.

RAW acotado del paladín. El LLM no calcula la curación ni el pool (D1):
llama `lay_on_hands`; el motor aplica y gasta. Economía de acciones
simplificada: la tool ES la acción. Sin curar enfermedad/veneno (gastar
5). Sin Divine Sense. Sin feats. Sin multiclase.

- Solo `class == "paladin"`. Pool máximo = `5 * level`. Campo
  `Character.lay_on_hands_pool` integer = puntos RESTANTES. Default 0.
  Paladín L1 en `Heroes.build` → 5 (o `5 * level` si `choices.level`).
- Tool `lay_on_hands(who, target, amount)` con `amount` integer. DM
  cualquiera; PC sólo si `who` es sí mismo. El target PUEDE ser otro
  personaje (a diferencia de Second Wind).
- Gasta `applied` del pool, no el amount pedido si hay cap:
  `applied = min(amount, remaining_pool, max(0, target.max_hp - target.hp))`.
  Cura por el path de `World.heal/2` (cap max_hp, limpia death saves si
  hp>0). No toca `temp_hp`.
- Errores (no gastan pool): who no existe; target no existe; who no
  paladín; amount no entero ≥ 1; pool 0 o amount > pool; applied == 0
  (objetivo a tope); `target.race` (downcase) `"undead"` o `"construct"`.
- Long rest: paladín que descansa → `lay_on_hands_pool = 5 * level`.
  Short rest NO recarga el pool. `compose_rest/3` lo usan short y long;
  recarga LoH solo en long rest.
- Level-up / merge / transitorios: no resetear el pool (como
  `smite_slot` / `second_wind_used`). El máximo crece al subir de nivel;
  el remaining se conserva.
- Codec encode/decode integer; jsonb viejo sin clave → 0 (D4/D8).

No cambia `Weapon`/`Spell`/`Item`. D46 intacto.

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46, Action Surge
D47, Fighting Style D48, Lay on Hands D49 y spellcasting paladín/ranger
L2; el resto de features por nivel sigue 🟡.

### D50 — Bardic Inspiration 5e
Estado: **Aceptada** — 2026-09-11.

RAW acotado del bardo. El LLM no tira el d6 ni elige cuándo (D1): llama
`bardic_inspiration`; el motor gasta el uso, marca `inspired` y aplica
el d6 en el primer roll del inspirado. Economía de acciones
simplificada: la tool ES el bonus action. Siempre d6 (sin escala
L5/10/15). Sin Font of Inspiration (short rest). Sin colleges, Cutting
Words, feats ni multiclase.

- Solo `class == "bard"` puede GASTAR usos. El buff puede ir a cualquier
  personaje (aliado o el propio bardo).
- Campos:
  - `Character.bardic_inspiration_uses` integer = usos RESTANTES.
    Default 0. Bardo en `Heroes.build` → `max(1, Character.modifier(c, :cha))`
    (CHA 8 → 1; CHA 16 → 3).
  - `Character.inspired` boolean = tiene un d6 pendiente. Default false.
    Cualquier clase puede estar inspired.
- Tool `bardic_inspiration(who, target)`: who es el bardo, target recibe
  `inspired=true`, who gasta 1 uso. DM cualquiera; PC sólo si `who` es
  sí mismo. Target puede ser otro.
- Errores (no gastan): who no existe; target no existe; who no bardo;
  uses == 0; target ya `inspired` (no stack, no refresh).
- El motor aplica y consume el d6 en el PRIMER de estos rolls del
  personaje inspired:
  1. `Actions.attack` — 1d6 al total del attack roll del PRIMER swing
     (Extra Attack: solo el primero). Hit o miss consume. No se suma al
     daño.
  2. `Actions.check` — 1d6 al total del chequeo.
  3. Salvación (`Combat.saving_throw` vía `Actions.spell` u otro path) —
     1d6 al total.
  4. `make_death_save` / death save — 1d6 al d20.
- Tras aplicar: `inspired = false`. El LLM no elige cuándo.
- Long rest del bardo: `bardic_inspiration_uses = max(1, cha_mod)`. No
  recarga en short rest. `inspired` de quien descansa (long rest) se
  pone false.
- Level-up / merge / transitorios: no resetear uses ni inspired.
- Codec: integer uses + boolean inspired (`== true`); jsonb viejo → 0 /
  false (D4/D8).

No cambia `Weapon`/`Spell`/`Item`. D49 intacto.

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46, Action Surge
D47, Fighting Style D48, Lay on Hands D49, Bardic Inspiration D50 y
spellcasting paladín/ranger L2; el resto de features por nivel sigue 🟡.

### D51 — Arcane Recovery 5e
Estado: **Aceptada** — 2026-09-11.

RAW acotado del mago. El LLM no elige ni calcula huecos (D1): llama
`arcane_recovery`; el motor restaura. Economía de acciones
simplificada: la tool ES el uso, fuera de combate. No exige haber
hecho short rest justo antes. Sin Signature Spells, Spell Mastery,
ritual_casting como tool, feats ni multiclase.

- Solo `class == "wizard"`.
- Campo `Character.arcane_recovery_used` boolean, default false.
  Codec `== true`; jsonb viejo → false (D4/D8).
- Tool `arcane_recovery(who)`. DM cualquiera; PC sólo sí mismo.
- Fuera de combate (`phase != :combat`). En combate → error, no marca
  used.
- Ya used → error. No mago → error. Who no existe → error.
- Presupuesto: `div(level + 1, 2)` (ceil(level/2)). Ningún hueco de
  nivel > 5.
- Restaura huecos GASTADOS (`current < max` de
  `SpellSlots.for_class(class, level)`), greedy de nivel más alto a
  más bajo. Restaurar un hueco de nivel N consume N del presupuesto.
  Para cuando el presupuesto restante < N.
- Si no hay ningún hueco gastado restaurable → error, no marca used.
- Si restaura al menos 1 hueco → marca `arcane_recovery_used = true`.
- Mensaje ES: qué niveles restauró y cuántos (ej. “recupera 1 hueco
  de nivel 2 y 1 de nivel 1”).
- Long rest: `arcane_recovery_used = false` (en `compose_long_rest`,
  NO en `compose_rest`/short rest). Short rest NO recarga el flag ni
  llama Arcane Recovery solo.
- Level-up / merge / transitorios: no resetear el flag.
- Warlock Pact Magic (D40) intacto. No toca bardos/clérigos/paladines.

No cambia `Weapon`/`Spell`/`Item`. D50 intacto.

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46, Action Surge
D47, Fighting Style D48, Lay on Hands D49, Bardic Inspiration D50,
Arcane Recovery D51 y spellcasting paladín/ranger L2; el resto de
features por nivel sigue 🟡.

### D52 — Divine Sense 5e
Estado: **Aceptada** — 2026-09-11.

RAW acotado del paladín. El LLM no calcula ni lista tipos (D1): llama
`divine_sense`; el motor gasta 1 uso y reporta. Economía de acciones
simplificada: la tool ES el uso. Combate permitido. No exige short rest
previo. Sin reloj “hasta el final de tu próximo turno”, sin 60 ft, sin
cobertura (no hay grid). Sin Channel Divinity, Turn the Unholy,
Improved Divine Sense, lugares consagrados/desecrados, feats ni
multiclase.

- Solo `class == "paladin"`.
- Campo `Character.divine_sense_uses` integer = usos RESTANTES.
  Default 0. Codec integer; jsonb viejo/ausente → 0 (D4/D8).
- Usos máximos: `max(1, 1 + Character.modifier(c, :cha))`. Paladín en
  `Heroes.build` inicializa a ese máximo (CHA 16 → 4). Otras clases 0.
- Tool `divine_sense(who)`. DM cualquiera; PC sólo sí mismo.
- 0 usos → error, no escanea. No paladín → error. Who no existe →
  error.
- Gasta 1 uso SIEMPRE que el scan se ejecute, incluso si no hay
  objetivos.
- Escanea TODOS los demás personajes del World (incluidos hp ≤ 0)
  cuya `race` downcase esté en `["celestial", "fiend", "undead"]`.
  No incluye a `who`. Reusa el truco de `race` de D46/D49.
- Mensaje ES con nombre + tipo: celestial → “celestial”, fiend →
  “infernal”, undead → “no-muerto”. Vacío: no percibe celestiales,
  infernales ni no-muertos.
- Long rest: paladín → refill al máximo; otras clases no-op. En
  `compose_long_rest`, NO en short rest.
- Level-up / merge / transitorios: no resetear usos restantes.
- D46 Divine Smite y D49 Lay on Hands intactos.

No cambia `Weapon`/`Spell`/`Item`. D51 intacto.

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46, Action Surge
D47, Fighting Style D48, Lay on Hands D49, Bardic Inspiration D50,
Arcane Recovery D51, Divine Sense D52 y spellcasting paladín/ranger
L2; el resto de features por nivel sigue 🟡.

### D53 — Turn Undead 5e
Estado: **Aceptada** — 2026-09-11.

RAW acotado del clérigo. El LLM no tira salvaciones ni elige no-muertos
(D1): llama `turn_undead`; el motor gasta el uso y aplica. Economía de
acciones simplificada: la tool ES el uso. Combate permitido; también
fuera de combate. Sin 30 ft / cover (no hay grid). Sin Dash obligatorio,
sin “no puede acercarse”, sin Destroy Undead L5, sin Channel de dominio,
sin Turn the Unholy, sin reloj de 1 minuto, sin feats ni multiclase.

- Solo `class == "cleric"` y `level >= 2`.
- Campo `Character.channel_divinity_used` boolean, default false.
  Codec `== true`; jsonb viejo/ausente → false (D4/D8).
- 1 uso hasta un rest (v1: no 2 usos a L6). Recarga en `compose_rest`
  (short Y long), como Second Wind.
- Tool `turn_undead(who)`. DM cualquiera; PC sólo sí mismo.
- Error, no gasta: who no existe; no clérigo; level < 2; already used.
- Gasta SIEMPRE si se ejecuta, incluso sin no-muertos.
- Objetivos: demás personajes con `race` downcase `"undead"` y hp > 0.
  Cada uno tira salvación de Sabiduría vs DC
  `8 + Rules.Ability.proficiency(level) + Character.modifier(cleric, :wis)`.
  Roller inyectado (`turn_undead(world, who, roller)`).
- Fallo: `World.apply_condition(name, "frightened")` (idempotente).
  Éxito: nada. Turned ≈ frightened (M06 ya da desventaja).
- Mensaje ES: lista quién falla (asustado) y quién supera, DC, usos.
  Vacío: “no hay no-muertos que Expulsar no-muertos pueda afectar”.
- Level-up / merge / transitorios: no resetear el flag.
- Reusa `race == "undead"` (D46/D49/D52). D52 Divine Sense y D49 intactos.

No cambia `Weapon`/`Spell`/`Item`. D52 intacto.

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46, Action Surge
D47, Fighting Style D48, Lay on Hands D49, Bardic Inspiration D50,
Arcane Recovery D51, Divine Sense D52, Turn Undead D53 y
spellcasting paladín/ranger L2; el resto de features por nivel sigue 🟡.

### D54 — Ki + Flurry of Blows 5e
Estado: **Aceptada** — 2026-09-13.

RAW acotado del monje. El LLM no tira ni elige dados (D1): llama
`flurry_of_blows`; el motor gasta 1 ki y resuelve 2 golpes sin armas.
Economía de acciones simplificada: la tool ES el Flurry (no exige haber
atacado antes). Combate permitido; también fuera de combate. Sin
Patient Defense, Step of the Wind, Stunning Strike, Deflect Missiles,
Martial Arts "golpe extra tras Attack action", Unarmored Movement,
feats ni multiclase.

- Solo `class == "monk"` y `level >= 2`.
- Campo `Character.ki` integer = puntos RESTANTES, default 0. Codec
  integer; jsonb viejo/ausente → 0 (D4/D8).
- Máximo de ki: `level` si monk L2+, si no 0 (`Progression.ki_points/2`).
  Builder monje L1 → 0; L2+ → `level`. Otras clases 0.
- Tool `flurry_of_blows(who, target, mode)`. DM cualquiera; PC sólo
  sí mismo. `mode` como `make_attack` (normal/advantage/disadvantage).
- Error, no gasta ki: who/target no existen; who caído (hp ≤ 0); no
  monje; level < 2; ki < 1.
- Gasta 1 ki SIEMPRE que se resuelvan los swings (hit o miss). Si el
  objetivo cae a mitad, omite el segundo swing (igual que Extra Attack).
- 2 golpes sin armas, N=2 fijo (NO `Progression.attack_count/2`): sin
  Sneak, sin Smite, sin Extra Attack. Reusa `resolve_swings` (como
  Action Surge D47).
- Arma sintética, no hace falta en inventory y no cambia `Weapon`:
  `%Weapon{name: "unarmed strike", dice: martial_arts_die, damage_type: "bludgeoning", attack_ability: :dex, finesse: true, ranged: false}`.
  Dado de artes marciales (`Progression.martial_arts_die/1`): L1–4
  "1d4", L5–10 "1d6", L11–16 "1d8", L17–20 "1d10".
- Mensaje ES: "X usa Ráfaga de golpes (ki restantes N). …" + el formato
  de ataque habitual.
- Short rest Y long rest: monje → refill ki al máximo (`level`); otras
  clases no-op. En `compose_rest` (como Channel Divinity D53).
- Level-up / merge / transitorios: no resetear ki restante.
- D35/D41/D46/D47 intactos.

No cambia `Weapon`/`Spell`/`Item`. D53 intacto.

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46, Action Surge
D47, Fighting Style D48, Lay on Hands D49, Bardic Inspiration D50,
Arcane Recovery D51, Divine Sense D52, Turn Undead D53, Ki/Flurry of
Blows D54 y spellcasting paladín/ranger L2; el resto de features por
nivel sigue 🟡.

### D55 — Hunter's Mark 5e
Estado: **Aceptada** — 2026-09-13.

RAW acotado del explorador. El LLM no tira dados (D1): llama
`hunters_mark`; el motor gasta 1 casilla de nivel 1, fija concentración
y aplica +1d6 en los impactos del marcador contra la presa. Sin economía
de acción bonus (la tool ES la marca), ventajas de tracking/perception,
múltiples presas, transferir marca entre objetivos, Branding Smite,
otros hechizos de concentración nuevos, feats ni multiclase.

- Solo `class == "ranger"` y `level >= 2` (half-caster: casillas desde
  L2).
- NO cambia `Character`/`Weapon`/`Spell`/`Item`: la marca vive en
  `concentrating` (string, D37) como `"hunter's mark:<presa>"` y gasta
  `spell_slots` de nivel 1 (`consume_slot`, como Divine Smite D46).
  Codec no cambia.
- Tool `hunters_mark(who, target)`. DM cualquiera; PC sólo sí mismo.
- Éxito (en este orden): who/target existen; who no caído (hp > 0);
  ranger L2+; target vivo (hp > 0); `has_slot?(who, 1)`; no concentra
  ya (si concentra —incluida otra marca— error: debe soltar antes con
  `drop_concentration`). Entonces gasta 1 casilla nivel 1 y
  `set_concentration(who, "hunter's mark:<target>")`.
- Errores NO gastan casilla ni tocan concentración.
- Daño: en la resolución de `make_attack` (swings de arma), si el
  atacante concentra `"hunter's mark:X"` y el objetivo es X → +1d6 por
  impacto, tipo de daño = el del arma (como Sneak Attack D41). Crítico
  dobla los d6 de la marca. NO aplica en spells ni en Flurry, ni a
  objetivos distintos de X: match exacto case-insensitive del nombre,
  sin fuzzy.
- El +1d6 se tira con el roller determinista dentro de la entrada de
  daño del RollLog (patrón sneak D41).
- Fin de la marca: `drop_concentration` existente, condiciones en
  `@breaks_concentration`, rage, unconscious — todo ya lo limpia
  (D37/D42); nada nuevo. Rests: nada nuevo (las casillas ya se
  recargan; la concentración persiste en descanso — RAW, así se queda).
- Mensaje ES: "X marca a Y como presa (Hunter's Mark, concentración,
  casilla nivel 1 gastada)." y en el golpe el desglose habitual con el
  d6 extra etiquetado "(+N presa marcada)" (formato sneak).

No cambia `Character`/`Weapon`/`Spell`/`Item`. D37/D41/D46 intactos.

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46, Action Surge
D47, Fighting Style D48, Lay on Hands D49, Bardic Inspiration D50,
Arcane Recovery D51, Divine Sense D52, Turn Undead D53, Ki/Flurry of
Blows D54, Hunter's Mark D55 y spellcasting paladín/ranger L2; el resto
de features por nivel sigue 🟡.

### D56 — Font of Magic 5e
Estado: **Aceptada** — 2026-09-13.

RAW acotado del hechicero: pool de puntos de hechicería con conversión
bidireccional a casillas. El LLM no calcula (D1): llama las tools; el
motor valida, gasta y convierte. Combate permitido (bonus action RAW;
economía de acciones fuera, como siempre). Sin Metamagic
(Quickened/Twinned/etc.), sorcerous restoration, gastar puntos en otras
cosas, feats ni multiclase.

- Solo `class == "sorcerer"` y `level >= 2`.
- Campo `Character.sorcery_points` integer = puntos RESTANTES, default
  0. Codec integer; jsonb viejo/ausente → 0 (patrón `ki` D54).
- Máximo: `level` si hechicero L2+, si no 0
  (`Progression.sorcery_points/2`). Builder hechicero L1 → 0; L2+ →
  `level`. Otras clases 0.
- Tool A `create_spell_slot(who, level)`: `level` entero 1..5 (RAW:
  máx casilla 5º). Coste RAW (`Progression.sorcery_slot_cost/1`):
  1º=2, 2º=3, 3º=5, 4º=6, 5º=7. Requiere `sorcery_points >= coste`;
  resta puntos y suma 1 casilla de ese nivel (`World.gain_slot/2`,
  encima del máximo diario — RAW lo permite). Si ya tiene casillas de
  ese nivel, incrementa en 1.
- Tool B `convert_to_sorcery_points(who, level)`: `level` entero 1..5
  — **decisión**: mismo rango que create por coherencia (el hechicero
  no tiene casillas superiores a 5º de su tabla y las creadas también
  son 1..5; sigue RAW en la práctica). Requiere `has_slot?(who, level)`;
  gasta 1 casilla (`consume_slot`) y gana `level` puntos con cap
  silencioso al máximo (`gain_sorcery_points`): el exceso se pierde, NO
  es error, y el mensaje muestra el resultado real.
- Ambas tools: DM cualquiera; PC sólo sí mismo (patrón divine_smite
  D46).
- Errores NO mutan nada: who no existe; who caído (hp ≤ 0); no
  hechicero; level < 2; nivel de casilla inválido (no entero o fuera
  de 1..5); puntos insuficientes (A); sin casilla de ese nivel (B).
- Rests: SOLO long rest rellena puntos al máximo (`level`) en
  `compose_long_rest` — RAW es long rest; DISTINTO de ki D54 que
  recarga en ambos. Short rest no toca el pool. Level-up no resetea
  puntos restantes.
- Mensajes ES: A "X teje magia: convierte N puntos de hechicería en 1
  casilla de nivel L (quedan M puntos)."; B "X drena una casilla de
  nivel L y recupera P punto(s) de hechicería (M/L máx)." + nota de
  exceso disipado si aplica cap.

No cambia `Weapon`/`Spell`/`Item`. D54 intacto (recarga de ki en ambos
rests se mantiene).

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46, Action Surge
D47, Fighting Style D48, Lay on Hands D49, Bardic Inspiration D50,
Arcane Recovery D51, Divine Sense D52, Turn Undead D53, Ki/Flurry of
Blows D54, Hunter's Mark D55, Font of Magic D56 y spellcasting
paladín/ranger L2; el resto de features por nivel sigue 🟡.

### D57 — Cunning Action: Hide 5e
Estado: **Aceptada** — 2026-09-13.

RAW acotado del pícaro: sólo el Hide de Cunning Action. El LLM no tira
dados (D1): llama `cunning_action_hide`; el motor resuelve el chequeo de
DEX (Sigilo) contra la percepción pasiva más alta de los enemigos
conscientes. Combate permitido (bonus action RAW; economía de acciones
fuera, como siempre).

- Solo `class == "rogue"` y `level >= 2`.
- NO cambia `Character`/`Weapon`/`Spell`/`Item` ni Codec: "hidden" es una
  condición más (`conditions`, aplicada con `World.apply_condition`).
- Tool `cunning_action_hide(who)`. DM cualquiera; PC sólo sí mismo.
- Chequeo (determinista, en el motor): tirada `1d20 + mod DEX + prof` si
  `"stealth"` está en `skill_proficiencies` (modo vía
  `Conditions.check_mode(a, :dex, :normal)` — poisoned/frightened aplican
  desventaja). DC = máxima percepción pasiva entre enemigos conscientes
  (`side != who.side` y hp > 0): `10 + mod SAB + prof` si `"perception"`
  entrenada (`Actions.passive_perception/1`). Sin enemigos conscientes →
  DC 10 (mínimo RAW). Éxito (≥ DC) → `apply_condition(who, "hidden")`;
  fallo → sin condición y sigue a la vista. Registro en RollLog (patrón
  ability_check). Mensaje ES con desglose: "X se esconde:
  1d20(12)+3+2=17 vs 15 — oculto" / "— falla y sigue a la vista".
- Ventaja: "hidden" entra en `@attack_self_advantage` de
  `Rules.Conditions` (junto a invisible). Así `make_attack` del oculto
  sale con ventaja efectiva (cancela con desventaja vía `combine`
  existente) y `sneak_opts` ve `:advantage` → Sneak Attack (D41) aplica
  gratis sin aliado.
- Limpieza de "hidden": tras resolver `make_attack` del oculto (hit o
  miss, todos los swings del `Actions.attack`) se quita la condición —
  atacar revela (composition en el change_fn, patrón inspired). Re-
  esconderse mientras oculto → error "ya está oculto" (no re-tira).
- **Hechizos de ataque** (`cast_spell` kind `:attack`): su ruta ya pasa
  por `Conditions.attack_mode`, así que la ventaja del oculto aplica
  gratis — se deja (documentado). **Decisión**: la limpieza de "hidden"
  tras el hechizo de ataque SÍ entra — era un cambio pequeño y local
  (wrap de las dos salidas de la rama `:attack` en `resolve_spell`), y
  sin él un caster oculto conservaría la ventaja para siempre.
- Incapacitación: si el oculto cae `unconscious`/condición
  incapacitante, `apply_condition` existente ya arrastra
  `concentrating`/`raging`/`reckless` pero NO quita "hidden" — fuera
  (no es gratis con la maquinaria existente; documentado). No afecta al
  flujo D57: un caído no puede atacar y el DM tiene
  `remove_condition`.
- Errores NO mutan: who no existe; who caído (hp ≤ 0); no pícaro; nivel
  < 2; ya oculto.
- **Fuera**: Dash y Disengage (este motor no tiene grid ni ataques de
  oportunidad — no tendrían efecto mecánico); visibilidad/posición;
  sigilo sostenido tras varias acciones; ocultarse de aliados; otros
  usos de Sigilo fuera de combate (para eso está `ability_check`);
  Uncanny Dodge; feats; multiclase. Flurry of Blows tampoco limpia
  "hidden" (un monje no llega a oculto por D57 y sin multiclase es
  inalcanzable; fuera de alcance).

No cambia `Character`/`Weapon`/`Spell`/`Item`. M06 gana la fila
`hidden` (ventaja al atacar). D41 intacto (hidden es sólo otra fuente
de ventaja).

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46, Action Surge
D47, Fighting Style D48, Lay on Hands D49, Bardic Inspiration D50,
Arcane Recovery D51, Divine Sense D52, Turn Undead D53, Ki/Flurry of
Blows D54, Hunter's Mark D55, Font of Magic D56, Cunning Action (Hide)
D57 y spellcasting paladín/ranger L2; el resto de features por nivel
sigue 🟡.

### D58 — Danger Sense 5e
Estado: **Aceptada** — 2026-09-13.

Defensa pasiva del bárbaro: ventaja en salvaciones de DES si no está
incapacitado. El LLM no interviene (no hay tool ni reacción): el motor
la aplica solo en la ruta existente de salvaciones.

- Solo `class == "barbarian"` y `level >= 2`. Sin campos nuevos ni
  Codec: class+level se leen en la ruta de resolución.
- Implementación: `Rules.Conditions.save_mode/3` — si el personaje es
  bárbaro L2+ y `ability == :dex` → ventaja, combinada vía `combine/2`
  existente (la desventaja de condición —p. ej. restrained— se cancela a
  normal; la ventaja pedida por el modelo se mantiene).
- Corte de incapacitación: reusa `@auto_fail_saves` (paralyzed/stunned/
  unconscious/petrified) — todas incapacitan y ya auto-fallan DES
  cortocircuitando antes de computar la ventaja (el helper `danger_sense?/2`
  re-chequea por robustez). No hay lista separada de condiciones
  incapacitantes en `Rules.Conditions`; una condición "incapacitated"
  aplicada suelta no corta Danger Sense (simplificación v1 documentada).
- Alcance: TODAS las salvaciones de DES del personaje que pasen por
  `Conditions.save_mode` — spells con save dex (y cualquier ruta futura).
  turn_undead es WIS: no cambia.
- Mensaje: el `mode_tag(:advantage)` existente ya muestra "(ventaja)" en
  el desglose; nada nuevo que escribir.
- **Fuera**: aplicar prof a ability_check (v1 no lo hace — no se arregla
  aquí), Uncanny Dodge, Indomitable, Relentless Rage, feats, multiclase.

No cambia `Character`/`Weapon`/`Spell`/`Item` ni Codec. M06/M42 ganan la
fila Danger Sense (ventaja en salvación DES del bárbaro L2+).

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46, Action Surge
D47, Fighting Style D48, Lay on Hands D49, Bardic Inspiration D50,
Arcane Recovery D51, Divine Sense D52, Turn Undead D53, Ki/Flurry of
Blows D54, Hunter's Mark D55, Font of Magic D56, Cunning Action (Hide)
D57, Danger Sense D58 y spellcasting paladín/ranger L2; el resto de
features por nivel sigue 🟡.

### D59 — Evasión 5e
Estado: **Aceptada** — 2026-09-13.

Defensa pasiva del pícaro: ante un hechizo con salvación de DES que
dañe a medias o a lo bestia, un pícaro L7+ no recibe daño si supera la
salvación y sólo la mitad si falla. El LLM no interviene: el motor la
aplica solo en la rama `:save` de `cast_spell`.

- Solo `class == "rogue"` y `level >= 7`. Sin campos nuevos ni Codec:
  class+level se leen en la ruta de resolución.
- Implementación: `Actions.resolve_save_spell` (rama `{:roll, _}`) —
  tras `Combat.saving_throw`, helper `evasion?/2`: si
  `spell.save_ability == :dex` y el objetivo es pícaro L7+ → éxito en la
  salvación ⇒ daño 0 (aunque el hechizo mitigara a mitad en éxito);
  fallo ⇒ `div(full, 2)` (redondeo hacia abajo), aunque el hechizo
  hiciera daño completo en fallo. Si el hechizo ya haría 0 en éxito,
  Evasión no cambia nada (sigue 0). Inspiración bárdica (D50) se aplica
  antes: un éxito gracias a la inspiración también activa Evasión.
- Sólo hechizos con salvación de DES (`kind: :save`). No aplica a saves
  de otras habilidades ni a daño directo sin save (ni a `:attack`).
- Mensaje: el desglose refleja el efecto — "(Evasión: sin daño)" tras
  superar la salvación, "(Evasión: mitad)" tras fallarla.
- Corte de incapacitación (RAW 5e14 "unless incapacitated"): misma lista
  que D58 — `@auto_fail_saves` auto-falla DES en `Conditions.save_mode`,
  así que un pícaro incapacitado nunca llega a la rama que aplica
  Evasión (recibe daño completo por auto-fallo).
- **Fuera**: Uncanny Dodge, Indomitable, Relentless Rage, Jack of All
  Trades, feats, multiclase; Evasión sobre daños no-HECHIZO (aliento,
  trampas) — v1 sólo modela saves de hechizo.

No cambia `Character`/`Weapon`/`Spell`/`Item` ni Codec. M43 en el
catálogo. 07-contrato-tools NO cambia (no hay tools nuevas).

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46, Action Surge
D47, Fighting Style D48, Lay on Hands D49, Bardic Inspiration D50,
Arcane Recovery D51, Divine Sense D52, Turn Undead D53, Ki/Flurry of
Blows D54, Hunter's Mark D55, Font of Magic D56, Cunning Action (Hide)
D57, Danger Sense D58, Evasión D59 y spellcasting paladín/ranger L2; el
resto de features por nivel sigue 🟡.

### D60 — Proficiency de skills en ability_check + Jack of All Trades
Estado: **Aceptada** — 2026-09-13.

Arregla el hueco v1 documentado en la tool (`ability_check` ignoraba
`Character.skill_proficiencies`: la ficha las guardaba pero la
resolución no las aplicaba — los checks eran menos deterministas de lo
que el motor promete, D1). Con la prof aplicada, Jack of All Trades del
bardo (L2+: mitad de prof en checks SIN el skill entrenado) sale gratis.

- Nueva tabla skill→característica de los 18 skills SRD en
  `Rules.Skills` (`ability/1`, `known?/1`, `normalize/1`): pure, claves
  string snake_case (nunca crea átomos de input del modelo, regla D8
  aplicada fuera del Codec). La normalización acepta espacios/guiones/
  mayúsculas ("Animal Handling" → `animal_handling`).
- La detección es skill-PRIMERO: "intimidation" es un skill de CAR, no
  la característica `int` (el parse de ability es por prefijo y se lo
  habría comido).
- Tool `ability_check(who, ability, dc, mode)` — MISMO arity y MISMO
  nombre de parámetro `ability` en el esquema (exAgent bindea args por
  nombre: renombrarlo rompería llamadas viejas del modelo). El @doc
  explica que acepta skill o característica.
- Resolución (`Combat.ability_check/6` + `Combat.check_proficiency/2`
  público para que el mensaje muestre el mismo desglose que la tirada):
  skill entrenado → prof completa (`Ability.proficiency/1`); sin
  entrenar y bardo L2+ → `div(prof, 2)` (JoaT, floor); sin entrenar y
  no bardo / bardo L1 → 0 como v1. Nunca ambos (RAW: JoaT sólo cubre
  checks que ya no lleven la prof). JoaT también aplica a checks con
  característica cruda (RAW: cualquier check sin prof).
- `Actions.check/8`: firma actual; el tercer parámetro acepta skill o
  ability. Skill pasado por nombre → la prof sale de la ficha
  (`skill_proficiencies`, membresía normalizada) y pisa el flag
  `proficient` del caller; ability cruda → flag del caller (compat).
  Skill desconocido que tampoco es ability → error directivo con
  ejemplos.
- Mensaje ES con desglose. Skill: "X hace un chequeo de Sigilo (DES):
  1d20(11) + DES 3 + prof 2 = 16 vs CD 15 — éxito"; JoaT se etiqueta
  "+ JoaT 1" (o "+ 1 (JoaT)" en el formato crudo). Ability cruda:
  formato v1 sin cambios. Etiquetas ES de skill/característica corta
  reutilizadas de `Heroes.Translations` (cero duplicación).
- `cunning_action_hide` (D57) NO cambia: ya suma prof de stealth por su
  cuenta (`skill_trained?/2`, ahora con membresía normalizada); un
  pícaro nunca es bardo (sin multiclase), JoaT no le aplica.
- Prompts: línea de `ability_check` del PC (exploración) y del DM
  actualizadas para pedir el NOMBRE DE SKILL cuando aplique y ability
  cruda sólo para checks genéricos. SIN línea nueva de JoaT en el prompt
  del bardo (es pasiva; no necesita anuncio).
- Sin campos nuevos de Character/Weapon/Spell/Item ni cambios de Codec.

**Fuera**: Expertise (doble prof), prof de tools/instrumentos, checks
pasivos distintos de perception (ya cubierto en D57), Reliable Talent,
feats, multiclase.

No cambia `Character`/`Weapon`/`Spell`/`Item` ni Codec. M44 en el
catálogo; 07-contrato-tools actualiza la fila de `ability_check`.

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46, Action Surge
D47, Fighting Style D48, Lay on Hands D49, Bardic Inspiration D50,
Arcane Recovery D51, Divine Sense D52, Turn Undead D53, Ki/Flurry of
Blows D54, Hunter's Mark D55, Font of Magic D56, Cunning Action (Hide)
D57, Danger Sense D58, Evasión D59, Jack of All Trades D60 y
spellcasting paladín/ranger L2; el resto de features por nivel sigue 🟡.

### D61 — Aura of Protection del paladín 5e
Estado: **Aceptada** — 2026-09-13.

Starting at L6, a paladin shares their charisma with every save of
their side. Automática (D1: el motor la aplica, el LLM no la anuncia
ni la pide) y **sin campos nuevos** — se deriva de `class`/`level`/
`cha`/`hp`/`side` que ya viven en `Character`.

- **Bonus**: `modifier(paladín, :cha)` por paladín consciente L6+ del
  mismo `side` que quien tira (el propio paladín incluido). Varios
  paladines **apilan** (RAW auras múltiples de same-name no, pero de
  paladines distintos sí: sumamos). CHA < 10 → bonus **negativo sin
  piso** (RAW: se aplica tal cual).
- **Simplificación sin grid**: no hay radio de 10 pies ni posiciones —
  el aura cubre a TODO personaje con `side == paladín.side` mientras
  el paladín tenga `hp > 0` (mismo criterio de "aliado consciente" que
  `conscious_ally?` D41). La regla es **genérica por side**: un
  no-muerto aliado de un paladín L6+ también lo recibe (aceptable).
- **Cobertura**: TODAS las salvaciones que resuelve el motor — rama
  `:save` de `cast_spell`, `turn_undead` (SAB), death saves
  (`make_death_save`, RAW sí aplica) y concentración (CON, daño). NO
  aplica a ability checks ni attack rolls (RAW).
- **Inserción**: `Actions.aura_save_bonus/2` (privado) suma al total
  tras `Combat.saving_throw` y antes de la inspiración bárdica (D50
  re-deriva el éxito del total acumulado, así no se pierde);
  `Combat.death_save/2` gana `bonus \\ 0` que desplaza el umbral 10
  sin tocar nat 1/20 (key off del dado). El desglose del mensaje lo
  muestra: "13 vs CD 13 **+3 aura**" / "(-1 aura)" en death saves.
- Helper compartido `World.paladins_conscious/3` (side, min_level).
- Sin tools, sin allowlist, sin prompts (pasiva), sin cambios de
  `Character`/`Weapon`/`Spell`/`Item` ni Codec.

**Fuera**: radio 10 pies (sin grid), Aura of Devotion vs charm (aura
de nivel 7, futuro), Aura of Hate (Oathbreaker), auras de otro tipo
(courage es D62), Improved Divine Smite, feats, multiclase. M45 en el
catálogo.

### D62 — Aura of Courage del paladín 5e
Estado: **Aceptada** — 2026-09-13.

Starting at L10, the paladin (y todo su side) no puede ser
frightened. Automática, **sin campos nuevos**, misma simplificación
sin-grid por `side` que D61 (todo aliado consciente-incluido del
paladín L10+ con `hp > 0`).

- **Hook en `World.apply_condition/2`**: si `condition ==
  "frightened"` y `World.courage_immune?/2` (alias de
  `paladins_conscious(w, side, 10) != []`, D61) → la condición NO se
  aplica: `{:ok, world}` **sin mutar**. La inmunidad no es error —
  los callers lo reportan.
- **Mensajes**: `Tools.apply_condition` (DM) devuelve "X es inmune al
  miedo (Aura de Coraje)" en vez del "ahora está frightened" mentiroso;
  `turn_undead` (D53) particiona sus objetivos fallidos en
  asustados/inmunes y añade "X es inmune al miedo (Aura de Coraje)".
  El doble hook (Actions particiona, World no-op) es defensa en
  profundidad: cualquier caller viejo queda cubierto por el no-op.
- **Idempotencia intacta**: la rama inmune no añade duplicados ni
  rompe `remove_condition`; las demás condiciones pasan igual.
- **Regla genérica por side**: `apply_condition` la usa turn_undead
  (D53) — un no-muerto aliado de un paladín L10+ sería inmune al
  fear de su propio clérigo (aceptable, documentado aquí).
- Sin tools nuevas, sin prompts (pasiva), sin cambios de
  `Character`/`Weapon`/`Spell`/`Item` ni Codec.

**Fuera**: radio 10 pies, inmunidad compartida con charm (Aura of
Devotion, L7, futuro), cleansed fear existente (el DM tiene
`remove_condition`), feats, multiclase. M46 en el catálogo.

### D63 — Wild Shape del druida 5e
Estado: **Aceptada** — 2026-09-13.

El druida L2+ se transforma en una bestia de un **catálogo fijo** de
CR ≤ 1/2; el LLM decide CUÁNDO, el motor valida, transforma y revierte
(D1). Dos campos NUEVOS en `Character`: `wild_shape_uses` (int, default
0; druida L2+ del builder → 2, L1/otras → 0; jsonb viejo → 0) y
`wild_shape` (nil = forma normal; transformado =
`%{beast, orig_str, orig_dex, orig_con, orig_hp, orig_max_hp, orig_ac,
orig_weapons}` — claves átomo en memoria, strings en Codec, D8).

- **Catálogo**: `Monsters.cat/1` (CR 0: STR 3, DEX 15, CON 10, SAB 12,
  CAR 7, PG 4, CA 12, bite 1d4 finesse), `black_bear/1` (CR 1/2: STR 15,
  DEX 14, CON 14, PG 19, CA 11, bite 1d6 — el motor suma STR +3 encima →
  **1d6+3 RAW**; los dados de arma SOLO parsean `NdM`, un `"1d8+3"`
  literal crasheaba `Combat.parse_dice`) y el `wolf` existente
  (**bite 2d4**: STR 12 → el motor suma +1 → 2d4+1 vs 2d4+2 RAW, media
  6 vs 7 — aproximación asumida, sin flat en dados de arma); los
  tres también en `Monsters.catalog/0` (spawnables por el DM) y en
  `Monsters.wild_shape_beasts/0` → `%{"cat" => 0.0, "wolf" => 0.25,
  "black_bear" => 0.5}` (cr float).
- **Gate de CR** (en `Actions.wild_shape/3`, RAW): druida L2–4 → máx
  0.25 (cat, wolf); L5+ → máx 0.5 (todas). Sin formas volar/nadar.
- **Tools** `wild_shape(who, beast)` / `end_wild_shape(who)`: DM
  cualquiera; PC sólo sí mismo (patrón divine_smite). Errores NO mutan
  (who inexistente, caído, no druida, L1, ya transformado, bestia
  desconocida, CR superior, 0 usos / no transformado en el revert).
- **Éxito transformar**: gasta 1 uso SIEMPRE; guarda
  str/dex/con/hp/max_hp/ac/weapons originales; aplica los de la bestia;
  CONSERVA int/wis/cha, nombre, side, clase, nivel, proficiencies,
  skill_proficiencies, condiciones y concentración (RAW no se rompe).
  El inventario de items NUNCA cambia (armas de bestia sintéticas; las
  originales se restauran al revertir). Mensaje ES: "X adopta la forma
  de un lobo (usos de forma salvaje restantes: N)."
- **Revert manual**: restaura TODO lo guardado con `hp = orig_hp`
  exacto; `wild_shape = nil`. Mensaje: "X vuelve a su forma original
  (PG N)."
- **Auto-revert** en `World.apply_damage/3` (cuello único de daño): si
  el objetivo está transformado y el hp resultante ≤ 0, exceso =
  daño que sobra tras la bestia (rest − hp bestia, tras resist y
  temp_hp como hoy); revierte y aplica el exceso a los PG originales:
  `hp = max(0, orig_hp − exceso)`. Daño exacto a 0 → exceso 0 → PG
  originales intactos. Si queda a 0 → caído (death saves como siempre).
  Nota en el log del world ("la bestia cae y X vuelve a su forma (PG
  N)") para que la narración lo muestre. temp_hp se consume antes que
  hp como hoy.
- **Bloqueo de hechizos**: mientras `wild_shape != nil`,
  `Actions.spell` → "X no puede conjurar en forma de bestia". TODO lo
  demás (`make_attack` con las armas de bestia, `ability_check`,
  descansar) funciona igual.
- **Rests**: short Y long recargan `wild_shape_uses` a 2 (druida) en
  `compose_rest` (como ki D54, RAW permite descansar en forma — no
  fuerza revert). Level-up no toca usos ni forma.

**Fuera** (simplificaciones asumidas): duración (sin reloj — sin
límite de horas), componentes verbales/somáticos (el bloqueo integral
de cast_spell ya lo cubre), Circle of the Moon (CR 2+ / formas de
combate), formas con velocidad de vuelo/natación, multiclase, feats,
equipment merge. M47 en el catálogo.

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46, Action Surge
D47, Fighting Style D48, Lay on Hands D49, Bardic Inspiration D50,
Arcane Recovery D51, Divine Sense D52, Turn Undead D53, Ki/Flurry of
Blows D54, Hunter's Mark D55, Font of Magic D56, Cunning Action (Hide)
D57, Danger Sense D58, Evasión D59, Jack of All Trades D60, Aura of
Protection D61, Aura of Courage D62, Wild Shape D63 y spellcasting
paladín/ranger L2; el resto de features por nivel sigue 🟡.

---

### D64 — Uncanny Dodge del pícaro 5e
Estado: **Aceptada** — 2026-09-13.

El pícaro L5+ arma una postura defensiva que reduce a la mitad el
próximo daño; el LLM decide CUÁNDO armar, el motor mitiga y consume
(D1). Sin reacciones ni rondas en el motor, se modela como flag
booleana (patrón `inspired`/`reckless`): `Character.uncanny_dodge`
(default false; true = armada; jsonb viejo/ausente → false, D8).

- **Tool** `start_uncanny_dodge(who)`: DM cualquiera; PC sólo sí mismo
  (patrón divine_smite). Errores NO mutan (who inexistente, caído
  hp≤0, no pícaro, nivel < 5, ya armada). Éxito: `uncanny_dodge =
  true`. Mensaje ES: "X se prepara para esquivar (Uncanny Dodge
  armado: el próximo daño se reduce a la mitad)."
- **Mitigación** en `World.apply_damage/3` (cuello único de daño):
  armada y `amount > 0` → el amount de ENTRADA se reduce a la mitad
  (`div/2`, floor) ANTES de resistencias (D38), temp_hp (D36) y hp —
  la forma más simple y determinista; el orden interno existente de
  `apply_damage` manda y queda fijado aquí. La flag se consume
  (`false`). Aplica a CUALQUIER fuente que pase por `apply_damage`
  (ataque, hechizo, trampa). amount ≤ 0 NO consume.
- **D63 intacto**: el auto-revert de Wild Shape corre después con el
  daño ya mitigado (exceso mitigado); un druida nunca es pícaro (sin
  multiclase), no hay caso cruzado.
- **Apila con Evasión (D59)**: mitad de mitad = cuarto (floor) —
  correcto RAW para un pícaro L7+ con ambas activas.
- **Sin economía de reacción/ronda** (simplificación asumida): 1 uso
  por DAÑO, no por ronda; armar es gratis en cualquier momento y se
  puede rearmar tras consumir; los descansos NO la gestionan (no es
  recurso por descanso — no se "recarga", simplemente se rearma).

**Fuera**: reacción formal/ronda (1/ronda RAW), resistencias dañinas
(otro sistema, D38), Evasion (ya existe D59 y se apila), Deflect
Missiles, feats, multiclase. M48 en el catálogo.

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46, Action Surge
D47, Fighting Style D48, Lay on Hands D49, Bardic Inspiration D50,
Arcane Recovery D51, Divine Sense D52, Turn Undead D53, Ki/Flurry of
Blows D54, Hunter's Mark D55, Font of Magic D56, Cunning Action (Hide)
D57, Danger Sense D58, Evasión D59, Jack of All Trades D60, Aura of
Protection D61, Aura of Courage D62, Wild Shape D63, Uncanny Dodge D64
y spellcasting paladín/ranger L2; el resto de features por nivel sigue
🟡.

---

### D65 — Metamagic del hechicero 5e
Estado: **Aceptada** — 2026-09-13.

El hechicero L3+ arma UNA opción de Metamagic gastando puntos de
hechicería (D56); el LLM decide CUÁNDO armar, el motor aplica y consume
con el próximo hechizo que califique (D1). Campo NUEVO en `Character`:
`metamagic` (nil = sin armar; armada =
`%{option: String.t(), target: String.t() | nil}` — claves átomo en
memoria, strings en Codec, jsonb viejo/ausente → nil, D8). Sólo UNA
opción armada a la vez.

- **Por qué esas tres**: Empowered (1 pt — reroll de dados de daño),
  Heightened (3 pts — desventaja en la salvación del objetivo) y Twinned
  (2 pts — el hechizo golpea también a un segundo objetivo) son las tres
  con efecto determinista real en un motor single-target sin reacciones
  ni economía de bonus actions. Quickened (economía de acciones),
  Distant/Extended (rango/duración no modelados), Subtle y Careful (sin
  área ni counterspell) quedan FUERA por no tener efecto mecánico aquí.
- **Tool** `arm_metamagic(who, option, target \\ "")`: DM cualquiera; PC
  sólo sí mismo (patrón divine_smite). `option` minúscula, tolerante a
  mayúsculas. Errores NO mutan: who inexistente, caído (hp≤0), no
  hechicero, nivel < 3, opción desconocida (mensaje con las tres
  válidas), ya armada ("X ya tiene Metamagia armada: OP — se consume con
  su próximo hechizo que califique"; SIN un-arm en v1), puntos
  insuficientes (coste exacto en el mensaje), heightened sin target,
  twinned sin target / target inexistente / target == who.
- **Éxito**: gasta el coste (1/3/2) vía `World.spend_sorcery_points/2`
  (D56) y fija `metamagic` (`World.set_metamagic/2`). SIN reembolso.
  Mensaje ES: "X arma Metamagia: Empowered (1 punto de hechicería,
  quedan N). El próximo hechizo que califique la aplicará." (Heightened/
  Twinned añaden "sobre <target>").
- **Aplicación/consumo** — SÓLO en `Actions.spell/5` → `resolve_spell`
  (nada de make_attack ni otros sitios):
  - **Empowered**: hechizo con dados de daño (dice + damage_type, kinds
    :attack/:automatic/:save) → los primeros `max(1, mod CAR)` dados se
    tiran dos veces conservando el mayor (determinista: dos tiradas del
    roller por dado mejorado; flat modifiers intactos). En crit se dobla
    la base mejorada SIN duplicar los rerolls. Etiqueta
    "(Metamagia: Empowered)" en el desglose. Un hechizo :attack que
    falla igualmente la consume (el hechizo califica por tipo — RAW se
    elige al lanzar). Curación y utilidad NUNCA califican.
    **Desviación RAW deliberada**: el keep-higher no es el "you must use
    the new rolls" del texto 2014 — se elige determinismo (el reroll
    nunca empeora) sobre la letra; documentado aquí, no en el prompt.
  - **Heightened**: hechizo :save cuyo objetivo == target armado → esa
    salvación se resuelve con desventaja (entra como
    `requested: :disadvantage` en `Conditions.save_mode`, se combina con
    lo existente por capas: Evasión/Danger Sense D58-D59/auras D61-D62
    intactas). Etiqueta "(Metamagia: Heightened)". Si el hechizo apunta
    a OTRO personaje (o no es :save), NO aplica NI consume.
  - **Twinned**: hechizo resuelto contra un objetivo ≠ lanzador → el
    MISMO hechizo se resuelve también contra el segundo target armado
    (cada resolución tira sus propios dados, NO re-usa los del primero;
    helper `resolve_twinned` que reusa `resolve_spell` contra target2 y
    compone cambios/mensajes en bloque por objetivo "… en A: …; en B:
    …"). La casilla se consume UNA vez (`compose_slot_consumption` ya lo
    hace) y la concentración se fija UNA sola vez (el hechizo es uno).
    Self-buff (objetivo == lanzador) NO aplica NI consume; twin target
    desaparecido del mundo → resolución simple sin consumir.
- **Consumo-on-apply** (divergencia menor de RAW, que la elige al
  lanzar): la opción se consume SÓLO cuando el hechizo califica;
  hechizos que no califican la dejan armada. Es la semántica más simple
  con un flag persistente y evita "quemar" la opción con un buff.
- **Interacciones**: un hechicero nunca es druida/bárbaro (sin
  multiclase) — sin casos cruzados con Wild Shape D63/rage. Empowered
  respeta crit doubling donde aplique (sin duplicar rerolls).
- **Rests**: nada nuevo — los puntos ya se recargan en long rest (D56);
  `metamagic` NO se toca en descansos (si quedó armada, sigue armada).
  Level-up tampoco la toca (patrón estado transitorio).

**Fuera**: Quickened, Distant, Extended, Subtle, Careful (sin efecto en
este motor), Sorcerous Restoration, más de una opción simultánea,
un-arm, reembolsos, Metamagic Adept, feats, multiclase. M49 en el
catálogo.

R09 queda **parcial**: Extra Attack D35, Sneak Attack D41, Rage D42,
Reckless Attack D44, Second Wind D45, Divine Smite D46, Action Surge
D47, Fighting Style D48, Lay on Hands D49, Bardic Inspiration D50,
Arcane Recovery D51, Divine Sense D52, Turn Undead D53, Ki/Flurry of
Blows D54, Hunter's Mark D55, Font of Magic D56, Cunning Action (Hide)
D57, Danger Sense D58, Evasión D59, Jack of All Trades D60, Aura of
Protection D61, Aura of Courage D62, Wild Shape D63, Uncanny Dodge D64,
Metamagic D65 y spellcasting paladín/ranger L2; el resto de features por
nivel sigue 🟡.

---

### D66 — Lucky del mediano 5e
Estado: **Aceptada** — 2026-09-14.

Rasgo racial AUTOMÁTICO (D1): el mediano (`race == "halfling"`, clave
del builder D52) rerollea sus 1 naturales. El agente no llama nada y no
hay tool ni prompt — el motor lee la raza de la ficha.

- **Dónde aplica**: en las TRES tiradas de d20 con personaje de
  `Rules.Combat` — `attack_roll/5`, `saving_throw/5`, `ability_check/6`.
  Si el d20 EFECTIVO (el conservado tras ventaja/desventaja) es 1 → se
  rerollea UNA vez y se USA el nuevo resultado (RAW "must use the new
  roll"; NO es keep-best: si el reroll da 1 otra vez, se queda en 1).
  El nat-1/nat-20 del ataque se evalúa sobre el dado FINAL (reroll a 20
  = crítico; reroll a 1 = fallo).
- **NO aplica** a death saves (`death_save/2` no recibe personaje) ni a
  tiradas sin d20 de personaje. Monstruos con `race: "halfling"`
  también lo tienen (gratis y correcto: el motor no distingue lado).
  **Cobertura por enumeración**: la suerte vive en las TRES funciones de
  `Rules.Combat` citadas, no en un cuello único — rutas que tiran su
  propio d20 por fuera NO la heredan: los ataques de hechizo
  (`cast_spell` rama `:attack`, que llama `kept_d20` directamente) y las
  salvaciones de muerte quedan fuera; si nace una ruta d20 nueva, hay
  que citarla a mano.
- **Implementación**: helper privado `maybe_lucky(%Character{}, d20,
  roller) -> {die, tag}` usado en los tres sitios. El reroll pasa por
  el MISMO roller → el RollLog group registra ambos dados
  (instrumentación intacta). Las firmas públicas de las tres funciones
  NO cambian: cada una delega en su variante `_tagged` nueva
  (`attack_roll_tagged/5`, `saving_throw_tagged/5`,
  `ability_check_tagged/6`) que devuelve el 4º elemento
  `lucky_tag` (`nil` cuando no fired) — es la que la capa `Actions`
  consume para pintar el desglose.
- **Desglose** (patrón mode_tag/aura_b): etiqueta "(Lucky: 1→N)" justo
  tras el dado en TODOS los mensajes que muestran el d20: ataque
  (single y multi-swing), salvación de hechizo, salvación de
  concentración, chequeo (`check_parts`) y Sigilo de Astucia.
- **Ventaja/desventaja**: Lucky rerollea sólo el dado CONSERVADO: con
  ventaja [1, 20] el 1 descartado NO rerrollea; con desventaja [15, 1]
  el 1 conservado SÍ.

**Fuera**: Brave, Halfling Nimbleness (sin grid/percepción), demás
razas y rasgos raciales, feats, multiclase. M50 en el catálogo.

---

### D67 — Resistencia implacable del semi-orco 5e
Estado: **Aceptada** — 2026-09-14.

Rasgo racial AUTOMÁTICO (D1): al semi-orco (`race == "half-orc"`) que
cae a 0 pg le quedan 1 pg y consciousness — una vez por descanso largo.
Sin tool ni prompt: hook en el cuello único de daño.

- **Campo**: `Character.relentless_endurance_used` (boolean, default
  false; true = gastada). Codec `== true` en ambas direcciones → jsonb
  viejo/ausente decodifica a false (D8).
- **Hook en `World.apply_damage/3`**: si el hp final ≤ 0, raza
  semi-orca y flag en false → `hp = 1`, flag a `true`, y el cambio
  añade nota al log del world: "la furia semi-orca mantiene a X en pie
  con 1 pg (Resistencia implacable)" (la narración la superficie).
- **Orden de capas en `apply_damage/3` (queda fijado aquí)**: Uncanny
  Dodge mitiga el amount de entrada (D64) → resistencias (D38) →
  temp_hp (D36) → hp → auto-revert de Wild Shape (D63, si forma
  bestia) → **Resistencia implacable** (hp 0 → 1) → death-save state
  como siempre. RE corre TRAS el revert: un druida semi-orco cuya
  bestia cae con exceso que dejaría al druida a ≤ 0 lo salva a 1 (ya
  en forma propia). Al salvar a 1 pg el personaje NO cae → no se
  limpian flags de caído (rage/reckless siguen).
- **Recarga**: `long_rest` (`compose_long_rest` →
  `World.set_relentless_endurance/2` a false). `short_rest` NO recarga.
  Si ya está gastada y vuelve a caer → 0 pg con normalidad.
- **Sin tools nuevas, sin allowlist, sin prompts** (pasiva racial; el
  builder ya pone la raza D52). Sin cambios en Weapon/Spell/Item.

**Fuera**: Savage Attacks (daño extra en crit — evaluar otro día),
Darkvision (sin percepción modelada), demás rasgos raciales, feats,
multiclase. M51 en el catálogo.

---

### D68 — Indomitable del guerrero 5e
Estado: **Aceptada** — 2026-09-14.

Rasgo de clase AUTOMÁTICO (D1): el guerrero L9+ (`class == "fighter"`,
`level >= 9`) rerollea una salvación fallida. El agente no llama nada — no
hay tool ni prompt: el motor aplica el reroll tras el fallo, ANTES de
decidir daño/efecto.

- **Campo**: `Character.indomitable_used` (boolean, default false; true =
  gastado). Codec `== true` en ambas direcciones → jsonb viejo/ausente
  decodifica a false (D8). Builder/monstruos lo heredan de
  `Character.new` (default false, patrón D67).
- **Dónde aplica — TODOS los sitios de `Actions` donde el PERSONAJE
  salva** (chokepoints post-Lucky D66): rama `:save` de hechizos
  (`resolve_save_spell`), SAB de `turn_undead` y salvación de
  CON de concentración (`one_hit_concentration`). Si la tirada FINAL
  (tras aura D61 e inspiración bárdica D50, que re-derivan el éxito) es
  FALLO y el guerrero L9+ tiene `indomitable_used == false` → UN reroll:
  la MISMA llamada `Combat.saving_throw_tagged/5` con los MISMOS
  argumentos (mismo modo y bonus; el aura se re-suma), se USA el nuevo
  resultado (RAW, no keep-best) y se marca `indomitable_used = true` vía
  `World.set_indomitable/2` compuesto en el change del sitio.
- **Desglose** (patrón Lucky D66): etiqueta "(Indomitable: X→Y)" (totales
  contra la CD) justo tras el dado; en `turn_undead` va pegada al nombre
  del no-muerto. El reroll pasa por el MISMO roller → el RollLog group
  registra ambos dados.
- **Interacciones fijadas aquí**:
  - El reroll decide el éxito FINAL: Evasión D59/mitad de daño/condiciones
    se evalúan tras él (mecánicamente Evasión es de pícaro y no solapa con
    guerrero, pero el orden queda fijado igual).
  - Modo: Heightened D65 (desventaja), Danger Sense D58 y condiciones
    entraron en la primera tirada → el reroll usa el MISMO modo (misma
    llamada). Lucky D66 puede dispararse EN el reroll si sale 1 (gratis,
    correcto RAW).
  - Inspiración bárdica (D50): el d6 se gastó en el primer intento y NO
    se re-tira en el reroll; el aura D61 (bonus plano) sí se re-suma.
  - Auto-fails (`Conditions.save_mode` → `:auto_fail`) y death saves
    (ruta sin personaje): FUERA — no hay dado que rerrollear.
  - Un solo uso por resolución: el struct actualizado viaja a la
    simulación de concentración (hechizo) y se hilvan los golpes de una
    misma acción (`pipe_damage`), así un segundo save en la misma
    resolución no puede gastar dos veces lo que es 1/descanso largo.
- **Recarga**: `long_rest` (`compose_long_rest` →
  `World.set_indomitable/2` a false, patrón D67). `short_rest` NO.
  Si ya está gastado, el fallo se queda como está.

**Fuera**: usos extra a L13/L17, Indomitable en ability checks o attack
rolls, death saves, feats, multiclase. M52 en el catálogo.

---

### D69 — Savage Attacks del semi-orco 5e
Estado: **Aceptada** — 2026-09-14.

Rasgo racial AUTOMÁTICO (D1): el semi-orco (`race == "half-orc"`) añade UN
dado de arma en el crítico melee. Sin tool ni prompt; sin campos nuevos
(racial); sin rests.

- **Hook en `Combat.damage_roll/4`** (dónde el crítico de ARMA duplica
  dados): atacante semi-orco + `weapon.ranged != true` + outcome `:crit`
  → UN dado del TAMAÑO del arma (`roller.(sides)` — para un 2d6 añade
  1d6, no otra tirada de 2d6; nunca doblado). Nueva variante pública
  `damage_roll_tagged/4` devuelve `{total, savage_die}` para que
  `Actions` pinte el desglose; `damage_roll/4` delega y dropea la
  etiqueta (patrón `*_tagged` D66, firmas intactas).
- **Desglose**: " (+N Savage)" en el swing (patrón " (+N sneak)"), antes
  del sneak; `swing.savage` viaja en el mapa del swing (0 cuando no
  aplica).
- **Aplica a**: golpes melee de `attack/6` (incluido el golpe sin armas
  sintético de Flurry D54 — melee weapon attack RAW) y de
  `action_surge`/`flurry`. **NO aplica** a armas a distancia, hechizos
  (`resolve_spell` no pasa por `damage_roll`), ni golpes no-críticos.
- **Apilable** (RAW): Savage es un dado de ARMA adicional y convive con
  sneak D41 / smite D46 / mark D55 / rage D42 — cada uno suma sus dados
  propios en el mismo swing.

**Fuera**: demás rasgos raciales del semi-orco (Darkvision sin
percepción modelada), feats, multiclase. M53 en el catálogo.

---

### D70 — Aliento de dragón del dragontino 5e
Estado: **Aceptada** — 2026-09-15.

Rasgo racial CON TOOL (patrón turn_undead/second_wind): el dragontino
(`race == "dragonborn"`, cualquier clase/nivel) exhala su aliento sobre
un objetivo. El LLM decide cuándo; el motor resuelve todo.

- **Tool** `breath_weapon(who, target)`: DM cualquiera; PC sólo sí
  mismo (guarda patrón divine_smite). Allowlist PCAgent + línea de
  prompt para dragontino con uso disponible (chequeo por RAZA, no
  clase) + una línea en el prompt del DM.
- **Campo**: `Character.breath_weapon_used` (boolean, default false;
  true = gastado). Codec `== true` en ambas direcciones → jsonb
  viejo/ausente → false (D8). Builder/monstruos lo heredan de
  `Character.new` (patrón D67/D68).
- **Daño**: dado por nivel en `Progression.breath_dice/1` — L1–4 "2d6",
  L5–10 "3d6", L11–16 "4d6", L17+ "5d6". Tipo **"fire" fijo**: no
  modelamos ascendencia dracónica (simplificación documentada aquí; el
  rasgo `breath_weapon` del builder D52 queda como string de ficha).
- **Resolución** (patrón spell :save): salvación de DES del objetivo
  contra CD = `8 + mod CON del dragontino + Ability.proficiency(level)`.
  Éxito → mitad del daño (floor); fallo → daño completo. Pasa por el
  MISMO stack de sitio de salvación que los hechizos: `Conditions.save_mode`
  (Danger Sense D58, auto-fails), Lucky D66, aura D61, inspiración
  bárdica D50, Indomitable D68 (reroll con mismo modo), Evasión D59
  (RAW cubre cualquier efecto de salvación DES con mitad de daño, no
  sólo hechizos) y chequeo de concentración del objetivo si concentra
  (`with_conc_damage`). Roller determinista + RollLog.
- **Combate permitido. 1 uso por descanso**: short Y long recargan
  (`compose_rest`, patrón ki D54 — RAW "regain after a short or long
  rest"). El uso se gasta SIEMPRE que se resuelve (salve o no el
  objetivo: es un área que se lanza).
- **Errores (NO mutan)**: who no existe; who caído; no dragontino; ya
  usado este descanso; target no existe. **Target caído PERMITIDO**
  (el aliento puede golpear a un caído; el daño fletea a 0 pg como
  siempre en `apply_damage`).
- **No es hechizo**: no consume casillas, no fija concentración, no
  interactúa con Metamagic D65, y un dragontino druida en Forma salvaje
  D63 PUEDE usarlo (rasgo racial, no `cast_spell` — RAW).

**Fuera**: elegir ascendencia/tipo de daño (fuego fijo), área de 15
pies/cono (motor single-target), reacción, segundo aliento, Dragon
Fear/Dragon Wings, feats, multiclase. M54 en el catálogo.

---

### D71 — Astucia gnoma 5e
Estado: **Aceptada** — 2026-09-15.

Rasgo racial AUTOMÁTICO (D1): el gnomo (`race == "gnome"`) tiene
ventaja en salvaciones de INT/SAB/CAR contra MAGIA. Sin tool, sin
prompt, sin campos, sin rests.

- **Equivalencia engine (fijada aquí)**: TODA salvación que sale de
  `cast_spell` (rama `:save`) y de `turn_undead` (divina = mágica) es
  "magia". No existen hoy rutas de salvación no mágicas con dado en el
  motor (el aliento D70 salva DES — fuera del alcance mental —, los
  ability checks y death saves no son salvaciones de ability, y la
  concentración es CON). Si algún día entra una salvación no mágica
  mental, el sitio debe NO inyectar la ventaja.
- **Implementación**: en esos dos sitios, si el objetivo es gnomo y la
  ability es `:int/:wis/:cha`, se inyecta `gnome_advantage: true` como
  fuente EXTRA de ventaja en `Conditions.save_mode/4` (firma nueva con
  opts opcionales; `save_mode/3` intacta). `combine/2` la combina:
  con desventaja de condición → normal; con Heightened D65
  (desventaja) → normal. Danger Sense D58 no interactúa (es DES).
- **Turn_undead**: la inyección está (contrato), pero hoy es
  inalcanzable en la práctica — el objetivo de Expulsar no-muertos
  exige `race == "undead"` y la raza es un campo único, así que ningún
  gnomo puede ser expulsado. Queda por simetría del contrato.
- **Etiqueta**: "(Astucia gnoma: ventaja)" en el desglose del hechizo
  cuando la ventaja del gnomo drove el modo (patrón tags D65/D66). Si
  se cancela (Heightened/condición → normal), no hay etiqueta — el
  modo final es normal y así se lee.
- **NO aplica a**: ability checks, death saves, concentración (CON —
  fuera del alcance mental, correcto RAW), salvaciones DES/CON/FUE.
- **Indomitable D68**: el reroll usa el MISMO modo → la ventaja gnoma
  se mantiene en el reroll (automático: la ventaja entró en
  `save_mode` antes del primer intento).

**Fuera**: demás rasgos raciales del gnomo (Darkvision, Gnome
Cunning no modela salvaciones no mágicas porque no existen), feats,
multiclase. M55 en el catálogo.

---

### D72 — Usos de Furia y Furia implacable 5e del bárbaro
Estado: **Aceptada** — 2026-09-15.

Cierra el hueco de economía de recursos del bárbaro: `start_rage` no
gastaba nada (furias infinitas al día) mientras el motor sí limitaba
ki/sorcery/breath. Furia implacable (L11) encaja en el hook de 0 pg
donde ya viven Resistencia implacable (D67) y el auto-revert (D63).
Sin tools nuevas ni prompts.

- **Usos de Furia**: campo `Character.rage_uses_used` (integer, default
  0; Codec tolerante a jsonb viejo, patrón D67/D68). Máximo por nivel en
  `Progression.rage_count/1` (tabla 5e): L1–2 → 2; L3–5 → 3; L6–11 → 4;
  L12–16 → 5; L17+ → 6. La validación de clase vive en `start_rage/1`
  (patrón `rage_damage/1`: la tabla es del bárbaro, no-bárbaro ni
  entra). `World.start_rage/1` exige `rage_uses_used < rage_count(level)`
  (error "no le quedan furias hoy (N/N usadas)" SIN mutar) y **gasta el
  uso al entrar** (incrementa 1); `end_rage/1` NO lo devuelve (RAW:
  gastado al entrar, aunque la furia se apague a los 0 pg o con
  `end_combat`). Ya raging → idempotente-OK sin gasto extra (comportamiento
  previo intacto). Sólo `long_rest` recarga (`compose_long_rest` →
  `set_rage_uses_used(name, 0)`); `short_rest` no.
- **Furia implacable (L11+)**: campo `Character.relentless_rage_successes`
  (integer, default 0; Codec tolerante). Hook en `World.apply_damage/4`
  en el punto de 0 pg, ANTES de la RE racial (D67). Si `class ==
  "barbarian"`, `level >= 11`, `raging == true` y hp final ≤ 0 →
  salvación CON contra CD `10 + 5 × successes`. Éxito → `hp = 1`,
  incrementa `successes` (el siguiente intento es más difícil), nota
  "la furia mantiene a X en pie con 1 pg (Furia implacable: salvación
  CON d20 N: total vs CD M)". Fallo → nota de fallo y cae al siguiente
  check (RE racial D67 si aplica: semi-orco bárbaro = ambas capas; un
  éxito de Furia implacable NO consume la RE ese golpe — el hp queda en
  1, no en 0). Long rest resetea `successes` a 0. Al quedar a 0 la furia
  se apaga (`clear_drop_flags`, orden hook→conditions intacto).
- **Orden de capas de daño (fijado aquí)**: Uncanny Dodge D64 mitiga el
  amount → resist D38 → temp_hp D36 → hp → revert Wild Shape D63 →
  **Furia implacable (clase, salvación)** → **Resistencia implacable
  (racial, hp 0 → 1)** → death saves.
- **Tirada**: sale de `Rules.Combat.saving_throw/5` (prof de CON de la
  ficha + Lucky D66 aplican — trivial porque `Combat` sólo consume el
  `Character`, no hay dependencia circular) con el roller determinista
  hilvanado: `apply_damage` gana un 4º parámetro opcional `roller`
  (default `&Dice.roll/1`) y `Actions.pipe_damage` pasa el suyo, así el
  save comparte el roller de la acción. **Simplificación documentada**:
  no hay RollLog a esa profundidad (la change-fn sólo ve el world), así
  que la nota en el log del world ES el registro de la tirada. Lucky
  funciona; Indomitable NO aplica (guerrero-only, multiclase fuera).
- **Aura de Protección (D61) suma** (es CON pero RAW el aura cubre TODAS
  las salvaciones): el helper `aura_save_bonus/2` pasó de privado en
  `Actions` a público en `World` (misma firma; `Actions` delega), así el
  hook usa el MISMO bonus plano que el resto de sitios de salvación.
- **Errores (NO mutan)**: personaje inexistente; no-bárbaro (mensaje
  existente); sin furias disponibles.

**Fuera**: duración de la furia (sin reloj de 1 minuto — D42), rage
como bonus action (economía de acciones), Path features, Persistent
Rage (L20 — sin duración no aplica), feats, multiclase. M56 en el
catálogo.

---

### D73 — Expertise 5e de pícaro y bardo
Estado: **Aceptada** — 2026-09-15.

Cierra el último hueco del subsistema de skills (D60 aplicó prof
simple y JoaT): Expertise duplica el bonus de competencia en skills
elegidas (pícaro L1, bardo L3).

- **Tool en vez de builder**: la elección NO vive en el flujo de UI del
  draft de nivel 1 ni en la subida de nivel — se modela como TOOL
  elegida una vez (`gain_expertise(who, skill)`), el mismo patrón que
  todas las features del motor: el LLM decide, el motor valida y
  persiste (D1). La tool cubre cualquier momento una vez elegible
  (creación, tras subir de nivel, en partida) — nada de integración con
  level-up.
- **Campo**: `Character.expertise`, array de strings (skills), default
  `[]`; Codec tolerante a jsonb viejo/ausente (patrón arrays). Siempre
  un subconjunto de `skill_proficiencies` (el motor lo exige).
- **Cupo por clase y nivel** — `Progression.expertise_count/2` (tabla
  5e-2014): rogue L1+ → 2, L6+ → 4; bard L3+ → 2, L10+ → 4; demás
  clases → 0. La tabla vive en `Progression` (fuente de verdad, patrón
  `rage_count/1`).
- **Tool `gain_expertise(who, skill)`** (DM cualquiera; PC sólo sí
  mismo, guard patrón divine_smite). `skill` normalizado vía
  `Rules.Skills` (D60: "Animal Handling"/"animal-handling" →
  `animal_handling`). Errores (NO mutan), en orden: who no existe; who
  caído; clase sin Expertise ("sólo pícaros y bardos"); nivel
  insuficiente para el PRIMER cupo (bardo L1–2: "llega a nivel 3");
  skill desconocida (error directivo con ejemplos); skill NO está en
  `skill_proficiencies` ("no tienes competencia en X"); skill ya en
  `expertise`; cupo agotado ("ya has elegido tus N expertises" con el
  cupo actual por nivel y la lista elegida). Éxito: añade la skill y
  mensaje ES "X profundiza su dominio de Sigilo (Expertise 1/2).".
  Mutador `World.add_expertise/2` (sin validación — la vive Actions).
- **Resolución (doble prof)**: `Combat.check_proficiency/3` gana un 3er
  parámetro opcional `skill` (default nil) y una 4ª.kind `:expert` —
  entrenado + expertised → `prof × 2`; `ability_check/7` y
  `ability_check_tagged/7` lo hilvan (firmas compatibles con defaults).
  Lo consumen las DOS rutas de checks con skill: `Actions.check`
  (desglose "prof 4 (experto)") y `cunning_action_hide` (D57: Sigilo
  doblado, desglose "+4 (experto)"). JoaT NUNCA aplica a una
  expertised (ya es competente — la cond-order lo garantiza). NO
  aplica a ability cruda sin skill ni a checks de bardo sin skill
  nombrada; `passive_perception` fuera (las DC de hide no cambian).
- **Sin rests** (elección permanente), **sin prompts** salvo: allowlist
  PCAgent + una línea condicional pícaro/bardo (sólo si class/level
  dan cupo > elegidos) + una línea en el prompt del DM.
- **Sin cambios** en Weapon/Spell/Item; campo nuevo sólo `expertise`.

**Fuera**: Expertise en tools/instrumentos, picks extra de reglas 2024,
integración con las choices de level-up (la tool cubre el momento),
feats, multiclase. M57 en el catálogo.

### D74 — Upcasting 5e RAW con tabla curada de escalado
Estado: **Aceptada** — 2026-09-15.

`cast_spell` gana `cast_level` opcional (nil = nivel base, compat hacia
atrás): lanzar un hechizo con una casilla superior aplica el escalado
EXACTO de cada hechizo (RAW 2014) desde una tabla curada EN CÓDIGO, y
consume UNA casilla del nivel pedido (M58).

- **Tabla curada en `Rules.Upcast`** (no en `Actions`): es datos de
  reglas, no orquestación (D1 — el motor es fuente de verdad), y evita
  inflar `Actions` con tablas estáticas. El JSON del SRD NO trae el
  bloque "A niveles superiores" estructurado, así que cada entrada se
  auditó contra la descripción RAW 2014. Helper público
  `extra_dice(spell, base, cast_level) -> "2d6" | nil` +
  `scaled_spell/2` (combina base+extra en UNA expresión de dados).
  Hechizos ausentes de la tabla no escalan (comportamiento previo).
- **Tabla**: burning_hands +1d6/nivel s/1º; thunderwave +1d8/n s/1º;
  shatter +1d8/n s/2º; fireball +1d6/n s/3º; lightning_bolt +1d6/n
  s/3º; blight +1d8/n s/4º; flame_strike +1d6/n s/5º; vampiric_touch
  +1d6/n s/3º; spiritual_weapon +1d8 cada DOS niveles s/2º (3º/5º no
  añaden); magic_missile +1 dardo (+1d4+1)/nivel s/1º; cure_wounds
  +1d8/n s/1º; healing_word +1d4/n s/1º; prayer_of_healing +1d8/n
  s/2º.
  - **Erratas del borrador del spec, resueltas hacia RAW**: (1) magic
    missile "3º = 4 dardos" era off-by-one — RAW es +1 dardo/nivel
    sobre los 3 base: 2º = 4, 3º = 5; (2) vampiric_touch NO es "cada
    dos niveles": RAW 2014 es +1d6 por cada nivel de casilla sobre 3º
    (4º = 4d6, 5º = 5d6…). Verificados contra el texto PHB/SRD.
- **Reglas de escalado**: el dado extra se combina con la expresión
  base (`"8d6"+"1d6" → "9d6"`) ANTES de resolver, de modo que entra al
  mismo RollLog (misma etiqueta, total combinado), la mitad en :save se
  calcula sobre el TOTAL escalado, el crit (:attack) dobla también los
  extra (el motor ya dobla la base), y Empowered (D65) boostea los
  dados combinados de forma natural. CD de salvación y concentración
  SIN cambios (RAW). flame_strike: RAW añade +1d6 fuego Y +1d6
  radiante; el motor modela 4d6 fuego único → escala +1d6 al total
  (simplificación documentada).
- **Validaciones (errores NO mutan)**: las existentes; cast_level
  entero entre `spell.level` y 9 (menor que la base → error claro; > 9
  → error; no entero → error directivo — la tool coacciona strings
  numéricos del modelo); trucos no se pueden lanzar a nivel superior;
  `World.has_slot?(who, cast_level)` con mensaje que cita el nivel
  PEDIDO. Éxito: `compose_slot_consumption` con cast_level (warlocks
  siguen gastando su casilla de pacto vía `slot_level_for`, RAW).
- **Mensaje ES**: "(nivel N)" justo tras el nombre del hechizo cuando
  cast_level > base ("Lyra conjura fireball (nivel 4); …"), cubre todas
  las ramas (save/attack/automatic/heal/utility) y el outer de
  Twinned. Magic missile reporta el número REAL de dardos (del conteo
  de dados: 4d4+4 → "4 dardos de fuerza").
- **PCAgent**: una línea tras la de conjurar explicando cast_level con
  ejemplos cortos. Guards DM/PC sin cambios.

**Fuera**: tabla completa de los 319 (sólo la curada), escalados
multi-objetivo ("+1 objetivo": hold_person, invisibility…), multi-rayo
(scorching_ray), variantes 2024, feats, multiclase.

**Excluidos de la tabla (verificados contra el JSON del SRD)**:
`heal` (70 pg planos, sin dados en el motor — el escalado +10 pg/nivel
quedaría sobre un efecto no resuelto con dados); `mass_cure_wounds`
(SRD `dice: null` → el motor no lo resuelve con dados reales);
`sleep` (el motor lo modela como curación automática de 5d8 al
objetivo, no como pool de pg — escalar eso amplificaría un
mal-modelo; la descripción del JSON además no trae el bloque de
escalado); escalados de DURACIÓN o no-dados (shield of faith y
compañía no escalan: consumen la casilla pedida sin dados extra).

---

### D75 — Araña gigante: primera fuente real de daño de veneno
Estado: **Aceptada** — 2026-09-15.

Hasta hoy NADA en el motor hacía daño de veneno (ningún arma de
bestiario ni hechizo del catálogo usaba "poison"), así que cualquier
resistencia al veneno habría sido dead code. Se añade la bestia
venenosa clásica (giant spider, CR 1) al bestiario — con ella la
Resistencia enana (D76) y las inmunidades existentes (skeleton, D38)
tienen contraparte medible. Sin campos, sin tools, sin mecánica nueva.

- **Builder**: `Monsters.giant_spider/1` (opts `name`/`backstory` como
  los demás), key `"giant_spider"` en `Monsters.catalog/0`, raza
  "beast", side "enemy", stats RAW CR 1: STR 15, DEX 16, CON 12,
  INT 2, WIS 12, CHA 7; CA 14; 26 pg; velocidad 30; salvación DES.
  Añadida a las enumeraciones de `spawn_monster` (prompt DM,
  guardrails y escenario arena) para que sea descubrible.
- **Mordida venenosa**: arma `bite`, dados `"3d8"`, `attack_ability:
  :dex`, melee. El TOTAL queda en "3d8+3 poison" porque el motor suma
  el mod de aptitud (DES +3) sobre dados de arma `NdM` — los dados de
  arma NO aceptan modificador plano (`Combat.parse_dice` solo parsea
  `NdM`; escribir "3d8+3" en `dice` haría crash en `damage_roll`, como
  el `bear_bite` latente). DEX también da el +5 al ataque RAW
  (prof 2 + 3). **Simplificación documentada**: RAW es 1d8+3
  perforante MÁS 2d8 veneno (salvación CON CD 11 para mitad); el motor
  modela UN tipo de daño por arma → se combina en un solo total
  "3d8+3 poison" (equivalente numérico aproximado) SIN la salvación
  CON intermedia.
- **Fuera**: telaraña (Web), trepar paredes (sin posicionamiento),
  poison de otros tipos, más armas/traits, entrar en Wild Shape
  (CR 1 > tope 1/2 de D63). M59 en el catálogo.

### D76 — Resistencia enana (Dwarven Resilience)
Estado: **Aceptada** — 2026-09-15.

El rasgo racial del enano 5e, en sus dos mitades RAW, sin campo nuevo
(se deriva de `race == "dwarf"`), sin tools, sin prompts, sin rests.

- **Resistencia al daño de veneno**: un enano recibe la MITAD (floor)
  del daño `type == "poison"`. Vive en la capa D38
  (`Character.incoming_damage/3` → `resistant_to?/2`, mismo sitio que
  la resistencia infernal del tieflino), que `World.apply_damage/3-4`
  aplica en su pipeline — NO como capa ad-hoc en World, para que las
  simulaciones que también consultan `incoming_damage` (DC de
  concentración `max(10, daño/2)`, tracking multi-golpe de
  `resolve_swings`) queden coherentes con la mutación real del world.
- **Orden de capas (fijado, actualiza el comentario del pipeline)**:
  Uncanny Dodge D64 (mitiga cualquier amount, primero) → resistencias
  D38 incluida la enana de veneno (mitiga poison) → temp_hp D36 →
  hp → auto-revert Wild Shape D63 → Furia implacable D72 →
  Resistencia implacable D67 → death saves. Dodge y resistencia se
  apilan multiplicativamente (un enano pícaro: mitad × mitad = cuarto,
  RAW correcto; `floor(floor(d/2)/2)`).
- **Ventaja en salvaciones contra veneno**: en la rama :save de
  `cast_spell`, si `spell.damage_type == "poison"` y el objetivo es
  enano → fuente extra de ventaja `dwarf_advantage:` en
  `Conditions.save_mode/4` (patrón gnome_advantage D71: `combine/2`
  la cancela contra Heightened D65 o desventaja de condición;
  etiqueta "(Resistencia enana: ventaja)" cuando condujo el modo; el
  reroll de Indomitable D68 conserva el modo). Aplica a CUALQUIER
  aptitud de salvación (RAW 2014: "saving throws against poison").
- **Nota de cobertura**: el catálogo tiene exactamente UN hechizo así
  hoy (cloudkill del SRD: CON, 5d8 poison, nivel 5) — el hook es
  correcto y futuro-prueba; los tests lo ejercitan con un fixture con
  esos mismos datos.
- **Fuera**: demás traits enanos (darkvision, speed, dwarven combat
  training, stonecunning), veneno de otros tipos, INMUNIDAD (no
  resistencia) de no-muertos, feats, multiclase. M60 en el catálogo.

### D77 — Auditoría y pulido del lote D35–D76
Estado: **Aceptada** — 2026-09-15.

Auditoría de CALIDAD del lote D35–D76 (no añade features): revisión de
los ~34 archivos de test del lote (comportamiento vs internals, rollers
deterministas con números exactos), verificación de los invariantes de
arquitectura (D6/D31), y consolidación de duplicación. Informe completo
en [`tecnico/10-auditoria-motor.md`](tecnico/10-auditoria-motor.md).

- **Gramática de dados única**: la regex `NdM±K` vivía replicada en
  `Dice.roll_expr`, `Dice.valid?`, `Rules.Upcast.parse` (privado) y
  `Actions.parse_dice_expr` (privado). Entra `Dice.parse_expr/1`
  público (`{count, sides, mod}`) como ÚNICO parser; `roll_expr`/`valid?`
  lo reusan vía el atributo `@dice_expr`, y `Rules.Upcast`/`Actions`
  delegan (las copias se eliminan). `Rules.Combat.parse_dice` (sólo
  `NdM`, error propio) NO se toca: su estrechez es deliberada (D75 —
  los dados de arma no aceptan modificador plano). Decisión: la casa del
  parser es `Dice`, no un `Rules.*`, porque ahí ya vivía la gramática
  que `roll_expr`/`valid?` usaban.
- **Tests de gaps ADR**: se añaden 11 tests de interacciones DECLARADAS
  en ADRs pero sin cobertura directa: aliento D70 × (concentración del
  objetivo, Danger Sense, Lucky, inspiración, aura, Indomitable);
  Evasión × inspiración (D59×D50); Indomitable × aura re-sumada (D68×D61);
  upcast × casilla de pacto del brujo (D74×D40); upcast × Twinned y
  upcast × Empowered con dados combinados (D74×D65).
- Cero cambios de comportamiento: suite 1500 → 1511 passed, mismos 3
  excluded (integración live). Contadores de docs realineados
  (AGENTS.md, progress, plan-fases, estrategia-pruebas).

### D78 — Combatir a los caídos: auto-crítico vs incapacitados y death-fails por daño a 0 pg
Estado: **Aceptada** — 2026-09-15.

Alineación RAW del cierre del lote D35–D77 (FIX-1): dos reglas 5e que el
motor omitía.

- **Auto-crítico vs incapacitados** (RAW "any attack that hits... within
  5 feet"): un golpe melee que ACIERTA contra un objetivo con condición
  `paralyzed` o `unconscious` sale `:crit` (dados doblados por el camino
  existente de `Combat.damage_roll_tagged`). La ventaja que esas
  condiciones ya otorgaban (`Conditions.attack_mode`, M06) se conserva;
  los ataques a distancia y los fallos NUNCA se promocionan. **Proxy de
  adyacencia**: el motor no tiene posicionamiento, así que "within 5
  feet" se interpreta como arma melee (`weapon.ranged != true`) —
  documentado como simplificación. Los ataques de hechizo NO siguen
  esta vía (la rama `:attack` de `cast_spell` tira su propio d20).
  Implementado en `Actions.resolve_one_swing` vía
  `auto_crit_vs_incapacitated/3`.
- **Death-fails por daño a 0 pg** (RAW): un personaje que ya está a 0 pg
  registra 1 fallo de salvación de muerte por golpe con daño restante >
  0 tras capas, 2 si el golpe fue crítico (`opts[:crit]` de
  `World.apply_damage/5`). El daño que te BAJA a 0 NO registra (sólo el
  recibido MIENTRAS estás a 0); el orden de capas D67 se respeta
  (Relentless Rage/Endurance dejan a 1 pg y no registran nada); massive
  damage instantáneo queda FUERA (deuda declarada); al 3er fallo el
  personaje muere por la vía existente (`World.dead?/2`). Un muerto no
  acumula más fallos.
- **Se puede atacar a un caído**: `resolve_swings` ya no corta los
  golpes de una acción cuyo objetivo EMPEZÓ a 0 pg (cada golpe registra
  su fallo); si el objetivo cae a mitad de la acción, los golpes
  restantes siguen saltándose (sin retarget, D35). El pipe de daño
  acepta `{cantidad, opts}` por golpe: el smite del MISMO golpe no
  doble-registra (`death_fail: false`); hechizos y demás callers van con
  opts por defecto.
- **Sin campos nuevos** en `Character`/`Weapon`/`Spell`/`Item` (D4): el
  tracker `death_saves` existente acumula. Nota al log del world por
  registro ("recibe daño estando caído") para que la narración lo
  muestre. Tests: `world_test.exs` (capas y muerte), `actions_test.exs`
  (atacar a un caído, secuencia hasta la muerte, Extra Attack vs
  caído), `conditions_test.exs` (auto-crítico melee/ranged/fallo).

---

### D79 — Tope de pasos del TurnMaster y evidencia en el fallo del beat
Estado: **Aceptada** — 2026-09-16 (ampliada el mismo día: terminación por captura).

Hallazgo de playtest (game 10053): el segundo beat del TurnMaster con LLM real
loopeó hasta el `max_steps: 50` por defecto de `ExAgent.new` (~50 s de stall +
~50 llamadas quemadas) antes de que el fallback WorldDriven recuperara la
partida. Un TM sano decide en UN tool-call; 50 pasos no tienen sentido para
ese agente.

- **Cap por defecto**: `TurnMaster.new/2` pasa `max_steps: 3` a `ExAgent.new`
  (una decisión + un reintento + margen), sobreescribible por opts. NO se
  toca el default de exAgent ni el de DM/PCAgent — ellos sí necesitan margen
  para tool-loops de combate (resolución + narración + compaction).
  El bucle offline nunca lo vio porque TestModel responde con label fijo.
- **Evidencia sin store**: el error `{:max_steps_exceeded, n}` de exAgent no
  arrastra las steps falladas y el store muere con el proceso. Canal que SÍ
  expone exAgent: los RunEvents por PubSub (`Server` arrancado con
  `pubsub: :local`). El beat Task del TM se suscribe al topic del agente
  (`Bootstrap.turnmaster_agent_id/1`), y al fallar el beat el warning del
  Game incluye las últimas 5 `tool_call_started` (tool + args). Sin tocar
  exAgent.
- **Normalización canónica del target**: las tools del TM aceptan
  case-insensitive + trim (`"thane"`, `" thane "` → `"Thane"`) y graban el
  nombre canónico del roster en la decisión, para que `Session.handoff/2`
  reciba un id real y no un near-miss que caería al fallback. `"dm"` sigue
  siendo siempre válido; los no-participantes se siguen rechazando.

**Ampliación — la primera decisión válida es terminal (terminación por
captura)**. Segundo playtest (game 10790): con el cap a 3 el TM ya no loopea
50 pasos, pero cada beat sano aún quemaba 3 llamadas y ~20-30 s antes de caer
al fallback: el modelo acertaba la tool en el paso 1 y seguía emitiendo
tools porque el prompt ("UNA tool… sin texto libre") peleaba con la
terminación del runtime (exAgent sólo finaliza con texto final). El fix:

- **Captura temprana** (`Beats.run_turnmaster_beat/4`): `Server.chat` corre en
  una task anidada y el beat consume los RunEvents del run en vivo. La
  PRIMERA `tool_call_finished` con éxito de una tool de decisión
  (`give_turn_to`/`cut_in`/`react`/`pass_to_dm`/`end_scene`) con decisión
  grabada en el recorder cierra el beat: la decisión se aplica por el camino
  de siempre (el Game lee el `Decision` recorder; single-writer D6 intacto).
- **Cancelación con gracia**: tras capturar, el beat espera hasta 100 ms a
  que el run concluya solo — un run rápido (scripted/offline) termina en
  microsegundos y su modelo final (posición de script del TestModel) e
  history se integran limpiamente en el Server; un LLM live que loopea pasa
  de la ventana y se cancela con `Server.abort/1` (mecanismo limpio del
  Server: mata la task del run, no integra nada, idempotente si ya acabó).
  Con la decisión en la mano, cualquier conclusión posterior del chat
  (éxito, error propio o `:aborted`) da igual: el beat settlea con esa
  decisión.
- **Contrato de prompt**: la regla 1 del system_prompt ahora exige que tras
  la tool-call el modelo responda el texto exacto «listo» — un modelo
  obediente termina el run solo en 2 pasos con history limpio; uno que no
  (el caso playtest) lo rescata la captura.
- **`max_steps: 3` se queda** como red de seguridad: las tools inválidas
  (target inexistente) no graban decisión, no hay captura, y el run sigue
  quemando su presupuesto hasta el warning con evidencia + WorldDriven
  (comportamiento pre-captura, intacto).

Tests: `turn_master_test.exs` (cap, override, normalización, fallo a
exactamente 3 pasos con contador de llamadas), `turn_master_loop_test.exs`
(modelo que loopea tools válidas → éxito con la primera decisión, sin warning
ni fallback; sólo tools inválidas → warning con evidencia y la partida sigue
vía WorldDriven; tool válida + «listo» → camino corto clásico).

---

## Pendientes de decisión (abiertas)

- **Coordinación real entre PCs auto**: cubierta por **TurnMaster (D25,
  Implementada)**. Validar en partida live que el ritmo y la equidad se
  sostienen; si no, ajustar prompt/brief del TurnMaster (no volver al
  round-robin como camino principal).
