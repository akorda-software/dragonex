# Brief de orquestación — noche Dragonex

Prompt operativo para un Run Orca de **toda la noche**. El coordinador pega
el § Objetivo en `run-create` y sigue el resto. No es un ADR ni un backlog
nuevo: es el contrato de esta noche.

Fecha de corte: **2026-09-10**. Repo: `/home/kukapu/dev/projects/dragonex`.
Checkout principal (no worktree). Suite de referencia: **720 passed, 3
excluded**, `mix compile --warnings-as-errors` limpio.

---

## Objetivo (pegar en `run-create --objective`)

Cerrar el pulido F6 de Dragonex esta noche, verificable, sin entrar en F7.

1. Asegurar y commitear el trabajo ya hecho y sin commit (F6.1 condiciones,
   F6.2/D33 banner, F6.3 mesa móvil, F6.4/D34 iniciativa individual).
2. Implementar F6.5: batería golden SRD del creador (12 clases × niveles
   1, 3 y 5; HP/AC/slots/save DC/saves). Discrepancias: bugs se corrigen;
   simplificaciones R09/D12–D15 se documentan, no se “arreglan”.
3. Pase de consistencia de docs (contadores de tests, F6.4/D34, AGENTS.md).
4. Si queda noche: endurecer huecos reales de F6.4/F6.5 con tests. Parar
   cuando F6 esté cerrado o haya un bloqueo que necesite al usuario.

Hecho de la noche: F6.5 marcado en `03-plan-fases.md` + `progress.md`,
suite verde, commits locales por ítem, **sin push**, sin F7, sin ADR
nuevo salvo que un bug de F6.5 lo exija (improbable).

---

## Estado al arrancar (no rehacer)

F0–F5 entregadas. F6.0–F6.4 **hechas en código y tests**, **no commiteadas**.

Working tree sucio (~33 files + 2 untracked): F6.1–F6.4 juntos.

| Ítem | Estado | Evidencia |
|---|---|---|
| F6.0 intents TM (D27) | ✅ en `main` | `eb4ab83` |
| F6.1 condiciones → ventaja | ✅ código, sin commit | `lib/dragonex/rules/conditions.ex` |
| F6.2 banner level-up | ✅ D33, sin commit | `docs/decisions.md` D33 |
| F6.3 mesa ≤720px | ✅ CSS drawer, sin commit | `priv/static/assets/game.css` |
| F6.4 iniciativa/monstruo | ✅ D34, sin commit | `World.current_combatant`, tests loop 3 goblins |
| F6.5 golden SRD | 🔴 siguiente | este brief |
| F7 | **fuera** | exige ADR nuevo; no esta noche |

HEAD: `b8288fd docs: suite verde 622 en FLUJO_PARTIDA` (docs drift viejo).

---

## Cola (orden estricto)

### T0 — Gates de arranque (coordinador, 5 min)

```sh
MIX_ENV=test mix test
mix compile --warnings-as-errors
mix format --check-formatted
git status --short
```

Si la suite no está en 720 verde, no se commitea ni se abre F6.5: se
investiga. Postgres: `127.0.0.1:5455` (`.env.dev`). App **no** hace falta
para tests.

### T1 — Commits del WIP (un worker, checkout principal)

Tres commits locales, `mix format` ya hecho. **No push. No amend de
`b8288fd`.** Mensajes:

1. `feat(rules): condiciones 5e → ventaja/desventaja (F6.1)`
   — `lib/dragonex/rules/conditions.ex`, `lib/dragonex/actions.ex`,
   tests conditions, catálogo M06, R24.
2. `feat(ui): mesa móvil + quitar banner level-up (F6.2/F6.3, D33)`
   — `game.css`, snapshot/show LiveView, D33, R20.
3. `feat(combat): un beat por monstruo (F6.4, D34)`
   — World/Codec/WorldDriven/Turnmaster/Combat/Brief/UI + tests D34 + docs.

Si un archivo mezcla F6.1 y F6.4 (`actions.ex`, `progress.md`,
`03-plan-fases.md`, `09-estrategia-pruebas.md`): ir al commit del ítem
principal y dejar el resto coherente; no pelear el split perfecto.

Aceptación: `git log` muestra los 3; `MIX_ENV=test mix test` sigue verde.

### T2 — F6.5 golden SRD (un worker, área `lib/dragonex/heroes/` + tests)

**Qué es:** auditoría, no feature nueva. Tabla de oráculos escritos a
mano contra SRD 5.1, comparados con `Heroes.build` + `LevelUp.apply`.

