# Handoff — Fase 4: Creador de personajes 5e (Dragones)

Eres un agente que continúa **Dragones**, un juego de D&D 5e con DM por IA sobre
**exAgent** (Elixir/Phoenix). Tu tarea: implementar el **creador de personajes**
completo y ceñido a las reglas de &D 5e (SRD), **separado** de la capa de
partidas.

---

## 0) Lee esto PRIMERO (sin tocar nada)

1. `ROADMAP.md` — la estrella polar. Tu parte es **Fase 4**.
2. `lib/dragones/character.ex` — **el formato exacto** que debe producir tu
   creador (lee su `embedded_schema`, `changeset/2` y `new/1`).
3. `lib/dragones/{weapon,spell,item}.ex` — la forma de weapons/spells/inventory
   que lleva un `Character`.
4. `lib/dragones/archetypes.ex` y `lib/dragones/monsters.ex` — **ejemplos
   canónicos** de personajes 5e nivel 1 válidos y completos (fíjate cómo se
   rellenan hp/ac/weapons/spells/saving_proficiencies). Son tu referencia de
   "personaje correcto".
5. `lib/dragones/codec.ex` — cómo el `Character` ↔ jsonb (tu salida debe
   sobrevivir este round-trip).
6. `lib/dragones/scenario.ex` (`catalog/0`) y `lib/dragones/games.ex`
   (`create_from_wizard/1`) — cómo la capa de **partidas** consume hoy los
   personajes predefinidos. Tu creador debe poder alimentar este punto, pero
   **sin acoplarse** a él.
7. `lib/dragones/rules/` (`Ability`, `Combat`) — las reglas que **leen** los
   stats del personaje. Tu creador debe poblarlos de forma que estas reglas
   computen resultados 5e correctos (modificadores, AC, save DC, etc.).

Arranca el stack y deja verde la base antes de cambiar nada:
`docker start infra-postgres-1` → `mix compile` →
`MIX_ENV=test mix test` (debe dar **135 passed, 3 excluded**).

---

## 1) El principio rector: SEPARACIÓN

> **Una cosa es crear personajes; otra es jugar partidas.**

El creador es un **módulo/contexto propio** que **no sabe nada** de partidas,
sesiones, DM ni LiveView. Su único contrato de salida es:

> Producir un `Dragones.Character` **válido, completo y 5e-correcto**.

La capa de partidas ya existe y ya consume `Character` (vía `Roster.catalog` →
`Games.create_from_wizard`). **No la rompas**. Cuando tu creador esté listo, el
único punto de integración será que el wizard pueda ofrecer personajes creados en
lugar de (o además de) los archetypes hardcoded — pero eso es **el último paso**,
opcional, y se hace tocando `scenario.ex`/el LiveView del wizard, **no** tu
módulo de creación.

Sugerencia de ubicación: `lib/dragones/heroes/` con un contexto
`Dragones.Heroes` (datos 5e + lógica de build). Nada de esto vive bajo
`games/`, `game/` ni `dragones_web/`.

---

## 2) El formato de salida EXACTO: `Dragones.Character`

Tu creador debe devolver un `%Dragones.Character{}` con **todos** estos campos
poblados de forma coherente con 5e (mira `archetypes.ex`):

```
name, race, class, side, level         # side es "pc" para personajes de jugador
hp, max_hp, temp_hp, ac, speed          # stats derivados (ver §4)
str, dex, con, int, wis, cha            # 6 puntuaciones (3–20 tras bonus de raza)
backstory                               # texto libre
weapons      :: [Dragones.Weapon{}]     # name, dice("1d8"), damage_type,
                                        #   attack_ability(:str|:dex|...),
                                        #   finesse, ranged
spells       :: [Dragones.Spell{}]      # name, level, kind(:save|:attack|:automatic),
                                        #   casting_ability, save_ability (si :save),
                                        #   dice, damage_type, effect
inventory    :: [Dragones.Item{}]       # name, qty, kind(:armor|:weapon|:gear|...)
conditions   :: []                      # vacío al crearse
death_saves  :: %{successes: 0, fails: 0}
saving_proficiencies :: [String.t()]    # ej ["str","con"] — de la CLASE
```

