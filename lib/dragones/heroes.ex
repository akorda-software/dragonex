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

  alias Dragones.{Character, Item, Spell}
  alias Dragones.Heroes.{Backgrounds, Classes, Equipment, Races, Scoring, Spells}
  alias Dragones.Rules.Ability

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
          optional(:level) => pos_integer()
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
         {:ok, _skills} <- validate_skills(class, choices[:skills]),
         {:ok, base} <- Scoring.resolve(choices[:scores], class.priority),
         bonuses <- resolve_bonuses(race, class),
         final <- Scoring.apply_bonuses(base, bonuses),
         :ok <- validate_final_scores(final),
         eq <- process_equipment(class.equipment ++ bg.equipment),
         hp <- compute_hp(class, final, race, choices[:level] || 1),
         ac <- compute_ac(eq, class, final),
         spells <- build_spells(class, choices[:spells]),
         attrs = to_attrs(choices, race, class, final, hp, ac, eq, spells),
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
          sex: String.t()
        }
  def random_draft do
    race = Enum.random(list_races())
    subs = subraces(race)

    %{
      name: Dragones.Scenarios.random_name(),
      race: race,
      subrace: if(subs != [], do: Enum.random(subs), else: nil),
      class: Enum.random(list_classes()),
      background: Enum.random(list_backgrounds()),
      sex: Enum.random(["hombre", "mujer", "no binario"])
    }
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

  defp process_equipment(slots) do
    Enum.reduce(slots, %{weapons: [], inventory: [], armor: nil, shield: false}, fn
      %{weapon: name}, acc ->
        case Equipment.weapon(name) do
          nil -> acc
          w -> %{acc | weapons: acc.weapons ++ [w]}
        end

      %{armor: name}, acc ->
        case Equipment.armor(name) do
          nil -> acc
          a -> %{acc | armor: a, inventory: acc.inventory ++ [%Item{name: name, qty: 1, kind: :armor}]}
        end

      %{shield: true}, acc ->
        %{acc | shield: true, inventory: acc.inventory ++ [%Item{name: "shield", qty: 1, kind: :armor}]}

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

  # ------------------------------------------------------------------- AC

  defp compute_ac(eq, class, scores) do
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

  defp build_spells(%{spellcasting: nil}, _user_picks), do: []

  defp build_spells(%{spellcasting: sc}, user_picks) do
    {cantrip_names, spell_names} =
      case user_picks do
        nil ->
          {sc.defaults.cantrips, sc.defaults.spells}

        picks when is_list(picks) ->
          Enum.split_with(picks, fn name ->
            case Spells.get(name) do
              %{level: 0} -> true
              _ -> false
            end
          end)
      end

    (cantrip_names ++ spell_names)
    |> Enum.map(&Spells.get/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_spell_struct(&1, sc.ability))
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
    if length(skills) == count do
      {:ok, skills}
    else
      {:error, "expected #{count} skills, got #{length(skills)}"}
    end
  end

  defp validate_skills(%{skill_list: list, skill_count: count}, skills) when is_list(skills) do
    invalid = Enum.reject(skills, &(&1 in list))

    cond do
      length(skills) != count ->
        {:error, "expected #{count} skills from the class list, got #{length(skills)}"}

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

  defp to_attrs(choices, race, class, scores, hp, ac, eq, spells) do
    race_label = race_display(race, choices)

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
      saving_proficiencies: Enum.map(class.saves, &Atom.to_string/1)
    }
  end

  defp race_display(%{name: name}, _choices), do: String.downcase(name)

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
