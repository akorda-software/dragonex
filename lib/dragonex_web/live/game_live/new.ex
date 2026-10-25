defmodule DragonexWeb.GameLive.New do
  @moduledoc """
  The creator wizard — a 2-step flow:

  1. **Detalles**: scenario selection + title/scene/dm_style.
  2. **Personajes**: pick your hero + up to 5 AI companion slots.

  The details step also picks the game's language (`games.locale`), defaulting
  to the current interface locale; the whole table then plays in it.

  Enemies are never picked by the player — the DM spawns them from the bestiary
  as the story unfolds.

  Open slots for other humans are claimed from the waiting room after create.
  """

  use Phoenix.LiveView, layout: {DragonexWeb.Layouts, :app}
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{Games, I18n, Roster, Scenarios}
  alias Dragonex.Heroes.Catalog
  alias DragonexWeb.GameLive.Dice

  @steps [:details, :characters]
  @max_companions 5

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    pcs = Enum.filter(Roster.catalog(), &(&1.side == "pc"))
    heroes = Roster.hero_catalog(user)

    {:ok,
     assign(socket,
       pcs: pcs,
       heroes: heroes,
       scenarios: Scenarios.all(),
       step: :details,
       selected_scenario: nil,
       my_hero: nil,
       companions: List.duplicate(nil, @max_companions),
       max_companions: @max_companions,
       picking_slot: nil,
       dice_engine: "2d",
       game_locale: Atom.to_string(I18n.locale()),
       custom_title: nil,
       custom_scene: nil,
       custom_dm_style: nil,
       title_error: nil,
       error: nil
     )}
  end

  # --- navigation ---

  @impl true
  def handle_event("next", _params, %{assigns: %{step: :details}} = socket) do
    changeset = Games.wizard_details_changeset(choices(socket.assigns))

    if changeset.valid?,
      do: {:noreply, assign(socket, step: :characters, error: nil, title_error: nil)},
      else: {:noreply, creation_error(socket, changeset)}
  end

  def handle_event("next", _params, %{assigns: %{step: :characters}} = socket) do
    if socket.assigns.my_hero == nil do
      {:noreply, assign(socket, error: dgettext("ui", "Elige tu personaje."))}
    else
      # Build roster and create the game
      create_game(socket)
    end
  end

  def handle_event("back", _params, socket) do
    {:noreply, assign(socket, step: :details, error: socket.assigns.title_error)}
  end

  # --- text field changes (custom scenario fields) ---

  # Custom-scenario text fields the wizard binds. Kept as an allowlist so a
  # forged phx-change "_target" can't drive String.to_atom (atom-table DoS, D8).
  # NOTE: strings, not atoms — `_target` carries the literal input name.
  @custom_fields ~w(custom_title custom_scene custom_dm_style)

  def handle_event("change", params, socket) do
    field = List.first(params["_target"] || [])
    value = if field, do: Map.get(params, field, ""), else: ""

    if field in @custom_fields do
      socket = assign(socket, String.to_existing_atom(field), value)

      socket =
        if field == "custom_title", do: assign(socket, title_error: nil, error: nil), else: socket

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # --- scenario selection ---

  def handle_event("pick_scenario", %{"key" => key}, socket) do
    cond do
      key == "custom" ->
        {:noreply,
         assign(socket, selected_scenario: %{key: "custom"}, error: nil, title_error: nil)}

      key == "arena" ->
        # Auto-select all 3 archetypes so the player can test every mechanic
        # without manual setup: fighter (STR melee + ranged), wizard (spellcasting),
        # rogue (DEX, finesse, ranged).
        {:noreply,
         assign(socket,
           selected_scenario: Scenarios.get(key),
           my_hero: "fighter",
           companions: ["wizard", "rogue", nil, nil, nil],
           title_error: nil,
           error: nil
         )}

      true ->
        {:noreply,
         assign(socket, selected_scenario: Scenarios.get(key), error: nil, title_error: nil)}
    end
  end

  # Both supported modes reveal the committed roll. The stored preference is
  # presentation only; availability comes from the installed package.
  def handle_event("pick_engine", %{"engine" => engine}, socket),
    do: {:noreply, assign(socket, dice_engine: Dice.effective_engine(engine))}

  # Language the game will be played in (narration, rules feedback, table UI).
  def handle_event("pick_locale", %{"locale" => locale}, socket),
    do: {:noreply, assign(socket, game_locale: locale |> I18n.normalize() |> Atom.to_string())}

  # --- companion slots ---

  def handle_event("open_picker", %{"slot" => idx}, socket) do
    {:noreply, assign(socket, picking_slot: String.to_integer(idx))}
  end

  def handle_event("close_picker", _params, socket) do
    {:noreply, assign(socket, picking_slot: nil)}
  end

  def handle_event("pick_companion", %{"slot" => slot_idx, "key" => key}, socket) do
    idx = String.to_integer(slot_idx)

    cond do
      key == "open" ->
        companions = List.replace_at(socket.assigns.companions, idx, "open")
        {:noreply, assign(socket, companions: companions, picking_slot: nil, error: nil)}

      key == "" ->
        {:noreply, assign(socket, picking_slot: nil)}

      true ->
        used = used_keys(socket.assigns)

        cond do
          key == socket.assigns.my_hero ->
            {:noreply,
             assign(socket, error: dgettext("ui", "Ya elegiste ese héroe como tu personaje."))}

          key in used ->
            {:noreply, assign(socket, error: dgettext("ui", "Ese héroe ya está en otro slot."))}

          true ->
            companions = List.replace_at(socket.assigns.companions, idx, key)
            {:noreply, assign(socket, companions: companions, picking_slot: nil, error: nil)}
        end
    end
  end

  def handle_event("clear_companion", %{"slot" => slot_idx}, socket) do
    idx = String.to_integer(slot_idx)
    companions = List.replace_at(socket.assigns.companions, idx, nil)
    {:noreply, assign(socket, companions: companions)}
  end

  # --- duplicate prevention for hero pick ---

  def handle_event("pick_hero", %{"key" => key}, socket) do
    used = used_keys(socket.assigns)

    cond do
      key in used ->
        {:noreply, assign(socket, error: dgettext("ui", "Ese héroe ya está como compañero IA."))}

      true ->
        {:noreply, assign(socket, my_hero: key, error: nil)}
    end
  end

  # --- random ---

  def handle_event("random", _params, socket) do
    scenario = Enum.random(Scenarios.all())
    keys = Enum.map(socket.assigns.pcs ++ socket.assigns.heroes, & &1.key)

    case Enum.shuffle(keys) do
      [] ->
        {:noreply, assign(socket, error: dgettext("ui", "No hay personajes disponibles."))}

      [my_hero | rest] ->
        n = rem(:rand.uniform(1000), @max_companions + 1)
        picked = Enum.take(rest, n)
        companions = picked ++ List.duplicate(nil, @max_companions - length(picked))

        {:noreply,
         assign(socket,
           selected_scenario: scenario,
           my_hero: my_hero,
           companions: companions,
           error: nil
         )}
    end
  end

  # --- create ---

  defp create_game(socket) do
    locale = I18n.normalize(socket.assigns.game_locale)

    # `Games.create_game/1` defaults `locale:` to the process locale, so the
    # game is created (and bootstrapped) in the chosen language.
    case I18n.with_locale(locale, fn ->
           Games.create_from_wizard_choices(choices(socket.assigns))
         end) do
      {:ok, game} ->
        {:noreply, Phoenix.LiveView.push_navigate(socket, to: "/games/#{game.id}")}

      {:error, :no_characters} ->
        {:noreply, assign(socket, error: dgettext("ui", "Selecciona al menos un personaje."))}

      {:error, {:name_taken, name}} ->
        {:noreply,
         assign(socket,
           error:
             dgettext(
               "ui",
               "Ya hay un personaje llamado %{name}. Elige otro héroe o cambia su nombre.",
               name: name
             )
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, creation_error(socket, changeset)}

      {:error, _} ->
        {:noreply, assign(socket, error: dgettext("ui", "No se pudo crear la partida."))}
    end
  end

  defp choices(s) do
    %{
      user_id: s.current_user.id,
      scenario: s.selected_scenario,
      my_hero: s.my_hero,
      companions: s.companions,
      dice_engine: s.dice_engine,
      locale: s.game_locale,
      custom_title: s[:custom_title],
      custom_scene: s[:custom_scene],
      custom_dm_style: s[:custom_dm_style]
    }
  end

  defp creation_error(socket, changeset) do
    title_error =
      if changeset.errors[:title],
        do:
          dgettext(
            "ui",
            "El título admite hasta %{limit} caracteres. Acórtalo para continuar.",
            limit: Games.creation_title_limit()
          )

    assign(socket,
      title_error: title_error,
      error:
        title_error || dgettext("ui", "Revisa los detalles de la partida antes de continuar.")
    )
  end

  # --- render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="wizard">

      <.link navigate="/" class="back">{dgettext("ui", "← volver")}</.link>
      <div class="wizard-head">
        <h1>{dgettext("ui", "Nueva partida")}</h1>
        <p class="sub">{dgettext("ui", "Elige la aventura, tu héroe y quién te acompaña.")}</p>
        <button type="button" class="btn-random" phx-click="random"><i class="px px-d20" aria-hidden="true"></i>{dgettext("ui", "Partida aleatoria")}</button>
      </div>

      <section class="creator-panel win-open">
      <div class="steps">
        <span class={"s #{step_class(@step, :details)}"}>{dgettext("ui", "1 · Detalles")}</span>
        <span class={"s #{step_class(@step, :characters)}"}>{dgettext("ui", "2 · Personajes")}</span>
      </div>

      <%= if @step == :details do %>
        <div class="step-label">{dgettext("ui", "Escenario")}</div>
        <div class="scenario-grid">
          <button :for={s <- @scenarios} :key={s.key} type="button" id={"scenario-#{s.key}"}
               class={"scenario-card #{if @selected_scenario && @selected_scenario.key == s.key, do: "sel", else: ""}"}
               aria-pressed={to_string(@selected_scenario != nil && @selected_scenario.key == s.key)}
               phx-click="pick_scenario" phx-value-key={s.key}>
            <span class="st">{s.title}</span>
            <span class="ss">{s.summary}</span>
          </button>
          <button type="button" id="scenario-custom" class={"scenario-card #{if @selected_scenario && @selected_scenario.key == "custom", do: "sel", else: ""}"}
               aria-pressed={to_string(@selected_scenario != nil && @selected_scenario.key == "custom")}
               phx-click="pick_scenario" phx-value-key="custom">
            <span class="st">{dgettext("ui", "Personalizada")}</span>
            <span class="ss">{dgettext("ui", "Crea tu propia aventura desde cero.")}</span>
          </button>
        </div>

        <div :if={@selected_scenario && @selected_scenario.key == "custom"} class="scenario-detail">
          <form id="custom-scenario-form" phx-change="change">
            <label class="step-label" for="custom_title">{dgettext("ui", "Título")}</label>
            <input id="custom_title" type="text" name="custom_title" value={@custom_title} placeholder={dgettext("ui", "Mi aventura…")}
              aria-invalid={to_string(@title_error != nil)} aria-describedby={if @title_error, do: "creation-error"} />

            <label class="step-label" for="custom_scene">{dgettext("ui", "Escena inicial")}</label>
            <input id="custom_scene" type="text" name="custom_scene" value={@custom_scene} placeholder={dgettext("ui", "una taberna, un calabozo, un bosque…")} />

            <label class="step-label" for="custom_dm_style">{dgettext("ui", "Estilo del DM")}</label>
            <input id="custom_dm_style" type="text" name="custom_dm_style" value={@custom_dm_style || "vivid but brief"} />
          </form>
        </div>

        <div :if={@selected_scenario && @selected_scenario.key != "custom"} class="scenario-detail">
          <div class="step-label">{dgettext("ui", "Título")}</div>
          <div class="scenario-title">{@selected_scenario.title}</div>
          <div class="step-label">{dgettext("ui", "Escena")}</div>
          <div class="scenario-scene">{@selected_scenario.scene}</div>
          <div class="step-label">{dgettext("ui", "Tono")}</div>
          <div class="scenario-tone">{@selected_scenario.tone}</div>
        </div>

        <div>
          <div class="step-label">{dgettext("ui", "Dados")}</div>
          <Dice.engine_picker engine={@dice_engine} />
        </div>

        <div>
          <div class="step-label" id="game-locale-label">{dgettext("ui", "Idioma de la partida")}</div>
          <div class="engine-toggle locale-toggle" role="group" aria-labelledby="game-locale-label">
            <button :for={{code, name, icon} <- [{"es", "Español", "px-scroll"}, {"en", "English", "px-quill"}]}
              type="button" id={"game-locale-#{code}"} lang={code}
              class={"engine-opt #{if @game_locale == code, do: "sel", else: ""}"}
              aria-pressed={to_string(@game_locale == code)} phx-click="pick_locale" phx-value-locale={code}>
              <span class="eo-tk"><i class={"px #{icon}"} aria-hidden="true"></i></span>
              <span class="eo-n">{String.upcase(code)}</span><span class="eo-d">{name}</span>
            </button>
          </div>
        </div>

        <div id="creation-error" class="error" role="alert" :if={@error}>{@error}</div>

        <div class="actions">
          <span></span>
          <button type="button" class="btn btn-primary" phx-click="next">{dgettext("ui", "Personajes →")}</button>
        </div>
      <% else %>
        <div class="step-label">{dgettext("ui", "Tu personaje")}</div>
        <div class="hero-grid">
          <button :for={h <- @heroes} :key={h.key} type="button" id={"game-hero-#{h.key}"}
               class={"hero-opt #{if @my_hero == h.key, do: "sel", else: ""} #{if h.key in @companions, do: "taken", else: ""}"}
               aria-pressed={to_string(@my_hero == h.key)} disabled={h.key in @companions}
               phx-click="pick_hero" phx-value-key={h.key}>
            <span class="hn">{h.name}</span>
            <span class="hr">{role_label(h.role)}</span>
          </button>
          <button :for={c <- @pcs} :key={c.key} type="button" id={"game-hero-#{c.key}"}
               class={"hero-opt #{if @my_hero == c.key, do: "sel", else: ""} #{if c.key in @companions, do: "taken", else: ""}"}
               aria-pressed={to_string(@my_hero == c.key)} disabled={c.key in @companions}
               phx-click="pick_hero" phx-value-key={c.key}>
            <span class="hn">{c.name}</span>
            <span class="hr">{role_label(c.role)}</span>
          </button>
        </div>

        <div class="step-label">{dgettext("ui", "Compañeros (hasta %{max})", max: @max_companions)}</div>
        <div class="slots">
          <%= for {companion, idx} <- Enum.with_index(@companions) do %>
            <div class="slot">
              <span class="slabel">{dgettext("ui", "Slot %{number}", number: idx + 1)}</span>
              <%= cond do %>
                <% companion == "open" -> %>
                  <span class="sval is-open"><i class="px px-key" aria-hidden="true"></i>{dgettext("ui", "Hueco para otro jugador")}</span>
                  <button type="button" class="btn btn-ghost btn-sm slot-clear" phx-click="clear_companion" phx-value-slot={idx} aria-label={dgettext("ui", "Quitar hueco para otro jugador %{number}", number: idx + 1)}>✕</button>
                <% companion -> %>
                  <span class="sval"><i class="px px-orb" aria-hidden="true"></i>{companion_label(@heroes ++ @pcs, companion)}</span>
                  <button type="button" class="btn btn-ghost btn-sm slot-clear" phx-click="clear_companion" phx-value-slot={idx} aria-label={dgettext("ui", "Quitar a %{name}", name: companion_label(@heroes ++ @pcs, companion))}>✕</button>
                <% @picking_slot == idx -> %>
                  <div class="slot-pick">
                    <button type="button" class="btn btn-sm pick-opt" phx-click="pick_companion" phx-value-slot={idx} phx-value-key="open"><i class="px px-key" aria-hidden="true"></i>{dgettext("ui", "Dejar hueco a un jugador")}</button>
                    <% avail = available_for_slot(@heroes ++ @pcs, @companions, @my_hero, idx) %>
                    <%= for h <- avail do %>
                      <button type="button" class="btn btn-sm pick-opt" phx-click="pick_companion" phx-value-slot={idx} phx-value-key={h.key}>
                        <i class="px px-orb" aria-hidden="true"></i>{h.name} ({role_label(h.role)})
                      </button>
                    <% end %>
                    <button type="button" class="btn btn-ghost btn-sm pick-cancel" phx-click="close_picker">{dgettext("ui", "Cancelar")}</button>
                  </div>
                <% true -> %>
                  <button type="button" class="btn btn-ghost btn-sm slot-add" phx-click="open_picker" phx-value-slot={idx}>{dgettext("ui", "+ Añadir compañero")}</button>
              <% end %>
            </div>
          <% end %>
        </div>

        <p class="wizard-note"><i class="px px-orb" aria-hidden="true"></i>{dgettext("ui", "Los compañeros con orbe los lleva la IA. Los enemigos los invoca el DM según la historia.")}</p>

        <div id="creation-error" class="error" role="alert" :if={@error}>{@error}</div>

        <div class="actions">
          <button type="button" class="btn btn-back" phx-click="back">{dgettext("ui", "← Detalles")}</button>
          <button type="button" class="btn btn-primary" phx-click="next"><i class="px px-swords" aria-hidden="true"></i>{dgettext("ui", "Crear partida")}</button>
        </div>
      <% end %>
      </section>
    </div>
    """
  end

  defp step_class(current, step) do
    cond do
      current == step -> "active"
      Enum.find_index(@steps, &(&1 == step)) < Enum.find_index(@steps, &(&1 == current)) -> "done"
      true -> ""
    end
  end

  # Roles are class keys ("fighter"); unknown values fall back to themselves.
  defp role_label(role) when is_binary(role), do: Catalog.class_label(role)
  defp role_label(role), do: role

  defp companion_label(all, key) do
    case Enum.find(all, &(&1.key == key)) do
      %{name: name, role: role} -> "#{name} (#{role_label(role)})"
      nil -> key
    end
  end

  defp used_keys(assigns) do
    assigns.companions
    |> Enum.reject(&is_nil/1)
  end

  defp available_for_slot(all_pcs, companions, my_hero, slot_idx) do
    current = Enum.at(companions, slot_idx)
    used = Enum.reject(companions, &is_nil/1) -- [current]

    Enum.reject(all_pcs, fn h -> h.key in used or h.key == my_hero end)
  end
end
