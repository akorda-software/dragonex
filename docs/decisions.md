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
controlador de monstruos (plegados en su turno) y director narrativo.

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

---

## Pendientes de decisión (abiertas)

- **Banner in-game de level-up inerte bajo milestone**: `viewer_level_up` en
  `GameLive.Show` sigue gateado por `Progression.can_level_up?(level, xp)`.
  Como no hay fuente de XP, nunca se muestra. Si se quiere un nudge en la mesa,
  cablear a un flag "DM granted" en vez de a XP. (No bloqueante.)
- **Coordinación real entre PCs auto**: cubierta por **TurnMaster (D25,
  Implementada)**. Validar en partida live que el ritmo y la equidad se
  sostienen; si no, ajustar prompt/brief del TurnMaster (no volver al
  round-robin como camino principal).
