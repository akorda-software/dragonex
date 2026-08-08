# Dragones — roadmap y arquitectura

Una estrella polar viva. Define **qué** construimos, **cómo** (arquitectura) y
**en qué orden** (fases). Antes de cada fase se relee y se afina.

> **Estado actual canónico** → [`docs/progress.md`](docs/progress.md) (qué está
> hecho / qué falta / deudas v1) y [`docs/decisions.md`](docs/decisions.md) (el
> *porqué*). Las cifras de tests que aparecen abajo por fase son **históricas
> del momento de cada entrega**; el conteo vivo está en `progress.md`.

---

## Visión

Un DM por IA dirige partidas de D&D 5e. Flujos del usuario:

1. **Creador de partidas**: defines la historia, el estilo del DM, qué personajes
   juegan y **cuántos son IA vs humanos**.
2. **Juego**: la partida arranca. El DM narra y aplica las reglas; los personajes
   actúan en turnos por iniciativa.
3. **Pausable y durable**: se pausa cuando quieras, **se guarda todo en DB**, se
   reanuda en cualquier momento (incluso tras cerrar/reiniciar).
4. **Asíncrono**: cuando el turno es de un humano, la partida **espera** hasta que
   ese humano actúe; no bloquea a nadie ni avanza sin él.

---

## Principios

1. **El motor es la fuente de verdad.** La IA nunca calcula resultados: llama a
   tools que los resuelven por las reglas. El LLM solo lee texto y narra.
2. **La lógica de partida vive en un proceso `Dragones.Game`**, no en el
   LiveView. El Game es dueño del bucle de turnos, ejecuta los AI, espera a los
   humanos, persiste y se pausa.
3. **El LiveView es vista + input.** Renderiza el estado del Game y envía las
   acciones del humano. Cero lógica de juego ahí.
4. **Persistencia en DB (Postgres).** Durable, reanudable, multi-partida.
5. **Asíncrono por diseño.** Los turnos de humanos no bloquean; la partida queda
   en espera (`:waiting`).

---

## Capas

```
UI           DragonesWeb.LiveView — vista + input del humano (suscrito vía PubSub)
Aplicación   Dragones.Game (GenServer por partida) — bucle, AI, espera-humano, pausa
Motor        ExAgent.Session + Dragones.{Rules, World, Actions, Tools, DM, TurnPolicy.WorldDriven}
Datos        Postgres — games/characters/participants + World (jsonb vía Codec)
```

El motor ya está construido y probado (reglas 5e, DM, guardapolvo de control,
iniciativa imparcial, persistencia del World). Las fases **envuelven** ese motor,
no lo rehacen.

---

## El bucle de turnos (`Dragones.Game`)

El Game process avanza turnos (a través del `Session` + `WorldDriven`):

- **Turno de un AI** → lanza el agente en un **Task**, aplica el resultado al
  World, avanza. El Game **no bloquea** en la llamada al LLM (sigue respondiendo
  mensajes: pausa, consultas de otros, etc.).
- **Turno de un humano** → marca la partida `:waiting`, persiste, **idles**. La
  partida queda a la espera sin consumir CPU.
- **Acción de un humano** (vía LiveView) → el Game la procesa, propone en el
  Session como ese participante, avanza y continúa el bucle (auto-AI siguiente o
  espera del siguiente humano).
- **Pausa** → el bucle se detiene hasta reanudar (`:paused`).
- **Cada cambio se persiste** en DB; el proceso puede caer y **rehidratarse**
  con el mismo `game_id`.

El DM es un participante AI especial con **tres sombreros**: árbitro (aplica
reglas vía tools), controlador de monstruos (plegados en su turno, como hoy) y
**director narrativo** — es quien hace avanzar la historia, decidiendo qué va
pasando, guiándose por la **biblia de campaña** definida en el creador de
partidas (`story` + `dm_style`). Los PCs pueden ser AI u humanos; un PC IA tiene
su **propio agente** (personalidad, objetivos), distinto del DM.

---

## Modelo de datos (Postgres / Ecto) — borrador

- `games`: `id`, `title`, `story_bible` (jsonb — ganchos, NPCs, localizaciones,
  tono; lo que guía al DM), `dm_style`, `status`
  (`:configuring | :running | :paused | :waiting | :ended`), `world` (jsonb vía
  `Dragones.Codec`), `round`, `current_participant`, timestamps.
