# Dragonex — Flujo de una partida

> Documento vivo que explica, en lenguaje natural, **cómo funciona una partida de
> Dragonex de punta a punta**, reflejando el código real (con referencias
> `archivo:línea`). Es la fuente de verdad narrativa sobre la que iteramos:
> cuando cambiemos algo, actualizamos este doc. Cuando encontremos un bug, lo
> apuntamos en la última sección.

---

## 1. Qué es Dragonex

Un **Dungeon Master por IA** para D&D 5e. El jugador crea una partida, elige un
escenario (o la arena de pruebas), y uno o varios personajes (controlados por
humano o por IA) viven una aventura narrada y arbitrada por el modelo LLM.

- **Stack**: Elixir + Phoenix LiveView. Motor de agentes: `ExAgent` (framework
  propio en `../exAgent`).
- **Modelo DM**: `deepseek/deepseek-v4-flash` vía OpenRouter (configurable por
  env). Sumarizador de compacción: `google/gemini-3.1-flash-lite`.
- **Persistencia**: Postgres. Una fila `games` por partida + un log append-only
  `game_events` + el `world` serializado como jsonb.

El modelo **solo narra**. Cada tirada, ataque, daño, salvación y muerte se
resuelve por herramientas (`make_attack`, `roll_initiative`, …). El LLM lee el
resultado factual y lo teje en prosa. Esto evita que el modelo mienta con
números.

---

## 2. Arquitectura por capas

```
┌─────────────────────────────────────────────────────────────┐
│ UI  DragonexWeb.GameLive.Show  (LiveView: vista + input)    │
├─────────────────────────────────────────────────────────────┤
│ App Dragonex.Game (GenServer, uno por partida)              │
│   - bucle por turno, lanza beats en Tasks                   │
│   - persiste world + status + events tras cada beat         │
│   - maneja pausa, auto-play, reintentos                     │
├─────────────────────────────────────────────────────────────┤
│ Motor ExAgent.Session + TurnMaster (decide) + WorldDriven   │
│   - TurnMaster reparte turnos (D25); WorldDriven = fallback │
│   - control guard: solo el actor en turno resuelve          │
├─────────────────────────────────────────────────────────────┤
│ Reglas  Dragonex.{Rules, World, Actions, Tools}             │
│   - matemática de combate (AC, daño, saves, iniciativa)     │
│   - change functions que mutan el World                     │
├─────────────────────────────────────────────────────────────┤
│ Agentes  Dragonex.{DM, PCAgent, TurnMaster, Events}         │
│   - system prompt + tools + capabilities                    │
│   - ExAgent.Server ejecuta el beat contra el modelo         │
├─────────────────────────────────────────────────────────────┤
│ Datos  Postgres: games / characters / participants /        │
│        game_events (log) + world jsonb (vía Codec)          │
└─────────────────────────────────────────────────────────────┘
```

**Principio rector**: el `Game` es la **única fuente de durabilidad**. Tras cada
beat persiste el `world` vivo, la posición de turno y un evento append-only. El
`Session` (motor) corre en memoria; si el proceso `Game` muere, uno nuevo
rehidrata el mismo `game_id` desde Postgres y continúa exactamente donde dejó.

---

## 3. Datos persistentes

- **`games`**: título, story_bible (jsonb), dm_style, world (jsonb via `Codec`),
  status (`:running | :waiting | :paused | :ended`), round,
  current_participant, intents (pendientes del humano), open_slots.
- **`participants`**: nombre, kind (`:ai | :human`), side (`pc | enemy`).
- **`characters`**: hoja del personaje (sheet jsonb) por partida.
- **`game_events`**: log **append-only**, monotónico por `seq`. Es la línea
  temporal reproducible de la partida. Tipos (`game_event.ex:22`):
  `:narration | :action | :tool | :dice | :system | :turn`.

El `world` jsonb se (de)serializa con `Dragonex.Codec`. Al rehidratar, se
reconstruye como `Dragonex.World` struct y se pasa como `shared_state` al
`Session`.

---

## 4. El `Game` GenServer: estado y lifecycle

Definido en `lib/dragonex/game.ex`. Un proceso por partida, arrancado vía
`Dragonex.Game.Supervisor` (registry por `game_id`).

**Struct**: `game_id`, `game`, `session`, `dm`, `turnmaster` (D25),
`pc_agents`, `model`, `roller`, `participants`, `intents`, `status`, `busy`,
`loop_phase` (`:actor | :turnmaster`), `last_actor`, `acted` flags de mini-turno.

### Rehidratación (`init` → `rehydrate`)
1. Carga el `games` row desde Postgres.
2. Decodifica el `world`, crea los `Participant` del `Session`.
3. Arranca el `Session` con policy `{WorldDriven, dm: "dm"}` (fallback).
4. Restaura la posición de turno (`restore_turn` / `Session.handoff`).
5. Crea el **agent DM** (`DM.new/2`) con la story bible horneada.
6. Crea el **agent TurnMaster** (`TurnMaster.new/2`, modelo barato).
7. Crea un **agent PCAgent** por cada participant `:ai` que no sea el DM.
8. `loop_phase`: `:turnmaster` si partida nueva; `:actor` si reanuda.
9. `send(self(), :advance)` → arranca el bucle.