**Dónde:** fichero nuevo `test/dragonex/heroes/srd_golden_test.exs`
(no hinchar `sheet_fields_test.exs`). `async: true`, sin DB (D9).

**Matriz mínima (AC F6.5):** 12 clases × {1, 3, 5} = 36 casos.

Clases: barbarian, bard, cleric, druid, fighter, monk, paladin, ranger,
rogue, sorcerer, warlock, wizard.

Fijar inputs para que el oráculo sea estable:

- Raza **human**, sin subraza (ASI +1 todas → números redondos).
- Background **soldier** (o el default de la clase si el builder lo exige).
- Standard array autoasignado por `priority` de la clase (no point-buy).
- Equipment **default** de la clase (primer grupo SRD).
- Skills/spells: defaults del builder (no picks custom).
- Level-up 1→3 y 1→5: ASI en el primario de la clase, 2 puntos, cap 20
  (D13: no hay feats). Paladín/ranger ganan `spellcasting` a L2 (R09).

Por cada ficha asertar, como mínimo:

| Campo | Notas SRD / Dragonex |
|---|---|
| `level` | 1 / 3 / 5 |
| `hp` y `max_hp` | L1: hit_die + CON. Subidas: media del dado (`div(die,2)+1`) + CON (+ racial si aplica). D11: level-up **no cura**; en golden partir de full HP. |
| `ac` | Armadura default + DEX con techo; barbarian/monk unarmored_defense. |
| `saving_proficiencies` | Las 2 de la clase. |
| Spell slots | Full casters / half-casters L2+ / warlock **como full-caster (D12)** — el golden espera el modelo Dragonex, no Pact Magic. |
| Save DC (si caster) | 8 + proficiency + mod de característica de conjuro. |
| `class_features` | L1 del catálogo. **No** exigir features por nivel salvo spellcasting paladín/ranger a L2 (R09). |

**Discrepancia:**

- Bug (HP/AC/slots/saves mal derivados vs SRD, y no cubierto por R09) →
  **arreglar** en `Heroes`/`LevelUp`/`Progression` + test. No tocar la
  forma de `Character`.
- Simplificación declarada (Pact Magic, feats, `spells_known`, features
  por nivel) → **no implementar**. Anotar en el `@moduledoc` del golden
  y, si hace falta, una línea en `progress.md` 🟡. No abrir F7.

Aceptación: 36 casos verdes; F6.5 ✅ en `03-plan-fases.md`; `progress.md`
lo mueve; `09-estrategia-pruebas.md` deja de decir “golden en curso”;
contador de tests actualizado. Commit:
`test(heroes): golden SRD 12 clases × L1/L3/L5 (F6.5)`.

### T3 — Docs drift (mismo worker o uno de docs, tras T2)

Alinear números que aún mienten:

- `AGENTS.md` dice 585 tests → 720+.
- `FLUJO_PARTIDA.md` § Tests dice 622 → 720+.
- `03-plan-fases.md` cabecera 713 y “585+ verde” → 720+.
- `09-estrategia-pruebas.md` cabecera 713 (el protocolo ya dice 720+).

No reescribir historia en `docs/historical/`. Commit:
`docs: alinear contadores y cerrar F6.5`.

### T4 — Solo si T2/T3 verdes y queda noche (no inventar alcance)

Prioridad, parar en el primero que no quepa:

1. Huecos D34 con test que falle o falte de verdad: monstruo que muere
   a mitad de ronda; `join_initiative` de un spawn; `current_combatant`
   nil en world rehidratado viejo. No rediseñar TurnMaster.
2. L4 mínimo de F6.3 si no hay ningún test LiveView del drawer móvil
   (un test, no un rediseño).
3. Nada más. **No F7. No feats. No Pact Magic. No concentración.
   No marketplace. No Horde. No XP.**

Si la cola se acaba: checkpoint, idle, no rellenar horas.

---

## Contratos que no se rompen

Leer `AGENTS.md` entero. En corto:

- Motor = verdad (D1). LLM no calcula.
- Single-writer (D6): LiveView no escribe `Repo`/`games.world`.
- Forma de `Character`/`Weapon`/`Spell`/`Item` intacta; campo nuevo → Codec (D4, D8).
- Codec: `String.to_atom` solo ahí (D8).
- Builder offline, custom inyectado (D9).
- Texto de modelo persistido → `Text.scrub` (D7).
- Package manager: **mix**, nunca npm/npx.
- Tests: **siempre** `MIX_ENV=test mix test`.
- No tocar `docs/historical/`.
- Commits estilo `feat(heroes): …`. `mix format` antes de commit.
- **No push, no PR, no `--force`, no cambiar git config.**
- No instalar, no docker compose down, no tocar `.env*` ni secretos.
- Deps locales: no cambiar `mix.exs` / D26.