**Invariante**: el `Dragones.Character.changeset/2` debe pasar **sin errores**
(nombre+class required, level 1–20, hp/max_hp/ac ≥ 0, abilities 1–20). Y el
`Codec.encode/decode` debe round-trip tu personaje sin perder nada (hay test de
codec — extiéndelo si añades formas nuevas).

---

## 3) Alcance 5e (SRD) — qué cubrir

Cubre el **SRD 5.1** (contenido abierto). Nivel **1** como objetivo principal
(pero la maquinaria de derivación no debe asumir "siempre 1": deja `level`
parametrizable; los PCs empiezan a nivel 1).

**Razas** (con bonus de puntuación, speed, size, traits de nivel 1; incluye
subrazas cuando aplique):
Dwarf (Mountain/Hill), Elf (High/Wood/Dark), Halfling (Lightfoot/Stout),
Human (variant opcional), Dragonborn, Gnome (Forest/Rock), Half-Elf, Half-Orc,
Tiefling.

**Clases** (con hit die, primary ability, saving-throw proficiencies, skills
elegibles nº, equipo inicial, y features/spells de nivel 1):
Barbarian, Bard, Cleric, Druid, Fighter, Monk, Paladin, Ranger, Rogue,
Sorcerer, Warlock, Wizard.

**Backgrounds** (sklls extra + equipo): Acolyte, Criminal, Folk Hero, Noble,
Sage, Soldier, Charlatan, Entertainer, Guild Artisan, Hermit, Outlander, Sage,
Sailor, Urchin (un buen subconjunto SRD es suficiente; documenta cuáles).

**Generación de puntuaciones**: soporta al menos **standard array**
(15,14,13,12,10,8) y **point buy** (27 puntos, 8–15 pre-raza). El resultado
tras aplicar bonus de raza debe quedar en 1–20.

> No inventes números: cada stat derivado debe poder justificarse con una regla
> 5e (mira `Dragones.Rules.Ability` y `Rules.Combat` para ver cómo los lee el
> motor).

---

## 4) Reglas de derivación (lo importante)

El creador **calcula** los stats a partir de las elecciones — no pide hp/ac al
usuario. Derivaciones 5e obligatorias:

- **Modifier**: `floor((score - 10) / 2)` (usa `Dragones.Rules.Ability.modifier/1`).
- **HP (nivel 1)**: `hit_die_max + con_mod` (hit_die_max = el valor máximo del
  dado de golpe de la clase, ej fighter d10 → 10).
- **AC**: según armadura inicial — `10 + dex_mod` (sin armadura), `11 + dex_mod`
  (leather), etc.; para mage armor/hechizos refléjalo. Documenta qué armadura
  inicial da cada clase/equipo.
- **Speed**: de la raza.
- **Saving proficiencies**: de la **clase** (ej fighter → str,con).
- **Skill proficiencies**: nº de la clase + background (elige un set válido o
  deja que el usuario escoja de la lista permitida).
- **Spellcasting** (sólo casters — bard/cleric/druid/sorcerer/warlock/wizard,
  +pala/ranger si aplica a nivel 1):
  - `casting_ability` = la stat del caster (ej wizard→int, cleric→wis, sorcerer→cha).
  - Hechizos de nivel 1 conocidos/preparados según la clase (cantrips + lvl-1).
  - Cada `Spell` debe traer `kind`/`casting_ability`/`save_ability`/`dice`/...
    Usa `Dragones.Spell` (mira `archetypes.ex`: firebolt/magic_missile/shield).
- **Weapons**: del equipo inicial de la clase; cada `Weapon` con
  `attack_ability` correcta (ranged→dex; finesse→lo maneja el motor con
  max(str,dex); melee→la stat de la clase).

Importante: el motor (`Rules.Combat`) ya sabe computar attack rolls, damage,
saves y spell DC **a partir del Character**. Tu trabajo es que esos campos
estén bien puestos; **no dupliques** la lógica de combate.

---

## 5) Entregables

