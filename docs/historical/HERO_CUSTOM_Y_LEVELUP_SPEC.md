# Spec — Contenido custom por usuario + Subida de nivel en partida

Especificaciones para implementar las dos próximas features del creador de
héroes / partidas de **Dragonex**. Doc autocontenida: incluye contexto del
estado actual, objetivos, diseño, modelo de datos, integración, criterios de
aceptación y **decisiones abiertas** que el usuario debe confirmar antes de
empezar.

Stack observado: Elixir 1.20, Phoenix 1.8.8, LiveView 1.2.3, Ecto 3.14, Postgres
(`mix.exs` mantiene rangos `~> 1.7`/`~> 1.0`; `mix.lock` fija las versiones actuales).
Package manager: **mix** (NUNCA npm). Tests: `MIX_ENV=test mix test` (actualmente
**435 passed**). Arranque: `docker compose -f compose.dev.yml up -d` (levanta Postgres + app en `http://localhost:4035`).

---

## 0) Leer primero (estado actual relevante)

- **Creador de héroes** (`Dragonex.Heroes` + `lib/dragonex/heroes/`): builder puro
  nivel 1 → `Dragonex.Character`. Flujo UI en `DragonexWeb.HeroLive.New` (5 pasos).
- **`Dragonex.Heroes.Catalog`** (`lib/dragonex/heroes/catalog.ex`): **única capa de
  display/consulta** del catálogo. Contrato previsto: `source: :builtin | :srd |
  :custom`. Hoy todas las funciones públicas devuelven `source: :builtin`; los
  hechizos SRD sí traen `source: :srd` desde `SRDSpells`, pero `Catalog.spells/2`
  y `spells_for_class/2` todavía lo descartan. Antes de añadir custom, preservar
  `Map.get(data, :source, :builtin)`. Funciones: `races/classes/backgrounds/spells/
  weapons/armors/equipment_for_class` + `*_label/2`.
- **Hechizos**: `Dragonex.Heroes.Spells` (builtin, 42) + `Dragonex.Heroes.SRDSpells`
  (319 cargados en compilación desde `priv/srd/spells.es.json`). Merge en
  `Spells.all/0` (builtin gana en duplicados). El importer es
  `scripts/import_srd_spells.py`.
- **`Dragonex.Character`** (`lib/dragonex/character.ex`): schema embebido. Campos
  relevantes: `weapons/spells/inventory` son `{:array,:map}` (llevan structs
  `Weapon`/`Spell`/`Item` en runtime, JSON-portables vía `Dragonex.Codec`).
  También: `skill_proficiencies`, `languages`, `racial_traits`, `class_features`,
  `background_feature`, `level` (1–20), `saving_proficiencies`.
- **Motor de partida**: `Dragonex.World` (estado), `Dragonex.Game` (GenServer por
  partida), `Dragonex.Actions` (intención→reglas→world), `Dragonex.Tools`
  (`deftool`s que el DM/PC IA llaman), `Dragonex.DM`, `Dragonex.Rules.Combat`.
- **`World.level_up/1`** ya existe: sube nivel, suma PG (dado golpe medio + CON),
  refresca huecos (`SpellSlots.for_class/2`). **No** añade hechizos ni ASI. También
  existe `Tools.level_up/2`, que hoy llama a `World.level_up/1` sin opciones.
- **Persistencia**: `heroes` (por user, `sheet` jsonb), `games`, `characters`
  (baseline estática por partida), `participants`, `game_events`; el estado vivo
  de la partida está en `games.world` vía `Codec`. Auth: `Dragonex.Accounts`,
  `DragonexWeb.UserAuth`. Cada `Hero` pertenece a un `User`.

---

# FEATURE A — Contenido custom por usuario

## A.1 Objetivo

Un usuario puede **crear armas, hechizos y objetos** que no existen en el SRD
("cosas muy locas"), guardarlos en su biblioteca personal, **asignarlos a sus
héroes** en el editor, y que **esos héroes los lleven a las partidas** donde el
contenido queda disponible para el DM/motor.

**No-objetivos (descartados de momento):** compartir contenido entre usuarios,
marketplace, contenido global de administrador (se podría añadir después reusando
el mismo modelo con `user_id: nil`).

## A.2 Decisiones abiertas (confirmar con el usuario antes de codificar)

1. **¿Tipos de contenido custom en la v1?** Recomendado: **armas, hechizos,
   objetos (items: equipo, consumibles, objetos mágicos)**. ¿También armaduras?
   Recomendado dejar armaduras fuera de la v1: afectan CA y requieren integrar
   `Equipment.armor/1`/`compute_ac` o añadir una ruta custom equivalente.
