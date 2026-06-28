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

  # How many events each "load more log" click pulls in. Tuned so one click
  # recovers ~2-4 turns of context.
  @log_page_size 100

  @impl true
  def mount(%{"game_id" => id}, session, socket) do
    game_id = String.to_integer(id)
    user = Dragones.Accounts.get_user(session["user_id"])

    # Initialize every assign the render may touch up front. The disconnected
    # render (HTTP request) and the connected render (websocket upgrade) start
    # from independent sockets, and a fast PubSub message can land between
    # mount and handle_params — so the full default set must exist from the
    # very first moment.
    socket = base_assigns(socket, game_id)

    cond do
      not Phoenix.LiveView.connected?(socket) ->
        {:ok, socket}

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

            {:ok,
             assign(socket,
               connected: true,
               current_user: user,
               show_join: false,
               show_waiting_room: false
             )}

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

    Phoenix.PubSub.broadcast(
      Dragones.PubSub,
      "dragones:game:#{game_id}",
      {:game_updated, game_id}
    )

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
          Phoenix.PubSub.broadcast(
            Dragones.PubSub,
            "dragones:game:#{socket.assigns.game_id}",
            {:game_updated, socket.assigns.game_id}
          )

          # Stay in the waiting room with refreshed data
          {:noreply,
           socket
           |> assign(
             show_join: false,
             show_waiting_room: true,
             waiting_game: Dragones.Repo.preload(updated_game, [:participants, :characters])
           )}

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

  def handle_event("toggle_dice_engine", _params, socket) do
    if socket.assigns[:dice_rolling] do
      {:noreply, socket}
    else
      engine = if socket.assigns[:dice_engine] == "3d", do: "2d", else: "3d"
      {:noreply, assign(socket, dice_engine: engine)}
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

  # Paginate the chat timeline upward. The button sits at the top of the log
  # when `has_more_events` is true; clicking it loads the previous chunk of
  # events (those with seq < the oldest currently shown) and prepends them to
  # the rendered blocks. The `chat` assign is rebuilt so blocks regroup the
  # newly-arrived events correctly under their `:turn` headers.
  def handle_event("load_more_log", _params, socket) do
    game_id = socket.assigns.game_id
    viewer = socket.assigns[:viewer]

    case Enum.at(socket.assigns[:chat] || [], 0) do
      nil ->
        {:noreply, socket}

      first_block ->
        oldest_seq =
          first_block.events
          |> Enum.map(& &1.seq)
          |> Enum.min(fn -> nil end)

        if oldest_seq == nil or oldest_seq <= 1 do
          {:noreply, assign(socket, has_more_events: false)}
        else
          older = Dragones.Games.events_before(game_id, oldest_seq, @log_page_size)
          older_blocks = chat_blocks(older, viewer)
          still_more? = length(older) == @log_page_size

          {:noreply,
           socket
           |> assign(
             chat: older_blocks ++ socket.assigns[:chat],
             has_more_events: still_more?
           )}
        end
    end
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
     |> assign(
       dice_show: false,
       dice_rolling: false,
       dice_hand: [],
       dice_groups: [],
       dice_flush_ref: nil,
       dice_hide_ref: nil
     )}
  end

  # The 2D hook reports every die finished its settle animation; reveal the
  # total and schedule auto-hide.
  def handle_event("dic_ex:settled:" <> _stage_id, _params, socket) do
    hide_ref = Process.send_after(self(), :hide_dice, @dice_hold_ms)
    {:noreply, assign(socket, dice_rolling: false, dice_hide_ref: hide_ref)}
  end

  # The 3D hook is physics-driven and reports landed faces instead of the 2D
  # settled event. Use those landed values for the modal total so the number
  # shown matches the face the player sees on top of the rendered dice.
  def handle_event("dic_ex:landed:" <> _stage_id, %{"values" => values}, socket) do
    hide_ref = Process.send_after(self(), :hide_dice, @dice_hold_ms)

    {:noreply,
     assign(socket,
       dice_hand: apply_landed_values(socket.assigns.dice_hand, values),
       dice_rolling: false,
       dice_hide_ref: hide_ref
     )}
  end

  def handle_event("dic_ex:landed:" <> _stage_id, _params, socket) do
    hide_ref = Process.send_after(self(), :hide_dice, @dice_hold_ms)
    {:noreply, assign(socket, dice_rolling: false, dice_hide_ref: hide_ref)}
  end

  @impl true
  def handle_info(
        {:game_updated, game_id},
        %{assigns: %{game_id: game_id, show_waiting_room: true}} = socket
      ) do
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

  def handle_info(
        {:game_updated, game_id},
        %{assigns: %{game_id: game_id, viewer: viewer}} = socket
      ),
      do: {:noreply, load(socket, game_id, viewer)}

  # Token-level narration streaming: each chunk the model emits during a beat
  # is appended to the live bubble. The bubble builds word-by-word while the
  # beat is in flight; once the model's response completes, the `Events`
  # capability persists the final text as a :narration event and the next
  # `{:game_updated, _}` re-render flushes the live bubble (its text now lives
  # in the chat timeline as a real narration entry).
  def handle_info({:text_delta, game_id, turn_id, actor, chunk}, %{assigns: %{game_id: game_id}} = socket) do
    prev_turn = socket.assigns[:live_turn_id]

    # New turn or new actor → start a fresh bubble (drop the previous preview).
    {text, live_turn, live_actor} =
      cond do
        prev_turn == nil or prev_turn != turn_id ->
          {chunk, turn_id, actor}

        true ->
          {socket.assigns[:live_text] <> chunk, prev_turn, socket.assigns[:live_actor]}
      end

    {:noreply,
     socket
     |> assign(live_text: text, live_turn_id: live_turn, live_actor: live_actor)}
  end

  # A roll GROUP landed (RollLog on_close). It already carries the full labeled
  # entry — who rolled, why, dice, total, what it contested against, outcome —
  # so we open the modal ONCE per group with everything in one shot. Multiple
  # groups arriving within the debounce window (e.g. an attack's d20 then its
  # damage dice) collapse into a single tumble + a stack of labeled cards.
  def handle_info({:dice_group, game_id, entry}, %{assigns: %{game_id: game_id}} = socket) do
    # Pull the dice of THIS group into the tumble hand, and stack the labeled
    # entry into the cards list. Both reset on each new group burst after the
    # hold timer fires (see :hide_dice).
    new_hand = Enum.map(entry["dice"] || entry[:dice] || [], fn
      [s, v] -> %{sides: s, value: v}
      {s, v} -> %{sides: s, value: v}
    end)

    hand = socket.assigns.dice_hand ++ new_hand
    groups = socket.assigns.dice_groups ++ [entry]

    if ref = socket.assigns[:dice_flush_ref], do: Process.cancel_timer(ref)
    if ref = socket.assigns[:dice_hide_ref], do: Process.cancel_timer(ref)

    token = socket.assigns.dice_token + 1
    flush_ref = Process.send_after(self(), {:flush_dice, token}, @dice_debounce_ms)

    {:noreply,
     socket
     |> assign(
       dice_hand: hand,
       dice_groups: groups,
       dice_show: true,
       dice_token: token,
       dice_flush_ref: flush_ref,
       dice_hide_ref: nil
     )}
  end

  # Flush the accumulated hand to the dic_ex hook as one tumble event. The token
  # guards against a cancelled-yet-already-fired timer double-pushing. The
  # labeled cards (dice_groups) are already in assigns and render beside the
  # tumble — no second pass needed.
  def handle_info({:flush_dice, token}, %{assigns: %{dice_token: token}} = socket) do
    payload = dice_payload(socket.assigns.dice_hand)

    hide_ref = Process.send_after(self(), :hide_dice, @dice_hold_ms)

    {:noreply,
     socket
     |> assign(dice_rolling: true, dice_flush_ref: nil, dice_hide_ref: hide_ref)
     |> push_event("dic_ex:roll:#{dice_stage_id(socket.assigns.dice_engine)}", payload)}
  end

  def handle_info({:flush_dice, _stale_token}, socket), do: {:noreply, socket}

  def handle_info(:hide_dice, socket) do
    {:noreply, assign(socket, dice_show: false, dice_hand: [], dice_groups: [], dice_hide_ref: nil)}
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
      busy_actor: nil,
      live_text: "",
      live_turn_id: nil,
      live_actor: nil,
      has_more_events: false,
      busy: false,
      pending: "",
      dice_hand: [],
      dice_groups: [],
      dice_show: false,
      dice_rolling: false,
      dice_token: 0,
      dice_flush_ref: nil,
      dice_hide_ref: nil,
      dice_engine: nil,
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
        socket =
          socket
          |> assign_new(:live_text, fn -> "" end)
          |> assign_new(:live_actor, fn -> nil end)
          |> assign_new(:live_turn_id, fn -> nil end)
          |> assign_new(:has_more_events, fn -> false end)

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
          chat: chat_blocks(snap.events, viewer),
          busy: snap.status == :running,
          busy_actor: busy_actor(snap),
          # Preserve the live (streaming) bubble while the same actor's beat is
          # in flight; flush it when the beat ends (busy_actor nil OR changed).
          # The narration event persisted by the Events capability replaces it
          # in the chat timeline on the same render.
          live_text: maybe_flush_live_text(socket, busy_actor(snap)),
          live_turn_id: if(busy_actor(snap) == socket.assigns[:live_actor], do: socket.assigns[:live_turn_id], else: nil),
          live_actor: if(busy_actor(snap) == socket.assigns[:live_actor], do: socket.assigns[:live_actor], else: nil),
          has_more_events: Map.get(snap, :has_more_events, false),
          pending: "",
          dice_hand: socket.assigns[:dice_hand] || [],
          dice_groups: socket.assigns[:dice_groups] || [],
          dice_show: socket.assigns[:dice_show] || false,
          dice_rolling: socket.assigns[:dice_rolling] || false,
          dice_token: socket.assigns[:dice_token] || 0,
          dice_flush_ref: socket.assigns[:dice_flush_ref] || nil,
          dice_hide_ref: socket.assigns[:dice_hide_ref] || nil,
          dice_engine: socket.assigns[:dice_engine] || (game && game.dice_engine) || "2d",
          auto_play: viewer != nil and MapSet.member?(snap[:auto] || MapSet.new(), viewer)
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

  # When the loop is :running, snap.current is the participant whose beat is in
  # flight — drives the "X está actuando…" indicator. nil when waiting/paused.
  defp busy_actor(%{status: :running, current: current}), do: current
  defp busy_actor(_), do: nil

  # Keep the streaming bubble's text while the same actor's beat is still in
  # flight; clear it the moment the beat ends (busy_actor nil) or a different
  # actor's beat starts (so we don't show stale text from the previous turn).
  # Defensive against the first render before any streaming has happened
  # (socket.assigns may not yet carry :live_text — use [:] access).
  defp maybe_flush_live_text(socket, busy_actor) do
    live_actor = socket.assigns[:live_actor]
    live_text = socket.assigns[:live_text] || ""

    if busy_actor != nil and busy_actor == live_actor,
      do: live_text,
      else: ""
  end

  # CSS class for the turn header actor label: highlights the viewer's own turn
  # and tones down the DM's.
  defp th_actor_class(actor, viewer) do
    cond do
      actor == viewer -> "mine"
      actor == "dm" -> "dm-side"
      true -> ""
    end
  end

  # Group the timeline into per-turn blocks so the chat reads as a sequence of
  # turns (each with its header — who/round/phase — and its events inline),
  # instead of a flat list where narration, dice and actions pile up without
  # hierarchy. Events without a turn_id (the opening narration, legacy events,
  # system notes) land in a prologue block with no header.
  defp chat_blocks(events, viewer) do
    visible =
      Enum.filter(events, fn e ->
        if viewer == "dm", do: e.visible_to in ["all", "dm"], else: e.visible_to == "all"
      end)

    # Walk the visible events in order, opening a new block every time a
    # :turn marker appears. The marker carries turn_id/round/phase/actor.
    {blocks, _current} =
      Enum.reduce(visible, {[], nil}, fn e, {acc, cur} ->
        case e do
          %{type: :turn, payload: %{"kind" => "start"} = p} ->
            header = %{
              turn_id: p["turn_id"],
              actor: e.actor,
              round: p["round"],
              phase: p["phase"]
            }

            block = %{header: header, events: []}
            {acc ++ [block], block}

          _ ->
            line = %{seq: e.seq, type: e.type, actor: e.actor, role: chat_role(e), who: chat_who(e), text: chat_text(e), outcome: chat_outcome(e)}

            case cur do
              nil ->
                # No open block — prologue (e.g. the opening narration).
                prologue = %{header: nil, events: [line]}
                {acc ++ [prologue], prologue}

              %{events: evs} = block ->
                updated = %{block | events: evs ++ [line]}
                # Replace the last block in acc with the updated one.
                {Enum.drop(acc, -1) ++ [updated], updated}
            end
        end
      end)

    blocks
  end

  # The role drives the CSS class. Narration by the DM → :dm. Narration/action
  # by a non-dm actor → :pc (the bot or human PC speaking in their own voice).
  # Dice → :roll. System → :system.
  defp chat_role(%{type: :narration, actor: actor}), do: if(actor == "dm", do: :dm, else: :pc)
  defp chat_role(%{type: :dice}), do: :roll
  defp chat_role(%{type: :action, actor: actor}), do: if(actor == "dm", do: :dm, else: :pc)
  defp chat_role(%{type: :turn}), do: :turn
  defp chat_role(_), do: :system

  # The label shown in the chat for each line: the acting hero's name for player
  # actions/declarations and for a PC bot's narration. DM narration carries no
  # label — it is understood to be the DM.
  defp chat_who(%{type: :dice, actor: actor, payload: p}) do
    who = p["who"] || actor
    if who, do: "🎲 #{who}", else: "🎲"
  end

  defp chat_who(%{type: :action, actor: actor}) when actor != "dm", do: actor
  defp chat_who(%{type: :narration, actor: actor}) when actor != "dm", do: actor
  defp chat_who(_), do: ""

  defp chat_outcome(%{type: :dice, payload: p}), do: p["outcome"]
  defp chat_outcome(_), do: nil

  defp chat_text(%{type: :system, payload: p}), do: p["note"] || p[:note] || ""
  defp chat_text(%{type: :dice, payload: p}), do: format_dice_line(p)
  defp chat_text(%{payload: p}), do: p["text"] || p[:text] || ""

  # A structured roll entry → one scannable line:
  #   "<reason>: d20:14 +4 = 18 vs CA 15 → ¡ACIERTO!"
  # Payload comes back from jsonb with string keys, dice as [[sides, value]],
  # against as ["ac"|"dc", n]; handle both atom- and string-keyed forms.
  defp format_dice_line(%{} = p) do
    dice = p["dice"] || p[:dice] || []
    reason = p["reason"] || p[:reason] || "tirada"
    total = p["total"] || p[:total]

    dice_str =
      dice
      |> Enum.map(fn
        [s, v] -> "d#{s}:#{v}"
        {s, v} -> "d#{s}:#{v}"
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    dice_sum =
      dice
      |> Enum.map(fn
        [_, v] when is_number(v) -> v
        {_, v} when is_number(v) -> v
        _ -> 0
      end)
      |> Enum.sum()

    mod = if is_number(total), do: total - dice_sum, else: nil

    parts = [reason, dice_str]

    parts =
      case mod do
        n when is_number(n) and n > 0 -> parts ++ ["+#{n}"]
        n when is_number(n) and n < 0 -> parts ++ ["#{n}"]
        _ -> parts
      end

    parts = if is_number(total), do: parts ++ ["= #{total}"], else: parts
    parts = append_if(parts, format_against(p["against"] || p[:against]))
    parts = append_if(parts, outcome_line(p["outcome"] || p[:outcome]))

    parts |> Enum.reject(&(&1 in ["", nil])) |> Enum.join(" ")
  end

  defp append_if(parts, ""), do: parts
  defp append_if(parts, frag), do: parts ++ [frag]

  defp format_against(v) do
    case v do
      ["ac", n] -> "vs CA #{n}"
      ["dc", n] -> "vs DC #{n}"
      {:ac, n} -> "vs CA #{n}"
      {:dc, n} -> "vs DC #{n}"
      _ -> ""
    end
  end

  defp outcome_line(o) do
    case o do
      "hit" -> "→ ¡ACIERTO!"
      "crit" -> "→ ¡CRÍTICO!"
      "miss" -> "→ fallo"
      "success" -> "→ éxito"
      "failure" -> "→ fallo"
      "revive" -> "→ ¡revive!"
      "crit_fail" -> "→ ¡PIFIA!"
      :hit -> "→ ¡ACIERTO!"
      :crit -> "→ ¡CRÍTICO!"
      :miss -> "→ fallo"
      :success -> "→ éxito"
      :failure -> "→ fallo"
      :revive -> "→ ¡revive!"
      :crit_fail -> "→ ¡PIFIA!"
      _ -> ""
    end
  end

  defp server(%{assigns: %{game_id: game_id}}) when not is_nil(game_id),
    do: Dragones.Game.Supervisor.whereis(game_id)

  defp server(_), do: nil

  # --------------------------------------------------------------- render

  @impl true
  def render(assigns) do
    ~H"""
    <div class="game">
      <style>
        /* Height chain: body -> LiveView wrapper -> main.game-layout -> .game.
           Only .game-log scrolls; every parent clips and passes a bounded height. */
        .game { position:relative; flex:1 1 0; width:100%; min-height:0; overflow:hidden; display:flex; flex-direction:column; gap:.6rem; padding:.6rem; box-sizing:border-box; }
        .game-topbar { flex:0 0 auto; min-height:0; }
        .turn-bar{display:flex; align-items:center; gap:1rem; background:#1f1f1f; border:1px solid #333; border-radius:6px; padding:.4rem .8rem; font-size:.9rem; min-width:0;}
        .game-body { flex:1 1 0; min-height:0; display:grid; grid-template-columns:220px minmax(0,1fr) 220px; gap:.6rem; overflow:hidden; }
        .game-rail { min-height:0; display:flex; flex-direction:column; gap:.6rem; overflow:hidden; }
        .game-center { min-width:0; min-height:0; display:flex; flex-direction:column; gap:.4rem; overflow:hidden; }
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
        .toast-stack{position:absolute; top:3.4rem; left:50%; transform:translateX(-50%); z-index:5; display:flex; flex-direction:column; align-items:center; gap:.4rem; width:min(720px, calc(100% - 2rem)); pointer-events:none;}
        .game-toast{max-width:100%; background:rgba(58,42,10,.96); border:1px solid #ea0; color:#ff5; padding:.45rem .9rem; border-radius:999px; font-weight:bold; box-shadow:0 8px 24px rgba(0,0,0,.35); pointer-events:auto;}
        .my-turn-banner{animation:pulse 1.5s infinite;}
        @keyframes pulse{0%,100%{opacity:1;}50%{opacity:.6;}}
        .intent-banner{display:flex; align-items:center; gap:.6rem; background:rgba(26,42,58,.96); border-color:#4af; color:#cdf; font-size:.85rem;}
        .game-input{display:flex; gap:.4rem;}
        .game-input-area{flex:0 0 auto; min-height:0;}
        .game-input input{flex:1 1 auto; min-width:0; padding:.5rem; font-size:1rem; background:#222; color:#eee; border:1px solid #444; border-radius:4px;}
        .game-input button{flex:0 0 auto; padding:.5rem 1.2rem; font-size:1rem; background:#2c2c2c; color:#eee; border:1px solid #555; border-radius:4px; cursor:pointer;}
        .game-input button:hover:not(:disabled){background:#3a3a3a;}
        .game-log{flex:1 1 0; min-height:0; background:#111; border:1px solid #333; border-radius:6px; padding:.8rem; font-size:.95rem; line-height:1.4; overflow:auto;}
        .load-more-btn{display:block; width:100%; margin:0 0 .8rem; padding:.4rem; font-size:.78rem; color:#7ab; background:#1a1a1a; border:1px dashed #333; border-radius:4px; cursor:pointer; font-family:inherit;}
        .load-more-btn:hover{color:#cdf; background:#222; border-color:#555;}
        .turn-block{margin:0 0 .9rem; padding:0; border-left:2px solid #2a2a2a; padding-left:.6rem;}
        .turn-block:first-child{margin-top:0;}
        .turn-head{margin:0 0 .4rem; padding-bottom:.2rem; border-bottom:1px solid #222;}
        .th-line{display:flex; align-items:baseline; gap:.4rem; flex-wrap:wrap; font-size:.78rem; color:#9ab;}
        .th-round{font-weight:bold; color:#fb0; font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:.74rem;}
        .th-sep{color:#444;}
        .th-actor{font-weight:bold; color:#cdf;}
        .th-actor.dm-side{color:#b08a3e;}
        .th-actor.mine{color:#4fbf90;}
        .th-you{font-size:.62rem; padding:.05rem .3rem; margin-left:.3rem; border-radius:3px; background:#1a3a2a; color:#7e7; border:1px solid #2f6a4a;}
        .th-phase{font-size:.7rem; color:#a55; padding:.05rem .35rem; border-radius:3px; background:#2a1a1a; border:1px solid #422;}
        .msg{margin:0 0 .6rem;} .msg .who{display:inline-block; margin-right:.4rem; font-weight:bold; color:#7ab;}
        /* The chip for a player's chat-input action: discrete icon-only by
           default, full text on hover as a tooltip. Never inline in the
           timeline — it's the player's intent, not narration. */
        .player-declared-chip{display:inline-flex; align-items:center; gap:.25rem; font-size:.78rem; color:#666; background:transparent; padding:.05rem .25rem; border-radius:4px; cursor:help; opacity:.5;}
        .player-declared-chip:hover{opacity:1; background:#1a1a1a;}
        .msg-dm{color:#e8dcc4;} .msg-dm .who{color:#b08a3e;}
        .msg-pc{color:#ffe9b0; border-left:2px solid #a55; padding-left:.5rem; margin-left:.2rem; font-style:italic;} .msg-pc .who{color:#fb0; font-style:normal; font-weight:bold;}
        .msg-roll{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:.86rem; color:#9cdec8; background:#11221c; border:1px solid #1f4a39; border-radius:4px; padding:.25rem .5rem; margin:.15rem 0;} .msg-roll .who{color:#4fbf90; font-family:Georgia,serif; font-size:.78rem;}
        .msg-roll.roll-hit,.msg-roll.roll-crit,.msg-roll.roll-success,.msg-roll.roll-revive{border-color:#2f6a4a; color:#bdf0d4;}
        .msg-roll.roll-miss,.msg-roll.roll-failure,.msg-roll.roll-crit_fail{border-color:#5a2a2a; color:#f0bdb0;}
        .msg-system{color:#777; font-style:italic;}
        .msg-system.thinking::after{content:" ⋯"; animation:dots 1.2s infinite;}
        @keyframes dots{0%{opacity:.3;}50%{opacity:1;}100%{opacity:.3;}}
        .live-streaming{position:relative; opacity:.92;}
        .live-streaming .cursor{display:inline-block; color:#fc8; animation:blink 1s steps(2) infinite; margin-left:1px;}
        @keyframes blink{0%,50%{opacity:1;}51%,100%{opacity:0;}}
        .sheet{flex:1 1 0; min-height:0; display:flex;}
        .card,.empty-sheet{flex:1 1 auto; min-height:0; overflow:hidden; background:#222; border:1px solid #3a3a3a; border-radius:8px; padding:.6rem;}
        .card h3{margin:0; font-size:1rem;} .card p{margin:.2rem 0; font-size:.85rem;}
        .side-enemy{border-color:#5a2222;} .card.your-turn{box-shadow:0 0 0 2px #bb0 inset;}
        .card.mine{box-shadow:0 0 0 2px #4af inset;}
        .you-tag{font-size:.7rem;color:#4af;font-weight:bold;margin-left:.4rem;}
        .conds{display:flex;flex-wrap:wrap;gap:.2rem;margin:.2rem 0 0;}
        .cond-badge{font-size:.65rem;padding:.08rem .3rem;border-radius:3px;background:#3a2222;border:1px solid #744;color:#faa;}
        .hp{height:8px; background:#400; border-radius:4px; margin:.3rem 0; overflow:hidden;}
        .hp-fill{height:100%; background:#3c3;}
        .combat-tracker{flex:1 1 0; min-height:0; display:flex; flex-direction:column; background:#1a1a1a; border:1px solid #3a2222; border-radius:8px; overflow:hidden;}
        .ct-header{display:flex; align-items:center; gap:.4rem; padding:.45rem .6rem; background:#2a1818; border-bottom:1px solid #3a2222; color:#fc8; font-weight:bold; font-size:.85rem;}
        .ct-header .ct-round{margin-left:auto; color:#fb0; font-size:.78rem;}
        .ct-list{flex:1 1 auto; min-height:0; overflow:auto; padding:.4rem; display:flex; flex-direction:column; gap:.35rem;}
        .combatant{display:flex; gap:.4rem; padding:.4rem; background:#222; border:1px solid #333; border-radius:6px;}
        .combatant.acting{border-color:#bb0; box-shadow:0 0 0 2px rgba(187,170,0,.3);}
        .combatant.mine{box-shadow:0 0 0 2px #4af inset;}
        .combatant.side-enemy{background:#2a1a1a; border-color:#5a2222;}
        .ct-mark{color:#ff5; width:.7rem; flex:0 0 auto; font-size:.8rem;}
        .ct-body{flex:1 1 auto; min-width:0;}
        .ct-name{font-weight:bold; font-size:.88rem;}
        .ct-down{color:#f55;}
        .ct-stats{font-size:.72rem; color:#9ab;}
        .combatant .hp{margin:.2rem 0;}
        .modal{position:fixed; inset:0; background:rgba(0,0,0,.6); display:flex; align-items:center; justify-content:center; z-index:10;}
        .modal-box{background:#222; border:1px solid #555; border-radius:10px; padding:1.2rem 2rem; text-align:center;}
        .modal-box ul{list-style:none; padding:0; font-size:1.3rem;}
        .dice-hidden{display:none !important;}
        .dice-overlay{backdrop-filter:blur(2px);}
        .dice-modal-box{min-width:320px;}
        .dice-modal-box h2{color:#fc8; font-size:1.1rem;}
        .dice-modal-box .dicex-roller{margin:.6rem auto;}
        .dice-modal-box .dicex-engine-3d{width:min(460px,80vw);--dicex-stage-h:320px;}
        .dice-modal-box .dicex-engine-2d{width:fit-content;min-width:220px;--dicex-stage-h:200px;}
        .dice-results{display:flex;flex-direction:column;align-items:center;gap:.55rem;margin-top:.4rem;}
        .dice-results-title{font-size:.75rem;color:#9ab;text-transform:uppercase;letter-spacing:.08em;}
        .dice-result-list{display:flex;flex-wrap:wrap;justify-content:center;gap:.45rem;max-width:min(440px,76vw);}
        .die-result{display:flex;align-items:center;gap:.35rem;background:#171717;border:1px solid #444;border-radius:999px;padding:.28rem .65rem;}
        .die-kind{font-size:.78rem;color:#9ab;}
        .die-value{font-size:1.25rem;font-weight:bold;color:#ff5;line-height:1;}
        .dice-rolling-text{font-size:1.1rem; color:#fc8; font-style:italic; margin-top:.4rem;}
        .dice-groups{display:flex;flex-direction:column;gap:.5rem;margin-top:.5rem;width:100%;max-width:min(440px,80vw);margin-left:auto;margin-right:auto;}
        .dice-group{background:#161616;border:1px solid #3a3a3a;border-left:4px solid #777;border-radius:8px;padding:.5rem .7rem;text-align:left;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;}
        .dice-group.dg-win{border-left-color:#3c3;color:#cfe;}
        .dice-group.dg-lose{border-left-color:#c33;color:#fdc;}
        .dice-group.dg-neutral{color:#cbd;}
        .dg-head{display:flex;justify-content:space-between;gap:.6rem;align-items:baseline;margin-bottom:.2rem;font-family:Georgia,serif;}
        .dg-who{font-weight:bold;color:#fc8;font-size:.9rem;}
        .dg-reason{font-size:.78rem;color:#9ab;font-style:italic;}
        .dg-line{font-size:.92rem;color:#e8e8e8;}
        .dg-against{color:#9ab;margin-left:.3rem;}
        .dg-outcome{margin-top:.25rem;font-weight:bold;font-size:.95rem;font-family:Georgia,serif;}
        .dg-win .dg-outcome{color:#7e7;}
        .dg-lose .dg-outcome{color:#f99;}
        .loading{flex:1 1 auto; display:flex; align-items:center; justify-content:center; color:#888; font-size:1.2rem;}
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
            busy_actor={@busy_actor}
            live_text={@live_text}
            live_actor={@live_actor}
            has_more_events={@has_more_events}
            pending={@pending}
            dice_show={@dice_show}
            dice_rolling={@dice_rolling}
            dice_hand={@dice_hand}
            dice_groups={@dice_groups}
            dice_engine={@dice_engine}
          />
      <% end %>
    </div>
    """
  end

  # The full table, rendered once the viewer has claimed a seat.
  defp table(assigns) do
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
          <button :if={@status in [:running, :waiting]} class="ctl-btn" phx-click="pause">Pausa</button>
          <button :if={@status == :paused} class="ctl-btn" phx-click="resume">Reanudar</button>
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
              <span class={"th-actor #{th_actor_class(block.header.actor, @viewer)}"}>
                {if block.header.actor == "dm", do: "Turno del DM", else: "Turno de #{block.header.actor}"}
                <span :if={block.header.actor == @viewer} class="th-you">TÚ</span>
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
              <span :if={entry.who != ""} class="who">{entry.who}</span>{entry.text}
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
          <span :if={@live_actor != "dm" and @live_actor != nil} class="who">{@live_actor}</span>{@live_text}<span class="cursor">▍</span>
        </p>
      </div>
      <div class="game-input-area">
        <form class="game-input" id="player-input" phx-submit="declare">
          <input
            name="text"
            value={@pending}
            disabled={@busy}
            placeholder={placeholder(@my_turn, @busy, @current, @status)}
          />
          <button type="submit" disabled={@busy}>{if @my_turn, do: "Actuar", else: "Declarar"}</button>
        </form>
      </div>
    </section>

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

    <.dice_stage
      show={@dice_show}
      rolling={@dice_rolling}
      hand={@dice_hand}
      groups={@dice_groups}
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

  attr(:world, :any, default: nil)
  attr(:current, :any, default: nil)
  attr(:round, :integer, default: 1)
  attr(:status, :any, default: nil)
  attr(:viewer, :any, default: nil)

  defp turn_bar(%{
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

  attr(:card, :map, default: nil)
  attr(:active, :boolean, default: false)
  attr(:mine, :boolean, default: false)

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

  # A scrollable initiative tracker shown in the left rail during combat: every
  # combatant in turn order with an HP bar, AC, conditions and a clear marker on
  # whoever is acting right now.
  attr(:world, :any, required: true)
  attr(:current, :any, default: nil)
  attr(:round, :integer, default: 1)
  attr(:viewer, :any, default: nil)

  defp combat_tracker(assigns) do
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

  defp combatant(assigns) do
    c = Map.get(assigns.world.characters, assigns.name)
    acting = controller(assigns.world, assigns.name) == assigns.current
    pct = if c && c.max_hp > 0, do: max(0, c.hp) / c.max_hp * 100, else: 0
    conds = if c, do: Enum.map(c.conditions || [], &cond_name/1), else: []

    assigns =
      assign(assigns, c: c, acting: acting, pct: pct, down: c && c.hp <= 0, conds: conds)

    ~H"""
    <div class={"combatant side-#{(@c && @c.side) || "pc"}#{if @acting, do: " acting", else: ""}#{if @name == @viewer, do: " mine", else: ""}"}>
      <span class="ct-mark">{if @acting, do: "▶", else: ""}</span>
      <div class="ct-body">
        <div class="ct-name">
          {@name}<span :if={@name == @viewer} class="you-tag">TÚ</span><span :if={@down} class="ct-down"> ✖</span>
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

  defp detail_sheet(assigns) do
    ~H"""
    <%= if @card do %>
      <% card = @card
         pct = if card.max_hp > 0, do: max(0, card.hp) / card.max_hp * 100, else: 0
         conds = Enum.map(card.conditions || [], &cond_name/1)
         weapons = Enum.map(card.weapons || [], & &1.name)
         spells = Enum.map(card.spells || [], & &1.name) %>
      <div class="sheet">
        <div class="card mine">
          <h3>{card.name}<span class="you-tag">TÚ</span></h3>
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

  attr(:show, :boolean, default: false)
  attr(:rolling, :boolean, default: false)
  attr(:hand, :list, default: [])
  attr(:groups, :list, default: [])
  attr(:engine, :string, default: "2d")

  defp dice_stage(assigns) do
    assigns = assign(assigns, :stage_id, dice_stage_id(assigns.engine))

    ~H"""
    <div class={"modal dice-overlay #{unless @show, do: "dice-hidden"}"} phx-click="dismiss_dice">
      <div class="modal-box dice-modal-box">
        <h2>🎲 Tirada</h2>
        <%!-- The dic_ex hook owns this element. It is always in the DOM (toggled
             via .dice-hidden) so push_event reliably reaches a mounted hook.
             The stage child is phx-update="ignore": the hook draws the dice
             canvases and LiveView must never diff them. --%>
        <div
          id={@stage_id}
          class={"dicex-roller dicex-engine-#{@engine}"}
          phx-hook={dice_hook(@engine)}
        >
          <div id={"#{@stage_id}-canvas"} class="dicex-stage" data-dicex-stage phx-update="ignore"></div>
        </div>

        <div :if={not @rolling and @groups != []} class="dice-groups">
          <.dice_group_card :for={{g, i} <- Enum.with_index(@groups)} :key={i} g={g} />
        </div>
        <div :if={not @rolling and @groups == [] and @hand != []} class="dicex-result dice-results">
          <div class="dice-results-title">Resultados</div>
          <div class="dice-result-list">
            <div :for={die <- dice_entries(@hand)} :key={die.index} class="die-result">
              <span class="die-kind">{die.label}</span>
              <span class="die-value">{die.value}</span>
            </div>
          </div>
        </div>
        <div :if={@rolling}>
          <div class="dice-rolling-text">tirando…</div>
        </div>

        <p class="muted">(click para cerrar)</p>
      </div>
    </div>
    """
  end

  # One roll group as a labeled, comparison-aware card: who rolled, why, the
  # dice + modifier + total, and — for contests — the opposing side (AC/DC) with
  # the outcome colored. This is what makes "what was rolled and why it mattered"
  # legible at a glance.
  attr(:g, :map, required: true)

  defp dice_group_card(assigns) do
    assigns =
      assign(assigns, :outcome_css, outcome_css(assigns.g[:outcome] || assigns.g["outcome"]))

    ~H"""
    <div class={"dice-group #{@outcome_css}"}>
      <div class="dg-head">
        <span class="dg-who">{(@g[:who] || @g["who"] || "—")}</span>
        <span class="dg-reason">{(@g[:reason] || @g["reason"] || "")}</span>
      </div>
      <div class="dg-line">
        <span class="dg-dice">{format_group_dice(@g)}</span>
        <span class="dg-against">{format_group_against(@g)}</span>
      </div>
      <div class="dg-outcome">{outcome_group_label(@g[:outcome] || @g["outcome"])}</div>
    </div>
    """
  end

  defp format_group_dice(g) do
    dice = g[:dice] || g["dice"] || []
    total = g[:total] || g["total"]

    dice_str =
      dice
      |> Enum.map(fn
        [s, v] -> "d#{s}:#{v}"
        {s, v} -> "d#{s}:#{v}"
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    sum = dice |> Enum.map(fn [_, v] -> v; {_, v} -> v; _ -> 0 end) |> Enum.sum()
    mod = if is_number(total), do: total - sum, else: nil

    mod_str =
      cond do
        mod == nil -> ""
        mod > 0 -> " +#{mod}"
        mod < 0 -> " #{mod}"
        true -> ""
      end

    total_str = if is_number(total), do: " = #{total}", else: ""
    "#{dice_str}#{mod_str}#{total_str}"
  end

  defp format_group_against(g) do
    case g[:against] || g["against"] do
      ["ac", n] -> " vs CA #{n}"
      ["dc", n] -> " vs DC #{n}"
      {:ac, n} -> " vs CA #{n}"
      {:dc, n} -> " vs DC #{n}"
      _ -> ""
    end
  end

  defp outcome_css(o) do
    case o do
      x when x in [:hit, "hit", :crit, "crit", :success, "success", :revive, "revive"] -> "dg-win"
      x when x in [:miss, "miss", :failure, "failure", :crit_fail, "crit_fail"] -> "dg-lose"
      _ -> "dg-neutral"
    end
  end

  defp outcome_group_label(o) do
    case o do
      :hit -> "¡Acierto!"
      "hit" -> "¡Acierto!"
      :crit -> "¡Crítico!"
      "crit" -> "¡Crítico!"
      :miss -> "Fallo"
      "miss" -> "Fallo"
      :success -> "Éxito"
      "success" -> "Éxito"
      :failure -> "Fallo"
      "failure" -> "Fallo"
      :revive -> "¡Revive!"
      "revive" -> "¡Revive!"
      :crit_fail -> "¡Pifia! (2 fallos)"
      "crit_fail" -> "¡Pifia! (2 fallos)"
      _ -> ""
    end
  end

  # ----------------------------------------------------------- dice helpers

  # Picks the LiveView hook name for the configured engine. The 2D hook is
  # server-authoritative theatre; the 3D hook is physics-driven and reports
  # landed faces back via dic_ex:landed:*.
  defp dice_hook("3d"), do: "DiceRoller"
  defp dice_hook(_), do: "DiceRoller2D"

  defp dice_stage_id("3d"), do: "dice-stage-3d"
  defp dice_stage_id(_), do: "dice-stage-2d"

  # Builds the roll payload the dic_ex hooks expect: dice grouped by sides, each
  # carrying the server-authoritative value used by 2D and by the final result.
  defp dice_payload(hand) do
    groups =
      hand
      |> Enum.group_by(& &1.sides)
      |> Enum.map(fn {sides, dice} ->
        %{sides: sides, rolls: Enum.map(dice, &%{value: &1.value, kept: true})}
      end)

    %{expression: dice_label(hand), total: dice_total(hand), groups: groups}
  end

  defp dice_entries(hand) do
    hand
    |> Enum.with_index(1)
    |> Enum.map(fn {%{sides: sides, value: value}, index} ->
      %{index: index, label: "d#{sides}", value: value}
    end)
  end

  defp dice_total(hand), do: Enum.sum(Enum.map(hand, & &1.value))

  defp apply_landed_values(hand, values) when is_list(hand) and is_list(values) do
    landed = Enum.map(values, &landed_value/1)

    valid? =
      length(hand) == length(landed) and
        Enum.all?(Enum.zip(hand, landed), fn
          {%{sides: sides}, value} when is_integer(value) -> value >= 1 and value <= sides
          _ -> false
        end)

    if valid? do
      hand
      |> Enum.zip(landed)
      |> Enum.map(fn {die, value} -> %{die | value: value} end)
    else
      hand
    end
  end

  defp apply_landed_values(hand, _values), do: hand

  defp landed_value(value) when is_integer(value), do: value
  defp landed_value(value) when is_float(value), do: round(value)

  defp landed_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp landed_value(_value), do: nil

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
    do:
      w.characters
      |> Enum.sort_by(fn {n, _} -> n end)
      |> Enum.take(@max_sheets)
      |> Enum.map(&elem(&1, 1))

  defp active_card?(%World{} = w, %Character{} = c, current),
    do: controller(w, c) == current and c.hp > 0

  defp active_card?(_, _, _), do: false

  defp controller(%World{} = w, name) when is_binary(name),
    do: controller(w, Map.get(w.characters, name))

  defp controller(_w, %{side: "pc"} = c), do: c.name
  defp controller(_w, _enemy), do: "dm"

  defp turn_label(viewer, _, viewer) when is_binary(viewer), do: "¡Tu turno!"
  defp turn_label(current, :paused, _) when current != nil, do: "En pausa"
  defp turn_label("dm", _, _), do: "Turno del DM"
  defp turn_label(other, _, _) when is_binary(other), do: "Esperando a #{other}"
  defp turn_label(_, _, _), do: ""

  defp placeholder(true, _, _, _), do: "¿Qué haces?"
  defp placeholder(_, true, _, _), do: "el DM está pensando…"
  defp placeholder(_, _, _, :paused), do: "Partida en pausa"

  defp placeholder(_, _, current, _) when is_binary(current),
    do: "Declara tu intención (turno de #{current})…"

  defp placeholder(_, _, _, _), do: "Declara tu intención…"

  defp cond_name(%{condition: c}), do: c
  defp cond_name(%{"condition" => c}), do: c
  defp cond_name(c) when is_binary(c), do: c
  defp cond_name(_), do: "?"
end
