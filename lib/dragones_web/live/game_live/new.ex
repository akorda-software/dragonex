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

  alias Dragones.{Games, Scenario, Scenarios}

  @steps [:details, :characters]
  @max_companions 5

  @impl true
  def mount(_params, session, socket) do
    user = Dragones.Accounts.get_user(session["user_id"])

    if user == nil do
      {:ok, Phoenix.LiveView.redirect(socket, to: "/login")}
    else
      pcs = Enum.filter(Scenario.catalog(), &(&1.side == "pc"))
      heroes = Scenario.hero_catalog(user)

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
    s = socket.assigns

    cond do
      s.selected_scenario == nil and s.my_hero == nil ->
        # Allow skipping if no scenario but we need a hero in step 2
        {:noreply, assign(socket, step: :characters, error: nil)}

      true ->
        {:noreply, assign(socket, step: :characters, error: nil)}
    end
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
    prev = if socket.assigns.step == :characters, do: :details, else: :details
    {:noreply, assign(socket, step: prev, error: nil)}
  end

  # --- text field changes (custom scenario fields) ---

  def handle_event("change", params, socket) do
    field = List.first(params["_target"] || [])
    value = if field, do: Map.get(params, field, ""), else: ""

    if field do
      {:noreply, assign(socket, String.to_atom(field), value)}
    else
      {:noreply, socket}
    end
  end

  # --- scenario selection ---

  def handle_event("pick_scenario", %{"key" => key}, socket) do
    if key == "custom" do
      {:noreply, assign(socket, selected_scenario: %{key: "custom"}, error: nil)}
    else
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

    {bible, title, scene, dm_style} =
      case s.selected_scenario do
        %{key: "custom"} ->
          {%{}, s[:custom_title] || "Nueva partida", s[:custom_scene] || "an unremarkable crossroads",
           s[:custom_dm_style] || "vivid but brief"}

        nil ->
          {%{}, "Nueva partida", "an unremarkable crossroads", "vivid but brief"}

        scenario ->
          {Scenarios.bible(scenario), scenario.title, scenario.scene, scenario.dm_style}
      end

    # Count open slots (waiting for human players)
    open_count = Enum.count(s.companions, &(&1 == "open"))

    # Build roster: my hero (human) + AI companions (skip "open" slots)
    roster = %{}

    roster =
      if s.my_hero,
        do: Map.put(roster, s.my_hero, %{"include" => "on", "kind" => "human"}),
        else: roster

    roster =
      s.companions
      |> Enum.with_index()
      |> Enum.reduce(roster, fn {key, idx}, acc ->
        cond do
          key == nil or key == "open" ->
            acc

          Map.has_key?(acc, key) ->
            Map.put(acc, "#{key}_#{idx}", %{"include" => "on", "kind" => "ai"})

          true ->
            Map.put(acc, key, %{"include" => "on", "kind" => "ai"})
        end
      end)

    params = %{
      "title" => title,
      "scene" => scene,
      "dm_style" => dm_style,
      "story_bible" => bible,
      "dice_engine" => s.dice_engine,
      "user_id" => s.current_user.id,
      "roster" => roster,
      "open_slots" => open_count
    }

    case Games.create_from_wizard(params) do
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
      <style>
        .wizard{max-width:680px;margin:0 auto;padding:1.5rem;font-family:Georgia,'Times New Roman',serif;}
        .wizard h1{font-size:1.3rem;color:#fc8;text-align:center;}
        .steps{display:flex;justify-content:center;gap:.4rem;margin-bottom:1.5rem;}
        .steps .s{padding:.3rem .7rem;border-radius:20px;font-size:.72rem;background:#222;border:1px solid #333;color:#666;}
        .steps .s.active{background:#3a2a1a;border-color:#a72;color:#fc8;}
        .steps .s.done{background:#1a2a1a;border-color:#474;color:#9f9;}
        .step-label{font-size:.8rem;color:#7ab;text-transform:uppercase;letter-spacing:.05em;margin:.8rem 0 .3rem;}
        .btn-random{padding:.4rem 1rem;border-radius:6px;border:1px solid #474;background:#1a2a1a;color:#9f9;font-size:.85rem;cursor:pointer;font-family:inherit;margin-bottom:1rem;}
        .btn-random:hover{background:#2a3a2a;}
        .scenario-grid{display:grid;grid-template-columns:1fr 1fr;gap:.5rem;}
        .scenario-card{padding:.8rem;background:#1a1a1a;border:1px solid #333;border-radius:6px;cursor:pointer;font-size:.85rem;color:#ccc;}
        .scenario-card:hover{border-color:#555;background:#222;}
        .scenario-card.sel{border-color:#a72;background:#3a2a1a;color:#fc8;}
        .scenario-card .st{font-weight:600;margin-bottom:.2rem;}
        .scenario-card .ss{font-size:.72rem;color:#777;line-height:1.4;}
        .engine-toggle{display:grid;grid-template-columns:1fr 1fr;gap:.5rem;}
        .engine-opt{display:flex;flex-direction:column;align-items:center;gap:.15rem;padding:.7rem;background:#1a1a1a;border:1px solid #333;border-radius:6px;cursor:pointer;font-family:inherit;color:#888;}
        .engine-opt:hover{border-color:#555;background:#222;}
        .engine-opt.sel{border-color:#a72;background:#3a2a1a;color:#fc8;}
        .engine-opt .eo-tk{font-size:1.2rem;}
        .engine-opt .eo-n{font-weight:700;font-size:.95rem;}
        .engine-opt .eo-d{font-size:.68rem;color:#777;}
        .engine-opt.sel .eo-d{color:#c96;}
        .hero-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(120px,1fr));gap:.4rem;}
        .hero-opt{padding:.5rem;background:#1a1a1a;border:1px solid #333;border-radius:6px;cursor:pointer;text-align:center;font-size:.82rem;color:#ccc;}
        .hero-opt:hover{border-color:#555;}
        .hero-opt.sel{border-color:#a72;background:#3a2a1a;color:#fc8;}
        .hero-opt.taken{opacity:.4;cursor:not-allowed;}
        .hero-opt .hn{font-weight:600;}
        .hero-opt .hr{font-size:.68rem;color:#666;margin-top:.1rem;}
        .slots{display:flex;flex-direction:column;gap:.4rem;margin-top:.4rem;}
        .slot{display:flex;align-items:center;gap:.5rem;padding:.4rem .6rem;background:#1a1a1a;border:1px solid #333;border-radius:6px;font-size:.82rem;}
        .slot .slabel{color:#666;font-size:.72rem;width:3rem;}
        .slot .sval{color:#fc8;}
        .slot button{margin-left:auto;padding:.2rem .5rem;background:#2a1a1a;border:1px solid #744;color:#f99;border-radius:4px;font-size:.7rem;cursor:pointer;font-family:inherit;}
        .slot-clear:hover{background:#3a2222;}
        .slot-add{background:#2c2c2c !important;border:1px solid #444 !important;color:#888 !important;font-size:.78rem !important;}
        .slot-add:hover{background:#3a3a3a !important;color:#ccc !important;}
        .slot-pick{display:flex;flex-wrap:wrap;gap:.3rem;flex:1;}
        .pick-opt{padding:.25rem .5rem;background:#1a2a1a !important;border:1px solid #474 !important;color:#9c9 !important;border-radius:4px;font-size:.72rem !important;cursor:pointer;font-family:inherit;margin:0 !important;}
        .pick-opt:hover{background:#2a3a2a !important;border-color:#7a7 !important;}
        .pick-cancel{padding:.25rem .5rem;background:transparent !important;border:1px solid #333 !important;color:#555 !important;border-radius:4px;font-size:.72rem !important;cursor:pointer;font-family:inherit;margin:0 !important;}
        .actions{display:flex;justify-content:space-between;margin-top:1.5rem;align-items:center;}
        .btn{padding:.55rem 1.3rem;border-radius:6px;border:1px solid #444;background:#2c2c2c;color:#eee;font-size:.92rem;cursor:pointer;font-family:inherit;}
        .btn:hover{background:#3a3a3a;}
        .btn-primary{background:#3a2a1a;border-color:#a72;color:#fc8;}
        .btn-primary:hover{background:#4a3520;}
        .btn-back{background:transparent;border-color:#333;color:#888;}
        .error{color:#f99;font-size:.85rem;margin:.5rem 0;text-align:center;}
        .back{color:#7ab;text-decoration:none;font-size:.85rem;}
        .note{font-size:.75rem;color:#555;text-align:center;margin-top:.8rem;}
      </style>

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
