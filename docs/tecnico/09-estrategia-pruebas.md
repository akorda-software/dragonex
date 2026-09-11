# Estrategia de pruebas

> **Técnico.** Cómo se verifica Dragonex: capas, principios, cobertura actual
> y el **protocolo de verificación** que todo agente debe pasar antes de
> declarar "hecho". Regla fundacional: **verificabilidad antes que
> afirmaciones** — nada está "funcionando" sin un test verde que lo pruebe.

Verde de referencia: **904 passed, 3 excluded** (`MIX_ENV=test mix test`),
100% offline, sin API key (los beats usan `TestModel`). `mix compile` sin
warnings; `mix format` limpio.

---

## Principios

1. **Determinismo**: nada de `:rand` en `Rules`/`Actions`/`World` — el roller
   se inyecta (`Dice`/`dic_ex` en prod; `seq([...])`/`always(n)` en tests).
   Un test puede decir "el d20 sale 20 → crítico" y asertar el resultado exacto.
2. **Oráculo independiente**: la matemática 5e se verifica en `Rules`/`Actions`
   **sin** LLM de por medio; los flows de agentes asertan sobre el **World**
   (estado), no sobre el texto de la narración. El LLM puede mentir; el test
   no le cree.
3. **Offline por defecto**: la suite no toca red. Lo que exige modelo real es
   `--include integration` (opt-in, `DRAGONEX_RUN_LIVE=1` + API key).
4. **Builder sin DB** (D9): `Heroes`/`Catalog` son puros; el contexto custom
   se inyecta. Sus tests corren `async: true`.
5. **Pirámide**: muchísimos unitarios del motor → flows de integración del
   bucle → un puñado de LiveView → smoke de LLM.

---

## Capas (dónde va cada test nuevo)

| Capa | Qué | Dónde | Modo |
|---|---|---|---|
| **L1 — Motor puro** | `Rules.Ability`/`Rules.Combat`/`Rules.Conditions`, `Actions`, `World`, `Dice`, `SpellSlots` (mecánicas `M1`–`M23`) | `test/dragonex/rules/`, `test/dragonex/{actions,world,conditions,spell_slots,rest,world_facts,ghost_combat,healing_and_bestiary}_test.exs` | `async: true`, rollers fijos |
| **L2 — Builder/catálogos** | `Heroes.build`, catálogos SRD, `LevelUp`, validaciones, custom content mechanics | `test/dragonex/heroes/*`, `test/dragonex/accounts/level_up_test.exs` | `async: true` sin DB (D9) |
| **L3 — Bucle y persistencia** | `Game` GenServer, beat completo con TestModel, retries/breaker, rehidratación, sync level-up, multiplayer, codec round-trip | `test/dragonex/{game_*,multi_level,persistence,turn_master*}_test.exs`, `test/dragonex/flows/*` | DB sandbox (ECTO Sandbox) |
| **L4 — Web** | LiveViews (mesa, wizard, level-up, custom content), auth | `test/dragonex_web/*` | `conn_case` + LiveViewTest |
| **L5 — Smoke LLM** | Un beat con `TestModel` (offline) por cada flujo de agente tocado | junto al flow que toca | offline |
| **L6 — Integración live** | Narración real contra proveedor | `flows/live_*_test.exs` | `--include integration`, opt-in |

Censo aproximado por área: heroes ~170 · motor/game+flows ~310 · web ~39 ·
rules ~25 · accounts ~22.

---

## Qué exige cada tipo de cambio

| Si tocas… | Mínimo de tests |
|---|---|
| Una mecánica (`Rules`/`Actions`/`World`) | L1 determinista + entrada en [`08-catalogo-mecanicas.md`](08-catalogo-mecanicas.md) |
| Una tool (firma/guarda/set) | L1 de la mecánica + smoke L5 del flow + update de [`07-contrato-tools.md`](07-contrato-tools.md) |
| El bucle (`game.ex`, TurnMaster, policies) | L3 del camino feliz Y del fallback (TurnMaster roto → WorldDriven, D25) |
| Prompts (DM/PC/TM) | L5 smoke +, si cambia comportamiento observable (idioma, repetición), test de guardrail (`dm_anti_repeat_test.exs` estilo) |
| Persistencia (`Codec`, schema) | Round-trip `codec_test.exs` + rehidratación `game_sync_genserver_test.exs` |
| Builder/catálogo | L2 + (si es derivado SRD) caso golden de ficha (ver F6.5) |
| LiveView | L4 del evento user-facing (click→evento→render) |

## Tests de robustez (ya existentes — no romper)

Retries/backoff/breaker (`game_retry_test.exs`), combate fantasma
(`ghost_combat_test.exs`), anti-loop PCs (`pc_anti_loop_test.exs`), anti-puppet
DM (`dm_puppet_pc_test.exs`), limbo de exploración (`exploration_limbo_test.exs`),
UTF-8/español (`text_test.exs`), rehidratación tras kill
(`game_sync_genserver_test.exs`). Un cambio en el bucle que pase la suite
rompiendo alguno de estos **no está terminado**.

---

## Protocolo de verificación (antes de declarar "hecho")

```sh
mix compile --warnings-as-errors   # 0 warnings
mix format --check-formatted       # formato limpio
MIX_ENV=test mix test              # 904+ passed, 0 failed
```

Y según la tabla anterior: tests nuevos de la capa que toca, docs actualizados
(`progress.md` mueve el ítem; ADR si hay decisión). Con API key disponible,
opcionalmente: `DRAGONEX_RUN_LIVE=1 OPENROUTER_API_KEY=… mix test --include integration`.

## Límites declarados

- No hay CI que corra la suite en cada push (pendiente de infra; el verde de
  referencia es local). Al añadir CI, este doc es el contrato de qué correr.
- Golden SRD del creador (F6.5): `test/dragonex/heroes/srd_golden_test.exs`
  (12 clases × L1/L3/L5).