### Status
- `:running` — el bucle avanza solo (turnos IA).
- `:waiting` — esperando que un humano declare (`act/2`).
- `:paused` — pausa; los beats IA no se auto-lanzan.
- `:ended` — fin.

---

## 5. El bucle por turno — `advance/1` (el corazón)

Micro-máquina **actor → turnmaster → handoff** (D25). Un tick = un paso.
**Nunca encadena más de un beat por tick**.

```
handle_info(:advance) → advance(state)
  ¿status != :running?  → no-op
  ¿busy != nil?         → no-op (hay un beat en vuelo)

  si loop_phase == :turnmaster:
    → beat TurnMaster (decide quién sigue)
    → al cerrar: Session.handoff / end_scene  (o fallback WorldDriven)
    → loop_phase := :actor, tick

  si loop_phase == :actor:
    según Session.current:
      nil                  → fin, persist :ended
      ai_pc?(current)      → lanza beat del PCAgent
      human?(current)      → :waiting (o consume intent pendiente)
      _ (DM)               → lanza beat del DM
    → al cerrar OK: NO end_turn; mark_acted; loop_phase := :turnmaster, tick
```

Detalle normativo: [`tecnico/01-bucle-del-agente.md`](tecnico/01-bucle-del-agente.md).
Spec de diseño: [`TURNMASTER.md`](TURNMASTER.md).

### Tipos de turno (fase `:actor`)

**IA PC**: agent propio + `PCAgent.instruction/3` + anti-loop, `run_beat`.

**Humano**: intent pendiente → beat; si no, `persist(:waiting)` hasta `declare/3`.
Un `declare` off-turn de **otro** humano despierta al TurnMaster (D27) para
que pueda priorizar esa iniciativa; si el TM no decide, el waiter no pierde
el floor. La UI permite encolar aunque haya un beat en vuelo. Un intent de
combate caduca al volver a exploración (D28). En combate, una reacción
clara (`interrumpo`, `escudo`…) fuerza `cut_in` aunque el TM hubiera
cedido a otro.

**DM**: instruction según limbo post-combate / exploración + guardrails, `run_beat`.

**TurnMaster** (fase `:turnmaster`): una sola tool-call de orquestación
(`give_turn_to`, `cut_in`, `react`, `pass_to_dm`, `end_scene`). No narra.
El brief lista **intenciones humanas pendientes**. Si falla o no decide →
`WorldDriven` (`Session.end_turn`) + nota de sistema, **excepto** en una
re-eval D27 (se queda el waiter).

---

## 6. Construcción y ejecución de un beat — `run_beat`

El GenServer se queda responsive: el beat corre en un
`Task.Supervisor.async_nolink`. El resultado llega por `handle_info({ref, result})`.

**Beat de actor**:
1. Elige el agent (`agent_for`: PCAgent si existe, sino DM).
2. `Brief.turn_prompt` + history compartido (`History.from_events`, §7).
3. Callbacks `on_roll_closed` / `on_text_delta`.
4. `Server.chat` con deps (SharedState, RollLog, beat ctx).
5. `busy = %Beat{kind: :actor, mini_turn: …}`.

**Beat TurnMaster** (`run_turnmaster_beat`):
1. `Brief.turnmaster_brief/4` (world + last_actor + roster + `state.intents`)
   + `TurnMaster.instruction` (`pending_intents`).
2. Recorder `Decision` por beat.
3. `Server.chat(turnmaster, …)` sin streaming.
4. `busy = %Beat{kind: :turnmaster}`.

**Resultado actor OK**: no `end_turn`; `maybe_force_combat` / `maybe_end_combat` /
`mark_acted` / `maybe_advance_round` (por `acted_this_round`); pasa a TurnMaster.

**Resultado TurnMaster OK**: aplica handoff; evento `:system` `actor: "turnmaster"`;
pasa a actor.

**Error**: retries transient / max_tokens (§15.1); soft fallback del actor sigue
avanzando con `end_turn`.

---

## 7. Contexto compartido — `History.from_events`

`lib/dragonex/history.ex`. **Es lo que da coherencia cross-agente**: cada beat
reconstruye TODA la línea temporal desde `game_events` como `[Message.t()]` y lo
pasa como `:message_history` (override del `state.history` del `Server`). Así el
DM lee lo que narró Vex, y Lyra ve el resultado del ataque de Thane.

### Formato de cada evento (`history.ex:121`)
- `:turn` (start) → **no genera mensaje**; se pliega como header
  `[R3 · combate · Turno de Vex]` en la siguiente narración.