1. **Datos 5e** (`lib/dragones/heroes/`): módulos de datos puros con razas,
   clases, backgrounds, equipo/hechizos iniciales. Datos como mapas/structs
   declarativos, sin estado. Documenta la fuente (SRD 5.1).
2. **Builder** (`Dragones.Heroes.build/1` o similar): dadas las elecciones
   (raza, subraza, clase, background, método+valores de puntuaciones, equipo/spell
   picks), devuelve un `Dragones.Character` **validado** (que pasa el changeset).
   Derivación pura y testeable.
3. **Validación 5e**: que las elecciones sean legales (raza existe, clase existe,
   skills dentro de la lista, nº de skills correcto, puntuaciones en rango,
   alineamiento válido, etc.). Usa/extend `Character.changeset`.
4. **(Opcional, último)** Integración con el wizard: que `Roster.catalog`/
   `create_from_wizard` pueda nutrirse de personajes creados. Mínimo impacto.

No construyas UI en esta iteración salvo que sobre tiempo; el foco es el
**motor de creación** (datos + builder + derivación + tests). Si haces UI, va en
`dragones_web/` y consume `Dragones.Heroes`.

---

## 6) Tests (obligatorios)

Cubre con tests offline (deterministas, sin LLM):

- **Canonicalidad**: para **cada clase** del catálogo, `Heroes.build(...)`
  produce un `Character` que pasa el changeset y cuyos stats derivados son los
  esperados (ej: fighter nivel 1 con con 14 → hp 11 o 12 según raza/bonus; wizard
  → int es la casting_ability; etc.). Compara contra los valores SRD.
- **Round-trip Codec**: un personaje creado sobrevive `Codec.encode→decode`.
- **Integración con el motor**: un personaje creado, puesto en un `World`, puede
  ser atacado / lanzar un hechizo a través de `Dragones.Actions` sin errores y
  con resultados coherentes (puedes reusar el patrón de
  `test/dragones/flows/combat_test.exs`).
- **Validación**: elecciones ilegales (raza inexistente, puntuación fuera de
  rango, skill no permitida) son rechazadas.

Usa el runner del proyecto: `MIX_ENV=test mix test`. No rompas los 135 tests
existentes.

---

## 7) Restricciones y convenciones (no las rompas)

- **Elixir/Phoenix**, package manager **mix** (NUNCA npm aquí). Tests SIEMPRE con
  `MIX_ENV=test mix test`.
- **No toques el motor** (`Rules`, `World`, `Actions`, `Tools`, `DM`,
  `TurnPolicy`, `Codec`). El `Character`/`Weapon`/`Spell`/`Item` **mantienen su
  forma** — tu creador los llena, no los cambia.
- **Separación estricta**: nada de `Dragones.Heroes` importa de `games/`/`game/`/
  `dragones_web/`. Si necesitas un `Character`, lo produces y lo devuelves; el
  consumidor decide qué hace con él.
- Sigue el estilo del repo (módulos con `@moduledoc`, `@spec`, datos
  declarativos, tests offline deterministas).
- Si encuentras fricción en **exAgent** (path dep `../exAgent`), puedes
  arreglarla in-situ, pero no es lo esperado aquí — tu trabajo es 100% en
  `dragones`.

---

## 8) Criterio de "hecho"

- Para **cada clase y raza** del SRD listado, `Dragones.Heroes` puede construir un
  `Dragones.Character` nivel 1 **válido y completo** (pasa changeset, stats
  derivados 5e-correctos, weapons/spells/equipo coherentes).
- El personaje entra limpio en el motor: `Actions.attack`/`Actions.spell` sobre
  él funcionan y dan resultados 5e.
- `MIX_ENV=test mix test` en verde (135 previos + los nuevos de creación).
- Un script `priv/build_hero.exs` (o test) que construya, p.ej., un "elf wizard
  sage" y un "dwarf fighter soldier" y los imprima, demostrando que todos los
  campos quedan bien.

Entrega el contexto de qué hiciste y qué falta (p.ej., subrazas cubiertas,
backgrounds, si dejaste UI para después). Deja la bola lista para integrar el
creador con el wizard.
