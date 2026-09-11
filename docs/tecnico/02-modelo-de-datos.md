# Modelo de datos

> **Técnico.** Qué se persiste, cómo vive en memoria, y cómo se cruza la frontera
> (jsonb ↔ structs) sin perder datos. Lee esto antes de tocar un struct, una
> migración o el `Codec`. Invariantes: `D4`, `D6`, `D7`, `D8`.

## Las dos caras del estado

Dragonex tiene **dos** representaciones del estado, y entender la relación entre
ellas es lo que evita bugs silenciosos:

1. **En runtime** — un árbol de **structs** Elixir (`World → Character →
   Weapon/Spell/Item`), mutado sólo por el `Game` GenServer (`D6`).
2. **En Postgres** — `games.world` como **jsonb**, más tablas relacionales para
   usuarios/héroes/eventos.

La frontera entre ambas es **`Dragonex.Codec`**: codifica structs → mapa
JSON-safe al persistir, y decodifica mapa → structs al rehidratar. Es **explícito
campo a campo** (sin heurística genérica de walking) precisamente para que nada se
pierda silenciosamente.

## Tablas (esquema relacional)

> **Fuente canónica:** `priv/repo/migrations/` (8 migraciones). Ante duda, mira
> la migración.

```
users ──< games
       ──< heroes ──< characters (snapshot baseline, opcional)
       ──< custom_contents

games ──< participants
      ──< characters (sheet baseline estática)
      ──< game_events (timeline append-only)
```

| Tabla | Columnas clave | Relaciones |
|---|---|---|
| `games` | `title`, `story_bible` jsonb, `dm_style`, `dice_engine`, **`world` jsonb** (vía Codec), `status` enum (`configuring/running/waiting/paused/ended`), `round`, `current_participant`, `intents` map, `open_slots` | `belongs_to :user`; `has_many :participants/:characters/:events` |
| `participants` | `name`, `kind` (`ai/human`), `side` (`pc/dm` — los enemigos no son participants, se pliegan al DM), `user_id` (nullable) | `belongs_to :game`, `belongs_to :user` |
| `characters` | `name`, **`sheet` jsonb** (baseline estática), `kind`, `hero_id` | `belongs_to :game`, `belongs_to :hero` |
| `game_events` | **`seq`** (monotono por game), `type` enum (`narration/action/tool/dice/system/turn`), `actor`, `visible_to`, `payload` jsonb, `inserted_at` | `belongs_to :game` |
| `users` | `email` (unique), `password_hash` (bcrypt), `display_name` | `has_many :heroes/:games/:custom_contents` |
| `heroes` | `user_id`, `name`, `race`, `class`, `level`, **`sheet` jsonb** (vía Codec), `draft` jsonb | `belongs_to :user` |
| `custom_contents` | `user_id`, `kind` (`weapon/spell/item`), `key` slug, `name_es`, **`definition` jsonb**, `notes` | `belongs_to :user` |

**`characters.sheet` es un snapshot baseline** (la ficha inicial). **El estado
vivo** (HP actual, condiciones, slots usados) **no vive aquí**: vive en
`games.world.characters`. Ojo al diseñar: si añades un campo al personaje, puede
que tenga que estar tanto en el `Codec.encode_character` (para `sheet`) como en el
`Codec.encode` (para `world`).

### Índices notables

- **`game_events(game_id, seq)` UNIQUE** — el `seq` es monotono por partida; el
  unique lo defiende frente a una race en `next_seq` (`games.ex`).
- **`participants(game_id, user_id)` UNIQUE** — un usuario no puede unirse dos veces
  a la misma partida (los `user_id` NULL de DM/IA no chocan: Postgres trata NULLs
  como distintos).
- Únicos por `(game_id, name)` en `participants` y `characters`, y
  `(user_id, kind, key)` en `custom_contents`.

## Árbol de structs (runtime)

```
Dragonex.World (world.ex)
├─ scene          String                       escena actual (lo que el DM narró)
├─ phase          :exploration | :combat
├─ round          pos_integer                  asalto de combate
├─ characters     %{name => Dragonex.Character}  (structs completos)
├─ initiative_order [name]                     orden de iniciativa
├─ log            [(actor, entry)]             legacy (se codifica como 2-arrays)
├─ spell_slots    %{name => %{level => count}}  CLAVES DE NIVEL ENTERAS
├─ facts          [String]                     hechos durables (D16, cap 30)
├─ acted_this_round MapSet(name)               main turns gastados (D25)
└─ current_combatant name | nil                slot vivo en combate (D34)

Dragonex.Character (character.ex)  — Ecto embedded schema
├─ identidad: name, race, class, sex, side, level, xp
├─ vitales:   hp, max_hp, temp_hp, ac, speed
├─ concentrating: String | nil     hechizo de concentración (D37)
├─ raging:        boolean          furia del bárbaro; default false (D42)
├─ reckless:      boolean          Reckless Attack; default false (D44)
├─ second_wind_used: boolean       Segundo aliento gastado; default false (D45)
├─ action_surge_used: boolean      Oleada de acción gastada; default false (D47)
├─ fighting_style: String | nil    archery | defense | dueling (D48)
├─ smite_slot:    integer | nil    Castigo divino pendiente 1..5 (D46)
├─ damage_resistances / damage_vulnerabilities / damage_immunities
│                 [String]         tipos 5e; default [] (D38)
├─ atributos: str/dex/con/int/wis/cha
├─ backstory
├─ weapons:   [Dragonex.Weapon]   almacenados como {:array, :map}
├─ spells:    [Dragonex.Spell]    {:array, :map}
├─ inventory: [Dragonex.Item]     {:array, :map}
├─ conditions:        [%{condition: name}]
├─ death_saves:       %{successes: integer, fails: integer}
└─ saving_proficiencies, skill_proficiencies, languages, racial_traits,
   class_features, background_feature

Weapon  (weapon.ex)  — struct plana: name, dice, damage_type, attack_ability, finesse, ranged
Spell   (spell.ex)   — struct plana: name, level, kind (:save/:attack/:automatic),
                       casting_ability, save_ability, dice, damage_type, effect
Item    (item.ex)    — struct plana: name, qty, kind
```

