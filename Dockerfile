# syntax=docker/dockerfile:1

# ------------------------------------------------------------------------------
# STAGE 1: Build (compila deps + release)
# ------------------------------------------------------------------------------
FROM hexpm/elixir:1.20.2-erlang-29.0.2-alpine-3.24.1 AS builder

# build-base: NIFs de bcrypt/etc.  git: deps exagent/dic_ex (git over HTTPS, públicas)
RUN apk add --no-cache build-base git

WORKDIR /app

ENV MIX_ENV=prod
ENV LANG=C.UTF-8

RUN mix local.hex --force && mix local.rebar --force

# Capa cache de deps: solo mix.exs/mix.lock. Reproducible (git deps fijadas por commit en mix.lock).
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Trae el código de la app
COPY . .

# Los assets de dicEx (priv/static/assets/*) son build artifacts gitignored,
# así que en un clone limpio no existen. Se regeneran desde la propia dep.
RUN mkdir -p priv/static/assets && cp deps/dic_ex/priv/static/* priv/static/assets/

RUN mix compile
RUN mix release

# ------------------------------------------------------------------------------
# STAGE 2: Runtime
# ------------------------------------------------------------------------------
FROM alpine:3.24.1

# libstdc++: NIFs (bcrypt).  openssl + ncurses-libs: runtime BEAM.
RUN apk add --no-cache libstdc++ openssl ncurses-libs

WORKDIR /app

RUN addgroup -S app && adduser -S app -G app

COPY --from=builder --chown=app:app /app/_build/prod/rel/dragonex ./

USER app

EXPOSE 4000
# Migra (idempotente) y luego arranca. Si una migración falla, el contenedor
# no arranca — preferible a servir con schema incompleto.
CMD ["sh", "-c", "bin/dragonex eval 'Dragonex.Release.migrate()' && bin/dragonex start"]
