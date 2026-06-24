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

  # Coalesce dice that arrive within this window into one 2D tumble (an action
  # rolls several dice back-to-back). Then hold the result this long after the
  # dice settle before auto-hiding the overlay.
  @dice_debounce_ms 140
  @dice_hold_ms 2600

  @impl true
  def mount(%{"game_id" => id}, session, socket) do
    game_id = String.to_integer(id)
    user = Dragones.Accounts.get_user(session["user_id"])

    cond do
      not Phoenix.LiveView.connected?(socket) ->
        {:ok, base_assigns(socket, game_id)}

      Games.get_game(game_id) == nil ->
        {:ok, push_navigate(socket, to: "/")}

      true ->
        game = Games.get_game(game_id)
        can_access = user && Games.can_access?(game, user)
        has_open_slots = game.open_slots > 0

        cond do
          # Configuring (waiting room) — creator, participants, and potential
          # joiners all see the room. Non-participants see a hero picker.
          game.status == :configuring and (can_access or has_open_slots) ->
            Phoenix.PubSub.subscribe(Dragones.PubSub, "dragones:game:#{game_id}")

            heroes = if user, do: Dragones.Accounts.list_heroes(user), else: []
            game = Dragones.Repo.preload(game, [:participants, :characters])

            {:ok,
             assign(socket,
               game_id: game_id,
               connected: true,
               current_user: user,
               show_join: false,
               show_waiting_room: true,
               waiting_game: game,
               waiting_heroes: heroes,
               is_creator: user && game.user_id == user.id
             )}

          # Running + can access → play
          can_access ->
            Phoenix.PubSub.subscribe(Dragones.PubSub, "dragones:game:#{game_id}")
            {:ok, _pid} = Game.ensure_started(game_id)
            {:ok, assign(socket, game_id: game_id, connected: true, current_user: user, show_join: false, show_waiting_room: false)}

          # No access → go away
          true ->
            {:ok, push_navigate(socket, to: "/")}
        end
    end
  end

  # The viewer is auto-assigned: the user's own participant. The creator can
  # toggle DM view via the "DM" button (patches ?as=dm).
  @impl true
  def handle_params(_params, _url, %{assigns: %{show_waiting_room: true}} = socket),
    do: {:noreply, socket}

  def handle_params(_params, _url, %{assigns: %{show_join: true}} = socket),
    do: {:noreply, socket}

  def handle_params(params, _url, %{assigns: %{connected: true, game_id: gid}} = socket) do
    viewer_param = Map.get(params, "as")
    {:noreply, load(socket, gid, viewer_param)}
  end

  def handle_params(_params, _url, socket), do: {:noreply, socket}

  # --------------------------------------------------------------- events

  @impl true
  def handle_event("start_game", _params, socket) do
    game_id = socket.assigns.game_id
    {:ok, _} = Games.start_game(game_id)
    {:ok, _pid} = Game.ensure_started(game_id)
    Phoenix.PubSub.broadcast(Dragones.PubSub, "dragones:game:#{game_id}", {:game_updated, game_id})
    # Full reload — mount runs again with status :running, loads the table
    {:noreply, Phoenix.LiveView.push_navigate(socket, to: "/games/#{game_id}")}
  end

  @impl true
  def handle_event("join_with_hero", %{"hero_id" => hero_id}, socket) do
    user = socket.assigns.current_user
    hero = Dragones.Accounts.get_user_hero(user, hero_id)

    if hero do
      game = Games.get_game(socket.assigns.game_id)
      sheet = Dragones.Accounts.hero_sheet(hero)

      case Games.join_game(game, user, sheet) do
        {:ok, updated_game} ->
          Phoenix.PubSub.broadcast(Dragones.PubSub, "dragones:game:#{socket.assigns.game_id}", {:game_updated, socket.assigns.game_id})

          # Stay in the waiting room with refreshed data
          {:noreply,
           socket
           |> assign(show_join: false, show_waiting_room: true, waiting_game: Dragones.Repo.preload(updated_game, [:participants, :characters]))}

        {:error, _} ->
          {:noreply, assign(socket, join_error: "No se pudo unir a la partida.")}
      end
    else
      {:noreply, assign(socket, join_error: "Héroe no encontrado.")}
    end
  end

  def handle_event("toggle_auto", _params, socket) do
    viewer = socket.assigns[:viewer]
    pid = server(socket)

    cond do
      is_nil(viewer) or viewer == "dm" or is_nil(pid) ->
        {:noreply, socket}

      socket.assigns[:auto_play] ->
        :ok = Game.disable_auto_play(pid, viewer)
        {:noreply, assign(socket, auto_play: false)}

      true ->
        :ok = Game.enable_auto_play(pid, viewer)
        {:noreply, assign(socket, auto_play: true)}
    end
  end

  def handle_event("share", _params, socket) do
    url = "/games/#{socket.assigns.game_id}"
    {:noreply, push_event(socket, "copy_url", %{url: url})}
  end

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

  def handle_event("dismiss_dice", _params, socket) do
    if ref = socket.assigns[:dice_flush_ref], do: Process.cancel_timer(ref)
    if ref = socket.assigns[:dice_hide_ref], do: Process.cancel_timer(ref)

    {:noreply,
     socket
     |> assign(dice_show: false, dice_rolling: false, dice_hand: [], dice_flush_ref: nil, dice_hide_ref: nil)}
  end

  # The 2D hook reports every die finished its settle animation; reveal the
  # total and schedule auto-hide.
  def handle_event("dic_ex:settled:dice-stage", _params, socket) do
    hide_ref = Process.send_after(self(), :hide_dice, @dice_hold_ms)
    {:noreply, assign(socket, dice_rolling: false, dice_hide_ref: hide_ref)}
  end

  @impl true
  def handle_info({:game_updated, game_id}, %{assigns: %{game_id: game_id, show_waiting_room: true}} = socket) do
    # In the waiting room: check if the game started
    game = Games.get_game(game_id)

    if game.status == :running do
      # Game started! Full reload to enter the table
      {:noreply, Phoenix.LiveView.push_navigate(socket, to: "/games/#{game_id}")}
    else
      # Still waiting: refresh the roster
      {:noreply, assign(socket, waiting_game: game)}
    end
  end

  def handle_info({:game_updated, game_id}, %{assigns: %{game_id: game_id, viewer: viewer}} = socket),
    do: {:noreply, load(socket, game_id, viewer)}

  def handle_info({:dice_roll, game_id, sides, value}, %{assigns: %{game_id: game_id}} = socket) do
    # A new die landed. We don't animate immediately: the engine rolls several
    # dice per action in quick succession (attack d20, then damage dice), so we
    # debounce them into one burst that the dic_ex 2D hook tumbles together.
    hand = socket.assigns.dice_hand ++ [%{sides: sides, value: value}]

    if ref = socket.assigns[:dice_flush_ref], do: Process.cancel_timer(ref)
    if ref = socket.assigns[:dice_hide_ref], do: Process.cancel_timer(ref)

    token = socket.assigns.dice_token + 1
    flush_ref = Process.send_after(self(), {:flush_dice, token}, @dice_debounce_ms)

    {:noreply,
     socket
     |> assign(dice_hand: hand, dice_show: true, dice_token: token, dice_flush_ref: flush_ref, dice_hide_ref: nil)}
  end

  # Flush the accumulated hand to the dic_ex hook as one roll event. The token
  # guards against a cancelled-yet-already-fired timer double-pushing.
  def handle_info({:flush_dice, token}, %{assigns: %{dice_token: token}} = socket) do
    payload = dice_payload(socket.assigns.dice_hand)

    {:noreply,
     socket
     |> assign(dice_rolling: true, dice_flush_ref: nil)
     |> push_event("dic_ex:roll:dice-stage", payload)}
  end

  def handle_info({:flush_dice, _stale_token}, socket), do: {:noreply, socket}

  def handle_info(:hide_dice, socket) do
    {:noreply, assign(socket, dice_show: false, dice_hand: [], dice_hide_ref: nil)}
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
      dice_hand: [],
      dice_show: false,
      dice_rolling: false,
      dice_token: 0,
      dice_flush_ref: nil,
      dice_hide_ref: nil,
      dice_engine: "2d",
      show_join: false,
      show_waiting_room: false,
      waiting_heroes: [],
      waiting_game: nil,
      join_heroes: [],
      join_error: nil,
      auto_play: false,
      is_creator: false
    )
  end

  defp load(socket, game_id, viewer_param) do
    case Dragones.Game.Supervisor.whereis(game_id) do
      nil ->
        base_assigns(socket, game_id)

      pid ->
        snap = Game.snapshot(pid)
        user = socket.assigns[:current_user]
        game = Games.get_game(game_id)
        is_creator = user && game && game.user_id == user.id

        # Auto-assign viewer: creator can use ?as=dm for DM view; everyone else
        # gets their own participant automatically.
        viewer =
          cond do
            viewer_param == "dm" and is_creator -> "dm"
            is_binary(viewer_param) -> validate_viewer(viewer_param, snap.participants)
            user != nil -> auto_viewer(snap.participants, user.id)
            true -> nil
          end

        assign(socket,
          loaded: true,
          connected: true,
          game_id: game_id,
          viewer: viewer,
          is_creator: is_creator,
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
          dice_hand: socket.assigns[:dice_hand] || [],
          dice_show: socket.assigns[:dice_show] || false,
          dice_rolling: socket.assigns[:dice_rolling] || false,
          dice_token: socket.assigns[:dice_token] || 0,
          dice_flush_ref: socket.assigns[:dice_flush_ref] || nil,
          dice_hide_ref: socket.assigns[:dice_hide_ref] || nil,
          dice_engine: (game && game.dice_engine) || (socket.assigns[:dice_engine] || "2d"),
          auto_play: socket.assigns[:auto_play] || false
        )
    end
  end

  # Find this user's human participant → auto-assign their viewer.
  defp auto_viewer(participants, user_id) do
    participants
    |> Map.values()
    |> Enum.find(fn p -> p.user_id == user_id and p.kind == :human end)
    |> case do
      %{name: name} -> name
      nil -> nil
    end
  end

  # A valid viewer is the DM or a human participant that exists.
  defp validate_viewer("dm", _), do: "dm"

  defp validate_viewer(name, participants) when is_binary(name) do
    case Map.get(participants, name) do
      %{kind: :human} -> name
      _ -> nil
    end
  end

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
        .ctl-active{background:#3a2a1a !important;border-color:#a72 !important;color:#fc8 !important;}
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
        .you-tag{font-size:.7rem;color:#4af;font-weight:bold;margin-left:.4rem;}
        .conds{display:flex;flex-wrap:wrap;gap:.2rem;margin:.2rem 0 0;}
        .cond-badge{font-size:.65rem;padding:.08rem .3rem;border-radius:3px;background:#3a2222;border:1px solid #744;color:#faa;}
        .hp{height:8px; background:#400; border-radius:4px; margin:.3rem 0; overflow:hidden;}
        .hp-fill{height:100%; background:#3c3;}
        .modal{position:fixed; inset:0; background:rgba(0,0,0,.6); display:flex; align-items:center; justify-content:center; z-index:10;}
        .modal-box{background:#222; border:1px solid #555; border-radius:10px; padding:1.2rem 2rem; text-align:center;}
        .modal-box ul{list-style:none; padding:0; font-size:1.3rem;}
        .dice-hidden{display:none !important;}
        .dice-overlay{backdrop-filter:blur(2px);}
        .dice-modal-box{min-width:320px;}
        .dice-modal-box h2{color:#fc8; font-size:1.1rem;}
        .dice-modal-box .dicex-roller{margin:.6rem auto; width:fit-content;}
        .dice-total{font-size:2.2rem; font-weight:bold; color:#ff5; line-height:1.1; margin-top:.3rem;}
        .dice-breakdown{font-size:.9rem; color:#9ab; margin-top:.2rem;}
        .dice-rolling-text{font-size:1.1rem; color:#fc8; font-style:italic; margin-top:.4rem;}
        .loading{display:flex; align-items:center; justify-content:center; height:100vh; color:#888; font-size:1.2rem;}
        .back-link{color:#7ab; text-decoration:none; font-size:.8rem;}
        .picker{position:fixed; inset:0; background:rgba(0,0,0,.75); display:flex; align-items:center; justify-content:center; z-index:20;}
        .picker-box{background:#222; border:1px solid #555; border-radius:10px; padding:1.5rem 2rem; text-align:center; min-width:280px;}
        .picker h2{margin:0 0 1rem;}
        .picker button{display:block; width:100%; margin:.3rem 0; padding:.6rem; font-size:1rem; background:#2c2c2c; color:#eee; border:1px solid #555; border-radius:6px; cursor:pointer;}
        .picker button:hover{background:#3a3a3a;}
      </style>

      <%= cond do %>
        <% @show_join -> %>
          <.join_screen game_id={@game_id} heroes={@join_heroes} error={@join_error} />
        <% @show_waiting_room -> %>
          <.waiting_room game_id={@game_id} game={@waiting_game} is_creator={@is_creator} current_user={@current_user} waiting_heroes={@waiting_heroes} />
        <% not @loaded -> %>
          <div class="loading">Cargando partida…</div>
        <% @viewer == nil -> %>
          <div class="loading">Esperando tu turno o la acción del DM…</div>
        <% true -> %>
          <.table
            game_id={@game_id}
            world={@world}
            current={@current}
            status={@status}
            round={@round}
            viewer={@viewer}
            is_creator={@is_creator}
            auto_play={@auto_play}
            participants={@participants}
            my_turn={@my_turn}
            my_intent={@my_intent}
            chat={@chat}
            busy={@busy}
            pending={@pending}
            dice_show={@dice_show}
            dice_rolling={@dice_rolling}
            dice_hand={@dice_hand}
            dice_engine={@dice_engine}
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
        <button :if={@viewer != "dm"} class={"ctl-btn #{if @auto_play, do: "ctl-active", else: ""}"} phx-click="toggle_auto">
          {if @auto_play, do: "🤖 Auto ON", else: "🤖 Auto"}
        </button>
        <.link :if={@is_creator and @viewer != "dm"} patch={"/games/#{@game_id}?as=dm"} class="ctl-btn">👁 DM</.link>
        <.link :if={@is_creator and @viewer == "dm"} patch={"/games/#{@game_id}"} class="ctl-btn">👤 Personaje</.link>
        <button class="ctl-btn" phx-click="share">🔗 Compartir</button>
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

    <.dice_stage
      show={@dice_show}
      rolling={@dice_rolling}
      hand={@dice_hand}
      engine={@dice_engine}
    />
    """
  end

  # The waiting room: a lobby where players join, pick heroes, and the creator
  # starts when everyone is ready.
  defp waiting_room(assigns) do
    ~H"""
    <div class="wr">
      <style>
        .wr{max-width:960px;margin:0 auto;padding:1.5rem;font-family:Georgia,'Times New Roman',serif;}
        .wr-header{text-align:center;margin-bottom:1.5rem;}
        .wr-header h1{color:#fc8;font-size:1.6rem;margin-bottom:.3rem;}
        .wr-header .scene{color:#889;font-size:.85rem;font-style:italic;}
        .wr-layout{display:grid;grid-template-columns:1fr 320px;gap:1.5rem;align-items:start;}
        @media(max-width:768px){.wr-layout{grid-template-columns:1fr;}}
        .slots-area h2{color:#7ab;font-size:.8rem;text-transform:uppercase;letter-spacing:.05em;margin:0 0 .8rem;}
        .slots-circle{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:.8rem;}
        .slot-card{background:#1a1a1a;border:2px solid #333;border-radius:12px;padding:1rem;text-align:center;transition:all .2s;}
        .slot-card.ready{border-color:#474;}
        .slot-card.you{border-color:#a72;box-shadow:0 0 12px rgba(170,100,30,.2);}
        .slot-card.empty{border-style:dashed;opacity:.6;}
        .slot-card .avatar{font-size:2rem;margin-bottom:.3rem;}
        .slot-card .sname{font-weight:700;color:#eee;font-size:.9rem;}
        .slot-card .shero{color:#889;font-size:.75rem;margin-top:.1rem;}
        .slot-card .sbadge{display:inline-block;font-size:.65rem;padding:.15rem .4rem;border-radius:10px;margin-top:.4rem;}
        .sbadge-ready{background:#1a2a1a;color:#9f9;border:1px solid #474;}
        .sbadge-waiting{background:#2a2a1a;color:#fc8;border:1px solid #553;}
        .sbadge-empty{background:#222;color:#666;border:1px solid #333;}
        .hero-picker{margin-top:.8rem;padding:.6rem;background:#222;border-radius:8px;}
        .hero-picker-label{font-size:.68rem;color:#7ab;text-transform:uppercase;margin-bottom:.4rem;text-align:left;}
        .hero-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(90px,1fr));gap:.3rem;}
        .hero-btn{padding:.4rem .2rem;background:#1a1a1a;border:1px solid #333;border-radius:6px;cursor:pointer;text-align:center;font-size:.75rem;color:#ccc;transition:all .12s;}
        .hero-btn:hover{border-color:#a72;background:#3a2a1a;color:#fc8;}
        .hero-btn .hn{font-weight:600;}
        .hero-btn .hd{font-size:.65rem;color:#666;margin-top:.1rem;}
        .sidebar{display:flex;flex-direction:column;gap:1rem;}
        .panel{background:#1a1a1a;border:1px solid #333;border-radius:10px;padding:1rem;}
        .panel h3{color:#7ab;font-size:.72rem;text-transform:uppercase;letter-spacing:.05em;margin:0 0 .5rem;}
        .share-link{color:#7ab;font-size:.78rem;word-break:break-all;background:#222;padding:.4rem;border-radius:4px;margin:.3rem 0;}
        .copy-btn{width:100%;padding:.5rem;border-radius:6px;border:1px solid #444;background:#2c2c2c;color:#eee;font-size:.82rem;cursor:pointer;font-family:inherit;margin-top:.3rem;}
        .copy-btn:hover{background:#3a3a3a;}
        .start-btn{width:100%;padding:.8rem;border-radius:8px;border:1px solid #a72;background:#3a2a1a;color:#fc8;font-size:1.05rem;cursor:pointer;font-family:inherit;}
        .start-btn:hover{background:#4a3520;}
        .info-row{font-size:.75rem;color:#889;padding:.2rem 0;}
        .no-hero{color:#666;font-size:.78rem;font-style:italic;padding:.5rem;}
      </style>

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

  defp preload_participants(game) do
    Dragones.Repo.preload(game, [:participants]).participants
  end

  defp participant?(nil, _), do: false
  defp participant?(%{id: uid}, participants) do
    Enum.any?(participants, fn p -> p.user_id == uid end)
  end

  # The join screen: pick one of your heroes to join the game.
  defp join_screen(assigns) do
    ~H"""
    <div class="picker">
      <div class="picker-box" style="min-width:320px;">
        <h2>🔓 Unirse a la partida</h2>
        <p style="color:#889;font-size:.82rem;margin-bottom:.8rem;">Elige tu héroe:</p>
        <div :if={@error} style="color:#f99;font-size:.82rem;margin-bottom:.6rem;">{@error}</div>
        <%= for hero <- @heroes do %>
          <button phx-click="join_with_hero" phx-value-hero_id={hero.id}>
            {hero.name} — {String.capitalize(hero.race)} {String.capitalize(hero.class)}
          </button>
        <% end %>
        <div :if={@heroes == []} style="color:#666;font-size:.82rem;font-style:italic;">
          No tienes héroes. <a href="/heroes/new" style="color:#7ab;">Crear uno</a>
        </div>
        <.link navigate="/" style="margin-top:.8rem;font-size:.8rem;color:#888;">← volver</.link>
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
         status = if card.hp <= 0, do: " [DOWN]", else: ""
         conds = Enum.map(card.conditions || [], &cond_name/1) %>
      <div class={"card side-#{card.side}#{if @active, do: " your-turn", else: ""}#{if @mine, do: " mine", else: ""}"}>
        <h3>
          {card.name}{status}<span :if={@mine} class="you-tag">TÚ</span>
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

  attr :show, :boolean, default: false
  attr :rolling, :boolean, default: false
  attr :hand, :list, default: []
  attr :engine, :string, default: "2d"

  defp dice_stage(assigns) do
    ~H"""
    <div class={"modal dice-overlay #{unless @show, do: "dice-hidden"}"} phx-click="dismiss_dice">
      <div class="modal-box dice-modal-box">
        <h2>🎲 Tirada</h2>
        <%!-- The dic_ex hook owns this element. It is always in the DOM (toggled
             via .dice-hidden) so push_event reliably reaches a mounted hook.
             The stage child is phx-update="ignore": the hook draws the dice
             canvases and LiveView must never diff them. --%>
        <div
          id="dice-stage"
          class={"dicex-roller dicex-engine-#{@engine}"}
          phx-hook={dice_hook(@engine)}
        >
          <div id="dice-stage-canvas" class="dicex-stage" data-dicex-stage phx-update="ignore"></div>
        </div>

        <div class="dicex-result" :if={not @rolling and @hand != []}>
          <div class="dice-total">{dice_total(@hand)}</div>
          <div class="dice-breakdown">{dice_label(@hand)}</div>
        </div>
        <div class="dicex-result" :if={@rolling}>
          <div class="dice-rolling-text">tirando…</div>
        </div>

        <p class="muted">(click para cerrar)</p>
      </div>
    </div>
    """
  end

  # ----------------------------------------------------------- dice helpers

  # Picks the LiveView hook name for the configured engine. The 2D hook is
  # server-authoritative (pure theatre over Elixir's roll); the 3D hook reports
  # landed faces back. For now only 2d is exercised.
  defp dice_hook("3d"), do: "DiceRoller"
  defp dice_hook(_), do: "DiceRoller2D"

  # Builds the roll payload the dic_ex 2D/3D hooks expect: dice grouped by
  # sides, each carrying its authoritative value. The visible tumble lands on
  # exactly these values.
  defp dice_payload(hand) do
    groups =
      hand
      |> Enum.group_by(& &1.sides)
      |> Enum.map(fn {sides, dice} ->
        %{sides: sides, rolls: Enum.map(dice, &%{value: &1.value, kept: true})}
      end)

    %{expression: dice_label(hand), total: dice_total(hand), groups: groups}
  end

  defp dice_total(hand), do: Enum.sum(Enum.map(hand, & &1.value))

  # "d20 + 2d6 + ..." style label from the accumulated hand.
  defp dice_label(hand) do
    hand
    |> Enum.group_by(& &1.sides)
    |> Enum.sort_by(fn {sides, _} -> sides end)
    |> Enum.map_join(" + ", fn {sides, dice} ->
      n = length(dice)
      if n == 1, do: "d#{sides}", else: "#{n}d#{sides}"
    end)
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

  defp cond_name(%{condition: c}), do: c
  defp cond_name(%{"condition" => c}), do: c
  defp cond_name(c) when is_binary(c), do: c
  defp cond_name(_), do: "?"
end
