defmodule DragonexWeb.GameLive.Show do
  @moduledoc """
  The game table — a thin **view + input** over a `Dragonex.Game` process.

  It opens a partida by `game_id` (resuming it from Postgres), subscribes to its
  `Dragonex.PubSub` updates, and renders the Game's snapshot. Each viewer
  sees their own participant; the creator may inspect the DM view (`?as=dm`).
  Several humans can share a partida: the input resolves on the viewer's own
  turn, their sheet is marked, and a banner calls "Es tu turno". The Game owns the loop/rules/persistence
  and enforces server-side that `declare/3` only resolves the current human's turn.

  The heavy view code lives apart: the timeline view-model in
  `DragonexWeb.GameLive.Chat`, the dice overlay FSM in `DragonexWeb.GameLive.Dice`,
  the Ajustes de IA modal in `DragonexWeb.GameLive.Settings` and the markup in
  `DragonexWeb.GameLive.Components`.
  """

  use Phoenix.LiveView, layout: {DragonexWeb.Layouts, :app}
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{Game, Games}
  alias DragonexWeb.GameLive.{Dice, Settings, Snapshot}
  import DragonexWeb.GameLive.Components

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
    game = Games.get_game(game_id)

    # The whole table (and its waiting room) renders in the game's language,
    # regardless of the visitor's interface locale. Both the disconnected and
    # the connected render follow it, so `<html lang>` matches too.
    if game, do: Dragonex.I18n.put_locale(game.locale)

    cond do
      not Phoenix.LiveView.connected?(socket) ->
        {:ok, socket}

      game == nil ->
        {:ok, push_navigate(socket, to: "/")}

      true ->
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

      case Games.start_game(game_id) do
        {:ok, _} ->
          {:ok, _pid} = Game.ensure_started(game_id)

          Phoenix.PubSub.broadcast(
            Dragonex.PubSub,
            "dragonex:game:#{game_id}",
            {:game_updated, game_id}
          )

          # Full reload — mount runs again with status :running, loads the table
          {:noreply, Phoenix.LiveView.push_navigate(socket, to: "/games/#{game_id}")}

        {:error, :not_found} ->
          room_unavailable(socket)
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("join_with_hero", %{"hero_id" => hero_id}, socket) do
    user = socket.assigns.current_user

    hero =
      case Ecto.Type.cast(:id, hero_id) do
        {:ok, id} when is_integer(id) and id > 0 -> Dragonex.Accounts.get_user_hero(user, id)
        _ -> nil
      end

    game = Games.get_game(socket.assigns.game_id)

    cond do
      is_nil(game) ->
        room_unavailable(socket)

      is_nil(hero) ->
        join_failed(
          socket,
          dgettext("ui", "Héroe no encontrado. Vuelve a elegir uno de tus héroes.")
        )

      true ->
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
             |> assign(show_waiting_room: true, waiting_game: updated_game, join_error: nil)}

          {:error, :already_joined} ->
            refresh_lobby(socket)

          {:error, :already_started} ->
            join_failed(socket, dgettext("ui", "La partida ya ha empezado."))

          {:error, :no_open_slots} ->
            join_failed(socket, dgettext("ui", "La partida no tiene plazas libres."))

          {:error, :name_taken} ->
            join_failed(
              socket,
              dgettext(
                "ui",
                "Ya hay un personaje llamado %{name}. Elige otro héroe o cambia su nombre.",
                name: sheet.name
              )
            )

          {:error, _} ->
            join_failed(
              socket,
              dgettext("ui", "No se pudo unir a la partida. Vuelve a elegir tu héroe.")
            )
        end
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
      {:noreply, assign(socket, dice_engine: Dice.effective_engine(engine))}
    end
  end

  def handle_event("share", _params, socket) do
    url = "/games/#{socket.assigns.game_id}"
    {:noreply, push_event(socket, "copy_url", %{url: url})}
  end

  @impl true
  def handle_event("declare", %{"text" => text}, socket) do
    if String.trim(text) == "" do
      {:noreply, assign(socket, pending: "", input_error: nil)}
    else
      result =
        try do
          with pid when is_pid(pid) <- server(socket),
               viewer when not is_nil(viewer) <- socket.assigns[:viewer] do
            Game.declare(pid, viewer, text)
          else
            _ -> {:error, :unavailable}
          end
        catch
          :exit, _ -> {:error, :unavailable}
        end

      socket =
        case result do
          {:ok, _} ->
            socket
            |> assign(pending: "", input_error: nil)
            |> push_event("action_accepted", %{
              game_id: socket.assigns.game_id,
              viewer: socket.assigns.viewer,
              text: text
            })

          {:error, :not_your_turn} ->
            assign(socket,
              pending: text,
              input_error: dgettext("ui", "Vuelve a tu personaje para declarar una acción.")
            )

          {:error, _} ->
            assign(socket,
              pending: text,
              input_error:
                dgettext(
                  "ui",
                  "No se pudo enviar tu acción. Recarga la partida para volver a intentarlo; tu texto sigue aquí."
                )
            )
        end

      {:noreply, socket}
    end
  end

  def handle_event("draft", %{"text" => text}, socket) do
    {:noreply, assign(socket, pending: text)}
  end

  def handle_event("toggle_sheet", _params, socket) do
    {:noreply, assign(socket, sheet_open: not socket.assigns.sheet_open)}
  end

  def handle_event("clear_intent", _params, socket) do
    with pid when is_pid(pid) <- server(socket),
         viewer when not is_nil(viewer) <- socket.assigns[:viewer] do
      _ = Game.clear_intent(pid, viewer)
    end

    {:noreply, socket}
  end

  # Expand the authoritative history window. Retaining its size in the socket
  # keeps earlier turns visible on broadcasts and regroups split turn markers.
  def handle_event("load_more_log", _params, socket) do
    {:noreply, Snapshot.load_more(socket)}
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
  @settings_events ~w(open_settings close_settings settings_select_source
                      settings_select_model settings_custom_model
                      settings_refresh_models settings_apply)

  def handle_event(event, params, socket) when event in @settings_events,
    do: Settings.handle_event(event, params, socket)

  # --------------------------------------------------------------- info

  @impl true
  def handle_info(
        {:game_updated, game_id},
        %{assigns: %{game_id: game_id, show_waiting_room: true}} = socket
      ) do
    # In the waiting room: check if the game started
    case Games.get_game(game_id) do
      nil ->
        room_unavailable(socket)

      %{status: :configuring} = game ->
        # Still waiting: refresh the roster
        {:noreply, assign(socket, waiting_game: game)}

      _game ->
        # Game started! Full reload to enter the table
        {:noreply, Phoenix.LiveView.push_navigate(socket, to: "/games/#{game_id}")}
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
        {:text_delta, game_id, _turn_id, _actor, _chunk},
        %{assigns: %{game_id: game_id, busy_stage: stage}} = socket
      )
      when stage in [:scene_review, :turnmaster, :retrying],
      do: {:noreply, socket}

  def handle_info(
        {:text_delta, game_id, turn_id, actor, chunk},
        %{assigns: %{game_id: game_id}} = socket
      ) do
    prev_turn = socket.assigns[:live_turn_id]

    # New turn or new actor → start a fresh bubble (drop the previous preview).
    {text, live_turn, live_actor} =
      cond do
        prev_turn == nil or prev_turn != turn_id or socket.assigns[:live_actor] != actor ->
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

  def handle_info({:dice_animation_timeout, token}, socket),
    do: Dice.animation_timeout(socket, token)

  def handle_info(:hide_dice, socket), do: Dice.hide(socket)

  def handle_info({:hide_dice, token}, socket), do: Dice.hide(socket, token)

  def handle_info({:settings_models, _, _} = msg, socket), do: Settings.handle_info(msg, socket)

  def handle_info({:settings_probe, _, _, _} = msg, socket),
    do: Settings.handle_info(msg, socket)

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --------------------------------------------------------------- load

  defp load(socket, game_id, viewer_param), do: Snapshot.load(socket, game_id, viewer_param)

  defp server(%{assigns: %{game_id: game_id}}) when not is_nil(game_id),
    do: Dragonex.Game.Supervisor.whereis(game_id)

  defp server(_), do: nil

  defp join_failed(socket, message), do: refresh_lobby(socket, message)

  defp refresh_lobby(socket, error \\ nil) do
    case Games.get_game(socket.assigns.game_id) do
      nil -> room_unavailable(socket)
      game -> {:noreply, assign(socket, join_error: error, waiting_game: game)}
    end
  end

  defp room_unavailable(socket) do
    {:noreply,
     socket
     |> put_flash(
       :error,
       dgettext("ui", "La partida ya no está disponible. Vuelve a tus partidas.")
     )
     |> push_navigate(to: "/")}
  end

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
          <.waiting_room game_id={@game_id} game={@waiting_game} is_creator={@is_creator} current_user={@current_user} waiting_heroes={@waiting_heroes} join_error={@join_error} />
        <% not @loaded -> %>
          <div class="loading">{dgettext("ui", "Cargando partida…")}</div>
        <% @viewer == nil -> %>
          <div class="loading">{dgettext("ui", "Esperando tu turno o la acción del DM…")}</div>
        <% true -> %>
          <.table
            game_id={@game_id}
            world={@world}
            current={@current}
            status={@status}
            round={@round}
            viewer={@viewer}
            is_creator={@is_creator}
            ai_label={@ai_label}
            auto_play={@auto_play}
            participants={@participants}
            my_turn={@my_turn}
            my_intent={@my_intent}
            chat={@chat}
            history_limited={@history_limited}
            busy={@busy}
            busy_actor={@busy_actor}
            busy_stage={@busy_stage}
            live_text={@live_text}
            live_actor={@live_actor}
            has_more_events={@has_more_events}
            pending={@pending}
            input_error={@input_error}
            sheet_open={@sheet_open}
            dice_show={@dice_show}
            dice_mode={@dice_mode}
            dice_rolling={@dice_rolling}
            dice_hand={@dice_hand}
            dice_groups={@dice_groups}
            dice_engine={@dice_engine}
          />
      <% end %>

      <Settings.modal
        show={@show_settings}
        sources={@settings_sources}
        source={@settings_source}
        models={@settings_models}
        models_status={@settings_models_status}
        model={@settings_model}
        custom_model={@settings_custom_model}
        error={@settings_error}
        checking={@settings_checking}
      />
    </div>
    """
  end
end
