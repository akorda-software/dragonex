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
**Sustituida por D228 para beats de actor** (el TurnMaster conserva su disyuntor).
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

> Vigencia del permiso: D197 reserva la tool directa grant_temp_hp al DM.
> El PC usa su hechizo/capacidad con fuente y coste validados por Rules.
> World.apply_temp_hp, absorción, no stacking y False Life permanecen.

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

### D80 — Precondiciones deterministas de actuación y ciclo de vida
Estado: **Aceptada** — 2026-09-16.

La revisión del motor reproduce acciones estando incapacitado, autocuración
a 0 PG, resurrección por curación ordinaria, descanso que resta PG y gasto de
Manos impositoras con una reserva ya agotada. Algunos tests anteriores
codificaban estos errores como comportamiento válido.

- `World.validate_actor/2` rechaza actores inexistentes, muertos, a 0 PG o
  con `incapacitated`, `stunned`, `paralyzed`, `petrified`, `unconscious`.
  `Actions` lo aplica a sus 18 entradas de acciones/bonus/reacciones antes
  de tirar y dentro del cambio devuelto, contra el mundo que lo recibe.
  Esta precondición común tiene prioridad sobre las validaciones específicas
  anteriores. No se aplica a salvaciones de muerte ni a recibir curación:
  son casos distintos de actuar voluntariamente.
- Los comandos directos `World.start_rage`, `start_reckless`, `start_smite`,
  `second_wind` y `lay_on_hands` también validan al actor. Los setters de
  bajo nivel siguen siendo primitivas para componer transiciones del motor.
- `World.heal` rechaza muertos y cantidades negativas/no enteras; las
  tiradas de curación y de descanso corto tienen mínimo 0. No existe una
  excepción implícita de resurrección por narración.
- `World.apply_death_save` valida que el personaje siga caído, vivo e
  inestable al aplicar el resultado. La estabilización conserva el sentinel
  persistido `successes: 3`, borra fallos y elimina ese sentinel al recibir
  daño que registre nuevos fallos (incluyendo partidas antiguas).
- Relentless Rage/Endurance solo sustituyen una caída real desde PG
  positivos; daño cero o daño a alguien ya caído no lo levanta. La caída
  efectiva a 0 borra concentración en `World`, también por la ruta directa.
- Manos impositoras revalida la reserva al aplicar el cambio; no cura
  gratis si la reserva cambió desde la preparación.

Esto corrige D45/D49 allí donde se permitía la autocuración estando caído.
No cambia structs ni Codec. No introduce economía completa de acciones,
resurrección, muerte instantánea por daño masivo ni seguimiento del tiempo.
La auditoría pendiente y sus límites están en `tecnico/10-auditoria-motor.md`.

Pruebas: `engine_lifecycle_test.exs`, `action_incapacitation_test.exs`,
`stabilization_test.exs`, más las suites existentes de las mecánicas afectadas.

---

### D81 — Daño canónico, resolución única y aplicación sin repetir dados
Estado: **Aceptada** — 2026-09-16.

`World.apply_damage` resuelve las capas de daño, supervivencia y concentración.
`Dragonex.Damage.prepare` usa esa misma ruta para preparar el resultado de una
acción. Devuelve una transición de ficha y notas; aplicarla no vuelve a tirar.
Comprueba los campos del objetivo de los que dependía el cálculo y rechaza
resultados obsoletos. El World solo se modifica al aplicar la change-fn.

Revisión 2026-09-26: las dependencias incluyen `inspired` e
`indomitable_used`. Para hechizos con salvación y aliento se conserva también
la ficha anterior a esa salvación: la concentración usa los recursos ya
consumidos por ella, pero la aplicación valida contra la ficha original.
Así se distingue el consumo dentro de la misma acción de un cambio externo
que invalida el resultado preparado. Dos regresiones de consumo externo en
`damage_pipeline_test.exs`.

`Actions.resolve_swings` intercala ataque → daño completo → concentración antes
del siguiente golpe. Desaparecen las simulaciones parciales de PG que omitían
PG temporales, Esquiva asombrosa, Forma salvaje y Resistencia implacable.
Arma y Castigo divino son componentes tipados de un mismo impacto: conservan
sus resistencias, pero producen una única salvación de concentración y una
única contabilización de fallos de muerte. La CD usa daño mitigado, incluso
si fue absorbido por PG temporales. El orden de las tiradas es ahora el orden
real de los impactos. Una inspiración gastada en la salvación del hechizo no
se vuelve a gastar en concentración.

Se conserva el alcance de las mecánicas previas (p. ej. proxy melee de distancia,
postura de Esquiva asombrosa de D64, sin muerte masiva). Unificar el pipeline
no equivale a implementar todo el SRD. Tests: `damage_pipeline_test.exs` más
concentración, smite, furia, rasgos raciales y Forma salvaje.

### D82 — Presupuesto persistido de acciones y turnos personales
Estado: **Aceptada** — 2026-09-16.

En combate, `TurnBudget` controla una acción, una bonus y una reacción. Ataque
Extra forma parte de UNA acción. Action Surge conserva su comando de ataque
adicional sin devolver la acción ordinaria. Flurry exige Attack y usa bonus.
Second Wind, inspiración, marca, ocultarse y conversiones de hechicería usan
bonus; acciones de clase y aliento usan action. Los chequeos activos usan una
acción; las salvaciones defensivas no. Death save tiene cupo propio de uno por
turno y un 20 natural permite actuar después.

Los hechizos usan `casting_time` del catálogo SRD. La regla de bonus spell se
comprueba en ambos órdenes y se limita al turno GLOBAL en curso (no impide
una reacción en el turno posterior de otro combatiente). Lanzamientos largos
se rechazan en combate: no se ejecutan instantáneamente. Custom sin metadatos
de tiempo conserva la convención de una acción.

`World.set_current_combatant(name, "main" | "reaction")` diferencia turno
propio de interrupción. Solo un nuevo turno propio renueva cupos; cambiar el
floor, repetir handoff o entrar en una reacción no los renueva. El fin del
turno pierde las acciones no utilizadas. Ataque furtivo registra el turno
global usado. Furia termina al final de un turno inactivo si no hubo ataque
hostil ni daño desde el anterior (excepción Persistent Rage L15+).

Las entradas validan antes de tirar y al aplicar. Cambios de turno/tiempo,
recursos del actor o presupuestos desde la preparación exigen resolver otra
vez. `World` revalida también sus comandos directos de furia, smite, Second
Wind, Lay on Hands y death saves. Los setters administrativos son primitivas,
no acciones de personaje. Fuera de combate no se inventan turnos de exploración.

Se añaden al World (y Codec) `turn_state`, `turn_kind`, `turn_owner`, con claves
JSON string. No cambia Character/Weapon/Spell/Item. El único ajuste del bucle
es etiquetar sus mini-handoffs como reacciones; no cambia exAgent.
Tests: `turn_budget_test.exs` y suite de bucle existente.

### D83 — Reloj explícito, dados de golpe finitos y caducidades
Estado: **Aceptada** — 2026-09-16.

`World.elapsed_seconds` avanza solo por operaciones deterministas: ronda = 6 s,
short rest = 3600 s, long rest = 28800 s y `advance_time` explícito fuera de
combate. No usa reloj real ni temporizadores de procesos. `rest_party` aplica
la recuperación de todos en un único intervalo, de forma atómica.

`rest_state` guarda dados de golpe gastados por personaje y comienzo del último
long rest. Short rest permite elegir 0..disponibles; omitir el número gasta
como máximo uno. Cada dado cura `max(0, dado + CON)`. Aun sin dados recupera
rasgos de short rest. Long rest cura, recupera hasta `max(1, floor(level/2))`
dados, borra PG temporales y se limita a una vez cada 24 h. Una subida de nivel
aumenta el máximo sin borrar dados gastados. Furia implacable recupera su CD en
AMBOS descansos (corrige D72); Font of Inspiration del bardo L5+ recarga en corto.

`WorldClock` persiste plazos en `effect_expiries`: concentración con duración SRD,
marca 1 h, furia 1 min, inspiración 10 min, Forma salvaje floor(level/2) horas,
PG temporales de False Life 1 h y condiciones con duración explícita vía
`apply_condition/3`. Expulsar no-muertos usa 60 s para su frightened modelado.
Reaplicar concentración renueva su plazo; sustituir PG temporales no hereda el
plazo de la fuente anterior. Las formas expiran antes de calcular los dados
gastados al finalizar un descanso. No se eliminan a ciegas venenos/maldiciones
sin duración conocida ni se inventa una duración para contenido custom.

Compatibilidad: jsonb anterior recibe cupos/dados inicialmente disponibles (no
hay información histórica para reconstruir gastos), tiempo 0 y duración máxima
desde la carga para efectos activos con duración conocida. Los snapshots nuevos
conservan tiempos y gastos exactos. Los campos son World+Codec, sin migración DB.

Tools: `short_rest` gana `hit_dice` opcional; `advance_time` y `rest_party` son
solo DM. Se conservan las entradas de descanso individual. La finalización
representa un descanso sin interrupciones; no simula encuentros durante él.
Tests: `rest_clock_test.exs`, `flows/rest_clock_test.exs` (TestModel), Codec.

### D84 — Identidad visual "crónica de mazmorra en 16 bits"
Estado: **Aceptada** — 2026-09-26.

La UI deja de ser CSS inline por página y pasa a un sistema único en
`priv/static/assets/dragonex.css` (tokens, ventanas, botones, formularios,
páginas), `game.css` (mesa, sala de espera, modales) y `wizard.css`
(asistentes). Ninguna LiveView lleva `<style>` propio.

- **Concepto**: la app es una mazmorra a la luz de antorchas (fondo de ladrillo
  pixelado + halo animado) y cada panel es una ventana de RPG de 16 bits: borde
  de color + anillo oscuro con esquinas recortadas (4 `box-shadow` desplazadas
  un píxel) + sombra dura. Las opciones elegidas se marcan con el cursor ▶ de
  menú de RPG.
- **La crónica**: el log de la mesa es un pergamino (tinta sobre papel) con
  capitular iluminada al abrir cada turno y las tiradas como resguardos de
  tinta. Es la pieza que da identidad; el resto es sobrio a propósito.
- **Tipografía**: Jacquarda Bastarda 9 (blackletter pixelada, solo títulos),
  Alegreya (prosa/narración), Departure Mono (UI y números). Se probó Pixelify
  Sans y se descartó: por debajo de ~18px la «C» se cierra en «O» y el «5» se
  lee «S» — inaceptable para PG/CA. Fuentes autoalojadas (OFL, subset latin)
  en `priv/static/assets/fonts/`, sin CDN en runtime.
- **Sprites**: pixel-art propio generado desde mapas ASCII por
  `scripts/gen_pixel_sprites.py` → `priv/static/assets/sprites/*.svg`
  (`crispEdges`, escalan sin blur). Sustituyen a los emojis de la UI. Se usan
  con `<i class="px px-<nombre>">`; los animados (antorcha, dragón, fuego) son
  tiras de frames recorridas con `steps()`.
- **UX tocada** (mínima, ligada al diseño): avisos «Es tu turno» / «Has
  declarado» se muestran encima de la caja de entrada en vez de flotar sobre la
  narración; aviso no bloqueante al copiar el enlace (antes `alert()`); barras
  de PG segmentadas que cambian de color por umbral; clases y razas traducidas
  en fichas y asistente; en móvil la barra de turno se vuelve deslizable y el
  cajón de ficha ya no reserva altura vacía.
- `prefers-reduced-motion` anula animaciones; foco de teclado visible en oro.

---

### D85 — Bless ejecutable con objetivos y fuente de concentración
Estado: **Aceptada** — 2026-09-26. Implementada.

Bless usa entradas de efecto en `Character.conditions`, con claves string
`condition: blessed`, `source: <lanzador>` y `concentration: bless`. No cambia
el struct de ficha; Codec ya conserva estos mapas. El reloj de concentración
del lanzador es el único plazo (60 segundos). Reemplazar, abandonar o perder
su concentración elimina sus entradas en todos los objetivos; relanzarlo
reemplaza objetivos y plazo. Varias fuentes pueden coexistir, pero se tira
solo un d4 por ataque/salvación, nunca por chequeo, iniciativa o daño.

`cast_spell` conserva objetivo principal y nivel; añade `additional_targets`
opcional, solo para Bless. Máximo `2 + cast_level` objetivos únicos existentes
y no muertos (un aliado caído sí puede recibirlo). Un lanzamiento consume una
acción, una casilla y una concentración; errores no gastan. Bless no usa
Twinned. Sin geometría, no se certifican alcance de 30 pies, visión ni
componentes materiales. Se integra en tiradas de arma/hechizo, salvaciones
incluida concentración, Furia implacable y muerte; se preservan naturales
1/20 y se registra el dado con el roller/RollLog existente.

Las reglas leen el efecto desde la ficha; World gestiona su ciclo de vida.
Las partidas antiguas sin estos metadatos no reciben un bonus inventado por
tener simplemente el texto `concentrating: bless`. Tampoco basta una condición
manual sin fuente. Los resultados preparados revalidan condiciones del actor;
Ataque Extra deja de usar el bonus si su fuente pierde concentración entre
golpes. Las notas de tiradas etiquetadas de Combat incluyen también Bless.

Pruebas: 21 casos deterministas en `bless_test.exs`, un smoke de schema y
compatibilidad en `flows/bless_test.exs`, y rehidratación real desde Postgres
en `bless_persistence_test.exs`. Suite: **1660 passed / 3 excluded**.

---

### D86 — Shield of Faith y CA efectiva compartida
Estado: **Aceptada** — 2026-09-26. Implementada.

Shield of Faith añade +2 a la CA efectiva, no a `Character.ac`. La regla de
CA efectiva vive en `Rules.Effects` y la consultan armas y hechizos de ataque;
incluye el estilo Defense ya existente. Los bonos del mismo hechizo no se
apilan, pero sí con Defense. Un lanzamiento consume bonus action y una casilla;
subir la casilla no cambia el +2 ni sus 600 segundos de concentración.

Reutiliza efectos en `conditions` con fuente y concentración (D85), con clave
`shield_of_faith`. Reemplazar/perder/abandonar concentración o vencer el plazo
retira solo los efectos de esa fuente. Relanzar cambia objetivo/plazo. No se
confunde con Shield, que sigue sin implementación mecánica propia.

Un objetivo existente no muerto, incluido el lanzador o un caído. Se mantiene
la semántica Twinned D65: puede afectar a dos objetivos distintos no-self con
una sola concentración/casilla; se consume la opción armada. No se habilita
`additional_targets` para este hechizo. Sin verificación de geometría de 60
pies, visión ni componentes materiales. El ciclo persiste mediante Codec.

Cada golpe de Ataque Extra vuelve a consultar la CA efectiva y registra la
CA que realmente usó; al perder auto-protección en el primer impacto, los
siguientes usan la defensa reducida. Ataques preparados (también los fallos)
rechazan cambios posteriores de CA/estilo/condiciones del objetivo.

Pruebas: 17 casos en `shield_of_faith_test.exs`, smoke TestModel de
`cast_spell`/`drop_concentration`, y rehidratación desde Postgres/Game.
Verificación: **1679 passed / 3 excluded**, compile sin warnings.

---

### D87 — Heal: curación plana y limpieza de condiciones
Estado: **Aceptada** — 2026-09-26. Implementada.

Heal pasa de descripción a efecto ejecutable: 70 PG a nivel 6 y +10 por
nivel de casilla superior (máximo 100 a nivel 9), sin dados ni modificador de
conjuración. Cura hasta el máximo y termina `blinded`, `deafened` y `diseased`,
incluidos sus plazos; esta última es la representación explícita de enfermedad
en `conditions`. No infiere enfermedades desde prosa ni cura veneno, maldiciones
u otras condiciones. No se introduce un subsistema de enfermedades.

Consume una acción y una casilla; no requiere ni reemplaza concentración.
Admite self y caídos vivos, pero rechaza muertos, constructos y no-muertos
(tipo representado por `race`, como D49) sin gastar recursos. Puede lanzarse a
PG completos para quitar condiciones. El mensaje reporta PG realmente recuperados.
Revalida los objetivos al aplicar para impedir resultados preparados obsoletos.
Conserva Twinned D65: dos objetivos distintos no-self, una casilla y consumo de
la opción armada; ambos se validan antes de aplicar. `additional_targets` sigue
siendo exclusivo de Bless. Sin geometría, visión ni componentes modelados.

Amplía la exclusión de Heal en D74: ahora su escalado plano se resuelve aparte
de la tabla de dados, sin modificar Spell/Character/Codec ni la tool `heal`
(curación por expresión de dados, distinta de `cast_spell` con spell `heal`).

Pruebas: 12 casos puros en `heal_spell_test.exs`, smoke PCAgent/TestModel
en `flows/heal_spell_test.exs` y Postgres/Game en `heal_spell_persistence_test.exs`.
Verificación: **1693 passed / 3 excluded**, compile sin warnings y formato global
correcto. El playtest integrado con LLM real permanece pendiente.

### D88 — Spare the Dying: estabilización ejecutable
Estado: **Aceptada** — 2026-09-26. Implementada.

El truco `spare the dying` estabiliza una criatura viva a exactamente 0 PG:
conserva sus PG y condiciones, borra fallos y usa el sentinel existente
`death_saves: %{successes: 3, fails: 0}`. No tira dados, no cura ni resucita.
Consume una acción, ninguna casilla y no altera concentración. Afecta a un
objetivo; Twinned D65 admite dos objetivos distintos no-self con una acción
y consume la metamagia armada. No admite `additional_targets` ni upcast.

Rechaza objetivos conscientes, muertos, inexistentes, constructos y no-muertos
(`race`, como D49/D87). Lanzarlo sobre alguien ya estable a 0 PG es válido:
conserva estabilidad y consume acción. Revalida objetivos y recursos al aplicar;
no gasta la salvación de muerte ni el turno del receptor. `World.stabilize/1`
es la transición de bajo nivel para una criatura viva a 0 PG; las restricciones
de tipo de criatura pertenecen al conjuro, no a toda estabilización posible.

Daño posterior rompe estabilidad por la ruta existente; curación posterior
reinicia contadores. Codec conserva el sentinel sin campos nuevos. PCAgent
distingue muerto, estable y moribundo: estando estable no pide herramientas
ni nuevas salvaciones. Sin geometría de contacto, componentes ni recuperación
automática de 1 PG tras 1d4 horas (no se incorpora un temporizador nuevo).

Pruebas: 11 casos en `spare_the_dying_test.exs`, smoke PCAgent/TestModel
en `flows/spare_the_dying_test.exs` y Postgres/Game en
`spare_the_dying_persistence_test.exs`. Dos reproducciones fallaron antes de
implementar: conjuro sin efecto y petición de salvación al PC estable.
Verificación: **1706 passed / 3 excluded**, compilación sin warnings y formato
global correcto. El playtest integrado con LLM real sigue pendiente.

### D89 — False Life: escalado de PG temporales y objetivo propio
Estado: **Aceptada** — 2026-09-26. Implementada.

Amplía D36/M23: False Life genera `1d4 + 4 + 5 × (cast_level − 1)` PG
temporales, una sola tirada y sin modificador de conjuración. El escalado
vive en `Rules.Upcast.false_life_dice/1`, separado de los dados de daño.
Una acción y una casilla del nivel pedido, hasta una hora sin concentración.
`target` debe ser el lanzador; el parámetro antes se ignoraba, pudiendo activar
Twinned indebidamente si se nombraba a otro. Ahora se rechaza sin gastar.
Twinned/Empowered/Heightened permanecen armadas porque este self-buff no califica.

Se conserva la selección determinista de D36/D83: nunca acumula, retiene el
mayor valor. Solo un valor estrictamente mayor sustituye fuente y plazo;
un valor menor o igual conserva el plazo anterior, aunque gasta la casilla
y la acción del lanzamiento. El mensaje diferencia valor generado y regla de
no acumulación; RollLog registra el único d4 y el total generado. Duración
no escala. Daño, descanso largo y carga usan el ciclo existente de PG temporales.
Sin selector humano de fuentes empatadas, componentes ni cambios de structs.

Pruebas: 11 casos en `false_life_test.exs`, smoke PCAgent/TestModel en
`flows/false_life_test.exs` y Postgres/Game en `false_life_persistence_test.exs`.
Oráculo de nivel 2 reproducido en rojo (7 PG frente a 12 esperados con d4=3).
Verificación: **1719 passed / 3 excluded**, compile sin warnings, formato global
y diff correctos. El playtest integrado con LLM real sigue pendiente.

### D90 — Lesser Restoration: elección explícita de una condición
Estado: **Aceptada** — 2026-09-26. Implementada.

Termina exactamente una de `blinded`, `deafened`, `paralyzed`, `poisoned`
o la enfermedad explícita `diseased`. `cast_spell` y `Actions.spell` añaden
`condition_to_remove` opcional al final, preservando llamadas anteriores.
Sin ese argumento se selecciona automáticamente solo si existe una única
condición elegible; si hay varias se pide elección, sin gastar recursos.
Una selección ausente/inválida o un objetivo sin efecto elegible se rechaza.
El argumento se rechaza en otros hechizos para no ignorar la intención.

Una acción, una casilla de nivel 2 o superior, efecto instantáneo sin dados,
curación, concentración ni escalado. No impone la exclusión de constructos o
no-muertos de Heal; sí rechaza personajes muertos. Twinned elimina una condición
por objetivo distinto no-self (política D65): selección explícita común, o única elegible independiente.
La aplicación revalida personajes y plazos para no ejecutar resultados obsoletos.
Se elimina el plazo de la condición retirada, conservando las demás.
Enfermedad sigue siendo el marcador abstracto `diseased`; no introduce un
catálogo de enfermedades individuales ni geometría para el alcance de toque.

Oráculo reproducido en rojo: el lanzamiento dejaba `poisoned` intacto.
18 pruebas nuevas: 15 de motor, 2 smoke PCAgent/TestModel (JSON antiguo y
selector nuevo) y 1 Postgres/Game (plazos, condición restante, acción/casilla).
Suite: **1737 passed / 3 excluded**. Compilación con warnings-as-errors y formato
global correctos. Playtest integrado de UI/LLM real sigue pendiente.

### D91 — Imposición de manos: purificación y curación combinadas
Estado: **Aceptada** — 2026-09-26. Implementada.

Amplía D49/M33 mediante `conditions_to_remove` opcional al final de
`lay_on_hands`: lista sin duplicados de `poisoned` y/o `diseased` presentes.
Cada condición cuesta 5 puntos de reserva. `amount` sigue siendo los PG
solicitados y puede ser 0 cuando se purifica; cura y purificación se combinan
en una sola acción. Se exige reserva para la cantidad solicitada más el coste
de purificar, pero solo se descuentan PG efectivos + 5 por condición, como D49.
Sin selector (o lista vacía) se conserva el contrato de curación anterior.

Purificar a alguien con PG completos es válido. Purificar a 0 PG sin curar
no estabiliza ni modifica salvaciones de muerte. Conserva PG temporales y
concentración; no es un hechizo ni activa metamagia. Rechaza muertos,
constructos/no-muertos, no-paladines, selecciones inválidas/ausentes y reserva
insuficiente. La operación revalida fichas/plazos antes de aplicarse; errores
no gastan ni purifican parcialmente. Reserva recuperable mediante descanso
largo existente. Enfermedad/veneno son marcadores abstractos, no un catálogo
de múltiples agentes patógenos ni una simulación de alcance de toque.

13 pruebas nuevas: 10 casos puros, 2 smoke PCAgent (JSON anterior/nuevo) y
1 Postgres/Game. Suite final **1750 passed / 3 excluded**, compile con
warnings-as-errors y formato global correctos. Una primera ejecución encontró
una colisión de email en `ProtectedRoutesTest` (fixture con `unique_integer`);
la prueba aislada y la repetición completa pasaron. No se modifica esa fixture.

### D92 — Corte finito de versión jugable y verificación real
Estado: **Aceptada** — 2026-09-26. Verificada dentro del alcance definido.

Se congela la ampliación de reglas para cerrar cuatro bloques: acceso/héroe,
partida real, recursos/continuidad y móvil/regresión. Contrato y evidencia en
`producto/05-cierre-version-jugable.md`. Dos partidas propias de QA, un humano
guerrero nivel 1, OpenRouter real y pruebas offline complementarias. No exige
implementar las 319 entradas SRD ni certifica campañas largas/multijugador.

El playtest detectó un cajón móvil sin el personaje propio al explorar solo
y una llamada a actuar durante pausa. Se corrigen manteniendo las columnas de
escritorio y la posibilidad de declarar intenciones. Regresión LiveView antes
en rojo; suite final **1751 passed / 3 excluded**. Próximo foco: latencia de
turnos (19–42 segundos observados hasta pasar al DM) y consistencia narrativa.

### D93 — Omitir la consulta del relevo ya forzado por D30
Estado: **Aceptada** — 2026-09-26.

Tras un beat del DM en exploración, D30 ya sobreescribe la decisión del TM
cuando su narración dirige la palabra a un humano. `Game.advance` puede aplicar
ese mismo relevo sin otra llamada al modelo: reutiliza la detección existente,
`do_apply_decision` y el cierre habitual de persistencia/broadcast/tick.

Guardas conservadoras: no combate, re-evaluación, intención humana pendiente,
último actor PC, `pending_mini`, `last_was_mini` ni `interrupted`. La selección
de humano sigue siendo la de D30; no introduce otra política de turnos. El
opener y el relevo tras PC ya tenían caminos directos y se conservan.

La equivalencia exigida es la del **relevo**. Al omitir la consulta también se
evitan sus posibles retries, eventos de error y contador/circuit breaker; no
se simulan errores de un proveedor que no fue llamado. Los casos no forzados
mantienen el TurnMaster y su manejo de errores.

`turnmaster_fast_path_test.exs`: 11 pruebas con contador real de `request/4`,
0 llamadas en relevo forzado, consulta conservada en ambiguos/combate/mini,
precedencia de intents, guardas por flag y pausa sin duplicar relevo. No se
afirma una reducción de segundos: queda pendiente una medición live nueva.

### D94 — Brief factual con estado efectivo y estable
Estado: **Aceptada** — 2026-09-26.

`Brief` presenta a DM, PCAgent y TurnMaster la CA calculada por
`Rules.Effects.effective_ac/1`, indicando la base cuando difiere; los PG
temporales se muestran separados de PG/máximos. Se distingue `[ESTABLE]` a
0 PG con el sentinel existente de tres éxitos, `[CAÍDO]` y `[MUERTO]`.
No añade una regla de estabilidad ni modifica el World.

La identidad incluye raza, clase y nivel canónicos, usando las traducciones
existentes y tolerando datos opcionales de NPC. DM/PCAgent reciben una
instrucción breve para priorizar este estado sobre inferencias por equipo:
un regalo narrado no equivale a un cambio mecánico aplicado por tools.
Esto mejora la información disponible, no garantiza ausencia de alucinaciones.

14 pruebas nuevas: CA 18→20→18 por efecto/concentración/plazo, Defense,
PG temporales, estados vitales, identidad/NPC y smoke TestModel de ambos agentes.
Integración D93+D94: **1776 passed / 3 excluded**.

### D95 — P3 efectos ejecutables de conjuros: escalado RAW de trucos, dados builtin y Guiding Bolt
Estado: **Aceptada** — 2026-09-26.

**Escalado de trucos por nivel de PERSONAJE** (no `cast_level`): el daño de un
truco escala en los umbrales RAW 5/11/17 (2/3/4 dados). D74 ya prohíbe lanzar
trucos a nivel superior, así que el eje de escalado es el nivel del lanzador.
La tabla curada vive en código (`Rules.Cantrips`, mismo criterio que
`Rules.Upcast` D74) con las caras base de cada truco: fire bolt 1d10, ray of
frost 1d8, chill touch 1d8, produce flame 1d8, shocking grasp 1d8, sacred
flame 1d8, vicious mockery 1d4, poison spray 1d12, acid splash 1d6 y eldritch
blast 1d10. **Equivalencia de Eldritch Blast**: RAW añade RAYOS (cada rayo es
una tirada de ataque separada); el motor lo simplifica a DADOS EXTRA sobre UNA
sola tirada (1d10→2d10→3d10→4d10): una tirada, un solo roll log, funciona con
crit/Empowered/advantage como cualquier hechizo de ataque. Simplificación
documentada, no oculta.

**Dados builtin y hojas rancias**: cast_spell rellena SOLO los campos `nil`
de la ficha (`dice`, `save_ability`, `damage_type`) con el catálogo
(`Heroes.Spells.get/1`, builtin gana al SRD como en `all/0`). Las hojas
persistidas antes de los builtin (jsonb con sacred flame `dice: null`) se
corrigen al lanzar, sin migración ni cambios de Codec. `custom_*` queda
excluido (su definición vive en el bundle inyectado, no en el catálogo).
Añadido builtin `poison spray` (1d12, salvación CON, veneno). **Acid splash**
RAW alcanza 2 criaturas; simplificado a 1 objetivo (misma ruta y validación
que el resto de trucos save). Poison spray y acid splash completan los cuatro
trucos save con `dice: null` en el JSON del SRD (no se edita
`priv/srd/spells.es.json`).

**Guiding Bolt ejecutable**: 4d6 radiante on-hit ya existía; lo nuevo es la
ventaja. Marcador = entrada estructurada en `conditions` del objetivo:
`%{"condition" => "guided", "source" => <lanzador>, "round" => <r>}` (mismo
portador que bless/shield of faith D86: conditions ya viaja por el jsonb y el
Codec lo tolera sin cambios). Se aplica SOLO al impactar; se CONSUME en la
primera tirada de ataque posterior contra el objetivo —hit o miss, cualquier
atacante, arma o hechizo— (en multiataque solo el primer swing queda
ventajoso, RAW); la ventaja se combina/cancela vía `Conditions.combine/2`
(patrón D57: ventaja+desventaja = normal). **Expiración perezosa sin tocar
los hot paths de `world.ex`**: el marcador solo está activo en combate y
mientras `turn_state[lanzador]["round"] == r` — `TurnBudget.start` (invocado
por `set_current_combatant` al iniciar un turno principal nuevo) reescribe ese
valor al arrancar el siguiente turno del lanzador, y `end_combat` limpia
`turn_state`, de modo que ambas caducidades (inicio del siguiente turno del
lanzador y fin del combate) se derivan del estado existente sin editar
`set_current_combatant`/`end_combat` (zona activa de otra tanda). Helpers
aislados `World.mark_guided/2` y `World.consume_guided/1` son la única huella
en `world.ex`. Una entrada muerta tras combate queda latente en el jsonb
(inofensiva: nunca reactiva) hasta consumirse o sobrescribirse. Un
lanzamiento fuera del turno propio (reacción) deja la marca inerte (el
`turn_state` del lanzador corresponde a su turno anterior): la ventana no se
abre y la entrada queda latente hasta consumirse.

### D96 — P7 Sleep y Shield ejecutables
Estado: **Aceptada** — 2026-09-26.

**Sleep (nivel 1, encantamiento)**. Antes el builtin caía en la rama de
curación de `:automatic` (dados sin `damage_type`) y **curaba al enemigo**;
ahora tiene caso propio en `cast_spell`. RAW: pool de **5d8** (+**2d8** por
nivel de casilla sobre 1 — fila `:sleep` en `Rules.Upcast`, combinada con la
base en una sola expresión `7d8`/`9d8`… para el conteo exacto de dados),
**sin salvación**. Simplificaciones documentadas: **sin rejilla ni área** —
afecta a todos los enemigos del lanzador vivos y conscientes (hp > 0 y sin
`unconscious` previo; `side` distinto), **ordenados por PG actuales
ascendente**; se aplica de menor a mayor: quien entra entero en el pool
restante queda `unconscious` (entrada estructurada
`%{"condition" => "unconscious", "source" => "sleep:<lanzador>"}`) y
descuenta TODO su pg; **la primera criatura que no cabe detiene el reparto**
(RAW). Duración 1 minuto vía `WorldClock` (misma clave que
`apply_condition`). **Despertar**: cualquier daño recibido
(`do_apply_damage` quita las entradas `sleep:*`, el daño se aplica normal);
un melee contra el dormido sigue auto-criticando por la condición existente.
El parámetro `target` de la tool se ignora semánticamente (área abstracta;
la validación de existencia sigue). **Twinned D65 no duplica el pool**: se
resuelve una vez y la opción no se aplica ni se consume (mismo criterio que
los self-buffs).

**Shield (nivel 1, abjuración)**. La reacción RAW ("cuando eres objetivo de
un ataque") no existe en este motor: se simplifica a una **postura armable
en el turno propio** (patrón D64 `start_uncanny_dodge`). No hay economía de
reacción consumible para el propio lanzador — divergencia documentada: se
arma **gratis** como D64 y **consume 1 casilla de nivel 1** (validación y
gasto genéricos de `cast_spell`). Efecto: **+5 a la CA efectiva** vía
`Rules.Effects.effective_ac/1` (entrada estructurada
`%{"condition" => "shielded"}` en `conditions` — nunca muta `c.ac`; apila
con Defense/Shield of Faith, no consigo misma: rearmar renueva). **Expira al
inicio del siguiente turno del lanzador**: barrido EAGER en
`set_current_combatant` (solo en turno nuevo, `first?`) y en `end_combat` —
más limpio que la expiración perezosa de guided (D95) porque
`effective_ac/1` sigue sin necesitar el World y el brief de CA (D94) lo
muestra sin tocar `brief.ex`. Solo armable en combate (fuera, error claro).
**Magic missile hace 0 daño** al portador mientras la postura viva (gancho
en la rama `:automatic` de daño).

**Fixes de revisión cruzada (misma tanda)**: (1) *guided zombie* —
`end_combat` ahora también BORRA las entradas guided: antes limpiaba
`turn_state` pero dejaba la marca, y un combate nuevo en la misma ronda la
revivía (el primer turno del lanzador reescribe `turn_state` a esa ronda y
`ts == round` la daba por activa). (2) *rangos de dados* — la validación
1..100 dados / 2..1000 caras vive en `Dice.valid?/parse_expr` (una sola
fuente): expresiones gramaticalmente válidas pero letales ("101d6",
"1d99999") o sin sentido ("1d1") se rechazan en TODAS las rutas de
expresión (heal incluido), no solo en `Actions.roll`/`Tools.roll`.

### D97 — Hold Person y Faerie Fire ejecutables
Estado: **Aceptada** — 2026-09-26.

Dos conjuros de control que el catálogo trae como `kind: save` sin dados.
Hasta ahora la rama de salvación aplicaba 0 de daño y no imponía la
condición. El motor pasa a resolverlos. Sin radio, sin «que puedas ver» y
sin cubo de 20 pies: un objetivo (Twinned D65 añade el segundo). Upcast de
objetivos queda fuera, como D74.

**Hold Person** (nivel 2, concentración 1 minuto). Salvación de Sabiduría
contra la CD del lanzador (8 + competencia + modificador de lanzamiento;
el aura D61 se suma, como en el resto de salvaciones de conjuro). Fallo:
`paralyzed` con fuente `hold_person:<lanzador>` mientras ese lanzador
concentra. Éxito: nada, y si nadie falla no hay concentración. La
paralización que ya existe sigue valiendo: auto-fallo de Fuerza/Destreza,
ventaja para quien le ataque y crítico automático en melee (D78).

Al **inicio del turno nuevo** del objetivo (`set_current_combatant`, solo
`first?`, el mismo cuello que D44) repite la salvación de Sabiduría contra
la CD guardada en la entrada. Éxito quita `paralyzed`. Fallo la mantiene.
Re-seleccionar el mismo turno o un turno de reacción no tiran. RAW pide el
final del turno; aquí es el inicio, porque ese es el cuello determinista
que ya existe.

**Humanoide:** si `race` está vacío, cualquier criatura (el motor no tiene
tipo de criatura). Si `race` existe, solo se acepta un humanoide conocido
(`human`, `elf`, `dwarf`, `halfling`, `gnome`, `half-elf`, `half-orc`,
`dragonborn`, `tiefling`, `humanoid`, `goblinoid`, `orc`, o un texto que
contenga `humanoid`). Un `beast` o un `giant` se rechaza sin mutar. Entran el goblin
del catálogo (`goblinoid`) y el kobold (`reptilian`: es el rótulo local
de un humanoide).

**Faerie Fire** (nivel 1, concentración 1 minuto). Salvación de Destreza.
Fallo: condición `faerie_fire` con fuente `faerie_fire:<lanzador>`. Éxito:
no hay marca. Cualquier atacante tiene ventaja contra el afectado
(`Conditions.attack_mode`, lista de ventajas del objetivo, el espejo de
`hidden` D57 que es del atacante). Se cancela con una desventaja del
atacante vía `combine/2`. Un objetivo.

**Limpieza por fuente.** `Effects.without_source/2` solo quitaba bless y
shield of faith. Ahora también quita `hold_person:<nombre>` y
`faerie_fire:<nombre>` cuando `clear_sourced_effects` recibe el nombre del
lanzador. Así caen por las mismas rutas que Bless (D85): soltar, daño a 0,
furia, incapacidad, reloj de concentración. `compose_concentration` no
vuelve a llamar a `set_concentration` en estos dos nombres: el efecto se
aplica después de fijar la concentración, como Bless.

Errores (no humanoide, objetivo inexistente o muerto, sin casilla) no
mutan. La casilla se gasta si el conjuro se resuelve, aunque todas las
salvaciones se superen.

### D98 — Mage Armor y Charm Person ejecutables
Estado: **Aceptada** — 2026-09-26.

Dos conjuros que hoy no hacen nada mecánico: mage armor es `automatic` sin
dados (noop) y charm person es `kind: save` sin dados (salvación de 0). El
motor pasa a resolverlos. Sin alcance ni «criatura voluntaria».

**Mage Armor** (nivel 1, 8 horas, sin concentración). Condición `mage_armor`
con plazo `28800` s (`WorldClock.track`, clave `condition:mage_armor`). No
muta `c.ac`. `Rules.Effects.effective_ac/1` usa `max(c.ac, 13 + mod DES)`
solo mientras la condición vive y el inventario no tiene armadura. El
inventario sí distingue armadura (`Item.kind == :armor`: leather, chain,
hide). Un objeto llamado `shield` también es `:armor` en el catálogo y **no
cuenta**: el escudo no termina Mage Armor. No hay acción de vestirse; la
fórmula simplemente no se aplica mientras esa armadura está en el
inventario, y vuelve si se quita. Relanzar no apila: renueva el plazo.
Cualquier objetivo vivo (el DM puede elegir a cualquiera). Twinned añade un
segundo objetivo y gasta una casilla. Upcast no cambia el efecto.

**Charm Person** (nivel 1, 1 hora, sin concentración). Salvación de
Sabiduría contra la CD del lanzador, con el mismo stack que el resto de
conjuros (aura D61, Bless, y Astucia gnoma D71: es salvación mental contra
magia). **Ventaja si `phase == :combat`**: simplificación de «si estáis
luchando contra él». No se apila con la ventaja gnoma (sigue siendo una
ventaja). Fallo: condición `charmed` con fuente `charm_person:<lanzador>` y
`caster_side`, plazo `3600` s. Éxito: nada. No hay concentración. No
reescribe `side` ni impide atacar.

El encantado tiene **desventaja al atacar al lanzador** (la fuente del
`charmed`), no al atacar a otros. Se cancela con una ventaja vía
`combine/2`. Humanoide: la misma lista que D97 (raza vacía = cualquiera).
Upcast de objetivos fuera.

**Se rompe** si el lanzador o alguien de su `side` inflige daño real
(`incoming > 0`) al encantado. Un tercero de otro bando no la quita. El
gancho está en `do_apply_damage`, junto al despertar de Sleep (D96). El
daño tiene que traer `attacker` y `attacker_side` en las opts; un daño sin
atacante no rompe el encanto. El plazo de 1 hora también la quita.

Errores (no humanoide, muerto, inexistente, sin casilla) no mutan.

### D99 — Arma espiritual persistente y Spirit Guardians ejecutables
Estado: **Aceptada** — 2026-09-27.

Dos piezas de clérigo que el motor resolvía a medias: spiritual weapon hacía
un único ataque de conjuro (con escalado cada 2 niveles) pero no dejaba arma
persistente; spirit guardians era un 3d8 de un disparo con flag de
concentración, sin aura recurrente. Ambos pasan a su forma RAW 2014, con las
simplificaciones de siempre (sin grid, sin posicionamiento).

**Arma espiritual** (nivel 2, 1 minuto, **sin concentración** — RAW). El
ataque inicial al lanzar queda como está: ataque de conjuro cuerpo a cuerpo
con los dados escalados por `Rules.Upcast` (cada 2 niveles) y **sin** mod de
lanzamiento (simplificación preexistente mantenida). Además la lanzadura
deja en el lanzador una **postura** — entrada estructurada en `conditions`,
patrón D96 shield:

    %{"condition" => "spiritual_weapon", "dice" => "1d8", "mod" => 3,
      "rounds_left" => 10}

con los dados ya escalados y el mod de la característica de lanzamiento
guardados. Como es una entrada de `conditions` (map arbitrario), el Codec la
persiste sin cambios y un jsonb viejo sin ella sigue decodificando.

La postura habilita la **nueva herramienta** `spiritual_weapon_attack(who,
target)` (DM cualquiera; PC solo si es quien): una **acción adicional**
(TurnBudget `:bonus`, patrón D82 healing word) que repite el ataque de
conjuro cuerpo a cuerpo — ahora `dados + mod` force — por el pipeline
existente: RollLog `:attack`, crítico dobla los DADOS (no el mod), guided
consume (D95), ventaja de faerie fire vía `Conditions.attack_mode`, bless al
d20 y CA efectiva del objetivo. Errores (sin postura, objetivo inexistente o
muerto, ya sin acción adicional) no mutan ni gastan.

`rounds_left` decrementa **solo al inicio de turno nuevo** del lanzador
(`first?`, el cuello D44); re-selección y reacción no decrementan. A 0 la
postura muere con nota en el log. Relanzar **sustituye** la postura previa
(no apila). Fuera de combate se permite lanzar, pero el reloj de rondas solo
avanza en combate: sin cuello determinista fuera de él (simplificación
documentada; la postura sobrevive a `end_combat`).

**Spirit Guardians** (nivel 3, concentración — plazo del SRD, 10 min). Al
lanzar **no hay daño inmediato**: se marca la postura/condición en el
lanzador, vinculada a concentración, patrón D97
(`World.impose_sourced_conditions` + cláusula que evita la doble fijación en
`compose_concentration`):

    %{"condition" => "spirit_guardians",
      "source" => "spirit_guardians:<lanzador>", "dice" => "3d8",
      "dc" => 13}

con los dados escalados al nivel de casilla y la CD del lanzador guardadas.
`target` se ignora (alcance self); Twinned no aplica ni consume (mismo
criterio que D96 sleep).

El **tick** ocurre al inicio del turno nuevo del lanzador (`first?` D44),
solo mientras concentra y está vivo y consciente: cada **enemigo** vivo
(`side` distinto) y consciente tira SAB contra la CD guardada con el stack
completo de `condition_save` (gnomo D71, aura D61, inspiración bárdica,
Indomitable D68, RollLog `:save`). Fallo: los dados completos de daño
radiante; éxito: la mitad (`div/2`, floor). Un único conjunto de dados por
enemigo. Orden determinista (nombre ascendente) para oráculos exactos. El
daño va por el pipeline completo (`Damage.prepare`): uncanny dodge,
resistencias, salvación de concentración del enemigo dañado y caída a 0 con
sus ganchos. Si el lanzador está caído/incapacitado o perdió la
concentración, el aura no tickea (y la condición muere por las mismas rutas
que Bless, D85: la limpieza por fuente de `without_source` cubre
`spirit_guardians:<nombre>`).

**Upcast** (`Rules.Upcast`): fila `spiritguardians` — `+1d8` por nivel de
casilla sobre 3º (RAW). Los dados escalados se guardan en la marca al
lanzar, así que cada tick usa el nivel de casilla gastado. La fila de
spiritual weapon (cada 2 niveles) ya existía y alimenta tanto el ataque
inicial como la postura.

Simplificaciones: sin radio de 15 pies ni velocidad reducida ni designar
criaturas ilesas — el aura alcanza a todos los enemigos vivos conscientes
(área abstracta, como D62); sin daño necrótico por alineamiento (siempre
radiante); arma espiritual sin posición (el ataque alcanza a cualquier
enemigo vivo). Errores no mutan ni gastan casilla; la casilla se gasta al
resolver el lanzamiento.

### D100 — Inicio de turno determinista, visible y con recursos consumidos
Estado: **Aceptada** — 2026-10-01.

La revisión de D97/D99 reproduce tres fallos: los relevos llamaban a
`World.set_current_combatant` sin el roller configurado en la partida; sus
salvaciones/daños no llegaban al timeline; tras un error del actor avanzaba
el cursor de Session pero quedaba activo el combatiente anterior. Además,
Spirit Guardians tiraba Inspiración/Indomitable sin consumirlos y podía
reutilizarlos en la salvación de concentración del mismo daño.

`Game.Combat.start_turn/3` centraliza la selección del combatiente para
relevos principales, reacciones, fallback del TM y fallback del actor.
Pasa el roller de Game y un RollLog opcional a `World.set_current_combatant/4`;
World lo transmite a la repetición de Hold Person y al aura de Spirit
Guardians. Las aridades anteriores siguen funcionando.

Los grupos se recogen durante la transición y, solo después de aplicarla,
el proceso Game persiste eventos `:dice` y los publica al modal. Llevan
`timing: "turn_start"` y `combatant`, además de quién tiró, motivo, dados,
total y resultado. No se inventa un beat de narración ni otra marca `:turn`:
la resolución ocurre antes de la acción/declaración. El siguiente DM/PCAgent
recibe esos eventos en el history compartido y los PG efectivos en el brief.

En Spirit Guardians, el daño recibe la ficha con Inspiración/Indomitable
ya consumidos por la salvación del hechizo, pero valida la transición contra
la ficha original. Se aplica el consumo incluso si el daño queda en cero
por inmunidad. Es el mismo contrato de resolución única de D81, sin reglas
de concentración paralelas.

Se conserva la guarda de turno nuevo de D82: re-seleccionar, interrumpir o
recargar el snapshot no repite tiradas/daño ni devuelve recursos. No cambia
structs ni Codec; conserva las simplificaciones temporales/espaciales de
D97/D99. No certifica latencia de campañas largas ni obediencia narrativa
de un proveedor.

13 pruebas nuevas: cinco de motor en `spirit_guardians_test.exs` y ocho de
Game/Postgres/TestModel en `game_start_turn_effects_test.exs`. Reproducciones
en rojo previas; suite offline **1931 passed / 3 excluded**.

### D101 — La sesión autenticada determina el personaje de la mesa

**Estado: Aceptada (2026-10-01).** `?as=` selecciona una vista, nunca la
identidad de otro jugador. Solo el creador puede usar `?as=dm`; cualquier
otro valor vuelve al participante humano vinculado al usuario autenticado.
La validación se aplica también en patches y actualizaciones PubSub, antes de
proyectar eventos privados, intenciones o auto-play.

La implementación anterior aceptaba cualquier nombre humano del roster y
tenía un fallback que aceptaba `dm` para participantes no creadores. Eso
permitía ver secretos del DM y declarar/activar auto-play como otro jugador.
Cuatro pruebas LiveView reproducen y cierran esos caminos. La vista DM es de
inspección: muestra un enlace para volver al personaje y no ofrece un input
que `Game.declare` necesariamente rechazaría. Se conserva el single-writer.

### D102 — Historial retenido y controles de mesa utilizables

**Estado: Aceptada (2026-10-01).** La LiveView retiene el tamaño de su ventana
de historial: empieza en 200 eventos, crece de 100 en 100 y pide al Game el
rango completo en cada snapshot. Reagrupar ese rango evita bloques de turno
partidos en el límite de página, mantiene lo ya cargado al recibir nuevos
eventos y elimina fragmentos borrados por un retry. No se mezclan versiones
antiguas de eventos en el socket. El cursor ya no depende de mensajes
visibles: una página de secretos del DM no bloquea la crónica de un jugador.

La ventana está limitada a 2000 eventos y 400 bloques; conserva los más
recientes y avisa al alcanzar el límite. El Game sigue usando 200 por defecto
para clientes existentes. Es una lectura acotada, sin cambios de World.
El hook de scroll captura la posición antes del patch y conserva un mensaje
ancla al insertar historia; si el lector estaba al final, sigue allí incluso
tras cambios de fuente o viewport. Un botón permite volver al último turno.

Pausa/reanudar precede los controles secundarios y tiene un objetivo táctil
de 44 px en móvil. La ficha usa un botón nativo con `aria-expanded` y un
panel identificado; su estado sobrevive a PubSub. Una declaración fallida
conserva el borrador y explica cómo reintentar. Enviar texto vacío no borra
una intención pendiente; el botón «Borrar» mantiene esa función explícita.

Evidencia: doce pruebas nuevas, suite **1943 passed / 3 excluded**, compile
con warnings-as-errors, formato y diff correctos; Chrome real a 1440 y
390 px, apertura/cierre por Espacio, intención/borrado, cambio de vista DM
y scroll después de resize. No certifica aún campañas largas ni accesibilidad
con lector de pantalla. El detector visual devuelve seis warnings de estilos
previos (bordes pixel, toast y transición de PG); no se cambia el mundo visual
de D84 como parte de este arreglo de uso.

### D103 — Diálogos de PCs después de citas de PNJ

**Estado: Aceptada (2026-10-01).** El playtest de taberna reproduce una fuga
real: el splitter conserva la puntuación dentro de comillas y deja «Lyra
deja…» en la misma cláusula que la cita anterior de Borin. Además no reconocía
«Vex asiente» ni diálogo citado con atribución «dice Lyra».

La sanitización de DM divide ese límite cuando comienza un nombre canónico de
PC, reconoce asentir como decisión y retira citas atribuidas al PC o citas
sin atribución inmediatamente después de una acción del PC retirada. Mantiene
las citas de PNJ con atribución propia, menciones citadas y estados pasivos.
Los nombres con puntuación se escapan y se validan por separadores, sin
depender de un word-boundary después de un paréntesis.

El corte vive en `Text`, antes de persistir y construir el history compartido.
La vista de streaming pasa también los nombres de PC del World; un cambio de
actor reinicia su burbuja incluso si comparte identificador de turno. No se
reescribe ningún evento antiguo. Es una defensa para formas reconocibles,
no comprensión semántica universal ni garantía de obediencia del proveedor.
Siete regresiones de texto/Game y dos de LiveView prueban el caso registrado,
conservación de PNJ/estados legítimos, idempotencia y vista en vivo.

### D104 — Fin de combate también antes del beat

**Estado: Aceptada (2026-10-01).** Un aura puede derrotar al último enemigo
durante `Combat.start_turn`, antes de que exista un beat. Esperar a Settlement
dejaba a un humano en `:waiting` dentro de un combate ya resuelto. Después de
aplicar los efectos y registrar sus dados, Game ejecuta el mismo
`maybe_end_combat` que ya usa Settlement: limpia la fase/combatiente,
descarta intenciones de combate obsoletas y registra una sola nota de fin.
Los dados conservan la fase en que realmente ocurrieron. Cuatro regresiones
prueban decisiones del TM, ausencia de decisión, error del TM y error del
actor; World y Postgres coinciden antes de la acción humana siguiente.

### D105 — Cada TurnMaster recibe un snapshot vigente

**Estado: Aceptada (2026-10-01).** Cada `run_turnmaster_beat` pasa
`message_history: []` al runner. El prompt ya contiene World, último actor,
roster, intenciones humanas, avisos e interrupción pendientes. Acumular los
prompts completos de relevos anteriores añadía estados de rondas/PG obsoletos
y hacía crecer el contexto con cada turno. No es el history narrativo
compartido del DM/PCAgent: esos agentes conservan su recorrido actual.

Se conserva el feedback de herramientas/reintentos dentro del beat y la
primera decisión válida terminal (D79). Se conserva también la progresión
del modelo Test entre runs, las consultas en combate/mini-turnos y las
prioridades D27/D28/D30/D93. Tres pruebas inspeccionan peticiones reales del
runner: un solo WORLD vigente por relevo, feedback inválido solo durante
su corrección y reacción humana/actor interrumpido presentes. Esto comprueba
contexto acotado; todavía no certifica una reducción de segundos.

### D106 — Borrador local hasta la confirmación de Game

**Estado: Aceptada (2026-10-01).** El hook del formulario guarda el borrador
en `sessionStorage`, separado por partida y personaje y limitado a esa
pestaña. Restaura el texto al recargar o volver de la vista DM. Se borra al
vaciar el campo o recibir `action_accepted` después de que Game confirme la
declaración; una confirmación antigua no borra un borrador nuevo diferente.
No escribe World/intenciones desde JavaScript y tolera almacenamiento no
disponible. El texto aceptado vive en Game; no vuelve a enviarse al recargar.

Evidencia D103–D106: diecisiete pruebas nuevas; suite **1960 passed /
3 excluded** (16,6 s), compile con warnings-as-errors, formato global y diff
limpios. Chrome real verifica restauración tras reload, confirmación sin
repetición y retorno de DM. El playtest continúa; «agradable para jugar» no
se considera logrado por este gate técnico.

### D107 — Un turno principal fallido también cuenta en la ronda

**Estado: Aceptada (2026-10-01).** En el playtest, el DM resolvió el ataque
del lobo y después intentó actuar por otro monstruo. La tool rechazó esa
segunda acción, pero el fallback no marcaba el slot como usado. El siguiente
beat DM podía volver a resolver el mismo monstruo y la ronda quedaba pendiente.

Antes de `Session.end_turn`, Settlement marca el combatiente actual igual que
en el camino exitoso. Conserva PG, recursos y acciones ya comprometidos; no
repite herramientas ni tiradas. Las mini-interrupciones no marcan el ledger
de turnos principales. El último turno fallido permite cerrar la ronda y
refrescar el siguiente actor. La guarda fuera de turno identifica además al
combatiente vigente y pide terminar su narración antes del relevo del TM.

Evidencia: tres fallos reproducidos antes del arreglo, un control de mini-turn
y una regresión del mensaje directivo. Cinco pruebas nuevas, gate focalizado
61 passed; suite **1965 passed / 3 excluded** (16,6 s), compile sin warnings,
formato global y diff correctos. No garantiza que el proveedor se autocorrija:
garantiza la liquidación del turno si no lo hace.

### D108 — El schema de hechizos coincide con sus argumentos opcionales

**Estado: Aceptada (2026-10-01).** En una partida real, Lyra agotó dos beats
porque `cast_spell` recibía `condition_to_remove` para un hechizo distinto de
Lesser Restoration. El puente aceptaba omitir ese argumento, pero el schema
derivado por exAgent exigía los seis argumentos y no admitía `null`.

`Tools.agent_tools/0` adapta los metadatos que reciben DM y PCAgent: solo
`caster`, `spell` y `target` son obligatorios; `cast_level`,
`additional_targets` y `condition_to_remove` admiten omisión o `null`. El
selector enumera exclusivamente las condiciones soportadas y `null`. Se
conservan firmas/aridades y la derivación de exAgent; no se modifica la
dependencia ni se anuncian uniones de tipos que su derivador no comprende.

Un selector en blanco se normaliza a ausencia en el puente. Un selector no
vacío para otro hechizo sigue siendo un error antes de tirar o gastar recursos,
con instrucción de omitirlo o enviar `null`. No se relajan las reglas de
Lesser Restoration ni se inventan elecciones por el jugador.

Evidencia: cuatro regresiones en rojo antes del arreglo; schemas reales de
ambos agentes y un beat PCAgent/TestModel que lanza un truco sin casillas.
60 pruebas focalizadas; suite **1969 passed / 3 excluded** (16,4 s), compile,
formato y diff correctos. Logs `/tmp/dragonex-spell-quality-*.log` y
`/tmp/dragonex-spell-contract-*.log`. Los agentes ya creados en una sesión
anterior conservan sus metadatos hasta reiniciarse; se verifica la aplicación
viva con una nueva partida propia, sin alterar ajustes globales.

### D109 — La ficha presenta defensas, reservas y estado vital del motor

**Estado: Aceptada (2026-10-01).** La mesa mostraba la CA base incluso con
defensas activas y no enseñaba casillas gastadas ni dados de golpe. Un PC a
0 PG aparecía siempre «Caído», aunque estuviera estable o muerto. La barra
del DM ocultaba qué monstruo estaba actuando y podía anunciar «¡Tu turno!»
mientras el motor resolvía la declaración humana.

Las fichas compacta/detallada y el tracker usan `Effects.effective_ac/1`.
La ficha propia presenta reservas del World con un `dl`: dados de golpe
restantes/nivel/tamaño, casillas restantes por nivel y Segundo aliento. No
calcula ni rellena máximos de casillas; un caster sin registro muestra esa
ausencia. Los nombres de armas/hechizos pasan por el catálogo español; el
alias legado `firebolt` conserva su clave y se presenta como «Rayo ígneo».

HP y death tracker determinan «Caído», «Estable» o «Muerto», con contadores
de salvación pendientes. En combate se nombra el combatiente canónico; la
invitación a actuar requiere `status: :waiting`. Un beat humano en curso dice
«Resolviendo tu acción». Son proyecciones de lectura, sin mutar fichas,
reservas, World o persistencia desde LiveView.

Evidencia: nueve regresiones nuevas en `game_sheet_state_test.exs`, incluyendo
un lanzamiento vía Game, gasto de casilla y recarga LiveView. Gate posterior
a la ficha compacta: **1978 passed / 3 excluded** (16,8 s), compile sin warnings,
formato global y diff correctos. Logs `/tmp/dragonex-sheet-quality-*.log`.
Playtest propio `/games/15110`: dos Magic Missile gastan de 2 a 0 casillas,
con daño 11/14 y fin de combate. Ficha/teclado/pausa/reload a 375/1440 px,
sin errores JS ni overflow; artefactos `/tmp/dragonex-playtest/mage-*.{log,png}`.

### D110 — La recuperación de combate sigue sus slots pendientes

**Estado: Aceptada (2026-10-01).** D107 corrige el ledger de turnos fallidos,
pero un `Session.handoff` del TM no avanza el cursor heredado de WorldDriven.
Tras cambiar de fase, ese cursor puede devolver al mismo PC o saltar a un
turno ya usado. Si la iniciativa se inicia dentro del beat DM, el slot todavía
es `nil` aunque una acción haya fijado `turn_owner`; marcar «dm» tampoco consume
el turno del monstruo que realmente actuó.

`Game.Combat.fallback_turn/2` comparte la recuperación de actor y TM. En
combate elige el primer combatiente pendiente de `World.combat_cycle`, con
handoff a su controlador y `start_turn` del nombre concreto. Mantiene enemigos
consecutivos y PCs caídos para sus salvaciones; omite enemigos derrotados y
PCs muertos. Una ronda completa vuelve a su primera posición. WorldDriven
mantiene sus semánticas públicas y su cursor para exploración/tests del
framework; no se altera la dependencia exAgent.

Una mini-interrupción no marca ni avanza la ronda, ni siquiera cuando el actor
es el último de la iniciativa y el ledger está vacío. Si su dueño principal
sigue pendiente en esta ronda, vuelve a ese slot sin refrescar acciones ni
repetir efectos. En otro caso continúa los slots pendientes. El motor limpia
el marcador de interrupción al recuperar la palabra.

La identidad liquidada usa el slot vigente o un `turn_owner` de esta ronda
todavía pendiente. Una transición de escena sin acción no consume un slot;
una narración DM sin slot tampoco se atribuye a un dueño ya gastado. Se conserva
el daño anterior al fallo. La prueba de contexto D100 se corrige para cerrar
cada decisión TestModel con «listo»; encadenar decisiones antes del cierre
abortaba el run y repetía su primer comando, una falsa cobertura por anti-loop.
Los Sessions de las regresiones D107/D110 se supervisan para evitar una carrera
entre `on_exit` y la caída de su proceso padre.

Evidencia: trece regresiones en rojo y una adicional de dueño anterior;
catorce nuevas en `game_combat_fallback_test.exs`, incluyendo Game/TestModel,
ataque comprometido y contexto del siguiente monstruo. **79** focalizadas y
suite **1992 passed / 3 excluded** (16,9 s), compile sin warnings, formato y
diff correctos. Logs `/tmp/dragonex-combat-fallback-*.log` y
`/tmp/dragonex-combat-quality-*.log`. Este ADR cubre recuperación; se revisa
por separado la validez de los relevos principales elegidos por el TM.

### D111 — La sala entra en mesa después de cualquier estado de inicio

**Estado: Aceptada (2026-10-01).** Un socket lento puede recibir el aviso de
inicio cuando Game ya está `:waiting` o `:paused`. La sala solo salía ante
`:running` y dejaba al invitado esperando aunque la partida hubiera empezado.
La transición comprueba ahora que el estado haya dejado de ser `:configuring`;
el montaje de la mesa vuelve a comprobar acceso e identidad como siempre.

Dos regresiones LiveView bloquean brevemente el socket y entregan las
notificaciones reales tras el Game esperar/pausar. Fallaron antes del cambio;
20 focalizadas pasadas y gate posterior **1994 passed / 3 excluded** (18,2 s).
No mutación de World ni nueva capacidad de inicio para el invitado.

### D112 — La declaración humana se puede leer por toque y teclado

**Estado: Aceptada (2026-10-01).** En la mesa compartida el texto literal
declarado estaba solo en `title` de un chip: móvil/teclado no podían consultarlo.
Se conserva la crónica compacta con un `details`/`summary` nativo por evento,
control de 44 px y foco visible. El texto completo aparece al abrirlo y Phoenix
escapa su HTML. La narración conserva párrafos y la identidad/ID del evento
permite mantener el disclosure abierto durante actualizaciones de la mesa.

Dos regresiones comprueban contenido literal, snapshot actualizado, escape y
narración. 28 focalizadas; gate **1996 passed / 3 excluded** (18,0 s), compile
sin warnings, formato y diff correctos. Navegador real a 375/1440 px: dos
cuentas propias, Mara/Lena, sala → unión → inicio → intenciones en pausa →
reanudación/resolución → consulta de ambas declaraciones → pausa/reload.
La invitada conserva Lena ante `?as=Mara…`/`?as=dm`, sin inspección DM ni ajustes.
El creador inspecciona DM y retorna a Mara. Disclosure abierto con Enter/toque,
sin errores JS ni overflow. Logs `/tmp/dragonex-{lobby,declaration,shared}-*.log`
y artefactos `/tmp/dragonex-playtest/shared-*`.

### D113 — La iniciativa impone el relevo principal sin consulta redundante

**Estado: Aceptada (2026-10-01).** Un `give_turn_to` válido podía saltar un
slot anterior o repetir un monstruo ya marcado; `pass_to_dm` podía saltar al
PC siguiente. D110 corregía la recuperación, pero no estas decisiones válidas.
En combate, Game impone ahora el primer slot pendiente del World a todo relevo
principal. Tras una reacción vuelve al dueño principal aún pendiente y conserva
su presupuesto. `cut_in`/`react` y `end_scene` siguen siendo excepciones explícitas.
Una intención de reacción conserva ese tipo incluso si el TM elige al mismo
humano mediante `give_turn_to`; no se convierte en otro turno principal.

Sin intenciones humanas ni re-eval/interrupción/mini-turn, el relevo ordinario
se aplica sin pedir una decisión al modelo: controlador y combatiente reales,
efectos/dados de inicio, cierre de combate, nota y persistencia habituales.
El Game sigue siendo el único escritor. Exploración conserva sus criterios
dramáticos y caminos D28/D30. `combat_handoffs: :turnmaster` es una opción de
diagnóstico/inyección para probar consulta, errores y captura D79; también
impone la iniciativa. No hay selector nuevo para el jugador ni campo nuevo
de Character/World/Codec.

Once regresiones/control nuevos en `game_combat_handoff_test.exs`: decisiones
fuera de orden/repetidas, reacción y retorno sin reembolso, contexto de dos
monstruos, contador de peticiones a cero, ronda nueva, intención ordinaria,
PC caído y cierre por aura antes de esperar. Las pruebas previas de consulta
usan la opción explícita; las fixtures de recuperación conservan un dueño
heredado fuera de orden. **76** focalizadas y **2007 passed / 3 excluded**
(18,2 s), compile sin warnings y formato correctos. Evidencia
`/tmp/dragonex-combat-handoff-*.log`. Reducir peticiones está probado;
la latencia del proveedor requiere mediciones reales adicionales.

### D114 — La rehidratación conserva el mini-turn pendiente

**Estado: Aceptada (2026-10-01).** `World.turn_kind`/`turn_owner` sobrevivían,
pero Bootstrap perdía `pending_mini`/`interrupted`. Reabrir una reacción en
pausa hacía que el siguiente beat, incluso fallido, marcara el turno principal
del reactor. Ahora esos indicadores se reconstruyen del World persistido;
no se añaden campos durables ni se vuelven a ejecutar efectos de inicio.

Cuatro regresiones en rojo/verde con Game/TestModel/Postgres cubren humano,
PC IA, monstruo controlado por DM y fallo después de comprometer Escudo.
El ledger conserva solo los principales anteriores; la casilla/reacción
gastadas permanecen y el dueño recupera su turno sin renovar Segundo aliento
ni el presupuesto. **42** focalizadas, **2011 passed / 3 excluded** (18,3 s),
compile sin warnings, formato/diff correctos. Evidencia
`/tmp/dragonex-reaction-rehydration-*.log`.

### D115 — La presencia de escena es durable y distinta de los PG

**Estado: Aceptada (2026-10-01).** La huida del goblin del playtest se narró
sin retirarlo del World; seguía siendo objetivo/hostil. `leave_scene(who, reason)`
y `return_to_scene(who)` registran ahora presencia explícita de no-PCs, solo
para DM. Son transiciones de escena; no deciden una huida ni sustituyen las
acciones/chequeos que correspondan. Los PCs permanecen en el grupo. Un chequeo
genérico o una narración por sí solos siguen sin alterar presencia.

`World.absent_characters` guarda motivos scrubbed/acotados; Codec conserva
compatibilidad con mundos anteriores. `World.character` sigue leyendo la
ficha almacenada y el reloj sigue caducando sus efectos. Consultas de escena,
acciones/objetivos, áreas, auras, iniciativa, control y briefs usan presencia.
Salir termina la concentración y sus efectos de fuente, sin poner PG a cero
ni curar estados entrantes. Eliminar un objetivo invalida las acciones ya
preparadas, incluida la transición de daño y módulos de soporte.

Salir retira su posición activa; si es el dueño principal actual termina ese
turno. Volver usa la misma ficha/PG/casillas y se incorpora al final del combate
como otros refuerzos, conservando presupuesto/ledger del asalto. No se puede
recrear con `spawn_monster` el mismo nombre para recuperar PG/recursos.
Game liquida el encuentro cuando ya no hay oponentes presentes; retorno de
un hostil en exploración usa el inicio automático existente. Persistencia y
fallos mantienen el single-writer; Character/Weapon/Spell/Item no cambian.

23 pruebas nuevas en `scene_presence_test.exs`/`game_scene_presence_test.exs`,
incluidos JSON legado, efectos, objetivos adicionales, roles, reentrada tras
reabrir y fallo después de salida comprometida. **52** focalizadas y
**2034 passed / 3 excluded** (18,5 s), compile sin warnings, formato/diff
correctos. Arena real propia `/games/16629`: Magic Missile deja la diana en
8/20 PG y Mara con una casilla; retirada termina combate, reentrada conserva
8/20 y la casilla. Pausa/reload, 375/1440 px sin errores JS ni overflow.
Evidencia `/tmp/dragonex-scene-*.log` y `/tmp/dragonex-playtest/presence-*`.

### D116 — Iniciativa automática con dados y transición tras fallo

**Estado: Aceptada (2026-10-01).** El retorno real de la diana abrió combate,
pero sus tiradas automáticas no llegaban al historial/modal. Además, un fallo
terminal del actor después de introducir un hostil conservaba el monstruo
en exploración. Game registra ahora esa iniciativa con su roller/RollLog y
publica los grupos factuales solo después de aplicar la transición por Session.
El mismo publicador sirve a los efectos de inicio de turno, manteniendo su
metadata; la iniciativa automática usa `timing: "forced_initiative"`.

El fallo terminal comprueba los hostiles nuevos antes de recuperar el relevo.
No consume el primer slot aún sin actuar. Se mantienen las guardas de fase,
hostiles introducidos y escritor admitido; una iniciativa explícita no se
duplica y un enemigo preexistente no dispara combate por sí solo. Retries
transitorios y de tokens conservan su camino. No cambian World/Codec ni las
fichas del dominio.

Cinco pruebas nuevas en rojo/verde, con Game/TestModel/Postgres, dados exactos,
eventos PubSub/historial únicos y controles de guardas. **39** focalizadas y
**2039 passed / 3 excluded** (18,7 s), compile sin warnings, formato/diff
correctos. Arena propia `/games/16629`: retirada/retorno de la misma diana,
iniciativa automática visible en crónica y modal (Mara 1+2=3, diana 10−4=6),
sin duplicados; conserva 8/20 PG y la casilla de Mara. Pausa/reload a 375 px,
sin errores JS ni overflow. Evidencia `/tmp/dragonex-forced-initiative-*.log`
y `/tmp/dragonex-playtest/forced-dice-live.log`.

### D117 — Asistentes operables por teclado con selección y texto conservados

**Estado: Aceptada (2026-10-01).** Tarjetas `div phx-click` de identidad,
trasfondo, atributos, equipo, escenario y héroe quedaban fuera del recorrido
con Tab. Ahora son botones nativos `type="button"`, con `aria-pressed`, IDs
estables y contenido de texto equivalente. Se conserva el diseño pixel D84.
Opciones ya ocupadas por compañeros quedan deshabilitadas. Hechizos,
habilidades, idiomas y equipo propio anuncian también su selección; inputs
tienen etiquetas asociadas y controles pequeños de los asistentes alcanzan
44 px. Los dados se describen por su comportamiento para el jugador.

El cliente LiveView añade `HTMLButtonElement.value` después de `phx-value-*`,
sobrescribiendo `phx-value-value`. Los botones de selección declaran ambos
valores iguales; una regresión reproduce esa metadata del navegador. El
asistente de partida inicializa los campos custom y pinta sus assigns al
volver atrás o cambiar temporalmente de escenario, conservando el borrador
de la sesión. No implica persistencia tras cerrar/recargar el asistente.

Seis regresiones nuevas, **32** focalizadas y **2045 passed / 3 excluded**
(19,9 s), compile sin warnings y formato/diff correctos. Navegador real con
Tab/Enter/Espacio: Iria del Alba, clériga humana, guardada/reabierta como
`/heroes/5425`; point buy, habilidades, idioma, equipo y hechizos. Partida
propia `/games/17032`, texto custom conservado, Mara/Vex IA y pausa/reload.
375/1440 px sin JS/overflow; selección mantiene foco. Verificación adicional
confirma URLs/ficha, y lectura de Postgres confirma título/escena/estilo.
Evidencia `/tmp/dragonex-wizard-*.log` y `/tmp/dragonex-playtest/wizard-*`.

### D118 — Grupo completo y presencia factual en las fichas de mesa

**Estado: Aceptada (2026-10-01).** Exploración ordenaba todas las fichas por
nombre y tomaba cuatro, aunque el grupo admite seis PCs. Un PNJ retirado
conservaba PG y seguía apareciendo. La proyección usa ahora personajes
presentes, conserva todos los PCs (incluidos caídos) y pone la ficha propia
primero. Añade como máximo dos fichas de escena no-PC vivas para acotar ese
suplemento; ninguna desplaza al grupo. Los dos carriles D84 mantienen su
anchura y reparten las fichas alternadas con scroll natural.

En móvil, un `details` nativo de compañeros dentro del cajón muestra PG,
CA y estados de los demás PCs en exploración/combate; el DM creador puede
consultar el grupo completo. `JS.ignore_attributes("open")` conserva solo
la apertura elegida por el jugador ante patches, mientras los datos internos
siguen actualizándose. No se congela el contenido ni se escribe World desde
la vista. La ficha detallada propia conserva su lugar y controles.

Siete pruebas nuevas: seis reproducciones en rojo/verde y ataque real del
DM que actualiza los PG de un compañero vía Game/Postgres/LiveView. **26**
focalizadas y **2052 passed / 3 excluded** (21,2 s), compile sin warnings,
formato/diff correctos. Mesa propia `/games/17373`, Iria con cinco PCs IA:
seis fichas a 1440/1024 px, compañeros/DM a 375 px, apertura conservada tras
intención/borrado por PubSub, pausa/reload, sin JS/overflow. La diana retirada
en `/games/16629` desaparece de fichas; sigue almacenada a 8/20 PG, Mara con
una casilla. Evidencia `/tmp/dragonex-party-*.log` y artefactos
`/tmp/dragonex-playtest/{party-*,presence-cards-*}`. El nuevo setup real reveló
diálogo inventado de Lyra por el DM; se conserva para la siguiente regresión.

### D119 — Gestos y citas de PCs retirados de la voz del DM

**Estado: Aceptada (2026-10-01).** La apertura real de seis PCs conservó
`Lyra… alza` seguido de una cita propia y `Nera… afina`. Se guarda el evento
literal como fixture. El recorte/detector reconoce estos predicados directos
con aposición opcional, junto con `comenta`; no atribuye a un PC el gesto de
un PNJ posterior en la misma frase. Conserva estados pasivos y la voz del
PC cuando es su propio actor.

Una cita sin hablante explícito conserva la atribución al PC cuya acción
se acaba de retirar, incluso si hay varias citas seguidas o streaming
incompleto. Una atribución explícita a PNJ o una cláusula de mundo cambia
ese contexto. `comenta` distingue también al hablante en una cita explícita.
Events e historial compartido pasan por el mismo recorte. No se reescriben
eventos históricos ni se pretende resolver toda variante de prosa libre;
el tratamiento D29 de otras acciones a mitad de cláusula conserva sus límites.

Nueve pruebas nuevas, incluido Game/TestModel/historial compartido y prefijos
de streaming; **61** focalizadas y **2061 passed / 3 excluded** (21,5 s),
compile sin warnings, formato/diff correctos. La prueba positiva de rutas
protegidas escribía usuarios fuera de sandbox y chocó con un correo de otra
ejecución: ahora comparte una transacción aislada con el socket y usa UUID.
Evidencia `/tmp/dragonex-puppet-{gesture,speaker}-*.log`.

Mesa real `/games/17373`: pedir opinión a Nera/Lyra tarda **14,05 s**, pero
los eventos muestran Iria → DM → Iria, sin respuesta de los agentes pedidos.
Conserva PG y dos casillas de Iria/Lyra/Mara, pausa/reload sin JS/overflow.
Ese recorrido descubrió la segunda cita implícita, ahora cubierta por la
regresión de atribución continuada, y un fallo de coordinación que sigue
abierto. `/tmp/dragonex-playtest/party-dialogue-{live,state}.log`.

### D120 — Respuestas propias de compañeros mediante petición declarativa

**Estado: Aceptada (2026-10-01).** La pregunta real de Iria a Nera/Lyra
volvía por DM a Iria sin ejecutar sus agentes. D28 fuerza PC → DM y D30
devuelve preguntas al humano; un recorte de prosa no concede esos turnos.
Se añade `request_response(recipients, question)`: el modelo interpreta la
declaración y registra destinatarios canónicos, pero el motor valida la
petición y aplica los relevos. El hablante se toma del handle admitido del
Session, nunca de un argumento inventado. El DM puede usarla al resolver
la declaración de un PC humano; actuando como `dm` queda rechazado.

Solo exploración, 1–5 PCs distintos, presentes, capaces de actuar y
registrados en el Session, sin self/PNJs. Pregunta scrubbed/acotada a 800
caracteres. `World.conversation` conserva origen, destinatarios, pendientes,
pregunta y etapa (`responses`/`world`/`return`); Codec admite JSON anterior
y descarta formas inválidas. Reintentos idénticos no reinician el cursor;
una petición distinta mientras se responde queda rechazada. El Game
liquida cada respuesta o fallo terminal una vez, da un cierre al DM y
devuelve la palabra al humano que preguntó. Un origen IA no gana otro turno
automático; prosigue D28/D30. No se infieren destinatarios con regex de prosa.

Intenciones humanas tienen prioridad; re-eval, mini/interrupted y combate
conservan su camino. Escena nueva o combate cancelan la petición. Reanudar
sobre un destinatario caído lo omite antes del beat, sin death save. Contexto
compartido contiene pregunta y voces previas; el cierre no inventa respuestas
de quien falló. Transiciones por Game/Session, sin mutación desde LiveView.
Los relevos ya determinados no consultan al TM (TestModel observado).

**24 pruebas nuevas**, **49** focalizadas y **2085 passed / 3 excluded**
(22,0 s), compile sin warnings, formato/diff correctos. Incluyen recursos,
orden, roles, schema, JSON/World en memoria anteriores, humano esperando,
pausa tras primera respuesta, errores de origen/respondedor/DM, intervención
humana con re-eval muda y cancelación/incapacidad. Dos reproducciones extra
detectaron el turno del caído al reabrir y el aviso `a dm`, ya corregidos.
Evidencia `/tmp/dragonex-conversation-*.log`.

Mesa propia `/games/17373`, agentes reiniciados desde Ajustes con la misma
selección: **Iria → Nera → Lyra → DM → Iria**, **25,26 s**. Cada compañero
responde con su propio evento. PG, casillas, escena y reloj conservados;
petición liquidada, pausa/reload a 375/1440 px sin JS/overflow. Lectura de
Postgres sin segundo Game escritor. `/tmp/dragonex-playtest/conversation-*`.
Es una muestra con ese proveedor; reconocer la pregunta y llamar la tool
sigue siendo tarea del modelo, no una garantía sobre cualquier prosa/modelo.
El aviso final al DM y compatibilidad de World en memoria se verificaron
después con las regresiones; los eventos históricos no se reescriben.

### D121 — La admisión valida la sala vigente y permite corregir la elección

**Estado: Aceptada (2026-10-02).** `join_game` leía estado/plazas/participantes
de una fila suministrada anteriormente: la última plaza podía reutilizarse y
un World iniciado sobrescribirse. Un nombre duplicado levantaba una excepción;
la LiveView guardaba `join_error`, pero la sala no lo renderizaba. Un ID inválido
o una sala eliminada desconectaban al jugador.

Unión e inicio bloquean la misma fila con `FOR UPDATE` y releen sus relaciones
dentro de una transacción. Solo `:configuring` admite un PC; una unión actualiza
World/plazas una vez y conserva las fichas existentes. Nombre ambiguo (incluye
case/espacios exteriores y `DM`) devuelve `:name_taken` y revierte todo. Un
reintento conserva identidad; inicio repetido conserva estado/cursor/intenciones.
Tras inicio, World sigue siendo propiedad del Game, conforme D6.

La sala muestra motivos recuperables y el estado vigente; elegir otro héroe
limpia el aviso. El selector acepta solo IDs casteados positivos y héroes
propios. La desaparición de la sala en unión, inicio o aviso PubSub vuelve a
partidas con flash. La comprobación de teclado móvil detectó el error fuera
de viewport: se sitúa junto al selector y se enlaza con `aria-describedby`.

**18 pruebas nuevas** de contexto/LiveView: copias obsoletas, última plaza,
dos uniones, rollback por nombre, idempotencia, sala iniciada/eliminada e IDs.
Son casos deterministas sobre snapshots; no una prueba de carga simultánea.
Con D122, **35** focalizadas y **2106 passed / 3 excluded** (30,3 s) en base
separada, compile sin warnings, formato/diff correctos.
`/tmp/dragonex-lobby-isolated-{focus,full}.log`.

Dos cuentas reales en `/games/19212`: error completo visible a 375 px → Enter
→ plaza/grupo compartidos → recarga, sin JS/overflow a 375/1440 px. Queda
configurada, sin llamar al modelo. `/tmp/dragonex-playtest/lobby-admission-*`;
`lobby-admission-viewport-red.log` registra la reproducción visual anterior.

### D122 — La base de pruebas no hereda el nombre de desarrollo

**Estado: Aceptada (2026-10-02).** El gate D121 vio una sala creada por el
navegador: `runtime.exs` cargaba `.env.dev` y usaba `DB_NAME` en dev y test,
anulando `dragonex_test` de `config/test.exs`. Sandbox revierte los tests
normales, pero no separa sus lecturas de las salas reales ni evita fixtures
fuera de transacción. Pasar `MIX_ENV=test` no bastaba.

Runtime de test usa `DB_TEST_NAME` explícito o `dragonex_test`; ignora
`DB_NAME` tanto del archivo como del shell/wrapper. Dev conserva `DB_NAME`.
Host/puerto/usuario/contraseña pueden compartir servidor Postgres; la base es
distinta. No se modifica el archivo privado ni producción. Se documenta
preparación con `MIX_ENV=test mix ecto.create`/`mix ecto.migrate`.

Tres pruebas evalúan el runtime real para DB_NAME heredado, override de test
y dev; restauran el entorno del proceso al terminar. Dos fallaban antes del
cambio. Base nueva creada y ocho migraciones aplicadas; **2106 passed /
3 excluded** (30,3 s), **35** focalizadas con D121. La sala de ambas cuentas
en desarrollo conserva plazas/personajes tras recarga. Compile sin warnings,
formato/diff correctos. `/tmp/dragonex-repo-config-red.log`,
`dragonex-test-db-{create,migrate}.log`, `dragonex-lobby-isolated-*.log`.

### D123 — Un PC conserva su voz y no narra acciones de otros PCs

**Estado: Aceptada (2026-10-02).** El evento real de Iria contenía
`Luego giro la cabeza hacia Lyra, que sigue hojeando sus pergaminos.`:
inventa un gesto de otra PC dentro de la pregunta propia. Se guarda el texto
como fixture. D29 solo recortaba PCs cuando el actor era DM; aplicar ese
recorte sin más también reveló que el matcher buscaba cualquier verbo a
80 caracteres y borraba `Lyra está herida mientras Sena abre la puerta`.

Con `pc_names` de World, la narración PC aplica el recorte a los demás PCs,
excluyendo al actor real. Su voz/gestos permanecen; acciones/citas ajenas y
la atribución implícita siguiente se retiran. El DM conserva el recorte de
todos los PCs. Eventos/streaming comparten Text; el siguiente agente recibe
los eventos ya limpios, sin reescribir historia anterior.

El predicado debe pertenecer inmediatamente al sujeto, con aposición o `ya`
opcionales. El detector de recordatorios usa el mismo criterio, sin prestar
el verbo de un PNJ posterior a un PC pasivo. Relativas `PC, que <acción>` se
recortan localmente hasta coma/fin de frase, con cuerpo acotado a 180 caracteres;
se conservan el nombre y las preguntas propias. `hojea`/`sigue hojeando` amplían
la lista curada del caso real. No es un parser de prosa universal: otros
gestos, adverbios y acciones mid-cláusula conservan los límites de D29.

Nueve pruebas Text/streaming y dos Game/TestModel, **11 nuevas**. Verifican
fixture real, preguntas, citas propias/ajenas, positivos de estados/PNJ,
nombres escapados, idempotencia y el historial del siguiente agente con PG/
casillas/persistencia conservados. Rojo/verde del falso sujeto adicional.
**85** focalizadas, **2117 passed / 3 excluded** en base separada (30,4 s),
compile sin warnings, formato/diff correctos. `/tmp/dragonex-pc-voice-*.log`,
`dragonex-pc-subject-red.log`.

Mesa propia de seis `/games/17373`: otra pregunta explícita produce
**Iria → Nera → Lyra → DM → Iria** en **17,12 s**, sin cambiar PG/casillas/
escena/reloj; cola liquidada. Pausa/reload a 375/1440 px sin JS/overflow.
Lectura de Postgres sin otro Game escritor. `/tmp/dragonex-playtest/pc-voice-*`.
La fixture demuestra el recorte de esa fuga; la muestra real verifica actores
y continuidad, sin prometer que el proveedor repita una forma concreta.

### D124 — La progresión amplía capacidad y conserva gasto de casillas

**Estado: Aceptada (2026-10-02).** R08/AC-8.4 y las docs de merge prometían
conservar casillas usadas, pero World.level_up y Games.merge reemplazaban
el pool por la tabla llena. Una maga agotada recibía tres casillas al subir
de L1 a L2 y un brujo recuperaba el pacto al cambiar su nivel. Dos tests
antiguos codificaban esa reposición; se corrigen junto con la lógica, siguiendo
el contrato de conservación. Subir no equivale a un descanso.

`SpellSlots.level_up/4` es puro y compartido por ambas entradas. Casters
normales conservan gasto por nivel: los disponibles suman a su valor anterior
el aumento de capacidad de la tabla. Se añaden niveles nuevos y half-casters desbloquean
su tabla. Las casillas pagadas con Fuente de magia se conservan, aunque excedan
la tabla o estén en un nivel sin capacidad diaria todavía. Pact Magic traslada
el gasto total del pool activo a su nuevo nivel, descartando la clave antigua;
un pool agotado sigue agotado salvo capacidad adicional nueva.

Un mundo legacy sin pool registrado se inicializa con la tabla nueva; una
clave ausente dentro de un pool registrado equivale a cero disponibles.
Repetir un merge al mismo nivel conserva el gasto. No se añaden campos de
Character/World/Codec. HP/condiciones/flags/pools planos/reloj/rest_state quedan
en su camino existente; los dados de golpe nuevos se derivan de level sin
reponer los ya usados. El descanso real mantiene su propia validación y
recarga, incluyendo el límite diario.

**16 pruebas nuevas** (13 motor, dos Game y una LiveView), **89** focalizadas
y **2133 passed / 3 excluded** (30,9 s) en base separada. Incluyen todas las
familias de caster, promoción/crecimiento de pacto, Fuente de magia real,
legacy, idempotencia, codec, largo real y límite diario; Game/TestModel usa la
tool del DM y el jugador confirma desde web por el único Game escritor.
Pausa/reapertura conserva gasto y dados. Compile sin warnings, formato/diff
correctos. `/tmp/dragonex-level-resources-{root,funded-red,green,full}.log`.
El playtest de Mara está preparado; el recorrido de navegador continuará con
la revisión de confirmaciones obsoletas, sin atribuirlo a este gate offline.

### D125 — Una confirmación aplica el nivel visto y ninguna sync lo rebaja

**Estado: Aceptada (2026-10-02).** Dos LiveViews de un héroe L1 confirmaban
sucesivamente L2 y L3 sin volver a revisar la ficha. Una sheet antigua enviada
al merge/Game podía rebajar el nivel vivo, sus máximos y reservas; además,
Games escribía World iniciado si no había proceso, fuera del escritor D6.

La web envía `expected_level` desde la ficha montada. Accounts bloquea/relee
la fila del héroe dentro de transacción antes de comparar y aplicar elecciones:
expectativa válida distinta devuelve `:stale_level`, malformed `:invalid_level`.
`grant_xp` usa el mismo bloqueo para conservar ficha/XP ante una subida.
La API sin expectativa sigue permitiendo una subida explícita por llamada;
no se impone un umbral nuevo ni cambia la política milestone de R08.

El Game valida el nivel contra su World dentro de Session.update_state;
un nivel anterior no toca World ni `characters.sheet`. El merge puro devuelve
el mundo anterior ante ese dato. Games enruta toda partida iniciada por su
Game canónico, arrancándolo si falta; el fallback directo queda solo para
`:configuring`, con bloqueo/relectura compartido con start_game. Si el inicio
se adelanta, libera transacción y llama al Game. Sync de nivel igual conserva
idempotencia y gasto según D124; no añade campos de Character/World/Codec.

La pestaña obsoleta vuelve a ficha con mensaje de revisión. El layout de
LiveView no renderizaba flash alguno: se muestran info/status y error/alert,
con cierre nativo de 44 px por teclado, sin desaparecer antes de leerlo.
Confirmar se deshabilita durante envío. Los errores de sync se registran;
no se promete reintento automático para un timeout que el bucle no implementa.

**6 pruebas nuevas**, **45** focalizadas, **2139 passed / 3 excluded**
(31,5 s), compile sin warnings, formato/diff correctos. Rojo/verde de
confirmación, merge/Game antiguo y flashes de info/error con seguimiento de
redirección. Sala preinicio, Game ausente, pausado/reabierto y XP comprobados.
Las copias obsoletas deterministas verifican rechazo; no son estrés de dos
conexiones independientes. `/tmp/dragonex-level-{confirmation,monotonic,flash}-*.log`.

Navegador propio: Mara `/heroes/5164` L1 → L2 desde una pestaña y rechazo de
la otra, aviso visible/cerrado por Enter. **8/14 PG**, **2/2 d6**, capacidad
adicional exacta en seis mesas pausadas: 1 → 2 en dos, 2 → 3 en cuatro.
Escena/reloj/PG/rest_state/fase/pausa/cursor conservados por lectura de Postgres
sin otro Game escritor. Arena/ficha y recarga a 375/1440 px sin JS/overflow.
`/tmp/dragonex-playtest/level-up-*`.

### D126 — Pools de clase amplían capacidad conservando gasto, también al desbloquearse

**Estado: Aceptada (2026-10-02).** Heroes.build entregaba ki/puntos de
hechicería/usos de Forma salvaje a nivel 2; LevelUp mantenía el cero de L1,
por lo que el recién desbloqueado no podía usarse hasta descansar. Imposición
de manos y los usos por Carisma tampoco ganaban capacidad disponible al subir.
La ficha no mostraba esos pools. Se extiende el criterio de D124 a reservas
planas; **sustituye la conservación literal del número remaining** al progresar
que codificaban D49/D50/D52/D54/D56/D63, preservando su gasto y reglas de descanso.
No se amplían las mecánicas ni las subclases declaradas fuera de alcance.

`ClassResources.capacities/1` deriva los seis máximos ya modelados de
clase/nivel/Carisma. `level_up/2` suma solo el incremento de capacidad al
remaining vivo; LevelUp usa la ficha anterior y Games.merge usa el Character
del World, sin copiar un pool lleno de la biblioteca. Monje/hechicero/druida
L1 → L2 reciben dos; ki/hechicería L2 agotados → L3 reciben uno, no tres;
paladín L1 remaining 2 → L2 remaining 7; ASI de CHA aporta un uso solo al
cruzar el modificador relevante. Cap/ASI sin cambio no reponen nada.

Una reserva nil/legacy cuenta como cero disponible, sin inventar una recarga.
Sync al mismo nivel/atributos conserva idempotencia y Codec mantiene campos
existentes. PG/condiciones/reloj/rest_state/flags/ledger no reciben descanso;
Fuente de magia conserva la casilla pagada según D124 y gana solo el punto del
nivel. Rest real sigue recargando según la clase. No cambia ninguna forma
Character/Weapon/Spell/Item/World ni añade DB al builder.

Ficha propia de mesa/drawer muestra disponible/máximo de los pools positivos
según World; L1 sin feature no parece desbloqueado. El estado agotado usa
`--text-dim` para conservar legibilidad sobre piedra D84. No cambia control
ni otorga turnos. Persistencia y PubSub comprueban valores, no prosa del modelo.

**16 pruebas nuevas** (12 motor, dos Game y dos web), **238** focalizadas,
**2155 passed / 3 excluded** (32,1 s), compile sin warnings y formato/diff
correctos. Ki/Font/Shape recién ganados ejecutan sus Actions sin descanso;
gasto real/ASI/cap/merge/codec/rest/reapertura y DM/TestModel/tool verificados.
Se ajustan cuatro expectativas antiguas de remaining exacto y una de puntos
tras casilla pagada, sin reponer los consumos previos.
`/tmp/dragonex-class-{progression,sheet}-*.log`.

Navegador propio: Sira `/heroes/5898`, `/games/19419`, L1 → L2; **2/2 → 0/2
puntos**, **3 → 4 casillas**, **8/14 PG**, reloj 0/rest_state vacío, pausa/cursor
conservados. **31,29 s** al siguiente humano; ficha/recarga a 375/1440 px sin
JS/overflow. Estado assertado con lectura de Postgres sin otro Game escritor.
`/tmp/dragonex-playtest/class-{progression,pool}-*`. La apertura usa el nombre
corto `Sira` para inventar una acción: nueva regresión narrativa pendiente,
no corregida ni reescrita por este trabajo de reservas.

### D127 — Nombres cortos únicos y atribuciones completas antes de retirar acciones ajenas

**Estado: Aceptada (2026-10-02).** La apertura real de `/games/19419` inventó
`cuando Sira deja caer la última chispa…`; el filtro conocía solo el nombre
canónico `Sira de la Chispa` y no esa subordinada. Una segunda reproducción
mostró que `Lyra` se atribuía citas de `Lyra del Mar` o `Lyra del Muelle`;
la limpieza del nombre propio también podía convertir el nombre ajeno en
`Del Mar`, escapando al recorte posterior.

Text deriva la primera palabra (al menos tres caracteres, empezando por
letra y permitiendo apóstrofo/guion) de nombres compuestos solo si tiene un propietario único entre
nombres registrados. Los nombres canónicos se deduplican sin distinguir mayúsculas;
si el nombre corto es ambiguo, no se infiere propiedad. `pc_names` fija quién
se puede retirar, `character_names` aporta el roster completo de World y el
actor siempre conserva sus propias formas. Se prioriza el nombre completo
más largo en citas y limpieza de encabezado; un PNJ con prefijo de PC conserva
su voz cuando narra el DM. El PC conserva su propia atribución corta.

`cuando`/`mientras <PC> <predicado proactivo inmediato>` se retiran localmente,
con límite de 180 caracteres hasta coma/puntuación/cita/salto. El caso real
mantiene la frase de ozono y el mensajero; voz propia, preguntas y estados
pasivos se conservan. Fronteras de nombre usan letras/números Unicode para
no confundir `Éowyn` con un fragmento de `SuperÉowyn`. Streaming de mesa,
Events y detector reciben el roster de World. Events usa el contexto al
inicio del beat; D131 lo amplía después con el World comprometido de cada
respuesta y refresca la mesa antes de la siguiente petición al modelo.

No interpreta pronombres, homónimos ambiguos, PNJs no registrados ni toda
la gramática libre; siguen los límites de D29. No transforma ni vuelve a
sanitizar eventos históricos. No cambia World, structs, schemas ni reglas.

**17 pruebas nuevas** (13 puras, dos Game/TestModel, dos web), **114**
focalizadas y **2172 passed / 3 excluded** (31,9 s), compile sin warnings,
formato/diff correctos. Fixture exacto, persistencia/historial, PG/recursos/
escena/reloj/rest_state y burbuja LiveView comprobados. Reproducciones
rojas/verde en `/tmp/dragonex-short-name-*.log`. No se atribuye a este gate
una obediencia universal del proveedor ni un nuevo recorrido live.

### D128 — La reserva que ven los agentes es la reserva viva de la ficha

**Estado: Aceptada (2026-10-02).** El brief enumeraba armas/hechizos/casillas,
pero omitía ki/hechicería/usos de Forma salvaje y los restantes pools D126.
Los prompts describen sus herramientas; sin reserva factual, el modelo no
veía de forma explícita que estaban agotadas. La validación del motor ya
rechazaba el gasto, pero el contexto debía permitir proponer con ese dato.

`ClassResources.pools/1` centraliza labels/orden/capacidad/remaining de los
seis pools desbloqueados. Brief y mesa lo comparten, leyendo el Character
vivo. Remaining nil/inválido se muestra como cero conservador, sin escribir
ni inicializarlo; capacidad cero no se ofrece como desbloqueada. Valores
positivos no se recortan al máximo. No hay DB en ese módulo ni nuevas formas.

Brief incluye dados de golpe desde Rest/ledger de World, flags de Segundo
aliento/Oleada de acción/Recuperación arcana/Canalizar divinidad con sus
niveles modelados, y forma animal activa/bloqueo de conjuros. No promete
cubrir todos los recursos raciales/clase: el alcance son esos pools/flags.
Ausentes no aportan reservas de escena y PNJs comunes no adquieren dados de
PC. El siguiente beat recibe el World actual tras pagar; el brief compacto
TurnMaster no crece ni cambia decisiones. Las tools siguen siendo el árbitro.

**17 pruebas nuevas** (14 puras, dos smokes DM/PC, un Game), **62** focalizadas,
**2189 passed / 3 excluded** (32,3 s), compile sin warnings y formato/diff
correctos. Game declara la conversión como humano, usa el servidor del DM
para resolverla y verifica la reserva del siguiente beat. Constructor de
agente con ficha anterior no sustituye el WORLD vivo. `/tmp/dragonex-resource-context-*.log`.

Pregunta real de Sira `/games/19419`: reconoce puntos agotados sin gastar,
**16,08 s** al humano, **0/2** puntos/cuatro casillas/**8/14 PG**. Character
completo/escena/reloj/rest_state/pausa/cursor/intenciones iguales en Postgres
antes/después, sin crear otro Game escritor. Ficha/reload 375/1440 px sin
JS/overflow; `/tmp/dragonex-playtest/resource-context-*`. No afirma toda
obediencia futura del proveedor ni reescribe narraciones históricas.

### D129 — Progresar al druida original conserva la bestia activa y su caducidad

**Estado: Aceptada (2026-10-02).** LevelUp calculaba máximo/CON/ASI/CA sobre
el Character físico de la bestia y dejaba el snapshot original antiguo;
merge de biblioteca sobrescribía esa bestia con estadísticas nativas y
sumaba su diferencia de CON a PG animales. Revertir perdía la progresión
física. Una segunda reproducción detectó que cambiar el snapshot reiniciaba
la duración: a elapsed 1800, L3 → L4 pasaba deadline 3600 → 9000.

`WildShape.base_form/1` lee la ficha original guardada, conservando el resto
del estado vivo. LevelUp aplica ahí progresión/ASI/vitalidad/AC/hechizos;
`preserve_form/2` guarda ese resultado dentro del snapshot y devuelve la
bestia con sus mismos PG/máximo/STR/DEX/CON/CA/armas. Mental/nivel/XP/hechizos/
features continúan en el Character. Games.merge usa esa base viva antes de
calcular retroactivo, conserva gasto y aplica la misma preservación de forma.
No cura bestia ni repone usos al progresar por niveles sin capacidad nueva.

Reversión manual/daño/caducidad comparten la lectura de forma original. El
exceso de daño llega a PG nativos progresados; ASI de CON aporta vitalidad
nativa según D13, sin curar a la bestia. Conjuros siguen bloqueados hasta
revertir; el hechizo nuevo puede usarse en forma original. Snapshot utiliza
los campos existentes D63: no cambia Character/World/Codec/schema.

WorldClock distingue cambio de estadísticas guardadas de una transformación
nueva: dos maps de la misma bestia mantienen deadline. Inicio/reversión/nueva
bestia mantienen el seguimiento habitual; subir no amplía el tiempo de un
uso ya iniciado. Merge repetido, codec y reapertura conservan ambas formas,
ledger y reloj. La biblioteca se sincroniza por su Game canónico (D125).

**12 pruebas nuevas** (nueve puras, dos Game/TestModel, una web), **158**
focalizadas y **2201 passed / 3 excluded** (32,8 s), compile sin warnings,
formato/diff correctos. Reproducciones rojas/verde de stats y deadline,
CON/DEX/mental/spells, bloqueo/reversión/daño, biblioteca/humano/DM/pausa/
reapertura y ficha web. Fixtures bestia **6/11** → nativa **7/29**, no un
nuevo recorrido live. `/tmp/dragonex-wild-progression-*.log`. Identificación
de forma activa y vitalidad original entregadas después por D130.

### D130 — La ficha distingue bestia activa y PG originales guardados

**Estado: Aceptada (2026-10-02).** Tras D129, la mesa seguía mostrando los
PG/CA de bestia bajo la identidad humana sin identificar la transformación.
Ahora un distintivo antes de la barra de vida indica «Forma de lobo» (o
gato/oso negro) en resumen, detalle móvil y tracker. `WildShape.beast_name/1`
comparte los nombres con el resultado de Actions; forma desconocida usa
«bestia», sin imprimir keys técnicas.

La ficha propia lee `orig_hp/orig_max_hp` del World y muestra «Forma original»
por separado; datos incompletos usan «Sin registrar». No reconstruye PG de
biblioteca ni cambia snapshots. Conjuros conocidos siguen visibles con la
indicación de volver a forma original para lanzarlos. La reversión elimina
distintivo/fila/aviso. Resúmenes de compañeros muestran la forma activa,
manteniendo la reserva original en la ficha propia. Sin nuevos campos ni CSS.

**Tres casos nuevos**, ampliación del recorrido LiveView D129 y **69**
focalizados; **2204 passed / 3 excluded** (33,0 s), compile sin warnings,
formato/diff correctos. La prueba real descubrió una segunda omisión: el
aviso se había añadido al detalle pero exploración usa el resumen; se
reproduce rojo y cubre ambos. `/tmp/dragonex-shape-sheet-*.log`.

Sylvi `/heroes/5899`, `/games/19420`, creada y progresada por navegador:
L2 lobo **11/11**, L3 conserva bestia y guarda **10/24 PG** nativos; vuelve
a estos PG/CA 15 por declaración resuelta con tools. Uso 1/2, casillas 4/2,
reloj 0 y ledger vacío conservados; deadline 3600 no se renueva y desaparece
al revertir. Capturas/reload 375/1440 px sin JS/overflow, **14,53/19,06 s**
al humano; lector de Postgres sin Game escritor adicional verifica estados.
`/tmp/dragonex-playtest/wild-shape-*`. El tono tranquilo no se mantuvo en la
última narración DM (aullido amenazante); no se afirma obediencia general.

### D131 — La limpieza narrativa y el preview conocen altas del mismo beat

**Estado: Aceptada (2026-10-02).** El contexto D127 fijaba los personajes al
inicio del beat. Si una tool creaba `Lyra del Muelle` y la siguiente respuesta
la hacía hablar, Events la confundía con la PC `Lyra` y borraba su cita. Con
`Mara del Río`/`Mara de la Bruma` mantenía además un alias corto ya ambiguo.

Events lee SharedState de solo lectura antes de persistir cada respuesta y
usa PCs/roster completos del World comprometido. Antes de cada petición,
compara ese contexto con deps.beat: si cambió, lo actualiza dentro del run y
publica `game_updated` para que la mesa lea el snapshot actual antes de nuevos
deltas. No escribe World, no cambia turno/phase/round del beat y no obtiene
identidades de los argumentos propuestos por el modelo. La lectura fallida
por sesión cerrada o contexto standalone conserva el snapshot disponible.

**Cinco casos nuevos**: tres Game/TestModel (prefijo canónico, homónimo
corto, alta no comprometida), fallback sin handle/inválido/cerrado y mesa
detenida después del alta antes de narrar. Persistencia/historial, ficha/
streaming/reload, ambigüedad y recursos verificados. **60** focalizados,
**2209 passed / 3 excluded** (33,4 s), compile sin warnings y formato/diff
correctos; dos reproducciones rojas. `/tmp/dragonex-live-roster-*.log`.
No registra PNJs solo mencionados, no reescribe historial ni afirma obediencia
general del proveedor; una cita emitida antes de ejecutar el alta conserva
los límites D29/D127 hasta que el World la conozca.

### D132 — El rol del agente se antepone a la petición tras reconstruir historia

**Estado: Aceptada (2026-10-02).** La revisión del estilo D130 detectó dos
eslabones omitidos. El estilo guardado no se pasa al DM; antes de conectarlo,
se verifica el envío de instrucciones. Con deps/exagent instalado desde Git,
Server solo inserta instrucciones al iniciar historial vacío. Game usa eventos
no vacíos y el adaptador Chat codifica únicamente messages, ignorando el campo
`params.instructions`. Tres rojos muestran DM/PC sin rol y resumen de compacción
ocupando su lugar, pese a que los constructores contienen los prompts.

`AgentInstructions` se ejecuta al final de las capabilities de DM/PCAgent,
después de compacción. Usa el rol del agente vigente como primer Request de
`request_messages`; conserva resúmenes y conversación, y elimina solo copias
idénticas de esas instrucciones de Requests existentes (mantiene sus User/
ToolReturn). No cambia `messages` ni `first_new_message_index`, ni depende de
leer privados del Server o de modificar exAgent. El prefijo es estable dentro
del agente. TurnMaster ya usa historia vacía por decisión y no cambia.

**Cuatro casos nuevos** inspeccionan los mensajes que recibe TestModel y su
representación Chat: Game DM con biblia/World/historial, PC con voz propia,
compacción con resumen y pasos de roll_dice con una sola copia del rol.
**35** focalizados, **2213 passed / 3 excluded** (33,1 s), compile sin warnings,
formato/diff correctos. `/tmp/dragonex-instructions-delivery-*.log`.
No atribuye todos los errores narrativos a este envío ni certifica obediencia
del proveedor. Sigue pendiente conectar dm_style y medir una partida nueva
con agentes construidos con estas capabilities.

### D133 — El estilo persistido forma parte del prefijo estable del DM

**Estado: Aceptada (2026-10-02).** El wizard/scenarios guardaban dm_style,
pero Bootstrap solo pasaba story_bible a DM.new. Al arreglar el envío D132,
el estilo seguía ausente de los messages del modelo. Dos rojos lo demuestran
para custom y primer escenario predefinido.

Bootstrap pasa el valor guardado y DM.system_prompt/2 añade una sección de
tono/ritmo al prefijo estable. Pide que eventos/avance respeten ese estilo;
la ficha, tools y reglas siguen siendo fuente de verdad. Recorta solo espacio
exterior y conserva saltos interiores; nil/vacío/tipo no soportado omite la
sección y conserva el prompt base. No cambia DB/schema, reglas ni modelo;
el estilo de una partida activa se aplica al construir/rehidratar su agente.

**Tres casos nuevos** inspeccionan la codificación del request: wizard custom
multiline, reapertura pausada/declared intent con el mismo prefijo y World,
todos los escenarios con estilo/biblia y valores legacy. **20** focalizados,
**2216 passed / 3 excluded** (32,9 s), compile sin warnings y formato/diff
correctos. `/tmp/dragonex-dm-style-*.log`.

Partida nueva `/games/19421`, Sylvi + Lyra/Vex IA con tono contemplativo:
ambos responden como sí mismos, **20,70 s** al humano; Character/casillas/
escena/phase/reloj/ledger/plazos/ausencia/pausa/cursor/intenciones iguales
antes/después y sin nuevos dados. Fichas/reload 375/1440 px sin JS/overflow;
lector de Postgres no crea otro Game escritor. `dm-style-*` en playtest.
La apertura tuvo cinco turnos de Lyra y dos chequeos antes de ceder a Sylvi,
inventó arrendajo/colgante y movió al grupo en prosa sin decisión humana.
No confirma agencia/fidelidad de toda la aventura ni reescribe esa historia;
son la siguiente revisión de calidad.

### D134 — Las respuestas del DM no borran la participación de los PCs

**Estado: Aceptada (2026-10-02).** En `/games/19421`, la apertura dio cinco
turnos a Lyra, seis al DM y dos chequeos antes de dejar actuar a Sylvi. El
recuento se verifica con marcadores de Postgres. El prompt del TM mostraba
solo `last_actor = dm`, y su anti-loop comparaba contra ese mismo actor;
una decisión válida para Lyra no detectaba que acababa de actuar antes del DM.
Cinco rojos Game reproducen repetición, consulta redundante y pérdida al reabrir.

`ExplorationTurns` es puro: recibe World, roster, agentes y marcadores. Los
últimos 64 `:turn` se consultan por tipo, sin depender de cuantos eventos
intermedios produzca un beat. Una intervención humana reinicia los compañeros
ya servidos; cualquier marcador de combate limita esa ventana. El marcador
nuevo incluye `turn_kind` y conserva compatibilidad con el anterior sin campo.
No modifica World, Character, Codec ni schema.

En una respuesta ordinaria del DM, un `give_turn_to` que repite una IA cede
a una persona disponible, priorizando quien no ha participado o quien lo
hizo hace más tiempo; empate por nombre. Si ya intervinieron todas las IA
disponibles, ese relevo humano se aplica sin consulta TM. Un TM mudo/fallido
tras una IA tampoco usa el cursor heredado para repetirla. El contexto enviado
al modelo incluye personas y compañeros ya servidos, conservando libertad
para una primera intervención o para otro compañero todavía sin turno.

Declaraciones humanas, preguntas dirigidas y `request_response` conservan
su prioridad. La nueva equidad no fuerza combate, interrupciones, re-eval ni
partidas sin persona manual disponible; un humano en piloto automático cuenta
como IA. PCs ausentes, caídos o incapacitados no son receptores disponibles.
El fallback de exploración también respeta la declaración pendiente; re-eval
muda sigue aparcando al waiter y no le roba la palabra.

**13 casos nuevos**, seis puros y siete Game/Postgres, prueban ciclo de cinco
compañeros, reinicio humano, elegibilidad/autoplay/límite combate, repetición
válida, contador de requests/contexto, reapertura tras 220 eventos, orden
humano/pausa/reapertura, TM mudo y prioridad en cola. Un rojo adicional fija
la frontera de una reacción de combate. **77** focalizados, **2229 passed /
3 excluded** (33,8 s), compile sin warnings y formato/diff correctos.
`/tmp/dragonex-exploration-fairness-*.log`.

Nuevo recorrido `/games/19422`: Sylvi + Lyra/Vex, apertura **12,10 s** hasta
el humano con una narración DM y ninguna IA previa. Pregunta explícita recibe
ambas voces y vuelve en **17,61 s**, World completo codificado idéntico antes/
después, pausa/cursor/intenciones iguales y ningún dado nuevo. Conserva escena
inicial; fichas/reload a 375/1440 px sin JS/overflow. Lectores no crean otro
Game escritor. `exploration-fairness-*` en playtest. No convierte la medición
en garantía de latencia ni certifica la agencia de todas las narraciones.

### D135 — Una escena del modelo no decide la acción de otros PCs

**Estado: Aceptada (2026-10-02).** La apertura D133 guardó «El grupo cruza…»
como narración y «Decidís cruzar…» en World.scene, pese a que solo Lyra había
propuesto acercarse. El filtro D29 buscaba PCs por nombre; set_scene aplicaba
solo scrub genérico. Las instrucciones de recuperación además ordenaban
trasladar al grupo. Fixtures exactos proceden de narración/escena de
`/games/19421`; esa historia no se reescribe.

Text añade cortes acotados de sujeto colectivo y movimiento plural afirmativo
cuando representan a otro PC. Mantiene entorno/PNJs, grupos NPC cualificados,
estados pasivos, singular propio, condicionales y preguntas. Extiende la
frontera tras una cita cerrada para conservar al PNJ y retirar el movimiento
colectivo siguiente. Streaming, Events e historial usan esos mismos cortes.
El detector de nudges mantiene su alcance más amplio de acciones por nombre.

La nueva comprobación puppets_pc compara el resultado de los cortes contra
la misma normalización de cláusulas: espacios/saltos no provocan rechazo, y
una invitación PNJ con un nombre PC permanece válida. set_scene limpia texto,
relee el roster del World/actor del handle y rechaza la propuesta completa
si contiene una acción de otros PCs/colectiva o queda vacía. Devuelve error
directivo antes de proponer, conservando escena/log/cola/recursos. Un PC
resuelto por DM puede describir su movimiento local propio; el control de
otras acciones permanece en el motor. Default/avance/postcombate recuerdan
estilo/agencia y actualizan el entorno en vez de ordenar traslado automático.

**15 casos nuevos**: seis puros de texto, siete Game/Postgres, uno LiveView y
uno de instrucciones. Ocho rojos iniciales reproducen publicación/propuesta/
copy; otro fija el falso positivo de invitación PNJ. Rechazo real conserva
World y reapertura; propuesta válida conserva recursos; pregunta registrada
antes del rechazo mantiene ambas respuestas en orden y retorno humano.
La mesa prueba preview y reload. **97** focalizados, **2244 passed / 3 excluded**
(34,5 s), compile sin warnings, formato/diff correctos.
`/tmp/dragonex-collective-agency-*.log`. Sin nuevo playtest de proveedor.

El criterio es estructural, no un comprobador general de consenso o posición.
Alusiones implícitas como «al acercaros» y planes/hechos semánticos continúan
bajo revisión. No se declara corregida toda prosa posible ni cerrada la aventura.

### D136 — Identidad registrada y capacidad antes del relevo por pregunta

**Estado: Aceptada (2026-10-02).** D30/D93 buscaban nombres completos con
regex sin fronteras ni prioridad entre identidades. «Sylvi» perdía a «Sylvi
del Roble»; «Lyra del Muelle» podía forzar al PC «Lyra». Una pregunta genérica
podía regresar al humano anterior en lugar del nombrado, y no se validaba que
el destinatario pudiera actuar. El historial de solo 24 eventos también perdía
al humano anterior tras un beat con muchas tools/eventos.

Text.addressed_pc/3 recibe destinatarios elegibles y todos los personajes
registrados; /2 conserva su llamada existente. Reutiliza las formas cortas
únicas de narración, escapa nombres literales, prioriza formas largas y aplica
fronteras Unicode. Un nombre corto ambiguo no fuerza un receptor; una pregunta
con varios humanos permanece genérica en lugar de depender del orden del
roster. Un nombre registrado de PNJ/IA/humano no elegible no se transforma en
otro humano. No se amplía el reconocimiento a toda la semántica de preguntas.

Game filtra receptores mediante World.validate_actor (incluye presencia,
0 PG/muerte e incapacitación) y entrega el registro completo al parser. En
preguntas genéricas primero mantiene el speaker de acciones/narración; si
quedó fuera de la ventana, usa Games.recent_turns (64), sin depender del
volumen de mensajes. Los tres caminos de relevo usan el mismo World vigente.
No crea campos, mutaciones de World, esquemas ni átomos nuevos a partir de texto.
Conserva las prioridades y guardas de conversaciones/intents/re-eval/mini/combate.

**11 casos nuevos**, diez rojos iniciales: identidad/Unicode/prefijo/ambigüedad,
nombres múltiples y contrato anterior; Game real prueba apertura sin TM,
otro humano frente al speaker anterior, PNJ de prefijo PC, incapacitado y
220 eventos intermedios sin World cambiado. **77** focalizados, **2255 passed /
3 excluded** (35,0 s), compile sin warnings. Los fixtures de guards usan
Worlds reales en lugar de mapas parciales. `dragonex-addressed-identity-*.log`.
Sin nueva medición de proveedor; referencias que no son vocativos/intención
semántica y latencia de grupos siguen bajo revisión.

### D137 — Retirar el movimiento supuesto dentro de una descripción válida

**Estado: Aceptada (2026-10-02).** D135 retiró «El grupo cruza…» del fixture
real, pero preservó «y al acercaros el destello…», que también daba por hecho
un traslado. Se reutiliza la narración exacta de `/games/19421`, conservando
su historia; no se inventa otra reproducción ni se reescribe el pasado.

Text corta localmente seis familias de infinitivos personales plurales con
«al» (acercar/adentrar/dirigir/marchar/alejar/apartar + os/nos) y un destino
acotado hasta la coma/frontera. Mantiene los hechos del entorno que siguen.
Aplica la operación por cláusula y fuera de citas, incluidas citas abiertas
mientras llega el streaming. Interrogación/condicionales/planes fuera de citas
se conservan; una pregunta o condicional pronunciado por un PNJ no oculta el
movimiento afirmativo que lo sigue. Añade frontera «Al…» tras cita cerrada,
limpia conjunciones finales del corte y capitaliza el nuevo comienzo.

El detector de nudges y puppets_pc usan el mismo reconocimiento; Events,
historial y preview reciben scrub. set_scene hereda el rechazo completo
antes de proponer, sin modificar World/log/cola; invitaciones PNJ y movimiento
singular propio permanecen válidos. No añade estado, reglas de viaje ni
un modelo semántico de consenso/posición; el vocabulario continúa acotado.

**9 casos nuevos** (siete Text/dos Game), más historial y LiveView reforzados.
Siete rojos iniciales; **93** focalizados, **2264 passed / 3 excluded** (34,8 s),
compile sin warnings, formato/diff correctos. `dragonex-implicit-agency-*.log`.
Partida real `/games/19422`: intervención Sylvi, Lyra/Vex propios una vez cada
uno, cierre DM y retorno humano **10,02 s**. World completo, escena, pausa,
cursor e intenciones iguales, cero dados. Recarga/fichas 375/1440 px sin
JS/overflow, lectores sin segundo escritor. `dialogue-continuity-*` en playtest.
Las respuestas usan «Sylvi» pero el retorno es de la conversación explícita;
no es prueba live del parser D136 ni garantía de latencia/fidelidad absoluta.

### D138 — Una persona toma la primera decisión de una mesa mixta

**Estado: Aceptada (2026-10-02).** El playtest de seis `/games/19423` tarda
25,76 s en dar control a Iria, con dos DM y una Mara; los ciclos D134 evitan
repeticiones pero aún permiten que una IA intervenga antes de la primera
persona. Tras presentar la escena se reserva esa primera decisión humana,
sin pedir otro arbitraje al modelo.

ExplorationTurns deriva opening? desde los 64 marcadores recientes: ningún
PC registrado tuvo turno, de ninguna fase/kind (un turno de combate/reacción
previo no se confunde con apertura). opening_human devuelve el primer humano
manual elegible solo con compañeros IA disponibles; no se aplica a autoplay
completo ni a una mesa sin IA. Usa el orden humano existente y no añade
campos persistidos a World/Character/Codec ni depende de last_actor = dm.

Game integra esa decisión en exploration_human_due y el fallback tras DM.
Las guardas y prioridades existentes de preguntas explícitas, intents,
conversación, re-eval y mini-turns permanecen. La presentación DM sigue
primero; el usuario puede declarar y, desde entonces, se mantienen los ciclos
D134. Pausa/rehidratación conservan cursor y no repiten la presentación.

**3 nuevos** (dos puros y un Game con uno/cinco compañeros), tres rojos
iniciales. Cuatro pruebas D134 ahora consumen una declaración humana real
antes de evaluar repetición/ciclo/TM mudo. **41** focalizados, **2267 passed /
3 excluded** (35,4 s), compile sin warnings, formato/diff correctos.
`dragonex-exploration-opening-*.log`. Nuevo `/games/19424`: primer control
**6,01 s**, un DM/cero IA y escena original igual. Pregunta a cinco **22,72 s**,
una intervención cada uno, cierre DM y vuelta Iria; World completo/recursos/
pausa/cursor/cola iguales, sin dados. Reload/fichas 375/1440 px sin JS/overflow,
lector sin otro escritor. `opening-control-*`. Variabilidad del proveedor:
no promete esos tiempos. Tres respuestas quedaron a mitad de frase; su
origen proveedor/filtro sigue pendiente de reproducción independiente.

### D139 — Una observación figurativa no es la voz ni la acción de un PNJ

**Estado: Aceptada (2026-10-02).** D138 detectó tres respuestas cortadas en
`/games/19424`. Captura en solo lectura de Server.history desde el Game dev
existente, pausado: cada raw estaba completo, finish_reason=stop y output
142/97/65 tokens. El filtro, no el presupuesto, producía el truncamiento.
Se guardan tres fixtures exactos; el gancho temporal de diagnóstico se retira.

Tres causas: @npc_attr interpretaba cualquier sustantivo después de «dice
el/la» como hablante (hora/verdad); solo_exec cortaba «quiebra» sin objeto,
incluida la luz en la jarra; cleanup_after_stat_strip borraba «tiene:» aunque
fuera gramática legítima. Text resuelve primero identidades registradas y,
para roles desconocidos, exige rol conocido o atribución de cita/dash antes
de cortar. Conserva propiedad de la voz propia. quiebra solo se corta con
lacre/sello/pergamino; el cleanup no borra palabras antes de colon.

No amplía los permisos de tools ni cambia World/Character/Codec/turnos.
Los cortes de voces ajenas, acciones de otros PCs, stats y resolución solo
siguen deterministas; mantiene vocabulario acotado, sin intérprete semántico
general ni whitelist de toda profesión ficticia posible.

**11 nuevos** (siete Text, un Game/tres respuestas, tres LiveView), diez
rojos iniciales. Asserts sobre texto completo, historial, preview/reload,
World/cola/rehidratación y negativos de PNJ/sello/stats. **94** focalizados,
**2278 passed / 3 excluded** (35,8 s), compile sin warnings, formato/diff
correctos. `dragonex-observation-integrity-*.log`. Continuación real19424:
Lyra/Mara/Nera propios, DM y retorno Iria **13,09 s**; raw=filtrado=persistido
para los tres, finish_reason=stop. World completo/recursos/pausa/cursor/cola
iguales, sin dados. Recarga/fichas 375/1440 px sin JS/overflow, lectores sin
segundo escritor. `observation-integrity-*` y `response-integrity-*`.
Las narraciones históricas no se reescriben. El gesto de asentimiento que el
DM atribuye a Iria y otras formas semánticas siguen bajo revisión D29.

### D140 — Validar parámetros de ASI sin perder las elecciones

**Estado: Aceptada (2026-10-02).** La LiveView de subida convertía los
parámetros del evento con to_existing_atom/to_integer. Una característica
desconocida, un delta inválido o un payload incompleto cerraban el proceso
y perdían el borrador; el evento también aceptaba ajustes en niveles sin ASI.

LevelUp usa mapas cerrados de las seis características y pasos +1/−1,
comprueba que el nivel incluye ASI y mantiene presupuesto 2/cap 20. Datos
inválidos no ajustan elecciones: asigna un error específico con role=alert
junto a los controles. Un evento válido recupera ese error sin limpiar otro
error de confirmación. El borrador permanece solo en la LiveView y la
confirmación conserva el nivel esperado D125; no cambia reglas de progresión,
World/Character/Codec ni la política de elecciones opcionales D13.

**5 casos nuevos**, cinco rojos iniciales; **28** focalizados,
**2283 passed / 3 excluded** (36,9 s), compile sin warnings, formato/diff
correctos. `dragonex-asi-input-*.log`. Navegador por teclado en la vista de
Sylvi L3: primer punto intacto tras error, segundo clic válido recupera sin
reconectar, dos puntos elegidos, recarga sin confirmar reinicia el borrador.
Biblioteca y todos los World/pausas/cursors/colas asociados iguales,
375/1440 px sin JS/overflow. `asi-input-*`, lector sin segundo escritor.

### D141 — Pronombres antes del predicado ajeno y entorno posterior conservado

**Estado: Aceptada (2026-10-02).** El cierre real19424 posterior a las tres
respuestas decía «Iria las recoge en silencio, asintiendo apenas, y el calor
de la cocina…». El predicado exigía verbo pegado al nombre y no contemplaba
recoge: el pronombre escondía el gesto que el DM asignaba a la jugadora.

Fixture exacto. Text incorpora recoge/recoger y permite como máximo un
clítico indirecto/reflexivo y uno de objeto antes de un verbo conocido. Las
directas, relativas/subordinadas y detector comparten el predicado, respetando
nombres canónicos/cortos únicos, actor propio y sujeto inmediato. No infiere
dueño de pronombres sin sujeto ni toma verbos de un PNJ posterior.

Una cláusula retirada puede contener después un sujeto ambiental separado:
divide «, y/e el/la…» solo para una lista acotada de sustantivos de entorno,
fuera de citas completas/incompletas, y conserva esa descripción legible.
«Y las guarda» sigue siendo una acción del PC, y una cita no recupera su voz.
No es un parser general de español. `set_scene` hereda el rechazo completo
antes de proponer, mientras streaming/Events/historial usan el corte local.
No cambia World/Character/Codec ni turnos/recursos/estilo.

**11 casos nuevos** (siete Text, un Game, un LiveView, dos Game/set_scene),
nueve regresiones en rojo; **89** focalizados, **2294 passed / 3 excluded**
(37,1 s), compile sin warnings, formato/diff correctos.
`dragonex-clitic-agency-*.log`. Seguimiento real19424: tres respuestas propias,
DM sin gesto humano y retorno Iria **15,67 s**, World completo/recursos/pausa/
cursor/cola iguales, cero dados; teclado/reload/fichas 375/1440 px sin
JS/overflow, lectores sin segundo escritor. `clitic-agency-*`. El cierre
nuevo no contiene el disparador exacto (comprobado con fixture); no reescribe
el gesto histórico ni certifica otras alusiones/consenso semántico D29.

### D142 — La destinataria de un diálogo no se convierte en hablante

**Estado: Aceptada (2026-10-02).** La entrega de Vex19425 perdió «la posadera»
y dejó «le tiendo el saquito a Aquí…». El raw de ese turno ya fue sustituido;
una reconstrucción mínima produce exactamente ese corte con «a la posadera—.»:
el detector de rol seguido de cita/dash confundía el cierre del inciso propio
con la apertura de una voz PNJ. No se etiqueta la reconstrucción como raw.

Text exige un sujeto/etiqueta de rol en inicio de cláusula, puntuación o
coordinación. El objeto tras preposición conserva su nombre/inciso/cita propios.
Una relativa inmediata «la posadera, que responde…» conserva al destinatario
y corta desde la respuesta. Se mantienen sujetos/etiquetas PNJ reales, voces
registradas y rol DM; usa vocabulario/gramática acotados y no resuelve todas
las formas de diálogo. No cambia World/Character/Codec/turnos/recursos/tools.

**9 casos nuevos** (siete Text, un Game, un LiveView), seis rojos iniciales
y uno adicional de relativa; **99** focalizados, **2303 passed / 3 excluded**
(37,2 s), compile sin warnings, formato/diff correctos.
`dragonex-npc-recipient-*.log`. Agradecimiento19425 **8,55 s**, Vex propio/DM;
raw capturado en el proceso pausado, finish_reason=stop, solo cabecera retirada,
limpio=persistido, World/recursos iguales y fichas 375/1440 px sin JS/overflow.
Gancho temporal retirado y compile limpio. Petición de jarra posterior
**13,63 s** omitió el turno de Vex: la captura suya sigue siendo el previo,
no una respuesta nueva. Siguiente diagnóstico del enrutamiento humano
explícito; no reescribe la entrega histórica ni certifica ese relevo.

### D143 — Un vocativo humano literal no depende de una llamada del narrador

**Estado: Aceptada (2026-10-02).** La pregunta real19425 «Vex, ¿puedes
acercar tu jarra…?» volvió Human → DM → Human: el modelo omitió la tool
D120 y el DM respondió antes de que Vex pudiera pedir el agua. Se amplía
D120 con reconocimiento determinista de una forma explícita y acotada.

Text resuelve solo un vocativo al comienzo, seguido de coma y pregunta
española completa. Admite varios nombres separados por comas/y/e, nombres
canónicos literales y cortos únicos entre todos los personajes registrados.
Conserva orden y propiedad, sin convertir prefijos PNJ ni homónimos en PCs.
Menciones, citas, preguntas genéricas/indirectas/incompletas y duplicados
no seleccionan destinatarios. Fuera de esa forma sigue la tool semántica;
no se pretende interpretar toda prosa humana ni decisiones del grupo.

Beats.consume_intent llama a Conversations dentro del Game single-writer
solo cuando se consume una declaración humana. Reutiliza Conversation.request
y las guardas D120: exploración, 1–5 PCs participantes presentes/capaces,
sin self/PNJs. Una invalidación cancela la propuesta entera, sin subconjunto
silencioso. Persiste antes de lanzar el narrador y entrega ese World al brief.
Intenciones pausadas/off-turn no abren cola anticipada y pueden limpiarse.

Una conversación pendiente no se sustituye. El prompt y la descripción de
tool reconocen la cola ya registrada; reintentos idénticos siguen idempotentes
y paráfrasis/destinatarios distintos se rechazan sin reiniciar respuestas.
Fallos terminales, pausa/reinicio, respuesta humana, prioridad de otra persona
y combate mantienen su camino. No añade campos, esquemas, eventos especiales,
tools ni mutaciones desde LiveView; no calcula reglas con el modelo.

**14 casos nuevos** (cinco Text, ocho Game, un LiveView), ocho rojos iniciales;
**72** focalizados, **2317 passed / 3 excluded** (39,3 s), compile sin warnings,
formato/diff correctos. `dragonex-explicit-question-*.log`. Mesa19425 real:
Mara → Vex → DM → Mara **6,51 s**, Vex85 propio, raw del agente existente
finish_reason=stop y limpio=persistido. World completo/biblioteca/pausa/cursor/
cola iguales, cero dados; teclado/reload/fichas 375/1440 px sin JS/overflow.
Gancho temporal retirado y compile limpio. `short-adventure-explicit-question-*`.
Tiempo observado variable; no certifica otras formas de petición ni toda
coherencia narrativa y no reescribe el relevo histórico perdido.

## D144 — Contexto factual del reloj y descanso largo

**Estado: Aceptada (2026-10-02).** Tras una noche real, el agente describió
la posada pero conservó el patio inicial en `World.scene`. El brief omitía
reloj y límite diario. Los briefs incluyen ahora tiempo relativo, disponibilidad
de descanso desde `Rest.long_rest_wait/2` y hechos canónicos también para
TurnMaster. La escena se presenta como último registro, subordinado a hechos
y decisiones posteriores. La respuesta de `rest_party` comunica el reloj
confirmado y pide actualizar el entorno con `set_scene` sin repetir efectos.

No se infiere una hora del día ni se modifica el World al construir contexto.
El validador y el brief comparten el límite de 24 h; combate e incapacitación
siguen bloqueando el descanso. **6 casos nuevos**, seis rojos iniciales,
**64** focalizados y **2323 passed / 3 excluded** (38,9 s), compile limpio.
La mañana real19425 devuelve el turno en **13,65 s**, conservando todo World
y los recursos, pero omite nuevamente `set_scene`. La instrucción no garantiza
el registro: su actualización persistente queda abierta para un cierre
verificable. `dragonex-clock-context-*.log`/`short-adventure-manana-contexto-*`.

## D145 — Instantánea de entorno estructurada y pendiente durable

**Estado: Aceptada (2026-10-02).** El modelo omite `set_scene` después de
una noche y de la siguiente pregunta aun con D144. Repetir instrucciones
no permite verificar el registro. World guarda `scene_refresh_pending`,
codificado explícitamente: tiempo positivo en exploración, facts nuevos y
fin de combate lo activan. `set_scene` lo cierra. Legacy sin campo se marca
si ya hay tiempo/facts; no reescribe historia ni recursos.

Al concluir un DM de exploración con registro pendiente, una ejecución aparte
del modelo de resúmenes devuelve `final_result(scene)` obligatorio mediante
OutputSchema. No tiene tools de reglas ni Events, usa los 40 eventos recientes
y el World actual, máximo dos pasos/20 s/1024 tokens/1200 caracteres. Modelos
offline siguen offline; `scene_model` permite inyección determinista. Conserva
las preferencias de proveedor. Se rechazan vacío, copia antigua, frase cortada
y las guardas acotadas de agencia, incluyendo el cruce y «los tres pasan…»
observados en las pruebas. Un fallo deja pendiente, sin repetir el beat ni
los descansos ya confirmados; diagnóstico en log sin cuerpo del proveedor.

El Task solo propone. Game compara el World esperado y aplica la instantánea
vía Session antes de cerrar el beat/persistir. `World.refresh_scene` conserva
la cola de conversación y su retorno; `set_scene` mantiene D120 para cambios
de escena declarados. Una respuesta desactualizada se descarta. La pausa
sigue responsive y no se revoca al terminar el registro. No hay llamada
adicional si el DM ya registró ni en diálogos sin señales de cambio.

**16 casos nuevos**, diez rojos iniciales, **120** focalizados y
**2339 passed / 3 excluded** (38,4 s), compile/formato/diff correctos.
Primera variante real con contexto120/modelo del beat: timeout20 s, vuelta
en38,71 s sin cambios; diagnóstico de lectura confirma timeout. Una muestra
del resumidor/contexto40 termina en7,06 s pero deja frase incompleta y decide
«los tres pasan el día…»: fixture exacto y rechazo añadidos. Variante final:
registro4,72 s/un paso, vuelta Mara23,89 s, escena cuarto/huerto persistida;
DM no llamó tools. Solo escena/log/marca cambian, World mecánico/biblioteca/
pausa/cursor iguales y cero dados. Reinicio real conserva World/130 eventos,
termina cinco auxiliares y mantiene el rechazo diario para tres PCs.
Web375/1440 px correcta; ganchos retirados y compile limpio.
`dragonex-scene-refresh-*`/`short-adventure-manana-registro-*`.

Las señales no identifican todo viaje por prosa, y los detectores no prueban
toda semántica. No se infieren coordenadas, hora absoluta, recursos ni una
garantía de coherencia del modelo. Un resumen inválido queda pendiente.

## D146 — Proyección de caducidades en el mensaje del descanso largo

**Estado: Aceptada (2026-10-02).** `compose_rest` adelanta el reloj, caduca
la Forma salvaje y cura el cuerpo vigente. `do_long_rest` describía antes
los PG de la bestia: 0PG11→11 pese a curar nativo6→29. Calcula ahora el
mensaje con `WorldClock.advance(world,28800)`, proyección pura como en el
descanso corto. El cambio preparado sigue usando Rest.complete y sus
guardas; no aplica el reloj al preparar, cambia esquemas ni recarga dos veces.
Si la forma todavía tiene plazo después de ocho horas, el mensaje conserva
el cuerpo de bestia representado. No amplía la semántica de Forma salvaje.

**6 casos nuevos**, cinco rojos iniciales, **76** focalizados,
**2345 passed / 3 excluded** (39,2 s), compile/formato/diff correctos.
Incluye daño de bestia/Codec, plazo exacto8 h y restante9 h, descanso de
dos formas con un único intervalo y feedback al DM/TestModel/persistencia.
Mesa19426/SylviL3: original10/24, lobo11/11; noche28,24 s al humano,
cuerpo24/24, forma nil, dos usos, reloj28800, casillas/dados/biblioteca
correctos y cero tiradas. Reinicio conserva World/20 eventos/pausa/cursor,
cierra tres auxiliares y mantiene el límite diario. Web375/1440 px correcta.
El history del siguiente DM sustituyó el feedback del beat humano: replay
de Actions sobre el World previo registrado devuelve14PG10→24 sin aplicar
la función de cambio; no se atribuye al replay una captura del agente real.
Ganchos retirados, compile limpio. `dragonex-rest-shape-feedback-*`/`rest-form-*`.

## D147 — Propietario de ejecución y cancelación por monitores

**Estado: Aceptada (2026-10-02).** Dos reproducciones dejan una petición
TestModel esperando tras detener Game, incluso con parada supervisada. Los
Servers y Session están enlazados al Game, pero exAgent arranca la ejecución
con `async_nolink` en su supervisor global; matar el Server no cancela esa
petición. Una salida normal tampoco termina los servidores enlazados.

`Game.RunLifecycle` monitoriza Game y cada beat para terminar sus Tasks al
perder el propietario. Una capability registra el monitor antes del pedido,
valida el propietario al recibir respuesta y antes de tools; se aplica a
DM/PC/TurnMaster/registro de escena. Las instrucciones de agente siguen
después de compaction (D132). Bootstrap vigila Session/Servers y cada PC,
también los de autoplay creados posteriormente. El monitor termina al acabar
sus objetivos. No se enlazan fallos del modelo al Game ni se modifica exAgent.
Events y callbacks de texto/dados descartan publicaciones de propietario
muerto. No se cambia World/Codec ni la semántica de pausa del beat en curso.

**12 casos nuevos**, tres fallos iniciales válidos (dos cancelaciones y un
autoplay posterior), **67** focalizados y **2357 passed / 3 excluded**
(39,1 s), compile limpio. Reinicio público y caída mantienen mundo/eventos/
pausa con petición detenida antes de tools. La mesa propia19427 confirma en
el VM web cancelación y cuatro auxiliares cerrados en12,48 ms, tres eventos
idénticos y reload375/1440 px/ficha por teclado sin JS/overflow. TestModel
offline: no se presenta como cancelación HTTP medida del proveedor. Ganchos
retirados. `dragonex-run-lifecycle-*`/`run-lifecycle-*`.

El gate final tiene11 errores de dueño Sandbox salido durante teardown,
con suite verde; su orden de cierre se revisará aparte. Un pedido detenido
antes de tools no prueba recuperación tras mutaciones parciales. El guardado
por beat sigue siendo el contrato; no se introduce transacción por llamada
de herramienta, cancelación de facturación ni garantía temporal aguas arriba.

## D148 — Conexión de test independiente y cierre de fixtures antes de SQL

**Estado: Aceptada (2026-10-02).** Los gates D147 registran errores de
dueño Sandbox salido pese a las aserciones verdes. Ecto recomienda
`start_owner!` cuando procesos no enlazados al test pueden sobrevivirlo.
`Test.Sandbox.start_shared!` conserva el dueño hasta `on_exit`; sustituye
el patrón checkout/shared en67 módulos/69 setups. Siete módulos async
mantienen sus checkout aislados.

Mantener el dueño no basta: cancelar partidas que todavía están consultando
interrumpe el cliente SQL. `Test.GameFixture` registra un hijo después del
Game; ExUnit lo termina primero y ese hijo pausa/espera el beat activo,
hasta5 s, antes del cierre del Game. Ante un Game muerto termina sin consulta.
Los fixtures conservan los IDs del Game y las pruebas de reapertura;55
módulos/147 arranques usan el helper. Las partidas iniciadas por LiveView
pertenecen al supervisor global: se detectan comparando Registry con el
inicio de la fixture y también se pausan/cierran antes del dueño. La limpieza
no consulta tablas para inventariar procesos durante la desconexión.

Un caso nuevo deja al modelo esperando después de un descanso confirmado:
la limpieza permite su respuesta final, conserva curación/reloj/World/eventos
en DB y luego cierra. **71** focalizados y **49** en la variante Registry,
sin errores. Gate final **2358 passed / 3 excluded** (39,2 s), cero errores
de log, compile/formato/diff correctos. Los gates intermedios no limpios
quedan en `dragonex-sandbox-lifecycle-*`; el final verificado es
`dragonex-sandbox-lifecycle-final-registry-full.log`.

Es infraestructura de prueba. No cambia la cancelación D147 ni permite
concluir que una caída después de efectos parciales sea durable. Las pruebas
específicas de parada/reinicio siguen deteniendo sus ejecuciones bloqueadas.

## D149 — Salida supervisada diferida hasta terminar el callback del Game

**Estado: Aceptada (2026-10-02).** Una operación del Game bloqueada bajo
control se corta al llamar `DynamicSupervisor.terminate_child`: sin señales
capturadas, la salida interrumpe el proceso antes de responder. Game activa
`trap_exit` en init para que OTP procese la parada después del callback actual.
Se mantiene el plazo de shutdown del supervisor; no garantiza respuesta si
expira ni ante `:kill`. Los beats IA siguen asíncronos y se cancelan con D147.

Capturar salidas requiere tratar las de los hijos vigentes: Session, DM,
TurnMaster o PC parado termina Game con motivo normalizado `:game_child_down`
para su recuperación transitoria. Un autoplay ya retirado queda fuera de la
lista vigente y su EXIT normal no reinicia la mesa. `format_status` conserva
solo game_id/status/fase/último actor en el estado del informe OTP; excluye
los modelos con credenciales. No se cambia World/Codec ni las reglas.

**5 casos nuevos**, un rojo inicial, **54** focalizados y
**2363 passed / 3 excluded** (39,0 s), cero errores de log, compile/formato/
diff correctos. Callback retenido100 ms responde antes de parada, caída DM,
salida normal Session, autoplay retirado e informe de estado probados.
VM web19427 con TestModel: confirma el mismo orden, cierra tres auxiliares y
reabre con World/tres eventos/pausa/cursor iguales. Reload375/1440 px y
teclado correctos. Adopción en mesas propias19425/19426 pausadas conserva
todo World/130 y20 eventos, relojes32400/28800, escena vigente y cursor;
cierra cinco/tres auxiliares anteriores y arranca con trap_exit activo.
Ganchos retirados. `dragonex-shutdown-order-*`/`shutdown-order-*`.

La operación controlada verifica el orden del proceso, no una medición
de latencia de SQL real. La persistencia tras caída con efectos parciales
sigue pendiente; dejar terminar un callback no equivale a una transacción
por beat ni a esperar que concluya un pedido al proveedor.

## D150 — Checkpoint durable de cada cambio de tool antes de confirmarlo
Fecha: 2026-10-02. Estado: **Aceptada**.

Un descanso ya aplicado estaba visible en el World de Session, pero Postgres
retenía el estado anterior mientras el modelo terminaba el beat. El rojo
inicial compara14/14 PG/reloj28800 con8/14/reloj0 guardados. Perder la narración
no debe deshacer una acción que el motor ya confirmó.

Las tools con `deps.game_owner` proponen vía `Game.commit_rule_change/3`.
Game comprueba Session, game_id, actor, turn_id y propietario vivo frente al
Beat activo; evalúa la función dentro de su proceso único. Guarda el candidato
World junto al cursor/status/intenciones actuales antes de publicarlo a la
Session con una función constante y responder. Rechazos, resultados que no
son World y excepciones de la función no publican ni guardan un cambio.
Las sesiones standalone conservan SharedState sin DB. La LiveView no escribe.

No se evalúa la función dentro de una transacción SQL: puede cerrar grupos
de tiradas cuyo recorder escribe eventos desde otro proceso. World y dados/
eventos no son una transacción conjunta; una caída antes de confirmar la tool
sigue requiriendo una política posterior. Un efecto guardado antes de publicar
puede sobrevivir aunque la respuesta se pierda. Los presupuestos de combate
y el límite diario de descanso conservan sus validaciones para impedir replay.

**7 casos nuevos**, gate **2370 passed / 3 excluded** (40,6 s), cero errores
más once avisos de tests, compile dev limpio. VM19428 offline: descanso8→14,
reloj28800 guardados antes de narrar, reinicio5,575 ms observado con World/
historial iguales, pedido viejo cerrado; continúa al humano, registra amanecer
y mantiene límite diario sin dados. Ganchos retirados. `dragonex-rule-checkpoint-*`.
La variante combinada de caídas rápidas agotó el límite de reinicios global;
no se presenta como verde y abre el trabajo de aislamiento entre mesas.

## D151 — Presupuesto de reinicios y supervisor aislados por mesa
Fecha: 2026-10-02. Estado: **Aceptada**.

Las pruebas de caídas revelaron que todos los Games compartían el presupuesto
3 reinicios/5 s del DynamicSupervisor. Cuatro fallos de una partida podían
cerrar también una mesa sana. El rojo específico confirma su DOWN:shutdown.

El gestor dinámico supervisa ahora `TableSupervisor` temporales; cada uno
supervisa un único Game transitorio/significativo con el presupuesto OTP
vigente3/5 s. Agotarlo termina solo esa mesa. El padre no reinicia el supervisor
temporal, evitando reabrir automáticamente un bucle de fallos. Abrir otra vez
reconstruye World desde DB. `auto_shutdown:any_significant` retira el supervisor
vacío tras salida normal; la API conserva GamePID, no el del supervisor.
Registry separado identifica propietarios y restart espera las dos claves.
La parada admite Games de desarrollo antiguos todavía hijos directos. No
altera World/Codec, reglas ni cancelación D147/checkpoint D150.

**6 casos nuevos**: una mesa/cuatro fallos con sana intacta, cuatro mesas
independientes, cierre normal, restart/idempotencia, ID ausente y checkpoint
tras `:kill`. Gate **2376 passed / 3 excluded** (40,4 s), cero errores/warnings;
compile limpio. Once avisos de tests eliminados manteniendo sus aserciones.
La variante previa tuvo una desconexión SQL porque la siguiente caída podía
matar el reemplazo antes de terminar init; la prueba final espera su respuesta.

VM web19429 con TestModel: cuatro caídas cierran supervisor/tres auxiliares;
manager y mesa19428 mantienen PID/World/historial. Reapertura manual conserva
World/pausa. Reload375/1440 px/teclado en ambas sin JS/overflow. Adopción propia
19425–19428 pausadas conserva World/eventos/modelos/cursores/relojes y cierra14
auxiliares antiguos. Ganchos retirados. `dragonex-fault-isolation-*`.
Esto limita el alcance de un fallo; no sustituye la atomicidad conjunta de
World/dados/eventos ni la recuperación de llamadas todavía no confirmadas.

## D152 — Reutilizar resultados de tools resueltas dentro del beat reintentado
Fecha: 2026-10-02. Estado: **Aceptada**.

Un503 al narrar después de un cast aplicado reiniciaba todo el beat. En
exploración no lo frenaba el presupuesto de combate y se gastaba otra
casilla/daño. El rojo inicial deja0 casillas cuando debería quedar1.

Las tools anunciadas a DM/PC se envuelven con `ToolReplay`. Game conserva
resultados exitosos textuales, saneados, por tool y argumentos en Beat;
PendingRetry los transporta al siguiente intento, y también los guarda el
retry por tokens. Solo se reutilizan resultados del intento anterior, de
modo que dos acciones originales consecutivas iguales siguen ejecutándose.
El feedback identifica el resultado previo, sin repetir efectos ni tiradas;
copias extra equivalentes en el intento reciben el mismo resultado anterior.
Errores no se registran y pueden corregirse. Un nuevo beat empieza vacío.

IDs del proveedor pueden cambiar y no forman la identidad. Nulos/omisiones
son equivalentes. Magia consulta `Actions.spell_definition/3`, el mismo lookup
puro usado por resolución, para nombres/nivel base; normaliza enteros limpios,
listas opcionales vacías y selección vacía. No calcula resultados en el LLM ni
muta desde la LiveView. Los wrappers validan el beat/Session/actor/propietario.

**9 casos nuevos**, **28** focalizados, **2385 passed / 3 excluded** (41,3 s),
cero errores/warnings y compile/formato/diff correctos. La fixture intermedia
de dos calls simultáneos fue corregida para representar dos casts consecutivos;
las guardas contra recursos obsoletos no se cambian. VM19430:503 simulado,
casillas2→1, Goblin20→14, un grupo de dados, feedback previo al modelo, vuelta
al humano1050,311 ms con backoff1 s. Reinicio posterior mantiene World/eventos;
reload375/1440 px/teclado/reserva correctos. Adopción19425–19429 propias pausadas
conserva World/eventos/modelos/cursores/relojes y cierra17 auxiliares anteriores.
Ganchos retirados. `dragonex-applied-action-retry-*`/`applied-action-retry-*`.

Esta memoria cubre reintentos dentro del Game vivo. No es un log durable entre
Games ni una transacción conjunta de World/dados/eventos. Sigue pendiente
recuperar el actor IA si un reinicio ocurre después de resolver su acción.

## D153 — Registro durable del beat IA aún no liquidado
Fecha: 2026-10-02. Estado: **Aceptada**.

D152 evitaba replay con Game vivo, pero reiniciar un PC IA después del cast
y antes de narrar perdía esa memoria. Rojo: segunda casilla gastada al reabrir.
World incorpora `actor_checkpoint`, con Codec explícito y nil en legacy.
Game guarda resultados exitosos antes de responder: argumentos canónicos y
feedback pasan por Text.scrub. Conserva actor/turn_id, fase/mini-turn y enemigos
anteriores. Restore valida tipos e identidad sin crear átomos desde texto.
El actor reutiliza feedback/marcador; el snapshot original conserva combate
tras spawn. Éxito/fallo definitivo limpia antes de persistir la liquidación.
Nuevo beat humano descarta el registro; volver a control humano no obliga a
repetir autoplay. No cambia structs de personajes ni la propiedad de World.

Ocho casos: restart/:kill tras magia IA, Codec/legacy, datos inválidos,
spawn/combate, sanitización, nueva declaración y fallo definitivo. 45 focalizados;
gate2393/3 en41,8 s sin errores/warnings, compile limpio. Fixture timeout de
SceneRefresh corregida: su plazo incluye preparar la petición y no garantiza
arrancar el callback; conserva World y verifica cierre si arrancó.
VM19431 TestModel: una casilla/daño6/un grupo, un marcador IA y turn_id original
tras restart; petición vieja cerrada, humano25,518 ms. Reload375/1440 px/ficha/
compañeros por teclado correctos. Adopción19425–19430 normaliza el campo nil,
conserva estado/eventos/modelos y cierra20 auxiliares. Ganchos retirados.

RuleCheckpoint guarda el efecto antes de que el wrapper obtenga el resultado
y guarde este registro. Una caída entre guardados, o durante tiradas previas,
exige otro protocolo. No es una transacción conjunta World/dados/eventos y la
recuperación confirmada aquí no se extiende a esas ventanas.

## D154 — Comprobante incluido en el mismo guardado que el efecto
Fecha: 2026-10-02. Estado: **Aceptada**.

D153 aún guardaba efecto y resultado en dos instantes. Una interrupción
después de aplicar magia, con la tool sin responder, pierde su identidad:
el rojo vuelve a gastar la segunda casilla al reiniciar.

El wrapper agrega una referencia efímera por ejecución y su clave canónica
al contexto. RuleCheckpoint reserva un resultado de esa ejecución y guarda
el comprobante en el mismo World candidato que el efecto. No hace un segundo
guardado para asociarlos. Game solo adopta el Beat candidato si guarda/publica
con éxito. Cuando llega el resultado final, sustituye la posición reservada;
varias propuestas de la misma tool no agregan entradas. Llamadas originales
distintas siguen separadas. Rechazos sin efectos no reservan comprobantes.
La referencia queda en Beat, nunca en JSON. El esquema durable D153 no cambia.

Si se pierde el feedback exacto, el comprobante confirma el cambio y pide usar
World/tiradas vigentes, sin inventar cálculo ni volver a ejecutarlo. Puede
representar un cambio parcial de una tool con varias propuestas: no promete
completar sus pasos restantes automáticamente. Se conserva el single-writer,
la API pública y las guardas de recursos; no se mueve el LLM al Game.

Cinco casos nuevos/29 focalizados: restart/:kill, feedback preciso único,
varias propuestas y rechazo corregido. Gate2398/3 en41,8 s sin errores/warnings.
VM19432 offline: corte antes de devolver la tool, comprobante+efecto guardados,
una casilla/daño6/un grupo y turno original; pedido viejo cerrado, comprobante
al actor recuperado, humano29,673 ms. Reload375/1440 px/ficha/compañeros por
teclado correctos. Adopción19425–19431 conserva estado/modelos/eventos, cierra24
auxiliares; ganchos retirados. `effect-checkpoint-recovery-*`.

Cierra la ventana efecto→resultado, no la anterior a guardar el efecto.
Dados/eventos ya emitidos durante preparación aún no son una transacción
conjunta con World. Esa atomicidad conserva su revisión propia.

## D155 — Consenso pasivo y gesto plural del cierre real del granero
Fecha: 2026-10-02. Estado: **Aceptada**.

Playtest19425 con proveedor real: el humano pide ideas antes de decidir;
Lyra/Vex responden, pero DM raw afirma «La decisión queda tomada entre vosotros
sin más debate…». La narración humana persistida también añade «y os miráis
un momento». World/biblioteca permanecen iguales; el fallo es agencia narrativa.
Fixtures conservan DM raw y texto humano persistido, distinguiendo sus fuentes.

Text agrega un predicado acotado de decisión pasiva entre vosotros/vosotras
y corta el gesto reflexivo plural incluso dentro de la declaración propia.
Conserva el resto de la frase/pregunta y el entorno PNJ. Respeta citas abiertas/
cerradas, preguntas, planes, grupos PNJ, singular propio y ausencia de otros PCs.
Una cita completa no ampara el consenso siguiente. La reparación de puntuación
solo acompaña un corte real; puntuación irregular sola no activa el guardián.
Events/History/preview comparten filtro y set_scene lo rechaza antes de World.
El prompt DM recuerda devolver al humano una decisión que dejó pendiente.
No añade un intérprete general de consentimiento ni reescribe eventos anteriores.

Nueve casos nuevos,46 focalizados. Gate2407/3 en49,4 s con trace/max_cases48,
cero errores/warnings, compile/formato/diff limpios. Adopción19425 conserva
estado/modelos/historial y cierra5 auxiliares. Nueva pregunta real vuelve al
humano en12,137 s con ideas propias/decisión abierta y World/biblioteca iguales;
raw Lyra con etiquetas D7 se guarda limpio, raw Vex/DM coincide con events.
Reload/fichas/compañeros por teclado375/1440 px sin JS/overflow. Ganchos retirados.
La diferencia frente a25,431 s no demuestra causalidad de rendimiento del filtro.
Otras formas de consenso y contradicciones semánticas mantienen su revisión.

## D156 — Agencia del roster también al registrar hechos durables
Fecha: 2026-10-02. Estado: **Aceptada**.

> Vigencia: D195 restringe el permiso de autor propio de esta decisión para
> establish_fact/set_scene: ahora solo el DM confirma esos datos canónicos.
> Las guardas de agencia, el saneado y la conservación de legacy permanecen.

El consenso real de D155 se rechazaba al intentar set_scene, pero establish_fact
lo guardaba y lo devolvía a todos los agentes como estado canónico. Rojo del
mismo fixture a través de la tool: «hecho registrado» en lugar de rechazo.
La tool sanea el texto y aplica Text.puppets_pc? con actor/PCs/personajes
actuales antes de proponer. Usa la misma gramática y atribución de escenas;
no agrega un parser ni una nueva forma de World. NPCs, grupos cualificados,
citas y acción propia siguen admitidos. Rechazo retorna error recuperable
sin escribir ni registrar un resultado exitoso de replay.

Cinco casos nuevos/39 focalizados; gate2412/3 en42,5 s, cero errores/warnings,
compile/formato/diff limpios. Standalone sin DB cubre acción ajena/grupo,
PNJ/homónimo/citas, acción propia y sanitización D7. Game/Postgres verifica
el bypass del fixture real. VM19433 offline rechaza y luego acepta mapa PNJ,
actualiza escena factual, humano31,705 ms; mecánicas iguales/cero dados,
restart/reload375/1440 px/fichas/compañeros por teclado correctos.
Adopción19425–19432 conserva estado/modelos/historial y cierra28 auxiliares;
ganchos retirados. `fact-agency-*`.

Se limita a predicados y sujetos que el guardián identifica. No prueba la
procedencia semántica de cada hecho ni sustituye World como fuente de reglas.
Las ventanas de dados/eventos anteriores al guardado conservan su revisión.

## D157 — Dados de tools con efecto/comprobante en una transacción
Fecha: 2026-10-02. Estado: **Aceptada**.

Rojo determinista: Actions.spell prepara y cierra sus dados antes de proponer;
la crónica recibía una tirada con World aún sin coste/daño. El callback global
de RollLog no distingue preparación de aplicación, y un corte deja ese evento.

ToolReplay asigna una referencia efímera y un RollLog diferido por ejecución.
El Agent del beat guarda grupos por referencia, sin incluirla en el JSON ni
llamar al Game desde un closer: algunas salvaciones cierran dentro de evaluar
el cambio en Game. Persistence recoge grupos después de evaluar y guarda
World/comprobante y eventos de dados en una transacción Postgres. Solo tras
el éxito de SQL y Session confirma el prefijo y publica grupos. El resultado
exitoso de roll_dice guarda su comprobante y dados sin cambio mecánico.
Errores SQL revierten el conjunto, se devuelven como fallo recuperable y no
publican la Session candidata. Varias propuestas vacían solo los grupos
confirmados; ejecuciones paralelas no comparten buffers. El hot reload acepta
recorders/structs efímeros anteriores sin campo execution/deferred.

Diez casos nuevos: ocho Game/Postgres y dos RollLog.43 focalizados,14 finales;
gate2422/3 en42,8 s, cero errores/avisos de compilación. Constraint SQL temporal
prueba rollback y posterior commit sin reroll. Concentración preparada e
interior, DM roll_dice, restart/:kill, rechazo y dos ejecuciones intercaladas.
VM19435 offline prueba preparación sin eventos, comprobante/dados junto al
efecto y restart antes del feedback: casilla1/Goblin14/un grupo/turn_id original,
humano27,299 ms; reload375/1440 px/teclado correctos. Adopción19425–19434
conserva estado/modelos/eventos y cierra37 auxiliares. Guion inicial duplicó
pausa; fixture19434 conservado, comprobación completa19435. Ganchos retirados.

No agrega campos de World/Character ni mueve al LLM a Game. La garantía cubre
las tools anunciadas al actor. Narraciones, tiradas standalone e iniciativa/
efectos automáticos fuera de ellas mantienen sus caminos. PubSub sigue siendo
best-effort después del commit: una caída puede dejar un evento durable que
el socket recupere por reload. No promete rollback del RNG ni una transacción
conjunta de todos los eventos de la partida. Conflictos SQL revierten la tool;
no se cambia aquí el mecanismo global de secuencias de eventos.

## D158 — Reserva durable de respuesta PNJ y retorno de una pregunta literal
Fecha: 2026-10-02. Estado: **Aceptada**.

Playtest real19425: pregunta desde la ventana a la posadera, respuesta propia
PNJ, World/biblioteca iguales;16,216 s con unos9 s entre la respuesta y el
relevo. No había cola de respuesta porque Conversation solo representa PCs.
Rojo offline con coordinador adverso: Thane→DM→Lyra→DM antes del humano.

Text reconoce una sola pregunta española completa a rol PNJ cualificado:
primera persona «(le) pregunto a la/al…: ¿…?» o vocativo con artículo. Acepta
el prefijo espacial «desde…» y el preámbulo real «antes de…, ¿…?» con límites.
No registra negaciones, planes, preguntas indirectas, reportes citados ni
varias preguntas; las preguntas PC explícitas conservan prioridad.
Game registra Conversation.request_world al consumir una declaración humana
en exploración. El mapa durable agrega world_recipient y recipients/pending
vacíos, stage world→return. Codec valida ese caso separado del de compañeros:
request_response no admite destinatarios vacíos ni reemplaza una pregunta PNJ.
Las instrucciones indican al DM responder por ese PNJ y devolver la decisión
al humano. La cola usa la orquestación existente, con prioridad de otra
intervención humana y guardas de combate/mini-turn; no inventa consenso ni
mueve personajes. No añade una herramienta anunciada ni campos a World/Character.

Diez casos nuevos/55 focalizados. Gate2432/3 en43,5 s, cero errores/avisos de
compilación. Sintaxis positiva/negativa, JSON/rechazo de mapas malformados,
validación/saneamiento, borrador, sustitución por modelo, prioridad humana y
restart con DM esperando. Misma19425 real: otra pregunta al mismo PNJ vuelve
al humano en8,143 s con voces Mara/DM y coordinador sin ninguna petición,
World/biblioteca iguales, cero dados. Raw DM con prefijos D7 se guarda limpio.
Reload375/1440 px/teclado sin JS/overflow. Adopción19425–19435 conserva estado/
modelos por rol/eventos y cierra41 auxiliares; ganchos retirados. `beta-npc-*`.

Son dos declaraciones distintas: no es un benchmark controlado ni garantía
de percentiles. El ahorro de consulta queda probado por el spy y el historial
vacío del coordinador. Preguntas a nombres libres, preámbulos distintos y
peticiones semánticas siguen su ruta anterior; no amplía el parser general
ni garantiza la verdad de cada dato narrado por el PNJ.

## D159 — Iniciativa automática confirmada antes de Session y publicación
Fecha: 2026-10-02. Estado: **Aceptada**.

Rojo Postgres: rechazar el segundo evento de iniciativa revierte las filas,
pero la Session ya estaba en combate y el primer grupo podía publicarse.
Combat evalúa ahora el cambio sobre un candidato privado. Persistence comparte
con las tools la transacción World/dados y agrega la nota de combate. Solo
después del commit actualiza Session y publica los grupos completos.

Settlement captura el rechazo y pausa conservando actor_checkpoint y enemigos
originales. ToolReplay.clear ocurre después de confirmar la iniciativa:
resume/restart recupera el spawn aplicado y vuelve a intentar la transición.
No añade campos de World/Character ni hace llamadas del LLM dentro de Game.

Tres casos nuevos y26 focalizados verdes: rollback SQL del segundo grupo,
ninguna publicación, éxito posterior y recuperación tanto por resume como
restart. Acceso local restablecido: gate2444/3 en44,6 s sin errores/warnings.
VM19436 guarda dos grupos una vez, reinicia conservando World/historial y
vuelve al humano sin otro spawn. Reload375/1440 px y teclado verificados.
No acredita atomicidad del inicio de turno o narraciones, ni rollback del RNG;
PubSub sigue siendo best-effort después del commit.

## D160 — Mínimo cero después de sumar el daño del arma
Fecha: 2026-10-02. Estado: **Aceptada**.

Con FUERZA6, dado1 y modificador−2, Actions mostraba «por−1 de daño».
Armar Castigo divino producía MatchError al preparar ese daño junto al radiante.
El [SRD5.1, Damage Rolls](https://media.dndbeyond.com/compendium-images/srd/5.1/SRD-OGL_V5.1.pdf)
permite daño cero y excluye daño negativo.

Rules.Combat.damage_total aplica el mínimo al total del mismo tipo después de
aptitud, estilo, Savage Attacks, Sneak Attack, furia y Hunter's Mark. El
subtotal tagged conserva la penalización hasta sumar los bonos; limitarlo
antes regalaría daño. La tirada pública sin bonos adicionales finaliza igual.
Actions usa ese total en feedback, RollLog y preparación; Castigo divino
permanece como componente radiante separado. Un impacto sin daño gasta la
acción, conserva PG temporales/concentración y no agrega fallos de muerte.

Rojo válido: cinco fallos entre ocho casos, incluido MatchError de Smite.
183 focalizados verdes; nueve finales tras añadir PC/TestModel/Session con
tools anunciadas; comprobación conjunta final184 verdes. Controles positivos de furia/marca/Sneak preservan la
penalización y resistencia. JSON round-trip y casilla única comprobados.
Gate completo2444/3 en44,6 s sin errores/warnings. VM19437 guarda arma0,
radiante4/Goblin6/casilla1 antes de la narración; restart recupera comprobantes,
sin más tiradas ni gasto, y retorna a Thane32,78 ms. Reload375/1440 px y fichas
por teclado sin JS/overflow. No cambia structs, tools o resistencias ni
acredita por sí sola la beta.

## D161 — Conservar el subtotal anterior al mínimo de daño
Fecha: 2026-10-02. Estado: **Aceptada**.

La revisión visual de D160 mostró daño0 correcto con penalización−1, aunque
FUERZA6 aplica−2: reconstruir el modificador como total menos dados pierde la
penalización cuando se limita a cero. Actions añade `raw_total` numérico solo
para ese subtotal negativo. RollLog conserva el campo opcional en eventos y
comprobantes; no modifica World/Character ni schema de tools.

RollTotals interpreta ese subtotal únicamente para daño con total0 y valor
numérico negativo. Crónica, tarjeta modal y History comparten la explicación
`d4:1 -2 = 0 (mínimo 0)`. Metadatos inválidos/no aplicables y eventos antiguos
mantienen la presentación previa; no se reconstruye una penalización desconocida
ni se reescribe historial. El dato mejora la explicación, sin cambiar tiradas,
coste, daño aplicado o resistencias.

Cinco casos nuevos más una aserción existente: rojo de cinco fallos y50
focalizados verdes; gate2449/3 en44,3 s sin errores/warnings. VM19438 con
PC/TestModel guarda subtotal−1, arma0, radiante4, Goblin6 y casilla1; restart
antes del feedback conserva efectos/turn_id, sin más dados. Retorna a Thane
en26,544 ms. Reload375/1440 px y teclado sin JS/overflow, captura móvil revisada;
compilación dev final limpia y ganchos retirados.

## D162 — Reservar y confirmar los efectos automáticos de inicio de turno
Fecha: 2026-10-02. Estado: **Aceptada**.

Rechazar el segundo grupo del aura dejaba Session con daño/concentración
aplicados y un primer dado publicado. Evaluar un candidato privado evita
ese adelanto, pero requiere conservar el destino del relevo ya elegido:
varios enemigos comparten DM y una reacción no equivale a un turno principal.

Combat persiste `World.pending_turn` (combatant/kind) antes de lanzar dados,
y Codec valida el marcador sin crear átomos. El candidato, todos los grupos
save/damage/concentración y retirada del marcador se confirman en la misma
transacción. Session y PubSub siguen el commit. Un rechazo pausa conservando
la reserva y los efectos previos; Game la reintenta antes de cualquier beat.
Bootstrap recupera el carácter de reacción/propietario principal. Eventos
viejos sin marcador siguen válidos; no cambia los structs de personajes.

Son dos escrituras deliberadas: reserva y resolución. Permiten recuperar un
corte antes de tirar y otro después del commit sin repetir daño confirmado.
No guardan/retroceden el estado del RNG ni garantizan escritura con SQL caído.
El cierre posterior del combate, notas de relevo y narraciones no forman parte
de esta transacción. PubSub permanece best-effort.

Seis casos nuevos (cuatro rojos iniciales) y82 focalizados verdes; gate2455/3
en45,4 s sin errores/warnings. VM19439 interrumpida con roller esperando y
reserva durable: parada supervisada5014,012 ms, World previo intacto/cero
eventos; restart aplica aura3/Goblin97/concentración perdida, tres grupos y
cinco dados. PC/TestModel recibe97/100 y segundo restart no vuelve a tirar.
Adopción19425–19438 conserva estado/historial/modelos por rol y cierra52
auxiliares. Reload375/1440 px/teclado sin JS/overflow, captura de escritorio
revisada; compilación/formato/diff limpios y ganchos retirados.

## D163 — Confirmar el cierre de combate, sus intenciones y notas juntos
Fecha: 2026-10-02. Estado: **Aceptada**.

Rechazar una nota del cierre dejaba Session en exploración pese al rollback
SQL. Eliminar intenciones escribía por separado; la segunda nota podía
fallar después de publicar la primera. Reabrir el World de una victoria
ya guardada tampoco liquidaba la fase antes de esperar otra acción.

Combat prepara World.end_combat, intenciones conservadas y notas sin mutar
Session. Persistence confirma World/estado/intenciones/notas en la misma
transacción; Session y señal de actualización siguen el commit. Un rechazo
pausa conservando el estado anterior y el comprobante del actor. El catch
transporta ese estado al tick o Settlement sin seguir el relevo fallido.
Game liquida una victoria durable antes de esperar/consumir una declaración
cuando no existe actor pendiente; si existe, primero recupera sus resultados.
Settlement no borra el comprobante hasta confirmar el cierre. World limpia
pending_turn al empezar/terminar combate. Sin structs ni migraciones nuevos.

Siete casos nuevos y52 focalizados: rollback de ambas notas, resume/restart,
recuperación del ataque ganador antes del feedback y tras rechazo de cierre.
Gate2462/3 con trazas en53,6 s sin errores/warnings; uno anterior en46,3 s
registró tres desconexiones de limpieza, no reproducidas en la suite trazada
ni17 focalizados. Esa incidencia sigue abierta, sin parches especulativos.
VM19440 cierra derrota guardada sin modelo/dados, conservando intención de
exploración; VM19441 recupera el golpe ganador una vez con turno original y
dos dados. Segunda reapertura conserva World/historial/notas. Adopción15
mesas propias/modelos por rol,56 auxiliares cerrados; reload375/1440 px y
teclado sin JS/overflow. Compile/formato/diff limpios, ganchos retirados.

Narraciones, relevo posterior y RNG no heredan esta transacción. Conservar el
comprobante permite recuperar sus resultados, sin garantizar todavía una
única publicación de toda respuesta del modelo al repetir la liquidación.

## D164 — Liquidar una respuesta completa sin volver a solicitarla
Fecha: 2026-10-02. Estado: **Aceptada**.

Una victoria podía guardar el golpe y publicar la respuesta final, pero fallar
al confirmar el cierre de combate. El comprobante D163 permitía recuperar las
tools; al solicitar otra respuesta se añadía un segundo párrafo final al mismo
turno. Dos rojos reproducen la duplicación por resume y restart.

Events incluye un booleano `complete` en la narración saneada: verdadero solo
para texto no vacío sin tools y sin finish_reason length/content_filter.
Games busca ese comprobante por partida, actor y turn_id. Beats lo reutiliza
solo cuando ToolReplay restaura el comprobante durable de ese mismo actor/
turno. Devuelve el resultado a Settlement sin petición, streaming ni evento
nuevo; la escena pendiente mantiene su registro independiente. No registra
uso de tokens ficticio por esa recuperación. Sin structs ni migraciones nuevos.

No deduplicamos por texto ni reducimos el turno a un párrafo: dos declaraciones
iguales junto a tools pueden ser legítimas. Texto parcial/filtrado, completamente
saneado a vacío y eventos antiguos sin marcador no prueban finalización. El
fallback de recuperación previo sigue disponible en esos casos. Las ventanas
sin comprobante de actor, los intentos incompletos y el relevo posterior siguen
abiertas; esto no convierte toda la liquidación en una transacción ni persiste
el RNG. Se conserva la compatibilidad de las crónicas antiguas.

Siete casos nuevos (cinco de publicación y dos cortes DM por restart/kill) y
cinco casos anteriores reforzados: golpe ganador antes/después del feedback,
rechazo de cierre e iniciativa. 49 focalizados; gate2469/3 en46,0 s limpio.
Dos expectativas antiguas que exigían otra petición al DM pasan a verificar
el siguiente turno real del goblin, ya en combate, con la respuesta original
visible una sola vez. Compile/formato/diff limpios.

VM19442 interrumpida durante el registro de escena, después de publicar la
respuesta: restart16,606 ms, cero peticiones al actor, descanso28800 s/límites
intactos y dos intervenciones originales. Completa la escena y vuelve al humano;
otro restart conserva World/historial. Reload375/1440 px, fichas por teclado,
sin JS/overflow y capturas revisadas. Ganchos retirados. La incidencia de limpieza
D163 no reaparece en el gate, pero no se acredita resuelta.

## D165 — Explicar la operación del reloj en el contexto del DM
Fecha: 2026-10-02. Estado: **Aceptada**.

La continuación real19425 decide salir solo después de las respuestas propias
de Lyra/Vex. Declara quince minutos de marcha y llega al molino; el DM llama
set_scene, pero no advance_time. World cambia de lugar con reloj32400 intacto.
El contrato de resolución humana reserva viajes/tiempo al DM, mientras su
contexto solo mostraba el reloj y pedía actualizar escena. La validación y
caducidad de WorldClock ya funcionan; no se sustituye ese motor por narración.

Brief añade una instrucción operativa solo al DM en exploración: registrar con
advance_time los segundos realmente consumidos de un viaje/espera declarado,
una vez antes de narrar llegada. Cambiar escena no aplica tiempo. Preguntas,
propuestas pendientes e indicaciones de distancia/duración de rutas no lo
consumen; rests ya aplican su intervalo. Sigue siendo el modelo quien selecciona
la tool y la duración; el motor valida y resuelve el cambio y sus caducidades.
No se añade parser de intención, campos de World, nuevas tools ni reparación
retroactiva automática. La guía no constituye una garantía de selección del LLM.

Dos rojos de entrega del contrato; dos smokes Game/TestModel con viaje de900 s,
Inspiración caducada, PG/casillas/rest_state conservados y recuperación tras
avance sin sumar otro intervalo. Un caso de scope DM/PC/TM/combate.35 focalizados,
gate2472/3 en46,9 s limpio; compile/formato/diff correctos.

En19425, la invitación conserva World en17,833 s. La primera marcha34,751 s
revela la omisión. Tras activar el nuevo contexto sin cambiar World/modelos,
confirmar explícitamente el tramo anterior registra900 s en35,721 s. El siguiente
viaje de quince minutos llega a la plaza/taberna con reloj34200 en47,54 s.
Solo cambian reloj/log/escena; biblioteca, fichas, recursos y hechos intactos,
cero dados nuevos. Restart conserva World/historial/modelos por rol y cierra
cinco auxiliares. Reload375/1440 px/teclado sin JS/overflow; siete dados anteriores
siguen visibles. Ganchos retirados, capturas revisadas.

Se acredita este recorrido con el mismo proveedor. La confirmación del tramo
omitido fue explícita y las latencias no son percentiles. La llegada incluye
Vex/DM adicional y el último history DM ya pertenece a ese cierre: su lista
vacía de tools no prueba que el beat de viaje omitiera tiempo. Revisar latencia,
registro de duraciones en otras declaraciones y continuidad con Maribel.

## D166 — Revisar el entorno tras movimiento humano sin registro
Fecha: 2026-10-02. Estado: **Aceptada**.

La entrada real19425 se narra dentro de la taberna, pero World conserva la
plaza. D145 solo solicitaba instantánea tras tiempo positivo, hechos nuevos o
fin de combate; no había esas señales ni set_scene. La traza atribuye6,5 s a
las dos narraciones y8,7 s al TM de15,713 s. El diálogo literal con Maribel
no consulta TM y conserva World en8,657 s. No se supone que toda esa consulta
sea prescindible: en exploración puede dar voz a un compañero disponible.

Beats añade scene_before al evento de una declaración humana de movimiento
literal en exploración. Es una señal de revisión, sin interpretar destino,
distancia o tiempo ni ejecutar el movimiento. SceneRefresh compara esa escena
con la vigente, el actor/turn_id de la última acción y el último turno humano.
Excluye conversación, autoplay, mini-turnos/re-evaluación y un set_scene ya
confirmado por el DM. Una escena modificada por el humano también excluye la
consulta; el primer gate revela esa compatibilidad y se añade su regresión.
Los eventos antiguos sin scene_before conservan su ruta, sin reescribirlos.
El vocabulario es afirmativo en primera persona, con saludos/despedidas
acotados antes del movimiento; preguntas, propuestas, citas y otros actores
no activan la revisión. No es un parser general de intenciones.

Reutiliza el recorder estructurado D145, su modelo y sus límites/guardas, sin
tools de reglas. Permite confirmar el entorno idéntico con :skip y sin escribir
solo si no había marca del motor pendiente; esa marca conserva el rechazo de
copiar la escena antigua. Un fallo de revisión añade la marca existente vía
Game/Session y la liquidación la persiste, sin repetir narraciones o reglas.
La aplicación de éxito/fallo compara World esperado y no pisa cambios
concurrentes. No se añaden World/structs/migraciones ni un segundo escritor.
Las ventanas de caída durante la revisión antes de liquidar mantienen el
alcance de recuperación D164; esto no garantiza cualquier prosa ni semántica.

Once casos nuevos, seis rojos iniciales y68 focalizados. Primer gate con una
regresión de escena humana y dos desconexiones Postgrex de limpieza. Corregido
el gate funcional,2483/3 con trazas/seed8106 en54,4 s sin errores/warnings;
la incidencia de limpieza sigue abierta. Compile/formato/diff correctos.

19425 con modelos conservados: acercarse a la barra22,895 s, dos peticiones
DM sin tools, recorder9,579 s/un paso y TM6,274 s; solo escena/log cambian a
interior, reloj34200 y recursos/biblioteca/encargo intactos, cero dados nuevos.
El recorder de esta mesa usa deepseek-v4-flash-0731, conservado desde antes;
no es una comparación con el resumidor por defecto de mesas nuevas. Preguntar
por menú5,026 s mantiene World sin TM/recorder extra. Restart conserva todo y
cierra cinco auxiliares; reload375/1440 px/teclado sin JS/overflow, capturas
revisadas, ganchos retirados. Datos individuales, sin mejora global/SLA probado.
Revisar esperas, movimientos fuera del vocabulario y la invitación gratuita
anterior frente al precio general comunicado por Maribel.

## D167 — Publicar el interrogante PNJ sin una reformulación del modelo
Fecha: 2026-10-02. Estado: **Aceptada**.

Las preguntas PNJ D158 ya fijan destinatario y retorno, pero el beat humano
todavía consulta al modelo para repetir lo que el jugador dijo. En D166 esa
petición tarda2,648/1,826 s antes de la respuesta PNJ. Si la declaración solo
contiene una pregunta informativa literal, no aporta una resolución de reglas.
Eliminarla requiere comprobar también el texto que rodea el interrogante:
una pregunta seguida de magia, pago o movimiento conserva trabajo real.

Text.literal_npc_speech reconoce una gramática más estrecha que D158: un
interrogante informativo, prefijo de habla/lugar acotado y espera pasiva, con
permiso opcional de escuchar para nombres PC registrados. Conserva las palabras
del interrogante, sin narrar el prefijo/espera. Peticiones de persuasión y
prefijos/colas inciertos conservan la ruta de modelo. Conversations exige una
cola PNJ cuyo actor y declaración coincidan, exploración humana manual y
ausencia de autoplay/mini/re-evaluación/interrupción. No interpreta semántica
general, ejecuta acciones ni amplía la lista D158 de destinatarios.

Beats pasa ese texto al Task habitual después de registrar la acción/cola.
Events.publish_speech aplica Text.scrub con roster vigente y los mismos datos
de actor/turno, persistencia y PubSub de las narraciones del modelo. Marca
habla completa; el Task devuelve texto/rolls vacíos/usage nil a Settlement.
El relevo DM y su respuesta continúan por los contratos existentes, con la
pregunta publicada en shared history. No crea tokens ficticios ni un segundo
escritor de World. Sin nuevos campos de World, structs o migraciones.

La ruta no elimina la resolución de una declaración mixta: pregunta con
False Life solicita al modelo humano y conserva herramienta, casilla, dado y
PG temporales5. Tampoco convierte una pregunta persuasiva en éxito gratuito.
La ventana de caída humana sin actor_checkpoint entre publicación y relevo
mantiene el alcance de D164; no se presenta como recuperación universal.

Siete casos nuevos (tres puros, tres Game y uno LiveView), cinco rojos iniciales,
69 focalizados en3,9 s. Scripts PNJ previos pasan a recibir primero la petición
DM; el caso de intento de reemplazar destinatario añade una observación para
conservar el beat humano con tools. El test de restart usa TableSupervisor por
Game.ensure_started y comprueba otro PID/una intervención, no un fixture directo.
Gate ordinario2490/3 en47,6 s, seed886859, sin errores/warnings; compile/formato/
diff limpios. La limpieza Postgrex anterior no reaparece ni se considera resuelta.

19425/modelos conservados: la pregunta sobre la invitación vuelve en4,536 s,
con una petición DM3,911 s y ninguna humana/TM/recorder/tools/dados. Maribel
confirma guiso/pan/jarra gratuitos y vino/licor aparte. World/reloj34200/
recursos/biblioteca iguales; no se consumió ni cobró comida. Restart conserva
World/historial/cursor/intenciones/modelos y cierra cinco auxiliares; reload
375/1440 px/teclado sin JS/overflow, capturas revisadas y ganchos retirados.
Se acredita una petición eliminada; preguntas distintas no prueban mejora
global/SLA. Continuar servicio/elección con voz propia IA y hechos durables.

## D168 — Recordar la voz propia al responder una pregunta compartida
Fecha: 2026-10-02. Estado: **Aceptada**.

En19425, el pedido de comida tiene actores/relevo correctos y World intacto,
pero Vex copia casi toda la frase y el gesto anterior de Lyra (bastón→arco,
semanas→días). Ambos reciben agentes/identidad propios e historia común. El
turno de respuesta pedía personalidad, sin distinguir explícitamente ese
historial de un guion; el anti-loop compara turnos del mismo actor y no debe
prohibir que dos personajes acepten legítimamente la misma invitación.

PCAgent.instruction recuerda la personalidad de clase junto a la pregunta
pendiente, permite acuerdo con palabras propias y prohíbe copiar frases/gestos
o inventar desacuerdo/hechos para diferenciarse. Solo afecta al destinatario
actual de la cola: turnos ordinarios, combate y estados a0 PG mantienen sus
contratos. Conserva shared history y respuestas; no descarta una coincidencia
ni añade reintentos, tools, campos o escritores de World. No promete que el
LLM produzca siempre prosa original.

Tres casos nuevos, dos rojos iniciales,39 focalizados en2,2 s. Game inspecciona
messages codificados, identidad/voz cercanas a la pregunta y respuesta previa
íntegra; conserva también los dos fixtures coincidentes, cuatro actores una
vez y World igual. Gate2493/3 en47,4 s, seed597997, sin errores ni desconexiones;
ocho avisos de ejecución, cinco del breaker simulado y tres de fixtures
anteriores. Nueva pregunta
real10,198 s muestra acuerdo con prosa diferente, cuatro peticiones y recursos/
biblioteca/reloj34200 iguales, sin TM/recorder/tools/dados. Browser375/1440 px/
teclado verificados. No compara latencia de preguntas distintas ni fuerza
opiniones diferentes. El gate D169 y el reinicio posterior conservan la entrega.

## D169 — Acortar el historial con límites Unicode
Fecha: 2026-10-02. Estado: **Aceptada**.

La espera real de veinte minutos publica la narración humana, pero su siguiente
petición DM falla antes del proveedor con Jason.EncodeError. La pregunta del
menú (seq234), válida en DB, acaba de salir de las doce narraciones recientes.
History sanea al construir mensajes y comprime después. Su regex de primera
frase no tenía Unicode: la clase con ¡ admite por separado0xC2, compartido por
¿ y el espacio inseparable, y corta dejando un byte líder sin continuación.
No es salida inválida del proveedor ni pérdida de credenciales.

El patrón cuenta caracteres Unicode y termina solo en .!?. El fallback sigue
usando String.slice; se preservan atribuciones, mensajes recientes y longitud
acotada sin modificar eventos guardados. No se añade un saneamiento posterior
que borre el signo partido y oculte la causa. Sin World/structs/migraciones,
herramientas nuevas ni alteraciones del orden compartido.

Tres rojos/tres casos nuevos: fixture exacto tras doce voces, ¿/¡/NBSP y JSON
del proveedor; Game cruza el umbral entre humano/DM, aplica1200 s/escena y
reinicia sin repetir tiempo/recursos/historia.18 focalizados en0,6 s, gate2496/3
en47,1 s, seed681098, sin errores/desconexiones ni avisos de compilación.
Diez avisos de ejecución: cinco del breaker simulado y cinco de fixtures
anteriores. La verificación adicional refuerza tres casos WorldFacts y dos
de intenciones/reacción: fin de beat, persistencia y efecto efectivo de Escudo,
con control negativo que falla al retirar set_scene. Un caso antibucle y tres
de narración DM reciben modelos PC/DM separados y verifican respuestas
completas;38 focalizados en2,0 s, sin errores/avisos. No añade esperas para
ocultar errores ni cambia producto. Compile/formato/diff limpios; la limpieza
intermitente Postgrex anterior permanece abierta.
Gate final de esa verificación,2026-10-03:2496/3 en48,0 s/seed30343,
sin errores/desconexiones/avisos inesperados; cinco avisos del breaker
con errores400 simulados, sin avisos de compilación.

19425/modelos conservados: espera3,504 s falla en JSON con World igual. Tras
corregir, la respuesta6,6 s llega, pero el modelo omite advance_time. Confirmar
explícitamente1200 s en20,451 s aplica34200→35400 una vez: la tool humana se
rechaza y DM la confirma. Recorder3,699 s actualiza cuenco vacío; solo reloj/
log/escena cambian, recursos/biblioteca iguales, cero dados. La omisión natural
es independiente y queda abierta; el smoke guionizado no acredita resolverla.
Restart mantiene todo, UTF-8/JSON válidos y cinco auxiliares cerrados. Reload
375/1440 px/teclado sin JS/overflow, capturas revisadas, ganchos retirados;
siete dados históricos intactos, cero en ventana reciente. Revisar duración
declarada fiable y fidelidad/durabilidad de los hechos narrativos nuevos.

## D170 — Exigir la resolución de una espera literal antes de aceptar el cierre DM
Fecha: 2026-10-03. Estado: **Aceptada**.

D169 elimina el fallo JSON, pero la espera original de veinte minutos sigue
sin avanzar el reloj. El texto original llega al shared history; una guía
genérica no impide que el DM termine con una narración sin herramientas.

WaitDeclaration reconoce esperas afirmativas con cantidad/unidad, calcula
segundos y limita un único intervalo a24 h. Beats añade wait_seconds y
clock_before al evento de acción del humano en exploración manual. Excluye
preguntas, propuestas/condicionales, citas/retellings, múltiples intervalos,
rests y viajes; los demás textos mantienen su resolución existente. No
interpreta esa declaración como éxito ni adelanta automáticamente el reloj.

WaitResolution recupera la acción pendiente para el DM y entrega su fuente y
duración junto al turno actual. Una capability permite texto final solo tras
registrar la resolución; Events y streaming no publican una final pendiente.
El DM selecciona advance_time para el intervalo completo o los segundos
realmente consumidos por una interrupción (incluso0); el motor valida el rango
y aplica WorldClock/caducidades. Entrar en combate también interrumpe la espera.
Una omisión recibe el reintento acotado de output; si sigue pendiente, Game
pausa conservando actor/declaración y puede reanudar sin volver a declarar.

La capability cambia allow_text_output para la aceptación del motor, conserva
el modo de herramientas normal del proveedor. El driver actual de exAgent
captura params antes de los hooks: cambiar output_mode ahí llegaría un paso
tarde y exigiría otra llamada después del registro. No se parchea la dependencia
ni se oculta ese desfase con un oráculo de parámetros más débil; se comprueban
la tool y el reloj realmente confirmados antes de aceptar/persistir la final.

World.resolve_wait guarda un comprobante acotado wait_resolution con el origen
del turno humano, segundos declarados/consumidos y relojes anterior/posterior.
Codec lo valida explícitamente, legacy sin campo carga nil. La guardia se
evalúa dentro de RuleCheckpoint con el World vigente, por lo que duplicados
y llamadas paralelas no cobran otro intervalo. El comprobante se persiste
con el efecto y sobrevive al borrado del actor_checkpoint: una interrupción
parcial o inmediata no puede cobrarse completa en un turno DM posterior.
Solo se conserva el último; un nuevo turno humano autoriza otro intervalo.
Sin cambios de Character/Weapon/Spell/Item ni consultas DB en builder.

Dieciséis casos nuevos, cuatro rojos de gramática y tres Game iniciales;
cuatro rojos de comprobante motivan su persistencia independiente.27 focalizados
en1,4 s; gate2512/3,48,0 s/seed944912, registra limpieza intermitente anterior.
La traza mismo seed/max_cases1 pasa2512/3 en56,4 s sin esos errores; causa abierta.
Una repetición55,3 s registra una desconexión y una terminación Game; también
usa max_cases1 aunque se solicitó48 con --trace. No prueba concurrencia ni
identifica todavía la causa de limpieza.

19425/modelos conservados: espera natural de cinco minutos registra300 una
vez,35400→35700; llamada humana rechazada, DM confirmado, sin dados/recargas.
También establece el rumor previo como fact.32,603 s con recorder10,567 s y
consulta TM; la narración repite casi literalmente el rumor anterior. No
certifica mejora de latencia, originalidad ni la selección semántica de toda
interrupción. Restart/reload375/1440 px/teclado mantienen World/comprobante/
historial/modelos y biblioteca, JSON válido, cinco auxiliares cerrados,
capturas revisadas y ganchos retirados. Ampliar otras duraciones y reducir
peticiones/narración repetida; la beta sigue en preparación.

## D171 — Publicar una espera pasiva literal antes de resolverla con el DM
Fecha: 2026-10-03. Estado: **Aceptada**.

La espera real D170 conserva el reloj, pero su beat humano pide al modelo
reformular la intención e intenta advance_time, rechazado por el control DM.
Ese trabajo no resuelve ninguna acción propia del personaje y añade peticiones.

WaitDeclaration.literal_speech reconoce una gramática más estrecha que la
duración D170: espera/aguardo o permanencia con cantidad/unidad y ubicación
pasiva explícitamente admitida. Devuelve el texto original mediante Text.scrub.
Las formulaciones con otras acciones o contexto incierto conservan el beat
humano normal; una espera seguida de False Life sigue gastando casilla/dados.

Beats utiliza la publicación Events ya existente para habla humana literal
cuando esa acción acaba de recibir wait_seconds/clock_before y no hay
conversación, intervención o mini-turn. La acción, su turno y la cola siguen
registrados por Game. Publicar «Espero…» no confirma que haya transcurrido
tiempo; el DM posterior recibe la declaración y el contrato D170. El motor
mantiene el reloj sin cambios hasta el registro de duración/interrupción.
La recuperación D164 conserva una voz humana completa sin volver a publicarla.
No cambia el modelo seleccionado, las reglas de World ni los structs de ficha.

Siete casos nuevos: tres de gramática y cuatro Game verifican peticiones
exclusivamente DM, palabras originales/historia/recursos, reinicio antes del
reloj, hechizo mixto y declaración pausada sin publicación anticipada.
El primer rojo pasa1/7; una expectativa sobre eventos iniciales se corrige
para comparar la cola con su propio historial de partida.29 focalizados en
1,2 s; gate2519/3 en47,0 s, seed944912/max_cases48, sin errores/desconexiones.
Cinco avisos esperados del breaker; limpieza SQL histórica sigue abierta.
Compile con warnings-as-errors, formato global y diff correctos.

19425/modelos iguales: «Espero tres minutos junto a la barra.» vuelve en
17,884 s, cero peticiones humanas, dos DM y advance_time180 una vez. Reloj
35700→35880, recursos/biblioteca iguales y cero dados. TM agota tokens en una
petición y aplica fallback; recorder3,853 s devuelve escena idéntica y deja
scene_refresh_pending=true. El PNJ amplía el rumor con pago/monedas/herrero,
solo en historial. No es un benchmark ni cierra esas incidencias narrativas.
Restart/reload375/1440 px/teclado conservan estado/historial/modelos/JSON y
cierran cinco auxiliares; capturas revisadas, ganchos retirados. El recolector
QA se recupera tras perder su módulo durante recompilación: no se descarta
esa incidencia ni se confunde con un fallo del motor. Beta sigue en preparación.

## D172 — Confirmar una escena idéntica solo tras una espera aislada verificable
Fecha: 2026-10-03. Estado: **Aceptada**.

D171 registra180 s, pero SceneRecorder devuelve el entorno idéntico y la
revisión queda pendiente. D166 admite confirmación de un movimiento local
cuando no había revisión mecánica pendiente; ampliarlo globalmente permitiría
ignorar hechos, descansos o cambios posteriores al snapshot.

World.resolve_wait añade scene_review_fingerprint al mapa del comprobante,
solo si el World anterior no tenía revisión pendiente. SHA-256 sobre su
representación determinista excluye elapsed_seconds, scene_refresh_pending,
wait_resolution y actor_checkpoint; conserva todo el resto del estado.
No hay nuevos campos de ficha, struct World ni migración. Codec valida64
caracteres hexadecimales minúsculos. Una huella inválida se retira sin perder
el comprobante válido del tiempo: no puede habilitar revisión ni cobrar de nuevo
un efecto confirmado. Legacy continúa sin huella.

SceneRefresh acepta una respuesta estructurada exactamente idéntica si el
intervalo tiene la misma fuente, duración, reloj inicial/final y estado de
entorno. Admite un intervalo parcial positivo. En memoria puede usar el World
anterior real para legacy; al recuperar usa la huella durable. Un entorno ya
pendiente, facts/recursos/escena distintos, otro reloj o fuente no coincidente
no reciben este permiso. La instrucción condicional del recorder explica que
solo el paso del tiempo no exige reescribir; puede registrar cambios de entorno
establecidos en los eventos. No fuerza al modelo a confirmar.

El Task propone; Game compara el World actual con el esperado y vuelve a
verificar el intervalo antes de limpiar únicamente scene_refresh_pending.
No modifica escena, log, cola, reloj ni recursos. Un resultado obsoleto deja
la revisión pendiente. WaitResolution.review_request recupera la fuente del
último action aun si D164 ya conservó la final DM: se reanuda solo el registro,
sin otra petición al actor ni publicación/tiempo duplicados.

Diez casos nuevos: siete de guardas/Codec/instrucciones y tres Game de flujo,
pausa y reinicio durante recorder. Rojo inicial1/6; recuperación7/9 y guía6/7
antes de implementar cada parte.53 focalizados en1,7 s/seed181952.
Gate final2529/3 en47,6 s/seed944912/max_cases48: una desconexión owner SQL,
un aviso TestModel agotado y cinco avisos deliberados del breaker; cero Games
terminados. Traza2529/3 en55,2 s/max_cases1 sin esas incidencias. La limpieza
intermitente sigue abierta. Compile/formato/diff correctos.

19425/modelos conservados:120/60 s naturales una vez,35880→36000→36060,
13,246/18,890 s hasta humano, sin petición humana/dados/gasto. Recorder4,904/
4,914 s reescribe ambas escenas por el contexto PNJ; la rama idéntica está
probada offline, incluido restart, todavía no observada con proveedor real.
La revisión legacy previa5,927 s actualiza escena sin aplicar reloj. Su oráculo
QA inicial compara JSON crudo con claves enteras de Codec y falla; se corrige
a comparar Worlds decodificados, sin mutación en el intento fallido.
Dos reinicios/reloads375/1440 px/teclado preservan estado/modelos/historial/
biblioteca/JSON y cierran cinco auxiliares cada uno; capturas revisadas y
ganchos retirados. La escena aún mezcla entorno, pregunta/gestos PNJ y una
jarra a medio vaciar. Continuidad narrativa y latencia siguen bajo revisión;
estos tiempos no constituyen un benchmark. Beta sigue en preparación.

## D173 — Separar el registro del entorno del diálogo PNJ en su instrucción
Fecha: 2026-10-03. Estado: **Aceptada**.

Las muestras D172 convierten la escena en un resumen de preguntas, ofertas
y gestos de Maribel. El prompt excluía diálogo/acciones de PCs, pero no
explicaba esa separación para los PNJ ni cómo tratar un registro ya mezclado.

SceneRecorder recibe una guía explícita: referencia del lugar, objetos y
condiciones físicas establecidos; omitir diálogo PNJ, preguntas/ofertas/rumores,
gestos pasajeros e inferencias de pensamientos. La conversación permanece en
history y los datos duraderos en facts. Al actualizar un registro mezclado,
conservar los detalles físicos establecidos sin inventar cantidades/consumo
por el paso del tiempo. Se mantienen schema1200, presupuesto, tools vacías,
guardas de agencia, confirmación D172 y aplicación exclusiva por Game.
Es una corrección de instrucciones, no un clasificador semántico determinista
ni una migración de escenas antiguas.

Un smoke Game nuevo verifica messages codificados enviados al proveedor,
snapshot físico, narración PNJ íntegra una vez,120 s/recursos/DB/Codec/restart.
Rojo0/1 por guía ausente;27 focalizados en0,7 s. Gate2530/3 en47,9 s,
seed944912/max_cases48: una desconexión SQL y una terminación Game/snapshot;
solo cinco avisos deliberados del breaker. Causa de limpieza sigue abierta.
Compile/formato/diff correctos.

19425/modelos iguales:30 s naturales una vez,36060→36090,21,956 s hasta
humano, DM2/TM2/recorder5,576 s. Sin petición humana/dados/gasto. La escena
baja915→662 caracteres y retira pregunta/oferta, pero mantiene manos apoyadas
y jarra a medio vaciar. El DM añade salida del forastero al norte a mediodía
sin actualizar facts. No acredita calidad semántica general ni mejora de
latencia; continuar continuidad narrativa y decisiones de avance del DM.
Restart/reload375/1440 px/teclado conservan World/historial/modelos/biblioteca/
JSON y cierran cinco auxiliares. Capturas revisadas, gancho retirado; beta
sigue en preparación.

## D174 — Cerrar las LiveViews de prueba después de devolver su conexión SQL
Fecha: 2026-10-03. Estado: **Aceptada**.

La traza de Game.init/snapshot y procesos atribuye la desconexión al caso de
ficha/recarga del druida transformado. ExUnit termina una LiveView mientras
esta posee la conexión Sandbox compartida. El snapshot en cola del Game
falla antes de cerrar el owner: no es un owner liberado prematuramente en
esta reproducción. Los títulos SQL cercanos no identifican el test causante.

ConnCase importa los helpers de Test.LiveViewFixture en lugar de duplicar
los de Phoenix. Sus macros live/live_isolated/follow_redirect delegan en
Phoenix, preservan retornos y registran un hijo después de cada canal montado.
ExUnit cierra hijos en orden inverso; ese hijo solicita GenServer.stop
síncrono, dejando terminar el callback/consulta en curso antes de salir.
Si la navegación ya cerró la vista, la carrera es inocua. Un fallo/timeout
con vista aún viva no se silencia. Cada vista tiene su propio hijo; el cierre
de una no termina el Game ni las otras. Solo se administra el montaje que
pasa por estos helpers; no se afirma cubrir todo patrón histórico de owner.

Dos pruebas usan una consulta real retenida por advisory lock de PostgreSQL
y dos vistas de un Game pausado. Verifican devolución de conexión, snapshot
en cola, World/historial/DB y segunda vista vivos. La conexión de control usa
la misma base test; no realiza peticiones al LLM. Un segundo seed descubre
otra carrera de fixture: TMSpy vinculaba su contador al proceso del test,
que moría antes de una última petición. Ahora ExUnit supervisa el contador
antes de su Game y lo cierra después; el contador y sus oráculos no cambian.
No se modifica código productivo ni dependencias para ocultar estos errores.

Rojo0/1 por ausencia del hijo de cierre;34 focalizados en6,7 s y45 incluyendo
TurnMaster en7,1 s, limpios. Gate2532/3 en48,0 s/seed944912/max_cases48 limpio;
intermedio49,0 s/seed30343 sin desconexiones pero con tarea/aviso TMSpy.
Tras corregir su ciclo de vida,2532/3 en48,2 s/mismo seed/max_cases48 sin
errores/desconexiones, solo cinco avisos deliberados breaker. Compile/formato/
diff correctos, traza temporal retirada. Los errores históricos de owner
sin atribución exacta conservan seguimiento; beta sigue en preparación.

## D175 — Una espera deliberada recibe un ritmo propio, no una orden de novedades
Fecha: 2026-10-03. Estado: **Aceptada**.

La muestra D173 de treinta segundos cierra el mercado, retira un forastero
y anuncia la tarde sin registrar hechos nuevos. Guardrails ya considera una
declaración progreso, pero el turno DM ordinario ordenaba introducir novedades
si la escena parecía parada. El prefijo estable también exigía avance sin
explicar que esperar es una decisión. Hay instrucciones de ritmo en conflicto.

Game usa el request D170 sobre400 eventos para seleccionar una instrucción
de espera deliberada, después de una conversación activa y antes de las
guías de limbo. Conserva los últimos40 para las guardas previas. La instrucción
permite ambiente estable, mantiene escena/agencia/estilo, no cierra hilos ni
retira PNJs solo por novedad y recuerda que el reloj relativo no es hora del
día. Un suceso coherente aún puede interrumpir: el motor registra la duración
real, incluida parcial/0 s. La guía común de agencia formula condicionalmente
los cambios del entorno; la orden explícita de avance permanece en los
atascos reales. El prefijo DM incluye la misma excepción a su regla de ritmo.

No se añade detector semántico de cierre de trama, migración de narraciones
ni registro automático de rumores como verdad. La selección de contexto es
determinista; la fidelidad narrativa sigue dependiendo del modelo. World,
Codec, tools y reglas de reloj/interrupción mantienen su contrato.

Cuatro casos nuevos prueban messages reales del adaptador antes/después de
la tool, recursos/hechos/escena, parcial5 s/restart y restart pendiente sin
duplicar voz/reloj, con control de guías ordinarias/limbo. Rojo1/3;46
focalizados en1,7 s, siete tras el último ajuste en0,5 s. Gates2536/3 en47,9/
48,8 s, seeds30343/944912/max_cases48, sin errores ni avisos inesperados;
cinco deliberados breaker. Compile/formato/diff correctos.

19425/modelos conservados:15/15 s una vez por fuente distinta,36090→36105→
36120,17,877/14,256 s hasta humano, escena/hechos/recursos iguales. Ambas
confirmaciones idénticas D172 se observan por primera vez con proveedor.
Recorder3,855/3,623 s; TM agota tokens/fallback en la primera y completa dos
peticiones en la segunda. No es comparación de rendimiento. Restart/reload
375/1440 px/teclado conservan World/historial/modelos/biblioteca/UTF-8/JSON
y cierran cinco auxiliares; capturas revisadas, ganchos retirados. Persisten
atribución/durabilidad PNJ, repetición sensorial y latencia; beta en preparación.

## D176 — Memoria de testimonios PNJ atribuida y separada de hechos confirmados
Fecha: 2026-10-03. Estado: **Aceptada**.

D171/D173 narran información duradera sin guardarla, mientras establish_fact
permite frases sin fuente y Brief las presenta como verdad canónica. Que un
PNJ diga que alguien salió del pueblo no confirma la salida ni la dirección.
El contrato carecía de una operación explícita para recordar esa versión.

record_npc_statement(speaker, statement), solo DM, propone por Game/Checkpoint
un cambio World con texto atribuido en facts existentes. NPCStatement sanea
ambos argumentos, normaliza NFC/espacios/citas internas, limita80/800 y valida
fuente completa/corta frente a PJ; un NPC conocido con prefijo compartido
tiene identidad propia. Una alegación citada sobre un PC no hace actuar al
PC. Usa la misma idempotencia/cap30 y persistencia/replay, sin campos nuevos
ni migraciones. No valida la existencia de un PNJ no representado en World
ni la veracidad de su relato: el DM aporta la fuente y el contenido.

Guardar testimonio no cambia el entorno físico. Conserva la marca previa
de revisión, sin crear ni limpiar una aquí; una modificación física real
requiere las herramientas correspondientes. Brief explica que la atribución
es canónica y el contenido sigue por comprobar, para DM/PC/TM. Instrucciones
DM/PNJ/resumen conservan fuente/dudas y guían cuándo usar la nueva tool;
establish_fact queda para hechos establecidos. Text también retira su nombre
si el modelo escribe una invocación como narración. No se extraen testimonios
de texto libre automáticamente ni se reclasifican facts antiguos por inferencia.

Diez casos nuevos verifican contrato, límites, permisos/Unicode/citas/scrub,
World/DB/Codec, ausencia de TM/recorder en respuesta PNJ, checkpoint/restart/
replay sin duplicar y contexto DM/PC tras resumen que omite el diálogo.
Rojos0/6,0/1 escena,6/7 scrub y6/7 Unicode;67 focalizados en1,0 s.
Gate2546/3 en49,3 s/seed30343/max_cases48, sin errores/avisos inesperados;
cinco deliberados breaker. Compile/formato/diff correctos.

19425/modelos conservados:7,605 s hasta humano, humano1/DM2/cero TM/recorder.
Maribel distingue lo observado de la dirección que le contó un zagal; la
tool guarda la fuente y el relato antes de la narración. Reloj36120, escena,
recursos y biblioteca iguales, testimonio durable tras restart/reload375/
1440 px/teclado; cinco auxiliares cerrados, capturas revisadas y hook retirado.
Zagal/cabras no estaban en history anterior; rellenar la jarra sin petición
y gestos del humano siguen bajo revisión. No demuestra veracidad, ajuste a
la biblia ni llamadas universales del modelo; beta sigue en preparación.

## D177 — Preguntar por lo visto u oído conserva la voz literal del jugador
Fecha: 2026-10-03. Estado: **Aceptada**.

El playtest D176 formula «¿Viste tú misma…?» y el whitelist informativo de
D167 no lo reconoce. La declaración ya tiene destinatario PNJ/respuesta
reservada, pero el modelo humano la repite añadiendo codos y mirada del PC.
No hay reglas que resolver en esa pregunta aislada. Se amplía solo el inicio
informativo con viste/oíste/escuchaste, con tú opcional; prefijo, destinatario,
pregunta única y cola pasiva/manual conservan todas las comprobaciones D167.
No amplía roles PNJ ni añade un clasificador semántico general.

Una pregunta con magia/pago/movimiento/duración adicional conserva el beat
humano; el caso mixto False Life verifica ambas formas de pregunta con su
casilla/dado/PG temporales. El DM sigue resolviendo su respuesta y registrando
testimonios; el motor no confirma que la versión del PNJ sea cierta. Los dos
fixtures de flujo D176 eliminan la respuesta humana que dejó de solicitarse
y comprueban voz literal; checkpoint/replay/restart/compacción conservados.

Tres casos nuevos: dos Text y uno LiveView con respuesta bloqueada, entrega
de contexto/voz literal, testimonio durable y reload. Rojo1/3;32 focalizados
en1,7 s; gate2549/3 en49,6 s/seed30343/max_cases48 sin errores ni avisos
inesperados, cinco deliberados breaker. Compile/formato/diff correctos.
El intermedio11/13 detectó dos errores de fixture: herrero no es un rol D158
admitido y la narración inicial de creación no pertenece a esta respuesta.
Se corrigen los oráculos, sin ampliar el producto para ocultarlos.

19425 conserva modelos/biblioteca/reloj36120: pregunta «¿Oíste…?» literal,
DM dos pasos/una ejecución y4,538 s hasta humano, sin petición humana/TM/
recorder ni cambios fuera de facts. Testimonio atribuido/restart/recargas
375/1440 px/teclado acreditados; cinco auxiliares cerrados y hook retirado.
Biblia vacía y zagal/cabras ausentes del historial previo: no prueba por sí
solo contradicción. Nueva versión del encuentro con el forastero y orden
de ficha/compañeros móvil siguen bajo revisión. No certifica semántica/SLA.

## D178 — Abrir Ficha vuelve a los datos propios; actualizar no mueve al lector
Fecha: 2026-10-03. Estado: **Aceptada**.

Las capturas D177 muestran compañeros antes que la ficha propia en móvil.
Chrome375/720 reproduce el efecto: tras desplegarlos/cerrar/reabrir, PG quedan
fuera del área recortada del cajón. Reordenar el DOM mejora jerarquía y tabulado,
pero conserva scroll209/151 px y desplaza ahora los datos hacia arriba.
Por eso la solución necesita ambas cosas: ficha propia antes de compañeros
y reinicio del scroll únicamente al abrir el cajón.

PlayerSheets, hook local sobre el aside existente, recuerda su estado abierto.
Al recibir el cambio cerrado→abierto deja scrollTop0; un patch mientras sigue
abierto conserva posición y el details nativo con ignore_attributes(open).
No cambia foco, pausa, estado de compañeros, datos World, estilos ni diseño
D84. En escritorio los detalles mobile siguen ocultos; DM mantiene Grupo.

Chrome19425 confirma PG14/14 visibles al reabrir375/720 px, scroll conservado
durante dos cambios de borrador y compañeros todavía abiertos.721/1024/1440
conservan fichas de escritorio, DM375 conserva tres miembros. SQL de solo
lectura compara World/actor/estado/ronda/intenciones/historial, reloj36120.
Cinco capturas revisadas, sin JS/overflow-x.721 px muestra crónica demasiado
estrecha y controles recortados; ampliar adaptación intermedia sigue pendiente.

41 focalizados en5,2 s; gate2549/3 en49,3 s/seed30343/max_cases48 limpio,
cinco avisos deliberados breaker. El gate49,4 s anterior observó nil TestModel
en la cripta repeat. El oráculo exacto del fixture de tres voces reproduce
0/1 al admitir una cuarta voz fallback: el polling podía llegar después del
siguiente autoplay. El fixture separa PC, empieza pausado y pausa antes de
liberar la tercera final DM. Exactamente tres voces/World/DB y log sin fallo;
no se cambia el motor ni la dependencia para ocultarlo. Compile/formato/diff
y detectores UI correctos, pruebas existentes mantenidas, sin nuevos campos.

## D179 — Mesa compacta hasta 1023 px, foco visible y ficha propia de combate
Fecha: 2026-10-03. Estado: **Aceptada**.

La captura721 px y la reproducción Chrome muestran una crónica237 px/texto185
con controles recortados. R20 ya fija escritorio desde1024: ampliar el corte
compacto hasta1023 resuelve ese intervalo sin reemplazar el diseño D84.
Los bloques intermedios tienen máximo72ch. En paisaje721–1023/altura≤600,
Ficha abre en un lateral240 px para conservar altura de crónica/entrada;
cerrada solo reserva el control. La sala de espera conserva su corte720.

La barra admite filas y scroll horizontal. TurnControls revela el botón
completo en focusin, con margen7 px para su marco; ajusta solo scrollLeft
local, sin scrollIntoView sobre padres. Tab nativo reproducía Invitar parcial
a375 incluso después de permitir scroll. Controles coarse≥44×44 px.
PlayerSheets mantiene su reinicio únicamente al abrir y estado de compañeros.

La prueba táctil descubre otro fallo: CSS de duplicados ocultaba la ficha
propia de combate, que se renderizaba directamente como sheet en el aside.
Un contenedor propio conserva su altura natural y evita esa regla; PG/CA
preceden raza/clase para entrar en el lateral corto. No oculta información,
no cambia World/turnos/modelos ni añade campos al dominio.

Chrome verifica ocho tamaños375–1440 y cuatro casos táctiles emulados de
exploración/combate, controles por Tab, ajustes/cancelar, ficha/compañeros,
iniciativa/input y sin JS/overflow-x. Siete capturas revisadas; SQL de solo
lectura confirma dos mesas intactas, reloj19425=36120. Sin hardware físico.
39 focalizados5,9 s y2549/3 en48,2 s/seed30343/max_cases48 limpios, cinco
breaker deliberados. Formato/compile/diff correctos. Detector: seis avisos
CSS anteriores conservados en D84, ninguno introducido. No certifica beta
ni continuidad narrativa: siguen versiones PNJ/cambios físicos y latencia.

## D180 — Presupuesto configurable del TurnMaster y prueba del corte real
Fecha: 2026-10-03. Estado: **Aceptada**.

El playtest D175 registró `max_tokens_exceeded` antes de decidir un relevo.
Constructor y Bootstrap imponían256 tokens por petición. Una prueba aislada
con el modelo/routing/temperatura originales alterna256/1024 cuatro veces:
la primera256 termina `length`, consume256 y no llama una tool; la segunda,
con1024, llama `give_turn_to` tras259 tokens. La tercera256 y cuarta1024
también deciden. World/eventos/agente real permanecen idénticos durante la
prueba. No demuestra fallo universal de256 ni fiabilidad estadística de1024.

En modelos que razonan, el límite puede incluir razonamiento y salida visible,
según la [documentación primaria de OpenRouter](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens).
La telemetría disponible no separa ese consumo: no se atribuye el corte a una
cantidad medida de razonamiento ni se cambia su esfuerzo por inferencia.

Decisión: `Models.turnmaster_max_tokens/0` devuelve1024 por defecto.
`DRAGONEX_TURNMASTER_MAX_TOKENS` acepta un entero positivo, con espacios
periféricos; ausente/vacío/inválido/no positivo mantiene1024. La opción
explícita `TurnMaster.new(model, max_tokens: ...)` prevalece. Bootstrap usa
el constructor sin repetir un valor fijo. La configuración se toma al crear
el agente; la mesa existente se reinicia para recogerla. Es un límite por
petición, no consumo fijo ni garantía de completar cualquier decisión.

Se mantienen modelo, ajustes restantes, routing y presupuestos DM/PC; no
hay nuevo ajuste UI. El máximo de tres pasos, captura de la primera decisión
válida D79, interrupciones y fallback WorldDriven siguen vigentes. Ampliar
el límite evita el corte observado sin eliminar límites de coste ni esconder
errores posteriores. No se implementa retry nuevo del coordinador.

Cuatro pruebas offline verifican la configuración hasta el request efectivo
de un Game y el relevo sin fallback. El modelo determinista exige259 tokens,
basándose en la muestra observada, sin pretender simular todos los proveedores.
El fixture fija al goblin como combatiente saliente: dejarlo nil permite
legítimamente otro turno y agota un script finito. Con el fixture corregido,
revertir solo constructor/Bootstrap produce1/4; restaurarlos da77 focalizados
en2,3 s. Gate2553/3 en50,2 s/seed30343/max_cases48, cero errores/desconexiones/
avisos inesperados y cinco breaker deliberados.

Mesa19425 con modelos originales: una espera15 s vuelve en9,667 s,
DM dos pasos y TM una ejecución que cede a Mara. Su cancelación posterior
es la terminación esperada al capturar esa primera decisión. Reloj36120→36135
una sola vez, solo cambia además la reserva de espera. Recursos/escena/hechos
intactos. Dos reinicios preservan World/historial/actor/intenciones/modelos,
cierran cinco auxiliares cada uno; el final conserva1024 y JSON/UTF-8 válidos.
Recargas375/1440 px/teclado y seis capturas verificadas; hooks privados retirados.
La traza incluye una revisión de escena de4,261 s antes del TM, con entorno
final idéntico. No se presenta como cero recorder: investigar su condición
de entrada y el contrato de espera antes de retirar una comprobación.

Antes del cambio, Maribel aclara la aparente contradicción entre preguntar y
pedir un encargo:8,13 s, un paso DM, ningún otro run, World idéntico. Esa
respuesta contextual no justifica forzar una mentira, corregir hechos por
inferencia ni certificar continuidad semántica general. Continúan variantes
de grupo, cambios físicos narrados y latencia; beta sigue en preparación.

## D181 — Conservar los desenlaces de dados en el historial compartido
Fecha: 2026-10-03. Estado: **Aceptada**.

En19425, las peticiones compartidas conservan el d20 y daño de Vex, pero
History convierte tanto hit como crit a «¡ACIERTO!». La etiqueta del motor
se pierde aunque el modelo pudiera inferir un crítico desde20. El mismo
formatter omite fail de Actions.death_save y reduce crit_fail a fallo simple.
Son pérdidas de contexto, no errores del cálculo determinista.

Decisión: traducir cada resultado confirmado con su distinción: hit→acierto,
crit→crítico, fail/miss→fallo y crit_fail→dos fallos de salvación de muerte.
Success/failure/revive conservan su formato. La etiqueta procede del outcome
del motor, nunca de recalcular un total o interpretar un d20. No añade reglas
de pifia, cambia fichas/World, reescribe eventos antiguos ni toca el chat.
Se aplica también al daño crítico porque RollLog conserva ese mismo outcome.

Tres pruebas generan grupos con Actions/RollLog, aplican sus transiciones y
comparan los contadores/PG reales antes de verificar History con claves átomo
y JSON. Un Game entrega ataque/daño antiguos a dos agentes, junto a su rol
propio en la petición efectiva. Recursos/eventos iguales y cero tiradas al
reiniciar con PID distinto. El fixture inicial no cerraba un Game de ExUnit
mediante el supervisor global; corregir su ownership antes del reinicio
evita confundir un ensure_started del mismo PID con recuperación. No se
modifica el supervisor de producción para acomodar ese fixture.

Control negativo final1/4 en0,2 s;78 focalizados en1,9 s. Gate2557/3 en49,2 s/
seed30343/max_cases48, cero errores/desconexiones/avisos inesperados y cinco
breaker deliberados. Formato, compile warnings-as-errors y diff correctos.

Dos conversaciones reales19425, con modelos/ajustes preservados: Lyra/Vex
y luego Vex/Lyra reciben un turno cada uno y vuelven a Mara tras cierre DM.
11,791/9,664 s; cuatro runs de un paso, cero TM/recorder/tools/dados, World
entero idéntico/reloj36135. El segundo contexto conserva crítico explícito y
ambos lo recuerdan. Preguntas diferentes, sin benchmark causal de latencia.
Reinicio conserva estado/eventos/actor/intenciones/hero/modelos/ajustes de
todos los roles, cierra cinco auxiliares; reload375/1440 px/teclado y seis
capturas revisadas. Instrumentación privada retirada, Show restaurado exacto.

Los mensajes live se capturan desde Server.history: no incluyen el prefijo
system efímero añadido al request. Esa entrega se verifica en el Game con
TestModel, sin presentar la captura como request completo del proveedor.
395 eventos caben en la ventana reciente400; no certifica memoria de toda
una campaña ni fidelidad semántica general. La reformulación humana añade
gestos repetidos y el cierre DM vuelve a cuenco/postigos/tarde. Continuar
preguntas informativas PC y repetición antes de declarar lista la beta.

## D182 — Habla humana literal en preguntas de recuerdo a compañeros
Fecha: 2026-10-03. Estado: **Aceptada**.

D181 muestra dos preguntas informativas al grupo. El narrador humano añade
la misma jarra a medio vaciar y gestos no declarados antes de las respuestas.
La cola D143 ya está registrada por el motor: reformular el habla añade una
petición sin resolver ninguna regla y puede atribuir acciones al jugador.

Decisión: Text.literal_pc_speech reconoce el vocativo PC validado existente,
una sola pregunta de recuerdo/conocimiento/observación y, como máximo, espera
pasiva de respuestas. Conserva el texto hasta el cierre de la pregunta, con
raya de habla y scrub; la espera queda en la intención original. Conversations
exige origen humano manual/exploración, cola íntegra con la misma pregunta y
orden y ausencia de mini/re-eval/interrupción. Beats selecciona esa publicación
local antes de iniciar el modelo humano, usando el mismo Events/settlement.
No modifica tools, World/Codec ni iniciativa; respuestas/cierre/retorno usan
la conversación durable vigente.

La gramática es deliberadamente acotada: recuerdas/recordáis, sabes/sabéis,
viste/visteis, oíste/oísteis y escuchaste/escuchasteis, con interrogativo y
pronombre opcionales. No interpreta toda intención. Peticiones/preferencias,
acciones adicionales, magia, dos preguntas, tiempos de espera e identidades
ambiguas conservan la ruta anterior. Así no omite costes o efectos para
eliminar una petición; el caso mixto False Life conserva su dado y casilla.

Tres casos parser/guardas y tres Game observan los messages efectivos, el rol
propio y habla literal de ambos PCs, cero request humano y reinicio durante
la primera respuesta con PID nuevo/sin voz duplicada. Los Games pertenecen
al supervisor público y se cierran en after. Control negativo4/6, sin errores
ni avisos; seis pasan0,5 s,62 focalizados2,9 s. Gate2563/3 en50,0 s/seed30343/
max_cases48 sin errores/desconexiones/avisos inesperados, cinco breaker.
Formato/compile warnings-as-errors/diff correctos.

19425 repite la pregunta inicial D181 con modelos/ajustes conservados: habla
exacta y Lyra/Vex/cierre DM/retorno Mara en7,647 s. Tres runs de un paso,
cero humano/TM/recorder/tools/dados, World entero/36135/hero iguales.13 eventos,
395→408. Vex añade un encabezado de turno que scrub retira: clean=persistido,
sin atribuir esa limpieza a obediencia perfecta del modelo. La captura live
es Server.history, no el request completo con system efímero; TestModel sí
verifica ambos requests efectivos.

Reinicio preserva World/historial/cursor/intenciones/hero/modelos/ajustes y
cierra cinco auxiliares; reanudar/pausar no añade eventos. UTF-8/JSON y reload
375/1440 px/teclado acreditados, cuatro capturas revisadas; hook retirado/Show
exactamente restaurado. Una llamada humana real eliminada no certifica SLA.
408 eventos superan400, pero los dados recordados todavía quedan en esa
ventana: no prueba memoria de hechos expulsados. El cierre DM repite cuenco/
postigos/tarde; seguir ese pulido y campañas largas antes de declarar beta.

## D183 — El anti-repeat respeta el contexto de conversación
Fecha: 2026-10-03. Estado: **Aceptada**.

D182 repite cuenco/postigos/tarde en el cierre DM. Una primera revisión quita
«1–2 frases de ambiente» y pide cierre breve/decisión humana. El playtest sigue
narrando cuenco y luz más dorada. La petición capturada revela una contradicción:
with_dm_anti_repeat antepone «cambia olor/sonido/luz» a la instrucción que prohíbe
relleno sensorial. El recordatorio general no conocía el tipo de turno.

Decisión: Game pasa context :conversation cuando Conversation.world_turn? es
verdadero; en el resto pasa :scene. Guardrails conserva el detector/umbral y
la guía ordinaria de sus llamadas existentes. La variante de conversación
solicita solo respuesta pendiente/consecuencia concreta o cierre breve sin
recapitular, sin exigir nuevos detalles sensoriales/gestos/hora. La instrucción
base deja abierta la decisión humana y explica que conversar no es un atasco.
Respuestas PNJ, herramientas, agencia, lengua y otros nudges conservan su camino.
No filtra prosa por inferencia, impone un cierre silencioso, cambia World/Codec
ni acredita obediencia del modelo.

Tres Game prueban los messages efectivos con narraciones previas repetidas,
dos intercambios y un DM pendiente reabierto con PID distinto. No repiten las
voces PC; dos marcadores DM corresponden a sus intentos antes/después del
reinicio, con una sola respuesta final. El PNJ responde y record_npc_statement
persiste su fuente mediante la tool. El fixture usa speaker, cuenta finales
completos y separa la apertura inicial/los intentos. Antes de conectar el contexto,
el fixture final produce1/3 en0,4 s por la guía sensorial;42 adyacentes en3,3 s.
Gate2566/3 en49,6 s/seed30343/max_cases48, cero errores/desconexiones/avisos
inesperados, cinco breaker deliberados. Formato/compile/diff correctos.

19425 recibe dos preguntas,7,618/7,605 s; tres runs de un paso, cero humano/
TM/recorder/tools/dados, World entero/clock36135/hero/modelos iguales.408→421→434.
La primera tiene solo el prompt cambiado y conserva el nudge sensorial antiguo.
Después de corregir el contexto, el umbral no activa anti-repeat en la última
petición; ya no lleva la orden antigua. La variante activada se verifica con
TestModel. El DM final todavía dice «la tarde sigue tibia» y «sin fisuras»:
no se presenta como repetición o fidelidad narrativa resueltas.

Dos reinicios preservan World/historial/cursor/intenciones/hero/modelos/ajustes,
cierran cinco auxiliares cada uno y no añaden eventos al reanudar/pausar. UTF-8/
JSON y reload375/1440 px/teclado/ficha/compañeros acreditados, ocho capturas
revisadas sin JS/overflow; hooks/probe retirados/Show exacto. Captura live es
Server.history sin system efímero, no un request completo. Evidencia privada:
conversation-pacing-verification.json. Sin SLA, memoria ilimitada ni hardware
físico/Safari. Seguir cierre discreto con guardas del motor que conserve PNJs
y consecuencias, y hechos fuera de la ventana400; beta continúa abierta.

## D184 — Una conversación PC acreditada puede cerrar sin narrador DM
Fecha: 2026-10-03. Estado: **Aceptada**.

D183 elimina instrucciones contradictorias, pero aún añade ambiente y recapitulación
después de una pregunta ya contestada por ambos PCs. Decisión: el Game puede
omitir esa petición cuando demuestra localmente que solo queda devolver el turno.
No depende de que un modelo declare «nada ha cambiado» ni analiza toda prosa libre.

Game.ConversationClosure reserva dentro de la conversación existente quiet_close:
SHA256 del Codec.encode(World) sin conversación/actor_checkpoint y seq de la acción
original. Es determinista, sin nuevos campos de structs de personaje/mundo ni tools.
Conversation.decode conserva solo hash64hex/seq positivo, elimina datos inválidos
o extras y no admite prueba para una consulta PNJ. El legado sin prueba conserva DM.
Admite vocativo PC y una pregunta informativa/opinión, con espera pasiva opcional,
en exploración manual sin mini/re-eval/interrupción ni escena pendiente. Peticiones
de acción y cláusulas adicionales al mundo quedan fuera. D182 mantiene por separado
su publicación literal de recuerdo/observación; preferencias siguen usando modelo humano.

El cierre se revalida dentro de la misma Session.update_state que liquida el último
PC: huella World íntegra, ninguna intención, acción idéntica en eventos recientes,
exactamente una narración completa de origen/destinatarios en orden y solo relevos
exploratorios previstos. Dados incluso sin cambio World, fallos, parciales,
pregunta nueva PC, cualquier acción/actor/evento inesperado o anchor perdido en400
impiden cierre local. La comparación incluye reloj/escena/hechos/log/recursos y
resto del World. Evita una Task silenciosa que decidiera sobre un snapshot mientras
sync_hero_level_up u otro mensaje cambia estado. Si pasa, termina el cursor DM
localmente y usa el retorno existente: cero beat, marcador o narración DM.

Seis tests puros y ocho Game cubren Codec, guardas, voz/prefix efectivos, reinicio
pendiente con PID distinto sin duplicados, habilidad con dado pero World igual,
False Life con pago/tirada únicos, preferencia, pregunta PC al PNJ, humano intercalado
y fallo/pregunta mixta. La regresión «Vex, ¿puedes pedir agua a la posadera?» descubre
la admisión excesiva inicial: restringir a consultas informativas conserva DM.
Tests de habla pura pasan a esperar retorno directo; D183 añade consulta al mundo
para mantener cobertura de su prompt/nudge y cierre pendiente.
Control negativo suprime exclusivamente los eventos usados para acreditar el cierre:
11/14 en1,0 s, tres positivos Game fallan, cero errores/avisos; fuente restaurada
byte a byte.69 focalizados en3,7 s y2580/3 en50,9 s/seed30343/max_cases48, sin
errores/desconexiones/avisos inesperados; cinco breaker deliberados. Formato/
compile warnings-as-errors/diff correctos.

19425 pasa434→444→454 con World/clock36135/hero/modelos íntegros y una voz Lyra/Vex
por consulta. Primera7,642 s: observador caducado, sin afirmar traza de modelos.
Repetición5,574 s: dos runs PC/un paso, cero humano/DM/TM/recorder/tools/dados,
history DM con hash idéntico antes/después. Reinicio cierra cinco auxiliares,
conserva World/history/cursor/intenciones/modelos/ajustes y no añade eventos al
reanudar/pausar. UTF-8/JSON, SQL solo lectura, reload375/1440/teclado y cuatro
capturas revisadas; hook retirado/Show exacto. Evidencia privada
quiet-conversation-verification.json. Captura live Server.history sin system efímero;
prefix real verificado con TestModel. No es clasificación semántica universal,
SLA, campaña ilimitada ni prueba de hardware/Safari. PNJs/efectos físicos y
continuidad fuera de400 siguen abiertos; objetivo beta activo.

## D185 — Visibilidad de eventos antes de reconstruir el historial de cada rol
Fecha: 2026-10-03. Estado: **Aceptada**.

La auditoría de memoria fuera de400 revela que History.visible? comprobaba solo
type pese a comentar que excluía eventos DM. Una nota de fallo privada u otra
narración DM-only podía entrar en el request de un PC. El feed ya separa all y
all/dm; filtrar solo en la LiveView no limita lo que un agente puede leer/narrar.

Decisión: History.from_events(events, viewer) filtra antes de headers, fusión y
compresión. Default nil y cualquier rol distinto de "dm" reciben solo all;
DM explícito recibe all/dm. Audiencias desconocidas/ausentes y tipos tool quedan
excluidos. Es la política ya existente del feed, sin nuevas audiencias privadas
por PC. Game.Beats pasa participant, nunca deduce permisos del Server: humanos
se resuelven en el mismo Server DM, pero su audiencia sigue siendo pública.
SceneRefresh mantiene from_events/1 público. No borra notas, muta World, añade
campos/tools, cambia modelos ni inspecciona secretos en facts/story_bible.

Cinco tests de History/recorder y dos Game cubren eventos privados de todos los
tipos, headers ocultos, compresión pública, audiencias inválidas, requests
efectivos humano/Lyra/Vex/DM y recorder, roles system y reinicio durante Lyra
con PID distinto sin duplicados. World/DB/historial privado permanecen intactos.
El primer fixture asignaba solo una respuesta al Server humano/DM y agotaba
TestModel; corregir el script deja rojo0/7 en0,3 s sin errores/avisos. Verde7/7
en0,3 s. Control filtro desactivado0/7 y selección DM omitida5/7, ambos0,3 s
limpios, fuentes exactamente restauradas.67 focalizados en4,7 s;2587/3 en50,5 s/
seed30343/max_cases48, cero errores/desconexiones/avisos inesperados; cinco
breaker deliberados. Formato/compile warnings-as-errors/diff correctos.

Reload19425 a375/1440 px por teclado conserva ficha/compañeros/último Vex453,
dos capturas revisadas sin JS/overflow. SQL solo lectura conserva World/cursor/
pausa y los454 eventos respecto D184;19439 pausada. No nuevos eventos, hooks,
playtest narrado ni requests de proveedor: la privacidad se acredita mediante
TestModel, no una captura live. Evidencia privada history-visibility-verification.json.
Recuperación de evidencia más antigua, consecuencias físicas PNJ y objetivo
beta continúan abiertos; sin SLA, memoria ilimitada ni hardware/Safari.

## D186 — Archivo mecánico acotado en el prompt actual
Fecha: 2026-10-03. Estado: **Aceptada**.

SQL19425 confirma la pérdida: ventana reciente55–454, ataque crítico y daño
de Vex en24–25 fuera de ella. D181 preserva etiquetas dentro de history,
pero no recupera eventos que la consulta400 ya no devuelve. D185 exige respetar
audiencia al ampliar contexto. Decisión: recuperar solo resultados dice antiguos
desde el log original, sin recapitulación LLM, nuevo estado ni replay de tools.

Games.rolls_before limita a32 aun si se pide más; filtra game_id, seq previo,
type=dice y all/all-dm según participante ANTES del límite y devuelve orden
cronológico. Migración9 añade índice parcial(game_id,visible_to,seq) WHERE
type='dice', aplicada dev/test; no transforma datos. History.roll_archive puro
revalida tipo/seq/payload/audiencia, orden/deduplicación/corte y límite. Usa
dice_line D181/D161: resultados almacenados, crítico/muerte/mínimo conservados,
sin recalcular reglas. Incluye seq/asalto/fase cuando existen y advierte selección
parcial/resultados pasados, sin inferir PG/recursos actuales ni acciones pendientes.

El archivo se añade al prompt actual junto al World. La primera implementación
lo anteponía a history y permitía que Summary perdiera cifras. El mensaje nuevo
del run queda fuera de la compresión del history anterior; una prueba fuerza
ese camino y verifica archivo íntegro con role prefix vigente. from_events y
el recorder siguen su política pública/DM reciente. Habla local y narración
final recuperada sin otra petición no consultan el archivo. No nuevos campos
Character/World, writers, reglas, herramientas ni narraciones artificiales.

Seis casos puros/compresión real, dos DB y dos Game cubren corte400,32 máximo,
privacidad antes del límite, grupos partidos, duplicados/desconocidos, JSON,
crítico/daño/death_save/subtotal negativo, requests humano/PCs/DM con rol propio
y reinicio durante Lyra con PID distinto sin volver a tirar ni publicar habla
humana. Primer rojo0/9 en0,6 s, todavía sin API; un fixture posterior comparaba
payload átomo recién insertado con JSON leído. Corregir oráculo y asegurar
prompt actual deja10/10 en0,7 s limpios. Controles finales archivo suprimido8/10
y filtro de audiencia antes de límite retirado9/10, ambos0,6 s sin errores/
avisos, fuentes restauradas byte a byte.77 focalizados5,2 s y2597/3 en50,1 s/
seed30343/max_cases48, cero errores/desconexiones/avisos inesperados; cinco
breaker deliberados. Formato/compile warnings-as-errors/diff correctos.

Dos preguntas19425:6,615/5,057 s, dos runs PC/un paso, cero humano/DM/TM/
recorder/tools/dados;454→464→474. Ambos prompts contienen los eventos24–25
fuera de400:20+5=25 vsCA15 y4d6(1,2,6,6)+3=18/crit dentro del mensaje WORLD.
Primera respuesta narrativa; al pedir cifras exactas, ambas voces verbalizan
20 natural/25 contra15/18. No cambia World/clock36135/hero/modelos/history DM.
Dos reinicios conservan World/history/cursor/intenciones/modelos/ajustes y
cierran cinco auxiliares cada uno; resume/pause sin eventos. SQL solo lectura,
UTF-8/JSON,375/1440 px/teclado y ocho capturas revisadas sin JS/overflow;
hooks retirados/Show exacto. Captura live Server.history sin system efímero;
compresión forzada y prefijos efectivos probados con TestModel. Evidencia
privada roll-memory-verification.json. Sin SLA ni hardware/Safari.

Límite explícito:32 tiradas antiguas no son búsqueda semántica de todo pasado,
archivo de escenas/testimonios ni garantía de memoria ilimitada. Las dos voces
repiten gesto de jarra incluso con datos correctos. Continuar esos recorridos,
consecuencias físicas PNJ y calidad de prosa; objetivo beta sigue activo.

## D187 — Respuesta PC completa sin gestos obligatorios; antibucle reciente y público
Fecha: 2026-10-03. Estado: **Aceptada**.

D186 registra dos respuestas correctas que copian el mismo gesto de jarra.
El prefijo PCAgent exigía haber propuesto o hecho un gesto, aunque la respuesta
pendiente prohibía copiar gestos y actuar. El nudge añadía nuevas inspecciones
o ability_check; además Enum.take(2) elegía las primeras voces de un bloque
cronológico, pese a anunciar las últimas. Son contratos contradictorios y
una selección temporal incorrecta, no un error de reglas deterministas.

Decisión: el prefijo estable y la instrucción admiten que responder ya completa
la intervención. Permiten conservar datos confirmados y evitan gestos físicos
de relleno. No se obliga a discrepar ni se borra el historial del predecesor.
Game selecciona :response desde la petición vigente para PC consciente;
Guardrails.with_pc_anti_loop acepta opts con default :scene, conservando la
ruta libre. Su rama de respuesta no exige novedad factual, gestos ni tiradas.
Detector: dos narraciones públicas más recientes del actor dentro de40 eventos;
la guía libre cita la última. Notas privadas no alimentan mensajes públicos.
Sin nuevas reglas, herramientas, structs, escrituras World o filtros semánticos.
Peticiones al PNJ/mundo conservan la ruta DM existente, incluido pedir agua.

Seis regresiones nuevas y contrato previo ampliado; mensajes reales TestModel,
predecesor preservado, cola pendiente y PID nuevo tras restart, una narración
por actor/World persistido íntegro. Rojo3/10 en0,5 s; corregido un oráculo que
rechazaba el marcador de turno del intento recuperado. Verde10/10 en0,5 s.
Controles sin contexto8/10 en0,4 s y sin privacidad9/10 en0,5 s, restauración
exacta y cero errores.96 focalizados3,8 s;2603/3 en51,1 s/seed30343/max_cases48,
salida0/cero errores/desconexiones/avisos inesperados, cinco breaker. Un gate
previo51,0 s informó2603/3 pero terminó143, conservado y repetido; causa sin
atribuir. Formato/compile warnings-as-errors/diff correctos.

Ensayo inicial19425 de3,997 s no ejecutó instrumentación por un assign incorrecto
del hook: sin afirmar runs o prefijo reconstruido. Corregirlo y exigir artefactos,
reiniciar conservando modelos/ajustes y reconstruir prefijos permite dos preguntas
observadas4,530/4,013 s,484→494→504. Dos runs PC/un paso por pregunta, cero
humano/DM/TM/recorder/tools/dados; ambas voces sin gesto de jarra y cifras del
motor correctas. Nudge no activado live, rama efectiva probada offline. World/
clock36135/hero/modelos/history DM íntegros, archivo24–25 en prompt actual,
raw/scrub/persistido iguales. Dos reinicios públicos total conservan estado y
cierran cinco auxiliares cada uno; resume/pause sin eventos. SQL solo lectura,
reload375/1440/teclado y seis capturas revisadas sin JS/overflow; hook retirado,
Show exacto. Evidencia privada pc-response-pacing-verification.json.

Límite: guía entregada y ausencia de este gesto en dos muestras no garantiza
originalidad o fidelidad semántica. Comparten fórmulas y mencionan posibles
huidas del goblin. Ventana40 no detecta toda repetición histórica. Continuar
aventura, PNJs/efectos físicos y memoria antigua; beta sigue activa, sin SLA.

## D188 — Publicar la pregunta PC informativa/opinión sin reinterpretación humana
Fecha: 2026-10-03. Estado: **Aceptada**. Amplía D182.

Una consulta real «Lyra, Vex, ¿qué os parece ir al cruce del molino a hablar
con el zagal?» tenía cola correcta, pero el narrador cambió las palabras e
introdujo «mientras esperáis la respuesta de Maribel». La ruta D182 solo
publicaba localmente recuerdo/observación; la opinión no necesitaba cálculo,
acción o narración adicional. Decisión: literal_pc_speech usa las formas
informativas/opinión existentes de pc_question_only?. Mantiene una pregunta,
vocativo inicial, espera pasiva y todas las guardas de cola manual vigente.
Publica tras scrub por Game/Events; no nuevo writer, estado, permiso, tool ni
clasificador semántico. Peticiones de acción/magia/movimientos añadidos y
contextos inciertos conservan su resolución. D184 sigue decidiendo el cierre
según transcript/World, con el mismo criterio de prudencia.

Cuatro regresiones nuevas y restart previo ampliado a ambas clases de pregunta.
Preferencia verifica habla exacta y cero humano/DM; fixtures de privacidad,
archivo y narrador bloqueado/fallido añaden una declaración propia para conservar
la ruta que prueban, con callback fallido realmente observado. No se debilita
la privacidad para ajustarla a scripts. Rojo/control memory-only6/10 en0,7 s,
fuente restaurada exacta.77 focalizados4,8 s;2607/3 en52,2 s/salida0,
seed30343/max_cases48, cero errores/desconexiones/avisos inesperados, cinco
breaker. Formato/compile warnings-as-errors/diff correctos.

19425: Maribel da pista atribuida504→511/6,095 s/DM dos pasos/una tool; solo
facts cambia. Su nueva era alternativa queda en prosa, no en ese testimonio.
Consulta antes511→521/6,109 s/tres runs/un paso conserva World pero modifica
habla. Después521→531/4,053 s/dos runs PC/un paso, habla exacta y cero otros/
tools/dados, World/clock36135/hero/modelos/history DM iguales. Datos antiguos
24–25 en prompts vigentes; no se garantiza originalidad de respuestas ni
causalidad de latencia entre muestras. Reinicio cierra cinco auxiliares y
conserva World/events/cursor/intents/modelos/ajustes; sin eventos resume/pause.
SQL solo lectura, UTF-8/JSON/reload375/1440/teclado y ocho capturas revisadas,
hook retirado/Show exacto. pc-opinion-literal-verification.json privado.

No implica partida acordada, viaje consumado o verdad de testimonios. La
recolección de prosa nueva no registrada y la semántica de toda pregunta siguen
abiertas; continuar desplazamiento explícito y zagal. Objetivo beta activo.

## D189 — Reconocer oficios PNJ con prioridad de las identidades PC
Fecha: 2026-10-03. Estado: **Aceptada**. Amplía D167/D177.

Una pregunta real al zagal pasó por humano/DM/TM porque los patrones solo
enumeraban doce roles. Se comparte un vocabulario de oficios habituales entre
pregunta explícita y vocativo. Admite un complemento de/del con un sustantivo
y artículo opcional; cláusulas/descripciones largas conservan ruta semántica.
No se infiere una entidad desde prosa ni se añade registro PNJ. La publicación
literal sigue exigiendo información/espera pasiva y cola manual coincidente.

Game aporta todos los nombres PC del World al registro y a la extracción del
habla. Una coincidencia completa o corta tras normalizar NFC/artículo/espacios
bloquea el atajo PNJ, incluso con alias corto ambiguo. Límites de palabra evitan
confundir Zagalote con Zagal. La resolución existente conserva la autoridad;
no cambia Character/World/Codec, herramientas o single-writer.

Seis regresiones nuevas y magia mixta ampliada; rojo9/14 en2,9 s, verde14/14
en0,8 s. Controles roles9/14 y roster13/14, fuentes restauradas.43 focalizados
2,5 s;2613/3 en52,6 s/salida0/seed30343/max_cases48, sin errores/desconexiones
ni avisos inesperados, cinco breaker. Formato/compile warnings-as-errors/diff.

19425: viaje explícito900 s,531→538/15,261 s, reloj37035/escena molino;
humano/DM y decisión TM cancelada tras tool válida, recorder3,015 s. Primera
pregunta16,811 s/538→545 reformulada; siguiente7,109 s/545→552 exacta, solo
DM dos pasos/record_npc_statement. Preguntas solo cambian facts atribuidos;
cero dados, recursos/hero/modelos íntegros. Scrub retira encabezados. Reinicio
conserva estado/ajustes y cierra cinco auxiliares; SQL/reload375/1440/teclado y
ocho capturas revisadas, hook retirado/Show exacto. Evidencia privada
npc-occupations-verification.json. Sin benchmark causal, semántica universal,
memoria ilimitada o beta certificada; continuar aventura y efectos físicos.

## D190 — Inventario narrativo cuantificado por el motor
Fecha: 2026-10-03. Estado: **Aceptada**, implementada (R38, alcance acotado).

19425 recoge un botón de latón: ambas voces lo describen guardado, pero World
e inventario permanecen idénticos560→567. No existe herramienta para registrar
esa posesión y la ficha/brief tampoco presentan el inventario. Se admite esta
ampliación F7 para que las acciones físicas tengan estado verificable.

Objetos descriptivos de aventura se registran como Item :gear existente,
sin modificar Character/Item/Codec ni equipar armas/armaduras o aplicar efectos.
El DM decide la entrega/retirada ficticia; grant_item/remove_item solo pueden
confirmarla en exploración para PC presente. El motor valida nombre saneado
1..160 caracteres, cantidad entera1..9999, máximo80 entradas, suma/resta sin
stock negativo y elimina entradas vacías. No se calcula desde narraciones.
La representación canónica NFC/case/espacios sirve también para replay del
mismo beat, evitando duplicar por distinta escritura al recuperar un fallo.

World aplica funciones de cambio mediante Game; briefing/ficha leen ese mismo
inventario y el héroe reusable no recibe botín de una partida. Progresión,
Codec/reinicio y recuperación tras cambio confirmado conservan cantidades.
El cambio solicita revisión durable de escena para no dejar el mismo objeto
en el suelo y en la bolsa. Recorder es lector; Game aplica su snapshot. Si
solo cambió inventario puede confirmar una descripción idéntica: requiere
inventory_scene_before en el comprobante existente, con revisión previa false
y SHA256 del World salvo inventarios/checkpoint/flag. Reloj, facts, log, escena,
PG y otros recursos participan en la huella. Solo tools de inventario y commit
contra World exacto autorizan limpiar el flag; legacy o pendientes anteriores
son conservadores. Timeout no deshace/repite stock y mantiene revisión pendiente.

La prueba real detecta que un PNJ devolvía el objeto en prosa sin grant_item;
el narrador humano también intentó la tool fuera de turno. Prefijo estable y
contrato por beat distinguen ambos papeles. El recordatorio final, después del
archivo de dados, incluye la última declaración pública/DM aún no respondida,
scrubbed y acotada1800; no interpreta semánticamente objetos/cantidades ni muta
World desde texto. La lista de posesión del motor prevalece sobre prosa antigua.

No se crea economía/peso/equipamiento dinámico, consumibles o registro global
de objetos sobre el suelo. La procedencia ficticia permanece a cargo del DM;
esto cuantifica posesión, no verifica toda semántica física del mundo.

22 regresiones/110 focalizados y2635/3 en52,6 s, seed30343/max_cases48/salida0;
sin errores/desconexiones/avisos inesperados, cinco breaker. Código temporal
retirado, formato/compile/diff correctos.19425 confirma entregas, dejar y recoger;
la formulación original623→630 retira una unidad, con recorder timeout20 s,
sin doble efecto.630→637 recoge una y revisa escena en3,634 s, sin pendiente.
SQL/reinicio/reload/teclado375/1440 y22 capturas conservan estado/ajustes/hero.
Las omisiones intermedias y el timeout quedan documentados; ampliar variantes
y latencia. Entregado este contrato, sin garantía de toda prosa o beta cerrada.

## D191 — La mesa distingue narración, revisión de escena y relevo
Fecha: 2026-10-03. Estado: **Aceptada**, implementada (R16/R19).

D190 observa esperas de hasta44,104 s, incluido un timeout del recorder.
La narración ya está publicada pero la mesa sigue mostrando «el DM está
narrando…» durante la revisión y el TurnMaster. La etiqueta debe describir
la operación actual; no supone una reducción de latencia.

Beat conserva PID y etapa efímeros; el actor DM avisa justo antes de solicitar
la revisión, solo cuando esta procede. Game acepta el aviso únicamente del
Task y turn_id que sigue en curso, y proyecta busy_stage como valor escalar.
TurnMaster y backoff tienen etapas propias. Nada se persiste en World/Codec,
no se añaden eventos de juego ni cambia quién puede actuar o el handoff.
Pausa/espera ocultan el indicador; reanudar refleja la etapa real, reiniciar
la reconstruye. La LiveView limpia la burbuja terminada al abandonar narración,
rechaza chunks tardíos en esas esperas y ofrece un status accesible sin
porcentajes, plazos prometidos ni detalles internos del proveedor.

TestModel bloqueado verifica etapas, mensajes obsoletos, pausa/reanudación,
reinicio, dos vistas/reload, borrador y efectos confirmados. La prueba web de
backoff descubre un cambio sin broadcast; se avisa al entrar en actor/TM/retry.
Un fallo del proveedor después de pause también sobrescribía status:running;
schedule_transient_retry preserva paused. No cambia backoff, resultados,
persistencia de tools o turnos; el usuario vuelve a decidir cuándo continuar.

Ocho casos nuevos, rojo0/5 y retry2/4;71 focalizados7,8 s. Gate2643/3 en53,3 s,
seed30343/max_cases48/salida0, sin errores/desconexiones/warnings de compile,
seis avisos deliberados (cinco breaker, un timeout de test). Formato/compile/diff.
19425 conserva637 eventos/estado/modelos/ajustes al reiniciar; dejar y recoger
637→644→651 tarda22,159/27,396 s. Ambas vistas375/1440 muestran revisión/relevo
sin cursor, borrador/reload/teclado correctos, cuatro PNG revisados. SQL solo
lectura: recursos/inventario final/facts/reloj37035/hero íntegros, cero dados;
solo escena/log cambian. Hook retirado y Show exacto, navegación normal final.
AC-16.3/19.3 cumplidos; espera comprensible no demuestra aceleración ni beta.

## D192 — Preguntas con preposición conservan la voz del jugador
Fecha: 2026-10-03. Estado: **Aceptada**, implementada (R31/R32).

19425 pregunta al zagal «¿De qué dirección venía el forastero…?».651→658
tarda11,742 s: el narrador humano añade apoyo en el pretil y reformula antes
de responder el DM. El filtro informativo admite ¿qué/dónde/quién…? pero no
preposición + interrogativo. También afecta preguntas equivalentes a PCs.

Text comparte una forma léxica acotada de una preposición española +
interrogativo acentuado (de qué, por qué, con quién, hacia dónde, desde cuándo…).
Se añade a los filtros existentes, sin cambiar destinatarios, prefijos, cola,
número de interrogantes o sufijos pasivos. El habla se publica saneada por
el mecanismo literal existente; la declaración completa sigue en acción/cola.
Acción añadida, magia, pago, movimiento, duración, autoplay/mini/combate e
identidad ambigua mantienen sus guardas. No interpreta efectos ni toca World.

Seis casos nuevos y restart/magia mixta ampliados: rojo20/26, verde26/26,
86 focalizados4,1 s;2649/3 en55,3 s/seed30343/max_cases48/salida0 sin errores,
desconexiones ni warnings de compile. Seis avisos deliberados del breaker/
timeout de prueba. Formato/compile warnings-as-errors/diff correctos.

La preparación inicial asume AgentInstructions en TurnMaster y falla antes
de jugar: se retira la instrumentación parcial. El primer probe de juego
rescata KeyError porque params usa function_tools/output_tools, no tools;
devuelve estado original. Conserva tres respuestas2,963/5,184/2,965 s,
entrada26904/27320/27468 tokens y tool16 ms, sin métricas de inicio/bytes.
Otro observer expira sin acción/trace durante la preparación; se conserva
su evidencia y se rearma solo tras comprobar Game/World/eventos sin cambios.

La corrección real658→665 publica habla exacta y vuelve en6,123 s: dos intentos
DM por fallo transitorio, una respuesta4,938 s/27365 tokens/72183 bytes de
messages JSON; cero narrador humano/TM/recorder, World intacto. Los bytes
cuentan messages, no todo el cuerpo HTTP. Viaje665→672/15,268 s registra900 s
y escena; el TM termina en la primera decisión válida (D79), sin medir como
completa su petición posterior cancelada. Consulta PC672→682/5,056 s recibe
solo Lyra/Vex2,597/2,090 s, conserva habla/pista/World, sin tools ni otros runs.
Los requests observados conservan facts e investigación/archivo cuando
corresponde; AgentInstructions sigue último para DM/PC, ausente en TM.
No se reduce memoria ni se atribuye aceleración causal a estas muestras.

Restart inicial/final conserva World/eventos/modelos/ajustes/hero, cierra cinco
auxiliares; SQL/reload375/1440/teclado y dos PNG revisados. Hook retirado/Show
exacto antes de navegación normal. AC-31.2h2/32.1b entregados; gramática
limitada, memoria ilimitada, calidad semántica general, latencia y beta abiertas.

## D193 — Momento del testimonio en el reloj determinista
Fecha: 2026-10-03. Estado: **Aceptada**, implementada (R25).

Los testimonios de19425 incluyen «hace dos días», pero facts solo conserva
fuente/contenido. Tras avanzar un día, Brief mostraba el reloj nuevo y la misma
frase sin el momento de su registro. La referencia temporal original se pierde.

NPCStatement añade a testimonios nuevos «[Registrado a los N s del reloj del
mundo.]», fuera de la cita, con elapsed_seconds del World. Es tiempo relativo,
no hora del día/fecha real. No interpreta «ayer» ni confirma cuándo sucedió lo
narrado. Fuente/dudas, límites80/800, cap30 y Codec siguen iguales; solo cambia
el texto del fact. No hay campos nuevos, migraciones ni otro escritor.

Duplicados normalizados aún conservados devuelven el primer fact y su marca,
sin renovar posición ni referencia al avanzar reloj. Legado sin marca se
conserva sin inventar fecha. Afirmación distinta tiene marca propia; si cap30
expulsa una versión, no existe un archivo oculto para recuperar su momento.
No backfill de prosa/facts ni detector semántico de contradicciones. El lookup
usa prefijo literal y sufijo numérico anclado: puntuación en fuente/texto no
se interpreta como regex; una etiqueta dentro de cita no cambia el reloj.
Brief DM/PC/TM explica referencia del testimonio frente al reloj actual y
prohíbe inferir fecha para legado. La descripción de tool explica primera marca.

Cinco regresiones nuevas; rojo inicial7/11 cubre las cuatro primeras.22 verdes
1,4 s; quinto cap incluido en94 focalizados2,5 s. Fixtures Game usan37935 y
verifican DB/checkpoint/replay/restart; compacción DM/PC omite diálogo tras
86400 s sin perder marca. Primer intento verde no compila por modificador/D;
se corrige con ancla\z y se conserva el log. Gate2654/3 en54,8 s/seed30343/
max_cases48/salida0 sin errores/desconexiones/warnings de compile; seis avisos
deliberados breaker/timeout. Formato/compile warnings-as-errors/diff correctos.

19425 conserva modelos/ajustes/estado: retorno682→689900 s; pregunta689→696
solo DM/dos pasos/una tool añade una versión sobre ir solo, marcada38835.
Viaje696→703900 s deja39735, sin renovar marca. Consulta703→713 tiene solo
Lyra/Vex, con marca presente en requests; separan palabra del zagal de botón/
huellas. Duraciones15,299/5,599/17,905/6,097 s no son benchmark causal/SLA.
Recorders de ambos viajes6,491/5,387 s; no recorder en preguntas. La versión
nueva no incluye «hace dos días» en su contenido: la prueba de envejecer esa
expresión concreta es determinista, no una respuesta live después de un día.

Restart713/SQL/reload1440/375/teclado/dos PNG conservan historia/recursos/hero,
cierra cinco auxiliares. Once facts antiguos intactos/sin marca inferida;
un nuevo testimonio, escena/log y1800 s; cero dados nuevos. Hook retirado/Show
exacto antes de navegar normalmente. AC-25.5b entregado; contenido/narración
no se verifica, memoria limitada/registro universal/latencia/beta siguen abiertos.

## D194 — Dado legible, accesible y cierre asociado a su generación
Fecha: 2026-10-03. Estado: **Aceptada**, implementada (R14, AC-14.4).

19425 investiga713→721: d20=16/INT+3/total19 frente aDC15, éxito y retorno
humano13,477 s. El modal omitía DC, carecía de botón/diálogo y Escape no cerraba.
group_card entregaba el mapa completo al formatter, que espera against.
Un hide sin generación podía cerrar una ventana posterior; settled no cancelaba
fallback y dismiss no invalidaba flush. El fallback tampoco liberaba rolling.

Formatter recibe against. Diálogo rotulado/focus_wrap, JS.push_focus/focus y
pop_focus, botón44 px/Escape e inert/aria-hidden explícito preservan pixel-art
y el lienzo dic_ex siempre montado. Cada timer de cierre tiene referencia
propia, se cancela/reemplaza y solo su generación vigente puede cerrar.
Dismiss invalida flush pendiente y limpia hand/groups/rolling/timers; flush
requiere ventana visible y referencia pendiente, evitando duplicados. Settled/
landed ocultos o antes de flush son inocuos. Snapshot retiene referencia local.
Nada se persiste: no cambios World, RNG, reglas, permisos ni Codec.

Nueve nuevos/59 focalizados4,9 s; gate final sin hook2663/3 en54,6 s,
seed30343/max_cases48/salida0, cero errores/desconexiones/avisos de compile;
seis avisos deliberados. Formato/compile/diff correctos. UI1440/375 reproduce
solo payload persistido716 (19vs15), comprueba foco/Tab/Shift+Tab/Escape/Enter,
44 px/lienzo/no overflow/JS y tres PNG incluyendo baseline. No repite RNG.

Seguimiento721→729 produce fallo nativo6+1=7vs15 y pierde rastro, avanza900 s,
revisa escena3,997 s y devuelve turno en17,729 s; Escape cierra tirada nueva.
Restart/SQL mantienen729 eventos, prefijo721, recursos/inventario/facts/hero,
modelos/ajustes, solo escena/log/reloj cambian; cierra cinco auxiliares.
Hook retirado/Show limpio y navegación normal antes del gate final.

Probe de investigación expiró tras acción completada: Game/SQL confirman721
sin repetirla; trace parcial se conserva separado. No se afirma cierre medido
del segundo request TM tras entregar turno. La pista de investigación solo
quedó en narración, no en facts. Chrome/2D/teclado no certifica Safari/hardware/
lector de pantalla. El hook 3D no etiqueta generación: un callback antiguo
posterior al flush nuevo aún no puede distinguirse; ninguna cara cliente cambia
World o dados persistidos. Coherencia/memoria/latencia/beta siguen abiertas.

## D195 — Solo el DM confirma hechos y escenas canónicas
Fecha: 2026-10-03. Estado: **Aceptada e implementada** (R25, AC-25.6).

19425 conserva fallo724/7vs15. Consulta729→739 solo Lyra/Vex recuerda pérdida,
World igual/5,585 s; ambos proponen sin viajar, aunque el texto se parece.
Investigación distinta739→747 produce12+3=15vs15 y una pista de lana. El narrador
humano llama establish_fact y guarda «Mara halló…» antes del DM. Humano usa
DM Server/tools para resolver reglas, con actor propio; autorización D156
permitía hechos propios y set_scene sin exigir DM. Los PCs IA no anuncian esas
tools, pero eso no protege el resolvedor humano ni la ejecución directa.

Reservar establish_fact y set_scene a actor canónico dm ANTES de leer/proponer
World. Conservar saneado/agencia/cap30/idempotencia/replay y los facts antiguos:
no borrar ni reinterpretar la pista ya guardada. Chequeos propios siguen por
Rules y sus resultados no confirman por sí mismos identidad, rumores o mundo.
Guía al final del prompt después de archivo/inventario: humano/PC deja respuesta
del mundo al DM; DM confirma escena/dato relevante con tools antes de narrar,
sin duplicar facts ni convertir testimonio PNJ en verdad. No extraer prosa
como hechos automáticamente. Se restringe el permiso de autor propio D156;
la protección de agencia del DM y las reglas de acción propia permanecen.

Siete tests nuevos/54 focalizados3,0 s; gate final sin hook2670/3 en54,6 s,
seed30343/max_cases48/salida0, sin errores/desconexiones/warnings de compile.
Seis avisos deliberados. Game confirma rechazo antes del DM, revisión y
restart sin repetir chequeo; DM/PC tras compacción conservan hechos/testimonio.
Dos fixtures históricos se adaptan al nuevo permiso; no se cambia el contrato
de SceneRefresh ni se borra una escena ya persistida por otro camino anterior.

Live747→755: inspección20vs15 solo usa ability_check humano, World igual.
Recogida755→762: grant_item DM añade hilo×1 y recorder deja espina vacía.
Consulta762→772/5,593 s solo PCs, World igual: posesión no confirma dueño.
Restart772/SQL/modelos/ajustes/hero/eventos/facts legacy intactos, cinco
auxiliares cerrados. Hook retirado, Show exacto y navegación1440/375/teclado/
dos PNG revisados. Evidencia privada fact-authority-verification.json.

Alcance solo esas dos tools; otros mutadores disponibles al resolvedor humano
requieren auditoría propia. Detalles nuevos quedaron en prosa, no facts; no se
acredita memoria completa. Voz repetida y Vex refuerza la recencia tentativa.
No certifica semántica libre, originalidad, hardware o beta. Primera consulta
al observer llegó antes de pausa: cierre QA falló y luego terminó el mismo
probe vivo una vez. Dos preparaciones de navegador fallaron antes de actuar.
No se repite acción; logs conservados. Segundo request TM sin cierre medido.

## D196 — Criaturas y solicitudes de combate solo por DM
Fecha: 2026-10-03. Estado: **Aceptada e implementada** (R22, AC-22.3).

D195 cierra solo facts/scene. La misma auditoría reproduce spawn_monster PC
con goblin creado, end_combat PC efectivo y roll_initiative PC que alcanza RNG.
PCAgent no anuncia estas tools, pero el resolvedor humano comparte DMServer.
La exclusión del anuncio no sustituye un permiso de ejecución del motor.

Exigir actor canónico dm antes de leer/proponer World o dados en esas tres
tools. Error directivo recuperable remite al actor a resolver su acción y
conserva fase/iniciativa. DM introduce el bestiario y solicita fases; motor
sigue imponiendo iniciativa automática y relevos. Reforzar combate no repite
tiradas previas. No cambia World/Codec/campos/RNG, stubs de framework ni reglas
puras. No afirma victoria por petición ni añade otro detector de combate.
Condiciones, curación cruda y nivel quedan para auditoría independiente.

Rojo2/9 puro confirma siete fallos; nueve verdes. Dos Game rechazan las tres
tools antes del DM, conservan SQL sin dados y permiten spawn DM seguido de
iniciativa forzada nativa; restart no introduce el enemigo rechazado. Primera
fixture de Game supuso orden de dados Mara/Goblin; Actions usa nombre canónico
Goblin/Mara, fixture corregida,11/11 en0,4 s.99 focalizados2,8 s sin avisos;
2681/3 en55,8 s, seed30343/max_cases48/salida0, sin errores/desconexiones/
warnings de compile, seis avisos deliberados. Formato/compile/diff correctos.

No hay acción LLM nueva: TestModel/Session/Game/Postgres verifican el permiso
y reinicio. SQL readonly conserva19425/seq772/World/eventos/hero/recursos y otra
mesa; navegador1440/375 conectado, cero JS/overflow, sin nuevos hooks/PNG.
Evidencia privada combat-authority-verification.json. No implica autorizar toda
petición del DM ni completar auditoría de otros mutadores/coherencia/beta.

## D197 — Efectos directos y nivel reservados al DM
Fecha: 2026-10-03. Estado: **Aceptada e implementada** (R21, AC-21.4).

La auditoría tras D196 reproduce en PC heal que alcanza RNG, condición stun
aplicada/veneno eliminado, subida de nivel y30 PG temporales propios sin
fuente/coste. PCAgent no anuncia estas tools, pero humano comparte DMServer.
El permiso D36 de otorgarse PG temporales permite evitar False Life y su slot.

Exigir actor dm en heal/grant_temp_hp/apply_condition/remove_condition/level_up
antes de World/target/RNG/propuesta. Error recuperable remite a cast_spell,
second_wind o feature, que Rules valida con fuente/recurso. Se restringe solo
el permiso PC de la tool grant_temp_hp de D36: World.apply_temp_hp, no stacking,
absorción y False Life pagado/plazo siguen iguales. Nivel humano sigue por
ficha; DM recibe aviso sin leer World. Aura/presencia/entradas DM se conservan.

El permiso DM de adjudicación directa permanece: no certifica la fuente/coste
de toda curación o condición que el DM introduzca. No extrae nuevos efectos de
prosa, no cambia los datos del personaje ni añade Rules/Codec/migraciones.

Once nuevos: puro rojo3/9 (seis fallos), verde9/9. Game normal/restart rechaza
las cinco tools, conserva veneno/compañera/nivel y False Life con un slot/una
tirada/plazo original antes de curación DM. Segunda petición curativa no
repite hechizo. La fixture antigua de aviso level_up carecía de actor:12/13;
handle DM ilegible conserva la comprobación sin World read,13/13 y15 con Game.
103 focalizados3,2 s sin avisos; gate2692/3 en56,2 s, seed30343/max_cases48/
salida0, cero errores/desconexiones/warnings de compile y seis avisos deliberados.
Formato/compile/diff correctos. Un path de replay inexistente es ignorado por
Mix en focalizados; no se le atribuye cobertura, gate completo sí recoge suite.

No hay acción LLM nueva: TestModel/Session/Game/Postgres acredita el permiso,
retorno y restart. SQL readonly conserva19425/772/World/eventos/recursos/hero/
facts y otra mesa. Navegación normal1440/375 sin JS/overflow, sin hooks/PNG
nuevos. Evidencia privada direct-effect-authority-verification.json. AC-21.4
entregado solo para esas cinco tools; fuente de adjudicaciones DM, agencia,
voz/dudas/memoria/latencia y beta siguen bajo revisión.

## D198 — Proyección de fuentes y memoria de segunda mano
Fecha: 2026-10-03. Estado: **Aceptada e implementada** (R25, AC-25.7).

Después de volver al molino y registrar una comparación del zagal, Lyra/Vex
presentan la comparación del hilo con el abrigo como observación propia. World
contiene su fuente y duda; ambos requests la reciben. Brief reúne todos los
facts bajo «verdad canónica» pese a la advertencia de testimonio. El historial
anterior también puede reforzar una conclusión equivocada. Reproducción real
786→796/4,575 s, sin mutaciones World ni tools: fallo de atribución narrativa.

Proyectar el formato existente «fuente afirma: «…»» a una sección separada
«Testimonios atribuidos (contenido sin confirmar)». NPCStatement.attributed?
reconoce prefijo y nombre/rol válido, sin validar fecha ni interpretar el cuerpo;
legado sin reloj y envolturas dobles siguen atribuidos. Mantener las cadenas
exactas y el orden relativo de cada sección para DM/PC/TM. No mutar/reclasificar
World ni crear un esquema de observaciones personales a partir de la prosa.
Los facts sin ese formato mantienen su presentación anterior; no se revisa
su veracidad ni autoría legacy automáticamente.

Entregar guía de fuentes al final del prompt de cada beat DM/PC/humano si hay
testimonio, también en combate. Hechos/testimonios actuales prevalecen frente
a prosa/resumen que cambie la fuente; una comparación o detalle solo dicho
por PNJ debe seguir atribuido, sin inventar que el PC lo vio. DM puede usar
primera persona en la voz del PNJ que afirma haber observado algo. No aplicar
un reescritor heurístico de «vimos» a prosa arbitraria ni bloquear narraciones
válidas del testigo. AgentInstructions sigue LAST; TM conserva sus capacidades.

Ocho tests nuevos: rojo0/8, verde8/8; la fixture for generada producía un aviso
de comparación constante, cambiado a helper con rol variable.46 focalizados
1,8 s limpios. Game actual recibe guía después del archivo de dados, responde
solo con PCs y conserva World/SQL/Codec, recursos y dado antiguo. Compacción
DM/PC con resumen falso mantiene la fuente actual y guía final; los modelos
scriptados no prueban obediencia semántica libre. Gate2700/3 en55,5 s,
seed30343/max_cases48/salida0, cero errores/desconexiones/compiler warnings;
seis avisos deliberados. Formato/compile/diff correctos.

Misma pregunta real796→806/6,616 s: Lyra/Vex atribuyen comparación al zagal,
no afirman haberla visto. Ambos requests incluyen secciones/guía, inventario,
marca y archivo; solo dos pasos PC, cero tools/TM/recorder/dados/World nuevo.
Desde772: regreso900 s, un nuevo testimonio41535, cuatro acciones, cero dados,
recursos/inventarios/plazos/hero y facts previos intactos. Reinicios796/806
conservan eventos/modelos/ajustes/intents, cierran cinco auxiliares; hook
retirado, Show exacto. SQL readonly/UI1440/375/teclado/dos PNG revisados,
cero JS/overflow, navegación no cambia ambas mesas. No hay baseline íntegra
de la otra mesa anterior a las acciones: solo pausa/Thane12 y comparación
íntegra antes/después de UI. Evidencia privada testimony-source-verification.json.

Límite: mejora de proyección y caso de comparación, no garantía general de
memoria/semántica/originalidad. Detalles materiales solo en prosa y voces muy
parecidas siguen abiertos. Registro nuevo lleva comillas externas dobles;
deduplicar envolturas de un mismo testimonio requiere otro cambio probado
sin renovar la primera marca ni modificar citas internas o hechos legacy.
Segundo request TM del regreso tiene inicio sin cierre medido al cancelarse.
No se fuerza resultado ni se repiten acciones por observación incompleta.

## D199 — Equivalencia textual de envolturas de testimonio
Fecha: 2026-10-03. Estado: **Aceptada e implementada** (R25, AC-25.8).

La memoria real del zagal conserva «''afirmación''» de una envoltura redundante.
Repetir sin comillas la misma afirmación crea otro fact/marca, cambia posición
y puede expulsar uno al cap30. La comparación anterior exigía el mismo cuerpo
literal. Una cita externa vacía también pasaba el límite mínimo de contenido.
No se trata de comprobar veracidad ni deduplicar opiniones semánticamente.

Antes de reemplazar citas internas, quitar únicamente envolturas completas no
ambiguas «…», “…” o ASCII simples/dobles, con anidamiento compatible y
repeticiones del mismo delimitador. El cierre de la primera cita debe abarcar
todo el texto; «una» y «otra» conserva ambas. En simétricas, otro delimitador
igual dentro impide inferir una envoltura; apóstrofo lexical entre letras/marcas/
números no cierra la cita y se conserva. Se inspecciona copia, no se borra de
la afirmación. Escapes o tipografía histórica perdida no se interpretan para
reconstruir una sintaxis original. Mantener los reemplazos internos existentes
que no permiten escapar de la atribución y las guardas de agencia/autoría.

Fuente sigue literal/normalizada, sin comparación por regex del nombre ni
case folding nuevo. Separar cuerpo/marca exterior de formato estricto, luego
comparar mismo texto normalizado sin envoltura. Devolver la primera cadena
retenida exactamente: no reescribir citas ni renovar reloj/posición/marca
legacy desconocida. Una fuente, duda o contenido distinto no se fusiona;
marca dentro del cuerpo no se trata como reloj del motor. No hay migración,
ledger oculto ni recuperación de referencias expulsadas. Límites80/800 siguen
aplicándose a entrada saneada/NFC/espacios antes de desenvuelto; vacío tras
quitar envoltura rechaza. Canonización/comparación acotadas a800 caracteres.

Nueve tests nuevos: real legacy doble/primera marca/cap, registros nuevos,
citas internas/apóstrofos, legacy sin fecha, citas parciales/desparejadas,
vacío/límites y fuentes/dudas/relojes falsos. Game normal confirma request DM,
conserva fact37935 con tres variantes; Game restart registra nuevo fact41535,
reproduce herramienta envuelta y repite sin envoltura sin otro fact/efecto.
Checkpoint/SQL/Codec/una declaración/cero dados correctos. Inicial8/9 asumía
checkpoint en no-op; segundo8/9 revela que «Sigues…» consumía primero modelo
humano. Registro nuevo/pregunta informativa y aserción DM corrigen fixtures,
sin alterar el flujo del producto. Red final con código exacto D198/hash
verificado1/9, ocho fallos; fuente final restaurada y verde9/9.43 focalizados
1,6 s limpios. Gate2709/3 en55,9 s,seed30343/max_cases48/salida0, cero errores/
desconexiones/compiler warnings y seis avisos deliberados. Formato/compile/
diff correctos. Evidencia privada testimony-quote-verification.json.

Sin nueva acción/proveedor LLM ni hooks; corrección determinista probada con
TestModel/Game/Postgres. SQL readonly antes/después mantiene19425/806/World/
eventos/14 facts originales (envoltura real41535 intacta), recursos/plazos/
inventarios/hero y otra mesa íntegra. Navegación normal1440/375/teclado/reload,
modal oculto/lienzo, cero JS/overflow, sin PNG nuevos. No certifica toda fuente,
voz/originalidad/semántica ni beta. Seguimiento: opiniones propias Lyra/Vex,
dudas/recencia/detalles de prosa y fuente/coste de adjudicaciones DM.

## D200 — Criterio propio y recomendaciones condicionales de compañeros

**Estado:** Aceptada. **Fecha:** 2026-10-03.

**Contexto:** una consulta real a Lyra/Vex dejaba decidir al humano y conservaba
World, pero repetía el plan y su justificación; Vex convertía la falta de
testigos en certeza sobre el destino. La guía de voz sola no lo evitaba.

**Decisión:** solo las respuestas pendientes de PCs en exploración reciben,
después del archivo de dados, una guía condicional: recomendar con razón y
criterio de clase/trasfondo actuales, poder coincidir sin copiar la justificación,
no forzar desacuerdo ni planes al pedir recuerdos. La ausencia de testimonios
no confirma destino/identidad. Combate/caída/DM/turno libre quedan fuera. No se
filtra semánticamente la prosa ni se fabrican hechos o acciones para diferenciar
voces. El motor conserva el turno humano y todos los recursos.

**Verificación:** ocho regresiones de guía/Game/compacción/restart; consulta
806→816 de referencia y repetición832→842 en16,903s tras D201. Lyra propone
contrastar indicios por separado; Vex aporta preguntar sin revelar pistas.
World/14facts/reloj41535/recursos/inventarios iguales; sin eventos DM/tools/dados nuevos.
Hubo cambio de modelo/adaptador a DeepSeek4.1/Decart/v2, por lo que no se atribuye
la diferencia solo al prompt ni se certifica semántica general. Lyra aún
desplaza «lo vi de lejos» del abrigo al hilo: queda una mejora de fidelidad
de referentes, sin modificar el testimonio guardado. Beta sigue abierta.

La consulta explícita842→852, ya con continuation4, termina en14,824s y conserva
World/recursos. Ambos atribuyen lo visto de lejos al forastero/abrigo y mantienen
la duda sobre la lana; también repiten casi la misma formulación. Es una
observación adicional, sin cambio de prompt entre ambas consultas, y no prueba
resolver referentes o variedad de voz de forma general.

La guía posterior permite acuerdo breve sobre datos con fuente/dudas correctas
y exige corregir contradicciones del compañero. Rojo5/9 y verde20 locales/20
Hex verifican entrega, compacción/restart y estado. Consulta852→862/9,177s
conserva World/recursos/prefijo852/otra mesa/hero; cambia algo la formulación,
pero aún repite datos y añade imprecisiones («dijo de lejos», «solo encontramos
el botón»). El registro original tiene un pronombre ambiguo; no se interpreta
ni reescribe para resolverlo. Estos casos no prueban brevedad/fidelidad general
ni una mejora causal de latencia. Gate posterior2737/3 en92,1s, seed534983,
max_cases48, sin errores de proceso/desconexiones; beta abierta.

## D201 — Paquetes hermanos en desarrollo y Hex en producción

**Estado:** Aceptada. **Fecha:** 2026-10-03. Sustituye D26 para dependencias.

**Contexto:** el usuario mantiene una candidata v2 en `../exAgent` y pide probar
sus cambios sin esperar publicación. El checkout usa ReqLLM y retira adaptadores
v1; Hex todavía publica1.2.0. Usar main en producción o fingir v2 publicada
impediría reproducir y distinguir ambos contratos.

**Decisión:** dev/test siempre resuelve `../exAgent` y `../dic_ex`, con error si
faltan; DRAGONEX_DEPS_ROOT permite otra raíz. Compose los monta de solo lectura.
Prod siempre usa Hex con rangos1.2/0.2 y mix.hex.lock, sin flags que lo cambien.
mix.lock fija transitivas de la candidata; test permite DRAGONEX_DEPS_SOURCE=hex.
bin/dev carga .env.dev antes de mix y conserva selectores/MIX_ENV explícitos.
Phoenix recarga los tres apps. Endpoint sirve JS/CSS desde el dic_ex cargado
por esa VM. Copiar al priv compartido permitía que un gate Hex sobrescribiera
el renderizador local; se elimina ese compilador y se verifican bytes HTTP en
ambos grafos. Cambios JS se reconstruyen con mix dic_ex.build dentro del paquete.

Fronteras v2: Session recibe kind:agent; Test/custom declaran tools; terminal de
streaming incluye modelo; errores RunError se desempaquetan conservando usage
parcial y las garantías de efectos/replay de Game. Errores de argumento corregibles
levantan ModelRetry; errores operativos conservan el fallo. Schemas anuncian
null/omisión de opciones que el dominio ya admite. Compaction proyecta contexto
para proveedor conservando historia canónica, sin elevar resumen a instrucciones.
WorldDriven tiene codec de política explícito y Session codec de World del host
después de validar JSON/identidad/roster; no cambia la forma de World/Character.

La crónica SQL es texto atribuido de la aplicación, no una continuación de
proveedor. History.import_events/2 entrega esa memoria a todos los modelos como
mensajes user rotulados; conserva visibilidad, orden, compresión y voz. No fabrica
bindings, migra reasoning ni rebaja guardas de exAgent: las respuestas y tools
del run actual conservan continuaciones nativas. La ruta sintética anterior
falló en la web816→832 antes de IO, dejando World intacto. El control HTTP
reproduce ese rechazo y demuestra memoria+una tool+continuación válida. La
evolución concurrente del paquete vincula además routing en continuation4 y
protege perfiles con y sin reasoning. Importación uniforme evita mezclar
Test/ReqLLM y conserva la guarda; el gate actualizado2731/3 vuelve a pasar.

ReqLLM usa perfil OpenRouter explícito sobre stock1.26: envelope obligatorio,
routing acotado y presupuesto único, sin passthrough de extra ni native JSON
habilitado. DeepSeek4.1Flash fija decart; MiMo2.6Flash fija io-net. Ambos usan only
y order, fallbackfalse/require_parameterstrue. Prueba real: DeepSeek pasa localv2
9,5s; MiMo pasa Hex1.2 7,9s. MiMo local falla antes de IO por ausencia de opción
reasoning.enabled:false en stock; no se inventa soporte ni se cambia proveedor.

Hex1.2 ignora message_history por chat y omite capabilities no cargadas. Una
frontera temporal Agent.chat/capability inicializa historia compartida antes de
compactar; constructores cargan capabilities explícitamente. Pruebas de conversación,
compacción/reinicio y replay12/12 en proceso nuevo. Se retira LegacyHistory cuando
el Hex adoptado incluya override nativo, junto al grafo/constructores legacy.

Dados locales admiten authoritative:true: la física es animación y muestra el
valor comprometido; cliente nunca cambia mano/totales/World. Geometría no soportada
o fallo WebGL usa2D; Hex0.2 sin esa capacidad usa2D también. Nueve tests de geometría/
ciclo de vida: última tirada durante carga, fallback exacto d100, cancelación,
idle/hidden/0px, último frame, free Rapier/GPU una vez y todas las caras del d10.

Los ajustes construyen perfiles de todos los roles antes de parar Game o
escribir ModelConfig. Incompatibles mantienen proceso/World/configuración; una
selección válida conserva la mesa pausada y sus eventos. El campo personalizado
usa un formulario nombrado: el navegador anterior lanzaba «form events require
the input to be inside a form». Rojo0/3→verde3/3 y Chrome sin errores.

**Verificación:** local2731/3 en93,0s, seed546348/max_cases48, tras el contrato
concurrente continuation4; Hex2722/3 completo más29 casos de importación final y
15/3 focalizados de cambios posteriores. Compile dev/prod sin warnings y formato
limpio. exAgent78/78 focalizados con el contrato actual;81/81 en el subconjunto
anterior y control privado con fuente6402e4a:3/8. No se afirma gate completo del
paquete. dic_ex80 Elixir+9 Node y build. WebGL
real comprueba caras3/5/7/9/11/19, RAF detenido y cierre de física; escritorio/
móvil, recarga del hermano y ajustes en la misma VM. SQL conserva816 al arrancar
y852 tras consulta posterior a continuation4, otra mesa y hero5164 íntegros.
Escritorio/móvil y ajustes también pasan con ese contrato. Candidatos no publicados; sin deploy,
commit ni cierre beta. MiMo local y fidelidad semántica siguen limitados.

## D202 — Separar animación y lectura del resultado de dados

**Estado:** Aceptada. **Fecha:** 2026-10-03.

**Contexto:** flush armaba el cierre2,6s antes de que llegase el callback de
asentado. Chrome/WebGL real tarda3,426/3,951/4,365s con seis dados: el resultado
podía desaparecer sin mostrar sus grupos. Sin callback tampoco había lectura.

**Decisión:** flush arma un watchdog10s; asentado o watchdog deja rolling=false
y muestra los grupos comprometidos, luego arma el hold de lectura2,6s. Cada
transición sustituye el token y cancela el timer anterior. hide requiere fase
de lectura, deadline requiere fase de animación; generaciones obsoletas no
afectan una nueva ráfaga. Dismiss cancela ambos estados inmediatamente. Se
conservan los assigns/timer compartidos de la FSM y se distinguen los mensajes,
sin cambiar World, dados persistidos ni el cálculo del motor. El watchdog
limita la espera visual, no declara que la física haya terminado ni confía
en caras remitidas por el cliente.

**Verificación:** rojo9/10 de cierre prematuro;23 focalizados locales y23 Hex
verdes, incluido Game/Postgres sin cambios y dos vistas. Gate2733/3 en93,0s,
seed174475/max_cases48, seis avisos deliberados, sin errores de proceso o
desconexiones. Formato/compile dev/prod pasan. LiveView aislada usa componente,
FSM y delegados reales: ack3D4,188s/cierre6,972s; al bloquear ack, resultado
10,436s/lectura2,802s. Total57/DC15/caras exactos, sin JS/tools/LLM. Servidor
de fixture cerrado; navegación1440/375 y SQL conserva19425/852/World/eventos/
otra mesa/hero. No se certifica duración máxima de la física o hardware distinto.

## D203 — Parches publicados y cliente web del paquete instalado

**Estado:** Aceptada. **Fecha:** 2026-10-03.

**Contexto:** Hex señala avisos conocidos en los locks, incluidos agotamiento
por WebSocket de [Bandit](https://github.com/mtrudel/bandit/security/advisories/GHSA-vg8x-66vg-5pxh),
joins sin límite de [Phoenix](https://github.com/phoenixframework/phoenix/security/advisories/GHSA-6983-jfq8-485w)
y validación de enlaces de [LiveView](https://github.com/phoenixframework/phoenix_live_view/security/advisories/GHSA-5cgh-g58j-m9cq).
Además el layout fija clientes CDN1.7.18/1.2.3 separados del servidor.

**Decisión:** actualizar los paquetes web/HTTP con Mix dentro de los rangos
actuales y verificar ambos grafos. Se adoptan Phoenix1.8.15/LiveView1.2.12/
Bandit1.12.5/Postgrex0.22.4/LazyHTML0.1.13 y transitivas compatibles. Hex incorpora
Mint1.11/hpax1.1/Plug1.20.3, ya presentes en local. ReqLLM1.26 y las fuentes de
exAgent/dic_ex permanecen en su contrato de D201. No se parchean dependencias
publicadas para ocultar avisos de compilación. Endpoint sirve únicamente los
módulos stock `phoenix.mjs` y `phoenix_live_view.esm.js` de los paquetes efectivos;
el layout importa esas rutas locales. Sin CDN, copias compartidas o build JS
propio; el cliente y el servidor evolucionan juntos en dev y releases.

**Verificación:** copia privada del WIP, locks generados con Mix y reproducidos
exactamente en raíz. Rojo0/3 de HTTP404/imports antiguos→22 controles privados
verdes. Root2736/3 en94,2s/seed682464; Hex2730/3 en58,0s/seed175437, max_cases48
y seis avisos deliberados, sin errores de proceso/desconexiones. Hex descubre
15 aliases de fixtures v2 sin uso; solo se mueve su ámbito dentro de la guarda,
con2 locales/3 Hex posteriores limpios. Compiles forzados de Dragonex dev/prod
con warnings-as-errors salen0 sin avisos; formato pasa. Builds fríos de terceros
mantienen deprecaciones/xref/Logger documentados, sin silenciamiento o fork.
Ambos `mix hex.audit` salen0 sin retirados/avisos conocidos; no es certificación
de seguridad general o reproducción adversarial de todos los CVE.

Web nueva4035 mantiene los tres roles DeepSeek4.1/Decart. Chrome1440/721/375
conecta/recarga/aplica ajustes, monta y libera3D; SHA de módulos igual a sus
paquetes, peticiones JS solo locales, cero JS/overflow. SQLreadonly conserva
19425/852/World/eventos/otra mesa/hero íntegros. Sin nuevo beat pagado o deploy;
beta sigue abierta.

## D204 — Aclaraciones citadas al mismo PNJ sin reformular al humano

**Estado:** Aceptada. **Fecha:** 2026-10-03.

**Contexto:** la consulta862→869 contiene dos interrogantes y «cuando dijiste…»
dentro de una cita. El detector de una sola pregunta la enviaba al narrador
humano, que añadía gestos; el DM aclaraba un referente sin guardar el testimonio.

**Decisión:** admitir una cita completa y emparejada con hasta tres preguntas
informativas al mismo rol PNJ. Un preámbulo de recuerdo acotado se conserva como
habla, sin interpretar su referente. Prefijo/espera pasivos y prioridad PC siguen
obligatorios; acciones exteriores, otras voces, peticiones o gramática incierta
conservan resolución normal. No cambia Conversation/World/Codec ni se extraen
facts de la prosa. La ruta previa de una pregunta se conserva.

**Verificación:** tres nuevas regresiones; rojo13/16 y verde23 adyacentes.
Game registra una aclaración atribuida conservando la original; hechizo mixto
gasta/tira y restart conserva una sola intervención.869→877 y877→884 publican
literalmente ambas preguntas; retorno humano y World íntegro. La primera falla
por argumentos generados inválidos; D205 recupera la posterior. La respuesta
real queda solo en prosa: registrar toda información duradera sigue abierto.
Gates2742/3 local y2735/3 Hex; escritorio/móvil sin JS/overflow. No es gramática
universal ni corrección retroactiva de testimonios o garantía de fidelidad.

## D205 — Reintento limitado de argumentos generados inválidos en v2

**Estado:** Aceptada. **Fecha:** 2026-10-03.

**Contexto:** un beat DM real recibe invalid_tool_arguments de ReqLLMEnvelope
al validar la respuesta generada. Game lo trataba como fallo terminal y cerraba
la conversación con una pausa ficticia. La misma biblioteca distingue los
errores de schema/history/continuation previos; no se deben reintentar por esto.

**Decisión:** solo RequestError de provider req_llm y reason invalid_tool_arguments
entra en el backoff/límite existente de tres reintentos. Se conserva el rechazo
estricto; no se corrigen argumentos, ignoran guardas o alteran stock ReqLLM.
Los efectos confirmados siguen por el ledger/replay del mismo beat. Los errores
de configuración, credenciales y continuidad conservan su clasificación.

**Verificación:** dos nuevas regresiones; rojo16/18. HTTP stock devuelve una
tool con tipo inválido después de confirmar magic missile, después la repite
válida: cuatro requests, una casilla, daño6 y un grupo.34 focalizados finales
limpios; gates2742/3 y2735/3, seis avisos deliberados, sin errores/desconexiones.
Consulta877→884/9,150s confirma un retry1/3 real y respuesta PNJ, habla literal,
World/prefijo862/otra mesa/hero exactos. No registra la aclaración: memoria durable
sigue pendiente. Formato/compiles propios limpios; avisos de terceros en build
frío sin parches. No garantiza recuperación en cada intento ni un SLA de latencia.

## D206 — Aclaración PNJ con comprobante de memoria del turno

**Estado:** Aceptada. **Fecha:** 2026-10-04.

**Contexto:** D204 conserva literalmente las preguntas al zagal y D205 recupera
un rechazo generado, pero tres consultas reales no guardan la aclaración. El
contexto siguiente puede recuperar solo la versión previa ambigua; pedirlo en
el prompt no prueba memoria comprometida.

**Decisión:** NPCMemoryResolution identifica solo una conversación de exploración
con cita y preámbulo de palabras previas reconocido por Text. El DM requiere
un resultado exitoso de record_npc_statement para esa fuente y turn_id en el
ledger ToolReplay antes de publicar final o deltas. La herramienta valida la
fuente y el Game guarda cambio+recibo por el single-writer habitual. Facts
previos solos no bastan; duplicado retenido confirma sin renovarlo. Reinicio
restaura el recibo; combate puede interrumpir. La capability aplica allow_text_output
en before_model_request; v2 lo lleva a la misma petición, Hex1.2 puede retrasar
tool_choice un paso pero su loop conserva el rechazo de final no resuelto.
La guía pide aclaración/fuente/dudas o límite explícito, no gestos. Sin campos
World/Codec nuevos, interpretación de prosa, llamadas ficticias, cambios en
ReqLLM o reparación de memoria anterior. La obligación no cubre toda pregunta
PNJ ni certifica verdad/relevancia; futura continuation persistida necesita
revalidar su fingerprint de output mode si se habilita en el host.

**Verificación:** nueve nuevos; rojo2/4 y32 focalizados locales/19 Hex verdes.
Stream v2 no revela borrador; Hex buffered bloquea final. HTTP stock v2 tres
requests required/required/auto implícito, Decart estricto/none, una atribución.
Duplicate/restart/fuente incorrecta/turno obsoleto/Codec comprobados. Gates2751/3
y2743/3 sin errores/desconexiones; formato y compiles propios dev/prod limpios.
Mesa884→891/7,665s añade solo testimonio41535 con dudas y origen de información,
conserva14 facts previos/recursos/reloj/otra mesa/hero. Restart/reload1440/375
SQL íntegro, cero JS/overflow, assets stock/sibling efectivos. AC-25.9 entregado;
beta activa, sin deploy/publicación y sin cambiar defaults persistidos.

## D207 — La escena libera sus recursos si falla su construcción

**Estado:** Aceptada. **Fecha:** 2026-10-04.

**Contexto:** cuando new DiceScene lanza después de crear WebGL/Rapier/tabla,
la asignación a hook._scene nunca ocurre. El fallback2D recupera la tirada,
pero no tiene la instancia parcial para liberarla; Chrome confirma recursos
vivos. Un error de renderer.dispose también interrumpía otras liberaciones.

**Decisión:** el constructor del candidato dic_ex es dueño de limpiar su
instancia parcial antes de propagar el error original. Dispose tolera recursos
aún ausentes, intenta sus pasos de liberación aunque uno falle y propaga el
primer error de limpieza; el constructor conserva su error de inicialización.
Idempotencia y fallback2D existentes se mantienen. No cambia protocolo,
motor, caras/total comprometidos, paquete publicado o la elección Hex/local.
Recursos internos que terceros no lleguen a entregar siguen fuera del alcance.

**Verificación:** cuatro límites de construcción y un error de limpieza,
rojo9/12 y13/14→14 Node verdes. Chrome real rojo pierde cleanup; final libera
renderer/contexto/física/tabla una vez pese a ambos errores, conserva el inicial
y pinta18/d20 pendiente con un asentado. Repetición de dispose y escena normal
limpias. Ruta normal anterior al refuerzo final de cleanup conserva caras
3/5/7/9/11/19, RAF y1440/375; último ensayo comprueba cleanup normal otra vez.
Build/compile/formato y14 host locales/14 Hex verdes, SHA servido igual al
bundle candidato. Gates completos previos D206 se conservan como referencia.
SQL19425/901/15 facts/otra mesa/hero íntegros. AC-14.8 entregado; sin publicar/
deploy. No se certifica todo error, recurso interno de terceros o GPU.

## D208 — El modo de dados refleja la capacidad del paquete instalado

**Estado:** Aceptada. **Fecha:** 2026-10-04.

**Contexto:** Hex dic_ex0.2 no anuncia caras autoritativas en3D. El montaje
usaba DiceRoller2D con ID3D, mientras creador y controles permitían/mostraban
3D; el resultado era seguro pero la elección y el estado resultaban engañosos.

**Decisión:** Dice resuelve effective_engine según renderer_capabilities real.
Solo authoritative_3d:true habilita3D. Creator, toggle, snapshot, stage y evento
de tirada usan ese mismo modo. Un paquete sin capacidad presenta2D y deshabilita
3D con «No disponible» en el creador; la mesa muestra el dato «Dados2D».
El control disponible anuncia modo actual y destino, y mantiene bloqueo al
animar. Una preferencia persistida anterior se adapta al presentar, sin
reescribir DB ni World; elección por vista se conserva en snapshots. No se
falsifican capacidades, cambia protocolo de dados o se publica el candidato.
Esto describe capacidad instalada, no éxito de inicialización en cada GPU:
fallback2D del hook sigue cubriendo un fallo posterior, sin reportarlo como
nueva preferencia al servidor.

**Verificación:** tres regresiones rojas local2/3/Hex0/3 verifican creador real,
dos vistas/snapshot/World sin escrituras y coincidencia ID/evento autoritativo.
Fixture previo del wizard se adapta a capacidad instalada. Gates2754/3 en96,7s
y2746/3 en58,4s, seis avisos deliberados y sin errores/desconexiones;26
focalizados finales en cada grafo verifican también el texto del control. Chrome
local/Hex1440/375 con teclado, deshabilitado y resultado19/DC15 conserva guardia
de animación y cero JS/overflow/tools/LLM; capturas inspeccionadas. Navegación
real4035 conserva901/World/eventos/otra mesa/hero; assets iguales al sibling.
Fixtures cerrados, formato/compiles propios limpios. Detector visual: seis
hallazgos preexistentes ajenos al cambio, no auditoría general limpia.
AC-14.9 entregado; beta activa, sin publicar/deploy.

## D209 — Diálogo directo con intervenciones públicas de la pregunta vigente

**Estado:** Aceptada. **Fecha:** 2026-10-04.

**Contexto:** los PCs reciben el testimonio aclarado, pero repiten su resumen
y añaden incisos. El prefijo estable pide prosa de novela mientras la guía
de datos solo permite omitir gestos. La intervención anterior puede quedar
en una crónica compactada; pending reducido tampoco prueba que alguien hablara.

**Decisión:** Game entrega a response_guidance los400 eventos que ya consulta.
El recibo de acción de quiet_close vincula la proyección a la pregunta vigente:
ancla pública con seq/fuente/texto exactos; solo destinatarios anteriores con
narración pública y complete:true tras ella, una por actor. Una respuesta
ausente/pruned/privada/incompleta no se fabrica. Text.scrub y tope1800 por voz;
un texto excesivo se omite entero para conservar sus matices en la crónica.
Se etiqueta diálogo atribuido, no evidencia confirmada ni instrucciones, y
se pide cotejarlo con facts/testimonios. Sin ancla demostrable en la ventana,
la guía normal permanece: no se infiere otra pregunta a partir de similitud.
No cambia World/Codec/DB, compacción o la aridad2 existente.

Solo el compañero capaz que responde recibe un formato final de diálogo
directo en1–2 frases cortas, sin acotaciones/gestos narrados; propuestas y
pasos para investigar son condicionales a la petición. Conserva criterio de
clase/trasfondo, acuerdo y límites de fuente/agencia. Combate/caída/DM/turno
libre mantienen sus instrucciones. Sin recortar/reemplazar prosa por regex,
inventar hechos ni imponer un tope que corte la respuesta del proveedor.

**Verificación:** rojo Game1/3 y formato5/6, seis casos nuevos y27 focalizados
en ambos grafos. TestModel confirma contexto tras restart sobre Vex y tras
compacción que exagera lo dicho por Lyra. Gates finales2760/3 en95,4s/seed916615
y2752/3 en58,1s/seed90244/max_cases48, seis avisos deliberados y sin errores/
desconexiones. Primer intento paralelo colisiona en constraints temporales
de tests,40P01 comprobado con ambas sentencias Postgres. Caso aislado8/8 y
gates finales secuenciales conservan cobertura; AGENTS/protocolo exigen bases
distintas para paralelizar. No se atribuye ese fallo al flujo del producto.

Consulta901→911/5,594s muestra que el contexto solo no elimina repetición/
gestos. Con formato directo,911→921/7,166s no añade gestos de narrador, pero
Lyra76/Vex61 palabras siguen largas/repetidas y con matices de fuente abiertos.
Historial distinto y proveedor estocástico impiden atribución causal general.
World/15 facts/recursos/reloj/otra mesa/hero exactos; Chrome1440/375/reload y
capturas sin JS/overflow, assets iguales al paquete. Formato/compiles propios
limpios. AC-32.4c entrega contexto/formato, no fidelidad semántica o SLA. Beta
activa, sin deploy/publicación.

## D210 — Orden conservado de los testimonios de una misma fuente

**Estado:** Aceptada. **Fecha:** 2026-10-04.

**Contexto:** la comparación inicial y la aclaración del zagal tienen el
mismo reloj41535. Brief presenta ambas como bullets equivalentes, aunque
World añade registros al final y no mueve un duplicado retenido. Los PCs aún
mezclan matices anteriores con los posteriores al consultar la pista.

**Decisión:** NPCStatement expone la fuente literal del formato atribuido con
la misma validación existente, sin interpretar contenido o reloj. Brief
agrupa por nombre completo con NFC/espacios/case; no une apodos, roles distintos
o acentos diferentes. Marca únicamente la última posición conservada de una
fuente con varias entradas. Cada cadena permanece literal, una vez y en su
orden dentro de la sección; ninguna versión se elimina o pasa a confirmada.
La guía distingue orden de registro de tiempo de lo relatado, y pide conservar
una aclaración posterior sobre fuente/límites al usar ese detalle. No supone
que una entrada posterior anule todo lo anterior o sea verdadera. No cambia
World/Codec/DB, cap30, deduplicación o referencias legacy desconocidas.

**Verificación:** rojo5/12; cuatro nuevos casos puros comprueban mismo reloj,
identidad acotada, últimas posiciones por fuente y repetición sin promoción.
Game refuerza mensajes efectivos después del archivo y compacción adversa;
un quinto caso nuevo reinicia entre Lyra y Vex y conserva ambas versiones,
sin repetir voz/humano o gastar recursos.46 focalizados en cada grafo verdes;
compile propio dev/prod forzado con warnings-as-errors limpio.

Consulta nueva921→934/15,905s con DeepSeek4.1/Decart: Vex conserva el límite
de visión cercana, pero Lyra86/Vex66 palabras siguen extensas y con matices
abiertos. Dos interrogativas quedan fuera del recognizer literal PC de una
sola pregunta: reformulación humana y cierre DM reaparecen. Se conserva esa
evidencia, sin atribuir mejora causal o garantizar semántica/SLA. World/15
facts/reloj/recursos/otra mesa/hero exactos; Chrome1440/375/reload sin JS/
overflow, capturas inspeccionadas, assets iguales al sibling. Mesa934 pausada.
Gates completos secuenciales2765/3/95,9s/seed916615 y2757/3/58,6s/seed90244,
max_cases48; seis avisos deliberados y sin errores/desconexiones. Formato/diff
limpios. AC-25.10 entrega orden/procedencia, no resolución automática de
contradicciones. Beta activa, sin publicar/deploy.

## D211 — Varias preguntas informativas conservan la voz humana y el cierre

**Estado:** Aceptada. **Fecha:** 2026-10-04.

**Contexto:** la consulta921→934 contiene dos preguntas informativas a Lyra
y Vex. pc_question_parts exige exactamente un par de interrogantes; no se
publica habla literal ni se reserva el comprobante de cierre. El narrador
humano añade una afirmación a Mara y el DM añade otro párrafo de ambiente.

**Decisión:** admitir de una a tres preguntas completas consecutivas bajo
el mismo vocativo PC. Se verifica cada interrogativa y toda la espera pasiva;
no se descartan palabras intermedias, acciones exteriores, cambio de voz,
espera cronometrada o una cuarta pregunta. La voz mantiene texto/espacios
internos y pasa por scrub. Una coma/punto y coma/dos puntos en cualquiera de
las preguntas sigue excluyendo cierre discreto aunque el habla sea literal.
Las guardas existentes de manual/exploración/identidad/petición exacta,
comprobante de acción, huella World, eventos completos/intenciones y ausencia
de dados/nueva pregunta siguen siendo las que permiten cerrar. Un hechizo o
tirada no se oculta por añadir interrogativas. No cambia World/Codec/DB,
cap800 de la petición, prioridad, tools o el prefijo estable del agente.

**Verificación:** seis casos nuevos y refuerzo de restart/magia mixta;
rojo20/26. Primer verde25/26 cuenta el evento DM de apertura de Games como
cierre nuevo: el fixture final conserva el prefijo y compara solo los eventos
posteriores a declarar. No cambia producto por ese fallo.64 focalizados
locales/Hex verdes, incluidos NPCs y contexto de voces anteriores/testimonios.
Game demuestra habla literal y entrega a ambos PCs, restart sin repetir al
humano, slot/dado cobrado una vez al conjurar, y DM conservado para dado sin
efecto World o nueva pregunta PNJ. Compile propio dev/prod forzado limpio.

Consulta idéntica934→944/4,061s con DeepSeek4.1/Decart: una voz humana exacta,
dos respuestas PC y retorno sin turno/narración DM. World/15 facts/reloj/
recursos/otra mesa/hero exactos. Chrome readonly1440/375/reload sin JS/overflow,
capturas inspeccionadas y bundle igual al sibling. Lyra74/Vex47 palabras,
acuerdo con criterio de cautela propio en Vex; brevedad/fuentes siguen abiertas.
Historial y proveedor estocástico impiden atribuir una mejora general de
latencia/semántica. AC-32.1c entrega el flujo acotado; beta activa, sin publicar/
deploy. Gates completos secuenciales2771/3/96,8s/seed916615 y2763/3/57,8s/
seed90244/max_cases48, seis avisos deliberados y sin errores/desconexiones;
formato/diff limpios.

## D212 — Instrucciones DM completas y límites de título recuperables

**Estado:** Aceptada. **Fecha:** 2026-10-04.

**Contexto:** el creador admite instrucciones sin límite visible, pero
dm_style es varchar255. Una aventura con476 caracteres causa SQL22001,
termina la LiveView y pierde el formulario; no hay inserción. Título tiene
el mismo límite físico y tampoco se valida antes de insertar.

**Decisión:** migrar solo dm_style a text, conservando valores/default.
Mantener título255 y compartir su changeset entre creación y validación
de detalles, contando puntos de código como PostgreSQL. La LiveView muestra
alerta asociada al campo y conserva elecciones para corregir/volver, incluso
tras un cambio final forjado. No añadir requisito de título no vacío ni
truncar texto. World/Codec y single-writer conservan sus contratos. Rollback
a varchar255 requiere resolver explícitamente estilos largos; falla antes
que truncar. La migración de producción queda pendiente de despliegue.

**Verificación:** cuatro casos nuevos y estilo largo entregado al request DM
tras restart. Rojo causal2/7 con esquema previo/validación desactivada;30
focalizados por grafo y gates secuenciales2775/3/97,2s/seed503014 y2767/3/
59,7s/seed846548/max_cases48, seis avisos deliberados, sin errores/
desconexiones. Dos errores iniciales del fixture se corrigen antes del rojo
causal. Compile propio dev/prod/formato/diff limpios; detector New vacío.
Migración test/dev preserva47 estilos/default y estado protegido. Chrome
1440/375/teclado/PNG sin JS/overflow crea19443 con estilo476 exacto/3D.
Abre pausada en6; consulta posterior a Ada llega a13 con World intacto,
pero voz reformulada y fallback tras tres reintentos inválidos. AC-10.5
entregado; no certifica esa consulta ni cierre beta. Sin publicar/deploy.

## D213 — PNJ por nombre y guía del envelope de la candidata local

**Estado:** Aceptada. **Fecha:** 2026-10-04.

**Contexto:** el primer diálogo de 19443 se reformula y falla tras tres retries
de invalid_tool_arguments. El detector solo admite roles; Ada y «¿Sabes si…?»
quedan fuera. Tras corregir esa ruta, 13→21 conserva habla exacta pero el DM
vuelve a fallar. Dos requests frescos stock ReqLLM buffered/stream devuelven
record_npc_statement con speaker/statement planos, sin arguments. Es una
reproducción independiente; no una captura de los ocho errores previos.

**Decisión:** reconocer un solo nombre propio de 3–40 caracteres con inicial mayúscula
cuando se entrega roster PC no vacío, excluyendo nombre completo/primer nombre
PC y manteniendo límites de cita/espera/preguntas/consecuencias. Añadir
«sabes si» a preguntas informativas; peticiones directas/magia exterior
conservan resolución. No introducir registros NPC ni cambiar World/Codec/DB.
La guía del formato wire pertenece al sibling exAgent: un system adicional
solo en Context backend con tools cualificadas. Caller/canonical history/
schema/codec/guards no cambian. No reparar/unwrap JSON plano ni inventar
capacidades. El perfil Hex 1.2 no requiere esa guía. Decisión genérica en
`../exAgent/docs/architecture/design.md`; sin publicación/version bump.

**Verificación:** cuatro nuevos/rojo 9/12/50 focales por grafo; restart conserva
una voz humana y memoria atribuida, magia mixta mantiene slot/dado. Guía:
rojo 14/15 y 131 casos ReqLLM en 14,5 s; fixture de history selecciona único
assistant por rol en vez de índice, sin relajar envelope. Logs negativos
de cierre/cancel/timeout esperados. El intento tooling 1.20.0 y diagnósticos
guardados antes de IO no son rojo de producto; se registra su causa.
Consulta 21→28 en 11,564 s con DeepSeek 4.1/Decart responde Ada y guarda un testimonio
con dudas, sin retries inválidos, con solo facts cambiado. Capturas 1440/375
inspeccionadas, sin JS/overflow horizontal; estado protegido exacto.
Local completo tras guía 2779/3/98,7 s/seed 581205 y Hex 2771/3/61,3 s/seed 889943,
max_cases 48, en secuencia; seis avisos deliberados y sin errores/desconexiones.
Compiles propios dev/prod/formato/diff limpios. FULL del paquete anterior
no se repite. AC-31.2h4 entregado; semántica/brevedad y aventura completa
siguen en beta. Sin deploy/publicar, mesa 28 pausada; avanzar campaña.

## D214 — Recordar la prosa ya publicada dentro del mismo turno

**Estado:** Aceptada. **Fecha:** 2026-10-04.

**Contexto:** el trayecto de Thane registra 300 s correctamente, pero los
eventos DM 44/45 repiten casi el mismo párrafo a ambos lados de una tool.
Events publica ambos segmentos a propósito; el modelo vuelve a narrar el
resultado después del retorno. El recordatorio entre turnos no cubre esto.

**Decisión:** AgentInstructions añade una guía en la proyección de petición
cuando EXISTS confirma prosa pública no vacía, complete:false, del mismo
game/actor/turn_id. La consulta no obtiene su texto. La guía pide una
consecuencia nueva breve, resultados reales y no repetir efectos. Se entrega
una sola vez por request, después del rol, también tras varias tools.
Sin esa evidencia o sin beat no se añade. No borrar/ocultar segmentos por
similitud: podrían contener cambios reales. No modificar historia canónica,
recibos, validación, reglas, schemas ni transporte exAgent.

**Verificación/límites:** tres regresiones, rojo 0/3 y 27 focales por grafo:
dos tools con publicación real, scope exacto/secretos/metadata, proyección
repetida única, cada segmento y recibo conservados. Gates intermedios
2782/3/98,8 s/seed 451855 y Hex 2774/3/60,1 s/seed 69495, max_cases 48.
La apertura real 46→68 conserva los segmentos 58/62 y no recapitula aquel
párrafo. Hay errores recuperados y otras derivas; no se acredita novedad
semántica ni un SLA. AC-31.3a entrega la guía, no un filtro de narración.

## D215 — Revalidar los combatientes al confirmar iniciativa

**Estado:** Aceptada. **Fecha:** 2026-10-04.

**Contexto:** en 19443/68 existe el esqueleto, pero el orden solo contiene
tres PCs. Log registra aparición antes de comienzo de combate y el checkpoint
contiene spawn_monster/roll_initiative del mismo beat. ExAgent ejecuta tools
concurrentemente: serializar escrituras Game no serializa las lecturas previas.
El control puro prepara iniciativa, añade un esqueleto y aplica el callback:
acepta el orden antiguo. Preparar después de añadirlo incluye cuatro.

**Decisión:** Actions.initiative captura nombres/DEX de los presentes con
PG positivos y compara la misma proyección dentro del cambio al aplicarse.
Si varía, rechaza con error directivo para preparar una iniciativa nueva.
No calcula dados dentro del commit, rellena slots sin tirada ni ignora
criaturas nuevas. Escena y otros datos sin efecto sobre iniciativa no la
invalidan. World.begin_combat conserva su API de orden explícito; no hay
cambios de World/Codec/DB ni serialización privada del framework.

**Verificación/límites:** tres tests puros, rojo 1/3: alta, ausencia, caída,
DEX, control fresco con cuatro d20 y desempate; escena válida, sin reroll
al aplicar. 53 focales por grafo incluyen autoridad, iniciativa automática,
rollback de dados/World, handoff y recuperación. AC-29.10 acredita este guard.
No reescribe 19443/68 ni demuestra todas las combinaciones de tools paralelas.
Conservarla pausada y verificar recuperación/replay real antes de continuar
combate/encargo. Beta activa, sin publicación o despliegue.
Gates finales locales 2785/3/97,3 s/seed 980986 y Hex 2777/3/60,3 s/seed
235773, max_cases 48, secuenciales: seis avisos deliberados y sin errores/
desconexiones. Compiles propios dev/prod/formato/diff verificados.

## D216 — Recuperar hostiles omitidos en un combate guardado

**Estado:** Aceptada. **Fecha:** 2026-10-04.

**Contexto:** D215 evita nuevas iniciativas obsoletas, pero 19443/68 ya tiene
un ataque de Vex, un turno gastado y el turno humano de Thane. Volver a tirar
iniciativa alteraría esa secuencia sin poder reconstruir un dado que nunca
existió para el esqueleto.

**Decisión:** antes de reanudar o despachar un beat, Game recupera los hostiles
presentes con PG positivos que faltan del orden. World los incorpora al final,
ordenados por nombre, con la misma regla de refuerzos existente. Conserva
slots anteriores, actor/owner, turnos gastados, recursos, reloj y dados.
Una nota pública declara esa incorporación; no presenta una tirada histórica
inventada. SQL guarda World y nota juntos; solo después cambia Session. Si
falla, queda en pausa y reanudar permite intentarlo de nuevo sin duplicar nota.
No interviene durante un beat en vuelo, checkpoint de actor o inicio de turno
pendiente: esos intentos deben liquidarse con su propio protocolo.

**Verificación/límites:** seis regresiones, rojo 0/6, 36 focales locales
4,3 s/Hex 2,2 s: recovery puro/idempotente/Codec, ausentes/caídos/exploración,
resume y reinicio running, rollback SQL y retry, guards de intentos pendientes.
El roller falla si se usa y el modelo registra cualquier petición inesperada.
Chrome real recupera 68→69 en 0,080 s: solo cambia order/log, una nota visible,
cuatro slots, Thane conserva el turno y Vex su gasto. PG/recursos/reloj300 y
prefijo exactos; 1440/375 sin JS/overflow, bundle dic_ex igual al sibling.
AC-29.11 cubre esta reparación heredada, no una reconstrucción de iniciativa
original ni todas las combinaciones de tools concurrentes. Seguir combate y
encargo; beta activa, sin publicar/desplegar.
Gates2791/3/99,7 s/seed524121 y Hex2783/3/60,7 s/seed763871, max_cases48,
secuenciales, seis avisos deliberados y sin errores/desconexiones; compiles
propios dev/prod limpios. Combate real69→85 cierra correctamente; recogida
85→107 revela self-handoff DM con viaje/entrega no declarados. No certificar
ese cierre de aventura; conservar107 y revisar por separado.

## D217 — Una respuesta ordinaria DM no abre otro turno DM

**Estado:** Aceptada. **Fecha:** 2026-10-04.

**Contexto:** en 19443/85→107, «recojo el farol» registra la recogida, pero
seis beats DM seguidos adelantan regreso300 s, entrega, retirada del inventario
y cierre del encargo. pass_to_dm no entra en la guarda de repetición; el alias
give_turn_to(dm) permite también un primer self-handoff. Los compañeros aún
no han actuado, así que human_due no fuerza la palabra de vuelta.

**Decisión:** tras una respuesta ordinaria del DM en exploración, ambos
relevos a sí mismo ceden a una persona manual elegible, con la prioridad de
participación existente. ExplorationTurns trata dm como repetición cuando
existe esa persona; el historial de turnos se consulta también sin compañeros
IA. La cadena de preguntas/intents/conversación mantiene prioridad. Combate,
mini-turnos, reacción, re-eval y autoplay conservan sus caminos. No obliga a
volver al humano cuando el TM elige otro compañero que todavía no actuó; tampoco
interpreta declaraciones o reescribe World/historia. Es una guarda de relevo,
no una validación semántica universal de cada tool.

**Verificación/límites:** tres nuevos, rojo8/11 (fallan los tres nuevos);
32 focales locales3,6 s/Hex1,5 s. Game real/TestModel grant_item guarda farol×1,
ambas decisiones TM se prueban con cero/dos compañeros; un segundo beat DM
avisa y propone viaje/retirada, y no se ejecuta. Reloj/escena exactos, una sola
respuesta DM y SQL iguales; pure conserva exclusión autoplay y compañeros
no servidos. No rehacer 19443/107: conserva el defecto y seguir mesa nueva por UI.

## D218 — Feedback temporal al reintentar argumentos rechazados

**Estado:** Aceptada. **Fecha:** 2026-10-04.

**Contexto:** en 19444/7→15 y30→37, ReqLLM rechaza argumentos y los tres
reintentos repiten la petición sin una indicación de ese rechazo. La guía de
envelope D213 no garantiza que el modelo cumpla su schema.

**Decisión:** PendingRetry conserva solo la causa normalizada
invalid_tool_arguments del adaptador req_llm. El siguiente intento DM/PC/TM
recibe una guía system estática para revisar schema/tipos/contenedor obligatorio
y conservar recibos de efectos confirmados. AgentInstructions la añade una
vez a la proyección, después del rol; TM usa también esa capability. No añade
el cuerpo del proveedor, cambia historia canónica, schema/validación/envelope,
tools, permisos ni presupuesto/backoff. Otros errores/primer intento no llevan
la guía. Es feedback efímero del último rechazo, no un checkpoint de partida.

**Verificación/límites:** cuatro nuevos, rojo1/4.43 focales locales2,7 s/
Hex1,7 s: actor/TM reales con error sintético, petición siguiente con cue única,
history/eventos sin guía/cuerpo privado, grant_item×1, World SQL y reloj exactos,
sin dado/turno duplicado; negativas de causa y proyección repetida. Un fixture
usaba Server.get inexistente: cambia a history público antes de verde. Primer
verde parcial descubre que TM no tenía la capability; se añade y las cuatro
regresiones pasan. Gates2798/3/99,2 s/seed774345 y Hex2790/3/62,3 s/seed64041,
max_cases48, secuenciales y sin errores/desconexiones; seis avisos deliberados.

Reinicio UI de19444/37 conserva World/historia exactos. Intento37→44 en28,838 s
con un retry pasa a error de tool/control: no existe esqueleto registrado y
la guarda pide actuar como dm, que tampoco tiene ficha. Conserva prosa
intermedia43 y no inventa dados/recursos; no atribuir recuperación completa
ni mejora causal de latencia a la guía. Revisar ese mensaje por separado.

## D219 — Rechazos de control según ficha, presencia y controlador

**Estado:** Aceptada. **Fecha:** 2026-10-04.

**Contexto:** la guarda de Tools sugería actuar como el proposer para todos
los rechazos. En un turno DM sin ficha de esqueleto, pide usar dm como atacante;
esa llamada también se rechaza porque dm es controlador. La ficha omitida se
convierte en una cadena de autocorrecciones imposibles.

**Decisión:** controlled_by? conserva exactamente sus permisos. Solo cambia
el feedback cuando rechaza: ficha inexistente indica nombre canónico y, para
DM, spawn_monster antes de iniciativa/acción; ausente conserva su ficha fuera
de escena; DM como actor o actuando por un PC recibe su función de controlador
y nombres registrados disponibles que realmente controla. Un PC conserva la
corrección hacia sí mismo. No cambia turnos, presupuestos, World, RNG ni
registro automático desde prosa; no sugerir recrear actores ausentes.

**Verificación/límites:** cinco nuevos, rojo1/5,29 focales locales1,8 s/Hex0,9 s.
Casos puros con roller que falla comprueban desconocido/dm/PC ajeno/ausente/
PC correcto. Game/TestModel recibe el rechazo, registra skeleton y después
iniciativa con dos dados; PC/PG/reloj/SQL exactos, sin ataque fantasma. Primer
fixture omitía policy en el harness; se añade antes del rojo causal. Esto
acredita el mensaje y recuperación scriptada, no obediencia del modelo real.
Gates finales2803/3/100,2 s/seed192264 y Hex2795/3/60,1 s/seed71290,
max_cases48, secuenciales, seis avisos deliberados y sin errores/desconexiones;
compiles propios forzados dev/prod, formato y diff limpios.

## D220 — World vigente en la continuación del mismo beat

**Estado:** Aceptada. **Fecha:** 2026-10-04.

**Contexto:** en19444/67→88, Vex pide rematar al esqueleto después de que
su herramienta lo haya llevado a0PG. Brief.turn_prompt fotografía el World
antes del run; los recibos llegan después de tools, pero la petición mantiene
aquella lista de objetivos y recursos. La proyección no incluía una nueva foto.
El fallo semántico observado no permite atribuir toda su causa a ese contexto;
sí permite reproducir la información antigua entregada al modelo.

**Decisión:** Beats pasa los tipos de participantes a deps. AgentInstructions,
desde la segunda petición DM/PC de ese beat, lee Session mediante SharedState
y añade un único WORLD VIGENTE a la proyección. Reutiliza Brief con raza/clase,
PG, inventario, recursos, hechos/testimonios y control actuales. Si
World.combat_over? ya se cumple, indica ausencia de enemigos presentes con PG
positivos y que el motor cerrará combate. No adelanta ese cierre. Sustituye
solo fotos temporales previas, preservando mensajes canónicos, resultados,
reglas, counters y World. Primera petición, contexto ajeno al beat y estado
no World no incorporan foto; TM no recibe los deps necesarios. No registra
desde prosa, filtra narraciones publicadas ni impone decisiones del modelo.

**Verificación/límites:** cinco nuevos: tres de proyección/stock/guards y dos
Game reales con ataque humano y Vex. Rojo2/5; ambas continuaciones faltaban y
la proyección de inventario también. El primer fixture usaba World.add
inexistente; se corrige antes del rojo causal. En verde se aísla SceneRefresh
con su propio modelo y se cuenta el d6 adicional legítimo de ataque furtivo.
17 focales por grafo pasan; PG0 llega antes de finalizar el mismo beat, un
golpe/dados exactos, PCs/reloj/SQL intactos. Foto ausente de Events/history,
stock actualizado sin fotos acumuladas y Session supervisada en tests puros.
Una lectura y un Brief por petición posterior; no hay query SQL nuevo ni
otro beat de modelo. Acredita entrega de contexto, no fidelidad/latencia
universal. No reescribir19444/109 ni19443/107 para borrar los defectos.
Gates finales2808/3/100,4 s/seed261014 y Hex2800/3/60,8 s/seed684244,
max_cases48, secuenciales y sin errores/desconexiones; seis avisos deliberados.
Compiles forzados propios dev/prod, formato y diff limpios. Readback109 tras
reload conserva World/historia, todas las narraciones y47 estilos anteriores.
La aclaración nueva109→116 en12,262 s/cero retries publica voz humana literal
y guarda testimonio PNJ con fuente/duda/606 s. Solo facts cambia; encargo y
recursos exactos tras restart UI/reload1440/375. No confirma aquel avistamiento
ni recupera la primera pregunta fallida o prueba causalidad de latencia.

## D221 — La resolución general no coescribe la voz humana

**Estado:** Aceptada. **Fecha:** 2026-10-04.

**Contexto:**19445/41 añade palabras no declaradas y48 condiciona la entrega.
consume_intent guarda la acción original, pero human_instruction pide al modelo
otra narración y Events publica su Text. El World vigente de D220 no define
quién puede escribir esa voz. Además, al reiniciar tras un resultado humano
guardado, advance_actor espera otra intención en lugar de terminar su checkpoint.

**Decisión:** el resolutor manual general sigue seleccionando herramientas;
su voz sale de la acción pública del mismo game/actor/turn_id, leída también
en retry/recovery. No usa otra acción próxima ni el histórico limitado400.
Events elimina solo Text de la última Response manual; conserva herramientas,
IDs, metadatos, uso y señales de truncación/filtrado. Una final no vacía y sin
tools publica la fuente literal con kind:human_declaration/complete:true.
Texto intermedio/incompleto y deltas del resolutor no se publican. Beats
liquida con la fuente también en Hex1.2, que maneja la Response original tras
el hook; v2 maneja la transformada. No modifica la librería ni su envelope.

History proyecta ese kind como declaración/intención user, sin abreviarlo
como prosa antigua ni afirmar que ocurrió. La entrada escrita por la persona
no es texto del modelo: conserva menciones/notación/palabras, reparando UTF-8;
HEEX la escapa. D7 sigue aplicándose a texto del modelo y args persistidos.
Preguntas/esperas reconocidas mantienen su bypass literal anterior, con su
saneamiento. AI/autoplay/DM no reciben esta sustitución. No reescribe eventos
anteriores ni cambia formas de World/Character/Codec, permisos, RNG, costes,
routing o presupuestos de retry. Una lectura SQL adicional por resolver manual.

Un checkpoint manual con esa acción termina el turno original antes de tomar
una intención nueva; reusa recibos/final ya publicados. No inventa una fuente
para checkpoint legacy sin acción. El fallo definitivo mantiene acción/dados
y publica aviso de sistema, sin titubeo atribuido ni comprobante de éxito.
No valida toda interpretación de la declaración ni obliga a elegir todas
las tools necesarias; la prosa y los hechos emitidos por el DM siguen aparte.

**Verificación/límites:**15 nuevos (Events7/History2/Game6), rojo0/10; fallo
definitivo rojo5/6. Se corrigen expectativas del fixture sobre eventos iniciales,
kind de Item y marca/log de inventario; recursos y prosa exactos se conservan.
Cinco casos existentes cambian su oráculo de voz, manteniendo escena, mini-TM,
conversación y dados.93 focales locales14,1 s/Hex6,5 s. Hex1.2 no transmite
stream_text en Server.chat: el control positivo de deltas DM solo acredita v2;
ambos grafos verifican texto/recibos/World público. Gates finales2823/3/100,1 s/
seed52307 y Hex2815/3/60,2 s/seed948896, max_cases48, secuenciales, seis
avisos deliberados por gate y cero errores/desconexiones. Compiles propios
forzados dev/prod, formato/diff limpios.19446 publica tres voces humanas
exactas, inventario×1 entra/sale y recursos intactos tras restart UI/reload.
La primera declaración no tiene ataque humano aplicado; Vex derrota al bandido.
Intro DM publica razonamiento; entrega dice cierre sin fact y adornos del PC
persisten en DM. No afirmar fidelidad universal, mejora causal de latencia ni beta.

## D222 — Frontera de publicación para narración estructurada

**Estado:** Aceptada. Integración por defecto verificada offline; R16/live pendientes.
**Fecha:** 2026-10-04.

**Contexto:** 19446/5 publica deliberación sin marcadores como Part.Text con
reasoning:none. No existe una separación entre contenido público y texto
auxiliar. La API oficial de output Ecto de exAgent está disponible en ambos
grafos, pero final_result junto a otras calls termina el run y deja sus
hermanas sin ejecutar. Sus callbacks de tools ordinarias no validan la call
de output; allow_text_output tampoco bloquea una final estructurada pendiente.

**Decisión:** usar Narration, un embedded_schema sin persistencia ni cambios
al dominio, con text obligatorio, UTF-8 válido y 1–8000 codepoints. Contract
opera solo cuando output_type es Narration. Desactiva el preview de texto
libre; Events conserva la Response completa en la continuación privada y
omite su publicación. Retiene contenido, partes, IDs, flags, uso y metadatos.
No introduce parsers privados del proveedor,
forks, capacidades ficticias ni cambios a ReqLLM/exAgent/dic_ex.

publish_result valida el par terminal Response/Request de new_messages;
exige una sola call final_result, output coincidente con sus args y retorno
ok del mismo ID. No usa el historial anterior como prueba del turno actual.
Comprueba vida del propietario, espera y aclaración PNJ desde SharedState
antes de publicar. Events devuelve el texto efectivamente persistido o una
causa de no publicación; su API anterior mantiene el retorno :ok. Texto del
modelo sigue pasando por Text.scrub con roster vigente; voz manual usa su
declaración fuente y permanece una intención. Ninguna comprobación resuelve
reglas, RNG, recursos o herramientas omitidas; los errores contienen solo causa.
Game conserva la propiedad de los checkpoints de publicación, sin cambiar
Character/Weapon/Spell/Item.

**Verificación inicial/límites:** 15 pruebas, con loop y Server reales en ambos
grafos. El rojo inicial pasa 1/13: once fallos de la frontera y un oráculo de
Text.scrub corregido para usar una acción que ya filtra. La primera integración
de los fixtures pasa 11/13; los dos restantes eran IDs repetidos de Session,
corregidos con supervisión separada. Contexto ausente reproduce después 14/15.
El control de streaming recibe deltas sin la frontera en v2; Hex 1.2 chat es
buffered y no se atribuye esa garantía a un stream inexistente. Un caso
adicional ReqLLM stock reproduce 0/1: quitar Text alteraba el assistant enviado
en el retry a una cadena vacía. Se sustituye esa mutación por la guarda de
publicación de Events; el control exige contenido nativo exacto en HTTP,
envelope real de final_result y Decart estricto/none, sin usar la red.
El schema
valida el sobre, no la verdad de la prosa ni la selección de todas las reglas.
La base anterior dejó pendiente integrar Game y verificar sus recorridos.

**Integración por defecto:** DM/PCAgent/Beats ya usan output
Narration sin bypass por TestModel/grafo. narrate es una tool explícita con
replay; cierre rechazado recibe una corrección de Game y después pausa el
mismo turno. ToolReplay restaura un checkpoint vacío pending_narration;
presupuestos sobreviven a PendingRetry503. Un segundo corte por tokens pausa,
sin borrar declaraciones válidas ya publicadas.

Game.NarrationCheckpoint guarda prosa y recibo juntos antes de Session/PubSub.
La intermedia conserva recibo pagado aun antes de que narrate termine; la
final conserva turno incluso sin tools, hasta revisión/settlement. Así restart
no repite publicación/costes. Reutiliza actor_checkpoint, sin campos nuevos
al dominio ni inferir resultados desde prosa. SQL fallido revierte ambos y
no anuncia la narración. Voz manual fuente y partes privadas nativas intactas.

19 casos nuevos: DM/PC, hermanas omitidas, ataque humano/RNG únicos, flags,
espera, backoff, pausa/restart y cortes antes de acuse/settlement. Rojo0/5
inicial,5/6 pérdida de intermedia al retry de tokens,7/12 flags que avanzaban
sin cierre,14/16 falta de recibo antes del acuse/en final sin tools.
Rojo17/19 reproduce retry tras pausa manual con cierre mixto o truncado;
Game conserva pausa/checkpoint sin lanzar otro retry ni reanudar.
Migración explícita de109 archivos anteriores, conservando oráculos de reglas,
fuentes y roles; se añaden comprobaciones de cierre real para evitar que un
fallback mecánico ocultase un fixture inválido. Verdes271 locales/269 Hex
en40,0/19,5 s; SQL rollback/etapas LiveView incluidos.
Otros9 por grafo en2,1/1,2 s cubren espera con magia, destinatario PNJ,
observaciones e iniciativa rechazada por SQL/recovery con cierre persistido.
Otros30 por grafo en8,2/3,3 s cubren voz/ritmo de PCs, memoria de tiradas,
agencia y actualización de escena, con los oráculos de fuente y World intactos.
Tandas posteriores local/Hex:25/23 PNJ/escena/ReqLLM retry,55/55 efectos/
persistencia/ciclo de vida,68/68 mesa web/reacciones/progresión,13/13 hechos/
antibucle,17/17 iniciativa/relevo,21/21 bucle de TurnMaster y3/3 lobby/ficha móvil.
La prueba de
respuesta tras un PC exige ahora cierre DM posterior, no una nota del relevo
inicial. Su prosa inicial deja de atribuir al humano una acción no declarada;
se conserva la fuente del jugador y se verifica retorno sin fallo de turno.
ReqLLM stock comprueba tres HTTP sintéticos: cierre prematuro sin memoria
rechazado, record_npc_statement y final_result validado. Sobre oficial,
Decart/none estricto y tool_choice required también tras registrar memoria.
La continuación nativa privada se conserva dentro de un run; el retry de
Game reconstruye contexto desde eventos públicos/recibos y no importa aquel
cierre rechazado. No confundir ambos límites de contexto.
Compile test140/prod Hex133 forzados con warnings-as-errors limpios.
Gates completos de integración D222 local2858/3 en105,3 s yHex2849/3 en63,8 s,
seed0/max_cases48, secuenciales y sin warnings/errores/desconexiones.
R16/live pendientes; estos gates no certifican AC-31.3d/beta.
19446/42 y originales/47 estilos/bundle/adaptador permanecen exactos.
El contrato público request_stream actual no entrega deltas de argumentos
tipados; ReqLLM emite texto y acumula las calls hasta la respuesta terminal.
Hace falta un camino público verificado para el preview del campo text.

**Gates de la base, anteriores a integración:**55 focales locales/54 Hex,
5,6/3,0 s. Gates2839/3 en101,5 s
(seed 872554) y Hex 2830/3 en 62,2 s (seed 595324), max_cases 48,
secuenciales; un aviso deliberado local/seis Hex, sin errores/desconexiones.
Compiles propios forzados dev/prod de 132 archivos con warnings-as-errors,
formato/diff limpios. Readback 1440/375 conserva narraciones y estado de
19446/42, originales protegidos y 47 estilos; bundle sibling y cero JS/overflow.
Esta evidencia histórica verifica la base; no sustituye los nuevos gates ni
acredita activación en la VM web. R16/NFR-5 pasan a revisión: preview libre
retenido; falta un preview seguro de campos estructurados.

## D223 — Causa de cortes Model en errores acotados de exAgent

**Estado:** Aceptada. Corrección del paquete local verificada offline; live pendiente.
**Fecha:** 2026-10-04.

**Contexto:**19447/51 pierde la causa original con retention_limit_exceeded,
error6300/4096; la entrega no retira campanilla ni guarda cierre. El fallback
devuelve Thane sin checkpoint. Esa mesa permanece íntegra. Una reproducción
separada demuestra que una Response incompleta de6–8KiB, válida dentro de su
límite, se copia también en RequestError y excede el control4KiB. Game deja
de reconocer length/content_filter, aunque el diagnóstico completo ya existe
en RunError.partial.pending_response. No afirmar que sea la causa original
de19447: sus bytes nativos no se conservaron en DB.

**Decisión:** arreglar esta duplicación general en ExAgent.Retention del sibling,
sin adaptador paralelo ni cambio a ReqLLM stock. Si sólo la copia parcial hace
exceder4KiB, sustituirla por marker:error sin parts/usage; conservar categoría,
finish_reason y diagnóstico acotado en pending_response. Control arbitrario
que siga excediendo se rechaza con su tamaño original. Copias pequeñas y
límites actuales intactos. No ejecutar calls incompletas ni reintentar desde
el framework; Game conserva sus presupuestos/replay y el World single-writer.
Sólo aplica a la candidata local v2; producción sigue usando Hex publicado.

**Verificación:** cinco nuevas del paquete; rojo39/42 y26/27 del tamaño del
negativo,102 focales verdes en11,8 s y58 runtime/Session/persistencia aparte
en0,6 s. Compilación forzada propia test130 con warnings-as-errors limpia.
Los102 incluyen diagnósticos existentes de peer cerrado/owner death; no se
atribuye su limpieza a este cambio. Dragonex23 en3,8 s con un caso v2 nuevo:
retirada ya pagada, corte nativo largo, mismo turno/retry, callback una vez,
fact de cierre una vez, sin prosa privada en history/eventos ni RNG.
Gates Dragonex nuevos local2859/3 en106,3 s yHex2849/3 en62,9 s,
secuenciales, seed0/max_cases48, sin warnings/errores/desconexiones.
La evidencia y los contratos del paquete constan también en su diseño,
changelog, status y roadmap. No full nuevo de ExAgent, publicación, bump,
commit ni claim de arreglo live. R16 y beta permanecen abiertos.

## D224 — Protocolos dinámicos con paquetes locales; consolidación en producción

**Estado:** Aceptada. Verificada offline en dev/test/producción.
**Fecha:** 2026-10-04.

**Contexto:** al recompilar exAgent local tras D223, dev avisa que Jason.Encoder
ya está consolidado y su derive de Server.Snapshot no tiene efecto. Mix usaba
su default de consolidación también en desarrollo; Phoenix recarga exAgent/
dic_ex. Un tipo nuevo con derive después de compilar falla al serializar en
dev y test. No basta silenciar el aviso ni repetir el build sin cambiar la
causa: el dispatch consolidado desconoce implementaciones nuevas.

**Decisión:** consolidate_protocols sólo cuando MIX_ENV=prod. Dev/test mantienen
el dispatch dinámico para los paquetes locales; prod conserva la consolidación
y su grafo Hex. No tocar protocolos del paquete, decoder, datos de partidas,
credenciales o caché global. El coste de lookup dinámico queda acotado al
entorno de iteración; no cambia el build de producción.

**Verificación:** regresión determinista crea un tipo/encoder en memoria
después de compilar y comprueba roundtrip real, con cleanup de ambos módulos.
Probe dev sin arrancar la aplicación verifica también Snapshot real. Rojo en
ambos entornos: derive sin efecto y Protocol.UndefinedError. Verde local/Hex;
probe dev comprueba roundtrip del tipo nuevo y Snapshot real. El warning viejo
se repetía desde el manifiesto del paquete incluso sin compilar: el código
Mix confirma previous_warnings en noop. Recompilar exAgent dev94 desde cero
con la configuración corregida elimina el diagnóstico sin silenciarlo.
Compile propio dev133/test140/prod Hex133 forzado con warnings-as-errors y
probe dev posterior limpios. Probe de configuración prod conserva
consolidación/Hex; gates completos2860/3 en105,8 s y2850/3 en63,3 s,
secuenciales seed0/max_cases48 sin warnings/errores/desconexiones. Formato/diff
limpios. Esta prueba no cualifica la nueva candidata en una partida real;
D223/live, R16 y beta siguen abiertos.

## D225 — Ataques de enemigos admitidos después de iniciativa en la mesa

**Estado:** Aceptada. Rechazo verificado offline en ambos grafos; recorrido live adicional.
**Fecha:** 2026-10-04.

**Contexto:**19448/48, DeepSeek4.1/Decart, recoge/entrega campanilla×1 y registra
cierre único, sin retry. Pero el bandido tira ataque en exploración12, antes
de las cuatro iniciativas14–17, y otro en su slot de combate21. Ambos fallan;
el segundo turno demuestra la acción extra aunque no haya daño. La ficha
existía y assert_controls aceptaba al DM; la iniciativa automática llegaba
sólo al terminar el beat. No cambiar la mesa que reproduce el defecto.

**Decisión:** en la admisión de callbacks de Game.ToolReplay, una nueva
make_attack de enemigo presente/apto/controlado se rechaza en exploración
antes de ejecutar la tool o gastar RNG. La directiva pide roll_initiative
y respetar el slot; agent_tools convierte ese error en ModelRetry dentro
del presupuesto existente. El Game single-writer valida su World vigente.
Recibos ya pagados se buscan primero; no bloquear su replay ni introducir
otro cambio de fase automático al registrar cada monstruo. Se conserva
el API de matemática offline y de Session sin Game. No afirma cubrir aún
otras tools ofensivas ni decidir sorpresa o intención desde la prosa.

**Verificación:** reproducción determinista roja5/6: tres d20 en vez
de las dos iniciativas. Regresión ampliada a fallar/acertar críticamente si
el ataque se admitiera: RNG ausente, PG íntegros, iniciativa explícita única,
World/SQL iguales y retorno humano sin fallo.72 focales locales finales en6,9s,
incluyendo combate/relevo/fallback/recovery/SQL y contrato de narración.
Gates completos2862/3 local en106,4s y2852/3 Hex en63,0s, secuenciales,
seed0/max_cases48 sin warnings/errores/desconexiones. Compiles propios
dev133/test140/prod Hex133 forzados con warnings-as-errors limpios; formato/diff
limpios. Runtime/config/deps/lock de exAgent conserva el delta D223.
Después de los gates cambia externamente su mix.exs sólo en extras/grupos de
docs: comparación byte a byte fuera de defp docs y hash previo contra HEAD
confirman alcance. Se conserva ese trabajo, sin atribuirlo a D225.
AC-29.12 pasa offline. La nueva VM con admisión activada ejecuta19449/38:
cuatro iniciativas antes de todo ataque, orden respetado y ningún ataque
enemigo extra; Vex7/Lyra9, una casilla gastada. Recogida×1/entrega×1 y cierre
único,39,734/10,520/16,111s hasta el humano sin retry. La traza pública no
acredita que se ejercitara la rama de rechazo; no confundir el recorrido con
esa prueba. Repite una cita PC y registra testimonio PNJ indirecto.
Restart/reload1440/375 conserva38/SQL/narraciones,47 estilos y referencias
anteriores, cero JS/overflow. Bundle SHA06a39589 coincide con el nuevo sibling
actualizado externamente; no se atribuye su cambio a esta decisión.
19449 queda protegida; R16/AC-31.3d/beta abiertos.

19448 también conserva prosa DM intermedia/final exacta22/23 y Vex narra
«13 más5» aunque el motor registra13 total, incluido sneak. La entrega
11,541s funciona; no reproduce el error de retención ni acredita su retry
live. Restart de agentes/reload1440/375 conserva48/SQL/narraciones,47 estilos,
mesas/héroe protegidos, bundle sibling y cero JS/overflow. R16/beta abiertos.

## D226 — Total de daño del arma separado de contribuciones incluidas

**Estado:** Aceptada. Verificada offline en ambos grafos; recorrido live adicional con fuentes concurrentes.
**Fecha:** 2026-10-04.

**Contexto:**19448 registra ataque Vex con daño13 incluido sneak5, pero el
feedback «por13 de daño piercing (+5 sneak)» invita a volver a sumarlo.
La narración dice «13 más5». El cálculo y PG son correctos; el contrato textual
mezcla un total con contribuciones ya incluidas. Conservar la reproducción.

**Decisión:** el feedback de cada golpe declara «de daño <tipo> en total»
y agrupa Savage/sneak/furia/presa marcada bajo «incluye». Esos componentes
ya pertenecen a dmg. Castigo divino se mantiene radiante adicional, separado
del total del arma; inspiración modifica el ataque y se etiqueta como tal.
No cambiar cálculo, RNG, recursos, shapes/Codec ni eventos anteriores.
La claridad factual se entrega desde Actions, sin pedir al modelo que
reinterprete etiquetas ambiguas ni asumir fidelidad universal de la prosa.

**Verificación:** ocho casos deterministas, inicialmente rojos, cubren
13 incluido5 sneak, furia, marca, crítico Savage+sneak, Extra Attack por golpe,
smite/slot único e inspiración acertada/fallada. El primer verde4/8 compara
tuplas con listas serializadas de RollLog; corregir la forma conserva los
dados/total/PG esperados.8/8 limpios;214 focales en0,3s. Se migran únicamente
expectativas textuales de seis módulos anteriores, conservando sus oráculos.
Gates completos2871/3 local en108,5s y2861/3 Hex en65,1s, secuenciales sobre
dragonex_combat_test y builds separados. Incluyen además un nuevo caso externo
de tarjeta DC/CA; se conserva sin atribuirlo a esta entrega.
Compiles propios forzados dev133/test140/prod Hex133 con warnings-as-errors
limpios, formato/diff limpios.641 fuentes estables durante los gates;
mesas19443–19449, originales/héroe y47 estilos exactos. Recibo
attack-damage-message-verification.json. Los gates preceden el trabajo D227.

La VM nueva ejecuta19450/46, DeepSeek4.1/Decart:20,899s apertura;64,293s
entrada/iniciativa/Vex;18,115s ataque humano en su slot;24,238s recogida y
16,615s entrega, sin retries/fallos. Vex10=arma2+DEX3+sneak5 deja bandido1;
Thane7=arma4+STR3 lo derrota. Fuente humana literal yPG12/7/10/Lyra2casillas/
reloj0 íntegros; recogida×1/retirada×1/cierre único. La declaración inicial
sólo abre combate y exige declarar otra vez en el slot; se registra ese
límite del recorrido. Vex no cita cifras: no prueba corrección aritmética
del modelo. Reload1440/375 conserva46/SQL/narraciones y referencias, cero
JS/overflow y bundle sibling. El nuevo recibo registra cambios concurrentes
de narración/chat/History y docs exAgent; Actions mantiene el hash verificado,
pero no se afirma que toda la partida usara las641 fuentes fijas del gate.
19450 queda protegida. Testimonios indirectos y un fact histórico que aún
sitúa la campanilla en la mesa permanecen; fidelidad/R16/AC-31.3d/beta abiertos.

## D227 — Ecos de voz dentro de un turno se muestran una vez

**Estado:** Aceptada. Verificada offline; nueva partida pendiente.
**Fecha:** 2026-10-04.

**Contexto:** el chat repite prosa por dos vías. (1) Desde D221 la voz humana
se publica literal como `human_declaration` tras las tools, después del
`:action` original: 14/14 declaraciones de las mesas recientes salen dobles
(chip D112 plegado + línea visible tras los dados). (2) `final_result` copia o
casi copia lo ya publicado con `narrate`: 19447/35→36 y 19448/22→23 exactas,
19443/44→45 con dos palabras cambiadas, 19449/15 repite la cita de Vex ya
contenida en 14 y 258/55→56. History reenvía al modelo ambas copias, lo que
refuerza la repetición y gasta la ventana de 12 narraciones literales.

**Decisión:** `Dragonex.SpeechEcho` (puro) analiza eventos del mismo actor y
`turn_id` no nulo. Una `human_declaration` idéntica a un `:action` del turno
se oculta y marca la acción como «con voz»: Chat la pinta como línea PC
visible en su posición (antes de los dados), sin chip; sin voz publicada el
chip D112 se mantiene. Entre una narración no completa y la siguiente del
mismo actor/turno: igual → queda la posterior; una contiene a la otra (por
palabras, ≥4) → queda la más larga; jaccard de raíces ≥0,6 → queda la
posterior, escrita tras los resultados. Dos completas solo se pliegan si son
idénticas. Paráfrasis y continuaciones no se pliegan: sobre todas las mesas
dev las copias puntúan 0,73–0,88 y el par legítimo más alto 0,33; distinguir
paráfrasis requiere juicio semántico. Chat y History aplican el mismo
análisis; los eventos durables, checkpoints, recibos y la paginación no
cambian. En origen, `Contract.instruction` y la respuesta de `narrate` piden
que el cierre continúe con lo nuevo sin copiar, recitar ni parafrasear.

**Verificación/límites:** 12 unitarios con textos de las mesas reales,
2 LiveView (rojo 0/2 sin el análisis) y 3 History (rojo 2/3). Probe sobre las
55 mesas dev (965 eventos): oculta exactamente las 5 copias citadas y 14 voces
humanas, sin falsos positivos. Gates 2888/3 local y 2878/3 Hex, secuenciales
en dragonex_chat_test; test141 forzado sin warnings. El refuerzo de prompt no está probado live y no
garantiza obediencia; las paráfrasis (19447/20→21, 9→10, 19446/40→41) siguen
visibles. Las mesas protegidas solo se leen.

## D228 — Turno de actor fallido: pausa recuperable, no prosa de relleno

**Estado:** Aceptada. Verificada offline en ambos grafos; partida live pendiente.
**Fecha:** 2026-10-04. Sustituye a D17 para beats de actor.

**Contexto:** 19447/49–52: el DM falla por `retention_limit_exceeded` tras la
entrega humana. El fallback publica «Una pausa breve se instala en la mesa…»,
marca el turno como gastado, limpia ToolReplay y devuelve la palabra: la
entrega queda sin resolver y el feed afirma algo que no ocurrió. D222 ya
pausaba y conservaba el turno para errores de narración/max_tokens; el resto
de fallos duros seguía la vía de relleno y solo pausaba tras 4 seguidos (D17).

**Decisión:** el primer fallo duro de un turno de actor (DM, PC IA o resolución
humana), tras agotar reintentos transitorios, usa `ToolReplay.retain_turn`:
pausa, guarda el checkpoint del mismo `turn_id` y publica en la misma
transacción una nota `kind: "turn_retained"` con un motivo legible
(`Beat.failure_label`: proveedor sin respuesta, petición rechazada, respuesta
demasiado grande o no válida, error interno). La causa cruda sigue solo en la
nota DM. No se marca el slot, no avanza el turno ni limpia recibos. Reanudar
reejecuta ese turno; las tools pagadas devuelven su recibo (sin RNG/costes) y la
cabecera de turno no se duplica. Si ese mismo turno vuelve a fallar
(`Games.turn_retained?`, durable ante reinicios), se omite por la vía anterior
de liquidación de slots, con nota `turn_skipped` y nunca prosa inventada:
un fallo determinista no bloquea la mesa. `Beat.fallback_narration` se elimina.
El TurnMaster mantiene su fallback a WorldDriven y su disyuntor propio.
`:retain_failed_turns` (por defecto true) permite a once módulos de test seguir
ejercitando directamente la vía de omisión.

**Verificación/límites:** siete casos nuevos, rojos con la política anterior
(7/7 fallan con ella y el resto de la batería pasa): resolución humana con y sin
replay del ataque, doble fallo con omisión, monstruo con ataque pagado que se
reanuda sin dados ni daño nuevos, 503 agotado, 400 inmediato y proveedor siempre
caído. Una sonda sobre la batería mostró guiones TestModel agotados que el
relleno ocultaba; el de GameSheetStateTest ocurría también con la política
anterior y su guion se completa. Solo el creador tiene «Reanudar»; la barra de
un invitado dice «En pausa · la reanuda quien creó la partida» (LiveView).
Gates finales 2892/3 local (seed 0 y 4242) y 2882/3 Hex, secuenciales en
dragonex_chat_test; dev134/test141 forzados sin warnings. No hay prueba live
ni reproducción del 6300/4096.

## D229 — WorldDriven en exploración continúa tras quien tenía el turno

**Estado:** Aceptada. Verificada offline.
**Fecha:** 2026-10-04.

**Contexto:** el reparto de exploración usaba un cursor independiente de
`current`. Un `handoff` del TurnMaster (p. ej. la apertura «El turno pasa al
DM») mueve `current` sin el cursor, y el siguiente `end_turn` podía volver a
elegir al DM: un segundo beat DM seguido. Con D228 apareció como pausas
intermitentes en WorldFactsTest (grafo Hex): mesa humano+DM, TM sin decisión,
fallback → DM otra vez → guion agotado. Antes se ocultaba con relleno.

**Decisión:** en exploración, `pick` toma el participante siguiente a `current`
en el roster y recoloca el cursor; sin `current` válido usa el cursor como
antes. Combate conserva el cursor por iniciativa, porque los huecos DM
consecutivos repiten el mismo id (D34).

**Verificación/límites:** regresión de policy roja con el síntoma DM→DM y verde
tras el cambio; dos baterías Hex consecutivas sin las pausas intermitentes.
Los DM→DM de 19443 son decisiones TM explícitas anteriores a D217, no esta
carrera; no se atribuye a D229 una mejora observada en partidas reales.

## D230 — Fuente de testimonio con su rol en aposición

**Estado:** Aceptada. Verificada offline y en partida live 19451.
**Fecha:** 2026-10-04.

**Contexto:** 19451/13–17: el DM registra a «Mira, la molinera» dos veces; la
gramática de fuentes rechaza la coma, el mensaje no dice qué corregir y el
turno se agota (D228 pausa y después omite). La coma en aposición es la forma
natural de nombrar a un PNJ con su rol.

**Decisión:** `NPCStatement.fact` normaliza una única aposición «Nombre, rol»
a «Nombre (rol)», forma ya admitida por la gramática almacenada; no se amplía
esa gramática, para no reclasificar hechos existentes. La comprobación de que
la fuente no sea un PC mira también el nombre antes del paréntesis: «Lyra (la
maga)» deja de colarse como testimonio. El error lista formas válidas. Un log
`record_npc_statement rejected speaker=…` conserva la fuente rechazada.

**Verificación/límites:** dos casos nuevos (aposición y PC disfrazado), 26
focales. En vivo, «Insisto a Mira…» registra «Mira (la molinera) afirma: «…»».

## D231 — Combate solo con hostiles registrados; objetivo sin ficha

**Estado:** Aceptada. Verificada offline y en partida live 19451.
**Fecha:** 2026-10-04.

**Contexto:** 19451/26–40: Thane ataca a ratas que solo existían en la prosa.
El resolutor manual intenta `spawn_monster` (exclusivo del DM) hasta agotar
reintentos. Después el DM tira iniciativa antes de crear las ratas: el motor
abre un combate sin enemigos y las criaturas entran al final sin tirada.

**Decisión:** `Actions.initiative` rechaza abrir combate sin una criatura
hostil viva y presente, indicando registrarla primero con `spawn_monster`.
Para objetivos inexistentes, el envoltorio de tools añade al «no existe el
objetivo» la guía: solo el DM registra criaturas; quien resuelve a un PC cierra
con confirmación. El rechazo de `spawn_monster`/`roll_initiative` y la
instrucción humana dicen lo mismo. Los refuerzos que entran a mitad de combate
siguen uniéndose al final sin tirada, como ya estaba documentado.

**Verificación/límites:** regresión de iniciativa sin hostiles; cinco tests de
orden reciben un enemigo sin cambiar lo que comprueban; caso Game de ataque a
«rata» sin ficha que cierra sin fallo ni criatura creada. En vivo el reintento
del turno cierra y el DM registra las dos ratas.

## D232 — Una declaración humana sin reglas no se narra resuelta

**Estado:** Aceptada. Verificada offline; obediencia live pendiente.
**Fecha:** 2026-10-04.

**Contexto:** 19451/37–38: tras cerrar la declaración de ataque sin ninguna
tirada, el DM narra «Thane lanza su estocada… pasa rozando» y mordiscos de
las ratas, sin herramientas.

**Decisión:** `Instructions.unresolved_human_intent/1` detecta, a partir de los
eventos, que el turno de actor inmediatamente anterior al del DM fue una
declaración humana sin dados, y añade a la instrucción del DM una «INTENCIÓN
PENDIENTE»: si era un ataque, conjuro o prueba, no narrar su resultado como
ocurrido. Inventario y preguntas quedan fuera del texto: el DM confirma
posesiones y responde. Es una indicación, no una garantía.

**Verificación/límites:** dos casos puros (sin dados, con dados, otro actor en
medio). No se ha observado aún una partida live que ejercite la nota.

## D233 — Home como crónica viva y logotipo pixel en toda la app

**Estado:** Aceptada. Verificada offline y en navegador (1440/375).
**Fecha:** 2026-10-04.

**Contexto:** la home mostraba un dragón pixel mal dibujado y el título en
blackletter pixelada (Jacquarda Bastarda 9), ajenos al resto del mundo visual
de 16 bits que el usuario valora. Debía ser espectacular y explicar al instante
qué es Dragonex. El usuario aprobó cambiar el logotipo en toda la app.

**Decisión:** la home es una partida en marcha: un fragmento real de 19451
(narración verbatim o recorte literal, tiradas con el payload registrado y
claves de arma/daño en castellano) se reproduce turno a turno en el pergamino
con las clases de la propia mesa y `RollFormat`. Los dados caen en una bandeja
de fieltro con el motor 2D de dic_ex (el mismo que usa la mesa) y una paleta
propia de hueso y rúbrica; una lectura grande muestra el último resultado. La
caja «Declara tu intención…» es la llamada a Crear cuenta. La reproducción la
dirige el servidor con temporizadores por generación (`HomeDemo` puro,
`GameLive.Index`), sin JS propio ni llamadas al modelo, y se puede pausar
(WCAG 2.2.2). El logotipo es un SVG pixel generado por
`scripts/gen_wordmark.py` (oro→brasa, contorno y extrusión fuera de los
huecos) en la cabecera y la home. El motor 3D se descartó: su suelo opaco y su
cámara fija dejaban los dados ilegibles en una bandeja pequeña.

**Verificación/límites:** 7 tests (guion y LiveView: avance, push de dados,
pausa con temporizador obsoleto, eventos de dic_ex aceptados, logotipo en otra
página). Revisión final independiente en dos rondas: seis arreglos resueltos;
la prosa en móvil se oculta durante ráfagas de tiradas, aceptado como parte
del extracto real. Las líneas de tirada de la mesa siguen mostrando claves en
inglés (shortbow, piercing): pendiente de localizar en el motor.

## D234 — Vista previa de la narración estructurada mientras se genera

**Estado:** Aceptada. Verificada offline y live (fireworks); depende del
proveedor y del exAgent publicado. **Fecha:** 2026-10-04.

**Contexto:** desde D222 la prosa pública viaja como argumento `text` de
`narrate`/`final_result`, y la mesa ya no mostraba nada hasta publicar. exAgent
solo reenviaba deltas de texto libre (privado). ReqLLM sí decodifica los
fragmentos de argumentos de las tools, pero el puente de exAgent los descartaba.

**Decisión:** exAgent (hermano, sin publicar) añade el campo opcional
`ModelRequestParameters.tool_call_deltas` y el evento
`{:tool_call_delta, %{index, name, fragment}}`; solo se pide cuando el llamante
pasa `deps.on_tool_call_delta`, así que otros consumidores no cambian. Dragonex
(`Narration.Preview`) acumula fragmentos por llamada, lee el valor de `text`
generado hasta el momento (JSON parcial, con o sin sobre `arguments`, escapes
cortados al final) y lo emite como `{:text_delta, …}` a la burbuja existente,
que ya sanea y se vacía al publicarse el evento validado. Nunca previsualiza la
resolución de una declaración humana (D221) ni otras tools. La vista previa no
es publicación: el contrato D222 y los checkpoints no cambian.

Medido en OpenRouter con `tool_choice: required` (el que envía el contrato):
trocean los argumentos fireworks, siliconflow, streamlake, atlas-cloud,
alibaba, inference-net, together y venice; Decart, Makora, DeepInfra, nextbit,
coreweave y parasail los entregan de golpe; DeepSeek oficial, novita, gmicloud
y parasail no admiten `required` para este modelo. Como el enrutado de DeepSeek
estaba fijado a Decart, `DRAGONEX_DEEPSEEK_PROVIDERS` (CSV estricto, sin
alternativas; por defecto `decart`) permite elegir otro sin tocar código.

**Verificación/límites:** exAgent: fragmentos reales por ReqLLM con y sin
opt-in y callback en run (62 focales). Dragonex: 3 casos del decodificador, 2 de
partida (vista previa del DM en orden y ninguna para voz humana, rojo sin la
guarda) y 1 de enrutado; se saltan en el grafo Hex. Live en 19451 con
fireworks: la burbuja crece y se sustituye por la narración publicada, sin
errores JS. Producción no lo tendrá hasta publicar exAgent y elegir un
proveedor que trocee; la calidad de fireworks como proveedor fijo no está
cualificada.

## D235 — Vocabulario del motor por idioma (capa 1 de la localización)

**Estado:** Aceptada. Verificada offline en ambos grafos. **Fecha:** 2026-10-04.

**Contexto:** el motor guarda claves estables en inglés (`longsword`,
`piercing`, `fire bolt`, `poisoned`) y las incrustaba tal cual en mensajes en
castellano: «ataque con shortbow», «6 de daño fire», «conjura firebolt»,
«elimina poisoned». Se ven en la crónica y el modelo las repite al narrar.
`Dragonex.I18n` y `Heroes.Translations` ya separaban claves y etiquetas por
idioma, pero solo se usaban en el creador y las fichas. El objetivo pedido es un
motor íntegro en castellano y otro íntegro en inglés.

**Decisión:** `Dragonex.Terms` traduce el vocabulario dentro de frases según la
locale: armas y ataques naturales en minúscula («arco corto», «mordisco»),
hechizos con su nombre propio (catálogo curado y, como respaldo, los 319 del
SRD importado: «Rayo ígneo», «Rociar veneno»), frase de daño concordada
(«daño perforante», «daño de fuego», «daño de fuerza» / «fire damage») y
condiciones («envenenado», «derribado»). Actions, tools y los módulos de
hechizos lo usan en motivos de tirada, feedback y mensajes. Los datos no se
traducen: World, argumentos de tools, `concentrating` y las listas que el
modelo usa como vocabulario de herramientas conservan las claves.
Los mensajes que enumeran valores válidos de un argumento también.

**Verificación/límites:** seis literales en inglés rompían la etiqueta
«(nivel N)» de los conjuros subidos de nivel al no coincidir el prefijo; los
tests de subida de nivel lo detectaron y se corrigieron. 4 casos de `Terms`;
expectativas de texto actualizadas sin cambiar dados, daño ni estado. Gates
2922/3 local y 2910+2 skipped Hex. Pendiente para el inglés íntegro: frases del
motor (capa 2), prompts de los agentes (capa 3) y heurísticas de `Text.scrub`,
que hoy son de gramática española (capa 4).

## D236 — Motor bilingüe: cada partida se juega íntegra en su idioma

**Estado:** Aceptada. Verificada offline en ambos grafos y en una partida live
en inglés. **Fecha:** 2026-10-04.

**Contexto:** D235 tradujo el vocabulario, pero las frases del motor, los
prompts de los agentes, el saneado de texto, la interfaz y parte del contenido
seguían escritos en castellano. Se pidió un motor íntegro en castellano y otro
íntegro en inglés, coherentes según el idioma de la partida.

**Decisión:**
- **Idioma por partida**: columna `games.locale` (`es` por defecto, `es|en`),
  elegida en el asistente (por defecto la de la interfaz). El proceso `Game` la
  fija al arrancar. Cada beat la captura (`table_locale`) antes de lanzar su
  tarea y viaja en `deps.locale`, que adoptan tools y capacidades porque corren
  en procesos de exAgent. `Dragonex.I18n` mantiene Gettext sincronizado y la
  locale es **por proceso**: dos mesas en idiomas distintos nunca se mezclan.
- **Frases en Gettext** (`Dragonex.Gettext`), dominios `engine` (feedback de
  reglas, errores, motivos de tirada, notas), `prompts` (DM, PC, TurnMaster,
  brief, guardrails, escenarios) y `ui` (LiveViews, asistente, avisos), más
  `errors` para Ecto. El msgid es el texto castellano previo, así que el
  castellano sigue igual byte a byte. Hay dos excepciones intencionadas: la
  concentración nombra el hechizo localizado («Bendición», no `bless`) y el
  presupuesto de turno dice «acción adicional» en vez de `bonus`. El inglés vive
  en `priv/gettext/en`, con 602/284/531 entradas y ninguna vacía ni dudosa.
- **Saneado y heurísticas por idioma**: `Text.Lexicon.Es/En` (scrub),
  guardrails (deriva de idioma en ambos sentidos, fin de combate), esperas
  (`WaitDeclaration`), testimonios (`NpcStatement` guarda «X states: “…”» y el
  parser acepta ambos formatos, así que las partidas guardadas siguen
  legibles) y PNJ de escenarios.
- **Contenido**: los escenarios se resuelven en el idioma de la partida. Los
  hechizos del SRD guardan `effect_en` (descripción original de open5e, que se
  rellena con `scripts/import_srd_spells.py --english`, sin LLM) junto al
  castellano, y los cuatro integrados que no son SRD llevan `effect_es`.
  `Catalog` elige según la locale. Los topónimos se fijan en un solo nombre
  inglés (Oakton, Black Forest).
- **Descripciones de tools en inglés neutro**: se fijan en compilación y valen
  para ambos idiomas. Las que pedían escribir algo en castellano ahora dicen «en
  el idioma de la partida».
- **Se quedan sin traducir**: claves de datos y argumentos de tools, mensajes
  de `Logger`, etiquetas internas del log del mundo y texto del usuario o del
  modelo.

**Verificación:** `i18n_catalog_test` (completitud y marcadores),
`game_english_table_test` (mesa inglesa e2e: prompt del DM en inglés y returns
de tools, tiradas y notas sin castellano), `engine_english_messages_test` y
tests de locale, términos, esperas, guardrails, escenarios, testimonios, scrub
y LiveView en inglés. Gates **3027 local** y **3015 + 2 skipped Hex**.
Partida live 19453 en inglés (Decart): creación, combate, fin de combate y
recogida del libro como «ledger», con 0 restos de castellano en eventos, chat y
log. Herramientas: `scripts/i18n_po.py` (exportar, fusionar y comprobar el
catálogo por trozos JSON) y `scripts/i18n_sweep.py` (busca literales en
castellano fuera de Gettext).

**Límites:** prod seguía en exAgent 1.2 (resuelto en D237). Las DBs
de test de otros agentes necesitan `ecto.migrate` para `games.locale`. Las
partidas ya creadas son `es`.

## D237 — Producción en exAgent 2.1 y dic_ex 0.3 de Hex

**Estado:** Aceptada. **Fecha:** 2026-10-12.

**Contexto:** desde D201 dev/test usaban los hermanos (exAgent 2.x, dic_ex
0.3) y prod seguía en Hex 1.2/0.2 porque v2 no estaba publicada. Eso dejaba en
prod sin narración en vivo (D234/R16), sin la causa conservada de D223 y con
dos tests del grafo Hex saltados. exAgent 2.1.0 y dic_ex 0.3.0 ya están en Hex.

**Decisión:** `mix.exs` pide `exagent ~> 2.1` y `dic_ex ~> 0.3` para el grafo
Hex; `mix.hex.lock` fija 2.1.0/0.3.0. Dev sigue resolviendo los hermanos (D201).

**Verificación:** grafo Hex 3027 passed / 3 excluded, sin skipped; local 3027 /
3 excluded; compile forzado `--warnings-as-errors` limpio en ambos.

**Límites:** no se ha desplegado. Los caminos de compatibilidad con 1.2 que
queden en el código pueden retirarse aparte. El proveedor por defecto para que
la narración en vivo trocee argumentos (D234) sigue sin decidir.

## D238 — Playtest sin interfaz medido, y routing de OpenRouter con claves atom

**Estado:** Aceptada. **Fecha:** 2026-10-12.

**Contexto:** las correcciones D100–D236 salían de playtests manuales en
navegador, caso a caso, sin una medida comparable entre partidas. Al
reanudar, la suite offline estaba verde, pero ninguna petición real llegaba
al proveedor: con `OPENROUTER_PROVIDER_ORDER` definido y un modelo distinto de
`deepseek-v4.1-flash`, `Models.routing_for/1` devolvía el fragmento del cuerpo
JSON (claves string) y ReqLLM ≥ 1.27 valida `openrouter_provider` como mapa de
claves atom («expected atom, got: "allow_fallbacks"»). Cada beat pausaba la
mesa antes de salir hacia OpenRouter.

**Decisión:**
- `Dragonex.Playtest.Metrics` (puro) mide sobre `game_events`: turnos por
  tipo de actor, fallos (`turn_failed`, pausas, omisiones, relevos de
  emergencia), ida y vuelta humana, duración de turnos IA y declaraciones de
  combate sin tirada propia. `mix dragonex.metrics` lo aplica a partidas
  guardadas (solo lectura).
- `Dragonex.Playtest` + `mix dragonex.playtest` juegan mesas reales sin
  interfaz: crean la partida como el asistente y un jugador bot (modelo
  barato, solo eventos públicos) escribe las declaraciones humanas por
  `Game.declare/3`. Reanuda pausas como haría el creador y devuelve métricas.
  Se niega a jugar sin proveedor real.
- La nota de fallo de turno lleva `kind: "turn_failed"`; las métricas aceptan
  también el texto de partidas anteriores.
- `routing_for/1` convierte el orden de `OPENROUTER_PROVIDER_ORDER` a
  `%{order:, allow_fallbacks:}`. Regresión que valida contra el esquema de
  ReqLLM.

**Verificación:** tests deterministas de métricas, jugador y arnés (con
`Test.Narrator`); partida live 19455 (DeepSeek v4 flash): aventura del molino
completa en 8 declaraciones, 0 fallos, ida y vuelta p50 12 s / p90 52 s.

**Límites:** el jugador bot no sustituye al navegador (UI, dados 3D, móvil).
Las métricas no juzgan la semántica de la prosa; «combate sin tirada» es un
indicador para revisar, no un error seguro.

## D239 — Recogidas y entregas declaradas exigen comprobante de inventario

**Estado:** Aceptada. **Fecha:** 2026-10-12.

**Contexto:** el prompt del DM ya obligaba a llamar `grant_item`/`remove_item`
(D190), pero en playtests el modelo narraba entregas sin tocar el stock. En
19457 el libro de cuentas quedó ×2 tras entregarlo: dos `grant_item`, ningún
`remove_item`. El cambio de inventario no deja evento propio, así que la prosa
y la ficha divergían sin que nada lo señalara.

**Decisión:**
- `Dragonex.InventoryDeclaration.kind/2` reconoce (es/en) si la declaración
  del jugador pide recoger, entregar o ambas. Es determinista y amplio a
  propósito, con exclusiones para gestos, armas y negaciones extraídas de
  falsos positivos reales.
- `Game.InventoryResolution` (capacidad, como `WaitResolution` y
  `NPCMemoryResolution`): en el beat DM de exploración que responde a esa
  declaración, añade una guía al contexto, bloquea la salida de texto y hace
  que `Narration.Contract` rechace `final_result` con
  `:inventory_unresolved` hasta que el checkpoint del turno tenga un recibo
  de `grant_item`, `remove_item` o `confirm_inventory_unchanged`. No escribe
  el World.
- Tool nueva `confirm_inventory_unchanged(who, reason)` (solo DM, sin efecto)
  para cuando el objeto no cambia de manos: el falso positivo cuesta una
  llamada, no un turno bloqueado.
- La revisión de escena «solo inventario» acepta también ese recibo.

**Verificación:** tests deterministas del detector (frases reales de
playtests, incluidos falsos positivos) y de partida: un cierre sin recibo no
se publica y el siguiente intento ve la guía y el feedback; `grant_item` y
`confirm_inventory_unchanged` desbloquean; una declaración sin objeto cierra
sin requisito.

**Límites:** el detector no entiende la frase; no decide qué objeto ni si el
cambio procede (eso sigue siendo del DM). Tampoco garantiza que el recibo
corresponda al objeto correcto ni evita un `grant_item` duplicado: la guía
lo prohíbe, pero el motor no lo comprueba.

## D240 — Sin doble concesión de objetos y `narrate` vacío sin coste

**Estado:** Aceptada. **Fecha:** 2026-10-12.

**Contexto:** D239 obliga a registrar el inventario, pero no evita registrarlo
dos veces. En 19457 el DM concedió el libro de cuentas al revelarlo en el
arcón y otra vez cuando Thane lo cogió: ×2. Aparte, en 19463 el proveedor
envió `narrate` con texto vacío hasta agotar los reintentos de la tool y el
turno entero falló, aunque la narración intermedia es opcional.

**Decisión:**
- `World.grant_item/4` rechaza conceder un objeto que el PC ya tiene (misma
  clave canónica) salvo `additional: true`, argumento opcional de
  `grant_item` para unidades nuevas de una pila (flechas, monedas). El
  rechazo cita el stock real y propone `confirm_inventory_unchanged`.
  `false`, `null` y omitido comparten clave de replay.
- `narrate` con texto en blanco no publica nada y responde `{:ok, …}`
  pidiendo seguir con las tools o cerrar con `final_result`. El resto de
  validaciones (longitud, UTF-8, requisitos pendientes, voz humana) sigue
  reintentando. `text` ausente o `null` lo rechaza antes el esquema de
  exAgent.

**Verificación:** tests de World (rechazo, `additional`, nueva concesión
tras entregar) y de partida (cinco `narrate` vacíos seguidos cierran el turno;
sin el cambio, reproduce el fallo de 19463).

**Límites:** el modelo puede marcar `additional: true` sin motivo; el motor
no sabe qué objetos son únicos. Un objeto concedido demasiado pronto (al
revelarlo) sigue siendo una sola unidad, no un error detectado.

## D241 — Las tiradas llevan los PG que dejaron

**Estado:** Aceptada. **Fecha:** 2026-10-12.

**Contexto:** la crónica mostraba «daño cortante a suso d6:4 +2 = 6» pero no
cómo quedaba suso: había que cruzar la línea con la ficha, que ya mostraba el
estado final de varias tiradas. Las ~27 aperturas de `RollLog` en `Actions` no
saben a quién acaba afectando el cambio (resistencias, PG temporales, áreas,
concentración).

**Decisión:** `RuleCheckpoint` compara el mundo antes y después de cada tool y
`RollLog.with_hp_changes/3` añade a la **última** tirada de esa tool
`hp: [[nombre, pg, pg_max]]` por cada criatura cuyos PG cambiaron. Se persiste
en el payload del evento `:dice` y viaja en `{:dice_group, …}`. La crónica lo
pinta bajo la tirada («suso queda a 4/10 PG») y la bandeja de dados también.

**Límites:** si una tool hace varias tiradas de daño al mismo objetivo, solo
la última muestra el resultado acumulado. Los cambios sin tirada (curación
fija, efectos automáticos) no muestran nota. Los eventos anteriores no la
tienen.

## D242 — La casa paga un solo modelo; el resto, con la clave del jugador

**Estado:** Aceptada. **Fecha:** 2026-10-12.

**Contexto:** el modal Ajustes cambiaba proveedor y modelo para **todas** las
mesas (`ModelConfig`, global y efímero) y siempre con la clave del servidor.
En producción eso deja que cualquier jugador elija un modelo caro a cuenta de
la casa, y un reinicio perdía la elección. El usuario quiere: con su clave,
solo DeepSeek v4.1 Flash en el proveedor más barato; quien quiera otro modelo
pone su propia clave (OpenRouter, OpenCode Go, OpenAI, Google, Anthropic) y lo
paga él. Sin topes por partida ni por usuario.

**Decisión:**

- **Modelo de la casa.** `Models.server_mode/0`: `:fixed` (por defecto,
  producción) u `:open` (dev/test por config; `DRAGONEX_SERVER_MODELS` lo
  fuerza). En `:fixed` toda mesa pagada por el servidor usa
  `deepseek/deepseek-v4.1-flash` en los tres roles (DM, resumen, TurnMaster).
  El routing de OpenRouter se calcula con `/models/…/endpoints`: solo
  endpoints con tools y activos, ordenados por coste ponderado según nuestro
  consumo real (77 % prompt cacheado, 19 % prompt, 4 % salida), con
  `allow_fallbacks` y `require_parameters`; se cachea 6 h y, si OpenRouter no
  responde, usa un orden conocido. D243 pone Decart primero. El sufijo
  `:floor` se descartó: ordena por precio de entrada y elegía el endpoint con
  la salida más cara.
- **Claves del jugador** en «Tu cuenta» (`/cuenta`, enlazada desde su nombre en
  la cabecera). Una por proveedor (`user_api_keys`). Antes de guardar se
  comprueban listando modelos (gratis; en OpenRouter, con `/key`). Se guardan
  cifradas con AES-256-GCM: clave derivada de `SECRET_KEY_BASE`, y usuario y
  proveedor como AAD, así una fila copiada a otro usuario no se abre. La UI
  solo muestra los 4 últimos caracteres; el texto plano nunca entra en los
  assigns ni en el HTML.
- **La elección es por partida** (`games.ai`, jsonb): `house`, `own`
  (proveedor + modelo + metadatos del catálogo) o `server` (solo en `:open`).
  `Game.restart/2` la guarda sin ningún `Game` vivo y la restaura si el
  arranque falla. `Bootstrap` reconstruye los modelos desde ahí, así que un
  crash o un reinicio de la app conserva quién paga. Si falta la clave, la
  mesa juega con la casa (aviso en el log). Se elimina `ModelConfig`.
- **Cómo se llega a cada proveedor.** exAgent 2.1 solo ejecuta tools sobre
  OpenAI Chat, así que cada proveedor se usa por su endpoint compatible:
  OpenRouter con su perfil (metadatos de catálogo y razonamiento apagado) y
  los demás con el perfil Chat genérico, sin pedir razonamiento. Al aplicar un
  modelo propio se hace una petición mínima real (`AIProviders.probe/1`); si
  el modelo expone razonamiento o rechaza las tools, falla en el modal y no en
  el primer turno.

**Verificación:** tests de cifrado (ida y vuelta, AAD, IV aleatorio), CRUD de
claves, listados por proveedor con HTTP simulado (`config :dragonex,
:ai_http`), ranking de endpoints, modelos de la casa en `:fixed`, `GameAI`
(selección, ida y vuelta jsonb, vuelta a la casa), arranque desde `games.ai`,
el modal (casa, clave propia con sonda, sonda fallida, clave borrada, perfil
incompatible, producción sin fuentes del servidor) y la página de cuenta.

**Límites:** rotar `SECRET_KEY_BASE` deja las claves guardadas ilegibles: las
mesas vuelven a la casa y cada jugador debe pegar su clave otra vez. El filtro
de modelos de OpenAI y Google es por nombre; uno nuevo con otro prefijo no
aparece en la lista, pero se puede escribir su slug. El coste ponderado
supone nuestra mezcla de tokens actual. En los proveedores compatibles no se
aplica caché explícita de prompt.

## D243 — La casa sirve DeepSeek por Decart

**Estado:** Aceptada. **Fecha:** 2026-10-13. Ajusta el routing de D242.

**Contexto:** con el routing de D242 (el más barato para nuestra mezcla de
tokens primero), la sesión larga 19465 salió estable (40 declaraciones, 0
fallos) pero lenta: turno DM p50 21 s frente a 7 s con Decart (tanda D239), e
ida y vuelta humana p50 32 s frente a 10 s. Encabezaba sail-research, nunca
medido. Una petición corta idéntica tardó 12,7 s en sail-research y 8,8 s en
Decart. El coste ponderado es 0,0337 $/M frente a 0,0382 $/M: Decart cuesta
un 13 % más, menos de un céntimo por sesión de 40 turnos.

**Decisión:** el modelo de la casa va primero por `decart`. Detrás, como
respaldo (`allow_fallbacks`), el resto de endpoints con tools ordenados por
coste. Sin respuesta de OpenRouter: decart, morph, relace, deepseek. El
usuario eligió Decart frente a morph, que fue más rápido en una sola muestra
pero nunca se ha medido en partida.

**Límites:** si Decart cae, el respaldo vuelve a ser el más barato y puede
ser lento. Cambiar de proveedor exige desplegar (constante en `Models`).

## D244 — Un grupo caído sigue en combate; bestiario con CR

**Estado:** Aceptada. **Fecha:** 2026-10-13.

**Contexto:** en la partida 19466 (playtest D243) el escenario pedía dos ratas
gigantes, que no existían en el bestiario. El DM usó la araña gigante (CR 1,
26 PG, veneno) y el grupo de nivel 1 murió. Con todos los PJ a 0 PG,
`World.combat_over?/1` cerraba el combate aunque las arañas siguieran en pie.
El DM lo reabría en cada beat (60 turnos de DM para 10 declaraciones) y acabó
intentando mover dos arañas en el mismo turno hasta agotar los reintentos.
Otro beat falló porque el DM sacaba de escena a una araña que ya había salido.

**Decisión:**
- `combat_over?/1` cuenta como «en el combate» a quien tiene PG > 0 y a un PJ
  moribundo (0 PG, ni muerto ni estable). El combate sigue mientras el grupo
  pelea por su vida (salvaciones de muerte, enemigos que pueden rematar). El
  aviso al DM de «no hay enemigos en pie» solo aparece si es verdad.
- Bestiario: `giant_rat` (SRD, CR 1/8) y CR de cada tipo (`Monsters.cr/1`).
  Pedir un tipo desconocido devuelve el catálogo de menor a mayor desafío y
  pide el de CR más parecido, nunca uno más fuerte. Se corrige el CR de
  kobold y bandido en la documentación (1/8).
- `leave_scene` y `return_to_scene` responden `{:ok, …}` cuando la escena ya
  es la pedida, sin tocar el mundo.
- El TurnMaster, al ver rechazada su elección, recibe la lista de quién puede
  recibir el turno.

**Verificación:** tests de `combat_over?` (grupo moribundo, estable, muerto,
enemigo caído), bestiario (rata SRD, CR completo y ordenado, mensaje de tipo
desconocido), herramientas de escena idempotentes y pista del TurnMaster.

**Límites:** no hay final de partida si muere todo el grupo; la partida
sigue en exploración. Un PJ a 0 PG en exploración puede declarar acciones y
el DM puede narrarlas. El DM aún puede insistir en mover a otro combatiente
fuera de turno; el arreglo del combate quita la causa vista, no el patrón.

## D245 — Entrar con Google y contraseña repetida al registrarse

**Estado:** Aceptada. **Fecha:** 2026-10-13.

**Contexto:** con prod abierto a betas con humanos, la página de acceso seguía
con el «Dragonex» en blackletter que DESIGN.md prohíbe como logotipo, el
registro aceptaba una contraseña tecleada una sola vez y no había forma de
entrar sin crear otra contraseña. Un nombre de aventurero vacío además
reventaba en la base de datos en vez de avisar.

**Decisión:**
- Entrar y Crear cuenta comparten una ventana con pestañas, el wordmark SVG
  encima y dos antorchas; cada error del registro se marca en su campo y el
  formulario conserva nombre y correo.
- El registro exige `password_confirmation` (el formulario siempre la envía;
  si falta, no coincide). El nombre es obligatorio (máx. 60).
- Google por OpenID Connect con código + PKCE, `state` y `nonce` en sesión,
  sin dependencia nueva (Req). El ID token llega directo del endpoint de
  tokens por TLS, así que basta comprobar `aud`, `iss`, `exp` y `nonce`
  (OIDC Core §3.1.3.7), sin JWKS.
- La cuenta se busca por `google_sub`; si no, un correo verificado por Google
  enlaza la cuenta existente con ese correo; si no, se abre una cuenta sin
  contraseña (`password_hash` pasa a admitir NULL y `authenticate/2` la
  rechaza). Un correo no verificado no enlaza ni crea nada.
- Sin `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET` el botón no aparece. La URI
  de retorno es `Endpoint.url() <> "/auth/google/callback"`.

**Verificación:** `test/dragonex_web/auth_test.exs` (pestañas y wordmark,
botón según configuración, confirmación distinta o ausente, nombre vacío,
URL de Google con PKCE, cuenta nueva, segunda visita, enlace por correo,
correo no verificado, `state`/`aud`/`nonce`/`exp` manipulados).

**Límites:** una cuenta abierta con Google no tiene contraseña ni forma de
crearla, y no hay recuperación de contraseña para nadie.

## Pendientes de decisión (abiertas)

- **Coordinación real entre PCs auto**: cubierta por **TurnMaster (D25,
  Implementada)**. Validar en partida live que el ritmo y la equidad se
  sostienen; ajustar prompt/brief para exploración e interrupciones. D113
  conserva la iniciativa determinista para turnos principales de combate.
