# Config, modelos y despliegue

> **Técnico.** Deps, ficheros de config, variables de entorno, puertos, los dos
> proveedores LLM y cómo se despliega. Para arrancar en local, el
> [`../../README.md`](../../README.md) + [`../../AGENTS.md`](../../AGENTS.md).

## Dependencias (`mix.exs`)

- **`exagent`** — dev/test resuelve siempre `../exAgent`; prod, Hex `~> 2.2.2`
  (D246). Ambos grafos ejecutan la misma API v2.
- **`dic_ex`** — dev/test resuelve siempre `../dic_ex`; prod, Hex `~> 0.3`.
  Endpoint sirve JS/CSS directamente del `priv/static` del `dic_ex` cargado.
  Los builds de test Hex no pueden sobrescribir los assets de una VM local.
  Reconstruir JS en el paquete: `mix dic_ex.build`; no hay build JS propio.
- **Clientes Phoenix/LiveView** (D203): Endpoint sirve `phoenix.mjs` y
  `phoenix_live_view.esm.js` desde el paquete instalado en cada VM. El layout
  importa esas rutas locales; no hay CDN ni versión del cliente fijada aparte.
- **Locks**: `mix.lock` para candidatos locales; `mix.hex.lock` para Hex/prod.
  El test explícito del segundo grafo usa `DRAGONEX_DEPS_SOURCE=hex`. Prod
  ignora rutas/flags locales; un hermano ausente en dev falla sin fallback.
- Phoenix `~> 1.7`, LiveView, Ecto `~> 3.12`, Bandit `~> 1.5`, `bcrypt_elixir`,
  `jason`, `lazy_html` (test), `dotenvy` (también requerido por llm_db/ReqLLM).
- Elixir `~> 1.20` (pin en `mix.exs`); Erlang/OTP 29 (entorno de dev/test actual,
  no hay pin duro en `mix.exs`).
- **Package manager: `mix`**. **Nunca** npm/npx — no hay frontend JS que compilar.

`bin/dev` carga `.env.dev` antes de mix; conserva MIX_ENV y los selectores
explícitos del shell. Phoenix recarga `dragonex`, `exagent` y `dic_ex`; Compose
dev monta ambos hermanos de solo lectura. D201 sustituye la configuración D26.

Routing solicitado: DeepSeek4.1Flash→`decart`, MiMo2.6Flash→`io-net`, con
`order`+`only`, `allow_fallbacks:false`, `require_parameters:true`. Smoke real
de herramienta+texto pasa con DeepSeek en v2 local y MiMo en Hex1.2. MiMo en
v2 falla antes de IO: stock ReqLLM1.26 no expone `reasoning.enabled:false`.
No se inventa `reasoning_effort` ni se usa otro proveedor para salvar el probe.

## Ficheros de config

| Fichero | Qué define |
|---|---|
| `config/config.exs` | PubSub `Dragonex.PubSub`, adapter Bandit, `signing_salt` (default de dev; prod lo pisa en `runtime.exs`) |
| `config/dev.exs` | Repo `127.0.0.1:5432`/`dragonex_dev`; endpoint `127.0.0.1:4000`; code reloader |
| `config/runtime.exs` | dev/test cargan `.env.dev` (Dotenvy); override DB por env; **prod requiere** `DATABASE_URL` y `SECRET_KEY_BASE` (+ opcional `LIVE_VIEW_SIGNING_SALT`, derivado del secret si no viene) |
| `config/test.exs` | Repo test, sandbox |

**Carga de entorno**: en `:dev`/`:test`, `runtime.exs` hace `Dotenvy.source([".env.dev", System.get_env()])`
y lo mete en `System.put_env`. Los valores del entorno real **ganan** sobre `.env.dev`.

## Variables de entorno

