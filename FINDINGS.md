# Dragones — spike findings

Spike para validar que exAgent 1.0 encaja en un juego de D&D. 10 flujos
implementados y testeados (21 offline + 1 live contra GLM-4.7-flash).

## Verdict: encaja bien

Cada capacidad del framework se probó en un flujo real del juego y funcionó:

| Flujo | Capacidad exAgent | Estado |
|---|---|---|
| Narración DM | Server + SharedState (single-writer) | ✅ |
| Sheets de personaje | OutputSchema + validaciones changeset → JSON Schema | ✅ |
| Combate + iniciativa | TurnPolicy.Initiative + tools que mutan mundo | ✅ |
| Dados | deps forwarding (roller inyectable para tests) | ✅ |
| Delegación de reglas | Coordination.delegation_tool (usage compartido) | ✅ |
| Ronda multi-participante | SupervisorPolicy (DM entre cada actor) | ✅ |
| Persistencia | Store.ETS + rehydrate tras crash | ✅ |
| Compacción | Compaction.Summary + Capability | ✅ |
| Aprobación de acciones | Permissions :ask + :approve callback | ✅ |
| DM real (live) | OpenRouter + tools coherentes con un LLM | ✅ |

## Friction / gaps para la app real

Estos NO son bugs de exAgent — son decisiones/limitaciones que el spike
sacó a la luz y que la app completa debe afrontar:

### 1. El Mundo NO se persiste solo (ALTO)
El `ExAgent.Server` checkpointa el **historial de conversación** del agente,
pero el **World** vive en el `ExAgent.Session` (en memoria). Una campaña
duradera necesita persistir el World también. El behaviour `ExAgent.Store`
declara callbacks de session-snapshot (`save_session_snapshot` /
`load_session_snapshot`) pero **no están cableados** en la Session.

Decisión para la app: (a) cablear session-snapshots en exAgent, o (b)
persistir el World aparte (la Session lo recibe en `shared_state:` al
arrancar), o (c) reconstruir el World desde el historial del DM.

### 2. El `agent_id` duplicado no se detecta (MEDIO)
Nada impide dos `ExAgent.Server` con el mismo `agent_id` contra el mismo
store → cross-talk. Para la app, conviene un registry propio que asegure
un agent_id único por partida.

### 3. `take_turn/3` accepta cualquier valor del change_fn (MEDIO)
Un `change_fn` que devuelve `{:ok, state, usage}` (la convención de tools de
exAgent) silenciosamente sobrescribe el World con esa 3-tupla. El harness
evita esto, pero la app real debe validarlo o usar siempre `{:ok, new}`.

### 4. `Dice` con secuencia determinista es manual (BAJO)
Para scriptear combates con varias tiradas usamos un Agent inline. Para la
app, un roller con semilla (`:rand.seed`) por partida es más limpio y
reproducible.

## Cómo correrlo

```sh
mix test                              # 21 offline
DRAGONES_RUN_LIVE=1 OPENROUTER_API_KEY=... \
  mix test --include integration      # +1 live (DM real)
```

exAgent es path dep (`../exAgent`); cualquier fix al framework se pilla al
instante.
