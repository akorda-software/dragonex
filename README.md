# Dragonex

Un **Dungeon Master por IA** para D&D 5e. Creas una partida, eliges un escenario
y uno o varios personajes (humanos o IA) viven una aventura narrada y arbitrada
por un LLM. El modelo **solo narra**: cada tirada, ataque, daño y salvación se
resuelve por herramientas que aplican las reglas 5e — así el DM no miente con
números.

- **Stack**: Elixir 1.20 · Phoenix LiveView · Postgres · `exAgent` (framework
  de agentes propio, GitHub dep `kukapu/exagent`).
- **Modelo DM**: `deepseek/deepseek-v4-flash` vía OpenRouter (configurable por
  env a OpenCode Zen/Go, ver [`docs/tecnico/06-config-modelos-despliegue.md`](docs/tecnico/06-config-modelos-despliegue.md)).

## Arranque rápido (dev)

```sh
docker compose -f compose.dev.yml up -d   # Postgres + app en http://localhost:4035
# source montado en .:/app con code_reloader → los cambios se ven al refrescar
```

Necesitas `OPENROUTER_API_KEY` en `.env.dev` (copia `.env.dev.example`) para
que el DM narre de verdad. Sin ella, los beats usan el `TestModel`.

## Comandos

```sh
MIX_ENV=test mix test                     # suite verde (1511 passed / 3 excluded)
mix format                                # antes de commit
docker logs -f dragonex-app               # logs del server
```

## Documentación

Empieza por [`docs/README.md`](docs/README.md) — índice, órdenes de lectura por
tarea y reglas de precedencia.

| Doc | Para qué |
|---|---|
| [`docs/README.md`](docs/README.md) | **Índice** de toda la doc + cómo leerla según tu tarea. |
| [`docs/producto/`](docs/producto/) | **El qué**: visión, alcance, cómo se juega. |
| [`docs/tecnico/`](docs/tecnico/) | **El cómo**: arquitectura, bucle del agente, datos, reglas, módulos, despliegue. |
| [`docs/decisions.md`](docs/decisions.md) | Decisiones de diseño confirmadas (ADR ligero) y su *porqué*. |
| [`docs/progress.md`](docs/progress.md) | **Estado por feature**: qué está hecho, qué falta, deudas v1. |
| [`docs/FLUJO_PARTIDA.md`](docs/FLUJO_PARTIDA.md) | Narrativa punta-a-punta de una partida (complemento del bucle técnico). |
| [`ROADMAP.md`](ROADMAP.md) | Visión, principios y fases (estrella polar). |
| [`AGENTS.md`](AGENTS.md) | Convenciones y comandos para agentes automatizados. |
| [`docs/historical/`](docs/historical/) | Handoffs/specs de iteraciones pasadas (archivo). |

## Estructura

```
lib/dragonex/         dominio + motor: Rules, World, Actions, Tools, DM, PCAgent,
                      Game (GenServer), Games (DB), Heroes (creador 5e), Accounts
lib/dragonex_web/     Phoenix: LiveViews (Game, Hero, CustomContent), router, auth
priv/repo/migrations  8 migraciones (games/heroes/users/custom_contents/...)
priv/srd/             spells.es.json (319, generado por scripts/import_srd_spells.py)
docs/                 progress, decisions, flujo de partida, histórico
```
