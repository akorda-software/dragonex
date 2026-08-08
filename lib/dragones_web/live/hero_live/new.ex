defmodule DragonesWeb.HeroLive.New do
  @moduledoc """
  The character creator — a multi-step LiveView wizard that builds a level-1
  D&D 5e character through `Dragones.Heroes.build/1` and saves it to the user's
  account.

  Steps: Identidad → Linaje → Detalles → Revisión.
  All stats (HP, AC, speed, spells, weapons) are auto-derived from 5e rules.
  """

  use Phoenix.LiveView, layout: {DragonesWeb.Layouts, :app}

  alias Dragones.{Character, Heroes, I18n}
  alias Dragones.Heroes.{Backgrounds, Catalog, Classes, Races, Scoring, Spells}

  @order [:identity, :heritage, :equipment, :details, :review]

  @impl true
  def mount(params, session, socket) do
    case Dragones.Accounts.get_user(session["user_id"]) do
      nil ->
        {:ok, Phoenix.LiveView.redirect(socket, to: "/login")}

      user ->
        socket =
          socket
          |> assign(:current_user, user)
          |> assign(:locale, I18n.locale())
          |> assign(:error, nil)
          |> assign(:custom, Dragones.Accounts.custom_bundle(user))

        mount_mode(params, user, socket)
    end
  end

  # --- random hero ---

  def handle_event("random", _params, socket) do
    draft = Heroes.random_draft()

    form =
      initial_form()
      |> Map.merge(%{
        name: draft.name,
        race: draft.race,
        subrace: draft.subrace,
        class: draft.class,
        sex: draft.sex,
        background: draft.background,
        score_method: draft.score_method,
        pb: draft.pb,
        backstory: draft.backstory,
        spells: draft.spells,
        equipment: draft.equipment,
        skills_choice: draft.skills_choice,
        extra_langs: draft.extra_langs
      })

    {:noreply, socket |> assign(form: form, step: :review, error: nil) |> refresh_preview()}
  end

  # --- navigation ---

  @impl true
  def handle_event("next", _params, socket) do
    current = socket.assigns.step
    form = socket.assigns.form

    if step_complete?(form, current) do
      {:noreply, socket |> assign(step: next_step(current), error: nil) |> refresh_preview()}
    else
      {:noreply, assign(socket, :error, step_error(current, form))}
    end
  end

  def handle_event("back", _params, socket) do
    {:noreply, assign(socket, step: prev(socket.assigns.step), error: nil)}
  end

  def handle_event("goto", %{"step" => step_str}, socket) do
    target = String.to_existing_atom(step_str)

    if step_reachable?(socket.assigns.form, target) do
      {:noreply, socket |> assign(step: target, error: nil) |> refresh_preview()}
    else
      {:noreply, assign(socket, :error, "Completa los pasos anteriores antes de saltar a este.")}
    end
  end

  # --- selection (grid clicks) ---

  def handle_event("select", %{"field" => field, "value" => value}, socket) do
    key = String.to_atom(field)
    # Limpia dependientes al cambiar una selección:
    #   raza/subraza/clase/trasfondo afectan a skills/idiomas/equipo/hechizos
    form =
      socket.assigns.form
      |> Map.put(key, if(value == "", do: nil, else: value))
      |> then(fn f ->
        if key == :race, do: f |> Map.put(:subrace, nil) |> Map.put(:extra_langs, []), else: f
      end)
      |> then(fn f -> if key == :subrace, do: Map.put(f, :extra_langs, []), else: f end)
      |> then(fn f ->
        if key == :class,
          do:
            f |> Map.put(:spells, nil) |> Map.put(:equipment, %{}) |> Map.put(:skills_choice, []),
          else: f
      end)
      |> then(fn f -> if key == :background, do: Map.put(f, :extra_langs, []), else: f end)

    {:noreply, socket |> assign(:form, form) |> refresh_preview()}
  end

  # --- equipment pick (one option per group) ---

  def handle_event("equip", %{"group" => group, "index" => index}, socket) do
    gid = String.to_existing_atom(group)
    idx = String.to_integer(index)
    equipment = Map.put(socket.assigns.form.equipment || %{}, gid, idx)
    form = %{socket.assigns.form | equipment: equipment}
    {:noreply, socket |> assign(:form, form) |> refresh_preview()}
  end

  # --- skill toggle (respeta el cupo de la clase; el trasfondo suma aparte) ---

  def handle_event("skill_toggle", %{"skill" => key}, socket) do
    current = socket.assigns.form.skills_choice || []
    count = (skill_opts(socket.assigns.form.class) || %{count: 0}).count

    cond do
      key in current ->
        form = %{socket.assigns.form | skills_choice: List.delete(current, key)}
        {:noreply, socket |> assign(:form, form) |> assign(:error, nil) |> refresh_preview()}

      length(current) >= count ->
        {:noreply, assign(socket, :error, "Ya tienes tus #{count} habilidades de clase.")}

      true ->
        form = %{socket.assigns.form | skills_choice: current ++ [key]}
        {:noreply, socket |> assign(:form, form) |> assign(:error, nil) |> refresh_preview()}
    end
  end

  # --- extra language toggle (respeta el nº de idiomas extra que tocan) ---

  def handle_event("lang_toggle", %{"lang" => key}, socket) do
    current = socket.assigns.form.extra_langs || []
    cap = extra_langs(socket.assigns.form)

    cond do
      key in current ->
        form = %{socket.assigns.form | extra_langs: List.delete(current, key)}
        {:noreply, socket |> assign(:form, form) |> assign(:error, nil) |> refresh_preview()}

      length(current) >= cap ->
        {:noreply, assign(socket, :error, "Ya tienes tus #{cap} idiomas extra.")}

      true ->
        form = %{socket.assigns.form | extra_langs: current ++ [key]}
        {:noreply, socket |> assign(:form, form) |> assign(:error, nil) |> refresh_preview()}
    end
  end

  # --- point-buy adjust (+/- on ability scores) ---

  def handle_event("pb_adjust", %{"ability" => ab, "delta" => delta}, socket) do
    ab_atom = String.to_atom(ab)
    delta_int = String.to_integer(delta)

    form =
      case Scoring.apply_delta(socket.assigns.form.pb, ab_atom, delta_int) do
        {:ok, new_pb} -> %{socket.assigns.form | pb: new_pb, score_method: "pointbuy"}
        {:error, :no_budget} -> socket.assigns.form
      end

    {:noreply, socket |> assign(:form, form) |> refresh_preview()}
  end

  # --- spell toggle (respeta el cupo de trucos/nivel-1 de la clase) ---

  def handle_event("spell_toggle", %{"spell" => name}, socket) do
    current = socket.assigns.form.spells || Classes.default_spell_names(socket.assigns.form.class)
    class_key = socket.assigns.form.class

    cond do
      name in current ->
        # deseleccionar siempre permitido
        form = %{socket.assigns.form | spells: List.delete(current, name)}
        {:noreply, socket |> assign(:form, form) |> assign(:error, nil) |> refresh_preview()}

      cap_reached?(class_key, current, name, socket.assigns[:custom] || %{}) ->
        # ya está al cupo de ese nivel: no añade más
        {:noreply,
         assign(socket, :error, spell_cap_error(class_key, name, socket.assigns[:custom] || %{}))}

      true ->
        form = %{socket.assigns.form | spells: current ++ [name]}
        {:noreply, socket |> assign(:form, form) |> assign(:error, nil) |> refresh_preview()}
    end
  end

  # --- text input change (form phx-change) ---

  def handle_event("extra_weapon_toggle", %{"key" => key}, socket) do
    form = socket.assigns.form
    ee = Map.get(form, :extra_equipment) || %{weapons: [], items: []}
    weapons = toggle_key(Map.get(ee, :weapons, []), key)
    form = %{form | extra_equipment: Map.put(ee, :weapons, weapons)}
    {:noreply, socket |> assign(:form, form) |> assign(:error, nil) |> refresh_preview()}
  end

  def handle_event("extra_item_toggle", %{"key" => key}, socket) do
    form = socket.assigns.form
    ee = Map.get(form, :extra_equipment) || %{weapons: [], items: []}
    items = toggle_item(Map.get(ee, :items, []), key)
    form = %{form | extra_equipment: Map.put(ee, :items, items)}
    {:noreply, socket |> assign(:form, form) |> assign(:error, nil) |> refresh_preview()}
  end

  def handle_event("change", params, socket) do
    field = List.first(params["_target"] || [])
    value = if field, do: Map.get(params, field, ""), else: ""

    form =
      if field do
        key = String.to_atom(field)
        normalized = if value == "", do: nil, else: value

        socket.assigns.form
        |> Map.put(key, normalized)
        # al cambiar subraza cambian los idiomas extra que tocan → reset
        |> then(fn f -> if key == :subrace, do: Map.put(f, :extra_langs, []), else: f end)
      else
        socket.assigns.form
      end

    {:noreply, socket |> assign(:form, form) |> refresh_preview()}
  end

  # --- save ---

  def handle_event("save", _params, %{assigns: %{preview: %Character{} = char}} = socket) do
    result =
      case socket.assigns.mode do
        :edit ->
          Dragones.Accounts.update_hero(
            socket.assigns.current_user,
            socket.assigns.hero.id,
            char,
            draft_from_form(socket.assigns.form)
          )

        :new ->
          Dragones.Accounts.save_hero(
            socket.assigns.current_user,
            char,
            draft_from_form(socket.assigns.form)
          )
      end

    case result do
      {:ok, _hero} ->
        {:noreply, Phoenix.LiveView.push_navigate(socket, to: "/heroes")}

      {:error, :in_game} ->
        {:noreply,
         assign(socket, :error, "Este héroe ya está en una partida y no se puede actualizar.")}

      {:error, _} ->
        {:noreply, assign(socket, :error, "No se pudo guardar.")}
    end
  end

  def handle_event("save", _, socket), do: {:noreply, assign(socket, :error, "Faltan datos.")}

  # --- helpers ---

  @stored_subrace_keys %{
    "mountain dwarf" => "mountain",
    "hill dwarf" => "hill",
    "dark elf (drow)" => "dark elf",
    "lightfoot halfling" => "lightfoot",
    "stout halfling" => "stout"
  }

  defp mount_mode(%{"id" => id}, user, socket) do
    case Dragones.Accounts.get_user_hero(user, id) do
      nil ->
        {:ok, Phoenix.LiveView.redirect(socket, to: "/heroes")}

      hero ->
        if Dragones.Accounts.hero_used?(hero) do
          {:ok, Phoenix.LiveView.redirect(socket, to: "/heroes/#{hero.id}")}
        else
          sheet = Dragones.Accounts.hero_sheet(hero)

          {:ok,
           socket
           |> assign(:mode, :edit)
           |> assign(:hero, hero)
           |> assign(:step, :review)
           |> assign(:preview, sheet)
           |> assign(:form, form_from_hero(hero, sheet))}
        end
    end
  end

  defp mount_mode(_params, _user, socket) do
    {:ok,
     socket
     |> assign(:mode, :new)
     |> assign(:hero, nil)
     |> assign(:step, :identity)
     |> assign(:preview, nil)
     |> assign(:form, initial_form())}
  end

  defp initial_form do
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

  defp form_from_hero(%{draft: draft}, _sheet) when is_map(draft) and map_size(draft) > 0 do
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

  defp form_from_hero(_hero, %Character{} = sheet) do
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

  defp draft_from_form(form) do
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

  defp draft_get(map, key, default \\ nil), do: Dragones.MapUtil.get(map, key, default)

  defp normalize_pb(map) when is_map(map) do
    Map.new([:str, :dex, :con, :int, :wis, :cha], fn ability ->
      value = Dragones.MapUtil.get(map, ability, 8)
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

  defp list_get(map, key), do: Dragones.MapUtil.get(map, key, []) || []

  defp stringify_extra_equipment(nil), do: %{"weapons" => [], "items" => []}

  defp stringify_extra_equipment(ee) when is_map(ee) do
    weapons = Enum.map(Dragones.MapUtil.get(ee, :weapons, []) || [], &to_string/1)

    items =
      Enum.map(Dragones.MapUtil.get(ee, :items, []) || [], fn
        %{key: k, qty: q} -> %{"key" => to_string(k), "qty" => q}
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    %{"weapons" => weapons, "items" => items}
  end

  defp toggle_key(list, key) do
    if key in list, do: List.delete(list, key), else: list ++ [key]
  end

  defp toggle_item(list, key) do
    existing = Enum.any?(list, &(item_key(&1) == key))

    if existing,
      do: Enum.reject(list, &(item_key(&1) == key)),
      else: list ++ [%{key: key, qty: 1}]
  end

  defp item_key(%{key: k}), do: k
  defp item_key(%{"key" => k}), do: k
  defp item_key(_), do: nil

  defp normalize_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp normalize_list(_), do: []

  defp normalize_optional_list(nil), do: nil
  defp normalize_optional_list(list) when is_list(list), do: normalize_list(list)
  defp normalize_optional_list(_), do: nil

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

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
        skill_choices(skills, Dragones.Heroes.Translations.skill_keys(), bg_skills, count)

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

  defp to_existing_atom(value) when is_atom(value), do: value

  defp to_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> String.to_atom(value)
  end

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp to_int(_value, default), do: default

  defp refresh_preview(socket) do
    form = socket.assigns.form

    if form.race && form.class && form.background do
      scores = if form.score_method == "pointbuy", do: form.pb, else: nil

      case Heroes.build(%{
             name: if(form.name == "", do: "Héroe", else: form.name),
             race: form.race,
             subrace: form.subrace,
             class: form.class,
             sex: form.sex,
             background: form.background,
             scores: scores,
             spells: form.spells,
             equipment_picks: form.equipment,
             skills: form.skills_choice,
             extra_languages: form.extra_langs,
             backstory: form.backstory,
             custom: socket.assigns.custom,
             extra_equipment: form.extra_equipment
           }) do
        {:ok, char} ->
          char = if form.name != "", do: %{char | name: form.name}, else: char
          assign(socket, preview: char, error: nil)

        {:error, msg} ->
          assign(socket, preview: nil, error: msg)
      end
    else
      assign(socket, :preview, nil)
    end
  end

  defp next_step(:identity), do: :heritage
  defp next_step(:heritage), do: :equipment
  defp next_step(:equipment), do: :details
  defp next_step(:details), do: :review
  defp next_step(:review), do: :review

  defp prev(:heritage), do: :identity
  defp prev(:equipment), do: :heritage
  defp prev(:details), do: :equipment
  defp prev(:review), do: :details
  defp prev(_), do: :identity

  # A step is "complete" when its required choices are filled — used both to
  # gate the "Siguiente" button and to decide whether a tab is reachable.
  defp step_complete?(f, :identity) do
    f.name != "" and f.race != nil and f.class != nil and
      (Heroes.subraces(f.race) == [] or f.subrace != nil)
  end

  defp step_complete?(f, :heritage), do: f.background != nil
  defp step_complete?(_f, :equipment), do: true
  defp step_complete?(_f, :details), do: true
  defp step_complete?(_f, :review), do: true

  defp step_error(:identity, f) do
    cond do
      f.name == "" -> "Ponle nombre a tu héroe."
      f.race == nil -> "Elige una raza."
      f.class == nil -> "Elige una clase."
      f.race && Heroes.subraces(f.race) != [] && f.subrace == nil -> "Elige una subraza."
      true -> "Completa la identidad."
    end
  end

  defp step_error(:heritage, f) do
    if f.background == nil, do: "Elige un trasfondo.", else: "Completa el linaje."
  end

  # A tab is reachable when every step before it is complete (identity always is).
  defp step_reachable?(form, target) do
    idx = Enum.find_index(@order, &(&1 == target))
    @order |> Enum.take(idx) |> Enum.all?(&step_complete?(form, &1))
  end

  defp step_status(current, step) do
    cond do
      current == step -> "active"
      Enum.find_index(@order, &(&1 == step)) < Enum.find_index(@order, &(&1 == current)) -> "done"
      true -> ""
    end
  end

  # --- render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="creator">

      <.link navigate="/heroes" class="nav-back">← mis héroes</.link>
      <div class="creator-head">
        <h1>{if @mode == :edit, do: "Editar héroe", else: "⚔ Forjar un héroe"}</h1>
        <div class="sub">D&D 5e · Nivel 1 · SRD</div>
        <button type="button" class="btn-random" phx-click="random">🎲 Héroe aleatorio</button>
      </div>

      <section class="creator-panel">
        <div class="steps">
          <button type="button"
                  class={"s #{step_status(@step, :identity)} clickable"}
                  phx-click="goto" phx-value-step="identity">
            1 · Identidad
          </button>
          <% reachable_h = step_reachable?(@form, :heritage) %>
          <button type="button"
                  class={"s #{step_status(@step, :heritage)} #{if reachable_h, do: "clickable", else: "locked"}"}
                  disabled={not reachable_h}
                  title={if not reachable_h, do: "Completa Identidad primero", else: nil}
                  phx-click={if reachable_h, do: "goto", else: nil} phx-value-step="heritage">
            2 · Linaje
          </button>
          <% reachable_e = step_reachable?(@form, :equipment) %>
          <button type="button"
                  class={"s #{step_status(@step, :equipment)} #{if reachable_e, do: "clickable", else: "locked"}"}
                  disabled={not reachable_e}
                  title={if not reachable_e, do: "Completa Identidad y Linaje primero", else: nil}
                  phx-click={if reachable_e, do: "goto", else: nil} phx-value-step="equipment">
            3 · Equipo
          </button>
          <% reachable_d = step_reachable?(@form, :details) %>
          <button type="button"
                  class={"s #{step_status(@step, :details)} #{if reachable_d, do: "clickable", else: "locked"}"}
                  disabled={not reachable_d}
                  title={if not reachable_d, do: "Completa los pasos anteriores primero", else: nil}
                  phx-click={if reachable_d, do: "goto", else: nil} phx-value-step="details">
            4 · Detalles
          </button>
          <% reachable_r = step_reachable?(@form, :review) %>
          <button type="button"
                  class={"s #{step_status(@step, :review)} #{if reachable_r, do: "clickable", else: "locked"}"}
                  disabled={not reachable_r}
                  title={if not reachable_r, do: "Completa los pasos anteriores primero", else: nil}
                  phx-click={if reachable_r, do: "goto", else: nil} phx-value-step="review">
            5 · Revisión
          </button>
        </div>

        <form phx-submit="next">
          <%= case @step do %>
            <% :identity -> %>
              <.identity_step form={@form} locale={@locale} />
            <% :heritage -> %>
              <.heritage_step form={@form} locale={@locale} />
            <% :equipment -> %>
              <.equipment_step form={@form} locale={@locale} />
            <% :details -> %>
              <.details_step form={@form} locale={@locale} custom={@custom} />
            <% :review -> %>
              <.review_step preview={@preview} locale={@locale} />
          <% end %>
        </form>

        <div :if={@error} class="error">{@error}</div>

        <div class="actions">
          <button :if={@step != :identity} type="button" class="btn btn-back" phx-click="back">← Atrás</button>
          <span :if={@step == :identity} />
          <button :if={@step != :review} type="button" class="btn btn-primary" phx-click="next">Siguiente →</button>
          <button :if={@step == :review && @preview} type="button" class="btn btn-primary" phx-click="save">{if @mode == :edit, do: "Actualizar héroe", else: "⚔ Guardar héroe"}</button>
        </div>
      </section>

      <.preview_card :if={@preview && @step != :review} preview={@preview} locale={@locale} />
    </div>
    """
  end

  # --- steps ---

  attr(:form, :map, required: true)
  attr(:locale, :atom, default: :es)

  defp identity_step(assigns) do
    ~H"""
    <div>
      <div class="step-label">Nombre</div>
      <input type="text" name="name" value={@form.name} phx-change="change" placeholder="Lyra, Thane, Vex…" />

      <div class="step-label">Sexo</div>
      <div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(120px,1fr));">
        <%= for sex <- ["hombre", "mujer", "no binario"] do %>
          <div class={"opt #{if @form.sex == sex, do: "sel", else: ""}"}
               phx-click="select" phx-value-field="sex" phx-value-value={sex}>
            <div class="on">{String.capitalize(sex)}</div>
          </div>
        <% end %>
      </div>

      <div class="step-label">Raza</div>
      <div class="grid">
        <%= for race <- Catalog.races(@locale) do %>
          <div class={"opt #{if @form.race == race.key, do: "sel", else: ""}"}
               phx-click="select" phx-value-field="race" phx-value-value={race.key}>
            <div class="on">{race.label}</div>
            <div class="od">{subrace_hint(race)}</div>
          </div>
        <% end %>
      </div>

      <div :if={@form.race && subraces_for(@form.race, @locale) != []}>
        <div class="step-label">Subraza</div>
        <select class="select-row" name="subrace" phx-change="change">
          <option value="">(elige subraza)</option>
          <%= for sr <- subraces_for(@form.race, @locale) do %>
            <option value={sr.key} selected={@form.subrace == sr.key}>{sr.label}</option>
          <% end %>
        </select>
      </div>

      <div class="step-label">Clase</div>
      <div class="grid">
        <%= for class <- Catalog.classes(@locale) do %>
          <div class={"opt #{if @form.class == class.key, do: "sel", else: ""}"}
               phx-click="select" phx-value-field="class" phx-value-value={class.key}>
            <div class="on">{class.label}</div>
            <div class="od">{class_hint(class)}</div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp heritage_step(assigns) do
    ~H"""
    <div>
      <div class="step-label">Trasfondo</div>
      <div class="grid">
        <%= for bg <- Catalog.backgrounds(@locale) do %>
          <div class={"opt #{if @form.background == bg.key, do: "sel", else: ""}"}
               phx-click="select" phx-value-field="background" phx-value-value={bg.key}>
            <div class="on">{bg.label}</div>
          </div>
        <% end %>
      </div>

      <div class="step-label">Puntuaciones de característica</div>
      <div class="grid" style="grid-template-columns:1fr 1fr;">
        <div class={"opt #{if @form.score_method == "auto", do: "sel", else: ""}"}
             phx-click="select" phx-value-field="score_method" phx-value-value="auto">
          <div class="on">Standard Array</div>
          <div class="od">Auto: 15·14·13·12·10·8</div>
        </div>
        <div class={"opt #{if @form.score_method == "pointbuy", do: "sel", else: ""}"}
             phx-click="select" phx-value-field="score_method" phx-value-value="pointbuy">
          <div class="on">Point Buy</div>
          <div class="od">27 pts · rango 8–15</div>
        </div>
      </div>

      <div :if={@form.score_method == "pointbuy"} style="margin-top:1rem;">
        <div class="step-label">
          Point Buy — Restantes: <strong style="color:#fc8;">{Scoring.point_buy_remaining(@form.pb)}</strong> pts
        </div>
        <div class="pb-grid">
          <%= for ab <- [:str, :dex, :con, :int, :wis, :cha] do %>
            <% val = @form.pb[ab]
               cost = Scoring.cost_for(val)
               ab_label = Dragones.Heroes.Translations.ability_short(ab, @locale) %>
            <div class="pb-row">
              <span class="pb-ab">{ab_label}</span>
              <button type="button" class="pb-btn" phx-click="pb_adjust" phx-value-ability={ab} phx-value-delta="-1">−</button>
              <span class="pb-val">{val}</span>
              <button type="button" class="pb-btn" phx-click="pb_adjust" phx-value-ability={ab} phx-value-delta="1">+</button>
              <span class="pb-cost">({cost}p)</span>
            </div>
          <% end %>
        </div>
        <div class="od" style="color:#555;font-size:.72rem;margin-top:.3rem;">
          Costes: 8→0, 9→1, 10→2, 11→3, 12→4, 13→5, 14→7, 15→9
        </div>
      </div>

      <div :if={@form.score_method == "auto"} class="od" style="text-align:center;color:#555;font-size:.78rem;margin-top:.3rem;">
        Asignado automáticamente según la prioridad de la clase.
      </div>

      <.skill_picker :if={@form.class} form={@form} locale={@locale} />
      <.language_picker :if={extra_langs(@form) > 0} form={@form} locale={@locale} count={extra_langs(@form)} />

    </div>
    """
  end

  defp skill_picker(assigns) do
    ~H"""
    <div style="margin-top:1rem;">
      <div class="step-label">
        Habilidades
        <span :if={skill_opts(@form.class)} style="color:#889;font-weight:normal;font-size:.78rem;">
          ({skill_selected_count(@form)}/{skill_opts(@form.class).count}) · el trasfondo añade las suyas gratis
        </span>
      </div>
      <div class="od" style="color:#555;font-size:.78rem;margin-bottom:.4rem;">
        Elige las habilidades de tu clase. Las del trasfondo se suman automáticamente.
      </div>
      <div class="spell-chips">
        <%= with %{count: count, options: options} <- skill_opts(@form.class) do %>
          <% selected = @form.skills_choice || [] %>
          <% full = length(selected) >= count %>
          <%= for opt <- options do %>
            <% on = opt.key in selected
               locked = full and not on %>
            <button type="button"
                    class={"spell-chip #{if on, do: "sel", else: ""} #{if locked, do: "locked", else: ""}"}
                    disabled={locked}
                    phx-click={if not locked, do: "skill_toggle"}
                    phx-value-skill={opt.key}>
              {opt.label}
            </button>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp language_picker(assigns) do
    ~H"""
    <div style="margin-top:1rem;">
      <div class="step-label">
        Idiomas adicionales
        <span style="color:#889;font-weight:normal;font-size:.78rem;">
          ({lang_selected_count(@form)}/{@count})
        </span>
      </div>
      <div class="od" style="color:#555;font-size:.78rem;margin-bottom:.4rem;">
        Tu raza o trasfondo te deja elegir idiomas extra.
      </div>
      <div class="spell-chips">
        <%= for key <- extra_language_choices(@form, @locale) do %>
          <% on = key in (@form.extra_langs || [])
             locked = lang_selected_count(@form) >= @count and not on %>
          <button type="button"
                  class={"spell-chip #{if on, do: "sel", else: ""} #{if locked, do: "locked", else: ""}"}
                  disabled={locked}
                  phx-click={if not locked, do: "lang_toggle"}
                  phx-value-lang={key}>
            {Dragones.Heroes.Translations.language(key, @locale)}
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp equipment_step(assigns) do
    ~H"""
    <div>
      <div :if={is_nil(@form.class)}>
        <div class="od" style="text-align:center;color:#555;font-size:.85rem;">
          Elige una clase en el paso de Identidad para configurar su equipo.
        </div>
      </div>

      <div :if={@form.class}>
        <div class="step-label">Equipo inicial de {Dragones.Heroes.Translations.class(@form.class, @locale)}</div>
        <div class="od" style="color:#555;font-size:.78rem;margin-bottom:.6rem;">
          Elige una opción en cada grupo. Es el equipo inicial según D&D 5e.
        </div>

        <%= for group <- Catalog.equipment_for_class(@form.class, @locale) do %>
          <% selected = Map.get(@form.equipment, group.id, 0) %>
          <div class="equip-group">
            <div class="equip-group-label">
              <%= case group.id do %>
                <% :weapon -> %> Arma
                <% :side -> %> Secundaria
                <% :defense -> %> Defensa
                <% :armor -> %> Armadura
                <% :shield -> %> Escudo
                <% :ranged -> %> A distancia
                <% :thrown -> %> Arrojadiza
                <% :bow -> %> Arco
                <% :focus -> %> Foco
                <% :pack -> %> Mochila
                <% :ammo -> %> Munición
                <% :darts -> %> Dardos
                <% :daggers -> %> Dagas
                <% :tools -> %> Herramientas
                <% :dagger -> %> Daga
                <% :simple -> %> Arma simple
                <% :spellbook -> %> Grimorio
                <% _ -> %> Otro
              <% end %>
            </div>
            <div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(160px,1fr));">
              <%= for opt <- group.options do %>
                <div class={"opt #{if selected == opt.index, do: "sel", else: ""}"}
                     phx-click="equip" phx-value-group={group.id} phx-value-index={opt.index}>
                  <div class="on">{opt.label}</div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <div class="od" style="color:#555;font-size:.72rem;margin-top:.6rem;">
          El equipo del trasfondo se añade automáticamente más adelante.
        </div>
      </div>
    </div>
    """
  end

  defp details_step(assigns) do
    ~H"""
    <div>
      <.spell_picker :if={Classes.caster?(@form.class)} form={@form} locale={@locale} custom={@custom} />
      <.custom_picker :if={has_custom?(@custom)} form={@form} custom={@custom} locale={@locale} />

      <div class="step-label">Historia (opcional)</div>
      <textarea name="backstory" phx-change="change" placeholder="Un ex-soldado que empuñó la espada de nuevo cuando su aldea ardió…">{@form.backstory}</textarea>
      <div class="od" style="color:#555;font-size:.78rem;margin-top:.3rem;">Vacío = se genera una por defecto.</div>
    </div>
    """
  end

  defp has_custom?(custom) do
    (custom[:weapons] || []) != [] or (custom[:items] || []) != []
  end

  attr(:form, :map, required: true)
  attr(:custom, :map, required: true)
  attr(:locale, :atom, default: :es)

  defp custom_picker(assigns) do
    ~H"""
    <div>
      <div class="step-label">Mi contenido (custom)</div>
      <div class="od" style="color:#555;font-size:.78rem;margin-bottom:.4rem;">
        Equipo que has creado en tu biblioteca. Toca para equipárselo (se añade al inicial).
      </div>

      <div :if={@custom.weapons != []} class="spell-group">
        <strong style="color:#7ab;font-size:.75rem;">ARMAS</strong>
        <div class="spell-chips">
          <%= for w <- Enum.filter(Catalog.weapons(@locale, custom: @custom), &(&1.source == :custom)) do %>
            <% selected = w.key in extra_weapons(@form) %>
            <button type="button" class={"spell-chip #{if selected, do: "sel", else: ""}"}
                    title={w.dice}
                    phx-click="extra_weapon_toggle" phx-value-key={w.key}>
              {w.label}
            </button>
          <% end %>
        </div>
      </div>

      <div :if={@custom.items != []} class="spell-group" style="margin-top:.6rem;">
        <strong style="color:#7ab;font-size:.75rem;">OBJETOS</strong>
        <div class="spell-chips">
          <%= for it <- Catalog.items(@locale, custom: @custom) do %>
            <% selected = it.key in extra_item_keys(@form) %>
            <button type="button" class={"spell-chip #{if selected, do: "sel", else: ""}"}
                    phx-click="extra_item_toggle" phx-value-key={it.key}>
              {it.label}
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp extra_weapons(form), do: form[:extra_equipment][:weapons] || []

  defp extra_item_keys(form) do
    Enum.map(form[:extra_equipment][:items] || [], fn
      %{key: k} -> k
      %{"key" => k} -> k
      _ -> nil
    end)
  end

  defp spell_picker(assigns) do
    ~H"""
    <div>
      <div class="step-label">Hechizos</div>
      <div class="od" style="color:#555;font-size:.78rem;margin-bottom:.4rem;">
        Toca para seleccionar/deseleccionar. No puedes pasar del cupo de tu clase.
      </div>
      <%= with {:ok, class} <- Classes.get(@form.class),
                sc <- class.spellcasting,
                picks <- Catalog.spells_for_class(@form.class, @locale, custom: @custom),
                custom <- @custom do %>
        <% cantrips_full = count_selected(@form, 0, custom) >= sc.cantrips
           level1_full = count_selected(@form, 1, custom) >= sc.spells_level1 %>
        <div class="spell-group">
          <strong style="color:#7ab;font-size:.75rem;">TRUCOS ({count_selected(@form, 0, custom)}/{sc.cantrips})</strong>
          <div class="spell-chips">
            <%= for entry <- picks.cantrips do %>
              <% selected = spell_selected?(@form, entry.key)
                 locked = cantrips_full and not selected %>
              <button type="button"
                      class={"spell-chip #{if selected, do: "sel", else: ""} #{if locked, do: "locked", else: ""}"}
                      disabled={locked}
                      title={entry.effect}
                      phx-click={if not locked, do: "spell_toggle"}
                      phx-value-spell={entry.key}>
                {entry.label}
              </button>
            <% end %>
          </div>
        </div>
        <div class="spell-group" style="margin-top:.6rem;">
          <strong style="color:#7ab;font-size:.75rem;">NIVEL 1 ({count_selected(@form, 1, custom)}/{sc.spells_level1})</strong>
          <div class="spell-chips">
            <%= for entry <- picks.level1 do %>
              <% selected = spell_selected?(@form, entry.key)
                 locked = level1_full and not selected %>
              <button type="button"
                      class={"spell-chip #{if selected, do: "sel", else: ""} #{if locked, do: "locked", else: ""}"}
                      disabled={locked}
                      title={entry.effect}
                      phx-click={if not locked, do: "spell_toggle"}
                      phx-value-spell={entry.key}>
                {entry.label}
              </button>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp review_step(assigns) do
    ~H"""
    <div>
      <%= if @preview do %>
        <.preview_card preview={@preview} locale={@locale} />
        <div style="text-align:center;color:#889;font-size:.85rem;margin-top:1rem;">
          Si todo está bien, ¡guarda tu héroe!
        </div>
      <% else %>
        <div class="error">Revisa los pasos anteriores.</div>
      <% end %>
    </div>
    """
  end

  # --- preview component ---

  attr(:preview, Character, required: true)
  attr(:locale, :atom, default: :es)

  defp preview_card(assigns) do
    ~H"""
    <div class="pv">
      <h3>{@preview.name}</h3>
      <div style="color:#fc8;font-size:.85rem;">
        {Catalog.race_label(@preview.race)} · {Catalog.class_label(@preview.class)} · Nivel {@preview.level}
        <span :if={@preview.sex}>· {String.capitalize(@preview.sex)}</span>
      </div>
      <div class="stats">
        <%= for ab <- [:str, :dex, :con, :int, :wis, :cha] do %>
          <% m = Character.modifier(@preview, ab)
             sign = if m >= 0, do: "+", else: "" %>
          <div>
            <strong>{Map.get(@preview, ab)}</strong>
            {Dragones.Heroes.Translations.ability_short(ab)} {sign}{m}
          </div>
        <% end %>
      </div>
      <div class="derived">
        <span>❤ {@preview.hp}/{@preview.max_hp}</span>
        <span>🛡 AC {@preview.ac}</span>
        <span>👁 {@preview.speed} ft</span>
        <span>Salvar: {Catalog.saving_throws(@preview.saving_proficiencies)}</span>
      </div>
      <div :if={@preview.weapons != []} class="spells">
        <strong>Armas:</strong> <%= Enum.map_join(@preview.weapons, ", ", fn w ->
          "#{Catalog.weapon_label(w)} (#{w.dice})"
        end) %>
      </div>
      <div :if={@preview.spells != []} class="spells">
        <strong>Hechizos:</strong>
        <%= Enum.map_join(@preview.spells, ", ", fn s ->
          label = Catalog.spell_label(s)
          if s.level == 0, do: "#{label} (truco)", else: "#{label} (N#{s.level})"
        end) %>
      </div>
      <div :if={@preview.skill_proficiencies != []} class="spells">
        <strong>Habilidades:</strong> {Catalog.skills(@preview.skill_proficiencies)}
      </div>
      <div :if={@preview.languages != []} class="spells">
        <strong>Idiomas:</strong> {Catalog.languages(@preview.languages)}
      </div>
      <div :if={@preview.racial_traits != []} class="spells">
        <strong>Rasgos raciales:</strong> {Enum.join(Catalog.racial_traits(@preview.racial_traits), ", ")}
      </div>
      <div :if={@preview.class_features != []} class="spells">
        <strong>Características de clase:</strong> {Enum.join(Catalog.class_features(@preview.class_features), ", ")}
      </div>
      <div :if={@preview.background_feature} class="spells">
        <strong>Trasfondo:</strong> {Dragones.Heroes.Translations.background_feature(@preview.background_feature)}
      </div>
    </div>
    """
  end

  defp subraces_for(race_key, locale), do: Catalog.subraces(race_key, locale)

  defp subrace_hint(%{subraces: []}), do: ""
  defp subrace_hint(%{subraces: subs}), do: "#{length(subs)} subrazas"

  defp class_hint(%{caster: true, hit_die: d}), do: "conjurador · d#{d}"
  defp class_hint(%{caster: false, hit_die: d}), do: "d#{d}"

  # nº de idiomas extra que tocan según raza+subraza+trasfondo actuales
  defp extra_langs(form) do
    Heroes.extra_language_slots(form.race, form.subrace, form.background)
  end

  # opciones de skills de la clase, localizadas (o nil si no hay clase)
  defp skill_opts(nil), do: nil

  defp skill_opts(class_key) do
    Catalog.class_skill_options(class_key, I18n.locale())
  end

  defp skill_selected_count(form), do: length(form.skills_choice || [])

  defp lang_selected_count(form), do: length(form.extra_langs || [])

  # idiomas extra que se pueden elegir: todos los del SRD salvo los que la raza
  # (con subraza) ya concede gratis — evita marcar "Común" como extra.
  defp extra_language_choices(form, _locale) do
    known =
      case Dragones.Heroes.Races.get(form.race || "", form.subrace) do
        {:ok, race} -> MapSet.new(race.languages)
        _ -> MapSet.new()
      end

    Enum.reject(Dragones.Heroes.Translations.languages(), &MapSet.member?(known, &1))
  end

  defp spell_selected?(%{spells: nil, class: class}, name) do
    name in Classes.default_spell_names(class)
  end

  defp spell_selected?(%{spells: spells}, name), do: name in spells

  # Nivel de un hechizo por su key: si es `custom_*` mira el bundle inyectado,
  # si no cae al catálogo builtin/SRD. Así los hechizos custom también cuentan
  # hacia el cupo de trucos/nivel-1 de la clase.
  defp spell_level(name, custom) do
    name = to_string(name)

    if String.starts_with?(name, "custom_") do
      case Enum.find(custom[:spells] || [], &(&1.key == name)) do
        nil -> nil
        %{definition: d} -> Dragones.MapUtil.get(d, "level")
      end
    else
      case Spells.get(name) do
        %{level: l} -> l
        _ -> nil
      end
    end
  end

  defp count_selected(%{spells: nil, class: class}, level, custom) do
    Enum.count(Classes.default_spell_names(class), fn name ->
      spell_level(name, custom) == level
    end)
  end

  defp count_selected(%{spells: spells}, level, custom) do
    Enum.count(spells, fn name -> spell_level(name, custom) == level end)
  end

  # ¿añadir `name` superaría el cupo de su nivel?
  defp cap_reached?(class_key, current, name, custom) do
    with lvl when lvl != nil <- spell_level(name, custom),
         {:ok, %{spellcasting: sc}} when not is_nil(sc) <- Classes.get(class_key) do
      cap = if lvl == 0, do: sc.cantrips, else: sc.spells_level1
      count = Enum.count(current, fn n -> spell_level(n, custom) == lvl end)
      cap != nil and count >= cap
    else
      _ -> false
    end
  end

  defp spell_cap_error(class_key, name, custom) do
    case spell_level(name, custom) do
      0 ->
        {:ok, %{spellcasting: sc}} = Classes.get(class_key)

        "Límite alcanzado: #{sc.cantrips} trucos para #{Dragones.Heroes.Translations.class(class_key)}."

      lvl when lvl != nil ->
        {:ok, %{spellcasting: sc}} = Classes.get(class_key)

        "Límite alcanzado: #{sc.spells_level1} hechizos de nivel 1 para #{Dragones.Heroes.Translations.class(class_key)}."

      nil ->
        "Hechizo desconocido."
    end
  end
end
