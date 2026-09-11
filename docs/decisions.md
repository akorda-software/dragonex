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
(`actions.ex:231`).

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

---

## Pendientes de decisión (abiertas)

- **Coordinación real entre PCs auto**: cubierta por **TurnMaster (D25,
  Implementada)**. Validar en partida live que el ritmo y la equidad se
  sostienen; si no, ajustar prompt/brief del TurnMaster (no volver al
  round-robin como camino principal).
