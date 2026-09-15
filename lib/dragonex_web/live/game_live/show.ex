defmodule DragonexWeb.GameLive.Show do
  @moduledoc """
  The game table — a thin **view + input** over a `Dragonex.Game` process.

  It opens a partida by `game_id` (resuming it from Postgres), subscribes to its
  `Dragonex.PubSub` updates, and renders the Game's snapshot. Each viewer
  **claims a participant** (`?as=<name>` or the picker overlay), so several humans
  can share a partida: the input is gated to the viewer's own turn, their sheet is
  marked, and a banner calls "Es tu turno". The Game owns the loop/rules/persistence
  and enforces server-side that `declare/3` only resolves the current human's turn.

  The heavy view code lives apart: the timeline view-model in
  `DragonexWeb.GameLive.Chat`, the dice overlay FSM in `DragonexWeb.GameLive.Dice`,
  the Ajustes de IA modal in `DragonexWeb.GameLive.Settings` and the markup in
  `DragonexWeb.GameLive.Components`.
  """

  use Phoenix.LiveView, layout: {DragonexWeb.Layouts, :app}

  alias Dragonex.{Game, Games}
  alias DragonexWeb.GameLive.{Chat, Dice, Settings, Snapshot}
  import DragonexWeb.GameLive.Components

  # How many events each "load more log" click pulls in. Tuned so one click
  # recovers ~2-4 turns of context.
  @log_page_size 100
  # Hard cap on how many turn-blocks the LiveView keeps rendered client-side.
  # Prevents unbounded memory/render growth when a user clicks "load more"
  # repeatedly; the oldest tail is dropped past this limit.
  @max_chat_blocks 400

  @impl true
  def mount(%{"game_id" => id}, _session, socket) do
    game_id = String.to_integer(id)
    user = socket.assigns.current_user

    # Initialize every assign the render may touch up front. The disconnected
    # render (HTTP request) and the connected render (websocket upgrade) start
    # from independent sockets, and a fast PubSub message can land between
    # mount and handle_params — so the full default set must exist from the
    # very first moment.
    socket = Snapshot.base_assigns(socket, game_id)

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
            Phoenix.PubSub.subscribe(Dragonex.PubSub, "dragonex:game:#{game_id}")

            heroes = if user, do: Dragonex.Accounts.list_heroes(user), else: []

            {:ok,
             assign(socket,
               connected: true,
               current_user: user,
               show_waiting_room: true,
               waiting_game: game,
               waiting_heroes: heroes,
               is_creator: user && game.user_id == user.id
             )}

          # Running + can access → play
          can_access ->
            Phoenix.PubSub.subscribe(Dragonex.PubSub, "dragonex:game:#{game_id}")
            {:ok, _pid} = Game.ensure_started(game_id)

            {:ok,
             assign(socket,
               connected: true,
               current_user: user,
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

  def handle_params(params, _url, %{assigns: %{connected: true, game_id: gid}} = socket) do
    viewer_param = Map.get(params, "as")
    {:noreply, load(socket, gid, viewer_param)}
  end

  def handle_params(_params, _url, socket), do: {:noreply, socket}

  # --------------------------------------------------------------- events

  @impl true
  def handle_event("start_game", _params, socket) do
    # Privileged: only the partida's creator may flip it to running. The button
    # is UI-gated, but a forged phx-click must not bypass the check.
    if creator?(socket) do
      game_id = socket.assigns.game_id
      {:ok, _} = Games.start_game(game_id)
      {:ok, _pid} = Game.ensure_started(game_id)

      Phoenix.PubSub.broadcast(
        Dragonex.PubSub,
        "dragonex:game:#{game_id}",
        {:game_updated, game_id}
      )

      # Full reload — mount runs again with status :running, loads the table
      {:noreply, Phoenix.LiveView.push_navigate(socket, to: "/games/#{game_id}")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("join_with_hero", %{"hero_id" => hero_id}, socket) do
    user = socket.assigns.current_user
    hero = Dragonex.Accounts.get_user_hero(user, hero_id)

    if hero do
      game = Games.get_game(socket.assigns.game_id)
      sheet = Dragonex.Accounts.hero_sheet(hero)

      case Games.join_game(game, user, sheet, hero_id: hero.id) do
        {:ok, updated_game} ->
          Phoenix.PubSub.broadcast(
            Dragonex.PubSub,
            "dragonex:game:#{socket.assigns.game_id}",
            {:game_updated, socket.assigns.game_id}
          )

          # Stay in the waiting room with refreshed data
          {:noreply,
           socket
           |> assign(show_waiting_room: true, waiting_game: updated_game)}

        {:error, :already_joined} ->
          {:noreply, assign(socket, join_error: "Ya estás en esta partida.")}

        {:error, :already_started} ->
          {:noreply, assign(socket, join_error: "La partida ya ha empezado.")}

        {:error, :no_open_slots} ->
          {:noreply, assign(socket, join_error: "La partida no tiene plazas libres.")}

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

  def handle_event("draft", %{"text" => text}, socket) do
    {:noreply, assign(socket, pending: text)}
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
          older = Dragonex.Games.events_before(game_id, oldest_seq, @log_page_size)
          older_blocks = Chat.blocks(older, viewer)
          still_more? = length(older) == @log_page_size

          # Cap the in-memory chat so a user clicking "load more" a hundred times
          # can't grow the assign without bound (each block carries its events).
          # When we exceed the cap, drop the OLDEST blocks at the tail — the user
          # is paging up, so the freshly loaded top is what matters.
          merged = older_blocks ++ socket.assigns[:chat]

          merged =
            if length(merged) > @max_chat_blocks do
              Enum.take(merged, @max_chat_blocks)
            else
              merged
            end

          {:noreply,
           socket
           |> assign(
             chat: merged,
             has_more_events: still_more?
           )}
        end
    end
  end

  def handle_event("pause", _params, socket) do
    # Only the creator may pause/resume the partida loop.
    if creator?(socket) do
      if pid = server(socket), do: _ = Game.pause(pid)
    end

    {:noreply, socket}
  end

  def handle_event("resume", _params, socket) do
    if creator?(socket) do
      if pid = server(socket), do: _ = Game.resume(pid)
    end

    {:noreply, socket}
  end

  # ------------------------------------------------- dice events (Dice FSM)

  def handle_event("dismiss_dice", params, socket), do: Dice.dismiss(params, socket)

  def handle_event("dic_ex:settled:" <> _stage_id, params, socket),
    do: Dice.settled(params, socket)

  def handle_event("dic_ex:landed:" <> _stage_id, params, socket), do: Dice.landed(params, socket)

  # ------------------------------------------------------ settings modal

  # Events owned by the Settings module (delegated below).
  @settings_events ~w(open_settings close_settings settings_select_provider
                      settings_select_model settings_custom_model
                      settings_set_reasoning settings_refresh_models settings_apply)

  def handle_event(event, params, socket) when event in @settings_events,
    do: Settings.handle_event(event, params, socket)

  # --------------------------------------------------------------- info

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
  def handle_info(
        {:text_delta, game_id, turn_id, actor, chunk},
        %{assigns: %{game_id: game_id}} = socket
      ) do
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

  def handle_info({:dice_group, game_id, entry}, %{assigns: %{game_id: game_id}} = socket),
    do: Dice.group_landed(socket, entry)

  def handle_info({:flush_dice, token}, socket), do: Dice.flush(socket, token)

  def handle_info(:hide_dice, socket), do: Dice.hide(socket)

  def handle_info({:settings_models, _, _} = msg, socket), do: Settings.handle_info(msg, socket)

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --------------------------------------------------------------- load

  defp load(socket, game_id, viewer_param), do: Snapshot.load(socket, game_id, viewer_param)

  defp server(%{assigns: %{game_id: game_id}}) when not is_nil(game_id),
    do: Dragonex.Game.Supervisor.whereis(game_id)

  defp server(_), do: nil

  # Server-side ownership guard for privileged actions (start/pause/resume/
  # settings). The buttons are UI-gated by @is_creator, but a forged phx-click
  # must be rejected here rather than trusted.
  defp creator?(%{assigns: assigns}), do: assigns[:is_creator] == true

  # --------------------------------------------------------------- render

  @impl true
  def render(assigns) do
    ~H"""
    <div class="game">

      <%= cond do %>
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

      <Settings.modal
        show={@show_settings}
        providers={@settings_providers}
        provider={@settings_provider}
        models={@settings_models}
        models_status={@settings_models_status}
        model={@settings_model}
        custom_model={@settings_custom_model}
        reasoning={@settings_reasoning}
      />
    </div>
    """
  end
end