2. **¿Niveles de hechizo custom?** Recomendado: permitir **cualquier nivel 0–9**
   (no solo nivel 1). El creador de héroe solo ofrece 0/1, pero en partida un
   héroe de nivel alto podría llevar un hechizo custom de nivel 3.
3. **¿Límite por usuario?** Recomendado: sin límite de entrada; vigilar abuso.
4. **¿Validación estricta de mecánicas?** Recomendado: el formulario valida que
   `dice` sea expresión válida (`Rules` la parsea), `kind` ∈ save/attack/automatic,
   `save_ability` ∈ las 6, etc. No inventar equis; el usuario mete los números.

## A.3 Modelo de datos

Una **única tabla** polimórfica por simplicidad y porque las tres entidades son
pequeñas:

```sql
CREATE TABLE custom_contents (
  id           BIGSERIAL PRIMARY KEY,
  user_id      BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL CHECK (kind IN ('weapon','spell','item')),
  key          TEXT NOT NULL,          -- slug estable, lowercased, único por (user_id, kind, key)
  name_es      TEXT NOT NULL,          -- label ES (y name_en opcional para futuro EN)
  definition   JSONB NOT NULL,         -- mecánicas (ver A.4)
  notes        TEXT,                   -- descripción/flavor libre del usuario
  inserted_at  TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
  updated_at   TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
  UNIQUE (user_id, kind, key)
);
CREATE INDEX custom_contents_user_idx ON custom_contents(user_id, kind);
```

Usar `timestamps(type: :naive_datetime)` para alinear con las tablas existentes.
`Accounts.User` y `Accounts.Hero` ya existen (no tocar salvo `has_many`/assoc; en
`User`, `has_many(:custom_contents, Dragonex.Accounts.CustomContent)`).

**Módulos nuevos** (`lib/dragonex/accounts/`):
- `Dragonex.Accounts.CustomContent` (schema Ecto).
- `Dragonex.Accounts` gana funciones: `list_custom_content(user, kind)`,
  `create_custom_content(user, attrs)`, `update_custom_content/2`,
  `delete_custom_content/1`, `get_custom_content/2`.

## A.4 `definition` JSONB por kind

Reusar la forma de las structs del motor para que encajen con conversión mínima:

- **weapon** → `%{dice, damage_type, attack_ability, finesse, ranged}` (igual que
  `Dragonex.Weapon`). Ej: `{"dice":"2d6","damage_type":"fire","attack_ability":"str","finesse":false,"ranged":false}`.
- **spell** → `%{level, kind, save_ability, dice, damage_type, effect, classes}`
  (igual que `Dragonex.Spell` SIN `name` ni `casting_ability`; `name` sale de
  `key`, `casting_ability` lo fija la clase al asignarlo). `classes` debe ser una
  lista de class keys (`["wizard", "sorcerer"]`, etc.) para que
  `spells_for_class` pueda filtrar sin ofrecer cualquier custom a cualquier clase.
  El `effect` va en español (lo escribe el usuario).
- **item** → `%{qty, kind}` donde `kind` ∈ `gear|armor|ammo|focus|consumable|magic`
  (igual que `Dragonex.Item`, que hoy solo tiene `name/qty/kind`). Para objetos
  mágicos con efecto mecánico, o bien guardar el texto en `notes` para la v1, o
  añadir explícitamente `effect` a `Dragonex.Item` **y** a `Codec` antes de usarlo
  en motor/UI.

El `definition` viene de JSONB con claves string; normalizar a atoms solo al construir
`Weapon`/`Spell`/`Item`. El motor consume structs, no el JSON crudo.

## A.5 Integración con el `Catalog` (la pieza clave)

`Catalog` es el seam. Hoy mezcla builtin + SRD, aunque aún marca todo como
`:builtin` en sus salidas. Añadir `:custom` así:

- Primero preservar `:srd` en hechizos (`source: Map.get(data, :source, :builtin)`) y
  actualizar el test que hoy afirma que todos los spells son builtin.
- `Catalog` gana un parámetro de contexto **inyectado**, no una consulta DB interna.
  Recomendado: `weapons(locale \\ I18n.locale(), opts \\ [])`, `spells(locale, opts)`,
  `spells_for_class(class_key, locale, opts \\ [])`, etc., donde `opts[:custom]` es
  `%{weapons: [...], spells: [...], items: [...]}` ya precargado por LiveView/Accounts.
  Con `custom: nil` o `%{}` devuelve solo builtin+SRD, así los tests `async: true` y
  el builder offline no tocan DB.
