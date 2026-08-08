defmodule Dragones.Heroes do
  @moduledoc """
  The character-creation context for Dragones.

  A pure, self-contained builder that turns 5e **choices** (race, subrace, class,
  background, ability scores, optional spells/skills) into a fully derived,
  changeset-valid `Dragones.Character` — ready for the game engine or the Codec.

  ## Separation

  This module knows nothing about games, sessions, the DM, or LiveView. Its sole
  contract is:

      iex> {:ok, %Dragones.Character{}} = Dragones.Heroes.build(%{
      ...>   name: "Lyra", race: "elf", subrace: "high elf",
      ...>   class: "wizard", background: "sage"
      ...> })

  The game layer already consumes `Character` via `Roster.catalog` /
  `Games.create_from_wizard` — that integration is a separate, optional step.

  ## What the builder derives (5e rules)

    * **Ability scores**: base (standard array / point buy / explicit) + racial
      bonuses → final 1–20.
    * **HP**: `hit_die_max + CON modifier (+ racial hp_bonus)`.
    * **AC**: from starting armour + shield + DEX, or Unarmored Defence
      (Barbarian / Monk) when unarmoured.
    * **Speed / saving_proficiencies**: from race / class.
    * **Weapons**: from starting equipment, each with the correct
      `attack_ability` (ranged→:dex, finesse→:str+finesse, melee→:str).
    * **Spells** (casters only): cantrips + level-1 spells with the class's
      casting ability, correct `kind`/`save_ability`/`dice`.

  The combat engine (`Rules.Combat`) computes attack rolls, damage, save DCs and
  spell attacks from these fields — the builder never duplicates that logic.

  ## Level scope

  Level 1 is fully supported (per the SRD). The `level` field is stored on the
  character but all derivations (HP, spell counts) are level-1; multi-level
  progression is a future enhancement.
  """

  alias Dragones.{Character, Item, Spell, Weapon}

  alias Dragones.Heroes.{
    Backgrounds,
    Classes,
    Equipment,
    Races,
    Scoring,
    Spells,
    Translations
  }

  alias Dragones.Rules.Ability

  @default_pb %{str: 8, dex: 8, con: 8, int: 8, wis: 8, cha: 8}

  @point_buy_shapes [
    [15, 14, 13, 12, 10, 8],
    [15, 15, 14, 10, 8, 8],
    [15, 14, 14, 10, 10, 8],
    [14, 14, 14, 12, 10, 8],
    [15, 13, 13, 12, 12, 8]
  ]

  @random_names ~w(
    Aelar Aelwyn Aldric Amara Arannis Arden Astrid Bastian Brina Bryn Calder
    Cora Corin Darian Delia Dorin Drask Eira Elara Eldrin Emera Fenris Garruk
    Halra Ilyra Isolde Joren Kael Ketha Kieran Liora Lyra Maelis Mira Naeris
    Nessa Nyssa Orin Pip Riven Rhogar Sable Selene Sylva Talia Tara Thane Toren
    Varek Vesper Vex Yara Zephyra Zorren
  )

  @type choices :: %{
          required(:name) => String.t(),
          required(:race) => String.t(),
          required(:class) => String.t(),
          required(:background) => String.t(),
          optional(:sex) => String.t(),
          optional(:subrace) => String.t(),
          optional(:scores) => term(),
          optional(:skills) => [String.t()],
          optional(:spells) => [String.t()],
          optional(:backstory) => String.t(),
          optional(:level) => pos_integer(),
          # Bundle de contenido custom del usuario (%{weapons/spells/items: [...]}).
          optional(:custom) => map(),
          # Equipo extra elegido por el jugador (armas/objetos custom o builtin).
          optional(:extra_equipment) => map()
        }

  @type build_error :: {:error, String.t()}

  @doc """
  Build a level-1 `Dragones.Character` from 5e choices.

  Returns `{:ok, %Character{}}` on success, or `{:error, reason}` when a choice
  is illegal (unknown race/class, out-of-range scores, skill not on the class
  list, etc.).

  ## Examples

      # Minimal — everything auto-derived from standard array + class defaults
      {:ok, lyra} = Heroes.build(%{
        name: "Lyra", race: "elf", subrace: "high elf",
        class: "wizard", background: "sage"
      })

      # Explicit point-buy scores
      {:ok, bryn} = Heroes.build(%{
        name: "Bryn", race: "human", class: "fighter", background: "soldier",
        scores: %{method: :point_buy, scores: %{str: 15, dex: 14, con: 15, int: 8, wis: 10, cha: 8}}
      })
  """
  @spec build(choices()) :: {:ok, Character.t()} | build_error()
  def build(%{} = raw) do
    choices = normalize_keys(raw)

    with {:ok, race} <- resolve_race(choices),
         {:ok, class} <- fetch(Classes, choices[:class], "class"),
         {:ok, bg} <- fetch(Backgrounds, choices[:background], "background"),
         {:ok, skills} <- validate_skills(class, choices[:skills]),
         {:ok, base} <- Scoring.resolve(choices[:scores], class.priority),
         bonuses <- resolve_bonuses(race, class),
         final <- Scoring.apply_bonuses(base, bonuses),
         :ok <- validate_final_scores(final),
         class_slots <- resolve_equipment(class, choices[:equipment_picks]),
         custom <- choices[:custom] || %{},
         eq0 <- process_equipment(class_slots ++ bg.equipment),
         eq <- apply_extra_equipment(eq0, choices[:extra_equipment], custom),
         hp <- compute_hp(class, final, race, choices[:level] || 1),
         ac <- compute_ac(eq, class, final),
         spells <- build_spells(class, choices[:spells], custom),
         languages <- resolve_languages(race, bg, choices[:extra_languages]),
         attrs =
           to_attrs(choices, race, class, bg, final, hp, ac, eq, spells, skills, languages),
         :ok <- validate_changeset(attrs) do
      {:ok, struct(Character, attrs)}
    end
  end

  # ---------------------------------------------------------------- queries

  @doc "All selectable race keys."
  @spec list_races() :: [String.t()]
  def list_races, do: Races.keys()

  @doc "All selectable class keys."
  @spec list_classes() :: [String.t()]
  def list_classes, do: Classes.keys()

  @doc "All selectable background keys."
  @spec list_backgrounds() :: [String.t()]
  def list_backgrounds, do: Backgrounds.keys()

  @doc "Subrace keys for a race (empty list if the race has none)."
  @spec subraces(String.t()) :: [String.t()]
  def subraces(race_key), do: Races.subrace_keys(race_key)

  @doc "Skill keys offered by a class for the player to pick, plus how many."
  @spec class_skill_options(String.t()) ::
          %{list: [String.t()] | :any, count: pos_integer()} | nil
  def class_skill_options(nil), do: nil

  def class_skill_options(class_key) do
    case Classes.get(class_key) do
      {:ok, %{skill_list: list, skill_count: count}} -> %{list: list, count: count}
      _ -> nil
    end
  end

  @doc "Extra language slots the current choices grant (race + subrace + background)."
  @spec extra_language_slots(String.t() | nil, String.t() | nil, String.t() | nil) ::
          non_neg_integer()
  def extra_language_slots(race_key, subrace_key, bg_key) do
    with {:ok, race} <- Races.get(race_key || "", subrace_key),
         {:ok, bg} <- fetch(Backgrounds, bg_key, "background") do
      (race.extra_languages || 0) + (bg.extra_languages || 0)
    else
      _ -> 0
    end
  end

  @doc """
  A random coherent set of hero choices (race + matching subrace, class,
  background, sex, name) for the creator's draft button. The caller owns the
  form-shape assembly; this only picks the domain values.
  """
  @spec random_draft() :: %{
          name: String.t(),
          race: String.t(),
          subrace: String.t() | nil,
          class: String.t(),
          background: String.t(),
          sex: String.t(),
          score_method: String.t(),
          pb: map(),
          spells: [String.t()] | nil,
          equipment: map(),
          skills_choice: [String.t()],
          extra_langs: [String.t()],
          backstory: String.t()
        }
  def random_draft do
    race = Enum.random(list_races())
    subs = subraces(race)
    subrace = if(subs != [], do: Enum.random(subs), else: nil)
    class = Enum.random(list_classes())
    background = Enum.random(list_backgrounds())
    {:ok, class_data} = Classes.get(class)
    score_method = if :rand.uniform(3) == 1, do: "pointbuy", else: "auto"

    %{
      name: random_hero_name(),
      race: race,
      subrace: subrace,
      class: class,
      background: background,
      sex: Enum.random(["hombre", "mujer", "no binario"]),
      score_method: score_method,
      pb: if(score_method == "pointbuy", do: random_point_buy(class_data), else: @default_pb),
      spells: random_spells(class_data),
      equipment: random_equipment(class_data),
      skills_choice: random_skills(class_data, background),
      extra_langs: random_extra_languages(race, subrace, background),
      backstory: random_backstory(race, subrace, class, background)
    }
  end

  defp random_hero_name, do: Enum.random(@random_names)

  # --------------------------------------------------------- level up

  @doc """
  Aplica una subida de nivel a un `Character` ya construido.

  Thin wrapper que delega en `Dragones.Heroes.LevelUp.apply/2` (el módulo de
  reglas de progresión, separado del builder). Ver ahí las reglas 5e aplicadas
  y el formato de `choices` (`:spells_added`, `:asi`, `:custom`).
  """
  @spec apply_level_up(Character.t(), map()) :: {:ok, Character.t()} | {:error, String.t()}
  def apply_level_up(%Character{} = c, choices \\ %{}),
    do: Dragones.Heroes.LevelUp.apply(c, choices)

  defp random_point_buy(%{priority: priority}) do
    @point_buy_shapes
    |> Enum.random()
    |> then(fn scores -> Enum.zip(priority, scores) end)
    |> Map.new()
  end

  defp random_equipment(%{equipment_groups: groups}) do
    Map.new(groups, fn %{id: id, options: options} ->
      {id, Enum.random(0..(length(options) - 1))}
    end)
  end

  defp random_skills(%{skill_list: list, skill_count: count}, background) do
    bg_skills =
      case Backgrounds.get(background) do
        {:ok, bg} -> bg.skills
        _ -> []
      end

    pool = if list == :any, do: Translations.skill_keys(), else: list
    preferred = Enum.reject(pool, &(&1 in bg_skills))
    pool = if length(preferred) >= count, do: preferred, else: pool

    pool
    |> Enum.shuffle()
    |> Enum.take(count)
  end

  defp random_extra_languages(race, subrace, background) do
    count = extra_language_slots(race, subrace, background)

    fixed =
      case Races.get(race || "", subrace) do
        {:ok, race_data} -> race_data.languages
        _ -> []
      end

    Translations.languages()
    |> Enum.reject(&(&1 in fixed))
    |> Enum.shuffle()
    |> Enum.take(count)
  end

  defp random_spells(%{spellcasting: nil}), do: nil

  defp random_spells(%{key: class_key, spellcasting: sc}) do
    spells = Spells.by_class(class_key)
    cantrip_pool = Enum.filter(spells, &(&1.level == 0))
    level1_pool = Enum.filter(spells, &(&1.level == 1))
    level1_count = if sc.spells_level1 > 0, do: sc.spells_level1, else: length(sc.defaults.spells)

    random_spell_names(cantrip_pool, sc.cantrips, sc.defaults.cantrips) ++
      random_spell_names(level1_pool, level1_count, sc.defaults.spells)
  end

  defp random_spell_names(pool, count, fallback) do
    pool
    |> Enum.map(& &1.name)
    |> Enum.shuffle()
    |> then(fn names -> if length(names) >= count, do: names, else: fallback end)
    |> Enum.take(count)
  end

  defp random_backstory(race, subrace, class, background) do
    race_label = Translations.race_display(subrace || race, Dragones.I18n.locale())
    class_label = Translations.class(class)
    background_label = Translations.background(background)

    Enum.random([
      "#{race_label} #{class_label} de origen #{background_label}, en busca de una deuda que saldar.",
      "Tras años como #{String.downcase(background_label)}, aprendió que la gloria no espera a nadie.",
      "Una vieja promesa empuja a este #{String.downcase(class_label)} a aceptar trabajos peligrosos.",
      "No habla mucho de su pasado, pero cada cicatriz tiene nombre propio.",
      "Persigue una pista menor que quizá revele una amenaza mucho mayor."
    ])
  end

  # ---------------------------------------------------------------- race

  defp resolve_race(choices) do
    race_key = to_string(choices[:race] || "")
    subrace_key = choices[:subrace] && to_string(choices[:subrace])

    if race_key == "" do
      {:error, "race is required"}
    else
      case Races.get(race_key, subrace_key) do
        {:ok, _} = ok ->
          ok

        {:error, msg} ->
          # Only try the parent-race heuristic when the race key itself was
          # unknown — not when a valid race simply needs a subrace.
          if String.starts_with?(msg, "unknown race") and subrace_key == nil do
            case find_parent_race(race_key) do
              nil -> {:error, "unknown race: #{race_key}"}
              parent -> Races.get(parent, race_key)
            end
          else
            {:error, msg}
          end
      end
    end
  end

  # Handles "high elf" as a race key by finding the parent race.
  defp find_parent_race(subrace_key) do
    Enum.find(Races.keys(), fn rk ->
      subrace_key in Races.subrace_keys(rk)
    end)
  end

  # --------------------------------------------------------------- bonuses

  defp resolve_bonuses(race, class) do
    case race.choose_bonus do
      nil ->
        race.bonuses

      n ->
        boosted = Map.keys(race.bonuses)
        candidates = Enum.reject(class.priority, &(&1 in boosted))
        chosen = Enum.take(candidates, n)
        Map.merge(race.bonuses, Map.new(chosen, fn ab -> {ab, 1} end))
    end
  end

  # --------------------------------------------------------------- equipment

  @doc """
  Resuelve los grupos de equipo inicial de una clase aplicando las picks del
  usuario.

  `picks` es un mapa `%{group_id => option_index}` (atom o string keys). Las
  `key` que faltan o índices fuera de rango caen a la **opción 0** (el default
  histórico), así una llamada sin picks reproduce el comportamiento previo.

  Devuelve la lista plana de slots (los que entiende `process_equipment/1`).
  """
  @spec resolve_equipment(map(), map() | nil) :: [map()]
  def resolve_equipment(class, picks) when is_map(class) do
    pick_map = normalize_pick_map(picks)

    Enum.flat_map(class.equipment_groups, fn %{id: gid, options: options} ->
      idx = Map.get(pick_map, gid, 0)
      Enum.at(options, idx, hd(options))
    end)
  end

  defp normalize_pick_map(nil), do: %{}

  defp normalize_pick_map(picks) when is_map(picks) do
    Map.new(picks, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
    end)
  end

  defp process_equipment(slots) do
    Enum.reduce(slots, %{weapons: [], inventory: [], armor: nil, shield: false}, fn
      %{weapon: name}, acc ->
        case Equipment.weapon(name) do
          nil -> acc
          w -> %{acc | weapons: acc.weapons ++ [w]}
        end

      %{armor: name}, acc ->
        case Equipment.armor(name) do
          nil ->
            acc

          a ->
            %{
              acc
              | armor: a,
                inventory: acc.inventory ++ [%Item{name: name, qty: 1, kind: :armor}]
            }
        end

      %{shield: true}, acc ->
        %{
          acc
          | shield: true,
            inventory: acc.inventory ++ [%Item{name: "shield", qty: 1, kind: :armor}]
        }

      %{gear: name}, acc ->
        %{acc | inventory: acc.inventory ++ [%Item{name: name, qty: 1, kind: :gear}]}

      %{ammo: name, qty: qty}, acc ->
        %{acc | inventory: acc.inventory ++ [%Item{name: name, qty: qty, kind: :gear}]}

      %{focus: name}, acc ->
        %{acc | inventory: acc.inventory ++ [%Item{name: name, qty: 1, kind: :gear}]}

      _, acc ->
        acc
    end)
  end

  # ----------------------------------------------------------- custom / extras

  # Añade equipo extra elegido por el jugador (armas/objetos custom o builtin)
  # al resultado de `process_equipment/1`. No sustituye el equipo inicial.
  defp apply_extra_equipment(eq, nil, _custom), do: eq

  defp apply_extra_equipment(eq, extra, custom) when is_map(extra) do
    weapons = list_field(extra, :weapons)
    items = list_field(extra, :items)

    new_weapons = Enum.flat_map(weapons, &resolve_extra_weapon(&1, custom))
    new_items = Enum.flat_map(items, &resolve_extra_item(&1, custom))

    %{eq | weapons: eq.weapons ++ new_weapons, inventory: eq.inventory ++ new_items}
  end

  defp list_field(map, key), do: Map.get(map, key, Map.get(map, to_string(key), [])) || []

  defp resolve_extra_weapon(key, custom) do
    key = to_string(key)

    cond do
      String.starts_with?(key, "custom_") ->
        case Enum.find(custom[:weapons] || [], &(&1.key == key)) do
          nil -> []
          %{name: name, definition: d} -> [weapon_from_def(name, d)]
        end

      true ->
        case Equipment.weapon(key) do
          nil -> []
          w -> [w]
        end
    end
  end

  defp weapon_from_def(name, d) do
    %Weapon{
      name: name,
      dice: defv(d, "dice"),
      damage_type: defv(d, "damage_type"),
      attack_ability: to_atom(defv(d, "attack_ability")),
      finesse: defv(d, "finesse") || false,
      ranged: defv(d, "ranged") || false
    }
  end

  defp resolve_extra_item(spec, custom) do
    key = to_string(spec_field(spec, :key))
    qty = spec_field(spec, :qty) || 1

    cond do
      String.starts_with?(key, "custom_") ->
        case Enum.find(custom[:items] || [], &(&1.key == key)) do
          nil ->
            []

          %{name: name, definition: d} ->
            [%Item{name: name, qty: qty, kind: to_atom(defv(d, "kind"))}]
        end

      true ->
        []
    end
  end

  defp spec_field(spec, key), do: Map.get(spec, key, Map.get(spec, to_string(key)))

  # Lee un campo de un `definition` con claves string o atom (helper compartido).
  defp defv(d, k), do: Dragones.MapUtil.get(d, k)

  defp to_atom(v), do: Dragones.MapUtil.to_atom(v)

  # ------------------------------------------------------------------- AC

  @doc """
  Cómputo de CA a partir del equipo derivado (`%{armor, shield}`), la clase (para
  Defensa sin Armadura) y las puntuaciones. Público para que `Heroes.LevelUp`
  recalcule la CA tras un ASI sin duplicar la regla.
  """
  def compute_ac(eq, class, scores) do
    dex_mod = Ability.modifier(scores[:dex])

    cond do
      eq.armor != nil ->
        Equipment.compute_ac(eq.armor, eq.shield, dex_mod)

      class.unarmored_defense != nil ->
        unarmored = 10 + sum_mods(class.unarmored_defense, scores)
        if eq.shield, do: unarmored + 2, else: unarmored

      true ->
        Equipment.compute_ac(nil, eq.shield, dex_mod)
    end
  end

  defp sum_mods(abilities, scores) do
    abilities
    |> Enum.map(fn ab -> Ability.modifier(scores[ab]) end)
    |> Enum.sum()
  end

  # ------------------------------------------------------------------- HP

  defp compute_hp(class, scores, race, level) do
    con_mod = Ability.modifier(scores[:con])
    hp_bonus = race.hp_bonus
    # Level 1: hit die max + con mod + racial bonus (e.g. hill dwarf +1)
    level_1 = class.hit_die + con_mod + hp_bonus

    if level > 1 do
      # Each level after 1: average hit die (rounded up) + con mod + racial bonus
      avg_roll = div(class.hit_die, 2) + 1
      level_1 + (level - 1) * (avg_roll + con_mod + hp_bonus)
    else
      level_1
    end
  end

  # ---------------------------------------------------------------- spells

  defp build_spells(%{spellcasting: nil}, _user_picks, _custom), do: []

  defp build_spells(%{spellcasting: sc}, user_picks, custom) do
    {cantrip_names, spell_names} =
      case user_picks do
        nil ->
          {sc.defaults.cantrips, sc.defaults.spells}

        picks when is_list(picks) ->
          Enum.split_with(picks, fn name ->
            case resolve_spell(name, custom) do
              %{level: 0} -> true
              _ -> false
            end
          end)
      end

    (cantrip_names ++ spell_names)
    |> Enum.map(&resolve_spell(&1, custom))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_spell_struct(&1, sc.ability))
  end

  # Resuelve una key de hechizo: custom (`custom_*`) mira el bundle inyectado;
  # el resto cae al catálogo builtin/SRD.
  defp resolve_spell(name, custom) do
    name = to_string(name)

    if String.starts_with?(name, "custom_") do
      case Enum.find(custom[:spells] || [], &(&1.key == name)) do
        nil -> nil
        %{name: n, definition: d} -> spell_data_from_def(n, d)
      end
    else
      Spells.get(name)
    end
  end

  defp spell_data_from_def(name, d) do
    save = defv(d, "save_ability")

    %{
      name: name,
      level: defv(d, "level"),
      kind: to_atom(defv(d, "kind")),
      save_ability: save && to_atom(save),
      dice: defv(d, "dice"),
      damage_type: defv(d, "damage_type"),
      effect: defv(d, "effect")
    }
  end

  defp to_spell_struct(data, casting_ability) do
    %Spell{
      name: data.name,
      level: data.level,
      kind: data.kind,
      casting_ability: casting_ability,
      save_ability: data.save_ability,
      dice: data.dice,
      damage_type: data.damage_type,
      effect: data.effect
    }
  end

  # ---------------------------------------------------------------- skills

  defp validate_skills(class, nil), do: {:ok, default_skills(class)}

  defp validate_skills(%{skill_list: :any, skill_count: count}, skills) when is_list(skills) do
    cond do
      length(skills) != count ->
        {:error, "expected #{count} skills, got #{length(skills)}"}

      length(Enum.uniq(skills)) != length(skills) ->
        {:error, "duplicate skills in: #{inspect(skills)}"}

      true ->
        {:ok, skills}
    end
  end

  defp validate_skills(%{skill_list: list, skill_count: count}, skills) when is_list(skills) do
    invalid = Enum.reject(skills, &(&1 in list))

    cond do
      length(skills) != count ->
        {:error, "expected #{count} skills from the class list, got #{length(skills)}"}

      length(Enum.uniq(skills)) != length(skills) ->
        {:error, "duplicate skills in: #{inspect(skills)}"}

      invalid != [] ->
        {:error, "skills not on the class list: #{inspect(invalid)}"}

      true ->
        {:ok, skills}
    end
  end

  defp default_skills(%{skill_list: :any, skill_count: count}) do
    Enum.take(~w(perception investigation persuasion insight performance), count)
  end

  defp default_skills(%{skill_list: list, skill_count: count}) do
    Enum.take(list, count)
  end

  # --------------------------------------------------------- score guards

  defp validate_final_scores(scores) do
    out =
      Dragones.Character.abilities()
      |> Enum.filter(fn ab ->
        v = scores[ab]
        not (is_integer(v) and v >= 1 and v <= 20)
      end)

    if out == [], do: :ok, else: {:error, "final scores out of range [1, 20]: #{inspect(out)}"}
  end

  # -------------------------------------------------------------- attrs

  defp to_attrs(choices, race, class, bg, scores, hp, ac, eq, spells, skills, languages) do
    race_label = race_display(race, choices)

    # skills de clase (elegidas o default) + skills del trasfondo (extra, sin
    # contar contra el cupo de la clase). Dedup conservando el orden.
    skill_proficiencies =
      (skills ++ Map.get(bg, :skills, []))
      |> Enum.uniq()

    %{
      name: to_string(choices[:name]),
      race: race_label,
      class: class.key,
      sex: choices[:sex],
      side: "pc",
      level: choices[:level] || 1,
      hp: hp,
      max_hp: hp,
      temp_hp: 0,
      ac: ac,
      speed: race.speed,
      str: scores[:str],
      dex: scores[:dex],
      con: scores[:con],
      int: scores[:int],
      wis: scores[:wis],
      cha: scores[:cha],
      backstory: choices[:backstory] || default_backstory(race_label, class, choices),
      weapons: eq.weapons,
      spells: spells,
      inventory: eq.inventory,
      conditions: [],
      death_saves: %{successes: 0, fails: 0},
      saving_proficiencies: Enum.map(class.saves, &Atom.to_string/1),
      skill_proficiencies: skill_proficiencies,
      languages: languages,
      racial_traits: race.traits,
      class_features: class.features,
      background_feature: bg.feature
    }
  end

  defp race_display(%{name: name}, _choices), do: String.downcase(name)

  # Idiomas fijos de raza (+ subraza ya mezclada) + extras elegidos por el
  # usuario. `extra` es el nº total de idiomas extra que tocan (raza + trasfondo,
  # p. ej. humano/acólito/alto elfo). Si el usuario elige duplicados o idiomas
  # que ya tiene por raza, se descartan y se rellenan con defaults para que el
  # personaje reciba siempre el nº de idiomas que le corresponden.
  defp resolve_languages(race, bg, user_extras) do
    extras_needed = (race.extra_languages || 0) + (bg.extra_languages || 0)
    known = race.languages

    chosen =
      user_extras
      |> normalize_list()
      # descarta los que ya sabe por raza y los duplicados entre los elegidos
      |> Enum.reject(&(&1 in known))
      |> Enum.uniq()

    filled = pad_languages(chosen, extras_needed, known)
    (known ++ filled) |> Enum.uniq()
  end

  defp normalize_list(nil), do: []

  defp normalize_list(list) when is_list(list) do
    Enum.flat_map(list, fn
      v when is_binary(v) and v != "" -> [v]
      _ -> []
    end)
  end

  defp normalize_list(_), do: []

  # rellena hasta `needed` idiomas extra: respeta los elegidos válidos y
  # completa con defaults del SRD si faltan.
  defp pad_languages(chosen, needed, _known) when length(chosen) >= needed,
    do: Enum.take(chosen, needed)

  defp pad_languages(chosen, needed, known) do
    remaining = needed - length(chosen)
    taken = (chosen ++ known) |> MapSet.new()
    defaults = ["elvish", "dwarvish", "draconic", "giant", "gnomish"]
    fill = defaults |> Enum.reject(&MapSet.member?(taken, &1)) |> Enum.take(remaining)
    chosen ++ fill
  end

  defp default_backstory(race, class, choices) do
    bg = choices[:background] || "unknown origin"
    "A #{race} #{class.key} of #{bg}, stepping into adventure."
  end

  # ------------------------------------------------------- changeset guard

  defp validate_changeset(attrs) do
    changeset = Character.changeset(%Character{}, attrs)

    if changeset.valid? do
      :ok
    else
      errors =
        Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} ->
          "#{field}: #{msg}"
        end)

      {:error, errors}
    end
  end

  # ---------------------------------------------------------------- helpers

  defp normalize_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
    end)
  end

  defp fetch(_module, nil, field), do: {:error, "#{field} is required"}

  defp fetch(module, key, _field) when is_binary(key) or is_atom(key) do
    module.get(to_string(key))
  end
end
