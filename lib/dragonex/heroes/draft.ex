defmodule Dragonex.Heroes.Draft do
  @moduledoc """
  Pure form ↔ draft mapping for the character creator wizard.

  The LiveView (`DragonexWeb.HeroLive.New`) keeps a plain map "form" with atom
  keys while the user clicks around; this module is the only place that knows
  how to seed that form from a saved hero (draft jsonb or legacy sheet), how to
  serialize it back into the string-keyed draft that `Dragonex.Heroes.build/1`
  and `Accounts.save_hero/4` consume, and the toggle/cap bookkeeping the wizard
  events need.

  Offline by design (D9): no Repo, no DB — safe for `async: true` tests.
  """

  alias Dragonex.{Character, Heroes}
  alias Dragonex.Heroes.{Backgrounds, Classes, Races, Translations}

  @stored_subrace_keys %{
    "mountain dwarf" => "mountain",
    "hill dwarf" => "hill",
    "dark elf (drow)" => "dark elf",
    "lightfoot halfling" => "lightfoot",
    "stout halfling" => "stout"
  }

  # ---------------------------------------------------------------- form seed

  def initial_form do
    %{
      name: "",
      race: nil,
      subrace: nil,
      class: nil,
      sex: nil,
      background: nil,
      backstory: nil,
      score_method: "auto",
      pb: %{str: 8, dex: 8, con: 8, int: 8, wis: 8, cha: 8},
      spells: nil,
      equipment: %{},
      skills_choice: [],
      extra_langs: [],
      extra_equipment: %{weapons: [], items: []}
    }
  end

  def form_from_hero(%{draft: draft}, _sheet) when is_map(draft) and map_size(draft) > 0 do
    initial_form()
    |> Map.merge(%{
      name: draft_get(draft, "name", ""),
      race: draft_get(draft, "race"),
      subrace: draft_get(draft, "subrace"),
      class: draft_get(draft, "class"),
      sex: draft_get(draft, "sex"),
      background: draft_get(draft, "background"),
      backstory: draft_get(draft, "backstory"),
      score_method: draft_get(draft, "score_method", "auto"),
      pb: normalize_pb(draft_get(draft, "pb", %{})),
      spells: normalize_optional_list(draft_get(draft, "spells")),
      equipment: normalize_equipment(draft_get(draft, "equipment", %{})),
      skills_choice: normalize_list(draft_get(draft, "skills_choice")),
      extra_langs: normalize_list(draft_get(draft, "extra_langs")),
      extra_equipment: normalize_extra_equipment(draft_get(draft, "extra_equipment"))
    })
  end

  def form_from_hero(_hero, %Character{} = sheet) do
    {race, subrace} = race_selection(sheet.race)
    background = background_from_feature(sheet.background_feature)

    initial_form()
    |> Map.merge(%{
      name: sheet.name || "",
      race: race,
      subrace: subrace,
      class: sheet.class,
      sex: sheet.sex,
      background: background,
      backstory: sheet.backstory,
      spells: Enum.map(sheet.spells || [], & &1.name),
      skills_choice:
        class_skill_choices(sheet.class, sheet.skill_proficiencies || [], background),
      extra_langs: extra_languages_from_sheet(sheet.languages || [], race, subrace, background),
      extra_equipment: %{weapons: [], items: []}
    })
  end

  # ------------------------------------------------------------- draft output

  def draft_from_form(form) do
    %{
      "name" => form.name,
      "race" => form.race,
      "subrace" => form.subrace,
      "class" => form.class,
      "sex" => form.sex,
      "background" => form.background,
      "backstory" => form.backstory,
      "score_method" => form.score_method,
      "pb" => stringify_map(form.pb || %{}),
      "spells" => form.spells,
      "equipment" => stringify_map(form.equipment || %{}),
      "skills_choice" => form.skills_choice || [],
      "extra_langs" => form.extra_langs || [],
      "extra_equipment" => stringify_extra_equipment(form[:extra_equipment])
    }
  end

  # ------------------------------------------------------------ toggle events

  def toggle_key(list, key) do
    if key in list, do: List.delete(list, key), else: list ++ [key]
  end

  def toggle_item(list, key) do
    existing = Enum.any?(list, &(item_key(&1) == key))

    if existing,
      do: Enum.reject(list, &(item_key(&1) == key)),
      else: list ++ [%{key: key, qty: 1}]
  end

  defp item_key(%{key: k}), do: k
  defp item_key(%{"key" => k}), do: k
  defp item_key(_), do: nil

  # ------------------------------------------------------------ spell cap logic

  def spell_selected?(%{spells: nil, class: class}, name) do
    name in Classes.default_spell_names(class)
  end

  def spell_selected?(%{spells: spells}, name), do: name in spells

  # Nivel de un hechizo por su key: si es `custom_*` mira el bundle inyectado,
  # si no cae al catálogo builtin/SRD. Así los hechizos custom también cuentan
  # hacia el cupo de trucos/nivel-1 de la clase.
  def spell_level(name, custom) do
    name = to_string(name)

    if String.starts_with?(name, "custom_") do
      case Enum.find(custom[:spells] || [], &(&1.key == name)) do
        nil -> nil
        %{definition: d} -> Dragonex.MapUtil.get(d, "level")
      end
    else
      case Dragonex.Heroes.Spells.get(name) do
        %{level: l} -> l
        _ -> nil
      end
    end
  end

  def count_selected(%{spells: nil, class: class}, level, custom) do
    Enum.count(Classes.default_spell_names(class), fn name ->
      spell_level(name, custom) == level
    end)
  end

  def count_selected(%{spells: spells}, level, custom) do
    Enum.count(spells, fn name -> spell_level(name, custom) == level end)
  end

  # ¿añadir `name` superaría el cupo de su nivel?
  def cap_reached?(class_key, current, name, custom) do
    with lvl when lvl != nil <- spell_level(name, custom),
         {:ok, %{spellcasting: sc}} when not is_nil(sc) <- Classes.get(class_key) do
      cap = if lvl == 0, do: sc.cantrips, else: sc.spells_level1
      count = Enum.count(current, fn n -> spell_level(n, custom) == lvl end)
      cap != nil and count >= cap
    else
      _ -> false
    end
  end

  def spell_cap_error(class_key, name, custom) do
    case spell_level(name, custom) do
      0 ->
        {:ok, %{spellcasting: sc}} = Classes.get(class_key)

        "Límite alcanzado: #{sc.cantrips} trucos para #{Translations.class(class_key)}."

      lvl when lvl != nil ->
        {:ok, %{spellcasting: sc}} = Classes.get(class_key)

        "Límite alcanzado: #{sc.spells_level1} hechizos de nivel 1 para #{Translations.class(class_key)}."

      nil ->
        "Hechizo desconocido."
    end
  end

  # --------------------------------------------------------- sheet → form bits

  defp race_selection(nil), do: {nil, nil}

  defp race_selection(value) do
    value = value |> to_string() |> String.trim() |> String.downcase()
    value = Map.get(@stored_subrace_keys, value, value)

    cond do
      value in Heroes.list_races() ->
        {value, nil}

      parent = parent_race_for(value) ->
        {parent, value}

      true ->
        {value, nil}
    end
  end

  defp parent_race_for(subrace) do
    Enum.find(Heroes.list_races(), fn race -> subrace in Heroes.subraces(race) end)
  end

  defp background_from_feature(nil), do: nil

  defp background_from_feature(feature) do
    Enum.find_value(Heroes.list_backgrounds(), fn key ->
      case Backgrounds.get(key) do
        {:ok, %{feature: ^feature}} -> key
        _ -> nil
      end
    end)
  end

  defp class_skill_choices(nil, _skills, _background), do: []

  defp class_skill_choices(class_key, skills, background) do
    bg_skills = background_skills(background)

    case Classes.get(class_key) do
      {:ok, %{skill_list: :any, skill_count: count}} ->
        skill_choices(skills, Translations.skill_keys(), bg_skills, count)

      {:ok, %{skill_list: list, skill_count: count}} ->
        skill_choices(skills, list, bg_skills, count)

      _ ->
        []
    end
  end

  defp skill_choices(skills, pool, bg_skills, count) do
    picked =
      skills
      |> Enum.reject(&(&1 in bg_skills))
      |> Enum.filter(&(&1 in pool))
      |> Enum.uniq()
      |> Enum.take(count)

    fill =
      pool
      |> Enum.reject(&(&1 in picked or &1 in bg_skills))
      |> Enum.take(count - length(picked))

    picked ++ fill
  end

  defp background_skills(nil), do: []

  defp background_skills(background) do
    case Backgrounds.get(background) do
      {:ok, bg} -> bg.skills
      _ -> []
    end
  end

  defp extra_languages_from_sheet(_languages, nil, _subrace, _background), do: []

  defp extra_languages_from_sheet(languages, race, subrace, background) do
    cap = Heroes.extra_language_slots(race, subrace, background)

    fixed =
      case Races.get(race, subrace) do
        {:ok, race_data} -> race_data.languages
        _ -> []
      end

    languages
    |> Enum.reject(&(&1 in fixed))
    |> Enum.uniq()
    |> Enum.take(cap)
  end

  # ------------------------------------------------------------- normalization

  defp draft_get(map, key, default \\ nil), do: Dragonex.MapUtil.get(map, key, default)

  defp normalize_pb(map) when is_map(map) do
    Map.new([:str, :dex, :con, :int, :wis, :cha], fn ability ->
      value = Dragonex.MapUtil.get(map, ability, 8)
      {ability, to_int(value, 8)}
    end)
  end

  defp normalize_pb(_), do: initial_form().pb

  defp normalize_equipment(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_existing_atom(key), to_int(value, 0)} end)
  end

  defp normalize_equipment(_), do: %{}

  defp normalize_extra_equipment(nil), do: %{weapons: [], items: []}

  defp normalize_extra_equipment(map) when is_map(map) do
    weapons = list_get(map, :weapons) |> Enum.map(&to_string/1)

    items =
      list_get(map, :items)
      |> Enum.map(fn
        %{key: k, qty: q} -> %{key: to_string(k), qty: to_int(q, 1)}
        %{"key" => k, "qty" => q} -> %{key: to_string(k), qty: to_int(q, 1)}
        %{"key" => k} -> %{key: to_string(k), qty: 1}
        %{key: k} -> %{key: to_string(k), qty: 1}
        k when is_binary(k) -> %{key: k, qty: 1}
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    %{weapons: weapons, items: items}
  end

  defp list_get(map, key), do: Dragonex.MapUtil.get(map, key, []) || []

  defp stringify_extra_equipment(nil), do: %{"weapons" => [], "items" => []}

  defp stringify_extra_equipment(ee) when is_map(ee) do
    weapons = Enum.map(Dragonex.MapUtil.get(ee, :weapons, []) || [], &to_string/1)

    items =
      Enum.map(Dragonex.MapUtil.get(ee, :items, []) || [], fn
        %{key: k, qty: q} -> %{"key" => to_string(k), "qty" => q}
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    %{"weapons" => weapons, "items" => items}
  end

  defp normalize_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp normalize_list(_), do: []

  defp normalize_optional_list(nil), do: nil
  defp normalize_optional_list(list) when is_list(list), do: normalize_list(list)
  defp normalize_optional_list(_), do: nil

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  # -------------------------------------------------------------- coercions

  def to_existing_atom(value) when is_atom(value), do: value

  def to_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    # Unknown atom: return the binary unchanged rather than creating a new atom.
    # Creating atoms from client-controlled form fields is an atom-table
    # exhaustion (DoS) vector (D8). A non-atom key is simply ignored downstream.
    ArgumentError -> value
  end

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp to_int(_value, default), do: default
end