- `Catalog.spell_label/2`, `weapon_label/2` e `item_label/2` necesitan una variante
  con contexto (`*_label(entry, locale, opts)`) o una resolución desde snapshot para
  poder mostrar `name_es` custom. Sin contexto deben seguir cayendo a la key.
- **`Weapon`/`Spell`/`Item` structs**: el `name` interno pasa a ser la `key`
  (incluye las custom). El display usa `Catalog.*_label`.

El **builder** (`Dragonex.Heroes.build/1`) recibe ya `equipment_picks`, `spells`,
etc. como keys. Para que un héroe lleve contenido custom, el builder solo necesita
que esas keys existan en los datos inyectados del usuario. **Ojo**: hoy
`process_equipment/1` solo resuelve equipo inicial builtin con `Equipment.weapon/1`
y `Equipment.armor/1`; no hay campo para “añadir un arma/item arbitrario” al héroe.
Recomendado:

- `Heroes.build/1` acepta `custom: %{weapons: ..., spells: ..., items: ...}`
  pre-cargado por LiveView desde DB.
- `build_spells/2` mira primero en custom y luego en `Spells.get/1`, respetando
  `classes` y nivel.
- Añadir choices explícitos para contenido extra, por ejemplo
  `extra_equipment: %{weapons: [key], items: [%{key: key, qty: n}]}`; el builder
  los convierte a `eq.weapons`/`eq.inventory` después del equipo inicial. No meter
  lecturas DB dentro del builder.

## A.6 UI

- Ruta nueva **`/mi-contenido`** (`DragonexWeb.CustomContentLive`): galería con
  las tres pestañas (Armas / Hechizos / Objetos), botón "crear", forms de edición.
  - Forms reutilizan el patrón del hero creator (chips, validación en vivo).
  - Cada form valida mecánicas (dados parseables, etc.) antes de guardar.
- **Editor de héroe**: en los pasos Equipo/Hechizos/Inventario, además de las
  opciones builtin/SRD, aparecen las custom del usuario (marcadas con una
  insignia "custom"). Para armas/objetos, decidir si se añaden como equipo extra
  (`extra_equipment`) o si pueden sustituir una opción de equipo inicial; v1
  recomendada: añadir como extra para evitar reescribir los grupos SRD.
- **Permisos**: solo el dueño edita/borra. En partida, otros jugadores pueden
  *ver* el contenido custom del héroe (a través de la ficha) pero no editarlo.

## A.7 Integración con partidas (importante)

Cuando un héroe con contenido custom entra en una partida:
- Su `sheet` (jsonb) ya contiene las armas/hechizos/items custom (con sus keys y
  mecánicas embebidas en los maps). **El motor (`Rules`, `Actions`, `Tools`) los
  consume sin cambios** porque opera sobre structs, no sobre el catálogo.
- Al crear/unirse a una partida, esa sheet se copia al baseline `characters.sheet`
  y al `games.world` vivo. La partida debe leer siempre el `games.world` vivo para
  estado mutable; `characters.sheet` queda como snapshot/base.
- **Sincronización**: si el usuario edita una definición custom *después* de que
  el héroe esté en partida, ¿se actualiza? Recomendado: **NO** automáticamente
  (la sheet es una snapshot). Documentar que editar custom no afecta a partidas
  en curso (igual que cambiar un héroe no cambia partidas activas).
- El `DM`/IA no necesita saber que es custom: ve `weapons`/`spells` como siempre.
  Opcional: en el `world_brief` marcar los objetos custom con `(custom)` para que
  el DM los narre con coherencia.

## A.8 Criterios de aceptación

- Un usuario crea un arma custom "Espada Llameante" (2d6 fuego) → aparece en su
  biblioteca → puede equipársela a un héroe nuevo → el héroe la lleva en la ficha
  con sus dados → en partida puede atacar con ella y `Rules.Combat` calcula el
  daño fuego correctamente.
- Ídem para un hechizo custom de nivel 3 y un objeto mágico custom (con efecto en
  `notes` si no se extiende `Item`).
- Otro usuario NO ve ni puede usar el contenido ajeno.
- Tests: `CustomContent` CRUD, merge en `Catalog` con `source: :custom`, builder
  con `custom: %{...}` + `extra_equipment` produce un `Character` válido,
  round-trip `Codec`.