| Var | Default | Para qué |
|---|---|---|
| `OPENROUTER_API_KEY` | — | API key del provider OpenRouter. Sin ella → `TestModel` |
| `OPENROUTER_PROVIDER_ORDER` | — | CSV de slugs de upstream providers de OpenRouter (orden = preferencia, minúsculas; vacío → routing default). Sólo con `DRAGONEX_PROVIDER=openrouter`; llega como objeto top-level `provider` (`order` + `allow_fallbacks: true`) vía `ModelSettings.extra` en DM, PC bots y TurnMaster (`models.ex`) |
| `OPENCODE_API_KEY` | — | API key del provider OpenCode (Zen/Go) |
| `OPENCODE_PLAN` | `go` | Plan de OpenCode (`go`/`zen`) |
| `DRAGONEX_PROVIDER` | `openrouter` | Provider activo (`openrouter`/`opencode`) |
| `DATABASE_URL` | — | **prod obligatoria** |
| `SECRET_KEY_BASE` | — | **prod obligatoria** (`mix phx.gen.secret`) |
| `LIVE_VIEW_SIGNING_SALT` | derivado del secret | signing salt de LiveView en prod |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | — | Cliente OAuth web de Google para «Continuar con Google» (D245). Sin ellas no hay botón. Redirección: `<url pública>/auth/google/callback` |
| `DB_HOST`/`DB_PORT`/`DB_USER`/`DB_PASS`/`DB_NAME` | `127.0.0.1`/`5432`/… | override de DB (dev/test) |
| `PORT` | `4000` | puerto http del endpoint |
| `PHX_BIND_IP` | `127.0.0.1` | IP de bind |
| `DRAGONEX_COMPACTION_THRESHOLD` | `250000` | umbral de compactación (tokens) |
| `DRAGONEX_COMPACTION_KEEP_RECENT` | `12` | mensajes recientes que la compactación conserva verbatim (`game/bootstrap.ex`) |
| `DRAGONEX_APP_TITLE` | `"dragonex"` | título canónico de la app (attribution de los providers, `models.ex`) |

## Los dos proveedores LLM (`Dragonex.Models`)

| Provider | Key | Modelo DM por defecto | Modelo summarizer | Reasoning |
|---|---|---|---|---|
| `:openrouter` (default) | `OPENROUTER_API_KEY` | `deepseek/deepseek-v4-flash` | `google/gemini-3.1-flash-lite` | `%{"reasoning" => %{"effort" => …}}` |
| `:opencode` | `OPENCODE_API_KEY` | `deepseek-v4-flash` | `gemini-3.5-flash-lite` | `%{"reasoning_effort" => …}` |

**Resolución del provider** (mesas de la casa en `:open`): `DRAGONEX_PROVIDER`
env → `:openrouter` (default). Un valor desconocido cae a `:openrouter` con
warning.

**Fallback offline**: si la key del provider activo falta o está vacía, todos
los roles caen a `%Models.Test{}` (`models.ex`). Así dev sin key sigue
funcionando — el DM no narra, pero los turnos se resuelven y los tests son
deterministas.

### Quién paga la IA de cada mesa (D242)

- `DRAGONEX_SERVER_MODELS` = `fixed` (default; producción) | `open` (dev y
  test vía `config :dragonex, :server_models`).
- **Casa** en `fixed`: `deepseek/deepseek-v4.1-flash` en los tres roles con
  `OPENROUTER_API_KEY`, Decart primero y el resto por coste ponderado como
  respaldo (`Models.house_routing/0`, cache 6 h; D243). En `open`, los defaults de env.
- **Clave propia** (`Dragonex.AIProviders`): el jugador la guarda en
  `/cuenta`, cifrada con una clave derivada de `SECRET_KEY_BASE`
  (`Accounts.KeyVault`). En el modal Ajustes elige proveedor y modelo; al
  aplicar se prueba con una petición mínima.
- **Servidor** (solo `open`): cualquier modelo de OpenRouter/OpenCode con las
  keys del servidor, para probar.
- La elección vive en `games.ai`; `Game.restart/2` la guarda y `Bootstrap` la
  reconstruye al arrancar (`Dragonex.GameAI`).

### Retirar o reemplazar una clave propia (D260)

Al completar la operación, las mesas afectadas quedan pausadas: al retirar
usan la casa; al reemplazar conservan la selección con la clave nueva. Se
cancelan las peticiones activas y se impide admitir otra con la generación
retirada. World, historial e identidad de efectos pagados sobreviven; reanudar
recupera el turno. Una petición ya enviada al proveedor puede tener coste.
Las comprobaciones antiguas no vuelven a guardar ni aplicar la clave y el
modal muestra un error recuperable si se cancela una comprobación.

## Puertos

| Qué | Host | Contenedor |
|---|---|---|
| App (dev, compose) | **4035** | 4000 |
| App (`mix phx.server` en host) | **4035** (vía `.env.dev` `PORT`) | — |
| Postgres (dev, compose) | **5455** | 5432 |
| App → Postgres (dentro de compose) | — | `postgres:5432` |

Los puertos están centralizados en [`../../PUERTOS.md`](../../PUERTOS.md) si existe
a nivel de workspace; los de Dragonex son 4035 (app) y 5455 (Postgres dev).

## Compose / Docker (`compose.dev.yml`)

- **`postgres`**: `postgis/postgis:17-3.5-alpine`, volumen externo
  `infra_postgres-data`, host `5455 → 5432`. `POSTGRES_DB: dragonex_dev`.
