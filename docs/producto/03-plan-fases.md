# Plan por fases

> **Producto.** Historial de fases entregadas y, sobre todo, el **backlog
> accionable** de lo que falta. Cada ítem pendiente referencia su requisito
> (`Rxx` de [`02-requisitos.md`](02-requisitos.md)), su definición de "hecho"
> y su receta de verificación. **Un agente puede tomar cualquier ítem de F6/F7
> y trabajar hasta verde sin más contexto que ese ítem + sus docs enlazados.**

Regla de oro (de [`../progress.md`](../progress.md)): una feature está hecha
cuando 1) tiene tests deterministas (o smoke si toca LLM), 2) `MIX_ENV=test
mix test` está verde, 3) su decisión está en `decisions.md` si es no trivial,
4) no deja TODO/FIXME sin dirección. **No se marca hecha por "el commit
existe" sino por "se verifica".**

---

## Fases entregadas ✅ (resumen; el detalle vive en `../progress.md`)

| Fase | Hito | Entregables clave |
|---|---|---|
| F0 — Spike exAgent | "encaja" (`FINDINGS.md`) | 10 flujos, validación de Session/TurnPolicy/tools |
| F1 — Motor 5e | El motor manda | `Rules`+`Actions`+`World`+`Tools`+`Dice`, WorldDriven |
| F2 — Partida durable | Jugar y sobrevivir | `Game` GenServer (D5), persistencia por beat (D3/D4), Codec (D8) |
| F3 — Robustez | Nunca se rompe | retries+breaker (D17), combate fantasma (D18), history compartido (D19), anti-loops |
| F4 — Héroes | Forjar y crecer | Builder 5 pasos + catálogos SRD ES + custom (D22) + level-up (D10–D13) |
| F5 — TurnMaster | La partida fluye | Orquestador de turnos (D25) con fallback WorldDriven |

Verde de referencia hoy: **566 tests passed**, compile sin warnings.

---

## F6 — Pulido del producto (backlog activo)

Orden sugerido por valor/esfuerzo. Cada ítem es autónomo.

### F6.1 — Automatismos de condición → ventaja (R24 🟡→✅)

**Qué**: hoy `adjust_mode_for_conditions` aplica ventaja/desventaja por
condición en **ataques** (`Rules.Combat.attack_roll`). Falta extender el mismo
principio a `saving_throw` y `ability_check`: p.ej. poisoned → desventaja en
checks y saves de STR/DEX (RAW), prone → desventaja en ataque *desde* prone,
blinded → desventaja general, paralyzed/unconscious → ventaja de los atacantes
contra el objetivo (esto último puede requerir tocar `Actions.attack`).

**Dónde**: `lib/dragonex/rules/combat.ex`, `lib/dragonex/actions.ex`
(`adjust_mode_for_conditions` es el punto de extensión), tests en
`test/dragonex/rules/combat_test.exs` + `actions_test.exs`.

**Hecho cuando**:
- AC-1: tabla de mapeo condición→(efecto en attack/save/check) documentada en
  `08-catalogo-mecanicas` (M6 extendida) y cubierta por tests por condición.
- AC-2: la cancelación 5e (ventaja+desventaja=normal) se mantiene en todos los
  caminos.
- AC-3: suite verde, sin cambios en el contrato de tools (`07-contrato-tools`).

### F6.2 — Banner de level-up en la mesa (decisión abierta → resolver)

**Qué**: `viewer_level_up` en `GameLive.Show` está gateado por XP que nunca
llega (milestone D10) → nunca se muestra. Decidir: (a) eliminar el banner, o
(b) cablearlo a un flag "DM granted" (el DM ya puede `level_up` a PCs IA; para
humanos haría falta una señal del DM o del propio jugador).

**Hecho cuando**: hay ADR en `decisions.md` que cierra la alternativa elegida
(y el código refleja la decisión). Es una decisión de producto pequeña — no
necesita más de un párrafo de ADR.

### F6.3 — Mesa responsive (R20 🔴)

