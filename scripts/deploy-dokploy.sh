#!/usr/bin/env bash
#
# Despliega dragonex (Phoenix) a un Dokploy self-hosted vía API REST.
# Crea: proyecto → entorno → Postgres (cont. separado) → aplicación (Dockerfile)
#        → provider GitHub → env vars → dominio → deploy.
#
# Uso:
#   1. rellena .env.dokploy
#   2. ./scripts/deploy-dokploy.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ ! -f "$PROJECT_ROOT/.env.dokploy" ]]; then
  echo "❌ Falta .env.dokploy. Cópialo a partir de .env.dokploy.example y rellénalo."
  exit 1
fi
set -a; source "$PROJECT_ROOT/.env.dokploy"; set +a

REQUIRED_VARS=(
  DOKPLOY_URL DOKPLOY_API_KEY
  PROJECT_NAME ENV_NAME APP_NAME
  GITHUB_OWNER GITHUB_REPO GITHUB_BRANCH GITHUB_ID
  DB_NAME DB_DATABASE_NAME DB_USER DB_PASSWORD
  DOMAIN_HOST DOMAIN_PORT
  SECRET_KEY_BASE OPENROUTER_API_KEY
)
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "❌ Falta la variable obligatoria: $var"
    exit 1
  fi
done

API_BASE="${DOKPLOY_URL%/}/api"
AUTH_HEADER="x-api-key: $DOKPLOY_API_KEY"
JSON_HEADER="Content-Type: application/json"

api_post() { local path=$1 body=$2; curl -fsS -X POST "$API_BASE$path" -H "$AUTH_HEADER" -H "$JSON_HEADER" -d "$body"; }
api_get()  { local path=$1; curl -fsS -X GET  "$API_BASE$path" -H "$AUTH_HEADER" -H "$JSON_HEADER"; }

# 1. Project ----------------------------------------------------------------
echo "📁 Creando proyecto '$PROJECT_NAME'..."
PROJECT_RES=$(api_post "/project.create" \
  "{\"name\":\"$PROJECT_NAME\",\"description\":\"${PROJECT_DESCRIPTION:-}\"}")
PROJECT_ID=$(echo "$PROJECT_RES" | jq -r '.projectId // empty')
if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID=$(api_get "/project.all" | jq -r --arg n "$PROJECT_NAME" \
    'if type=="array" then .[] else .items[] end | select(.name==$n) | .projectId' | head -n1)
fi
echo "   ✅ Project: $PROJECT_ID"

# 2. Environment ------------------------------------------------------------
echo "🌿 Creando entorno '$ENV_NAME'..."
ENV_RES=$(api_post "/environment.create" "{\"name\":\"$ENV_NAME\",\"projectId\":\"$PROJECT_ID\"}")
ENV_ID=$(echo "$ENV_RES" | jq -r '.environmentId // empty')
if [[ -z "$ENV_ID" ]]; then
  ENV_ID=$(api_get "/environment.byProjectId?projectId=$PROJECT_ID" | jq -r --arg n "$ENV_NAME" \
    'if type=="array" then .[] else .items[] end | select(.name==$n) | .environmentId' | head -n1)
fi
echo "   ✅ Environment: $ENV_ID"

# 3. Postgres (contenedor separado) ----------------------------------------
echo "🐘 Creando PostgreSQL '$DB_NAME'..."
DB_RES=$(api_post "/postgres.create" "{
  \"name\": \"$DB_NAME\",
  \"databaseName\": \"$DB_DATABASE_NAME\",
  \"databaseUser\": \"$DB_USER\",
  \"databasePassword\": \"$DB_PASSWORD\",
  \"environmentId\": \"$ENV_ID\"
}")
DB_ID=$(echo "$DB_RES" | jq -r '.postgresId // empty')
DB_APP_NAME=$(echo "$DB_RES" | jq -r '.appName // empty')
if [[ -z "$DB_ID" ]]; then
  echo "❌ Falló la creación de la base de datos:"; echo "$DB_RES"; exit 1
fi
echo "   ✅ Database: $DB_ID (hostname: $DB_APP_NAME)"