- `characters`: `id`, `game_id`, `name`, `sheet` (jsonb — el `Character`),
  `kind` (`:ai | :human`).
- `participants`: `id`, `game_id`, `name`, `kind`, `side`. (El DM es un
  participant `:ai` con side `"dm"`.)
- `game_events`: `id`, `game_id`, `seq`, `type`
  (`:narration | :action | :tool | :dice | :system`), `actor`, `visible_to`
  (`:all | :dm | :<participant>`), `payload` (jsonb), `inserted_at`.
  Log **append-only** — el historial completo para (a) recrear/replay,
  (b) contexto de los agentes, (c) la línea narrativa del chat (los `:visible_to`
  adecuan qué ve cada participante).

Se refina al implementar la Fase 0.

---

## Persistencia, contexto de agentes y coste

- **Estado + historial**: el `world` (jsonb) es el estado actual recreable; los
  `game_events` son la línea temporal append-only. Ambos se persisten en cada
  cambio → la partida se reconstruye/reanuda por `game_id` sin pérdida.
- **Contexto para los agentes**: el prompt de cada agente (DM y PCs IA) =
  `system` (reglas/rol) + `story_bible` (solo DM) + resumen del estado (`world_brief`)
  + **eventos recientes relevantes** (`game_events`, filtrados por `visible_to`).
  En partidas largas, los eventos viejos se **compactan** a un resumen
  (`ExAgent.Compaction.Summary`) para no inflar tokens.
- **Ahorro de tokens (caching)**: estructurar el prompt con un **prefijo
  estable** (system + biblia + reglas + resumen) y una **cola volátil** (último
  turno) para aprovechar el **prompt caching** del proveedor (cache_control /
  auto-cache de OpenRouter). Verificar soporte en el adaptador de exAgent al
  llegar (posible tarea de integración).
- **Coste**: modelo-por-rol (modelo barato para PCs IA y narración sencilla;
  mejor modelo en beats clave del DM), `max_tokens` ajustado, y rate limiting.

---

## Qué ya tenemos (base aprovechable)

- **Reglas 5e**: `Rules.Ability`, `Rules.Combat` (ataques, daño, críticos,
  salvaciones, chequeos, ventaja/desventaja, death saves).
- **Mundo**: `World` (máquina de estados, `combat_over?`, **guardapolvo de
  control** `controlled_by?/3`).
- **Puente**: `Actions` (intención→reglas→world) + `Tools` (`deftool`).
- **DM**: `DM` (system prompt estricto + `world_brief`).
- **Turnos**: `TurnPolicy.WorldDriven` (iniciativa del World, imparcial).
- **Persistencia del World**: `Codec` + `Store.Coded`.
- **Dados**: inyectables (tests deterministas) + modal cutre en la UI.
- 113 tests offline + 3 live (base pre-Fase 0). Arquetipos (fighter/wizard/rogue) y trasgos.

**Desechable**: el cascade síncrono actual en `GameLive.handle_info` — fue una
prueba del flujo; la Fase 0 lo reemplaza por el `Dragones.Game`.

---

## Fases

### Fase 0 — cimientos: `Dragones.Game` + DB  *(la que reorganiza todo)* — ✅ HECHA
- Ecto + Postgres: schemas `Game`/`Character`/`Participant`/`GameEvent` + migraciones. ✅
- `Dragones.Game` (GenServer, `:transient` bajo `DynamicSupervisor`, registro por
  `game_id` vía `Registry`): arranca, rehidrata del DB, persiste cada cambio
  (estado **y** `game_events` append-only). ✅
- El Game usa `ExAgent.Session` (`WorldDriven`) como motor in-memory; el Game es
  la capa de durabilidad (Postgres). Ejecuta AI en `Task`s; espera humanos
  (`:waiting`). ✅
- Contexto de agentes: `world_brief` + `story_bible` ya cableados al prompt del
  DM (base para caching/compactación). ✅
- Bucle migrado al Game process (DM beats + guardapolvo `controlled_by?`).
- **Verificado**: `MIX_ENV=test mix test` (117 verdes) + `priv/live_game.exs`
  (DM live: narra, los dados rodaron por tools — `d20=5` miss narrado honestamente —
  persiste estado+eventos, y **rehidrata tras kill** del proceso, mismo `game_id`). ✅