- `:narration` → mensaje `assistant` con etiqueta `[actor]:`.
- `:action` (declaración del humano) → mensaje `user` con `[actor declara]:`.
- `:dice` → mensaje `user` inline: `[🎲 Vex] ataque ... d20:14 = 14 vs CA 10 → éxito`.
- `:system` → mensaje `user` con `[sistema]:`.

### Atribución y compresión
- Las **12 narraciones más recientes** van verbatim (`@recent_narrations_kept 12`,
  `history.ex:54`). Las anteriores se truncan a la primera frase (~180 chars).
- `coalesce_assistant_runs` (`history.ex:224`) colapsa mensajes `Response`
  consecutivos **solo si son del mismo actor** (parsea la etiqueta `[actor]:`
  vía `narration_actor/1`). Runs del mismo actor (DM mid-beat + DM final) se
  funden para ahorrar tokens; runs de actores distintos quedan como turnos
  `assistant` separados con su propia etiqueta, preservando la atribución.

### ✅ Fixes aplicados en la reconstrucción (causas del "bucle temporal")
Tres bugs en `history.ex` degradaban el contexto que recibía el modelo y eran
la raíz de la incoherencia de la partida de prueba. Ya resueltos:

1. **`coalesce_assistant_runs` mezclaba actores**: colapsaba **cualquier** par
   de `Response` consecutivas sin comprobar el actor, fundiendo narraciones de
   turnos adyacentes (DM, Thane, Vex, Lyra) en un único blob `assistant`. El
   modelo perdía quién dijo qué → re-narraba y re-asignaba acciones. Ahora
   solo colapsa mismo actor.
2. **`split_responses` tenía los grupos invertidos** (el más grave): el
   predicado `responses_after <= keep` seleccionaba los "recent" pero el código
   los llamaba `old_pairs`. Resultado: las narraciones **RECIENTES se
   truncaban** y las **VIEJAS iban verbatim al FINAL** del history (orden
   temporal corrompido). Ahora el predicado es `>= keep`, que marca los "old"
   correctamente. Sin este fix, el modelo veía el pasado reciente recortado y
   el pasado lejano desordenado al final — justo lo que provocaba que el
   demonio pareciera "nuevo".
3. **Compresión demasiado corta** (`@recent_narrations_kept = 5`): con 4 agentes
   auto (~6-8 narraciones por ronda) solo la última ronda y media iba entera.
   Subido a **12** (~2 rondas completas), margen suficiente para la continuidad.

---

## 8. Los agentes

### DM — `lib/dragonex/dm.ex`
Un único agent que narra el mundo, da voz a monstruos/PNJ, arbitra y controla
el ritmo. **System prompt de 16 reglas** (`dm.ex:149`), con la story bible
horneada al final (prefijo cacheable). Críticas:
- **#3** quién actúa (turno de jugador vs turno del DM; las herramientas de
  escena como `roll_initiative`/`spawn_monster` están exentas).
- **#5** empezar combate es urgente: llamar `roll_initiative` al instante al
  estallar pelea o al spawnear un hostil (con nota de que el motor lo fuerza
  como red de seguridad, ver §15.2).
- **#11** avance de escena: tras 2 turnos sin progreso, provocar un evento.
- **#14** SOLO narras tu turno y tus monstruos/PNJ; **nunca** narras a un PC
  haciendo algo.
- **#15** no revelar stats (HP/CA) a los jugadores.
- **#16** formato de output: prosa pura, sin etiquetas `[Actor]:`, tablas, ni
  tokens internos.

### PCAgent — `lib/dragonex/pc_agent.ex`
Un agent por personaje IA, con personalidad derivada de su clase
(`pc_agent.ex:277`). Tools restringidas (atacar, conjurar, checks, descansos):
NO puede spawnear, tirar iniciativa, terminar combate ni subir nivel. Reglas
clave:
- **#3** solo objetivos válidos listados en la instrucción.
- **#4** exploración sin enemigos → actúa en personaje sin tool.
- **#5** proactividad + **ANTIBUCLE** (no repetir intención; tomar acción).
- **#10/#11** formato y no stats.

### Instruction por turno
- `PCAgent.instruction/3` (`pc_agent.ex:182`): adapta al estado. Caído → solo
  `make_death_save`. Combate con enemigos → lista objetivos válidos + armas.
  Exploración → actúa en personaje, sin forzar tool.
- `Brief.turn_prompt/5` (`brief.ex`): `world_brief` + instruction.

---

## 9. El `world_brief` — lo que el agente "ve"

`dm.ex:204`. Snapshot compacto del mundo que se inyecta en cada turno:
- línea de fase (`Combate -- ronda 2 (iniciativa: goblin → Thane)` o `Exploración`),
- de quién es el turno (y si es DM, qué monstruos controla),
- línea de control (quién es IA auto vs quién espera input humano),
- **hechos establecidos** (`world.facts`, §15.8): verdad canónica persistente
  que todos los agentes leen cada turno (evita que el DM abandone o reintroduzca
  ganchos),