F7 (feats, concentración, Pact Magic, multiclase, marketplace, Horde, XP)
**exige ADR nuevo antes de código**. Esta noche no.

---

## Cómo se verifica (todo ítem)

```sh
mix compile --warnings-as-errors
mix format --check-formatted
MIX_ENV=test mix test
```

Una feature está hecha cuando sus AC pasan **y** `progress.md` la mueve —
no cuando existe el commit (`03-plan-fases.md`).

Tocar LLM: smoke con `TestModel`. No gastar `OPENROUTER_API_KEY` para
sondear cuota ni para “ver si narra”. Integración live = opt-in, no esta
noche salvo que el usuario lo pida.

---

## Reparto Orca

- Coordinador: este chat / Run. No implementa fixes de review (reasigna).
- Oleada inicial: **1 worker** (T1). Luego **1 worker** (T2). T3 puede
  ser el mismo. No dos editores sobre `lib/dragonex/heroes/` a la vez.
- Worktree: **checkout principal** (`current`). No crear worktrees.
- Modelo workers: `zai-coding-plan/glm-5.3`. Si no hay cuota:
  `opencode-go/muse-spark-1.3-contributor`. T2 (oráculos SRD, más
  delicado): si GLM duda, `openai/gpt-5.6-sol` medium o `xai/grok-4.6`
  high. No `gpt-6-astra`. No `max`.
- Un implementador investiga + cambia + prueba. Review solo lectura
  independiente **después** de T2 si el diff de Heroes es grande.
- No `MIX_ENV=test mix test` concurrente en el mismo checkout.
- Preguntar al usuario (gate) solo si: hay que entrar en F7, push, o
  un bug de F6.5 exigiría cambiar la forma de `Character`.

---

## Checkpoint (al cerrar bloque / compactar / pausar)

```
Objetivo, T0–T4, qué está ✅ con evidencia (comando + recuento).
HEAD y commits locales de esta noche (hashes).
Suite: N passed / excluded / failed.
WIP activo, archivos, bloqueos, pregunta al usuario.
Siguiente acción exacta. No F7.
```

Guardar en este mismo fichero bajo `## Diario` (append), no en historical.

---

## Diario

- 2026-09-10: brief creado. WIP F6.1–F6.4 sin commit. Siguiente: T0+T1
  cuando el usuario diga «orquesta».
- 2026-09-10 ~21:34Z: Run `run_5452a7e2e6af` arrancado. Usuario: workers
  `xai/grok-4.6` mientras haya cuota; fallback `zai-coding-plan/glm-5.3`
  luego `opencode-go/muse-spark-1.3-contributor`. OpenCode no admite
  `--effort`. T0 ✅ `MIX_ENV=test mix test` → 720 passed, 3 excluded;
  `mix compile --warnings-as-errors` limpio; `mix format --check-formatted`
  OK. HEAD `b8288fd`. WIP intacto (~33 + 2 untracked, incluye este brief).
  Siguiente: T1 commits F6.1–F6.4. No F7.
- 2026-09-10 ~21:41Z: T1 ✅ verificado por coordinador. Commits locales
  `527a23d` F6.1, `65b86c2` F6.2/F6.3, `9a79e53` F6.4. `master` ahead 3,
  sin push. Suite coordinador: 720 passed, 3 excluded. Dispatch
  `ctx_3294341d1f66` released. Siguiente: T2 F6.5 golden SRD. No F7.
- 2026-09-10 ~21:51Z: T2+T3 ✅ coordinador. `d3ce543` golden 36 casos;
  `f0540d6` docs 756. Suite 756 passed / 3 excluded. F6.5 ✅ en
  03-plan-fases y progress. Sin bugs HP/AC/slots/saves; D12–D14 en 🟡.
  HEAD `f0540d6`, ahead 5, sin push. Dispatch `ctx_5850b21680c0` released.
  Siguiente: T4 huecos reales D34 (muerte mid-round, codec nil) + un
  test drawer F6.3 si no existe. No F7.
- 2026-09-10 ~22:02Z: T4 ✅ coordinador. `b259221` D34 mid-round+codec nil;
  `53d108b` drawer Ficha. Suite 758 passed / 3 excluded. join_initiative
  no duplicado. HEAD `53d108b`, ahead 7, sin push. F6 cerrado. Cola
  T0–T4 agotada: checkpoint e idle. No F7. Dispatch `ctx_6763bb842254`
  quedó `retained` (user_takeover); no forzar cierre.
