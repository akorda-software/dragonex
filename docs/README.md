# Documentación de Dragonex

> **Documentación viva del proyecto.** Esta carpeta describe qué es Dragonex
> (producto) y cómo está implementado hoy (técnico), alineada con el código real.
> Si una afirmación de estos docs contradice el código, **el código gana**;
> corrige el doc (o abre una decisión en `decisions.md`).

Dragonex es un **DM por IA para D&D 5e**: una aplicación donde uno o varios
personajes (humanos o IA) viven una aventura narrada y arbitrada por un LLM que
**solo narra** — cada tirada, ataque y salvación la resuelve un motor
determinístico de reglas (`deftool`s), así el DM no miente con números.

---

## Mapa de la documentación

| Doc | Qué contiene | Audiencia |
|---|---|---|
| [`producto/00-vision-y-alcance.md`](producto/00-vision-y-alcance.md) | Qué es, para quién, principios de diseño, dentro/fuera de alcance | todos |
| [`producto/01-como-se-juega.md`](producto/01-como-se-juega.md) | El journey del jugador y el bucle de gameplay (nivel producto) | todos |
| [`tecnico/00-arquitectura.md`](tecnico/00-arquitectura.md) | Subsistemas, capas, dirección de dependencias, diagrama | técnico |
| [`tecnico/01-bucle-del-agente.md`](tecnico/01-bucle-del-agente.md) | **El corazón**: trace exacto de un turno (declarar → beat → tools → reglas → World → narración → historial) | técnico |
| [`tecnico/02-modelo-de-datos.md`](tecnico/02-modelo-de-datos.md) | Tablas DB, árbol de structs, frontera `Codec`, invariantes de datos | técnico |
| [`tecnico/03-motor-de-reglas.md`](tecnico/03-motor-de-reglas.md) | `Rules`/`Actions`/`World`: cómo se resuelve 5e, el contrato "el motor es la verdad" | técnico |
| [`tecnico/04-agentes-dm-y-pc.md`](tecnico/04-agentes-dm-y-pc.md) | DM y PCAgent: prompts, tools, guardrails, coherencia entre agentes | técnico |
| [`tecnico/05-mapa-de-modulos.md`](tecnico/05-mapa-de-modulos.md) | Referencia: cada módulo con una línea de responsabilidad | técnico |
| [`tecnico/06-config-modelos-despliegue.md`](tecnico/06-config-modelos-despliegue.md) | Deps, config, runtime, puertos, proveedores LLM, despliegue | técnico |
| [`decisions.md`](decisions.md) | **ADRs** `D1`–`D24`: decisiones de diseño confirmadas y su *porqué* | todos |
| [`progress.md`](progress.md) | **Estado por feature** ✅/🟡/🔴: qué está hecho, qué falta, deudas v1 | todos |
| [`FLUJO_PARTIDA.md`](FLUJO_PARTIDA.md) | Narrativa detallada punta-a-punta de una partida (complemento de `tecnico/01`) | técnico |
| [`historical/`](historical/) | Handoffs/specs de iteraciones pasadas — **archivo, no normativo** | archivo |

El contrato para agentes automatizados vive en **[`../AGENTS.md`](../AGENTS.md)**
(comandos, convenciones que no se rompen). Empieza siempre por ahí.

---

## Órdenes de lectura (por tarea)

No hace falta leerlo todo. Carga el subconjunto que toque:

- **Nuevo en el proyecto** → `AGENTS.md` → `producto/00` → `producto/01` → `tecnico/00`.
- **Implementar una regla/mecánica 5e** → `tecnico/03` + `tecnico/02` + `decisions` D1, D4, D8.
- **Trabajar el agente DM o el PCAgent** → `tecnico/01` + `tecnico/04` + `decisions` D1, D16, D19, D20.
- **Tocar persistencia o el `World`** → `tecnico/02` + `tecnico/06` + `decisions` D3, D5, D6.
- **Añadir contenido custom o tocar el creador de héroes** → `tecnico/05` + `progress` (§ Creador) + `decisions` D9.
- **Arrancar / operar en local** → `../README.md` → `AGENTS.md` → aquí.

---

## Precedencia (cómo resolver conflictos)

En caso de contradicción entre fuentes, gana la más alta en esta lista:

1. **El código** — fuente de verdad última. Un doc que mienta sobre el código es un bug del doc.
2. **`decisions.md`** (ADR vigente) — el *porqué* estructural confirmado.
3. **`AGENTS.md`** — convenciones que no se rompen + comandos.
4. **`docs/tecnico/*`** — cómo está implementado hoy.
5. **`docs/producto/*`** — qué es el producto.
6. **`docs/FLUJO_PARTIDA.md`** — narrativa detallada (complemento).
7. **`docs/historical/*`** — archivo no normativo (jamás citar como autoridad).

> **Si dos fuentes se contradicen y no sabes cuál prima: detente, documenta la
> discrepancia y propón una decisión.** No elijas una en silencio. (Patrón
> tomado de `taket`.)

---

## Fuente canónica (dónde mira la verdad)

Cada conceptos tiene **un único sitio canónico**; el resto enlaza, no replica:

| Concepto | Fuente canónica |
|---|---|
| Estado de una feature | `progress.md` |
| Razón de una decisión estructural | `decisions.md` (ADR `Dn`) |
| Forma de un struct (`Character`/`Weapon`/`Spell`/`Item`) | el struct en `lib/dragonex/` + `Codec` (`codec.ex`) |
| Esquema de DB | las migraciones en `priv/repo/migrations/` |
| Lista de tools del LLM | `Dragonex.Tools` (`tools.ex`) + `Dragonex.DM`/`PCAgent.tools/0` |
| Flujo exacto de un beat | `tecnico/01-bucle-del-agente.md` (respaldado por `game.ex`) |
| Invariante "no se rompe" | `AGENTS.md` § Convenciones + los ADR `D1`–`D9` |

---

## Convenciones de esta documentación

- **Idioma**: español para prosa y producto; identificadores de código en inglés (tal como van en el repo).
- **IDs estables**: las decisiones se citan como `D4`, `D17` (de `decisions.md`). Los subsistemas como `S1`–`S10` (definidos en `tecnico/00`). Los invariantes como `D1`–`D9` (de `AGENTS.md`).
- **Referencias a código**: `archivo.ex:línea` para que un agente o humano salte directo.
- **Drift honesto**: si un doc sabía algo cierto y ya no lo es, lleva una nota de evolución al principio en vez de borrarse (patrón `audible-to-mp3`).
- **`progress.md` dice qué existe; `decisions.md` dice por qué; `tecnico/*` dice cómo.**

---

## Cómo mantenerla

- Al terminar una feature: actualiza `progress.md` (mueve el item entre ✅/🟡/🔴) y, si tomaste una decisión no trivial, añade un ADR a `decisions.md`.
- Al refactorizar: actualiza el `tecnico/*` que describa lo movido **en el mismo cambio**.
- Si doc y código divergen por descuido: prioriza arreglar el doc; si el código estaba mal, arregla el código y deja el doc apuntando a la verdad nueva.
- No edites `historical/` — es archivo.