- escena,
- una línea por personaje: `nombre (clase, lado): hp/max_hp pg, CA ac armas…`.

> **Nota**: el brief muestra HP/CA al modelo (los necesita para decidir), pero la
> regla #15 le prohíbe verbalizarlos al jugador. La sanitización (`Text.scrub`,
> §14) limpia lo que se escapa.

---

## 10. Herramientas y resolución por reglas

`lib/dragonex/tools.ex`. Cada `deftool` propone un cambio vía `SharedState` tras
pasar el guard de control (`assert_controls`). Las herramientas de resolución
(`make_attack`, `cast_spell`, `ability_check`, `make_death_save`, `heal`,
`roll_initiative`) tienen `max_retries: 3` (`dm.ex:27`, `pc_agent.ex:34`): si el
modelo propone como actor equivocado, el guard devuelve un error directivo y hay
margen para autocorregirse.

La matemática vive en `Dragonex.Rules.Combat` y `Dragonex.Actions`. Las
herramientas son puentes: nunca calculan números, solo proponen el change.

---

## 11. Combate end-to-end

1. **Inicio**: el DM llama `roll_initiative` (o el motor lo fuerza, §15.2).
   `Actions.initiative` rolla d20+mod para cada combatiente consciente, ordena
   descendente y devuelve un `World.begin_combat(order)` change. La fase pasa a
   `:combat`.
2. **Turnos**: un beat por combatiente (D34). `WorldDriven` cicla
   `initiative_order` mapeando enemigos al DM **sin** colapsar slots
   consecutivos. `World.current_combatant` nombra el slot; `can_act?`
   admite al controlador (`"dm"` o el PC).
3. **Resolución**: `make_attack`/`cast_spell` resuelven por reglas, persisten
   `:dice` (modal en vivo) y aplican daño.
4. **Fin automático** (`maybe_end_combat`, `game.ex:1159`): cuando
   `World.combat_over?` (≤1 lado con conscientes), el motor cambia a
   `:exploration` y emite `[sistema]: ⚔ El combate termina.`. No depende de que
   el DM lo recuerde.
5. **Avance de ronda** (`maybe_advance_round`, `game.ex:1179`): cuando el último
   del ciclo actúa, `world.round` sube.

---

## 12. Auto-play

Un humano puede togglear auto-play (`enable_auto_play/disable_auto_play`,
`game.ex:133`). Al activarlo se crea un `PCAgent` para ese personaje y, si está
en su turno `:waiting`, se flipea a `:running` para que el bot juegue ya. El
toggle se refleja en el snapshot (`auto_humans`) y sobrevive a recargas.

---

## 13. Eventos en vivo y streaming

- **Tiradas en vivo** (`RollLog.start` con `on_close`): cada grupo de dados se
  persiste y broadcastea **al instante** (no al final del beat). El modal abre
  una vez por tirada con todo el contexto.
- **Narración en vivo** (`Events` capability, `events.ex`): `after_model_request`
  publica el texto del modelo (mid-beat + cierre) como `:narration`, con
  `Text.scrub(text, actor)` aplicado, apenas el modelo lo produce. El `actor` se
  pasa para que el scrub pueda quitar la auto-referencia inicial (ver §14).
- **Streaming token-a-token**: `ExAgent.drive_stream` consume el stream del
  provider; cada `:text_delta` se broadcastea. La LiveView muestra una burbuja
  con cursor ▍ que se flushea al persistir la narración final. Desactivado para
  el modelo `Test` (su `request_stream` no propaga el índice mutado).
- **Anti-duplicación de segmentos** (`maybe_flush_live_text/3` +
  `segment_already_carded?` en `show.ex`): en un beat `texto → tool → texto`, el
  segundo segmento de narración se persiste como un `:narration` nuevo (vía
  `Events`) ANTES de que el streaming del segundo segmento empiece. Cuando llega
  el `:game_updated`, la burbuja se limpia si su `live_text` coincide con la
  última narración persistida del actor, así el segundo segmento streamea limpio
  en su propia caja en vez de appendarse al primero (que ya está cardado).
- **Render sin auto-referencia duplicada** (`leading_self?/2` en `show.ex`): la
  burbuja de streaming usa texto **sin scrub**, así que si el chunk crudo empieza
  con el nombre del actor, la vista omite el span `who` para no pintar
  "LyraLyra…". (El scrub definitivo llega al persistir.)

---

## 14. Sanitización — `Text.scrub`  (`lib/dragonex/text.ex`)

Cuello de botella central y determinístico: se aplica ANTES de persistir
cualquier narración (`events.ex:65`) y al reconstruir el history compartido. Una
sola regla cubre todos los puntos de consumo (cajas, history, summarización) sin
depender de que el modelo obedezca el prompt.

