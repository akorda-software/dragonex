defmodule DragonesWeb.GameLive.New do
  @moduledoc """
  The creator wizard — a 2-step flow:

  1. **Detalles**: scenario selection + title/scene/dm_style.
  2. **Personajes**: pick your hero + up to 5 AI companion slots.

  Enemies are never picked by the player — the DM spawns them from the bestiary
  as the story unfolds.

  Future: "open" slots that other human players can claim by joining the game.
  """

  use Phoenix.LiveView, layout: {DragonesWeb.Layouts, :app}

  alias Dragones.{Games, Roster, Scenarios}

  @steps [:details, :characters]
  @max_companions 5

  @impl true
  def mount(_params, session, socket) do
    user = Dragones.Accounts.get_user(session["user_id"])

    if user == nil do
      {:ok, Phoenix.LiveView.redirect(socket, to: "/login")}
    else
      pcs = Enum.filter(Roster.catalog(), &(&1.side == "pc"))
      heroes = Roster.hero_catalog(user)

      {:ok,
       assign(socket,
         current_user: user,
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
         error: nil
       )}
    end
  end

  # --- navigation ---

  @impl true
  def handle_event("next", _params, %{assigns: %{step: :details}} = socket) do
    {:noreply, assign(socket, step: :characters, error: nil)}
  end

  def handle_event("next", _params, %{assigns: %{step: :characters}} = socket) do
    if socket.assigns.my_hero == nil do
      {:noreply, assign(socket, error: "Elige tu personaje.")}
    else
      # Build roster and create the game
      create_game(socket)
    end
  end

  def handle_event("back", _params, socket) do
    {:noreply, assign(socket, step: :details, error: nil)}
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
      {:noreply, assign(socket, String.to_existing_atom(field), value)}
    else
      {:noreply, socket}
    end
  end

  # --- scenario selection ---

  def handle_event("pick_scenario", %{"key" => key}, socket) do
    cond do
      key == "custom" ->
        {:noreply, assign(socket, selected_scenario: %{key: "custom"}, error: nil)}

      key == "arena" ->
        # Auto-select all 3 archetypes so the player can test every mechanic
        # without manual setup: fighter (STR melee + ranged), wizard (spellcasting),
        # rogue (DEX, finesse, ranged).
        {:noreply,
         assign(socket,
           selected_scenario: Scenarios.get(key),
           my_hero: "fighter",
           companions: ["wizard", "rogue", nil, nil, nil],
           error: nil
         )}

      true ->
        {:noreply, assign(socket, selected_scenario: Scenarios.get(key), error: nil)}
    end
  end

  # Dice render engine: "2d" (canvas, server-authoritative) or "3d" (physics).
  # Lives per-partida so every viewer shares one authoritative roll.
  def handle_event("pick_engine", %{"engine" => engine}, socket),
    do: {:noreply, assign(socket, dice_engine: if(engine == "3d", do: "3d", else: "2d"))}

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
            {:noreply, assign(socket, error: "Ya elegiste ese héroe como tu personaje.")}

          key in used ->
            {:noreply, assign(socket, error: "Ese héroe ya está en otro slot.")}

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
        {:noreply, assign(socket, error: "Ese héroe ya está como compañero IA.")}

      true ->
        {:noreply, assign(socket, my_hero: key, error: nil)}
    end
  end

  # --- random ---

  def handle_event("random", _params, socket) do
    scenario = Enum.random(Scenarios.all())

    all_pcs = socket.assigns.pcs ++ socket.assigns.heroes
    my_hero = (all_pcs |> Enum.random()).key

    companions =
      0..(@max_companions - 1)
      |> Enum.map(fn _ ->
        if :rand.uniform() > 0.5 do
          (all_pcs |> Enum.random()).key
        else
          nil
        end
      end)

    {:noreply,
     assign(socket,
       selected_scenario: scenario,
       my_hero: my_hero,
       companions: companions,
       error: nil
     )}
  end

  # --- create ---

  defp create_game(socket) do
    s = socket.assigns

    choices = %{
      user_id: s.current_user.id,
      scenario: s.selected_scenario,
      my_hero: s.my_hero,
      companions: s.companions,
      dice_engine: s.dice_engine,
      custom_title: s[:custom_title],
      custom_scene: s[:custom_scene],
      custom_dm_style: s[:custom_dm_style]
    }

    case Games.create_from_wizard_choices(choices) do
      {:ok, game} ->
        {:noreply, Phoenix.LiveView.push_navigate(socket, to: "/games/#{game.id}")}

      {:error, :no_characters} ->
        {:noreply, assign(socket, error: "Selecciona al menos un personaje.")}

      {:error, _} ->
        {:noreply, assign(socket, error: "No se pudo crear la partida.")}
    end
  end

  # --- render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="wizard">

      <.link navigate="/" class="back">← volver</.link>
      <h1>Nueva partida</h1>

      <div style="text-align:center;">
        <button type="button" class="btn-random" phx-click="random">🎲 Aleatorio</button>
      </div>

      <div class="steps">
        <span class={"s #{step_class(@step, :details)}"}>1 · Detalles</span>
        <span class={"s #{step_class(@step, :characters)}"}>2 · Personajes</span>
      </div>

      <%= if @step == :details do %>
        <div class="step-label">Escenario</div>
        <div class="scenario-grid">
          <div :for={s <- @scenarios} :key={s.key}
               class={"scenario-card #{if @selected_scenario && @selected_scenario.key == s.key, do: "sel", else: ""}"}
               phx-click="pick_scenario" phx-value-key={s.key}>
            <div class="st">{s.title}</div>
            <div class="ss">{s.summary}</div>
          </div>
          <div class={"scenario-card #{if @selected_scenario && @selected_scenario.key == "custom", do: "sel", else: ""}"}
               phx-click="pick_scenario" phx-value-key="custom">
            <div class="st">✍ Personalizada</div>
            <div class="ss">Crea tu propia aventura desde cero.</div>
          </div>
        </div>

        <div :if={@selected_scenario && @selected_scenario.key == "custom"} style="margin-top:1rem;">
          <div class="step-label">Título</div>
          <input type="text" name="custom_title" phx-change="change" placeholder="Mi aventura…" />

          <div class="step-label">Escena inicial</div>
          <input type="text" name="custom_scene" phx-change="change" placeholder="una taberna, un calabozo, un bosque…" />

          <div class="step-label">Estilo del DM</div>
          <input type="text" name="custom_dm_style" phx-change="change" value="vivid but brief" />
        </div>

        <div :if={@selected_scenario && @selected_scenario.key != "custom"} style="margin-top:1rem;">
          <div class="step-label">Título</div>
          <div style="color:#eee;font-size:.95rem;">{@selected_scenario.title}</div>
          <div class="step-label">Escena</div>
          <div style="color:#aaa;font-size:.85rem;font-style:italic;">{@selected_scenario.scene}</div>
          <div class="step-label">Tono</div>
          <div style="color:#aaa;font-size:.82rem;">{@selected_scenario.tone}</div>
        </div>

        <div style="margin-top:1.2rem;">
          <div class="step-label">Motor de dados</div>
          <div class="engine-toggle">
            <button type="button" class={"engine-opt #{if @dice_engine == "2d", do: "sel", else: ""}"} phx-click="pick_engine" phx-value-engine="2d">
              <span class="eo-tk">🎲</span>
              <span class="eo-n">2D</span>
              <span class="eo-d">canvas, rápido</span>
            </button>
            <button type="button" class={"engine-opt #{if @dice_engine == "3d", do: "sel", else: ""}"} phx-click="pick_engine" phx-value-engine="3d">
              <span class="eo-tk">🎮</span>
              <span class="eo-n">3D</span>
              <span class="eo-d">física, inmersivo</span>
            </button>
          </div>
        </div>

        <div class="error" :if={@error}>{@error}</div>

        <div class="actions">
          <span></span>
          <button type="button" class="btn btn-primary" phx-click="next">Personajes →</button>
        </div>
      <% else %>
        <div class="step-label">Tu personaje</div>
        <div class="hero-grid">
          <div :for={h <- @heroes} :key={h.key}
               class={"hero-opt #{if @my_hero == h.key, do: "sel", else: ""} #{if h.key in @companions, do: "taken", else: ""}"}
               phx-click="pick_hero" phx-value-key={h.key}>
            <div class="hn">{h.name}</div>
            <div class="hr">{h.role}</div>
          </div>
          <div :for={c <- @pcs} :key={c.key}
               class={"hero-opt #{if @my_hero == c.key, do: "sel", else: ""} #{if c.key in @companions, do: "taken", else: ""}"}
               phx-click="pick_hero" phx-value-key={c.key}>
            <div class="hn">{c.name}</div>
            <div class="hr">{c.role}</div>
          </div>
        </div>

        <div class="step-label">Compañeros (hasta {@max_companions})</div>
        <div class="slots">
          <%= for {companion, idx} <- Enum.with_index(@companions) do %>
            <div class="slot">
              <span class="slabel">Slot {idx + 1}</span>
              <%= cond do %>
                <% companion == "open" -> %>
                  <span class="sval" style="color:#9f9;">🔓 Esperando jugador…</span>
                  <button type="button" class="slot-clear" phx-click="clear_companion" phx-value-slot={idx}>✕</button>
                <% companion -> %>
                  <span class="sval">{companion_label(@heroes ++ @pcs, companion)} 🤖</span>
                  <button type="button" class="slot-clear" phx-click="clear_companion" phx-value-slot={idx}>✕</button>
                <% @picking_slot == idx -> %>
                  <div class="slot-pick">
                    <button type="button" class="pick-opt" phx-click="pick_companion" phx-value-slot={idx} phx-value-key="open">🔓 Abrir para jugador</button>
                    <% avail = available_for_slot(@heroes ++ @pcs, @companions, @my_hero, idx) %>
                    <%= for h <- avail do %>
                      <button type="button" class="pick-opt" phx-click="pick_companion" phx-value-slot={idx} phx-value-key={h.key}>
                        {h.name} ({h.role}) 🤖
                      </button>
                    <% end %>
                    <button type="button" class="pick-cancel" phx-click="close_picker">Cancelar</button>
                  </div>
                <% true -> %>
                  <button type="button" class="slot-add" phx-click="open_picker" phx-value-slot={idx}>+ Añadir</button>
              <% end %>
            </div>
          <% end %>
        </div>

        <div class="note">💡 Los enemigos los invoca el DM según la historia. Próximamente: slots abiertos para otros jugadores.</div>

        <div class="error" :if={@error}>{@error}</div>

        <div class="actions">
          <button type="button" class="btn btn-back" phx-click="back">← Detalles</button>
          <button type="button" class="btn btn-primary" phx-click="next">⚔ Crear partida</button>
        </div>
      <% end %>
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

  defp companion_label(all, key) do
    case Enum.find(all, &(&1.key == key)) do
      %{name: name, role: role} -> "#{name} (#{role})"
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
