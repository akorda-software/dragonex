defmodule Dragonex.GameCombatFallbackTest do
  use ExUnit.Case, async: false
  # These cases exercise the skip path of a failed actor turn (D228).
  setup {Dragonex.Test.Harness, :skip_failed_turns}
  @moduletag :capture_log

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Archetypes, Game, Games, Monsters, World}
  alias Dragonex.Game.{Beat, Combat, Settlement, Turnmaster}
  alias Dragonex.TurnPolicy.WorldDriven
  alias ExAgent.Session

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp roller(20), do: 15
  defp roller(_), do: 1

  defp state(order \\ nil) do
    {:ok, game} =
      Games.create_game(
        title: "Canonical combat fallback",
        roster: [
          {Archetypes.fighter(), :human},
          {Archetypes.wizard(), :ai},
          {Monsters.goblin(name: "g1"), :ai},
          {Monsters.goblin(name: "g2"), :ai}
        ]
      )

    world = Games.load_world(Games.get_game(game.id))

    world =
      if order do
        {:ok, world} = World.begin_combat(order).(world)
        {:ok, world} = World.set_current_combatant(hd(order)).(world)
        world
      else
        world
      end

    session =
      start_supervised!(
        {Session,
         shared_state: world,
         policy: {WorldDriven, dm: "dm"},
         participants: [p("dm", :other), p("Thane", :human), p("Lyra")]}
      )

    assert {:ok, _} = Session.start(session)

    %Game{
      game_id: game.id,
      session: session,
      roller: &roller/1,
      status: :paused,
      participants: %{
        "dm" => %{kind: :other},
        "Thane" => %{kind: :human},
        "Lyra" => %{kind: :ai}
      }
    }
  end

  defp change(state, transition) do
    assert {:ok, _} =
             Session.update_state(state.session, Session.current(state.session), transition)

    state
  end

  defp mark(state, names) do
    Enum.reduce(names, state, fn name, state -> change(state, World.mark_acted(name)) end)
  end

  defp handoff(state, name, action \\ :give_turn_to) do
    Turnmaster.apply_turnmaster_decision(state, %{action: action, to: name})
  end

  # An older persisted handoff can already be out of initiative order. D113
  # prevents new ones; recovery must still finish that interrupted owner.
  defp existing_main_turn(state, name) do
    world = Session.read_state(state.session)
    assert {:ok, _} = Session.handoff(state.session, World.controller_of(world, name))
    Combat.start_turn(state, name)
  end

  defp settle(state, actor, result, opts \\ []) do
    phase = Keyword.get(opts, :phase, Session.read_state(state.session).phase)

    beat = %Beat{
      participant: actor,
      phase: phase,
      turn_id: "fallback-#{System.unique_integer([:positive])}",
      enemies_before: MapSet.new(["g1", "g2"]),
      mini_turn: Keyword.get(opts, :mini, false)
    }

    result =
      case result do
        :error -> {:error, {:crashed, :actor_failed}}
        :ok -> {:ok, "La escena continúa.", [], nil}
      end

    Settlement.handle_beat_result(%{state | busy: beat}, result)
  end

  test "an actor failure after the exploration-to-combat handoff does not repeat that actor" do
    state = state() |> change(World.begin_combat(["Lyra", "g1", "g2", "Thane"]))
    state = handoff(state, "Lyra")
    state = settle(state, "Lyra", :error)
    world = Session.read_state(state.session)

    assert world.current_combatant == "g1"
    assert Session.current(state.session) == "dm"
    assert world.acted_this_round == MapSet.new(["Lyra"])
    assert world.round == 1
    assert Games.load_world(Games.get_game(state.game_id)) == world
  end

  for {next, controller, order} <- [
        {"Thane", "Thane", ["g1", "Thane", "g2", "Lyra"]},
        {"Lyra", "Lyra", ["g1", "Lyra", "g2", "Thane"]},
        {"g2", "dm", ["g1", "g2", "Thane", "Lyra"]}
      ] do
    test "fallback to #{next} records the actual controller #{controller} for metrics" do
      state = state(unquote(order)) |> settle("dm", :ok)
      state = Turnmaster.fallback_world_driven(state, :no_decision)

      assert Session.read_state(state.session).current_combatant == unquote(next)
      assert Session.current(state.session) == unquote(controller)

      note =
        state.game_id
        |> Games.list_events()
        |> Enum.find(&(&1.payload["kind"] == "turnmaster_fallback"))

      assert note.type == :system
      assert note.actor == "system"
      assert note.payload["to"] == unquote(controller)
      assert note.payload["reason"] == "no_decision"
    end
  end

  for result <- [:error, :ok] do
    test "#{result} after a named monster handoff skips already spent PC slots" do
      state = state(["g1", "Thane", "g2", "Lyra"]) |> mark(["g1", "Thane"])
      state = handoff(state, "g2") |> settle("dm", unquote(result))

      state =
        if unquote(result) == :ok,
          do: Turnmaster.fallback_world_driven(state, :no_decision),
          else: state

      world = Session.read_state(state.session)
      assert Session.current(state.session) == "Lyra"
      assert world.current_combatant == "Lyra"
      assert world.acted_this_round == MapSet.new(["g1", "Thane", "g2"])
      assert world.round == 1
    end

    test "#{result} after initiative and an attack inside the DM beat consumes the actual monster" do
      state = state() |> change(World.begin_combat(["g1", "g2", "Thane", "Lyra"]))
      world = Session.read_state(state.session)
      {:ok, _, attack} = Actions.attack(world, "g1", "Thane", "scimitar", &roller/1)
      state = change(state, attack)
      committed = Session.read_state(state.session)
      assert committed.current_combatant == nil
      assert committed.turn_owner == "g1"

      state = settle(state, "dm", unquote(result), phase: :exploration)

      if unquote(result) == :ok, do: assert(state.last_actor == "g1")

      state =
        if unquote(result) == :ok,
          do: Turnmaster.fallback_world_driven(state, :no_decision),
          else: state

      world = Session.read_state(state.session)
      assert world.current_combatant == "g2"
      assert world.acted_this_round == MapSet.new(["g1"])
      assert world.characters["Thane"].hp == committed.characters["Thane"].hp
      assert world.turn_state["g1"]["action"] == true
      assert world.round == 1
    end
  end

  test "starting combat without a character action leaves the first combatant's turn available" do
    state = state() |> change(World.begin_combat(["g1", "g2", "Thane", "Lyra"]))
    state = settle(state, "dm", :ok, phase: :exploration)
    assert Session.read_state(state.session).acted_this_round == MapSet.new()

    state = Turnmaster.fallback_world_driven(state, :no_decision)
    world = Session.read_state(state.session)
    assert world.current_combatant == "g1"
    assert world.turn_state["g1"]["action"] != true
    assert world.round == 1
  end

  test "a DM narration without a live slot is not attributed to the previously spent owner" do
    state = state(["g1", "Thane", "g2", "Lyra"]) |> mark(["g1", "g2"])
    state = change(state, World.set_current_combatant(nil))
    assert Session.read_state(state.session).turn_owner == "g1"
    state = settle(state, "dm", :ok)
    assert state.last_actor == "dm"
    assert Session.read_state(state.session).acted_this_round == MapSet.new(["g1", "g2"])
  end

  test "a completed round starts at its first slot despite the stale policy cursor" do
    state = state(["Thane", "g1", "g2", "Lyra"]) |> mark(["Thane", "g1", "g2"])
    state = handoff(state, "Lyra") |> settle("Lyra", :error)
    world = Session.read_state(state.session)

    assert world.round == 2
    assert world.current_combatant == "Thane"
    assert world.acted_this_round == MapSet.new()
    assert world.turn_state["Thane"]["round"] == 2
    assert Games.load_world(Games.get_game(state.game_id)) == world
  end

  for result <- [:error, :ok] do
    test "#{result} in a reaction returns to the unfinished main slot without consuming it" do
      state = state(["g1", "Thane", "g2", "Lyra"]) |> mark(["g1"])
      state = existing_main_turn(state, "g2")
      main_budget = Session.read_state(state.session).turn_state["g2"]
      state = handoff(state, "Lyra", :react)
      state = settle(state, "Lyra", unquote(result), mini: true)

      state =
        if unquote(result) == :ok,
          do: Turnmaster.fallback_world_driven(state, :no_decision),
          else: state

      world = Session.read_state(state.session)
      assert Session.current(state.session) == "dm"
      assert world.current_combatant == "g2"
      assert world.turn_owner == "g2"
      assert world.turn_kind == "main"
      assert world.turn_state["g2"] == main_budget
      assert world.acted_this_round == MapSet.new(["g1"])
      assert world.round == 1
      assert state.interrupted == nil
    end
  end

  test "fallback skips a defeated enemy and keeps a downed PC's death-save turn" do
    state = state(["g1", "g2", "Thane", "Lyra"])
    state = change(state, World.apply_damage("g2", 7))
    state = change(state, World.apply_damage("Thane", 12))
    state = settle(state, "dm", :error)
    world = Session.read_state(state.session)

    assert world.phase == :combat
    assert world.current_combatant == "Thane"
    assert Session.current(state.session) == "Thane"
    assert world.characters["Thane"].hp == 0
    refute "g2" in World.combat_cycle(world)
    assert "Thane" in World.combat_cycle(world)
    assert world.acted_this_round == MapSet.new(["g1"])
  end

  for result <- [:error, :ok] do
    test "#{result} in the last actor's reaction cannot close an otherwise unspent round" do
      state = state(["g1", "Thane", "g2", "Lyra"])
      state = existing_main_turn(state, "g2") |> handoff("Lyra", :react)
      state = settle(state, "Lyra", unquote(result), mini: true)

      state =
        if unquote(result) == :ok,
          do: Turnmaster.fallback_world_driven(state, :no_decision),
          else: state

      world = Session.read_state(state.session)
      assert world.round == 1
      assert world.acted_this_round == MapSet.new()
      assert world.current_combatant == "g2"
    end
  end

  test "the real Game advances directly to the second monster after a partially committed opener" do
    {:ok, game} =
      Games.create_game(
        title: "Committed opener failure",
        roster: [
          {Archetypes.fighter(), :human},
          {Monsters.goblin(name: "g1"), :ai},
          {Monsters.goblin(name: "g2"), :ai}
        ]
      )

    # Initiative rolls in alphabetical order: Thane, g1, g2, then attack.
    dice = start_supervised!({Agent, fn -> [1, 20, 15, 15, 1] end})

    roller = fn sides ->
      Agent.get_and_update(dice, fn
        [next | rest] -> {next, rest}
        [] -> {if(sides == 20, do: 15, else: 1), []}
      end)
    end

    owner = self()
    failed = start_supervised!({Agent, fn -> false end}, id: :opener_failure)

    observe_next = fn messages, _params ->
      context =
        Enum.map_join(messages, "\n", fn message ->
          Enum.map_join(message.parts, "\n", fn
            %{content: text} when is_binary(text) -> text
            _ -> ""
          end)
        end)

      send(owner, {:next_monster_context, context})
      narration("El segundo goblin observa el camino.")
    end

    model = %ExAgent.Models.Test{
      script: [
        tool_calls([call("roll_initiative", %{})]),
        tool_calls([
          call("make_attack", %{
            "attacker" => "g1",
            "target" => "Thane",
            "weapon" => "scimitar",
            "mode" => "normal"
          })
        ]),
        fn messages, params ->
          if Agent.get_and_update(failed, &{&1, true}),
            do: observe_next.(messages, params),
            else: raise("failure after committed attack")
        end
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model, roller: roller]}})
    assert :ok = Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    assert_receive {:next_monster_context, context}
    assert context =~ "Es TU turno (DM) -- actúa por: g2."
    world = Game.world(pid)
    assert world.characters["Thane"].hp == 9
    assert world.acted_this_round == MapSet.new(["g1", "g2"])
    assert world.current_combatant == "Thane"
    assert Games.load_world(Games.get_game(game.id)) == world
  end
end