- **`app`**: build desde `Dockerfile.dev`, source mount `.:/app`, code reloader.
  Env: `DB_HOST=postgres`, `DB_PORT=5432`, `PORT=4000`, `PHX_BIND_IP=0.0.0.0`.
  Host `4035 → 4000`. Comando: `mix deps.get && mix ecto.migrate && mix phx.server`.
- `Dockerfile` y `Dockerfile.dev` presentes. Deploy script `scripts/deploy-dokploy.sh`.

Arranque dev estándar:

```sh
docker compose -f compose.dev.yml up -d   # Postgres + app en http://localhost:4035
# o sólo Postgres y la app en host:
docker compose -f compose.dev.yml up -d postgres
DB_PORT=5455 mix phx.server               # http://localhost:4035
```

## Despliegue (producción)

- Release con `mix release` (ver `Dragonex.Release` para migrate/rollback sin Mix).
- Variables obligatorias en prod: `DATABASE_URL`, `SECRET_KEY_BASE`, y la key del
  provider elegido. Opcional `LIVE_VIEW_SIGNING_SALT`, `PHX_HOST`, `PHX_SERVER`.
- Despliegue vía Dokploy (`scripts/deploy-dokploy.sh`): imagen Docker + env vars
  inyectadas.

### CI antes de producción (D262)

`.github/workflows/ci.yml` prueba cada push salvo `production`, además de PRs
y ejecuciones manuales. El job `Published dependencies / offline tests`
instala el grafo Hex bloqueado, audita paquetes, comprueba formato y compile
sin warnings propios, migra PostgreSQL 17 y ejecuta la suite offline.

Solo un push a `master` con ese job verde puede promover su SHA a
`production`. La promoción comprueba que sigue siendo la punta de `master`
y actualiza la referencia sin force; una promoción antigua no puede hacer
retroceder una más reciente. La comprobación de punta no es atómica con la
actualización: puede promover un commit probado ya superado, nunca uno sin
probar. La rama `production` exige el check de GitHub Actions también a
administradores y prohíbe force-push/borrado.

Dokploy (Oracle Madrid, aplicación `3qfR_NLCaXL7Sw9Hvu9Ye`) sigue
`production`, con auto-deploy activo. No se comparte la API key de Dokploy
con Actions: el webhook GitHub de la rama protegida inicia el despliegue.
Un fallo o cancelación de CI deja la rama y el servicio en su última versión.
La promoción usa el `GITHUB_TOKEN` efímero con `contents: write` solo en ese
job; los tests tienen permiso de lectura y credenciales LLM vacías.

Antes de habilitar el flujo, `production` se creó en el commit desplegado
`9601df2`; cambiar la rama de Dokploy no reinició la aplicación. La primera
ejecución remota del gate, sobre `f6383da`, pasó:
[run 40182791446](https://github.com/akorda-software/dragonex/actions/runs/40182791446).
Las promociones posteriores quedan en el
[historial de CI](https://github.com/akorda-software/dragonex/actions/workflows/ci.yml)
y en los despliegues de Dokploy, con el SHA correspondiente.

La promoción completa se verificó sobre `59b362e` en
[40185544102](https://github.com/akorda-software/dragonex/actions/runs/40185544102):
check y promoción verdes, webhook recibido por Dokploy y release con el mismo
SHA respondiendo HTTP200 y conectando LiveView. Un commit posterior de solo
documentación puede registrar esta evidencia con `[skip ci]`; no avanza
`production` ni vuelve a desplegar el código ya probado.

Los despliegues manuales desde el panel o API siguen siendo operaciones de
administración: comprobar el SHA y su CI antes de usarlos. El script de
bootstrap crea infraestructura nueva; su plantilla apunta a `production`.
Revertir una release normalmente se hace mediante un commit de revert en
`master`, que vuelve a pasar CI, sin forzar la rama protegida.

Fuentes: [autodeploy de Dokploy](https://docs.dokploy.com/docs/core/auto-deploy),
[permisos y eventos de GITHUB_TOKEN](https://docs.github.com/en/actions/concepts/security/github_token).

## Comandos del día a día

```sh
MIX_ENV=test mix test                # suite (siempre con MIX_ENV=test)
mix format                           # obligatorio antes de commit
mix compile                          # sin warnings
docker logs -f dragonex-app          # logs del server (compose)
DRAGONEX_RUN_LIVE=1 OPENROUTER_API_KEY=... mix test --include integration  # tests live
```

## Lectura siguiente

- [`05-mapa-de-modulos.md`](05-mapa-de-modulos.md) — dónde está cada módulo.
- [`../../AGENTS.md`](../../AGENTS.md) — el contrato operativo (comandos, invariantes).
- [`../progress.md`](../progress.md) — qué está hecho.