- `MIX_ENV=test mix test` sigue verde.

---

# FEATURE B — Subida de nivel en partida

## B.1 Objetivo

Cuando un personaje sube de nivel **dentro de una partida**, aplicar no solo PG +
huecos (ya hecho) sino también **las elecciones del jugador**: hechizos nuevos,
**mejora de característica (ASI) o dote** a niveles 4/8/12/16/19, y desbloquear
conjuración en clases que la ganan tarde (paladín/explorador a L2, subclases a L3).

## B.2 Decisiones abiertas (confirmar con el usuario antes de codificar)

1. **¿Sistema de progresión?** Opciones:
   - (a) **Por hito (milestone)**: el DM decide "subes a nivel N". Más simple,
     encaja con un DM por IA. **Recomendado.**
   - (b) **XP**: requiere tabla de XP/encuentro, contabilidad, CR de monstruos.
     Mucho más trabajo.
2. **¿Quién dispara la subida?** Recomendado: el **DM (IA)** vía tool
   `level_up(target, options)` donde `options` lleva las elecciones del jugador
   (o el DM propone y el jugador confirma por chat). Alternativa: botón en la UI
   del jugador humano "subir de nivel" cuando el DM lo autorice.
3. **¿Elecciones automáticas o manuales?**
   - Hechizos nuevos al subir: ¿los elige el jugador (UI) o el DM/IA propone?
     Recomendado: **jugador elige** vía un modal; el DM/IA solo dispara.
   - ASI/dote a L4/8/...: el jugador elige (+2 a una característica, +1 a dos, o
      una dote). Recomendado: **solo ASI en la v1** (dotes requiere catálogo de
      feats — dejar para después).
4. **¿Preparar hechizos (cleric/druid/paladin) vs conocerlos (wizard/sorcerer)?**
   En la v1: simplificar a "el personaje añade X hechizos a su lista conocida/
   preparada". El motor ya no distingue estrictamente al almacenar `spells`.

## B.3 Modelo de progresión (lo que ya está, lo que falta)

**Ya automático** (`World.level_up/1` + reglas derivadas):
- Nivel +1, PG (dado medio + CON), tope nivel 20.
- Huecos de conjuro refrescados (`SpellSlots.for_class/2`).
- Bonificador de competencia (derivado de nivel en `Rules.Ability.proficiency/1`).
- CD de salvación y ataque de conjuro (derivados).
- El builder también calcula PG para `level > 1`, pero sigue documentado como
  nivel 1 para elecciones: spells/features/equipo no escalan por nivel.

**Falta (la feature):**
- **Hechizos al subir**: nº por clase/nivel (ej. mago +2 hechizos/nivel en el
  grimorio; bardo/hechicero según tabla). Definir tabla
  `Dragonex.Heroes.Progression.spells_known(class, level)`.
- **Trucos al subir**: algunas clases ganan un truco a niveles concretos.
- **Conjuración desbloqueada**: paladín L2, explorador L2 → ganan `spellcasting`
  feature + hechizos iniciales. Monge L2 (Ki), L3 (subclase). Definir
  `class_features_per_level`.
- **ASI** a L4/8/12/16/19: +2 pts a repartir en características (máx 20).
- **Clases de conjurador**: desbloquear hechizos de nivel superior (ej. mago L3
  puede llevar hechizos de N2). El picker ya filtra por nivel — reusar.

## B.4 Flujo de subida de nivel (UI)

Nuevo modal/step en `DragonexWeb.GameLive.Show` (la mesa), disparado cuando el
`Game` notifica que un PC sube (vía PubSub, igual que otros eventos):

1. **Resumen**: "¡X ha subido a nivel N!" + delta automático (+PG, +huecos, +comp.
   si toca). El jugador ve qué es automático.
2. **Elecciones** (solo las que aplican a esa clase/nivel):
    - **Hechizos nuevos**: picker (extiende `Catalog.spells_for_class`, que hoy
      devuelve solo `cantrips` + `level1`, con `max_spell_level:` o crea una
      función nueva para progreso). Filtra por nivel ≤ nuevo nivel de conjuro.
      Cupo según `spells_known`/decisión de preparadores.
   - **ASI** (si nivel ∈ 4/8/12/16/19): stepper +2 a repartir.
   - (Opcional) **Truco nuevo** si toca.
3. **Confirmar** → `Game` aplica los cambios al `Character` del `World`,
   persiste, y continúa la partida.

