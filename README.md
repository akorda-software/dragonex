# Dragonex

Un **Dungeon Master por IA** para D&D 5e. Creas una partida, eliges un escenario
y uno o varios personajes (humanos o IA) viven una aventura narrada y arbitrada
por un LLM. El modelo **solo narra**: cada tirada, ataque, daño y salvación se
resuelve por herramientas que aplican las reglas 5e — así el DM no miente con
números.

- **Stack**: Elixir 1.20 · Phoenix LiveView · Postgres · `exAgent` (framework
  de agentes propio, carpeta hermana en desarrollo y Hex en producción).
- **Modelo DM**: `deepseek/deepseek-v4-flash` vía OpenRouter (configurable por
  env a OpenCode Zen/Go, ver [`docs/tecnico/06-config-modelos-despliegue.md`](docs/tecnico/06-config-modelos-despliegue.md)).

## Arranque rápido (dev)

```sh
docker compose -f compose.dev.yml up -d   # Postgres + app en http://localhost:4035
# source montado en .:/app con code_reloader → los cambios se ven al refrescar
```

Necesitas `OPENROUTER_API_KEY` en `.env.dev` (copia `.env.dev.example`) para
que el DM narre de verdad. Sin ella, los beats usan el `TestModel`.

Desarrollo y pruebas usan siempre `../exAgent` y `../dic_ex`; `bin/dev` carga
la configuración y Phoenix recarga también esos paquetes. Compose monta ambas
carpetas. Producción usa `mix.hex.lock` y las versiones publicadas de Hex,
actualmente exAgent 2.2.2/dic_ex 0.3 (D246).
Para cambios JavaScript de dados ejecuta `mix dic_ex.build` en ese hermano.
La web sirve JS/CSS desde el `dic_ex` cargado por esa VM. Reconstruirlo en el
paquete actualiza el renderizador local; comprobar Hex en otro build no lo
sobrescribe.

Phoenix y LiveView también sirven sus módulos JavaScript desde los paquetes
instalados, con la misma versión del servidor; el navegador no necesita CDN.

La política de modelos de la casa y las claves propias del jugador se describe
en [`docs/progress.md`](docs/progress.md) (D242–D243). Las pruebas ordinarias
usan modelos deterministas y no necesitan una clave de proveedor.

## Comandos

```sh
MIX_ENV=test bin/dev ecto.create           # preparar dragonex_test una vez
MIX_ENV=test bin/dev ecto.migrate          # aplicar migraciones de pruebas
MIX_ENV=test bin/dev test                  # estado de la suite en docs/progress.md
mix format                                # antes de commit
docker logs -f dragonex-app               # logs del server
```

Las pruebas usan `dragonex_test`, separada de `DB_NAME` en `.env.dev`.
`DB_TEST_NAME` permite elegir otra base de pruebas; host/puerto/usuario se
comparten con la conexión de desarrollo.

## Integración continua

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) prepara el gate de GitHub
Actions para pull requests, pushes a `master` y ejecución manual. Usa las
versiones de Elixir/OTP del Dockerfile, Postgres 17 y el grafo de `mix.hex.lock`:
formato, compilación sin warnings propios, auditoría Hex, migraciones y suite
offline. No necesita los checkouts hermanos ni claves de modelos y no despliega.
La primera ejecución remota queda pendiente de publicar el workflow.

Para repetir ese grafo localmente, con la base de pruebas preparada:

```sh
MIX_ENV=test DRAGONEX_DEPS_SOURCE=hex MIX_DEPS_PATH=.hex_graph/deps MIX_BUILD_PATH=.hex_graph/_build bin/dev test --seed 0
```

Los cambios de los paquetes hermanos se siguen verificando con el gate local
habitual; la CI del consumidor verifica las versiones publicadas y fijadas.

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
priv/repo/migrations  migraciones versionadas (games/heroes/users/custom_contents/...)
priv/srd/             spells.es.json (319, generado por scripts/import_srd_spells.py)
docs/                 progress, decisions, flujo de partida, histórico
```