**Qué**: la mesa es un grid 3-col que no reflowea en móvil. Diseñar layout
apilado (feed primero, ficha colapsable, dice modal ya es overlay). Sólo CSS +
quizá `pending_prefers_reduction` de LiveView para reordenar; **cero lógica**.

**Hecho cuando**:
- AC-1: a 375px de ancho el feed es usable (input visible, sin scroll
  horizontal), la ficha se abre/cierra, los dados se ven.
- AC-2: sin regresiones a ≥1024px (tests LiveView existentes verde).
- AC-3: nota en `tecnico/00-arquitectura` si cambia la estructura de
  componentes.

### F6.4 — Iniciativa individual por monstruo (R28 → requiere mini-ADR)

**Qué**: hoy todos los enemigos colapsan en el turno del DM (dedup en
WorldDriven). Dar a cada monstruo su slot de iniciativa (manteniendo el DM
como su *controlador*).

**Ojo**: interacciona con `acted_this_round` y con el TurnMaster (su brief
muestra el orden; los mini-turnos de monstruos deben seguir fluyendo). Es la
feature pendiente más "calada" de F6: tocar `world.ex` (initiative_order ya es
por nombre → los monstruos YA tienen entrada propia si su nombre entra al
orden; el colapso es política), `turn_policy/world_driven.ex` y el brief.

**Hecho cuando**:
- AC-1: ADR que fija la semántica (¿un beat por monstruo o un beat del DM que
  los recorre?).
- AC-2: 3 monstruos con iniciativa distinta actúan en su orden, el DM narra
  cada uno; TurnMaster sigue respetando el orden con `cut_in` disponible.
- AC-3: tests de loop (`turn_master_loop_test.exs` estilo) + flows de combate
  multi-monstruo verde.

### F6.5 — Pase de fidelidad SRD del creador (auditoría)

**Qué**: verificación sistemática de los derivados del builder contra el SRD
(HP/AC/slots/save DC/proficiencias por clase-raza nivel 1 y en level-ups
muestra 2/3/4/5). No es implementar nada: es una **batería de tests golden**
con fichas esperadas escritas a mano del SRD.

**Hecho cuando**: tabla de casos golden en
`test/dragonex/heroes/sheet_fields_test.exs` (o fichero nuevo) cubriendo las
12 clases × {nivel 1, 3, 5} mínimo; discrepancias encontradas se reportan como
ítems propios (o se corrigen si son bugs).

---

## F7 — Fuera de v1 (requieren ADR nuevo para entrar)

Cada uno cierra una simplificación declarada (`02-requisitos` R09/R28):

- **Feats** (D13): catálogo + integración en ASI (elección feat vs +2).
- **Concentración / temp_hp / resistencias**: mecánicas de motor nuevas
  (`M23+`), tocan `Character`/`Codec`/`Actions`.
- **Pact Magic del warlock** (D12): tabla propia de slots short-rest.
- **Multiclase**: fuera del builder actual por diseño; implicaría rehacer
  progression.
- **Marketplace de contenido custom** (D22): compartir entre usuarios.
- **Multi-nodo** (D24, pausada): Horde/HA.
- **XP como fuente de level-up** (D10): la infraestructura (`grant_xp`,
  `can_level_up?`) está latente; cablear requiere decidir quién otorga XP.

---

## Cómo trabaja un agente sobre este plan

1. Elige un ítem (F6.x recomendado; F7 exige ADR primero).
2. Lee el requisito `Rxx` enlazado + los docs técnicos que toque
   (`08-mecánicas`, `07-tools`, `tecnico/01` si cambia el bucle).
3. Implementa con tests (ver [`../tecnico/09-estrategia-pruebas.md`](../tecnico/09-estrategia-pruebas.md)
   para qué capa de test exige cada cambio).
4. Verifica: `mix compile` (0 warnings) → `mix format` → `MIX_ENV=test mix test`
   (566+ verde). Si toca prompts/agentes: smoke con TestModel incluido.
5. Actualiza `../progress.md` (mueve el ítem) y este doc (marca el ítem). Si
   tomaste una decisión no trivial: ADR en `../decisions.md`.
6. Commit estilizado (`feat(motor): …`, `fix(hero): …`).