# 4. Application ------------------------------------------------------------
echo "🚀 Creando aplicación '$APP_NAME'..."
APP_RES=$(api_post "/application.create" "{
  \"name\": \"$APP_NAME\",
  \"appName\": \"$APP_NAME\",
  \"description\": \"${APP_DESCRIPTION:-}\",
  \"environmentId\": \"$ENV_ID\"
}")
APP_ID=$(echo "$APP_RES" | jq -r '.applicationId // empty')
if [[ -z "$APP_ID" ]]; then
  echo "❌ Falló la creación de la aplicación:"; echo "$APP_RES"; exit 1
fi
echo "   ✅ Application: $APP_ID"

# 5. Build type: Dockerfile (mix.exs y Dockerfile están en la raíz del repo) -
echo "🐳 Configurando build type (Dockerfile)..."
api_post "/application.saveBuildType" "{
  \"applicationId\": \"$APP_ID\",
  \"buildType\": \"dockerfile\",
  \"dockerfile\": \"Dockerfile\",
  \"dockerContextPath\": \"${GITHUB_BUILD_PATH:-}\",
  \"dockerBuildStage\": null,
  \"herokuVersion\": null,
  \"railpackVersion\": null
}" > /dev/null
echo "   ✅ Build type: dockerfile"

# 6. GitHub provider --------------------------------------------------------
echo "🔌 Conectando GitHub..."
api_post "/application.saveGithubProvider" "{
  \"applicationId\": \"$APP_ID\",
  \"repository\": \"$GITHUB_REPO\",
  \"branch\": \"$GITHUB_BRANCH\",
  \"owner\": \"$GITHUB_OWNER\",
  \"buildPath\": \"${GITHUB_BUILD_PATH:-}\",
  \"githubId\": \"$GITHUB_ID\",
  \"triggerType\": \"push\"
}" > /dev/null
echo "   ✅ GitHub: $GITHUB_OWNER/$GITHUB_REPO:$GITHUB_BRANCH"

# 7. Environment variables --------------------------------------------------
echo "🔐 Guardando variables de entorno de la app..."
ENV_VARS="PHX_SERVER=true
PHX_HOST=${PHX_HOST:-$DOMAIN_HOST}
PORT=${DOMAIN_PORT}
SECRET_KEY_BASE=${SECRET_KEY_BASE}
DATABASE_URL=ecto://${DB_USER}:${DB_PASSWORD}@${DB_APP_NAME}:5432/${DB_DATABASE_NAME}
POOL_SIZE=${POOL_SIZE:-10}
OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
DRAGONEX_MODEL=${DRAGONEX_MODEL:-deepseek/deepseek-v4-flash}
DRAGONEX_SUMMARIZER_MODEL=${DRAGONEX_SUMMARIZER_MODEL:-google/gemini-3.1-flash-lite}
DRAGONEX_APP_TITLE=${DRAGONEX_APP_TITLE:-dragonex}
DRAGONEX_DM_MAX_TOKENS=${DRAGONEX_DM_MAX_TOKENS:-1500}"
ENV_JSON=$(printf '%s' "$ENV_VARS" | jq -R -s '.')
api_post "/application.saveEnvironment" "{
  \"applicationId\": \"$APP_ID\",
  \"env\": $ENV_JSON,
  \"buildArgs\": null,
  \"buildSecrets\": null,
  \"createEnvFile\": false
}" > /dev/null
echo "   ✅ Variables guardadas"

# 8. Domain -----------------------------------------------------------------
echo "🌐 Creando dominio..."
api_post "/domain.create" "{
  \"applicationId\": \"$APP_ID\",
  \"host\": \"$DOMAIN_HOST\",
  \"port\": ${DOMAIN_PORT},
  \"https\": ${DOMAIN_HTTPS:-true},
  \"certificateType\": \"letsencrypt\"
}" > /dev/null
echo "   ✅ Dominio: https://$DOMAIN_HOST"

# 9. Deploy -----------------------------------------------------------------
echo "🚦 Lanzando deploy..."
api_post "/application.deploy" "{\"applicationId\": \"$APP_ID\"}" > /dev/null
echo "   ✅ Deploy disparado"

echo ""
echo "========================================"
echo "  🎉 Deploy iniciado"
echo "========================================"
echo "  Project : $PROJECT_ID"
echo "  App     : $APP_ID"
echo "  DB      : $DB_ID"
echo "  URL     : https://$DOMAIN_HOST"
echo "========================================"
echo "  Sigue el build en: $DOKPLOY_URL → $PROJECT_NAME → $APP_NAME → Logs"
