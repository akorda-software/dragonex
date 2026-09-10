# Arquitectura

> **Técnico.** Cómo se divide Dragonex en subsistemas, cómo se comunican y dónde
> vive cada cosa. Para el detalle módulo a módulo, ver
> [`05-mapa-de-modulos.md`](05-mapa-de-modulos.md); para el bucle exacto,
> [`01-bucle-del-agente.md`](01-bucle-del-agente.md).

## La idea estructural

Dragonex separa radicalmente **dos responsabilidades** que en otros sistemas
mezcla el LLM:

- **Narrar** — le corresponde al LLM (DM y PCAgent).
- **Arbitrar** — le corresponde al **motor 5e** determinístico (`Rules`/`Actions`/`World`).

El LLM **jamás** decide el resultado de una tirada, daño o salvación. Llama a una
`deftool` que ejecuta el motor, lee el resultado, y lo traduce a prosa. Esto es el
invariante `D1` y estructura toda la arquitectura.

La segunda idea clave: el **estado** (`World`) tiene **un solo escritor** (el
`Game` GenServer, `D6`) y vive en Postgres, no en la memoria del modelo. El
proceso puede morir y la partida rehidrata.

## Subsistemas

```
┌──────────────────────────────────────────────────────────────────────────┐
│ S1  Web / LiveView            lib/dragonex_web/                          │
│     Phoenix.LiveView: la mesa, el creador de héroes, lobby, auth.        │
│     NUNCA escribe en Repo datos de partida (D6).                         │
│     Mesa: grid 3-col ≥721px; ≤720px feed+input y ficha en drawer CSS.    │
├──────────────────────────────────────────────────────────────────────────┤
│ S2  Partida / Game GenServer   lib/dragonex/game.ex + lib/dragonex/game/ │
│     Un proceso :transient por game_id. Es el ÚNICO escritor del World.  │
│     Lanza los beats como Task, persiste tras cada uno.                   │
├──────────────────────────────────────────────────────────────────────────┤
│ S3  Motor de agentes (engine) ExAgent.Session + turn_policy/ + TurnMaster│
│     Driva el chat modelo↔tools. TurnMaster reparte turnos (D25);         │
│     WorldDriven queda como fallback determinista.                        │
├──────────────────────────────────────────────────────────────────────────┤
│ S4  Reglas 5e                  lib/dragonex/rules/ + actions.ex + world  │
│     Matemática PURA sin estado (roller inyectado). Resuelve tiradas.     │
├──────────────────────────────────────────────────────────────────────────┤
│ S5  Tools (API del LLM)        lib/dragonex/tools.ex                     │
│     deftools que el modelo invoca → Actions → World (vía SharedState).   │
├──────────────────────────────────────────────────────────────────────────┤
│ S6  Agentes                    lib/dragonex/{dm,pc_agent,turn_master,    │
│                                agent,events,brief,history}.ex            │
│     DM, PCAgent y TurnMaster (orquestación de turnos, D25). Prompts,     │
│     guardrails, contexto compartido.                                     │
├──────────────────────────────────────────────────────────────────────────┤
│ S7  Persistencia               lib/dragonex/games.ex + games/ + codec.ex │
│     El contexto Games toca Repo (games/participants/characters/events).  │
│     Codec: World ↔ jsonb simétrico.                                      │
├──────────────────────────────────────────────────────────────────────────┤
│ S8  Creador de héroes          lib/dragonex/heroes.ex + heroes/          │
│     Builder PURO y offline (D9): choices 5e → Character nivel 1.         │
│     Custom inyectado (opts[:custom]), nunca lee DB.                      │
├──────────────────────────────────────────────────────────────────────────┤
│ S9  Auth                       lib/dragonex/accounts.ex + accounts/      │
│     Users, heroes, custom_contents (bcrypt). El contexto que SÍ usa      │
│     Repo desde la LiveView (datos de usuario, no de partida).            │
├──────────────────────────────────────────────────────────────────────────┤
│ S10 Config / Modelos           lib/dragonex/{models,model_config,        │
│                                application,release,i18n}.ex              │
│     Proveedores LLM (OpenRouter/OpenCode), select runtime, supervision.  │
└──────────────────────────────────────────────────────────────────────────┘
```

## Dirección de dependencias (qué puede llamar a qué)

Las flechas apuntan hacia abajo. Una capa **nunca** llama a una superior.

```
S1 Web ───────────► S2 Game GenServer ──► S3 Engine (ExAgent.Session)
   │                     │                      │
   │                     │                      ├──► S5 Tools ──► S4 Reglas
   │                     │                      │         │
   │                     │                      │         └──► (propone) World (en S3)
   │                     │                      │
   │                     │                      └──► S6 Agentes (DM, PCAgent)
   │                     │
   ├─► S9 Accounts ─► Repo (users/heroes/custom_contents)
   │
   └─► S7 Games (lifecycle: create/join/start/delete) ─► Repo (games...)
                              ▲
                              │  (persist/read World, events)
                   S2 Game GenServer ─► S7 Games
```

