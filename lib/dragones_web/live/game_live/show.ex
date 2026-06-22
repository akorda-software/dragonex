defmodule DragonesWeb.GameLive.Show do
  @moduledoc """
  The game table — a thin **view + input** over a `Dragones.Game` process.

  It opens a partida by `game_id` (resuming it from Postgres), subscribes to its
  `Dragones.PubSub` updates, and renders the Game's snapshot. Each viewer
  **claims a participant** (`?as=<name>` or the picker overlay), so several humans
  can share a partida: the input is gated to the viewer's own turn, their sheet is
  marked, and a banner calls "Es tu turno". The Game owns the loop/rules/persistence
  and enforces server-side that `act/3` only resolves the current human's turn.
  """

  use Phoenix.LiveView, layout: {DragonesWeb.Layouts, :app}

  alias Dragones.{Character, Game, Games, World}

  @max_sheets 4

  @impl true
  def mount(%{"game_id" => id}, _session, socket) do
    game_id = String.to_integer(id)

    cond do
      not Phoenix.LiveView.connected?(socket) ->
        {:ok, base_assigns(socket, game_id)}

      Games.get_game(game_id) == nil ->
        {:ok, push_navigate(socket, to: "/")}

      true ->
        Phoenix.PubSub.subscribe(Dragones.PubSub, "dragones:game:#{game_id}")
        {:ok, _pid} = Game.ensure_started(game_id)
        {:ok, assign(socket, game_id: game_id, connected: true)}
    end
  end

  # The viewer is derived from the `?as=` query param (shareable URL) on mount
  # and whenever the picker patches it. The Game's own broadcasts re-load the
  # same viewer via handle_info.
  @impl true
  def handle_params(params, _url, %{assigns: %{connected: true, game_id: gid}} = socket) do
    {:noreply, load(socket, gid, Map.get(params, "as"))}
  end

  def handle_params(_params, _url, socket), do: {:noreply, socket}

  # --------------------------------------------------------------- events

  @impl true
  def handle_event("declare", %{"text" => text}, socket) do
    with pid when is_pid(pid) <- server(socket),
         viewer when not is_nil(viewer) <- socket.assigns[:viewer] do
      _ = Game.declare(pid, viewer, text)
    end

    {:noreply, assign(socket, pending: "")}
  end

  def handle_event("clear_intent", _params, socket) do
    with pid when is_pid(pid) <- server(socket),
         viewer when not is_nil(viewer) <- socket.assigns[:viewer] do
      _ = Game.clear_intent(pid, viewer)
    end

    {:noreply, socket}
  end

  def handle_event("pause", _params, socket) do
    if pid = server(socket), do: _ = Game.pause(pid)
    {:noreply, socket}
  end

  def handle_event("resume", _params, socket) do
    if pid = server(socket), do: _ = Game.resume(pid)
    {:noreply, socket}
  end

  def handle_event("dismiss_modal", _params, socket),
    do: {:noreply, assign(socket, show_modal: false, rolls: [])}

  @impl true
  def handle_info({:game_updated, game_id}, %{assigns: %{game_id: game_id, viewer: viewer}} = socket),
    do: {:noreply, load(socket, game_id, viewer)}

  def handle_info({:dice_roll, game_id, sides, value}, %{assigns: %{game_id: game_id}} = socket) do
    id = socket.assigns.rolls_seq + 1

    {:noreply,
     socket
     |> assign(rolls_seq: id, show_modal: true)
     |> update(:rolls, &(&1 ++ [%{id: id, sides: sides, value: value}]))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --------------------------------------------------------------- load

  defp base_assigns(socket, game_id) do
    assign(socket,
      loaded: false,
      connected: false,
      game_id: game_id,
      viewer: nil,
      world: nil,
      current: nil,
      status: nil,
      round: 1,
      participants: %{},
      my_turn: false,
      chat: [],
      busy: false,
      pending: "",
      rolls: [],
      rolls_seq: 0,
      show_modal: false
    )
  end

  defp load(socket, game_id, viewer_param) do
    case Dragones.Game.Supervisor.whereis(game_id) do
      nil ->
        base_assigns(socket, game_id)

      pid ->
        snap = Game.snapshot(pid)
        viewer = validate_viewer(viewer_param, snap.participants)

        assign(socket,
          loaded: true,
          connected: true,
          game_id: game_id,
          viewer: viewer,
          world: snap.world,
          current: snap.current,
          status: snap.status,
          round: snap.round,
          participants: snap.participants,
          intents: snap.intents,
          my_intent: Map.get(snap.intents, viewer),
          my_turn: viewer != nil and snap.current == viewer,
          chat: chat_lines(snap.events, viewer),
          busy: snap.status == :running,
          pending: "",
          rolls: socket.assigns[:rolls] || [],
          rolls_seq: socket.assigns[:rolls_seq] || 0,
          show_modal: socket.assigns[:show_modal] || false
        )
    end
  end

  # A valid viewer is a human participant or "dm" (the omniscient referee view).
  defp validate_viewer("dm", _), do: "dm"

  defp validate_viewer(name, participants) when is_binary(name) do
    case Map.get(participants, name) do
      %{kind: :human} -> name
      _ -> nil
    end
  end

  defp validate_viewer(_, _), do: nil

  defp chat_lines(events, viewer) do
    events
    |> Enum.filter(fn e ->
      if viewer == "dm", do: e.visible_to in ["all", "dm"], else: e.visible_to == "all"
    end)
    |> Enum.map(fn e -> %{seq: e.seq, role: chat_role(e), text: chat_text(e)} end)
  end

  defp chat_role(%{type: :narration}), do: :dm
  defp chat_role(%{type: :action, actor: actor}), do: if(actor == "dm", do: :dm, else: :player)
  defp chat_role(_), do: :system

  defp chat_text(%{type: :system, payload: p}), do: p["note"] || p[:note] || ""
  defp chat_text(%{payload: p}), do: p["text"] || p[:text] || ""

  defp server(%{assigns: %{game_id: game_id}}) when not is_nil(game_id),
    do: Dragones.Game.Supervisor.whereis(game_id)

  defp server(_), do: nil

  # The pickable seats: human participants (claim your character) + "DM" view.
  defp seats(%{participants: ps}) do
    human =
      ps
      |> Map.values()
      |> Enum.filter(&(&1.kind == :human))
      |> Enum.map(& &1.name)
      |> Enum.sort()

    human ++ ["dm"]
  end

  # --------------------------------------------------------------- render

  @impl true
  def render(assigns) do
    ~H"""
    <div class="game">
      <style>
        .game { display:grid; grid-template-columns:220px 1fr 220px; grid-template-rows:auto 1fr 1fr auto;
          grid-template-areas:"bar bar bar" "tl chat tr" "bl chat br" "input input input";
          gap:.6rem; padding:.6rem; height:100vh; box-sizing:border-box; }
        .turn-bar{grid-area:bar; display:flex; align-items:center; gap:1rem; background:#1f1f1f; border:1px solid #333; border-radius:6px; padding:.4rem .8rem; font-size:.9rem;}
        .round{font-weight:bold; color:#fb0;}
        .initiative{display:flex; gap:.4rem; list-style:none; padding:0; margin:0;}
        .initiative li{padding:.15rem .5rem; background:#2a2a2a; border-radius:4px; border:1px solid #333;}
        .initiative li.active{background:#3a3a1a; border-color:#bb0; color:#ff5;}
        .whose-turn{font-weight:bold;}
        .controls{margin-left:auto; display:flex; gap:.4rem; align-items:center;}
        .viewer-tag{font-size:.8rem; color:#7ab;}
        .ctl-btn{padding:.25rem .7rem; font-size:.8rem; border-radius:4px; border:1px solid #555; background:#2c2c2c; color:#eee; cursor:pointer; text-decoration:none;}
        .ctl-btn:hover{background:#3a3a3a;}
        .my-turn-banner{background:#3a2a0a; border:1px solid #ea0; color:#ff5; padding:.4rem .8rem; border-radius:4px; font-weight:bold; animation:pulse 1.5s infinite;}
        @keyframes pulse{0%,100%{opacity:1;}50%{opacity:.6;}}
        .intent-banner{display:flex; align-items:center; gap:.6rem; background:#1a2a3a; border:1px solid #4af; color:#cdf; padding:.35rem .6rem; border-radius:4px; font-size:.85rem;}
        .slot-tl{grid-area:tl;} .slot-tr{grid-area:tr;} .slot-bl{grid-area:bl;} .slot-br{grid-area:br;}
        .chat{grid-area:chat; display:flex; flex-direction:column;}
        .input{display:flex; gap:.4rem;}
        .input-area{grid-area:input; display:flex; flex-direction:column; gap:.3rem;}
        .input input{flex:1; padding:.5rem; font-size:1rem; background:#222; color:#eee; border:1px solid #444; border-radius:4px;}
        .input button{padding:.5rem 1.2rem; font-size:1rem; background:#2c2c2c; color:#eee; border:1px solid #555; border-radius:4px; cursor:pointer;}
        .input button:hover:not(:disabled){background:#3a3a3a;}
        .log{background:#111; border:1px solid #333; border-radius:6px; padding:.8rem; font-size:.95rem; line-height:1.4; overflow:auto;}
        .msg{margin:0 0 .6rem;} .msg .who{display:inline-block; margin-right:.4rem; font-weight:bold; color:#7ab;}
        .msg-player{color:#ffd;} .msg-player .who{color:#fb0;}
        .msg-system{color:#777; font-style:italic;}
        .sheet{display:flex; align-items:flex-start;}
        .card,.empty-sheet{width:100%; background:#222; border:1px solid #3a3a3a; border-radius:8px; padding:.6rem;}
        .card h3{margin:0; font-size:1rem;} .card p{margin:.2rem 0; font-size:.85rem;}
        .side-enemy{border-color:#5a2222;} .card.your-turn{box-shadow:0 0 0 2px #bb0 inset;}
        .card.mine{box-shadow:0 0 0 2px #4af inset;}
        .you-tag{font-size:.7rem; color:#4af; font-weight:bold; margin-left:.4rem;}
        .hp{height:8px; background:#400; border-radius:4px; margin:.3rem 0; overflow:hidden;}
        .hp-fill{height:100%; background:#3c3;}
        .modal{position:fixed; inset:0; background:rgba(0,0,0,.6); display:flex; align-items:center; justify-content:center; z-index:10;}
        .modal-box{background:#222; border:1px solid #555; border-radius:10px; padding:1.2rem 2rem; text-align:center;}
        .modal-box ul{list-style:none; padding:0; font-size:1.3rem;}
        .die{display:inline-block; min-width:2.4em; padding:.1em .4em; background:#333; border-radius:4px;}
        .loading{display:flex; align-items:center; justify-content:center; height:100vh; color:#888; font-size:1.2rem;}
        .back-link{color:#7ab; text-decoration:none; font-size:.8rem;}
        .picker{position:fixed; inset:0; background:rgba(0,0,0,.75); display:flex; align-items:center; justify-content:center; z-index:20;}
        .picker-box{background:#222; border:1px solid #555; border-radius:10px; padding:1.5rem 2rem; text-align:center; min-width:280px;}
        .picker h2{margin:0 0 1rem;}
        .picker button{display:block; width:100%; margin:.3rem 0; padding:.6rem; font-size:1rem; background:#2c2c2c; color:#eee; border:1px solid #555; border-radius:6px; cursor:pointer;}
        .picker button:hover{background:#3a3a3a;}
      </style>

      <%= cond do %>
        <% not @loaded -> %>
          <div class="loading">Cargando partida…</div>
        <% @viewer == nil -> %>
          <.picker seats={seats(%{participants: @participants})} game_id={@game_id} />
        <% true -> %>
          <.table
            game_id={@game_id}
            world={@world}
            current={@current}
            status={@status}
            round={@round}
            viewer={@viewer}
            participants={@participants}
            my_turn={@my_turn}
            my_intent={@my_intent}
            chat={@chat}
            busy={@busy}
            pending={@pending}
            show_modal={@show_modal}
            rolls={@rolls}
          />
      <% end %>
    </div>
    """
  end

  # The full table, rendered once the viewer has claimed a seat.
  defp table(assigns) do
    ~H"""
    <header class="turn-bar">
      <.turn_bar world={@world} current={@current} round={@round} status={@status} viewer={@viewer} />
      <span class="controls">
        <span class="viewer-tag">tú: {@viewer}</span>
        <.link patch={"/games/#{@game_id}"} class="ctl-btn">cambiar</.link>
        <.link navigate="/" class="ctl-btn">lobby</.link>
        <button :if={@status in [:running, :waiting]} class="ctl-btn" phx-click="pause">Pausa</button>
        <button :if={@status == :paused} class="ctl-btn" phx-click="resume">Reanudar</button>
      </span>
    </header>

    <div :if={@my_turn} class="my-turn-banner" style="grid-area:bar; margin-top:.4rem;">
      🎲 Es tu turno — ¿qué hace {@viewer}?
    </div>

    <div :for={{slot, idx} <- [tl: 0, tr: 1, bl: 2, br: 3]} :key={slot} class={"sheet slot-#{slot}"}>
      <.sheet
        card={Enum.at(sheets(@world), idx)}
        active={active_card?(@world, Enum.at(sheets(@world), idx), @current)}
        mine={@viewer != "dm" && Enum.at(sheets(@world), idx) != nil && Enum.at(sheets(@world), idx).name == @viewer}
      />
    </div>

    <section class="chat">
      <div class="log" id="log">
        <p :for={entry <- @chat} :key={entry.seq} class={"msg msg-#{entry.role}"}>
          <span class="who">{role_label(entry.role)}</span>{entry.text}
        </p>
        <p :if={@busy} class="msg msg-system thinking">el DM está pensando…</p>
      </div>
    </section>

    <div class="input-area">
      <div :if={@my_intent} class="intent-banner">
        Has declarado: «{@my_intent}»
        <button class="ctl-btn" phx-click="clear_intent">borrar</button>
        <span :if={not @my_turn} class="muted">(se resolverá en tu turno)</span>
      </div>

      <form class="input" id="player-input" phx-submit="declare">
        <input
          name="text"
          value={@pending}
          disabled={@busy}
          placeholder={placeholder(@my_turn, @busy, @current, @status)}
        />
        <button type="submit" disabled={@busy}>{if @my_turn, do: "Actuar", else: "Declarar"}</button>
      </form>
    </div>

    <.dice_modal :if={@show_modal} rolls={@rolls} />
    """
  end

  # The "who are you?" overlay, shown before a viewer claims a seat.
  defp picker(assigns) do
    ~H"""
    <div class="picker">
      <div class="picker-box">
        <h2>¿Quién eres?</h2>
        <.link :for={seat <- @seats} :key={seat} patch={"/games/#{@game_id}?as=#{seat}"}>
          <button>{if seat == "dm", do: "👁 Ver como DM", else: seat}</button>
        </.link>
        <.link navigate="/" style="margin-top:.6rem; font-size:.8rem; color:#888;">← volver al lobby</.link>
      </div>
    </div>
    """
  end

  attr :world, :any, default: nil
  attr :current, :any, default: nil
  attr :round, :integer, default: 1
  attr :status, :any, default: nil
  attr :viewer, :any, default: nil

  defp turn_bar(%{world: %World{phase: :combat} = w, current: current, round: round, status: status, viewer: viewer}) do
    assigns = %{w: w, current: current, round: round, status: status, viewer: viewer}

    ~H"""
    <span class="round">Round {@round}</span>
    <ul class="initiative">
      <li :for={name <- @w.initiative_order} :key={name} class={if controller(@w, name) == @current, do: "active", else: ""}>
        {name}
      </li>
    </ul>
    <span class="whose-turn">{turn_label(@current, @status, @viewer)}</span>
    """
  end

  defp turn_bar(%{current: current, status: status, viewer: viewer}) do
    assigns = %{current: current, status: status, viewer: viewer}

    ~H"""
    <span class="phase">Exploración</span>
    <span class="whose-turn">{turn_label(@current, @status, @viewer)}</span>
    """
  end

  attr :card, :map, default: nil
  attr :active, :boolean, default: false
  attr :mine, :boolean, default: false

  defp sheet(assigns) do
    ~H"""
    <%= if @card do %>
      <% card = @card
         pct = if card.max_hp > 0, do: max(0, card.hp) / card.max_hp * 100, else: 0
         status = if card.hp <= 0, do: " [DOWN]", else: "" %>
      <div class={"card side-#{card.side}#{if @active, do: " your-turn", else: ""}#{if @mine, do: " mine", else: ""}"}>
        <h3>
          {card.name}{status}<span :if={@mine} class="you-tag">TÚ</span>
        </h3>
        <p class="muted">{card.class} · {card.side}</p>
        <div class="hp"><div class="hp-fill" style={"width:#{pct}%"}></div></div>
        <p>HP {card.hp}/{card.max_hp} · AC {card.ac}</p>
      </div>
    <% else %>
      <div class="empty-sheet muted">— vacío —</div>
    <% end %>
    """
  end

  attr :rolls, :list, required: true
  defp dice_modal(assigns) do
    ~H"""
    <div class="modal" phx-click="dismiss_modal">
      <div class="modal-box">
        <h2>🎲 Tirada</h2>
        <ul>
          <li :for={r <- @rolls} :key={r.id}><span class="die">d{r.sides}</span> → <strong>{r.value}</strong></li>
        </ul>
        <p class="muted">(click para cerrar)</p>
      </div>
    </div>
    """
  end

  # ----------------------------------------------------------- helpers

  defp sheets(nil), do: []
  defp sheets(%World{} = w),
    do: w.characters |> Enum.sort_by(fn {n, _} -> n end) |> Enum.take(@max_sheets) |> Enum.map(&elem(&1, 1))

  defp active_card?(%World{} = w, %Character{} = c, current),
    do: controller(w, c) == current and c.hp > 0

  defp active_card?(_, _, _), do: false

  defp controller(%World{} = w, name) when is_binary(name),
    do: controller(w, Map.get(w.characters, name))

  defp controller(_w, %{side: "pc"} = c), do: c.name
  defp controller(_w, _enemy), do: "dm"

  defp role_label(:dm), do: "DM"
  defp role_label(:player), do: "Jugador"
  defp role_label(:system), do: ""

  defp turn_label(viewer, _, viewer) when is_binary(viewer), do: "¡Tu turno!"
  defp turn_label(current, :paused, _) when current != nil, do: "En pausa"
  defp turn_label("dm", _, _), do: "Turno del DM"
  defp turn_label(other, _, _) when is_binary(other), do: "Esperando a #{other}"
  defp turn_label(_, _, _), do: ""

  defp placeholder(true, _, _, _), do: "¿Qué haces?"
  defp placeholder(_, true, _, _), do: "el DM está pensando…"
  defp placeholder(_, _, _, :paused), do: "Partida en pausa"
  defp placeholder(_, _, current, _) when is_binary(current), do: "Declara tu intención (turno de #{current})…"
  defp placeholder(_, _, _, _), do: "Declara tu intención…"
end
