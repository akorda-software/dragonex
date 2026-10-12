defmodule DragonexWeb.HeroLive.New do
  @moduledoc """
  The character creator — a multi-step LiveView wizard that builds a level-1
  D&D 5e character through `Dragonex.Heroes.build/1` and saves it to the user's
  account.

  Steps: Identidad → Linaje → Detalles → Revisión.
  All stats (HP, AC, speed, spells, weapons) are auto-derived from 5e rules.

  The step markup lives in `DragonexWeb.HeroLive.New.Components`; the form ↔
  draft mapping in `Dragonex.Heroes.Draft`.
  """

  use Phoenix.LiveView, layout: {DragonexWeb.Layouts, :app}
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{Character, Heroes, I18n}
  alias Dragonex.Heroes.{Classes, Draft, Scoring}

  import DragonexWeb.HeroLive.New.Components,
    only: [
      identity_step: 1,
      heritage_step: 1,
      equipment_step: 1,
      details_step: 1,
      review_step: 1,
      preview_card: 1
    ]

  @order [:identity, :heritage, :equipment, :details, :review]

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user

    socket =
      socket
      |> assign(:locale, I18n.locale())
      |> assign(:error, nil)
      |> assign(:custom, Dragonex.Accounts.custom_bundle(user))

    mount_mode(params, user, socket)
  end

  # --- random hero ---

  def handle_event("random", _params, socket) do
    draft = Heroes.random_draft()

    form =
      Draft.initial_form()
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
      {:noreply,
       assign(
         socket,
         :error,
         dgettext("ui", "Completa los pasos anteriores antes de saltar a este.")
       )}
    end
  end

  # --- selection (grid clicks) ---

  def handle_event("select", %{"field" => field, "value" => value}, socket) do
    key = Draft.to_existing_atom(field)
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
        {:noreply,
         assign(
           socket,
           :error,
           dgettext("ui", "Ya tienes tus %{count} habilidades de clase.", count: count)
         )}

      true ->
        form = %{socket.assigns.form | skills_choice: current ++ [key]}
        {:noreply, socket |> assign(:form, form) |> assign(:error, nil) |> refresh_preview()}
    end
  end

  # --- extra language toggle (respeta el nº de idiomas extra que tocan) ---

  def handle_event("lang_toggle", %{"lang" => key}, socket) do
    current = socket.assigns.form.extra_langs || []

    cap =
      Heroes.extra_language_slots(
        socket.assigns.form.race,
        socket.assigns.form.subrace,
        socket.assigns.form.background
      )

    cond do
      key in current ->
        form = %{socket.assigns.form | extra_langs: List.delete(current, key)}
        {:noreply, socket |> assign(:form, form) |> assign(:error, nil) |> refresh_preview()}

      length(current) >= cap ->
        {:noreply,
         assign(
           socket,
           :error,
           dgettext("ui", "Ya tienes tus %{count} idiomas extra.", count: cap)
         )}

      true ->
        form = %{socket.assigns.form | extra_langs: current ++ [key]}
        {:noreply, socket |> assign(:form, form) |> assign(:error, nil) |> refresh_preview()}
    end
  end

  # --- point-buy adjust (+/- on ability scores) ---

  def handle_event("pb_adjust", %{"ability" => ab, "delta" => delta}, socket) do
    ab_atom = Draft.to_existing_atom(ab)
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

      Draft.cap_reached?(class_key, current, name, socket.assigns[:custom] || %{}) ->
        # ya está al cupo de ese nivel: no añade más
        {:noreply,
         assign(
           socket,
           :error,
           Draft.spell_cap_error(class_key, name, socket.assigns[:custom] || %{})
         )}

      true ->
        form = %{socket.assigns.form | spells: current ++ [name]}
        {:noreply, socket |> assign(:form, form) |> assign(:error, nil) |> refresh_preview()}
    end
  end

  # --- text input change (form phx-change) ---

  def handle_event("extra_weapon_toggle", %{"key" => key}, socket) do
    form = socket.assigns.form
    ee = Map.get(form, :extra_equipment) || %{weapons: [], items: []}
    weapons = Draft.toggle_key(Map.get(ee, :weapons, []), key)
    form = %{form | extra_equipment: Map.put(ee, :weapons, weapons)}
    {:noreply, socket |> assign(:form, form) |> assign(:error, nil) |> refresh_preview()}
  end

  def handle_event("extra_item_toggle", %{"key" => key}, socket) do
    form = socket.assigns.form
    ee = Map.get(form, :extra_equipment) || %{weapons: [], items: []}
    items = Draft.toggle_item(Map.get(ee, :items, []), key)
    form = %{form | extra_equipment: Map.put(ee, :items, items)}
    {:noreply, socket |> assign(:form, form) |> assign(:error, nil) |> refresh_preview()}
  end

  def handle_event("change", params, socket) do
    field = List.first(params["_target"] || [])
    value = if field, do: Map.get(params, field, ""), else: ""

    form =
      if field do
        key = Draft.to_existing_atom(field)
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
          Dragonex.Accounts.update_hero(
            socket.assigns.current_user,
            socket.assigns.hero.id,
            char,
            Draft.draft_from_form(socket.assigns.form)
          )

        :new ->
          Dragonex.Accounts.save_hero(
            socket.assigns.current_user,
            char,
            Draft.draft_from_form(socket.assigns.form)
          )
      end

    case result do
      {:ok, _hero} ->
        {:noreply, Phoenix.LiveView.push_navigate(socket, to: "/heroes")}

      {:error, :in_game} ->
        {:noreply,
         assign(
           socket,
           :error,
           dgettext("ui", "Este héroe ya está en una partida y no se puede actualizar.")
         )}

      {:error, _} ->
        {:noreply, assign(socket, :error, dgettext("ui", "No se pudo guardar."))}
    end
  end

  def handle_event("save", _, socket),
    do: {:noreply, assign(socket, :error, dgettext("ui", "Faltan datos."))}

  # --- helpers ---

  defp mount_mode(%{"id" => id}, user, socket) do
    case Dragonex.Accounts.get_user_hero(user, id) do
      nil ->
        {:ok, Phoenix.LiveView.redirect(socket, to: "/heroes")}

      hero ->
        if Dragonex.Accounts.hero_used?(hero) do
          {:ok, Phoenix.LiveView.redirect(socket, to: "/heroes/#{hero.id}")}
        else
          sheet = Dragonex.Accounts.hero_sheet(hero)

          {:ok,
           socket
           |> assign(:mode, :edit)
           |> assign(:hero, hero)
           |> assign(:step, :review)
           |> assign(:preview, sheet)
           |> assign(:form, Draft.form_from_hero(hero, sheet))}
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
     |> assign(:form, Draft.initial_form())}
  end

  defp refresh_preview(socket) do
    form = socket.assigns.form

    if form.race && form.class && form.background do
      scores = if form.score_method == "pointbuy", do: form.pb, else: nil

      case Heroes.build(%{
             name: if(form.name == "", do: dgettext("ui", "Héroe"), else: form.name),
             race: form.race,
             subrace: form.subrace,
             class: form.class,
             sex: form.sex,
             background: form.background,
             scores: scores,
             spells: form.spells,
             equipment_picks: form.equipment,
             skills: if(form.skills_choice == [], do: nil, else: form.skills_choice),
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

  # --- wizard step machine ---

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
      f.name == "" ->
        dgettext("ui", "Ponle nombre a tu héroe.")

      f.race == nil ->
        dgettext("ui", "Elige una raza.")

      f.class == nil ->
        dgettext("ui", "Elige una clase.")

      f.race && Heroes.subraces(f.race) != [] && f.subrace == nil ->
        dgettext("ui", "Elige una subraza.")

      true ->
        dgettext("ui", "Completa la identidad.")
    end
  end

  defp step_error(:heritage, f) do
    if f.background == nil,
      do: dgettext("ui", "Elige un trasfondo."),
      else: dgettext("ui", "Completa el linaje.")
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

  # opciones de skills de la clase (o nil si no hay clase) — solo el cupo
  defp skill_opts(nil), do: nil

  defp skill_opts(class_key) do
    Dragonex.Heroes.Catalog.class_skill_options(class_key, I18n.locale())
  end

  # --- render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="creator">

      <.link navigate="/heroes" class="nav-back">{dgettext("ui", "← mis héroes")}</.link>

      <div class="creator-head">
        <h1>{if @mode == :edit, do: dgettext("ui", "Editar héroe"), else: dgettext("ui", "Forjar un héroe")}</h1>
        <p class="sub">{dgettext("ui", "D&D 5e · nivel 1 · reglas SRD")}</p>
        <button type="button" class="btn-random" phx-click="random"><i class="px px-d20" aria-hidden="true"></i>{dgettext("ui", "Héroe aleatorio")}</button>
      </div>

      <section class="creator-panel win-open">
        <div class="steps">
          <button type="button"
                  class={"s #{step_status(@step, :identity)} clickable"}
                  phx-click="goto" phx-value-step="identity">
            1 · {dgettext("ui", "Identidad")}
          </button>
          <% reachable_h = step_reachable?(@form, :heritage) %>
          <button type="button"
                  class={"s #{step_status(@step, :heritage)} #{if reachable_h, do: "clickable", else: "locked"}"}
                  disabled={not reachable_h}
                  title={if not reachable_h, do: dgettext("ui", "Completa Identidad primero"), else: nil}
                  phx-click={if reachable_h, do: "goto", else: nil} phx-value-step="heritage">
            2 · {dgettext("ui", "Linaje")}
          </button>
          <% reachable_e = step_reachable?(@form, :equipment) %>
          <button type="button"
                  class={"s #{step_status(@step, :equipment)} #{if reachable_e, do: "clickable", else: "locked"}"}
                  disabled={not reachable_e}
                  title={if not reachable_e, do: dgettext("ui", "Completa Identidad y Linaje primero"), else: nil}
                  phx-click={if reachable_e, do: "goto", else: nil} phx-value-step="equipment">
            3 · {dgettext("ui", "Equipo")}
          </button>
          <% reachable_d = step_reachable?(@form, :details) %>
          <button type="button"
                  class={"s #{step_status(@step, :details)} #{if reachable_d, do: "clickable", else: "locked"}"}
                  disabled={not reachable_d}
                  title={if not reachable_d, do: dgettext("ui", "Completa los pasos anteriores primero"), else: nil}
                  phx-click={if reachable_d, do: "goto", else: nil} phx-value-step="details">
            4 · {dgettext("ui", "Detalles")}
          </button>
          <% reachable_r = step_reachable?(@form, :review) %>
          <button type="button"
                  class={"s #{step_status(@step, :review)} #{if reachable_r, do: "clickable", else: "locked"}"}
                  disabled={not reachable_r}
                  title={if not reachable_r, do: dgettext("ui", "Completa los pasos anteriores primero"), else: nil}
                  phx-click={if reachable_r, do: "goto", else: nil} phx-value-step="review">
            5 · {dgettext("ui", "Revisión")}
          </button>
        </div>

        <form id="hero-creator-form" phx-change="change" phx-submit="next">
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
          <button :if={@step != :identity} type="button" class="btn btn-back" phx-click="back">{dgettext("ui", "← Atrás")}</button>
          <span :if={@step == :identity} />
          <button :if={@step != :review} type="button" class="btn btn-primary" phx-click="next">{dgettext("ui", "Siguiente →")}</button>
          <button :if={@step == :review && @preview} type="button" class="btn btn-primary" phx-click="save">{if @mode == :edit, do: dgettext("ui", "Actualizar héroe"), else: dgettext("ui", "Guardar héroe")}</button>
        </div>
      </section>

      <.preview_card :if={@preview && @step != :review} preview={@preview} locale={@locale} />
    </div>
    """
  end
end
