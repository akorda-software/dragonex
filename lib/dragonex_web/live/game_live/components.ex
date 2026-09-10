defmodule DragonexWeb.GameLive.Components do
  @moduledoc """
  Presentational function components for the game table: the full table layout
  (topbar, chat timeline, rails, input), the waiting room, the turn bar and the
  character cards (combat tracker + detail sheet).

  Extracted from `DragonexWeb.GameLive.Show` so the markup + its tiny view
  helpers live apart from the LiveView's event handling and state. The chat
  view-model builders live in `DragonexWeb.GameLive.Chat`, the dice overlay in
  `DragonexWeb.GameLive.Dice` and the Ajustes modal in
  `DragonexWeb.GameLive.Settings`.
  """

  use Phoenix.Component

  alias Dragonex.{Character, World}
  alias DragonexWeb.GameLive.{Chat, Dice, Settings}

  @max_sheets 4

  # ----------------------------------------------------------------- turn bar

  attr(:world, :any, default: nil)
  attr(:current, :any, default: nil)
  attr(:round, :integer, default: 1)
  attr(:status, :any, default: nil)
  attr(:viewer, :any, default: nil)

  def turn_bar(%{
        world: %World{phase: :combat} = w,
        current: current,
        round: round,
        status: status,
        viewer: viewer
      }) do
    assigns = %{w: w, current: current, round: round, status: status, viewer: viewer}

    ~H"""
    <span class="round">Round {@round}</span>
    <ul class="initiative">
      <li :for={name <- @w.initiative_order} :key={name} class={if World.acting?(@w, name, @current), do: "active", else: ""}>
        {name}
      </li>
    </ul>
    <span class="whose-turn">{turn_label(@current, @status, @viewer)}</span>
    """
  end

  def turn_bar(%{current: current, status: status, viewer: viewer}) do
    assigns = %{current: current, status: status, viewer: viewer}

    ~H"""
    <span class="phase">Exploración</span>
    <span class="whose-turn">{turn_label(@current, @status, @viewer)}</span>
    """
  end

  defp turn_label(_current, :paused, _), do: "En pausa"
  defp turn_label(viewer, _, viewer) when is_binary(viewer), do: "¡Tu turno!"
  defp turn_label("dm", _, _), do: "Turno del DM"
  defp turn_label(other, _, _) when is_binary(other), do: "Esperando a #{other}"
  defp turn_label(_, _, _), do: ""

  # --------------------------------------------------------------- sheet card

  attr(:card, :map, default: nil)
  attr(:active, :boolean, default: false)
  attr(:mine, :boolean, default: false)

  def sheet(assigns) do
    ~H"""
    <%= if @card do %>
      <% card = @card
         pct = if card.max_hp > 0, do: max(0, card.hp) / card.max_hp * 100, else: 0
         status = if card.hp <= 0, do: " [DOWN]", else: ""
         conds = Enum.map(card.conditions || [], &cond_name/1) %>
      <div class={"card side-#{card.side}#{if @active, do: " your-turn", else: ""}#{if @mine, do: " mine", else: ""}"}>
        <h3>
          {card.name}{status}<span :if={@mine} class="you-tag"> TÚ</span>
        </h3>
        <p class="muted">{card.class} · {card.side}</p>
        <div class="hp"><div class="hp-fill" style={"width:#{pct}%"}></div></div>
        <p>HP {card.hp}/{card.max_hp} · AC {card.ac}</p>
        <p :if={conds != []} class="conds">
          <span :for={c <- conds} class="cond-badge">{c}</span>
        </p>
      </div>
    <% else %>
      <div class="empty-sheet muted">— vacío —</div>
    <% end %>
    """
  end

  # ----------------------------------------------------------- combat tracker

  # A scrollable initiative tracker shown in the left rail during combat: every
  # combatant in turn order with an HP bar, AC, conditions and a clear marker on
  # whoever is acting right now.
  attr(:world, :any, required: true)
  attr(:current, :any, default: nil)
  attr(:round, :integer, default: 1)
  attr(:viewer, :any, default: nil)

  def combat_tracker(assigns) do
    ~H"""
    <div class="combat-tracker">
      <div class="ct-header">
        <span>⚔</span> Iniciativa <span class="ct-round">Ronda {@round}</span>
      </div>
      <div class="ct-list">
        <div :for={name <- @world.initiative_order} :key={name}>
          <.combatant world={@world} name={name} current={@current} viewer={@viewer} />
        </div>
      </div>
    </div>
    """
  end

  attr(:world, :any, required: true)
  attr(:name, :string, required: true)
  attr(:current, :any, default: nil)
  attr(:viewer, :any, default: nil)

  def combatant(assigns) do
    c = Map.get(assigns.world.characters, assigns.name)
    acting = World.acting?(assigns.world, assigns.name, assigns.current)
    pct = if c && c.max_hp > 0, do: max(0, c.hp) / c.max_hp * 100, else: 0
    conds = if c, do: Enum.map(c.conditions || [], &cond_name/1), else: []

    assigns =
      assign(assigns, c: c, acting: acting, pct: pct, down: c && c.hp <= 0, conds: conds)

    ~H"""
    <div class={"combatant side-#{(@c && @c.side) || "pc"}#{if @acting, do: " acting", else: ""}#{if @name == @viewer, do: " mine", else: ""}"}>
      <span class="ct-mark">{if @acting, do: "▶", else: ""}</span>
      <div class="ct-body">
        <div class="ct-name">
          {@name}<span :if={@name == @viewer} class="you-tag"> TÚ</span><span :if={@down} class="ct-down"> ✖</span>
        </div>
        <div class="hp"><div class="hp-fill" style={"width:#{@pct}%"}></div></div>
        <div class="ct-stats">HP {(@c && @c.hp) || 0}/{(@c && @c.max_hp) || 0} · CA {(@c && @c.ac) || "?"}</div>
        <div :if={@conds != []} class="conds">
          <span :for={cd <- @conds} class="cond-badge">{cd}</span>
        </div>
      </div>
    </div>
    """
  end

  # The viewer's own detailed sheet (combat): full stats + weapons/spells so the
  # player has their full character at hand while the tracker shows everyone.
  attr(:card, :map, default: nil)

  def detail_sheet(assigns) do
    ~H"""
    <%= if @card do %>
      <% card = @card
         pct = if card.max_hp > 0, do: max(0, card.hp) / card.max_hp * 100, else: 0
         conds = Enum.map(card.conditions || [], &cond_name/1)
         weapons = Enum.map(card.weapons || [], & &1.name)
         spells = Enum.map(card.spells || [], & &1.name) %>
      <div class="sheet">
        <div class="card mine">
          <h3>{card.name}<span class="you-tag"> TÚ</span></h3>
          <p class="muted">{card.race} {card.class} · niv {card.level}</p>
          <div class="hp"><div class="hp-fill" style={"width:#{pct}%"}></div></div>
          <p>HP {card.hp}/{card.max_hp} · CA {card.ac}</p>
          <p class="muted">STR {card.str} · DEX {card.dex} · CON {card.con}<br />INT {card.int} · WIS {card.wis} · CHA {card.cha}</p>
          <p :if={weapons != []}><span class="muted">Armas:</span> {Enum.join(weapons, ", ")}</p>
          <p :if={spells != []}><span class="muted">Hechizos:</span> {Enum.join(spells, ", ")}</p>
          <p :if={conds != []} class="conds">
            <span :for={c <- conds} class="cond-badge">{c}</span>
          </p>
        </div>
      </div>
    <% end %>
    """
  end

  # ----------------------------------------------- shared condition formatter

  # Normalizes a condition entry (struct/map/binary shape from jsonb or live
  # state) into a display label.
  defp cond_name(%{condition: c}), do: c
  defp cond_name(%{"condition" => c}), do: c
  defp cond_name(c) when is_binary(c), do: c
  defp cond_name(_), do: "?"

  # ------------------------------------------------------------- full table

  # The full table, rendered once the viewer has claimed a seat.
  def table(assigns) do
    ~H"""
    <% cards = sheets(@world) %>

    <header class="game-topbar">
      <div class="turn-bar">
        <.turn_bar world={@world} current={@current} round={@round} status={@status} viewer={@viewer} />
        <span class="controls">
          <span class="viewer-tag">tú: {@viewer}</span>
          <button :if={@viewer != "dm"} class={"ctl-btn #{if @auto_play, do: "ctl-active", else: ""}"} phx-click="toggle_auto">
            {if @auto_play, do: "🤖 Auto ON", else: "🤖 Auto"}
          </button>
          <button class="ctl-btn" phx-click="toggle_dice_engine" disabled={@dice_rolling} title="Cambiar render de dados">
            🎲 {String.upcase(@dice_engine)}
          </button>
          <.link :if={@is_creator and @viewer != "dm"} patch={"/games/#{@game_id}?as=dm"} class="ctl-btn">👁 DM</.link>
          <.link :if={@is_creator and @viewer == "dm"} patch={"/games/#{@game_id}"} class="ctl-btn">👤 Personaje</.link>
          <button class="ctl-btn" phx-click="share">🔗 Compartir</button>
          <.link navigate="/" class="ctl-btn">lobby</.link>
          <button :if={@is_creator and @status in [:running, :waiting]} class="ctl-btn" phx-click="pause">Pausa</button>
          <button :if={@is_creator and @status == :paused} class="ctl-btn" phx-click="resume">Reanudar</button>
          <button :if={@is_creator} class="ctl-btn ai-btn" phx-click="open_settings" title={"Ajustes de IA: " <> Settings.ai_button_label()}>
            <span class="ai-gear">
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <path d="M11.078 2.25c-.917 0-1.699.663-1.85 1.567L9.05 4.889c-.02.12-.115.26-.297.348a7.493 7.493 0 0 0-.986.57c-.166.115-.334.126-.45.083L6.3 5.508a1.875 1.875 0 0 0-2.282.819l-.922 1.597a1.875 1.875 0 0 0 .432 2.385l.84.692c.095.078.17.229.154.43a7.598 7.598 0 0 0 0 1.139c.015.2-.059.352-.153.43l-.841.692a1.875 1.875 0 0 0-.432 2.385l.922 1.597a1.875 1.875 0 0 0 2.282.818l1.019-.382c.115-.043.283-.031.45.082.312.214.641.405.985.57.182.088.277.228.297.35l.178 1.071c.151.904.933 1.567 1.85 1.567h1.844c.916 0 1.699-.663 1.85-1.567l.178-1.072c.02-.12.114-.26.297-.349.344-.165.673-.356.985-.57.167-.114.335-.125.45-.082l1.02.382a1.875 1.875 0 0 0 2.28-.819l.923-1.597a1.875 1.875 0 0 0-.432-2.385l-.84-.692c-.095-.078-.17-.229-.154-.43a7.614 7.614 0 0 0 0-1.139c-.016-.2.059-.352.153-.43l.84-.692c.708-.582.891-1.59.433-2.385l-.922-1.597a1.875 1.875 0 0 0-2.282-.818l-1.02.382c-.114.043-.282.031-.449-.083a7.49 7.49 0 0 0-.985-.57c-.183-.087-.277-.227-.297-.348l-.179-1.072a1.875 1.875 0 0 0-1.85-1.567h-1.843ZM12 15.75a3.75 3.75 0 1 0 0-7.5 3.75 3.75 0 0 0 0 7.5Z" />
              </svg>
            </span>
            <span class="ai-label">{Settings.ai_button_label()}</span>
          </button>
        </span>
      </div>
    </header>

    <div class="toast-stack">
      <div :if={@my_turn} class="game-toast my-turn-banner">
        🎲 Es tu turno — ¿qué hace {@viewer}?
      </div>
      <div :if={@my_intent} class="game-toast intent-banner">
        Has declarado: «{@my_intent}»
        <button class="ctl-btn" phx-click="clear_intent">borrar</button>
        <span :if={not @my_turn} class="muted">(se resolverá en tu turno)</span>
      </div>
    </div>

    <div class="game-body">
    <input type="checkbox" id="sheet-drawer" class="sheet-drawer-toggle" />
    <aside class="game-rail game-rail-left">
      <%= if @world != nil and @world.phase == :combat do %>
        <.combat_tracker world={@world} current={@current} round={@round} viewer={@viewer} />
      <% else %>
        <div class="sheet">
          <.sheet card={Enum.at(cards, 0)} active={active_card?(@world, Enum.at(cards, 0), @current)} mine={@viewer != "dm" and Enum.at(cards, 0) != nil and Enum.at(cards, 0).name == @viewer} />
        </div>
        <div class="sheet">
          <.sheet card={Enum.at(cards, 2)} active={active_card?(@world, Enum.at(cards, 2), @current)} mine={@viewer != "dm" and Enum.at(cards, 2) != nil and Enum.at(cards, 2).name == @viewer} />
        </div>
      <% end %>
    </aside>

    <section class="game-center">
      <div class="game-log" id="log" phx-hook="AutoScroll">
        <button
          :if={@has_more_events}
          class="load-more-btn"
          phx-click="load_more_log"
          title="Cargar turnos anteriores"
        >
          ↑ cargar turnos anteriores
        </button>

        <div :for={{block, bi} <- Enum.with_index(@chat)} :key={block.header && block.header.turn_id || bi} class="turn-block">
          <div :if={block.header} class="turn-head">
            <span class="th-line">
              <span class={"th-actor #{Chat.th_actor_class(block.header.actor, @viewer, @auto_play)}"}>
                {Chat.turn_header_label(block.header.actor, @viewer, @auto_play)}
              </span>
              <span :if={block.header.phase == "combat"} class="th-phase">⚔ combate</span>
            </span>
          </div>

          <p
            :for={entry <- block.events}
            :key={entry.seq}
            class={"msg msg-#{entry.role}#{if entry.outcome, do: " roll-#{entry.outcome}", else: ""}"}
          >
            <span :if={entry.type == :action and entry.actor != "dm"} class="player-declared-chip" title={entry.text}>
              <span class="pd-icon">💭</span>
            </span>
            <span :if={not (entry.type == :action and entry.actor != "dm")}>
              <span :if={entry.who != ""}><span class="who">{entry.who}</span>{" "}</span>{entry.text}
            </span>
          </p>
        </div>
        <p :if={@busy and @live_text == ""} class="msg msg-system thinking">
          {case @busy_actor do
            "dm" -> "el DM está narrando…"
            nil -> "el DM está pensando…"
            name -> "#{name} está actuando…"
          end}
        </p>
        <p :if={@live_text != ""} class={"msg msg-#{if @live_actor == "dm", do: "dm", else: "pc"} live-streaming"}>
          <span :if={Chat.show_live_who?(@live_text, @live_actor)} class="who">{@live_actor} ·</span>{if Chat.show_live_who?(@live_text, @live_actor), do: " "}{Chat.live_shown(@live_text, @live_actor)}<span class="cursor">▍</span>
        </p>
      </div>
      <div class="game-input-area">
        <form class="game-input" id="player-input" phx-change="draft" phx-submit="declare">
          <input
            name="text"
            value={@pending}
            disabled={@status == :ended}
            placeholder={placeholder(@my_turn, @busy, @current, @status)}
          />
          <button type="submit" disabled={@status == :ended}>
            {if @my_turn and not @busy, do: "Actuar", else: "Declarar"}
          </button>
        </form>
      </div>
    </section>

    <label for="sheet-drawer" class="sheet-drawer-label">Ficha</label>
    <aside class="game-rail game-rail-right">
      <%= if @world != nil and @world.phase == :combat and @viewer != "dm" and @world.characters[@viewer] != nil do %>
        <.detail_sheet card={@world.characters[@viewer]} />
      <% else %>
        <div class="sheet">
          <.sheet card={Enum.at(cards, 1)} active={active_card?(@world, Enum.at(cards, 1), @current)} mine={@viewer != "dm" and Enum.at(cards, 1) != nil and Enum.at(cards, 1).name == @viewer} />
        </div>
        <div class="sheet">
          <.sheet card={Enum.at(cards, 3)} active={active_card?(@world, Enum.at(cards, 3), @current)} mine={@viewer != "dm" and Enum.at(cards, 3) != nil and Enum.at(cards, 3).name == @viewer} />
        </div>
      <% end %>
    </aside>
    </div>

    <Dice.stage
      show={@dice_show}
      rolling={@dice_rolling}
      hand={@dice_hand}
      groups={@dice_groups}
      engine={@dice_engine}
    />
    """
  end

  # ----------------------------------------------------------- waiting room

  # The waiting room: a lobby where players join, pick heroes, and the creator
  # starts when everyone is ready.
  def waiting_room(assigns) do
    ~H"""
    <div class="wr">

      <div class="wr-header">
        <h1>⚔ {@game.title}</h1>
        <div class="scene">{(@game.world || %{})["scene"] || ""}</div>
      </div>

      <div class="wr-layout">
        <div class="slots-area">
          <h2>Jugadores en la sala</h2>
          <div class="slots-circle">
            <% participants = preload_participants(@game) %>

            <%= for p <- participants do %>
              <div class={"slot-card ready #{if @current_user && p.user_id == @current_user.id, do: "you", else: ""}"}>
                <div class="avatar">{if p.kind == :ai, do: "🤖", else: "👤"}</div>
                <div class="sname">{p.name}</div>
                <div class="shero">{hero_role(p)}</div>
                <div class="sbadge sbadge-ready">
                  {if @current_user && p.user_id == @current_user.id, do: "TÚ ✓", else: "listo"}
                </div>
              </div>
            <% end %>

            <%= for _ <- List.duplicate(nil, @game.open_slots) do %>
              <div class="slot-card empty">
                <div class="avatar">🔓</div>
                <div class="sname" style="color:#888;">Slot libre</div>
                <div class="sbadge sbadge-empty">esperando jugador…</div>
              </div>
            <% end %>
          </div>

          <%!-- Hero picker for non-participants --%>
          <%= if @current_user && not participant?(@current_user, participants) and @game.open_slots > 0 do %>
            <div class="hero-picker">
              <div class="hero-picker-label">Elige tu héroe para unirte</div>
              <div class="hero-grid">
                <%= for hero <- @waiting_heroes do %>
                  <div class="hero-btn" phx-click="join_with_hero" phx-value-hero_id={hero.id}>
                    <div class="hn">{hero.name}</div>
                    <div class="hd">{String.capitalize(hero.race)} {String.capitalize(hero.class)}</div>
                  </div>
                <% end %>
              </div>
              <div :if={@waiting_heroes == []} class="no-hero">
                No tienes héroes. <a href="/heroes/new" style="color:#7ab;">Crear uno →</a>
              </div>
            </div>
          <% end %>
        </div>

        <div class="sidebar">
          <div class="panel">
            <h3>Invitar jugadores</h3>
            <div class="info-row">📋 Comparte el enlace con tus amigos</div>
            <button class="copy-btn" phx-click="share">📋 Copiar enlace</button>
            <div class="info-row" style="margin-top:.5rem;">
              🔓 {@game.open_slots} slot(s) libre(s)
            </div>
          </div>

          <div class="panel">
            <%= if @is_creator do %>
              <button class="start-btn" phx-click="start_game">⚔ ¡Empezar partida!</button>
              <div class="info-row" style="text-align:center;margin-top:.5rem;">
                Puedes empezar cuando quieras
              </div>
            <% else %>
              <% joined = participant?(@current_user, participants) %>
              <h3>{if joined, do: "Estado", else: "Únete"}</h3>
              <div class="info-row">
                {if joined, do: "✅ Estás listo — esperando al creador…", else: "Elige un héroe arriba para unirte"}
              </div>
            <% end %>
          </div>

          <div class="panel">
            <h3>Info</h3>
            <div class="info-row">📖 {(@game.story_bible || %{})["tone"] || "—"}</div>
            <div class="info-row">🎭 {String.slice((@game.story_bible || %{})["hook"] || "", 0, 80)}…</div>
          </div>

          <.link navigate="/" style="text-align:center;color:#7ab;font-size:.8rem;display:block;">← lobby</.link>
        </div>
      </div>
    </div>
    """
  end

  defp hero_role(%{kind: :ai}), do: "IA"
  defp hero_role(%{kind: :human}), do: "Jugador"

  defp preload_participants(game), do: game.participants || []

  defp participant?(nil, _), do: false

  defp participant?(%{id: uid}, participants) do
    Enum.any?(participants, fn p -> p.user_id == uid end)
  end

  # ---------------------------------------------------------------- helpers

  defp sheets(nil), do: []

  defp sheets(%World{} = w),
    do:
      w.characters
      |> Enum.reject(fn {_, c} -> c.side != "pc" and c.hp <= 0 end)
      |> Enum.sort_by(fn {n, _} -> n end)
      |> Enum.take(@max_sheets)
      |> Enum.map(&elem(&1, 1))

  defp active_card?(%World{} = w, %Character{} = c, current),
    do: World.acting?(w, c.name, current) and c.hp > 0

  defp active_card?(_, _, _), do: false

  defp placeholder(_, _, _, :paused), do: "Declara tu intención (en pausa)…"
  defp placeholder(_, _, _, :ended), do: "La partida ha terminado"
  defp placeholder(true, false, _, _), do: "¿Qué haces?"

  defp placeholder(_, _, current, _) when is_binary(current),
    do: "Declara tu intención (turno de #{current})…"

  defp placeholder(_, _, _, _), do: "Declara tu intención…"
end