**LiveView ya es vista+input sobre `Dragones.Game`** ✅: `GameLive.mount`
crea la partida (`Scenario.default` → `Games.create_game`), arranca el Game
(`Game.ensure_started`) y se suscribe a `Dragones.PubSub` (`"dragones:game:<id>"`);
renderiza el `snapshot` (sheets + la línea de chat desde `game_events`) y envía
`Game.declare/3`. El Game es el único que toca la lógica y el Repo; el LiveView sólo
refleja lo que el Game reporta (incluido el modal de dados, alimentado por el
roller del Game que publica cada tirada). Cero cascade síncrono.

**Las cuatro fases del roadmap están hechas** (ver Fase 4 abajo). Lo pendiente
es refinamiento de producto (mobile, reacciones, iniciativa individual por
monstruo) — ver [`docs/progress.md`](docs/progress.md) § "Pendiente / fuera de
v1".

### Fase 1 — creador de partidas (wizard) — ✅ HECHA
- `Dragones.Scenario.catalog/0` (fighter/wizard/rogue PCs + goblin monster) +
  `Games.create_from_wizard/1` (roster + iniciativa automática: monstruos
  primero si los hay → el DM auto-actúa al abrir). ✅
- `GameLive.New` (`/games/new`): título/escena/estilo + reparto con toggle
  `:ai`/`:human` por PC (los monstruos siempre son del DM). Crea y navega a la
  mesa. ✅

### Fase 2 — multi-partida + pausa/reanuda — ✅ HECHA
- `GameLive.Index` (`/`): lista las partidas (título/estado/turno), Abrir,
  Borrar, Nueva. `GameLive.Show` (`/games/:game_id`) abre/reanuda por id
  (rehidrata del DB). ✅
- Botones Pausa/Reanudar en la mesa (`Game.pause/resume`); transiciones
  `:running ↔ :paused`/`:waiting` limpias. ✅
- **Verificado**: 125 tests verdes + dev server sirve `/`, `/games/new`,
  `/games/:id`.

### Fase 3 — asíncrono real + multi-humano — ✅ HECHA
- **Identidad por humano**: cada viewer "reclama" su personaje (`?as=<name>` o el
  overlay "¿Quién eres?"). El snapshot expone `participants` para el picker. ✅
- **Render por perspectiva**: el input se habilita sólo en TU turno, tu sheet se
  marca "TÚ", banner "Es tu turno" + "Esperando a X". Modo "Ver como DM"
  (eventos `visible_to :dm`). Varios viewers comparten la partida vía PubSub. ✅
- **Gating servidor**: `Game.declare/3(server, participant, text)` verifica que el
  turno es del humano reclamado — un viewer no puede actuar por otro. ✅
- **Verificado**: 127 tests verdes (multi-human Game test + picker/claim web
  tests) + `priv/live_game.exs` con 2 humanos (Thane+Lyra vs trasgo): el DM
  auto-actúa, Lyra queda fuera de juego en el turno de Thane (`:not_your_turn`),
  cada humano actúa en su turno, el firebolt de Lyra remata al trasgo → combate
  termina, todo persiste y rehidrata.

### Fase 4 — creador de personajes completo — ✅ HECHA
- **Builder nivel-1** (`Dragones.Heroes`): razas + subrazas, clases,
  backgrounds, puntuaciones (standard array / point buy / explícito),
  equipment (grupos SRD + custom), spells (casters), skills, languages. ✅
- **Catálogos SRD**: clases, razas, trasfondos, equipo completo, 42 hechizos
  builtin + **319 SRD** (importados a `priv/srd/spells.es.json` vía
  `scripts/import_srd_spells.py`). ✅
- **i18n ES/EN** del catálogo (`Heroes.Translations`). ✅
- **UI**: `HeroLive.New` creator de 5 pasos, `HeroLive.Show` ficha,
  `HeroLive.LevelUp` subida de nivel. ✅
- **Contenido custom por usuario** (`custom_contents` weapon/spell/item, CRUD
  en `/mi-contenido`, merge en `Catalog` con `source: :custom`). ✅
- **Subida de nivel en partida (milestone)**: `LevelUp.apply` + sync viva
  (GenServer single-writer) + tool `level_up` del DM. RAW: no cura. ✅