Dos aridades:
- `scrub(text)` → equivalente a `scrub(text, nil)` (sin actor).
- `scrub(text, actor)` → además quita la auto-referencia inicial del actor (ver
  paso 3).

Pasos, en orden:
1. etiquetas iniciales `[Actor]:` / `[Actor declara]:` (hasta 4 anidadas),
2. headers de turno iniciales (`R2 · combate · Turno de …`) **y** tags
   mid-prosa `[R2 · Turno de X]` / `[→ Name decide]` (D7/D30),
3. **auto-referencia inicial** (`strip_leading_self_name`, solo con `scrub/2`):
   quita el nombre DEL actor al inicio ("Lyra levanta…" → "levanta…"), con
   separador tras él **o pegado a una minúscula** ("Thanedeja…" → "deja…", el
   leak típico de DeepSeek). Así el DM narrando "Lyra cae herida" (actor "dm")
   queda intacto. Resuelve el "LyraLyra" en cajas e history de una sola vez.
4. tokens internos de DeepSeek `<｜DSML｜…>`,
5. bloques de recap de combate (`**Estado del Combate:**` + listas con stats),
6. HP/CA inline: `6/13 pg` (X/Y), `CA 15`, `7 PG` bare, `X de los Y puntos de
   vida`, `clase de armadura N` (conservador con números lore),
7. **líneas con sintaxis de dados del motor** (`d20: +5 vs`) que el modelo
   imita del history — un leak de tool-call narrada se elimina entero,
8. **tool-calls escritas en prosa** (`establish_fact("…")`, `spawn_monster(…)`,
   `[Establecer hecho: …]`) — el modelo las escribe en vez de emitirlas como
   tool real; se eliminan,
