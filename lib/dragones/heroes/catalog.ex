defmodule Dragones.Heroes.Catalog do
  @moduledoc """
  Capa de **consulta y display** del catálogo de creación de personajes.

  Es el único punto por el que la UI debe preguntar por razas, clases,
  trasfondos, armas, armaduras y hechizos. Devuelve entradas ya **localizadas**
  y listas para pintar, separando la `key` estable (la que almacena el formulario
  y el motor) de la `label` (lo que ve el usuario).

  ## Por qué existe

  Hoy los datos son solo el catálogo **builtin** del SRD (declarativos en
  `Races`, `Classes`, `Equipment`, `Spells`, `Backgrounds`). Pero la idea es
  ampliar el catálogo con:

    1. **SRD completo** importado (fase siguiente), y
    2. **Contenido custom por usuario** persistido en DB.

  Ambos se inyectan aquí: el `Catalog` mezcla builtin + importado + custom y la
  UI no se entera de dónde viene cada entrada. Por eso cada entrada lleva un
  `source` (`:builtin` hoy; `:srd` y `:custom` mañana).

  ## Contrato

  Toda función de listado recibe la `locale` (default: `Dragones.I18n.locale/0`)
  y devuelve listas de mapas con forma estable:

      %{key: String.t(), label: String.t(), source: :builtin | :srd | :custom, ...}

  Las funciones `*_label/2` resuelven la etiqueta de un valor ya almacenado en
  un `Character` (race, class, weapons, spells, inventory).
  """

  alias Dragones.Heroes.{Backgrounds, Classes, Equipment, Races, Spells, Translations}
  alias Dragones.I18n

  @type source :: :builtin | :srd | :custom

  # ============================================================ razas

  @doc """
  Razas disponibles para el creador, localizadas, con sus subrazas.

      [%{key: "elf", label: "Elfo", source: :builtin,
         subraces: [%{key: "high elf", label: "Alto Elfo"}, ...]},
       ...]
  """
  @spec races(atom()) :: [map()]
  def races(locale \\ I18n.locale()) do
    for key <- Races.keys() do
      %{
        key: key,
        label: Translations.race(key, locale),
        source: :builtin,
        subraces: subraces(key, locale)
      }
    end
  end

  @doc "Subrazas de una raza localizadas (devuelve `[]` si no tiene)."
  @spec subraces(String.t(), atom()) :: [map()]
  def subraces(race_key, locale \\ I18n.locale()) do
    for key <- Races.subrace_keys(race_key) do
      %{key: key, label: Translations.subrace(key, locale), source: :builtin}
    end
  end

  @doc """
  Etiqueta de la raza de un personaje ya almacenado.

  Acepta tanto la `key` de una raza (`"human"`) como el nombre de una subraza
  (`"high elf"`), porque el builder actual guarda uno u otro en `Character.race`.
  """
  @spec race_label(String.t() | nil, atom()) :: String.t()
  def race_label(value, locale \\ I18n.locale()), do: Translations.race_display(value, locale)

  # ============================================================ clases

  @doc """
  Clases disponibles para el creador, localizadas, con metadata útil para la UI
  (si es conjurador, dado de golpe, primaria).
  """
  @spec classes(atom()) :: [map()]
  def classes(locale \\ I18n.locale()) do
    for key <- Classes.keys() do
      {:ok, c} = Classes.get(key)

      %{
        key: key,
        label: Translations.class(key, locale),
        source: :builtin,
        caster: not is_nil(c.spellcasting),
        hit_die: c.hit_die,
        primary: c.primary
      }
    end
  end

  @doc "Etiqueta de la clase de un personaje ya almacenado."
  @spec class_label(String.t() | nil, atom()) :: String.t()
  def class_label(key, locale \\ I18n.locale())
  def class_label(nil, _locale), do: ""
  def class_label(key, locale), do: Translations.class(key, locale)

  # ============================================================ trasfondos

  @doc "Trasfondos disponibles para el creador, localizados."
  @spec backgrounds(atom()) :: [map()]
  def backgrounds(locale \\ I18n.locale()) do
    for key <- Backgrounds.keys() do
      %{
        key: key,
        label: Translations.background(key, locale),
        source: :builtin
      }
    end
  end

  @doc "Etiqueta de un trasfondo almacenado."
  @spec background_label(String.t() | nil, atom()) :: String.t()
  def background_label(key, locale \\ I18n.locale())
  def background_label(nil, _locale), do: ""
  def background_label(key, locale), do: Translations.background(key, locale)

  # ============================================================ armas

  @doc "Todas las armas del catálogo, localizadas, con sus mecánicas."
  @spec weapons(atom()) :: [map()]
  def weapons(locale \\ I18n.locale()) do
    for {key, w} <- Equipment.weapons() do
      %{
        key: key,
        label: Translations.weapon(key, locale),
        source: :builtin,
        dice: w.dice,
        damage_type: w.damage_type,
        damage_type_label: Translations.damage_type(w.damage_type, locale),
        attack_ability: w.attack_ability,
        finesse: w.finesse,
        ranged: w.ranged
      }
    end
  end

  @doc "Etiqueta de un arma almacenada en un `Character` (mapa o `Weapon`)."
  @spec weapon_label(map() | String.t(), atom()) :: String.t()
  def weapon_label(entry, locale \\ I18n.locale())
  def weapon_label(%{name: name}, locale), do: Translations.weapon(name, locale)
  def weapon_label(name, locale) when is_binary(name), do: Translations.weapon(name, locale)

  # ============================================================ armaduras

  @doc "Todas las armaduras y escudos del catálogo, localizados."
  @spec armors(atom()) :: [map()]
  def armors(locale \\ I18n.locale()) do
    builtin =
      for {key, a} <- Equipment.armors() do
        %{
          key: key,
          label: Translations.armor(key, locale),
          source: :builtin,
          type: a.type,
          base_ac: a.base_ac,
          max_dex: a.max_dex,
          stealth_disadvantage: a.stealth_disadvantage
        }
      end

    shield = %{
      key: "shield",
      label: Translations.armor("shield", locale),
      source: :builtin,
      type: :shield,
      base_ac: 2,
      max_dex: :unlimited,
      stealth_disadvantage: false
    }

    [shield | builtin]
  end

  @doc "Etiqueta de una armadura/escudo almacenado."
  @spec armor_label(String.t() | nil, atom()) :: String.t()
  def armor_label(key, locale \\ I18n.locale())
  def armor_label(nil, _locale), do: ""
  def armor_label(key, locale), do: Translations.armor(key, locale)

  # ============================================================ hechizos

  @doc "Hechizos del catálogo, opcionalmente filtrados por nivel, localizados."
  @spec spells(atom(), keyword()) :: [map()]
  def spells(locale \\ I18n.locale(), opts \\ []) do
    level = Keyword.get(opts, :level)

    for data <- Spells.all(), is_nil(level) or data.level == level do
      %{
        key: data.name,
        label: spell_name_label(data.name, locale),
        source: :builtin,
        level: data.level,
        kind: data.kind,
        kind_label: Translations.kind(data.kind, locale),
        save_ability: data.save_ability,
        dice: data.dice,
        damage_type: data.damage_type,
        damage_type_label: Translations.damage_type(data.damage_type, locale),
        effect: data.effect
      }
    end
  end

  @doc "Trucos (nivel 0) localizados."
  @spec cantrips(atom()) :: [map()]
  def cantrips(locale \\ I18n.locale()), do: spells(locale, level: 0)

  @doc "Hechizos de nivel 1 localizados."
  @spec spells_level1(atom()) :: [map()]
  def spells_level1(locale \\ I18n.locale()), do: spells(locale, level: 1)

  @doc "Etiqueta de un hechizo almacenado en un `Character` (mapa o `Spell`)."
  @spec spell_label(map() | String.t(), atom()) :: String.t()
  def spell_label(entry, locale \\ I18n.locale())
  def spell_label(%{name: name}, locale), do: spell_name_label(name, locale)
  def spell_label(name, locale) when is_binary(name), do: spell_name_label(name, locale)

  # Prioridad: traducción manual (canónica del SRD-ES) > nombre español del SRD
  # importado (LLM) > la propia key.
  defp spell_name_label(name, locale) do
    hand = Translations.spell(name, locale)

    if hand != name do
      hand
    else
      case Spells.get(name) do
        %{name_es: ne} when is_binary(ne) and ne != "" -> ne
        _ -> name
      end
    end
  end

  @doc """
  Hechizos que una clase puede elegir al nivel 1 (truco + nivel 1), localizados.

  Devuelve **TODOS** los hechizos del catálogo que pertenecen a la lista de la
  clase (según `Spells.by_class/1`), no solo los defaults: el jugador elige
  libremente hasta el cupo de la clase. Los `defaults` de la clase se marcan
  aparte para que el UI los traiga pre-seleccionados.
  """
  @spec spells_for_class(String.t(), atom()) :: %{cantrips: [map()], level1: [map()]}
  def spells_for_class(class_key, locale \\ I18n.locale()) do
    defaults = MapSet.new(Classes.default_spell_names(class_key))

    entries =
      for data <- Spells.by_class(class_key) do
        %{
          key: data.name,
          label: spell_name_label(data.name, locale),
          source: :builtin,
          level: data.level,
          kind: data.kind,
          kind_label: Translations.kind(data.kind, locale),
          save_ability: data.save_ability,
          dice: data.dice,
          damage_type: data.damage_type,
          damage_type_label: Translations.damage_type(data.damage_type, locale),
          effect: data.effect,
          default: MapSet.member?(defaults, data.name)
        }
      end

    {cantrips, rest} = Enum.split_with(entries, &(&1.level == 0))
    level1 = Enum.filter(rest, &(&1.level == 1))
    %{cantrips: cantrips, level1: level1}
  end

  # ============================================================ inventario

  @doc "Etiqueta de un objeto de inventario (arma, armadura, equipo o nombre libre)."
  @spec item_label(map() | String.t(), atom()) :: String.t()
  def item_label(entry, locale \\ I18n.locale())
  def item_label(%{name: name}, locale), do: Translations.item(name, locale)
  def item_label(name, locale) when is_binary(name), do: Translations.item(name, locale)

  @doc "Etiqueta del `kind` de un objeto de inventario."
  @spec item_kind_label(atom() | String.t(), atom()) :: String.t()
  def item_kind_label(kind, locale \\ I18n.locale()), do: Translations.item_kind(kind, locale)

  # ============================================================ equipo inicial

  @doc """
  Grupos de equipo inicial de una clase, localizados y listos para pintar en el
  creador. Cada grupo exige elegir **una** opción.

      [%{id: :weapon, options: [%{index: 0, label: "Bastón", slots: [...]},
                                %{index: 1, label: "Daga",   slots: [...]}]},
       ...]

  El `index` es el valor que el formulario guarda en `equipment_picks[id]`.
  Las `slots` son los slots SRD que el builder aplica al elegir esa opción.
  """
  @spec equipment_for_class(String.t(), atom()) :: [map()]
  def equipment_for_class(class_key, locale \\ I18n.locale()) do
    case Classes.get(class_key) do
      {:ok, %{equipment_groups: groups}} ->
        for %{id: gid, options: options} <- groups do
          %{
            id: gid,
            options:
              options
              |> Enum.with_index()
              |> Enum.map(fn {slots, idx} ->
                %{index: idx, label: describe_slots(slots, locale), slots: slots}
              end)
          }
        end

      {:error, _} ->
        []
    end
  end

  @doc """
  Descripción legible y localizada de una lista de slots de equipo
  (p. ej. `[%{armor: "leather armor"}, %{weapon: "longbow"}, %{ammo: "arrows", qty: 20}]`
  → "Armadura de cuero + Arco largo + 20 Flechas").
  """
  @spec describe_slots([map()], atom()) :: String.t()
  def describe_slots(slots, locale \\ I18n.locale()) when is_list(slots) do
    slots
    |> Enum.map(&describe_slot(&1, locale))
    |> Enum.join(" + ")
  end

  defp describe_slot(%{weapon: name}, l), do: Translations.weapon(name, l)
  defp describe_slot(%{armor: name}, l), do: Translations.armor(name, l)
  defp describe_slot(%{shield: true}, l), do: Translations.armor("shield", l)
  defp describe_slot(%{gear: name}, l), do: Translations.gear(name, l)
  defp describe_slot(%{focus: name}, l), do: Translations.gear(name, l)
  defp describe_slot(%{ammo: name, qty: qty}, l), do: "#{qty} #{Translations.gear(name, l)}"

  # ============================================================ habilidades / tiradas

  @doc "Etiqueta de una skill (string almacenado o atom)."
  @spec skill_label(String.t() | atom(), atom()) :: String.t()
  def skill_label(key, locale \\ I18n.locale()), do: Translations.skill(to_string(key), locale)

  @doc "Etiqueta de una característica (str/dex/…), larga o corta."
  @spec ability_label(String.t() | atom(), atom(), keyword()) :: String.t()
  def ability_label(key, locale \\ I18n.locale(), opts \\ []) do
    if Keyword.get(opts, :short, false) do
      Translations.ability_short(key, locale)
    else
      Translations.ability(key, locale)
    end
  end

  @doc "Lista de tiradas de salvación de un personaje, ya localizadas y legibles."
  @spec saving_throws([String.t()], atom()) :: String.t()
  def saving_throws(profs, locale \\ I18n.locale()) when is_list(profs) do
    profs
    |> Enum.map(&Translations.ability(&1, locale))
    |> Enum.join(", ")
  end

  # ============================================================ habilidades / idiomas / rasgos

  @doc "Lista de habilidades (skills) localizadas y legibles."
  @spec skills([String.t()], atom()) :: String.t()
  def skills(keys, locale \\ I18n.locale()) when is_list(keys) do
    keys
    |> Enum.map(&Translations.skill(&1, locale))
    |> Enum.join(", ")
  end

  @doc "Lista de idiomas localizados y legibles."
  @spec languages([String.t()], atom()) :: String.t()
  def languages(keys, locale \\ I18n.locale()) when is_list(keys) do
    keys
    |> Enum.map(&Translations.language(&1, locale))
    |> Enum.join(", ")
  end

  @doc "Lista de rasgos raciales localizados."
  @spec racial_traits([String.t()], atom()) :: [String.t()]
  def racial_traits(keys, locale \\ I18n.locale()) when is_list(keys) do
    Enum.map(keys, &Translations.trait(&1, locale))
  end

  @doc "Lista de características de clase localizadas."
  @spec class_features([String.t()], atom()) :: [String.t()]
  def class_features(keys, locale \\ I18n.locale()) when is_list(keys) do
    Enum.map(keys, &Translations.feature(&1, locale))
  end

  @doc "Característica de trasfondo localizada."
  @spec background_feature(String.t() | nil, atom()) :: String.t()
  def background_feature(key, locale \\ I18n.locale())
  def background_feature(nil, _locale), do: ""
  def background_feature(key, locale), do: Translations.background_feature(key, locale)

  @doc "Las skills que una clase ofrece para elegir, localizadas (`:any` → lista SRD completa)."
  @spec class_skill_options(String.t(), atom()) :: %{count: pos_integer(), options: [map()]} | nil
  def class_skill_options(class_key, locale \\ I18n.locale()) do
    case Classes.get(class_key) do
      {:ok, %{skill_list: :any, skill_count: count}} ->
        %{
          count: count,
          options:
            for(
              k <- Translations.skill_keys(),
              do: %{key: k, label: Translations.skill(k, locale)}
            )
        }

      {:ok, %{skill_list: list, skill_count: count}} ->
        %{
          count: count,
          options: for(k <- list, do: %{key: k, label: Translations.skill(k, locale)})
        }

      _ ->
        nil
    end
  end
end