- **Verificado**: tests extensos (heroes/level-up/custom-content/accounts) +
  `MIX_ENV=test mix test` verde.

**Siguiente:** refinamientos de producto y reglas (mobile, reacciones,
iniciativa individual, coordinación de PCs auto) — ver
[`docs/progress.md`](docs/progress.md).

### Mejoras transversales (cualquier fase)
- **Cola de intenciones** ✅: el input está **siempre activo** — un humano
  `declare/3` su acción cuando quiera (incluso fuera de turno); se persiste
  (`games.intents`) y el loop la consume al llegar su turno, donde el DM la valora
  (válida → tools; sin sentido → narra o el guardapolvo la rechaza). Declarar en
  tu turno resuelve al momento. Reemplazó al `act` con input sólo-en-tu-turno.
- **Robustez del DM** ✅: el guardapolvo `controlled_by?` rechaza un monstruo
  actuando en turno de jugador con un error **directivo** (le dice al DM quién
  debe actuar y cómo re-emitar); las tools de resolución tienen `max_retries: 3`
  (`DM.tools/0`) y la instrucción por turno repite el proponente. Verificado:
  test determinista (mis-act → REFUSED → autocorrección → no `:paused`) + live.
- **Caching de prefijo** ✅: la story bible se hornea en el **system prompt**
  (prefijo estable); el volatile (world brief) va sólo en el último mensaje.
  OpenRouter cachea el prefijo → medido en vivo: **44–85% de los tokens de
  entrada cacheados** por beat. Framework: `parse_usage` captura
  `cached_tokens` y `sum_details` ya no casca con details anidados.
- **Modelo-por-rol** ✅: `Dragones.Models` centraliza `dm/0` (mejor adherencia)
  + `summarizer/0` (barato: flash/lite) + `dm_max_tokens/0`, todo env-overridable.
- **Compactación** ✅: `Compaction.Summary` cableada en el DM via capability; al
  cruzar el umbral el summarizer barato recapa el historial viejo (keep_recent
  verbatim). Umbral/ventana configurables (`DRAGONES_COMPACTION_*`).

> Todas las mejoras transversales del roadmap original están **hechas**. Lo
> que sigue es refinamiento de producto/reglas — lista viva en
> [`docs/progress.md`](docs/progress.md) § "Pendiente / fuera de v1":
> modal de dados pulido, condiciones→ventaja automática, iniciativa individual
> por monstruo, reacciones / "preparar acción".

---

## Decisiones confirmadas

- **Reusar `ExAgent.Session` como motor** (supervisado, durable, policy). El Game
  orquesta por encima. ✅
- **Game process on-demand**: arranca al abrir la partida, para por idle con el
  estado a salvo en DB. ✅ (para empezar)
- **World como jsonb en `games`** (vía `Codec`) + `game_events` append-only para
  el historial. ✅ (Fase 0)
- **El Game es la capa de durabilidad**, no un `Store` ExAgent: el `Session`
  corre in-memory (sin store) y el `Dragones.Game` persiste a Postgres tras cada
  beat (estado + evento). Rehidratar = leer el row, reconstruir el `Session` y
  `Session.handoff/2` al `current_participant` guardado. Evita doble persistencia
  y mantiene los `game_events` (que no son contrato de `ExAgent.Store`) en una
  sola capa. ✅ (Fase 0)
- **Multi-nodo (`Registry`/`Horde`)**: fuera de alcance por ahora. ⏸

## Cosas a tener en cuenta (lo que podría faltar)

- **Multi-agente**: cada PC IA es su propio agente (prompt + personalidad +
  objetivos + contexto), no un clon del DM. Definir cómo se construyen y qué ven.
- **Visibilidad de información**: `game_events.visible_to` distingue qué ve cada
  quien (jugadores no ven DCs ocultos/notas del DM; los PCs IA tampoco).
- **Memoria entre sesiones**: compactación (`Compaction.Summary`) para partidas
  largas — el DM "recuerda" sin inflar tokens.
- **Biblia de campaña estructurada**: la `story` del creador no es un string;
  son ganchos/NPCs/localizaciones/tono que dirigen al DM narrativo.
- **Coste**: caching de prefijo + modelo-por-rol + `max_tokens` + rate limiting.
- **Replay/depuración**: el `game_events` append-only permite reconstruir y
  depurar cualquier partida.
