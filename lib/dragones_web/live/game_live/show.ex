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

  alias Dragones.{Character, Game, Games, Heroes.Progression, World}
  alias DragonesWeb.GameLive.RollFormat
  import DragonesWeb.GameLive.Components

  @max_sheets 4

  # Coalesce dice that arrive within this window into one 2D tumble (an action
  # rolls several dice back-to-back). Then hold the result this long after the
  # dice settle before auto-hiding the overlay.
  @dice_debounce_ms 140
  @dice_hold_ms 2600

  # How many events each "load more log" click pulls in. Tuned so one click
  # recovers ~2-4 turns of context.
  @log_page_size 100
  # Hard cap on how many turn-blocks the LiveView keeps rendered client-side.
  # Prevents unbounded memory/render growth when a user clicks "load more"
  # repeatedly; the oldest tail is dropped past this limit.
  @max_chat_blocks 400

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

      case Games.join_game(game, user, sheet, hero_id: hero.id) do
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
    if pid = server(socket), do: _ = Game.pause(pid)
    {:noreply, socket}
  end

  def handle_event("resume", _params, socket) do
    if pid = server(socket), do: _ = Game.resume(pid)
    {:noreply, socket}
  end

  # ----------------------------------------------------------- Ajustes de IA
  #
  # The gear button (creator-only) opens a modal to swap provider / DM model /
  # reasoning effort at runtime. The selection is written to Dragones.ModelConfig
  # and applied by restarting the Game process, which rehydrates from Postgres
  # with the new model wired into the DM agent.

  def handle_event("open_settings", _params, socket) do
    provider = Dragones.Models.provider()
    model = Dragones.Models.model()
    reasoning = Dragones.Models.reasoning()

    socket =
      socket
      |> assign(
        show_settings: true,
        settings_providers: Dragones.Models.providers(),
        settings_provider: provider,
        settings_model: model,
        settings_custom_model: "",
        settings_reasoning: reasoning,
        settings_models: [],
        settings_models_status: :loading
      )
      |> fetch_models()

    {:noreply, socket}
  end

  def handle_event("close_settings", _params, socket),
    do: {:noreply, assign(socket, show_settings: false)}

  def handle_event("settings_select_provider", %{"provider" => pid}, socket) do
    provider = String.to_existing_atom(pid)

    socket =
      socket
      |> assign(
        settings_provider: provider,
        settings_models: [],
        settings_model: nil,
        settings_custom_model: "",
        settings_reasoning: :none,
        settings_models_status: :loading
      )
      |> fetch_models()

    {:noreply, socket}
  end

  def handle_event("settings_select_model", %{"model" => model}, socket) do
    reasoning =
      default_reasoning_for(
        socket.assigns.settings_provider,
        socket.assigns.settings_models,
        model
      )

    {:noreply,
     assign(socket,
       settings_model: model,
       settings_custom_model: "",
       settings_reasoning: reasoning
     )}
  end

  def handle_event("settings_custom_model", %{"value" => value}, socket),
    do: {:noreply, assign(socket, settings_custom_model: value || "")}

  def handle_event("settings_set_reasoning", %{"level" => level}, socket) do
    reasoning = if level == "none", do: :none, else: level
    {:noreply, assign(socket, settings_reasoning: reasoning)}
  end

  def handle_event("settings_refresh_models", _params, socket) do
    {:noreply, socket |> assign(settings_models_status: :loading) |> fetch_models()}
  end

  # Apply: persist the override, restart the partida with the new model, close.
  def handle_event("settings_apply", _params, socket) do
    provider = socket.assigns.settings_provider

    # Custom slug wins over the dropdown when filled.
    model =
      case String.trim(socket.assigns.settings_custom_model || "") do
        "" -> socket.assigns.settings_model
        custom -> custom
      end

    # Clamp the reasoning to a value the chosen model actually accepts (so we
    # never send e.g. "xhigh" to a model that only supports low/medium/high, or
    # :none to a mandatory-reasoning model).
    reasoning =
      clamp_reasoning(
        provider,
        socket.assigns.settings_models,
        model,
        socket.assigns.settings_reasoning
      )

    :ok =
      Dragones.ModelConfig.set(
        provider: provider,
        model: model,
        reasoning: reasoning
      )

    # Restart rehydrates the same game_id from Postgres with the new model.
    if socket.assigns.game_id,
      do: {:ok, _} = Dragones.Game.restart(socket.assigns.game_id)

    Phoenix.PubSub.broadcast(
      Dragones.PubSub,
      "dragones:game:#{socket.assigns.game_id}",
      {:game_updated, socket.assigns.game_id}
    )

    {:noreply, assign(socket, show_settings: false)}
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

  # A roll GROUP landed (RollLog on_close). It already carries the full labeled
  # entry — who rolled, why, dice, total, what it contested against, outcome —
  # so we open the modal ONCE per group with everything in one shot. Multiple
  # groups arriving within the debounce window (e.g. an attack's d20 then its
  # damage dice) collapse into a single tumble + a stack of labeled cards.
  def handle_info({:dice_group, game_id, entry}, %{assigns: %{game_id: game_id}} = socket) do
    # Pull the dice of THIS group into the tumble hand, and stack the labeled
    # entry into the cards list. Both reset on each new group burst after the
    # hold timer fires (see :hide_dice).
    new_hand =
      Enum.map(entry["dice"] || entry[:dice] || [], fn
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
    {:noreply,
     assign(socket, dice_show: false, dice_hand: [], dice_groups: [], dice_hide_ref: nil)}
  end

  # Live model catalogue for the Ajustes modal: a background task fetched the
  # provider's /models endpoint. Reconcile the in-modal selection with the list
  # (if the current model isn't offered, move it to the custom field so the
  # dropdown stays valid) and clamp the reasoning to a value the model accepts.
  def handle_info({:settings_models, provider, result}, socket) do
    if socket.assigns.show_settings and socket.assigns.settings_provider == provider do
      case result do
        {:ok, models} ->
          current = socket.assigns.settings_model

          {model, custom} =
            if current != nil and Enum.any?(models, &(&1.id == current)),
              do: {current, ""},
              else: {nil, current || ""}

          reasoning =
            clamp_reasoning(provider, models, model, socket.assigns.settings_reasoning)

          {:noreply,
           assign(socket,
             settings_models: models,
             settings_model: model,
             settings_custom_model: custom,
             settings_reasoning: reasoning,
             settings_models_status: :ok
           )}

        {:error, :no_key} ->
          {:noreply, assign(socket, settings_models: [], settings_models_status: :no_key)}

        {:error, _} ->
          {:noreply, assign(socket, settings_models: [], settings_models_status: :error)}
      end
    else
      {:noreply, socket}
    end
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
      live_last_narration_seq: 0,
      has_more_events: false,
      pending: "",
      dice_hand: [],
      dice_groups: [],
      dice_show: false,
      dice_rolling: false,
      dice_token: 0,
      dice_flush_ref: nil,
      dice_hide_ref: nil,
      dice_engine: nil,
      show_waiting_room: false,
      waiting_heroes: [],
      waiting_game: nil,
      join_error: nil,
      auto_play: false,
      is_creator: false,
      viewer_level_up: nil,
      viewer_level_up_cache: {nil, nil},
      # Ajustes de IA modal (gear button). provider/model/reasoning are the
      # in-modal selections; the effective config lives in Dragones.ModelConfig.
      show_settings: false,
      settings_providers: [],
      settings_provider: nil,
      settings_models: [],
      settings_models_status: :idle,
      settings_model: nil,
      settings_custom_model: "",
      settings_reasoning: :none
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
          |> assign_new(:live_last_narration_seq, fn -> 0 end)
          |> assign_new(:has_more_events, fn -> false end)

        # The snapshot is a synchronous GenServer call. If the game server is
        # busy (processing a beat, heavy mailbox), the default 5s timeout can
        # fire and crash the LiveView — taking the user's view down. Catch the
        # exit and skip this update: the next broadcast will retry.
        snap =
          try do
            Game.snapshot(pid)
          catch
            :exit, _ ->
              nil
          end

        if snap == nil do
          socket
        else
          user = socket.assigns[:current_user]
          game = Games.get_game(game_id)
          is_creator = user && game && game.user_id == user.id

          viewer =
            cond do
              viewer_param == "dm" and is_creator -> "dm"
              is_binary(viewer_param) -> validate_viewer(viewer_param, snap.participants)
              user != nil -> auto_viewer(snap.participants, user.id)
              true -> nil
            end

          busy = busy_actor(snap)

          # Streaming bubble state. We track the seq of the actor's latest
          # persisted narration: when a NEW narration lands while the same beat
          # is still in flight (mid-beat text → tool call → text), the segment
          # we were streaming is now a chat card, so the bubble is flushed and
          # the next segment streams fresh. Seq-based (not text-comparison) so
          # it's robust to scrubbing changing the persisted text vs the raw
          # streaming preview.
          live =
            compute_live_state(
              busy,
              snap.events,
              socket.assigns[:live_actor],
              socket.assigns[:live_text],
              socket.assigns[:live_turn_id],
              socket.assigns[:live_last_narration_seq]
            )

          {vlu, vlu_cache} =
            compute_viewer_level_up(
              viewer,
              game,
              socket.assigns[:current_user],
              socket.assigns[:viewer_level_up_cache]
            )

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
            busy_actor: busy,
            live_text: live.text,
            live_turn_id: live.turn_id,
            live_actor: live.actor,
            live_last_narration_seq: live.last_seq,
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
            auto_play: viewer != nil and MapSet.member?(snap[:auto] || MapSet.new(), viewer),
            viewer_level_up: vlu,
            viewer_level_up_cache: vlu_cache
          )
        end
    end
  end

  # Banner de subida de nivel del viewer: su héroe de biblioteca puede subir.
  # El nivel/XP se leen del `Hero.sheet` (fuente de verdad). Para no decodificar
  # el sheet en cada broadcast, cacheamos por `(hero_id, hero.updated_at)`: solo
  # refrescamos cuando el héroe cambia (gana XP / sube), que es lo único que mueve
  # el banner.
  defp compute_viewer_level_up(viewer, game, user, {prev_key, prev_val}) do
    gc = Enum.find((game && game.characters) || [], &(&1.name == viewer))

    with gc when gc != nil <- gc,
         %{hero_id: hero_id} when hero_id != nil <- gc,
         %{} = hero <- Dragones.Accounts.get_hero(hero_id) do
      cache_key = {hero_id, hero.updated_at}

      if cache_key == prev_key do
        {prev_val, {cache_key, prev_val}}
      else
        sheet =
          case user && Dragones.Accounts.get_user_hero(user, hero_id) do
            nil -> nil
            h -> Dragones.Accounts.hero_sheet(h)
          end

        val =
          cond do
            sheet == nil ->
              nil

            sheet.level >= 20 ->
              nil

            Progression.can_level_up?(sheet.level, sheet.xp || 0) ->
              %{hero_id: hero_id, target: sheet.level + 1}

            true ->
              nil
          end

        {val, {cache_key, val}}
      end
    else
      _ -> {nil, {nil, nil}}
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

  # Streaming bubble state machine, re-evaluated on every `:game_updated`
  # re-render. The bubble shows the text currently being generated; it must
  # flush (clear) the moment a streamed segment has been persisted as a chat
  # card, so the NEXT segment (the model's reaction after a mid-beat tool call)
  # streams fresh instead of appending to the already-carded text.
  #
  # We detect "a new segment just landed" by comparing the seq of the actor's
  # latest narration against the seq we saw when the bubble started filling.
  # This is robust where a text comparison would not be: the persisted text is
  # scrubbed (`Text.scrub/2` strips leading tags, the actor's own name, HP
  # leaks…) while the bubble holds the RAW stream, so they routinely differ.
  #
  # On a beat/actor change we clear the bubble AND seed `last_seq` to the new
  # actor's latest narration, so the segment that's ALREADY on screen when we
  # connect doesn't count as "new" and flush prematurely.
  defp compute_live_state(busy, events, live_actor, live_text, live_turn_id, prev_seq) do
    live_text = live_text || ""
    prev_seq = prev_seq || 0
    latest_seq = last_narration_seq(events, busy) || 0

    cond do
      busy == nil or busy != live_actor ->
        %{text: "", last_seq: latest_seq, turn_id: nil, actor: nil}

      live_text != "" and latest_seq > prev_seq ->
        %{text: "", last_seq: latest_seq, turn_id: live_turn_id, actor: live_actor}

      true ->
        %{text: live_text, last_seq: prev_seq, turn_id: live_turn_id, actor: live_actor}
    end
  end

  defp last_narration_seq(events, actor) do
    events
    |> Enum.reverse()
    |> Enum.find(fn e -> e.type == :narration and e.actor == actor end)
    |> case do
      nil -> nil
      e -> e.seq
    end
  end

  # CSS class for the turn header actor label: highlights the viewer's own turn
  # and tones down the DM's.
  defp th_actor_class(actor, viewer, auto_play) do
    cond do
      actor == viewer and auto_play -> "auto"
      actor == viewer -> "mine"
      actor == "dm" -> "dm-side"
      true -> ""
    end
  end

  # The header label for the acting character: "TÚ" if the viewer is manually
  # controlling them; "🤖 <name> (auto)" if they enabled auto-play on their own
  # character; otherwise just the name (or "Turno del DM").
  defp turn_header_label("dm", _viewer, _auto), do: "Turno del DM"

  defp turn_header_label(actor, viewer, true) when actor == viewer do
    ["🤖 ", actor, " (auto)"]
  end

  defp turn_header_label(actor, viewer, _auto) when actor == viewer do
    [actor, " · TÚ"]
  end

  defp turn_header_label(actor, _viewer, _auto), do: "Turno de #{actor}"

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
    # Blocks are prepended (and lines prepended within each block) for O(1)
    # updates, then reversed at the end so the result is chronological — the
    # earlier `acc ++ [block]` form was O(n²) over a long timeline.
    blocks_rev =
      Enum.reduce(visible, [], fn e, acc ->
        cur = List.first(acc)

        case e do
          %{type: :turn, payload: %{"kind" => "start"} = p} ->
            header = %{
              turn_id: p["turn_id"],
              actor: e.actor,
              round: p["round"],
              phase: p["phase"]
            }

            block = %{header: header, events: []}
            [block | acc]

          _ ->
            line = %{
              seq: e.seq,
              type: e.type,
              actor: e.actor,
              role: chat_role(e),
              who: chat_who(e),
              text: chat_text(e),
              outcome: chat_outcome(e)
            }

            case cur do
              nil ->
                # No open block — prologue (e.g. the opening narration).
                [%{header: nil, events: [line]} | acc]

              %{events: evs} = block ->
                [%{block | events: [line | evs]} | tl(acc)]
            end
        end
      end)

    blocks_rev
    |> Enum.reverse()
    |> Enum.map(&%{&1 | events: Enum.reverse(&1.events)})
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

  # True when the streaming bubble's text already opens with the actor's own
  # name (a PC bot narrating in third person, "Lyra levanta..."). In that case
  # the leading `who` span is redundant — showing it would render "LyraLyra
  # levanta...". Persisted cards are already scrubbed of this by
  # `Text.scrub/2`, but the live bubble streams RAW text, so we guard here too.
  # Word-boundary safe: the name must be followed by a separator, so
  # "Lyranthropo" never matches.
  defp leading_self?(text, actor) when is_binary(text) and is_binary(actor) and actor != "" do
    trimmed = text |> String.trim() |> String.trim_leading("—*\"'- ")
    size = byte_size(actor)

    case trimmed do
      <<prefix::binary-size(^size), rest::binary>> when prefix == actor ->
        # The card already labels the actor, so a leading self-name would render
        # doubled. The streaming bubble uses RAW (un-scrubbed) text, so we must
        # detect the self-name here too. After the name, strip any closing
        # markdown bold (`**Thane**...` → `**...`) the model emits, then accept
        # a separator OR a lowercase letter (DeepSeek sometimes glues the name
        # to the next word with no space: "Thanedeja ...").
        rest = String.trim_leading(rest, "*")
        rest == "" or Regex.match?(~r/^([:：,.\s\-—]|[a-zá-úñ])/, rest)

      _ ->
        false
    end
  end

  defp leading_self?(_, _), do: false

  defp chat_outcome(%{type: :dice, payload: p}), do: p["outcome"]
  defp chat_outcome(_), do: nil

  defp chat_text(%{type: :system, payload: p}), do: p["note"] || p[:note] || ""
  defp chat_text(%{type: :dice, payload: p}), do: RollFormat.format_line(p)
  defp chat_text(%{payload: p}), do: p["text"] || p[:text] || ""

  defp server(%{assigns: %{game_id: game_id}}) when not is_nil(game_id),
    do: Dragones.Game.Supervisor.whereis(game_id)

  defp server(_), do: nil

  # Kick off a background fetch of the provider's live model list. The result
  # lands in handle_info({:settings_models, ...}). Uses ExAgent's TaskSupervisor
  # (already in the tree); start_child is fire-and-forget (no ref message).
  defp fetch_models(socket) do
    provider = socket.assigns.settings_provider

    if provider do
      parent = self()

      Task.Supervisor.start_child(ExAgent.TaskSupervisor, fn ->
        send(parent, {:settings_models, provider, Dragones.Models.list_models(provider)})
      end)
    end

    socket
  end

  # --- thinking selector helpers -------------------------------------------
  #
  # The reasoning effort is dynamic per model: OpenRouter exposes each model's
  # supported efforts (+ a default and a mandatory flag); OpenCode carries no
  # metadata, so it falls back to a generic low/medium/high set.

  # Find the model_info map for `model_id` in the fetched list (nil if absent,
  # e.g. a custom slug typed in the free-text field).
  defp find_model_info(_models, nil), do: nil

  defp find_model_info(models, model_id),
    do: Enum.find(models, &(&1.id == model_id))

  # Resolve what the thinking section should render for the selected model:
  #   * {:unsupported}                 — model explicitly has no reasoning
  #   * {:unknown}                      — reasoning metadata not curated yet
  #   * {:options, efforts, mandatory}  — render these effort buttons (+ Off unless mandatory)
  defp thinking_state(_provider, models, model_id, custom) do
    if custom != "" do
      # Custom slug → no metadata, offer the generic set.
      {:options, sort_efforts(Dragones.Models.generic_efforts()), false}
    else
      case find_model_info(models, model_id) do
        %{reasoning?: false} ->
          {:unsupported}

        %{reasoning?: nil} ->
          {:unknown}

        %{efforts: efforts, mandatory: mandatory} ->
          {:options, sort_efforts(efforts || Dragones.Models.generic_efforts()), mandatory}

        _ ->
          {:unknown}
      end
    end
  end

  defp sort_efforts(efforts) do
    order = Dragones.Models.effort_order()

    Enum.sort_by(efforts, fn e ->
      case Enum.find_index(order, &(&1 == e)) do
        nil -> 99
        idx -> idx
      end
    end)
  end

  defp effort_label("none"), do: "Off"
  defp effort_label("minimal"), do: "Mín"
  defp effort_label("low"), do: "Bajo"
  defp effort_label("medium"), do: "Medio"
  defp effort_label("high"), do: "Alto"
  defp effort_label("xhigh"), do: "Muy alto"
  defp effort_label("max"), do: "Máx"
  defp effort_label(other), do: String.capitalize(other)

  # The gear button's live label: provider/model + (reasoning) for the currently
  # effective config (override → env). Reflects what the running Game uses.
  defp ai_button_label do
    provider = Dragones.Models.provider()
    model = Dragones.Models.model()
    effort = Dragones.Models.reasoning() |> reasoning_short()
    "#{provider}/#{model} (#{effort})"
  end

  defp reasoning_short(:none), do: "off"
  defp reasoning_short(effort) when is_binary(effort), do: effort

  # Default reasoning when a model is first selected: the model's own default
  # effort, or :none (forced to a level when reasoning is mandatory).
  defp default_reasoning_for(_provider, models, model_id) do
    case find_model_info(models, model_id) do
      %{reasoning?: false} -> :none
      %{default_effort: effort} when is_binary(effort) -> effort
      %{mandatory: true} -> "medium"
      _ -> :none
    end
  end

  # Clamp a reasoning choice to a value the model actually accepts, so we never
  # send an invalid effort. `:none` is kept unless the model mandates reasoning.
  defp clamp_reasoning(:openrouter, models, model_id, current) do
    case find_model_info(models, model_id) do
      nil ->
        current

      %{reasoning?: false} ->
        :none

      %{efforts: efforts, mandatory: mandatory, default_effort: default} ->
        cond do
          current == :none and mandatory -> default || "medium"
          is_binary(current) and (is_nil(efforts) or current in efforts) -> current
          true -> default || if mandatory, do: "medium", else: :none
        end
    end
  end

  # OpenCode has no per-model metadata → keep any generic low/medium/high, else :none.
  defp clamp_reasoning(:opencode, _models, _model_id, current) do
    case current do
      effort when effort in ["low", "medium", "high"] -> effort
      _ -> :none
    end
  end

  defp clamp_reasoning(_, _, _, _), do: :none

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

      <.settings_modal
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
          <button :if={@is_creator} class="ctl-btn ai-btn" phx-click="open_settings" title={"Ajustes de IA: " <> ai_button_label()}>
            <span class="ai-gear">
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <path d="M11.078 2.25c-.917 0-1.699.663-1.85 1.567L9.05 4.889c-.02.12-.115.26-.297.348a7.493 7.493 0 0 0-.986.57c-.166.115-.334.126-.45.083L6.3 5.508a1.875 1.875 0 0 0-2.282.819l-.922 1.597a1.875 1.875 0 0 0 .432 2.385l.84.692c.095.078.17.229.154.43a7.598 7.598 0 0 0 0 1.139c.015.2-.059.352-.153.43l-.841.692a1.875 1.875 0 0 0-.432 2.385l.922 1.597a1.875 1.875 0 0 0 2.282.818l1.019-.382c.115-.043.283-.031.45.082.312.214.641.405.985.57.182.088.277.228.297.35l.178 1.071c.151.904.933 1.567 1.85 1.567h1.844c.916 0 1.699-.663 1.85-1.567l.178-1.072c.02-.12.114-.26.297-.349.344-.165.673-.356.985-.57.167-.114.335-.125.45-.082l1.02.382a1.875 1.875 0 0 0 2.28-.819l.923-1.597a1.875 1.875 0 0 0-.432-2.385l-.84-.692c-.095-.078-.17-.229-.154-.43a7.614 7.614 0 0 0 0-1.139c-.016-.2.059-.352.153-.43l.84-.692c.708-.582.891-1.59.433-2.385l-.922-1.597a1.875 1.875 0 0 0-2.282-.818l-1.02.382c-.114.043-.282.031-.449-.083a7.49 7.49 0 0 0-.985-.57c-.183-.087-.277-.227-.297-.348l-.179-1.072a1.875 1.875 0 0 0-1.85-1.567h-1.843ZM12 15.75a3.75 3.75 0 1 0 0-7.5 3.75 3.75 0 0 0 0 7.5Z" />
              </svg>
            </span>
            <span class="ai-label">{ai_button_label()}</span>
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
              <span class={"th-actor #{th_actor_class(block.header.actor, @viewer, @auto_play)}"}>
                {turn_header_label(block.header.actor, @viewer, @auto_play)}
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
              <span :if={entry.who != ""}><span class="who">{entry.who}</span> </span>{entry.text}
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
          <span :if={@live_actor != "dm" and @live_actor != nil and not leading_self?(@live_text, @live_actor)} class="who">{@live_actor}</span>{@live_text}<span class="cursor">▍</span>
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
      <%= if assigns[:viewer_level_up] do %>
        <style>
          .level-up-banner{background:#241c14;border:1px solid #a72;border-radius:12px;padding:.7rem .8rem;margin-bottom:.6rem;color:#fc8;font-size:.82rem;line-height:1.4;}
          .level-up-banner strong{display:block;margin-bottom:.4rem;}
          .level-up-banner .btn{display:inline-block;background:#3a2a1a;border:1px solid #a72;color:#fc8;border-radius:8px;padding:.3rem .7rem;text-decoration:none;font-size:.78rem;}
        </style>
        <div class="level-up-banner">
          <strong>¡Tu héroe puede subir a nivel {assigns[:viewer_level_up].target}!</strong>
          <.link navigate={"/heroes/#{assigns[:viewer_level_up].hero_id}/level-up"} class="btn">Gestionar subida →</.link>
        </div>
      <% end %>
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

  # The Ajustes de IA modal: provider switch, live model list (with free-text
  # fallback) and reasoning-effort selector. Creator-only; writing the selection
  # restarts the partida so the new model takes effect.
  attr(:show, :boolean, default: false)
  attr(:providers, :list, default: [])
  attr(:provider, :atom, default: nil)
  attr(:models, :list, default: [])
  attr(:models_status, :atom, default: :idle)
  attr(:model, :string, default: nil)
  attr(:custom_model, :string, default: "")
  attr(:reasoning, :any, default: :none)

  defp settings_modal(assigns) do
    ~H"""
    <div :if={@show} class="modal settings-modal">
      <div class="settings-backdrop" phx-click="close_settings"></div>
      <div class="modal-box settings-box">
        <h2>⚙ Ajustes de IA</h2>

        <div class="settings-section">
          <div class="settings-label">Provider</div>
          <div class="settings-providers">
            <button
              :for={p <- @providers}
              type="button"
              phx-click="settings_select_provider"
              phx-value-provider={p.id}
              disabled={not p.configured}
              class={"settings-pbtn #{if @provider == p.id, do: "sel", else: ""}#{if not p.configured, do: " disabled", else: ""}"}
            >
              <span class={"settings-dot #{if p.configured, do: "on", else: "off"}"}></span>
              {p.name}
            </button>
          </div>
        </div>

        <div class="settings-section">
          <div class="settings-label">
            Modelo
            <button type="button" phx-click="settings_refresh_models" class="settings-refresh" title="Refrescar modelos">↻</button>
          </div>
          <%= cond do %>
            <% @models_status == :loading -> %>
              <div class="settings-msg">cargando modelos…</div>
            <% @models_status == :no_key -> %>
              <div class="settings-msg warn">sin API key para este provider — escribe el slug abajo</div>
            <% @models_status == :error -> %>
              <div class="settings-msg warn">no se pudieron cargar los modelos — escribe el slug abajo</div>
            <% true -> %>
              <form phx-change="settings_select_model">
                <select name="model" class="settings-select">
                  <option value="" disabled={@model == nil}>(elige modelo)</option>
                  {Phoenix.HTML.Form.options_for_select(Enum.map(@models, &{&1.id, &1.id}), @model)}
                </select>
              </form>
          <% end %>
          <input
            type="text"
            class="settings-input"
            phx-change="settings_custom_model"
            value={@custom_model}
            placeholder="o escribe un slug (ej: deepseek-v4-flash)"
          />
        </div>

        <div class="settings-section">
          <div class="settings-label">Thinking (cuánto razona)</div>
          <%= case thinking_state(@provider, @models, @model, @custom_model) do %>
            <% {:unsupported} -> %>
              <div class="settings-msg warn">este modelo no soporta thinking</div>
            <% {:unknown} -> %>
              <div class="settings-msg warn">nivel de thinking sin confirmar para este modelo</div>
            <% {:options, efforts, mandatory} -> %>
              <div class="settings-reasoning">
                <button
                  :if={not mandatory}
                  type="button"
                  phx-click="settings_set_reasoning"
                  phx-value-level="none"
                  class={"settings-rbtn #{if @reasoning == :none, do: "sel", else: ""}"}
                >
                  Off
                </button>
                <button
                  :for={eff <- efforts}
                  type="button"
                  phx-click="settings_set_reasoning"
                  phx-value-level={eff}
                  class={"settings-rbtn #{if @reasoning == eff, do: "sel", else: ""}"}
                >
                  {effort_label(eff)}
                </button>
              </div>
          <% end %>
        </div>

        <div class="settings-actions">
          <button class="ctl-btn" phx-click="close_settings">Cancelar</button>
          <button class="ctl-btn ctl-active" phx-click="settings_apply">Aplicar ⚡</button>
        </div>
        <p class="settings-hint">
          Aplicar reinicia el proceso de la partida con el nuevo modelo/thinking.
          El estado queda en Postgres, así que continúa en el mismo punto.
        </p>
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
      assign(
        assigns,
        :outcome_css,
        RollFormat.outcome_css(assigns.g[:outcome] || assigns.g["outcome"])
      )

    ~H"""
    <div class={"dice-group #{@outcome_css}"}>
      <div class="dg-head">
        <span class="dg-who">{(@g[:who] || @g["who"] || "—")}</span>
        <span class="dg-reason">{(@g[:reason] || @g["reason"] || "")}</span>
      </div>
      <div class="dg-line">
        <span class="dg-dice">{RollFormat.format_dice(@g)}</span>
        <span class="dg-against">{RollFormat.format_against_spaced(@g)}</span>
      </div>
      <div class="dg-outcome">{RollFormat.outcome_label(@g[:outcome] || @g["outcome"])}</div>
    </div>
    """
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
      |> Enum.reject(fn {_, c} -> c.side != "pc" and c.hp <= 0 end)
      |> Enum.sort_by(fn {n, _} -> n end)
      |> Enum.take(@max_sheets)
      |> Enum.map(&elem(&1, 1))

  defp active_card?(%World{} = w, %Character{} = c, current),
    do: World.controller_of(w, c) == current and c.hp > 0

  defp active_card?(_, _, _), do: false

  defp placeholder(true, _, _, _), do: "¿Qué haces?"
  defp placeholder(_, true, _, _), do: "el DM está pensando…"
  defp placeholder(_, _, _, :paused), do: "Partida en pausa"

  defp placeholder(_, _, current, _) when is_binary(current),
    do: "Declara tu intención (turno de #{current})…"

  defp placeholder(_, _, _, _), do: "Declara tu intención…"
end
