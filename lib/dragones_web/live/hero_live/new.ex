defmodule DragonesWeb.HeroLive.New do
  @moduledoc """
  The character creator — a multi-step LiveView wizard that builds a level-1
  D&D 5e character through `Dragones.Heroes.build/1` and saves it to the user's
  account.

  Steps: Identidad → Linaje → Detalles → Revisión.
  All stats (HP, AC, speed, spells, weapons) are auto-derived from 5e rules.
  """

  use Phoenix.LiveView, layout: {DragonesWeb.Layouts, :app}

  alias Dragones.{Character, Heroes}
  alias Dragones.Heroes.{Classes, Scoring, Spells}

  @order [:identity, :heritage, :details, :review]

  @impl true
  def mount(_params, session, socket) do
    case Dragones.Accounts.get_user(session["user_id"]) do
      nil ->
        {:ok, Phoenix.LiveView.redirect(socket, to: "/login")}

      user ->
        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:step, :identity)
         |> assign(:error, nil)
         |> assign(:preview, nil)
         |> assign(:form, %{
           name: "",
           race: nil,
           subrace: nil,
           class: nil,
           sex: nil,
           background: nil,
           backstory: nil,
           score_method: "auto",
           pb: %{str: 8, dex: 8, con: 8, int: 8, wis: 8, cha: 8},
           spells: nil
         })}
    end
  end

  # --- random hero ---

  def handle_event("random", _params, socket) do
    draft = Heroes.random_draft()

    form = %{
      name: draft.name,
      race: draft.race,
      subrace: draft.subrace,
      class: draft.class,
      sex: draft.sex,
      background: draft.background,
      score_method: "auto",
      pb: %{str: 8, dex: 8, con: 8, int: 8, wis: 8, cha: 8},
      backstory: nil,
      spells: nil
    }

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
    # Clear subrace when race changes; reset spells when class changes
    form =
      socket.assigns.form
      |> Map.put(key, if(value == "", do: nil, else: value))
      |> then(fn f -> if key == :race, do: Map.put(f, :subrace, nil), else: f end)
      |> then(fn f -> if key == :class, do: Map.put(f, :spells, nil), else: f end)

    {:noreply, socket |> assign(:form, form) |> refresh_preview()}
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

  # --- spell toggle ---

  def handle_event("spell_toggle", %{"spell" => name}, socket) do
    current = socket.assigns.form.spells || Classes.default_spell_names(socket.assigns.form.class)

    new_spells =
      if name in current do
        Enum.reject(current, &(&1 == name))
      else
        current ++ [name]
      end

    form = %{socket.assigns.form | spells: new_spells}
    {:noreply, socket |> assign(:form, form) |> refresh_preview()}
  end

  # --- text input change (form phx-change) ---

  def handle_event("change", params, socket) do
    field = List.first(params["_target"] || [])
    value = if field, do: Map.get(params, field, ""), else: ""

    form =
      if field do
        Map.put(socket.assigns.form, String.to_atom(field), value)
      else
        socket.assigns.form
      end

    {:noreply, socket |> assign(:form, form) |> refresh_preview()}
  end

  # --- save ---

  def handle_event("save", _params, %{assigns: %{preview: %Character{} = char}} = socket) do
    case Dragones.Accounts.save_hero(socket.assigns.current_user, char) do
      {:ok, _hero} ->
        {:noreply, Phoenix.LiveView.push_navigate(socket, to: "/heroes")}

      {:error, _} ->
        {:noreply, assign(socket, :error, "No se pudo guardar.")}
    end
  end

  def handle_event("save", _, socket), do: {:noreply, assign(socket, :error, "Faltan datos.")}

  # --- helpers ---

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
             backstory: form.backstory
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
  defp next_step(:heritage), do: :details
  defp next_step(:details), do: :review
  defp next_step(:review), do: :review

  defp prev(:heritage), do: :identity
  defp prev(:details), do: :heritage
  defp prev(:review), do: :details
  defp prev(_), do: :identity

  # A step is "complete" when its required choices are filled — used both to
  # gate the "Siguiente" button and to decide whether a tab is reachable.
  defp step_complete?(f, :identity) do
    f.name != "" and f.race != nil and f.class != nil and
      (Heroes.subraces(f.race) == [] or f.subrace != nil)
  end

  defp step_complete?(f, :heritage), do: f.background != nil
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
        <h1>⚔ Forjar un héroe</h1>
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
          <% reachable_d = step_reachable?(@form, :details) %>
          <button type="button"
                  class={"s #{step_status(@step, :details)} #{if reachable_d, do: "clickable", else: "locked"}"}
                  disabled={not reachable_d}
                  title={if not reachable_d, do: "Completa Identidad y Linaje primero", else: nil}
                  phx-click={if reachable_d, do: "goto", else: nil} phx-value-step="details">
            3 · Detalles
          </button>
          <% reachable_r = step_reachable?(@form, :review) %>
          <button type="button"
                  class={"s #{step_status(@step, :review)} #{if reachable_r, do: "clickable", else: "locked"}"}
                  disabled={not reachable_r}
                  title={if not reachable_r, do: "Completa los pasos anteriores primero", else: nil}
                  phx-click={if reachable_r, do: "goto", else: nil} phx-value-step="review">
            4 · Revisión
          </button>
        </div>

        <form phx-submit="next">
          <%= case @step do %>
            <% :identity -> %>
              <.identity_step form={@form} />
            <% :heritage -> %>
              <.heritage_step form={@form} />
            <% :details -> %>
              <.details_step form={@form} />
            <% :review -> %>
              <.review_step preview={@preview} />
          <% end %>
        </form>

        <div :if={@error} class="error">{@error}</div>

        <div class="actions">
          <button :if={@step != :identity} type="button" class="btn btn-back" phx-click="back">← Atrás</button>
          <span :if={@step == :identity} />
          <button :if={@step != :review} type="button" class="btn btn-primary" phx-click="next">Siguiente →</button>
          <button :if={@step == :review && @preview} type="button" class="btn btn-primary" phx-click="save">⚔ Guardar héroe</button>
        </div>
      </section>

      <.preview_card :if={@preview && @step != :review} preview={@preview} />
    </div>
    """
  end

  # --- steps ---

  attr(:form, :map, required: true)

  defp identity_step(assigns) do
    ~H"""
    <div>
      <div class="step-label">Nombre</div>
      <input type="text" name="name" value={@form.name} phx-change="change" placeholder="Lyra, Thane, Vex…" />

      <div class="step-label">Sexo</div>
      <div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(120px,1fr));">
        <%= for sex <- ~w(hombre mujer no binario) do %>
          <div class={"opt #{if @form.sex == sex, do: "sel", else: ""}"}
               phx-click="select" phx-value-field="sex" phx-value-value={sex}>
            <div class="on">{String.capitalize(sex)}</div>
          </div>
        <% end %>
      </div>

      <div class="step-label">Raza</div>
      <div class="grid">
        <%= for race <- Heroes.list_races() do %>
          <div class={"opt #{if @form.race == race, do: "sel", else: ""}"}
               phx-click="select" phx-value-field="race" phx-value-value={race}>
            <div class="on">{String.capitalize(race)}</div>
            <div class="od">{subrace_count(race)}</div>
          </div>
        <% end %>
      </div>

      <div :if={@form.race && Heroes.subraces(@form.race) != []}>
        <div class="step-label">Subraza</div>
        <select class="select-row" name="subrace" phx-change="change">
          <option value="">(elige subraza)</option>
          <%= for sr <- Heroes.subraces(@form.race) do %>
            <option value={sr} selected={@form.subrace == sr}>{String.capitalize(sr)}</option>
          <% end %>
        </select>
      </div>

      <div class="step-label">Clase</div>
      <div class="grid">
        <%= for class <- Heroes.list_classes() do %>
          <div class={"opt #{if @form.class == class, do: "sel", else: ""}"}
               phx-click="select" phx-value-field="class" phx-value-value={class}>
            <div class="on">{String.capitalize(class)}</div>
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
        <%= for bg <- Heroes.list_backgrounds() do %>
          <div class={"opt #{if @form.background == bg, do: "sel", else: ""}"}
               phx-click="select" phx-value-field="background" phx-value-value={bg}>
            <div class="on">{String.capitalize(bg)}</div>
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
               cost = Scoring.cost_for(val) %>
            <div class="pb-row">
              <span class="pb-ab">{String.upcase(to_string(ab))}</span>
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

    </div>
    """
  end

  defp details_step(assigns) do
    ~H"""
    <div>
      <.spell_picker :if={Classes.caster?(@form.class)} form={@form} />

      <div class="step-label">Historia (opcional)</div>
      <textarea name="backstory" phx-change="change" placeholder="Un ex-soldado que empuñó la espada de nuevo cuando su aldea ardió…">{@form.backstory}</textarea>
      <div class="od" style="color:#555;font-size:.78rem;margin-top:.3rem;">Vacío = se genera una por defecto.</div>
    </div>
    """
  end

  defp spell_picker(assigns) do
    ~H"""
    <div>
      <div class="step-label">Hechizos</div>
      <div class="od" style="color:#555;font-size:.78rem;margin-bottom:.4rem;">
        Toca para seleccionar/deseleccionar. Los defaults ya están elegidos.
      </div>
      <%= with {:ok, class} <- Classes.get(@form.class),
                sc <- class.spellcasting do %>
        <div class="spell-group">
          <strong style="color:#7ab;font-size:.75rem;">TRUCOS ({count_selected(@form, 0)}/{sc.cantrips})</strong>
          <div class="spell-chips">
            <%= for name <- sc.defaults.cantrips do %>
              <button type="button"
                      class={"spell-chip #{if spell_selected?(@form, name), do: "sel", else: ""}"}
                      phx-click="spell_toggle" phx-value-spell={name}>
                {name}
              </button>
            <% end %>
          </div>
        </div>
        <div class="spell-group" style="margin-top:.6rem;">
          <strong style="color:#7ab;font-size:.75rem;">NIVEL 1 ({count_selected(@form, 1)}/{sc.spells_level1})</strong>
          <div class="spell-chips">
            <%= for name <- sc.defaults.spells do %>
              <button type="button"
                      class={"spell-chip #{if spell_selected?(@form, name), do: "sel", else: ""}"}
                      phx-click="spell_toggle" phx-value-spell={name}>
                {name}
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
        <.preview_card preview={@preview} />
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

  defp preview_card(assigns) do
    ~H"""
    <div class="pv">
      <h3>{@preview.name}</h3>
      <div style="color:#fc8;font-size:.85rem;">
        {String.capitalize(@preview.race)} · {String.capitalize(@preview.class)} · Nivel {@preview.level}
        <span :if={@preview.sex}>· {String.capitalize(@preview.sex)}</span>
      </div>
      <div class="stats">
        <%= for ab <- [:str, :dex, :con, :int, :wis, :cha] do %>
          <% m = Character.modifier(@preview, ab)
             sign = if m >= 0, do: "+", else: "" %>
          <div>
            <strong>{Map.get(@preview, ab)}</strong>
            {String.upcase(to_string(ab))} {sign}{m}
          </div>
        <% end %>
      </div>
      <div class="derived">
        <span>❤ {@preview.hp}/{@preview.max_hp}</span>
        <span>🛡 AC {@preview.ac}</span>
        <span>👁 {@preview.speed} ft</span>
        <span>Salvar: {Enum.join(@preview.saving_proficiencies, ", ")}</span>
      </div>
      <div :if={@preview.weapons != []} class="spells">
        <strong>Armas:</strong> <%= Enum.map_join(@preview.weapons, ", ", &"#{&1.name} (#{&1.dice})") %>
      </div>
      <div :if={@preview.spells != []} class="spells">
        <strong>Hechizos:</strong>
        <%= Enum.map_join(@preview.spells, ", ", fn s ->
          if s.level == 0, do: "#{s.name} (cantrip)", else: "#{s.name} (N#{s.level})"
        end) %>
      </div>
    </div>
    """
  end

  defp subrace_count(race) do
    case Heroes.subraces(race) do
      [] -> ""
      subs -> "#{length(subs)} subrazas"
    end
  end

  defp spell_selected?(%{spells: nil, class: class}, name) do
    name in Classes.default_spell_names(class)
  end

  defp spell_selected?(%{spells: spells}, name), do: name in spells

  defp count_selected(%{spells: nil, class: class}, level) do
    Classes.default_spell_names(class)
    |> Enum.count(fn name ->
      case Spells.get(name) do
        %{level: ^level} -> true
        _ -> false
      end
    end)
  end

  defp count_selected(%{spells: spells}, level) do
    Enum.count(spells, fn name ->
      case Spells.get(name) do
        %{level: ^level} -> true
        _ -> false
      end
    end)
  end
end