`weapons`/`spells`/`inventory` se guardan como `{:array, :map}` (Ecto no sabe de
structs arbitrarios) — en runtime **llevan structs dentro**, y **sólo sobreviven
al jsonb gracias al `Codec`**. Sin él volverían como mapas sin `__struct__`.

## La frontera `Codec` (`codec.ex`)

`encode/1` → mapa JSON-safe:

- atoms (`phase`, `kind`, abilities) → **strings**.
- la tupla del `log` → array de 2.
- `spell_slots` → tal cual (pero con claves string al pasar por Jason).

`decode/1` → structs otra vez:

- **`String.to_atom`** para kind/ability/item kind (decisión `D8`: en el `Codec` se
  permite `String.to_atom`; **fuera** del `Codec`, siempre `to_existing_atom`).
- **re-integeriza las claves de nivel de `spell_slots`** (`codec.ex`). Sin esto,
  las claves `"1"`, `"2"` (strings tras el jsonb) harían que `has_slot?/3` (que
  mira por integer) reportase cero slots → los casters no podrían conjurar tras un
  rehydrate. Bug real que ya pasó.
- `decode(nil)` → `%World{}` (un `games.world` nullable no crashea el rehydrate).

> **Patrón recurrente y duro:** cualquier campo que a nivel runtime tenga **claves
> atom o integer** se corrompe al pasar por Jason/jsonb (se vuelven strings).
> `spell_slots` y `conditions` son los casos vivos. Si añades uno así, normalízalo
> en `Codec.decode` y **añade un test de round-trip por Jason**.

## Invariantes de datos (no se rompen)

Estos son **contratos**, no gustos. Romperlos es un bug aunque el test siga verde.

| ID | Invariante | Dónde se defiende |
|---|---|---|
| `D4` | **No cambiar la forma** de `Character`/`Weapon`/`Spell`/`Item`. Un campo nuevo en `Character` debe entrar en `Codec.encode/decode` o **no sobrevive** al jsonb. | `Codec` |
| `D6` | `games.world` se muta **solo** vía el `Game` GenServer. La LiveView nunca escribe `Repo` de partida. | `Game` + `SharedState` |
| `D7` | Todo texto del modelo que se persista o entre en el historial pasa por `Text.scrub`. | `events.ex:64`, `history.ex` |
| `D8` | `String.to_atom` **solo** en `Codec`. Fuera, `to_existing_atom`. | revisión manual + tests |
| `D9` | `Heroes.build` y `Catalog` no tocan DB; el custom content se **inyecta** (`opts[:custom]`). Tests `async: true`. | `heroes.ex`, `catalog.ex` |
| `D16` | `world.facts` durable, idempotente, cap 30. | `world.ex` (`add_fact`) |

## Persistencia y rehidrata

- **Al crear** partida (`Games.create_game`): `Codec.encode(world)` →
  `games.world`.
- **Tras cada beat** (`Game` → `Games.save_state`): lee el World vivo con
  `Session.read_state`, lo codifica y persiste, junto a `status`/`round`/`intents`.
- **Al rehidratar** (`Game.start_link` → `rehydrate`): `Games.load_world/1` →
  `Codec.decode(world)` → `World` vivo en la `Session`. Los `:running`/`:waiting`
  colapsan a `:running` para que el bucle arranque.

El `Game` arranca **la `Session` sin store** (`D3`): el propio `Game` es la capa de
durabilidad. Por eso `Store.Coded` existe (envuelve `Codec` sobre ETS) pero apenas
se usa en producción.

## El timeline `game_events`

Es la fuente de la **coherencia narrativa** (`D19`): en cada beat, `History.from_events/1`
reconstruye el contexto compartido desde aquí.

- `seq` monotono por partida (`next_seq`).
- `type` discrimina: `:narration` (texto del modelo, sanitizado), `:action`
  (declaración humana), `:tool` (invocación de tool), `:dice` (tirada con
  desglose), `:system` (nota del motor), `:turn` (marcador de cambio de turno).
- Las narraciones viejas se **comprimen** en el historial a una línea; se guardan
  las 12 más recientes verbatim (`History`).

→ Cómo se recompone el contexto en cada beat:
[`01-bucle-del-agente.md`](01-bucle-del-agente.md) §3.