Reglas de la dirección:

- **S1 → S2**: la LiveView habla con la partida **sólo** vía el GenServer
  (`Game.declare/3`, `Game.pause/1`, `Game.sync_hero_level_up/3`…). Nunca toca
  `games.world`.
- **S1 → S9 / S7 (lifecycle)**: la LiveView sí usa `Accounts` y `Games` para
  *crear/unirse/arrancar/borrar* partidas, y para heroes/custom content. Son
  escrituras fuera de una partida viva.
- **S5 Tools → S4 Reglas → World**: un tool llama a `Actions`, que llama a
  `Rules`, y **propone** el cambio al `World` vía `SharedState.propose_change/2`.
  El tool nunca muta el World directamente.
- **S2 es el único escritor del World**: los cambios se aplican a través de la
  `Session` que el `Game` posee.

## Dónde vive cada cosa (tabla rápida)

| Quieres tocar… | Subsistema | Módulo(s) principal(es) |
|---|---|---|
| Una pantalla / evento de la LiveView | S1 | `lib/dragonex_web/live/` |
| El bucle de la partida, pausa, reanuda | S2 | `Dragonex.Game` (`game.ex`) |
| De quién es el turno | S3/S6 | `TurnMaster` (principal) + `WorldDriven` (fallback) |
| Una regla 5e (tirada, daño, salvación) | S4 | `Dragonex.Rules.Combat`, `Rules.Ability` |
| El puente intent→world de una acción | S4 | `Dragonex.Actions` |
| La estructura/estado del mundo | S4 | `Dragonex.World` |
| Una herramienta que el LLM puede llamar | S5 | `Dragonex.Tools` |
| El prompt del DM o del PC | S6 | `Dragonex.DM`, `Dragonex.PCAgent` |
| Guardrails (anti-loop, anti-puppet…) | S6 | `Dragonex.Game.Guardrails` |
| El historial compartido / brief del mundo | S6 | `Dragonex.History`, `Dragonex.Brief` |
| El esquema de DB / persistencia | S7 | `lib/dragonex/games/`, `Dragonex.Codec` |
| El creador de personajes / level-up | S8 | `lib/dragonex/heroes/` |
| Usuarios / heroes / contenido custom | S9 | `lib/dragonex/accounts/` |
| Modelo LLM / provider / runtime | S10 | `Dragonex.Models`, `Dragonex.ModelConfig` |

## Árbol de procesos (runtime)

```
Dragonex.Application
├─ Dragonex.Repo                       (pool Ecto)
├─ Phoenix.PubSub                      ("dragonex:game:<id>")
├─ Dragonex.ModelConfig                (GenServer: override runtime del modelo)
├─ Dragonex.Game.Registry              (Registry unique, lookup por game_id)
├─ Dragonex.Game.Supervisor            (DynamicSupervisor)
│   └─ Dragonex.Game  (uno por game_id, :transient, registrado en el Registry)
└─ DragonexWeb.Endpoint                (Bandit)
```

Cada partida es un `Dragonex.Game` aislado bajo el `DynamicSupervisor`, arrancado
on-demand (`Game.ensure_started/2`) y localizado por `game_id` en un `Registry`.
Si su proceso muere, es `:transient` → se rehidrata de Postgres al rearrancar
(`Game.start_link` → `rehydrate`). El historial y el `World` están en disco, no en
el proceso.

## Decisiones estructurales clave (por qué es así)

Las decisiones completas están en [`../decisions.md`](../decisions.md). Las
que más impacto tienen en la arquitectura:

- **`D1`** — el motor es la fuente de verdad → separa S4/S5 de S6.
- **`D3`/`D5`** — la `Session` se arranca **sin store**; el `Game` es la capa de
  durabilidad (persiste tras cada beat). Por eso `Store.Coded` existe pero apenas
  se usa en producción.
- **`D6`** — single-writer → S2 es el único que escribe `games.world`.
- **`D19`** — el historial se **reconstruye** desde `game_events` en cada beat, en
  vez de acumularlo por agente. Esto da coherencia entre DM y PCAgent.
- **`D20`** — la story bible va horneada en el system prompt (prefijo cacheable).

## Lectura siguiente

- [`01-bucle-del-agente.md`](01-bucle-del-agente.md) — el trace exacto de un turno.
- [`02-modelo-de-datos.md`](02-modelo-de-datos.md) — DB, structs, Codec.
- [`../FLUJO_PARTIDA.md`](../FLUJO_PARTIDA.md) — la misma arquitectura contada como narrativa de una partida.