Si el PC es **IA**, el propio agente (DM o PC IA) elige sus hechizos/ASI vía tools
(o se auto-asigna defaults) — no hay modal.

## B.5 API del motor

- `World.level_up(name, choices \\ %{})` — extender el existente conservando
  compatibilidad de llamada: `level_up(name)` queda como wrapper sin elecciones.
  Además de lo automático, aplica `choices.spells_added`, `choices.asi`,
  `choices.cantrips_added`, `choices.features_added`, etc. al `Character`.
- `Tools`: extender el `deftool level_up(ctx, target)` existente a una variante con
  opciones (`opts`) donde `opts` lleva `%{spells: [...], asi: %{str: 1, dex: 1}, ...}`.
  Para PC IA, el agente usa la tool. Para PC humano, **añadir API en `Dragonex.Game`**
  (p. ej. `Game.level_up(pid, target, choices)`) que haga el cambio dentro del
  GenServer, persista con `Games.save_state/6` y emita PubSub; el LiveView no debe
  mutar DB ni `World` por fuera del single-writer.
- Si un PC humano necesita elecciones y el DM llama `level_up` sin `opts`, decidir
  si la tool crea un “level-up pendiente” para abrir modal, o si aplica solo cuando
  `choices` llega completo. Esa decisión afecta persistencia de pendientes.
- `Dragonex.Heroes.Progression` (módulo nuevo, puro): tablas de
  `spells_known/2`, `cantrips_known/2`, `features_at(level)`, `asi_at?(level)`,
  `max_spell_level(class, level)`. **Fuente de verdad** para qué elecciones
  aplicar.

## B.6 Datos de progresión (lo más tedioso)

Tablas SRD 5.1 por clase (nivel → hechizos/trucos/huecos). Ya tenemos huecos en
`SpellSlots`. Falta `spells_known`/`cantrips_known` (varía: mago = grimorio +2 por
nivel, clérigo/druida/paladín preparan característica+nivel, bardo/hechicero =
tabla cerrada, brujo = pacto). **Simplificación recomendada para v1**: para
preparadores, permitir cambiar libremente su lista al subir; para los de lista
cerrada, usar la tabla SRD. Documentar la simplificación.

## B.7 Criterios de aceptación

- Un clérigo L1 → L2: sube PG, +1 hueco N1, y puede ajustar su lista preparada
  según la simplificación acordada. Sin ASI (nivel 2).
- Un paladín L1 → L2: desbloquea conjuración (gana huecos N1 + hechizos
  iniciales), gana Golpe Divino. La ficha muestra los nuevos `class_features`.
- Un guerrero L3 → L4: sube PG y gana **ASI** (+2 a repartir, máx 20).
- Un mago L2 → L3: puede añadir hechizos de **nivel 2** (no solo 1) al grimorio.
- La partida persiste la subida (rehidratable tras crash).
- Tests: `Progression` tablas, `World.level_up(name, choices)` aplica bien,
  round-trip de `Codec` para la sheet con los nuevos hechizos/ASI.

---

## Orden recomendado de ejecución (otra sesión)

1. **Feature A primero** (autocontenida, no toca el motor de partida):
   1. Migración + schema `CustomContent` + contexto en `Accounts`.
   2. `Catalog` preserva `:srd`, acepta `custom: %{...}` inyectado y no rompe offline.
   3. Builder con `custom: %{...}` + `extra_equipment` inyectado.
   4. LiveView `/mi-contenido` + integración en el editor de héroe.
   5. Tests.
2. **Feature B después** (toca el motor y depende de tener el editor maduro):
   1. `Dragonex.Heroes.Progression` (tablas).
   2. Extender `World.level_up/2` con `choices` y `Tools.level_up` existente.
   3. API `Game.level_up/3` + modal de level-up en `GameLive`.
   4. Tests.

## Notas de ingeniería

- **No romper el builder offline**: el `Catalog` y `Heroes.build` deben seguir
  funcionando sin DB (tests `async: true`, sin sandbox). El contexto custom se
  **inyecta**, no se consulta dentro del builder.
- **`Codec`**: cualquier campo nuevo al `Character` (p. ej. `level_log` si se
  quiere historial) debe ir a `encode_character`/`decode_character` o no sobrevive.
- **I18n**: todo texto nuevo al usuario va por `Translations`/`Catalog`, no hardcoded.
- **Custom keys**: prefijo `custom_` o namespace por user para evitar colisiones
  con keys SRD en el mismo `Character`.
