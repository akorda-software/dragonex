defmodule Dragonex.Game.KeyRevocation do
  @moduledoc """
  Coordinates account-key changes with model admission and live tables.
  Key changes serialize briefly per user/provider; provider IO runs outside
  that lock. The Game owns the pause, checkpoint and agent replacement.
  """
  import Ecto.Query
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{Accounts, GameAI, Games, Models, Repo, World}
  alias Dragonex.Game.{Beat, Bootstrap, PendingRetry, Persistence, ToolReplay}
  alias Dragonex.GameAI.OwnKeyModel

  @registry Dragonex.GameAI.RequestRegistry

  def locked(user_id, provider, fun),
    do: :global.trans({{__MODULE__, user_id, provider}, self()}, fun, [node()])

  def admit(%OwnKeyModel{} = model) do
    locked(model.user_id, model.provider, fn ->
      if is_binary(model.version) and
           Accounts.api_key_version(model.user_id, model.provider) == model.version do
        {:ok, _} = Registry.register(@registry, {model.user_id, model.provider}, model.version)
        :ok
      else
        {:error, :credential_revoked}
      end
    end)
  end

  def release(%OwnKeyModel{} = model),
    do: Registry.unregister(@registry, {model.user_id, model.provider})

  # Caller holds the account/provider lock, after persisting the key change.
  def changed(user_id, provider, {_action, _models} = transition) do
    games =
      Repo.all(
        from(g in Games.Game,
          where:
            g.user_id == ^user_id and fragment("?->>'source' = 'own'", g.ai) and
              fragment("?->>'provider' = ?", g.ai, ^provider),
          select: g.id
        )
      )

    # Let Game cancel its own beat before terminating remaining standalone
    # requests, so cancellation cannot be settled as an ordinary actor failure.
    results = Enum.map(games, &change_table(&1, user_id, provider, transition))

    @registry
    |> Registry.lookup({user_id, provider})
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.each(&stop_request/1)

    if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :tables_not_updated}
  end

  defp change_table(id, user_id, provider, {action, _models} = transition) do
    case Dragonex.Game.Supervisor.whereis(id) do
      nil ->
        query =
          from(g in Games.Game,
            where:
              g.id == ^id and g.user_id == ^user_id and fragment("?->>'source' = 'own'", g.ai) and
                fragment("?->>'provider' = ?", g.ai, ^provider),
            update: [
              set: [
                status:
                  fragment(
                    "CASE WHEN ? IN ('running', 'waiting') THEN 'paused' ELSE ? END",
                    g.status,
                    g.status
                  )
              ]
            ]
          )

        query =
          if action == :removed,
            do: from(g in query, update: [set: [ai: ^GameAI.encode(%{source: :house})]]),
            else: query

        # Publish the new payer and pause atomically. A Game registers before
        # reading its row: if it loaded the old row while this write ran, the
        # second lookup catches it; any later start reads the paused row.
        Repo.update_all(query, [])

        case Dragonex.Game.Supervisor.whereis(id) do
          nil -> :ok
          pid -> GenServer.call(pid, {:credential_changed, user_id, provider, transition}, 30_000)
        end

      pid ->
        GenServer.call(pid, {:credential_changed, user_id, provider, transition}, 30_000)
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Resolve house defaults before taking the key lock; catalogues may need HTTP."
  def defaults do
    {:ok, opts} = GameAI.build(%{source: :house}, nil)
    model = opts[:model] || Models.dm()
    summarizer = opts[:summarizer] || Models.summarizer()

    turnmaster =
      opts[:turnmaster_model] ||
        if(Models.live?(model), do: Models.turnmaster(), else: %ExAgent.Models.Test{})

    [model: model, summarizer: summarizer, turnmaster_model: turnmaster]
  end

  @doc "Runs inside Game's callback, preserving the Session and turn phase."
  def transition(state, user_id, provider, {action, house_models}) do
    selection = GameAI.selection(state.game)

    if state.game.user_id == user_id and match?(%{source: :own, provider: ^provider}, selection) do
      {selection, models} =
        if action == :replaced do
          case GameAI.build(selection, user_id) do
            {:ok, models} -> {selection, models}
            _ -> {%{source: :house}, house_models}
          end
        else
          {%{source: :house}, house_models}
        end

      cancel_beat(state.busy)
      Enum.each([state.dm, state.turnmaster | Map.values(state.pc_agents)], &stop_agent/1)
      note = %{kind: "api_key_changed", note: note(action)}

      case retain(state, note) do
        {:ok, retained} ->
          :ok = Games.set_ai(state.game_id, GameAI.encode(selection))
          game = Games.get_game(state.game_id)
          # Results/EXIT messages of old agents cannot match the replacements.
          rotated = Bootstrap.replace_agents(%{retained | game: game, busy: nil}, models)
          Persistence.broadcast_updated(rotated)
          {:ok, rotated}

        {:error, _} ->
          # The generation guard already forbids the retired credential. Stop
          # cleanly on a persistence error so no dead agent can be resumed.
          send(self(), {:credential_transition_failed, state.game_id})

          {{:error, :persistence_failed},
           %{state | status: :paused, busy: nil, dm: nil, turnmaster: nil, pc_agents: %{}}}
      end
    else
      {:ok, state}
    end
  end

  defp retain(%{busy: %Beat{kind: :actor} = beat} = state, note),
    do: ToolReplay.retain_turn(state, beat, note)

  defp retain(%{busy: %PendingRetry{participant: actor} = retry} = state, note)
       when actor != "turnmaster" do
    world = ExAgent.Session.read_state(state.session)
    restored = ToolReplay.restore(world, actor)
    beat = struct(Beat, Map.take(Map.from_struct(retry), Map.keys(%Beat{})))

    beat = %{
      beat
      | enemies_before:
          if(restored,
            do: restored.enemies_before,
            else: World.living_enemies(world)
          ),
        inventory_scene_before: if(restored, do: restored.inventory_scene_before),
        legacy_attack_keys: if(restored, do: restored.legacy_attack_keys, else: MapSet.new())
    }

    ToolReplay.retain_turn(state, beat, note)
  end

  defp retain(state, note) do
    status = if state.status in [:configuring, :ended], do: state.status, else: :paused
    paused = %{state | status: status}
    world = ExAgent.Session.read_state(state.session)

    case Persistence.persist_roll_change(paused, world, [], "system", %{}, [note]) do
      {:ok, []} -> {:ok, paused}
      error -> error
    end
  end

  defp cancel_beat(%Beat{pid: pid, ref: ref}) do
    if is_reference(ref), do: Process.demonitor(ref, [:flush])
    if is_pid(pid), do: Task.Supervisor.terminate_child(ExAgent.TaskSupervisor, pid)
    :ok
  end

  defp cancel_beat(_), do: :ok

  defp stop_agent(pid) when is_pid(pid) do
    try do
      ExAgent.Server.abort(pid)
      GenServer.stop(pid, :normal, 5_000)
    catch
      :exit, _ -> if Process.alive?(pid), do: stop_request(pid)
    end
  end

  defp stop_agent(_), do: :ok

  defp note(:removed),
    do:
      dgettext(
        "engine",
        "La clave de IA se ha retirado. La mesa usa el modelo de la casa y queda en pausa; reanuda cuando quieras."
      )

  defp note(:replaced),
    do:
      dgettext(
        "engine",
        "La clave de IA se ha actualizado. La mesa queda en pausa con la nueva clave; reanuda cuando quieras."
      )

  # A delayed successful probe must never apply a withdrawn/replaced model.
  # Rebuild its model under the same lock as key changes before stopping Game.
  def restart(game_id, opts, restart) do
    case Keyword.get(opts, :ai) do
      %{"source" => "own", "provider" => provider} = ai ->
        case Games.get_game(game_id) do
          nil ->
            {:error, :not_found}

          game ->
            locked(game.user_id, provider, fn ->
              with {:ok, models} <- GameAI.build(GameAI.selection(%{ai: ai}), game.user_id) do
                restart.(Keyword.merge(opts, models))
              end
            end)
        end

      _ ->
        restart.(opts)
    end
  end

  defp stop_request(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      1_000 ->
        Process.exit(pid, :kill)
        receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
    end
  end
end
