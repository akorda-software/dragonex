defmodule Dragonex.Game.ToolReplay do
  @moduledoc """
  Reuses committed effects and successful tool results when the same actor
  beat is retried. New beats and standalone sessions execute normally.
  Game saves a receipt with each effect, replacing it with final feedback
  when available. World retains these until settlement, so its successor
  can recover even when a tool never finishes replying.
  """
  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.Game.Beat
  alias ExAgent.Session.SharedState

  def wrap(%{takes_ctx: true, call: original, name: name} = tool) do
    %{tool | call: fn ctx, args -> invoke(ctx, name, args, original) end}
  end

  def wrap(tool), do: tool

  defp invoke(%{deps: %{game_owner: owner} = deps} = ctx, name, args, original)
       when is_pid(owner) do
    # Tool callbacks run in exAgent processes; the replay feedback below must
    # follow the table's language even when the wrapped tool never runs.
    Dragonex.I18n.adopt(deps)

    # Omitted optional arguments and explicit nulls have the same meaning to
    # the bridge; provider call IDs do not identify a logical repeated action.
    key = {name, canonical_args(ctx, name, args) |> scrub_args()}

    case GenServer.call(owner, {:tool_replay, deps, key}) do
      :execute ->
        id = make_ref()

        deps =
          deps
          |> Map.put(:tool_commit, %{id: id, key: key})
          |> Map.put(:roll_log, Dragonex.RollLog.for_tool(deps[:roll_log], id))

        ctx = %{ctx | deps: deps}
        result = original.(ctx, args)
        :ok = GenServer.call(owner, {:remember_tool_result, ctx.deps, key, result})
        result

      {:replay, value} ->
        {:ok,
         dgettext(
           "engine",
           "Resultado ya aplicado antes del fallo; no repitas la acción: %{result}",
           result: value
         )}

      {:error, _} = error ->
        error
    end
  end

  defp invoke(ctx, _name, args, original), do: original.(ctx, args)

  defp canonical_args(ctx, "cast_spell", args) do
    world = SharedState.read(ctx.deps.state)
    spell = Dragonex.Actions.spell_definition(world, args["caster"], args["spell"])

    args =
      if spell do
        level = cast_level(args["cast_level"]) || spell.level
        args |> Map.put("spell", spell.name) |> Map.put("cast_level", level)
      else
        args
      end

    args =
      if args["additional_targets"] == [], do: Map.delete(args, "additional_targets"), else: args

    selection = args["condition_to_remove"]

    args =
      if is_binary(selection) and String.trim(selection) == "",
        do: Map.delete(args, "condition_to_remove"),
        else: args

    without_nulls(args)
  end

  defp canonical_args(_ctx, name, args) when name in ["grant_item", "remove_item"] do
    args = if args["additional"] == true, do: args, else: Map.delete(args, "additional")
    args |> Map.update("item", nil, &Dragonex.Rules.Inventory.key/1) |> without_nulls()
  end

  defp canonical_args(_ctx, _name, args), do: without_nulls(args)
  defp without_nulls(args), do: Map.reject(args, fn {_key, value} -> is_nil(value) end)

  defp cast_level(level) when is_binary(level) do
    case Integer.parse(String.trim(level)) do
      {value, ""} -> value
      _ -> level
    end
  end

  defp cast_level(level), do: level

  def lookup(state, deps, key) do
    key = scrub_key(key)

    if active?(state, deps) do
      beat = state.busy

      case Map.get(beat.replay_results, key, []) do
        [] ->
          {admit_execution(state, key), state}

        results ->
          index = Map.get(beat.replay_counts, key, 0)
          value = Enum.at(results, index) || List.last(results)
          beat = %{beat | replay_counts: Map.put(beat.replay_counts, key, index + 1)}
          {{:replay, value}, %{state | busy: beat}}
      end
    else
      {{:error, :stale_beat}, state}
    end
  end

  # Enemy weapon attacks belong to an initiative slot. Admission runs inside
  # Game before the tool callback, so a rejected opening attack spends no RNG
  # or resources. Paid receipts still replay before this check.
  defp admit_execution(state, {"make_attack", %{"attacker" => actor}}) do
    world = ExAgent.Session.read_state(state.session)
    character = Dragonex.World.present_character(world, actor)

    if world.phase == :exploration and match?(%{side: "enemy"}, character) and
         Dragonex.World.controlled_by?(world, actor, state.busy.participant) and
         Dragonex.World.validate_actor(world, actor) == :ok do
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — %{actor} no puede atacar antes de la iniciativa. " <>
           "Usa roll_initiative y respeta el combatiente actual; no resuelvas un ataque extra en exploración.",
         actor: actor
       )}
    else
      :execute
    end
  end

  defp admit_execution(_state, _key), do: :execute

  def remember(state, deps, key, {:ok, value}) when is_binary(value) do
    key = scrub_key(key)

    if active?(state, deps) do
      value = Dragonex.Text.scrub(value)
      beat = state.busy
      {pending, commits} = Map.pop(beat.tool_commits, get_in(deps, [:tool_commit, :id]))

      results =
        case pending do
          {^key, index} ->
            Map.update!(beat.tool_results, key, &List.replace_at(&1, index, value))

          _ ->
            Map.update(beat.tool_results, key, [value], &(&1 ++ [value]))
        end

      beat = %{beat | tool_results: results, tool_commits: commits}
      world = ExAgent.Session.read_state(state.session)
      world = Map.put(world, :actor_checkpoint, checkpoint(beat))

      with {:ok, entries} <-
             Dragonex.Game.Persistence.persist_tool_change(state, world, deps),
           {:ok, _} <-
             ExAgent.Session.update_state(state.session, beat.participant, fn _ ->
               {:ok, world}
             end) do
        Dragonex.Game.Persistence.publish_tool_rolls(state, deps, entries)
        {:ok, %{state | busy: beat}}
      else
        {:error, _} = error -> {error, state}
      end
    else
      {{:error, :stale_beat}, state}
    end
  end

  def remember(state, _deps, _key, _result), do: {:ok, state}

  # RuleCheckpoint saves this receipt in the SAME World write as the effect.
  # The final tool feedback replaces it when available. If the actor dies
  # before replying, the receipt still prevents charging the effect again.
  def stage_change(
        state,
        %{tool_commit: %{id: id, key: {name, _args} = key}},
        world
      )
      when is_reference(id) and is_binary(name) do
    key = scrub_key(key)
    beat = state.busy

    beat =
      if Map.has_key?(beat.tool_commits, id) do
        beat
      else
        previous = Map.get(beat.tool_results, key, [])

        receipt =
          dgettext(
            "engine",
            "La herramienta %{tool} ya aplicó su cambio. " <>
              "Consulta el estado vigente y las tiradas registradas; no repitas el efecto.",
            tool: name
          )

        %{
          beat
          | tool_results: Map.put(beat.tool_results, key, previous ++ [receipt]),
            tool_commits: Map.put(beat.tool_commits, id, {key, length(previous)})
        }
      end

    {%{state | busy: beat}, Map.put(world, :actor_checkpoint, checkpoint(beat))}
  end

  def stage_change(state, _deps, world), do: {state, world}

  # Speech is durable before its acknowledgement. An intermediate tool needs
  # its paid receipt; a final response needs the same turn even with no tools,
  # until scene review and settlement finish. The public event proves closure.
  def stage_narration(state, deps, world) do
    {next, candidate} = stage_change(state, deps, world)
    saved = checkpoint(next.busy) |> Map.put("pending_narration", true)
    {next, %{candidate | actor_checkpoint: saved}}
  end

  def turn_id(world, actor) do
    case restore(world, actor) do
      nil -> nil
      saved -> saved.turn_id
    end
  end

  @doc "Retain the unresolved narration's turn, even when no rule tool has run yet."
  def retain_narration(state, beat) do
    retain_turn(state, beat, %{
      note:
        dgettext(
          "engine",
          "No se pudo completar la narración de %{actor}. La partida está en pausa; " <>
            "los resultados registrados se conservan. Reanuda para volver a intentarlo.",
          actor: beat.participant
        )
    })
  end

  @doc """
  Pause on the failed actor turn and keep its checkpoint, so resume reruns the
  same turn_id and replays paid receipts. The public note is saved with it.
  """
  def retain_turn(state, beat, note) when is_map(note) do
    world = ExAgent.Session.read_state(state.session)
    saved = checkpoint(beat) |> Map.put("pending_narration", true)
    candidate = %{world | actor_checkpoint: saved}
    paused = %{state | status: :paused, loop_phase: :actor}
    note = Map.put(note, :turn_id, beat.turn_id)

    with {:ok, []} <-
           Dragonex.Game.Persistence.persist_roll_change(
             paused,
             candidate,
             [],
             beat.participant,
             %{},
             [note]
           ),
         {:ok, _} <-
           ExAgent.Session.update_state(state.session, beat.participant, fn _ ->
             {:ok, candidate}
           end) do
      Dragonex.Game.Persistence.broadcast_updated(paused)
      {:ok, paused}
    end
  end

  def restore(%{actor_checkpoint: saved}, actor) when is_map(saved) do
    with %{
           "actor" => ^actor,
           "turn_id" => turn_id,
           "tools" => tools,
           "phase" => phase,
           "enemies_before" => enemies,
           "mini_turn" => mini
         } <- saved,
         true <- is_binary(turn_id) and turn_id != "" and is_list(tools),
         true <- tools != [] or saved["pending_narration"] == true,
         true <- phase in ["combat", "exploration"] and is_boolean(mini),
         true <- is_list(enemies) and Enum.all?(enemies, &is_binary/1),
         true <- Enum.all?(tools, &valid_entry?/1) do
      results = Map.new(tools, fn entry -> {{entry["name"], entry["args"]}, entry["values"]} end)

      %{
        turn_id: turn_id,
        inventory_scene_before: Map.get(saved, "inventory_scene_before"),
        tool_results: results,
        mini_turn: mini,
        phase: if(phase == "combat", do: :combat, else: :exploration),
        enemies_before: MapSet.new(enemies)
      }
    else
      _ -> nil
    end
  end

  def restore(_, _), do: nil

  def clear(state) do
    world = ExAgent.Session.read_state(state.session)

    if Map.get(world, :actor_checkpoint) != nil do
      actor = ExAgent.Session.current(state.session)

      {:ok, _} =
        ExAgent.Session.update_state(state.session, actor, fn current ->
          {:ok, %{current | actor_checkpoint: nil}}
        end)
    end

    state
  end

  defp checkpoint(beat) do
    %{
      "actor" => beat.participant,
      "turn_id" => beat.turn_id,
      "phase" => Atom.to_string(beat.phase),
      "mini_turn" => beat.mini_turn,
      "inventory_scene_before" => beat.inventory_scene_before,
      "enemies_before" => MapSet.to_list(beat.enemies_before),
      "tools" =>
        Enum.map(beat.tool_results, fn {{name, args}, values} ->
          %{"name" => name, "args" => args, "values" => values}
        end)
    }
  end

  defp valid_entry?(%{"name" => name, "args" => args, "values" => values}) do
    is_binary(name) and is_map(args) and is_list(values) and values != [] and
      Enum.all?(values, &is_binary/1)
  end

  defp valid_entry?(_), do: false

  defp scrub_key({name, args}), do: {name, scrub_args(args)}

  defp scrub_args(value) when is_binary(value), do: Dragonex.Text.scrub(value)
  defp scrub_args(values) when is_list(values), do: Enum.map(values, &scrub_args/1)

  defp scrub_args(values) when is_map(values),
    do: Map.new(values, fn {key, value} -> {key, scrub_args(value)} end)

  defp scrub_args(value), do: value

  defp active?(
         %{session: session, game_id: game_id, busy: %Beat{kind: :actor} = beat},
         %{
           state: %SharedState{session: session, participant_id: actor},
           beat: %{game_id: game_id, turn_id: turn_id},
           beat_owner: owner
         }
       ) do
    actor == beat.participant and turn_id == beat.turn_id and is_pid(owner) and
      Process.alive?(owner)
  end

  defp active?(_, _), do: false
end
