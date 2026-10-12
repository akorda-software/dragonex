defmodule DragonexWeb.GameLive.Snapshot do
  @moduledoc """
  Projects a `Dragonex.Game` snapshot into the game table's LiveView assigns.

  Extracted from `DragonexWeb.GameLive.Show`: owns the default assign set
  (`base_assigns/2`) and the viewer-resolution rules (auto-assign the user's
  own participant, with a creator-only `?as=dm` inspection view).
  """

  use Phoenix.Component

  alias Dragonex.{Game, Games}
  alias DragonexWeb.GameLive.{Chat, Dice}

  @log_page_size 100
  @max_log_events 2_000
  @max_chat_blocks 400

  def base_assigns(socket, game_id) do
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
      log_limit: 200,
      history_limited: false,
      busy: false,
      busy_actor: nil,
      busy_stage: nil,
      live_text: "",
      live_turn_id: nil,
      live_actor: nil,
      live_last_narration_seq: 0,
      has_more_events: false,
      pending: "",
      input_error: nil,
      sheet_open: false,
      dice_hand: [],
      dice_groups: [],
      dice_show: false,
      dice_mode: "tray",
      dice_rolling: false,
      dice_token: 0,
      dice_flush_ref: nil,
      dice_hide_ref: nil,
      dice_hide_token: nil,
      dice_engine: nil,
      show_waiting_room: false,
      waiting_heroes: [],
      waiting_game: nil,
      join_error: nil,
      auto_play: false,
      is_creator: false,
      # Ajustes de IA modal (gear button): in-modal selections; the table's
      # effective choice lives in games.ai (Dragonex.GameAI, D242).
      ai_label: nil,
      show_settings: false,
      settings_sources: [],
      settings_source: "house",
      settings_models: [],
      settings_models_status: :idle,
      settings_model: nil,
      settings_custom_model: "",
      settings_error: nil,
      settings_checking: false
    )
  end

  def load(socket, game_id, viewer_param) do
    case Dragonex.Game.Supervisor.whereis(game_id) do
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
            Game.snapshot(pid, socket.assigns[:log_limit] || 200)
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

          # A URL selects a view, never another player's identity. Every input
          # event uses this assign, so accepting a roster name here would also
          # allow declaring or toggling auto-play on someone else's character.
          viewer =
            if viewer_param == "dm" and is_creator do
              "dm"
            else
              if user, do: auto_viewer(snap.participants, user.id)
            end

          busy = Chat.busy_actor(snap)
          blocks = Chat.blocks(snap.events, viewer)

          can_page? =
            (socket.assigns[:log_limit] || 200) < @max_log_events and
              length(blocks) < @max_chat_blocks

          # Streaming bubble state. We track the seq of the actor's latest
          # persisted narration: when a NEW narration lands while the same beat
          # is still in flight (mid-beat text → tool call → text), the segment
          # we were streaming is now a chat card, so the bubble is flushed and
          # the next segment streams fresh. Seq-based (not text-comparison) so
          # it's robust to scrubbing changing the persisted text vs the raw
          # streaming preview.
          live =
            Chat.compute_live_state(
              busy,
              snap.events,
              socket.assigns[:live_actor],
              socket.assigns[:live_text],
              socket.assigns[:live_turn_id],
              socket.assigns[:live_last_narration_seq]
            )

          assign(socket,
            loaded: true,
            connected: true,
            game_id: game_id,
            viewer: viewer,
            is_creator: is_creator,
            ai_label: if(game, do: Dragonex.GameAI.label(game)),
            world: snap.world,
            current: snap.current,
            status: snap.status,
            round: snap.round,
            participants: snap.participants,
            intents: snap.intents,
            my_intent:
              case Dragonex.Intents.text(Map.get(snap.intents, viewer)) do
                "" -> nil
                text -> text
              end,
            my_turn: viewer != nil and snap.current == viewer,
            chat: Enum.take(blocks, -@max_chat_blocks),
            busy: snap.status == :running,
            busy_actor: busy,
            busy_stage: Map.get(snap, :busy_stage),
            live_text: live.text,
            live_turn_id: live.turn_id,
            live_actor: live.actor,
            live_last_narration_seq: live.last_seq,
            has_more_events: snap.has_more_events and can_page?,
            history_limited:
              length(blocks) > @max_chat_blocks or (snap.has_more_events and not can_page?),
            pending: socket.assigns[:pending] || "",
            dice_hand: socket.assigns[:dice_hand] || [],
            dice_groups: socket.assigns[:dice_groups] || [],
            dice_show: socket.assigns[:dice_show] || false,
            dice_rolling: socket.assigns[:dice_rolling] || false,
            dice_token: socket.assigns[:dice_token] || 0,
            dice_flush_ref: socket.assigns[:dice_flush_ref] || nil,
            dice_hide_ref: socket.assigns[:dice_hide_ref] || nil,
            dice_hide_token: socket.assigns[:dice_hide_token] || nil,
            dice_engine:
              Dice.effective_engine(socket.assigns[:dice_engine] || (game && game.dice_engine)),
            auto_play: viewer != nil and MapSet.member?(snap[:auto] || MapSet.new(), viewer)
          )
        end
    end
  end

  def load_more(socket) do
    if socket.assigns.has_more_events do
      socket
      |> assign(log_limit: min(socket.assigns.log_limit + @log_page_size, @max_log_events))
      |> load(socket.assigns.game_id, socket.assigns.viewer)
    else
      socket
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
end