9. **frases meta / ruptura de cuarta pared** ("el sistema resuelve…", "la escena
   se resetea", "lo materializo en el mundo para que sea oficial", "como DM…"),
10. frases meta del motor ("el sistema resuelve…"),
11. tablas markdown y battlemaps ASCII.

**Idempotente**: limpiar texto ya limpio es no-op. Es la red que atrapa lo que
el modelo filtra cuando desobedece las reglas #15/#16.

---

## 15. Robustez del bucle

### 15.1 Reintentos y fallback (`game.ex:664`, `handle_beat_result`)
Dos presupuestos de retry **independientes** por beat:
- **max_tokens**: si el modelo se corta a mitad, reintenta UNA vez con un
  preamble "SÉ BREVE" (`brief_retry_instruction`).
- **transitorio** (`schedule_transient_retry`, `game.ex`): ante errores del
  proveedor `{:model_request_failed, %ExAgent.RequestError{…}}` con `:timeout`,
  `:request_failed`, HTTP 5xx/429, o `:provider_error` con body de overload/rate,
  reintenta con **backoff exponencial** (1s → 3s → 10s, máx. 3) vía
  `Process.send_after({:retry_beat, turn_id})`. Mientras duerme, `busy` queda
  como `pending_retry` (sin Task ref) para que `advance` no lance beats
  competidores. Tras 3 intentos cae al fallback suave (`"X titubea y el turno
  pasa de largo"`). Backoff overrideable por `{:dragonex, :transient_backoffs}`.
- **Crash del Task** → `:DOWN` → fallback.

### 15.2 Combate fantasma — `maybe_force_combat` (`game.ex`, §bug #2)
Si un beat **introduce** un enemigo vivo (`side == "enemy"`, hp > 0) mientras la
fase es `:exploration`, el motor tira iniciativa él mismo y hace `begin_combat`.
Compara `enemies_before`/`after` (guardados en `busy`) para **no** disparar en
el beat de setup (monstruos preexistentes no cuentan). Emite
`[sistema]: ⚔ Aparecen hostiles — el motor toma la iniciativa automáticamente.`.

### 15.3 Anti-loop de PCs — `with_pc_anti_loop` (§bug #3)
Compara las últimas 2 narraciones del bot (similitud de **Jaccard** > 0.75 sobre
palabras normalizadas, sin stopwords). En casi-duplicado, inyecta un nudge强硬
que fuerza una acción DISTINTA y concreta.

### 15.4 Anti-puppet del DM — recorte + `with_dm_no_puppet_nudge` (§bug #4, D29)
Si una cláusula del DM **empieza** por `<PC> <verbo de acción>`, `Text.scrub`
(con `pc_names`) la tira antes de persistir. Estados pasivos (`Lyra está
herida`) y menciones que no son sujeto se conservan. El detector suelto
sigue cosiendo un recordatorio de regla 14 al siguiente beat si queda una
fuga mid-cláusula.

### 15.5 Limbo de exploración — `exploration_limbo?` (§bug #5)
Detecta un backlog de ≥6 eventos de **narración pura** sin progreso mecánico (sin
`:dice`, `:action`, ni `:system` de spawn/scene) en `:exploration`. Dispara
`dm_advance_instruction` (spawn / PNJ / set_scene / evento / resolver lo pedido).
Es la generalización de `post_combat_limbo?` a la exploración.

### 15.6 Anti-repetición del DM — `with_dm_anti_repeat`
Cuando el DM reutiliza casi la misma línea ("se desvanece en una nube de humo
sulfúrico" x N) lee como un disco rayado. Compara las últimas 2 narraciones del
DM (Jaccard ≥ 0.7) y, en casi-duplicado, cose un nudge que le exige un enfoque y
vocabulario NUEVOS (detalle sensorial, ángulo, ritmo). Espejo del anti-loop de
PCs, pero para variedad narrativa.

### 15.7 Combate fantasma v2 — `with_dm_unspawned_hostile_nudge`
Si el DM narra `"(aparece|se materializa|irrumpe|surge) un hostil"` en exploración
**sin** enemigos vivos en el world (no llamó `spawn_monster`), el motor no puede
forzar combate (`maybe_force_combat` no ve enemigo). El nudge le exige
`spawn_monster` este turno — que luego dispara el `maybe_force_combat` de §15.2.
Si no quiere combate, que no narre apariciones hostiles.

### 15.8 Hechos durables — `world.facts` + `establish_fact`
El DM aterrizaba ganchos solo en narración (truncable en el history), y a los
pocos turnos los abandonaba o reintroducía. Ahora el world lleva `facts: [String]`
persistente (codec round-trip), expuesto en el `world_brief` como
**"Hechos establecidos"**. El DM los registra con la tool `establish_fact("<frase>")`
(regla #11 del prompt) cuando introduce algo concreto y duradero (PNJ, puerta
secreta, encargo, revelación). Idempotente. Todos los agentes leen los hechos
cada turno → coherencia canónica.

### 15.9 Circuit breaker — `fallback_streak` + pausa automática
Si una racha de beats cae al fallback blando (provider caído, rate-limit
persistente, escena atascada que todo agente falla), el loop **PAUSA** la
partida en vez de seguir avanzando turnos. Sin esto, una salida de OpenRouter
producía un flujo infinito de *"X titubea y el turno pasa de largo"* que
inundaba la línea temporal y saturaba el server (síntoma: 503 al paginar).
`fallback_streak` se incrementa en cada fallback y se resetea con cualquier
beat exitoso; al llegar a `@max_fallback_streak` (4 = 1 ronda de 4
participantes) se persiste `:paused`, se emite una nota `:system` explicativa,
y no se manda `tick`. El usuario reanuda manualmente cuando la causa subyacente
se ha despejado.

### 15.10 Coherencia curación/mundo — regla #10 del DM
El DM narraba *"os han cosido a los tres"* sin llamar `heal` → los world
characters seguían a 0 HP y el motor les seguía pidiendo salvaciones de muerte
en una escena narrativamente ya resuelta. La regla #10 ahora obliga a llamar
`heal("nombre", "XdY+mod")` cada vez que algo restaura pg (PNJ cura, poción,
descanso, vendas); narrarlo sin `heal` deja al personaje atascado y rompe la
coherencia. Refuerzo de prompt (no fuerza estructural, pero alinea mundo y
narración en la causa más común de atasco post-combate).

### 15.11 Guardián de idioma — `with_dm_spanish_nudge`
DeepSeek-v4-flash a veces se va al **inglés** durante un párrafo pese al
"responde en castellano" del system prompt. `looks_english?/1` cuenta stopwords
inequívocamente inglesas (`the/and/was/were/this/that/…`) en la última
narración del DM; si pasa de 5, el siguiente beat recibe un nudge fuerte que le
exige castellano exclusivo (salvo nombres propios de la biblia). Conservador:
la lista evita falsos amigos con palabras castellanas.

---

## 16. Modelos — `lib/dragonex/models.ex`
- DM: `deepseek/deepseek-v4-flash` (env `DRAGONEX_MODEL`).
- Sumarizador: `google/gemini-3.1-flash-lite` (env `DRAGONEX_SUMMARIZER_MODEL`).
- `DRAGONEX_DM_MAX_TOKENS=1500`. PCs: 2048.
- OpenRouter cachea el prefijo del system; `cached_tokens/1` extrae el ahorro de
  `usage.details`.
- Umbral de compacción 250k (efectivamente desactivado; modelos de 1M).

---

## 17. UI — `DragonexWeb.GameLive.Show`
- Feed **agrupado por turnos** (`chat_blocks/2`): cada turno es un bloque con
  header (`Turno de X · ⚔ combate`) y eventos inline.
- Auto-play: icono 🤖 (lila) cuando el viewer es auto-play; `· TÚ` (verde) si es
  manual. Indicador "X está actuando…" dinámico.
- Input del humano oculto tras 💭 con hover (nunca inline).
- **Paginación** del log: botón ↑ carga turnos anteriores (`events_before/3`).
- **Streaming bubble** `@live_text` con cursor parpadeante, flush al persistir.
- **Modal de dados**: una apertura por grupo, con razón + dados + total + contra
  + resultado.

La LiveView **nunca** toca el Repo ni polls: se suscribe a `Dragonex.PubSub` al
tópico `dragonex:game:<id>` y re-fetch del snapshot al recibir
`{:game_updated, game_id}`.

---

## 18. Bugs conocidos y mejoras pendientes  📌

> **Sección viva.** Apuntamos aquí lo que encontremos para atacarlo en orden.

### ✅ Resueltos
- [x] **"LyraLyra" (auto-referencia duplicada)** — `Text.scrub/2` con
      `strip_leading_self_name` quita el nombre del actor al inicio (cajas +
      history). Render con `leading_self?/2` cubre la burbuja de streaming (texto
      sin scrub). Tests en `text_test.exs`.
- [x] **Streaming duplicado** (`texto → tool → texto`) — `maybe_flush_live_text/3`
      + `segment_already_carded?` limpia la burbuja cuando coincide con la última
      narración persistida del actor.
- [x] **Bugs 1-5 del handoff original** — retry con backoff transitorio,
      combate fantasma (`maybe_force_combat`), anti-loop PCs, anti-puppet DM,
      limbo de exploración. Tests en `game_retry_test`, `ghost_combat_test`,
      `pc_anti_loop_test`, `dm_puppet_pc_test`, `exploration_limbo_test`.
- [x] **`coalesce_assistant_runs` mezclaba actores** (`history.ex`) — ahora
      solo colapsa runs del mismo actor (`narration_actor/1`). Causa raíz del
      "quién dijo qué" perdido.
- [x] **`split_responses` invertía los grupos** (`history.ex`) — el más grave:
      truncaba las recientes y dejaba las viejas verbatim al final (orden
      temporal corrompido). Predicado corregido a `>= keep`.
- [x] **`@recent_narrations_kept = 5`** → subido a **12** para 4 agentes auto.
- [x] **Stats revelados** — `Text.scrub` ahora también limpia `CA 15`, `7 PG`
      bare, `X de los Y puntos de vida`, `clase de armadura N` (no solo X/Y).
      Conservador con números lore ("15 monedas"). Tests en `text_test.exs`.
- [x] **Frases calcadas del DM** — `with_dm_anti_repeat` compara las últimas 2
      narraciones (Jaccard ≥ 0.7) y, en casi-duplicado, cose un nudge de variedad.
      Tests en `dm_anti_repeat_test.exs`.
- [x] **Combate fantasma v2** — `with_dm_unspawned_hostile_nudge`: si el DM
      narra "(aparece|se materializa|irrumpe) un hostil" en exploración sin
      enemigos vivos, le fuerza `spawn_monster` (que dispara `maybe_force_combat`).
- [x] **DM narra PCs (ampliado)** — `@puppet_action_verbs` ampliada con verbos
      de movimiento/diálogo/observación (camina, abre, dice, examina…). El
      nudge de regla 14 dispara en más casos.
- [x] **DM apila ganchos y los abandona** — `world.facts` + tool
      `establish_fact` + bloque "Hechos establecidos" en el `world_brief`. Los
      hechos durables sobreviven a la truncación del history y los leen todos
      los agentes cada turno. Tests en `world_facts_test.exs`.
- [x] **Auto-play de varios PCs = caos** — nudge de coordinación en
      `PCAgent.instruction` (exploración): reaccionar a lo que los compañeros
      propusieron en vez de abrir hilos paralelos. (La coherencia base ya viene
      del history bien reconstruido tras el fix de `history.ex`.)
- [x] **`"X titubea"` espurio** — `handle_non_max_token_error` ahora omite el
      fallback de narración si la `Events` capability ya persistió una para ese
      `turn_id` (caso texto-mid-beat + fallo final: no pinta "titubea" encima).
- [x] **Bucle infinito de "titubea"** — `fallback_streak` + circuit breaker:
      tras 4 fallbacks consecutivos la partida se **pausa** (nota `:system`
      explicativa, no se manda `tick`). Evita el flujo infinito durante una
      caída persistente del proveedor y, de paso, el 503 al paginar (síntoma
      de server saturado por el bucle). Test en `game_retry_test`.
- [x] **DM no aplicaba curación al narrarla** — regla #10 reforzada: narrar
      curación sin `heal` deja personajes atascados a 0 pg (salvaciones de
      muerte eternas en una escena ya resuelta). Ahora exige `heal`.
- [x] **Paginación sin límite en el LiveView** — `@max_chat_blocks` (400) tope
      de bloques renderizados; el tail más viejo se suelta al cargar más,
      previniendo OOM tras muchos "load more".
- [x] **Nombre pegado / duplicado** (`Thanedeja`, `Thane**Thane**`) — raíz:
      el modelo emite el nombre en **markdown bold** (`**Thane**deja`); el scrub
      ahora striptea el cierre `**` también, y el render añade un espacio
      textual entre el chip `who` y el texto (el `margin` CSS no se preserva al
      copiar). `leading_self?` del bubble actualizado.
- [x] **Inglés mezclado** — `with_dm_spanish_nudge` detecta narración inglesa
      (stopwords) y fuerza castellano el siguiente beat.
- [x] **Frases meta + tool-calls en prosa** — scrub ampliado: quita
      `establish_fact(…)`, `spawn_monster(…)`, `[Establecer hecho: …]` y
      rupturas de cuarta pared ("la escena se resetea", "lo materializo en el
      mundo", "como DM…").
- [x] **Byte UTF-8 inválido que wedged la partida (crítico)** — el modelo emitía
      a veces un byte líder suelto (`0xC2` sin continuación). Jason no podía
      serializarlo → `{:model_request_failed, %Jason.EncodeError{…}}` → todos
      los beats fallaban → bucle de "titubea" → pausa, y al reanudar seguía
      fallando (el byte estaba en el history persistido). Fix:
      `Text.sanitize_utf8/1` se aplica al final del scrub (lo persistido queda
      limpio) Y en `History` (`msg_request`/`msg_response`) al reconstruir el
      history (limpia datos ya corruptos en DB). Además, el `note` del error en
      `handle_non_max_token_error` se trunca+sanitiza para no persistir el
      binario crudo del `Jason.EncodeError`.
- [x] **GenServer zombie tras borrar un game** — si se borraba la fila `games`
      mientras el proceso seguía vivo, cada tick crasheaba con violación de
      foreign key y el supervisor lo reiniciaba en bucle. Ahora `handle_info(@tick)`
      hace `rescue Ecto.ConstraintError` y para el proceso limpio (`{:stop, :normal}`).

### 🟡 Mejoras futuras (validar en la próxima partida)
- [x] **Coordinación real entre PCs auto (mesa)**: el system prompt #5 y la
      instruction de exploración decían «elige y ejecuta / camina hacia la
      salida», contradiciendo la regla 13 (proponer y esperar). En 258 Lyra
      se marchaba sola («desaparece en el arco», «sin esperar respuesta»).
      Alineado a compañero de mesa; el antibucle ya no empuja a irse.
- [x] **Scrub estructural de DM-narra-PC** (D29): cláusulas sujeto-inicial
      `<PC> <verbo>` se tiran al persistir; pasivo y mención no-sujeto se
      quedan. Time-skip y voz de PNJ en beat de PC también se recortan.
      Opener de exploración = `pass_to_dm` sin «relevo».
- [x] **Voz de PNJ en frase larga** (D30): se recorta desde el primer
      atribuidor; el split no parte comillas. Headers mid-prosa fuera.
- [x] **Pregunta del DM al humano** (D30): no se cede al otro PC.

### 🟡 Validado en vivo (partida 913) y deudas que quedan
- [x] Voz de PNJ en beat de PC: Thane pregunta a Borin; el persistido de
      Thane no trae el diálogo de Borin; el DM responde después.
- [x] Dados: `🎲 Lyra · chequeo/ataque` (punto medio). ThaneSe en el AT
      es chip+«Se…» (el persistido ya es «Se levanta»).
- [x] Combate + D18 iniciativa + `cut_in` («Thane interrumpe.»).
- [x] **«Ábrelo tú, si quieres.»** retiene el floor (D30: `tú` / `si quieres`).
- [x] **`gritando:`** y `el enano … —` se cortan en beat de PC.
- [x] **ThaneSe visual**: chip `Thane ·` (no se pega a Se).
- [x] **`Thane's hand`** se tira al persistir.
- [x] **PC IA no cierra solo** (D32): en exploración con humano, se tiran
      cláusulas de ejecución (`despliega el pergamino`, `coge el…`).
- [x] **Biblia → facts** (D32): Borin + gancho oficial + enemigos previstos.

### ⚪ Menores
- [ ] _（sin pendientes menores abiertos）_

---

## Cómo correr una partida de prueba

1. `docker compose -f compose.dev.yml up -d` (levanta Postgres + app; http://localhost:4035).
2. Navegador → http://localhost:4035/games/new → escenario "Arena de Pruebas".
3. Toggle auto-play en un PC para observar sin input humano.
4. Pausar/reanudar cuando haga falta. Logs: `docker logs -f dragonex-app`.

## Tests
- `MIX_ENV=test mix test` → suite verde (**844** actualmente).
- Tests aislados por bug: `game_retry_test` (incluye circuit breaker),
  `ghost_combat_test`, `pc_anti_loop_test`, `dm_puppet_pc_test`,
  `exploration_limbo_test`, `text_test` (scrub/2 + bold + stats + leak + meta +
  tool-calls), `history_test`, `dm_anti_repeat_test` (incluye anti-inglés),
  `world_facts_test`.
