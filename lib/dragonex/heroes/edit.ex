defmodule Dragonex.Heroes.Edit do
  @moduledoc """
  Offline edits of a saved hero without replaying level-ups or resting it.

  Every preview starts from the same saved sheet and initial form. Identity
  changes only replace the edited fields. Mechanical changes retain level,
  XP and expenditure while rebuilding the relevant derived values. A stored
  creation draft anchors earned ability increases; legacy sheets retain their
  confirmed scores until the player explicitly changes score choices.
  """

  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{Character, ClassResources, Codec, Heroes, WildShape}
  alias Dragonex.Heroes.{Classes, Draft, Equipment, Progression, Spells}

  @abilities ~w(str dex con int wis cha)a
  @identity ~w(name sex backstory)a
  @mechanical ~w(race subrace class background score_method pb spells equipment skills_choice extra_langs extra_equipment)a
  @equipment ~w(class background equipment extra_equipment)a
  @heritage ~w(race subrace background extra_langs)a
  @skills ~w(class background skills_choice)a
  @pools ~w(ki sorcery_points lay_on_hands_pool divine_sense_uses bardic_inspiration_uses wild_shape_uses)a

  @doc "Whether a hero has no trustworthy creation-score baseline."
  def legacy?(%{draft: draft}) when is_map(draft) and map_size(draft) > 0,
    do: draft["preserve_confirmed_scores"] == true

  def legacy?(_), do: true

  @doc "Keep the legacy score policy when the first editable draft is saved."
  def draft(form, hero, updated) do
    draft = Draft.draft_from_form(form)
    spent = spent_pools(updated, spending(hero))
    capacities = ClassResources.capacities(updated)

    draft =
      Map.put(
        draft,
        "edit_resource_spent",
        Map.new(spent, fn {key, value} ->
          {Atom.to_string(key),
           %{
             "spent" => value,
             "remaining" => Map.get(updated, key) || 0,
             "capacity" => Map.get(capacities, key, 0)
           }}
        end)
      )

    if legacy?(hero), do: Map.put(draft, "preserve_confirmed_scores", true), else: draft
  end

  @doc "Spent pool amounts retained across edits, including inactive classes."
  def spending(%{sheet: sheet, draft: draft}) do
    saved = if is_map(draft), do: draft["edit_resource_spent"] || %{}, else: %{}
    sheet = sheet |> Codec.decode_character() |> WildShape.base_form()
    capacities = ClassResources.capacities(sheet)

    history =
      for field <- @pools,
          %{"spent" => spent, "remaining" => remaining, "capacity" => capacity} <-
            [Map.get(saved, Atom.to_string(field))],
          is_integer(spent) and spent >= 0 and is_integer(remaining) and remaining >= 0 and
            is_integer(capacity) and capacity >= 0,
          # A changed active balance/capacity is authoritative after a rest,
          # progression or external sheet update. Unchanged edit projections
          # retain over-cap expenditure across later capacity increases.
          not Map.has_key?(capacities, field) or
            (remaining == Map.get(sheet, field) and capacity == capacities[field]),
          into: %{},
          do: {field, spent}

    spent_pools(sheet, history)
  end

  @spec rebuild(Character.t(), map(), map(), keyword()) ::
          {:ok, Character.t()} | {:error, String.t()}
  def rebuild(%Character{} = original, initial, form, opts \\ []) do
    if not is_binary(form.name) or String.trim(form.name) == "" do
      {:error, dgettext("ui", "Ponle nombre a tu héroe.")}
    else
      if changed?(initial, form, @mechanical) do
        rebuild_mechanics(original, initial, form, opts)
      else
        {:ok, identity(original, initial, form)}
      end
    end
  end

  defp rebuild_mechanics(active, initial, form, opts) do
    original = WildShape.base_form(active)
    custom = Keyword.get(opts, :custom, %{})
    equipment? = changed?(initial, form, @equipment)

    with {:ok, old_base} <- basis(initial),
         {:ok, new_base} <- basis(form),
         {:ok, old_bonus} <- bonuses(initial),
         {:ok, new_bonus} <- bonuses(form),
         scores <- scores(original, initial, form, old_base, new_base, old_bonus, new_bonus, opts),
         {:ok, rebuilt} <- build(form, original.level, scores, new_bonus, equipment?, custom),
         {:ok, spells} <- spells(original, initial, form, custom) do
      same_class? = original.class == rebuilt.class

      max_hp =
        if same_class? and original.race == rebuilt.race and original.con == rebuilt.con,
          do: original.max_hp,
          else: rebuilt.max_hp

      # Begin with the saved sheet so condition state, spent-use flags, temporary
      # HP and every unrelated mechanic survive. Only derived choices change.
      updated =
        original
        |> Map.merge(Map.take(rebuilt, @abilities ++ [:race, :class]))
        |> Map.put(:max_hp, max_hp)
        |> Map.put(:hp, min(original.hp, max_hp))
        |> Map.put(:spells, spells)
        |> Map.put(:class_features, features(original, rebuilt, same_class?))
        |> Map.put(
          :fighting_style,
          if(same_class?, do: original.fighting_style, else: rebuilt.fighting_style)
        )
        |> maybe_replace(rebuilt, equipment?, [:inventory, :weapons])
        |> maybe_replace(rebuilt, changed?(initial, form, @skills), [:skill_proficiencies])
        |> maybe_replace(rebuilt, not same_class?, [:saving_proficiencies])
        |> maybe_replace(rebuilt, changed?(initial, form, @heritage), [
          :languages,
          :background_feature
        ])
        |> maybe_replace(rebuilt, changed?(initial, form, [:race, :subrace]), [
          :racial_traits,
          :speed
        ])
        |> identity(initial, form)
        |> preserve_pools(original, opts)
        |> update_expertise(original, initial, form)
        |> update_resistances(original, old_base, rebuilt)
        |> update_ac(original)
        |> remove_incompatible_effects(original)

      updated =
        if active.wild_shape != nil and updated.class == "druid",
          do: WildShape.preserve_form(updated, active),
          else: updated

      {:ok, updated}
    end
  end

  # Only race/class/base-score choices matter to the ability baseline. Do not
  # require old custom equipment or spells to remain in today's catalogue.
  defp basis(form, scores \\ :form) do
    Heroes.build(%{
      name: "Héroe",
      race: form.race,
      subrace: form.subrace,
      class: form.class,
      background: form.background || "soldier",
      scores: if(scores == :form, do: form_scores(form), else: scores)
    })
  end

  defp bonuses(form) do
    with {:ok, base} <- basis(form, Map.new(@abilities, &{&1, 8})) do
      {:ok, Map.new(@abilities, &{&1, Map.fetch!(base, &1) - 8})}
    end
  end

  defp scores(original, initial, form, old_base, new_base, old_bonus, new_bonus, opts) do
    cond do
      Keyword.get(opts, :legacy, false) and changed?(initial, form, [:score_method, :pb]) ->
        Map.take(new_base, @abilities)

      Keyword.get(opts, :legacy, false) ->
        Map.new(@abilities, &{&1, Map.fetch!(original, &1) + new_bonus[&1] - old_bonus[&1]})

      true ->
        Map.new(@abilities, fn ability ->
          earned = Map.fetch!(original, ability) - Map.fetch!(old_base, ability)
          {ability, Map.fetch!(new_base, ability) + earned}
        end)
    end
  end

  defp build(form, level, scores, bonuses, equipment?, custom) do
    Heroes.build(%{
      name: form.name,
      race: form.race,
      subrace: form.subrace,
      class: form.class,
      background: form.background,
      sex: form.sex,
      backstory: form.backstory,
      level: level,
      scores: Map.new(@abilities, &{&1, scores[&1] - bonuses[&1]}),
      skills: if(form.skills_choice == [], do: nil, else: form.skills_choice),
      extra_languages: form.extra_langs,
      equipment_picks: if(equipment?, do: form.equipment, else: %{}),
      extra_equipment: if(equipment?, do: form.extra_equipment, else: nil),
      custom: custom
    })
  end

  defp form_scores(%{score_method: "pointbuy", pb: scores}), do: scores
  defp form_scores(_), do: nil

  defp spells(original, initial, form, custom) do
    if original.class == form.class and not changed?(initial, form, [:spells]) do
      {:ok, original.spells}
    else
      picks = form.spells || Classes.default_spell_names(form.class)

      initial_names =
        spell_names(initial.spells || Classes.default_spell_names(initial.class), custom)

      ability = casting_ability(form.class)
      max_level = Progression.max_spell_level(form.class, original.level)

      with {:ok, selected} <- selected_spells(picks, form.class, max_level, ability, custom) do
        earned =
          original.spells
          |> Enum.reject(&(&1.name in initial_names))
          |> Enum.filter(fn spell ->
            original.class == form.class or
              compatible_spell?(spell, form.class, max_level, custom)
          end)
          |> Enum.map(&%{&1 | casting_ability: ability})

        {:ok, Enum.uniq_by(selected ++ earned, & &1.name)}
      end
    end
  end

  defp selected_spells(picks, class, max_level, ability, custom) do
    Enum.reduce_while(picks, {:ok, []}, fn key, {:ok, spells} ->
      case Spells.resolve(key, custom) do
        nil ->
          {:halt, {:error, dgettext("engine", "hechizos desconocidos: %{spells}", spells: key)}}

        data ->
          if ability != nil and data.level <= max_level and allowed?(data, class) do
            {:cont, {:ok, spells ++ [Spells.to_character_spell(data, ability)]}}
          else
            {:halt,
             {:error,
              dgettext("engine", "hechizos fuera de la lista de la clase: %{spells}", spells: key)}}
          end
      end
    end)
  end

  defp spell_names(picks, custom) do
    Enum.map(picks, fn key ->
      case Spells.resolve(key, custom) do
        nil -> to_string(key)
        spell -> spell.name
      end
    end)
  end

  defp compatible_spell?(spell, class, max_level, custom) do
    data =
      Spells.get(spell.name) ||
        case Enum.find(custom[:spells] || [], &(&1.name == spell.name)) do
          nil -> nil
          entry -> Spells.resolve(entry.key, custom)
        end

    data != nil and casting_ability(class) != nil and spell.level <= max_level and
      allowed?(data, class)
  end

  defp allowed?(%{classes: classes}, class) when is_list(classes), do: class in classes
  defp allowed?(_custom, _class), do: true

  defp casting_ability("paladin"), do: :cha
  defp casting_ability("ranger"), do: :wis

  defp casting_ability(class) do
    case Classes.get(class) do
      {:ok, %{spellcasting: %{ability: ability}}} -> ability
      _ -> nil
    end
  end

  defp features(original, _rebuilt, true), do: original.class_features

  defp features(_original, rebuilt, false),
    do:
      Enum.uniq(
        rebuilt.class_features ++
          Enum.flat_map(1..rebuilt.level, &Progression.features_at(rebuilt.class, &1))
      )

  defp preserve_pools(updated, original, opts) do
    spent = spent_pools(original, Keyword.get(opts, :spent, %{}))

    Enum.reduce(ClassResources.capacities(updated), updated, fn {field, capacity}, next ->
      Map.put(next, field, max(0, capacity - Map.get(spent, field, 0)))
    end)
  end

  defp spent_pools(sheet, history) do
    Enum.reduce(ClassResources.capacities(sheet), history, fn {field, capacity}, spent ->
      used = max(0, capacity - (Map.get(sheet, field) || 0))
      Map.update(spent, field, used, &max(&1, used))
    end)
  end

  defp update_expertise(updated, original, initial, form) do
    if changed?(initial, form, @skills) do
      expertise =
        original.expertise
        |> Enum.filter(&(&1 in updated.skill_proficiencies))
        |> Enum.take(Progression.expertise_count(updated.class, updated.level))

      %{updated | expertise: expertise}
    else
      updated
    end
  end

  defp update_resistances(updated, original, old_base, rebuilt) do
    if original.race == rebuilt.race do
      updated
    else
      %{
        updated
        | damage_resistances:
            Enum.uniq(
              (original.damage_resistances -- old_base.damage_resistances) ++
                rebuilt.damage_resistances
            )
      }
    end
  end

  defp update_ac(updated, original) do
    equipment = armor(updated)

    if updated.class == original.class and equipment == armor(original) and
         Map.take(updated, [:dex, :con, :wis]) == Map.take(original, [:dex, :con, :wis]) do
      updated
    else
      {:ok, class} = Classes.get(updated.class)
      %{updated | ac: Heroes.compute_ac(equipment, class, Map.take(updated, @abilities))}
    end
  end

  defp armor(character) do
    armor =
      Enum.find_value(character.inventory, fn
        %{kind: :armor, name: name} when name != "shield" -> Equipment.armor(name)
        _ -> nil
      end)

    shield? = Enum.any?(character.inventory, &match?(%{kind: :armor, name: "shield"}, &1))
    %{armor: armor, shield: shield?}
  end

  defp remove_incompatible_effects(updated, original) do
    updated
    |> then(fn c ->
      if c.class == "barbarian", do: c, else: %{c | raging: false, reckless: false}
    end)
    |> then(fn c -> if c.class == "paladin", do: c, else: %{c | smite_slot: nil} end)
    |> then(fn c -> if c.class == "sorcerer", do: c, else: %{c | metamagic: nil} end)
    |> then(fn c -> if c.class == "rogue", do: c, else: %{c | uncanny_dodge: false} end)
    |> then(fn c ->
      if (c.class == original.class and c.spells == original.spells) or concentration_known?(c),
        do: c,
        else: %{c | concentrating: nil}
    end)
  end

  defp concentration_known?(%{class: "ranger", concentrating: "hunter's mark:" <> _}), do: true
  defp concentration_known?(c), do: Enum.any?(c.spells, &(&1.name == c.concentrating))

  defp identity(sheet, initial, form) do
    Enum.reduce(@identity, sheet, fn field, sheet ->
      if Map.get(initial, field) == Map.get(form, field),
        do: sheet,
        else: Map.put(sheet, field, Map.get(form, field))
    end)
  end

  defp maybe_replace(sheet, candidate, true, fields),
    do: Map.merge(sheet, Map.take(candidate, fields))

  defp maybe_replace(sheet, _candidate, false, _fields), do: sheet

  defp changed?(initial, form, fields),
    do: Enum.any?(fields, &(Map.get(initial, &1) != Map.get(form, &1)))
end
