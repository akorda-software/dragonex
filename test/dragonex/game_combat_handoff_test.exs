defmodule Dragonex.GameCombatHandoffTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Archetypes, Character, Game, Games, Monsters, World}
  alias Dragonex.Game.Turnmaster
  alias Dragonex.TurnPolicy.WorldDriven
  alias ExAgent.{Models.Test, Session}

  defmodule CountingModel do
    @behaviour ExAgent.Model
    defstruct [:counter, script: []]

    def new(script \\ []) do
      counter = ExUnit.Callbacks.start_supervised!({Agent, fn -> 0 end})
      %__MODULE__{counter: counter, script: script}
    end

    def calls(model), do: Agent.get(model.counter, & &1)

    @impl true
    def request(model, messages, settings, params) do
      index = Agent.get_and_update(model.counter, fn n -> {n, n + 1} end)
      reply = Enum.at(model.script, index, "(sin decisión)")
      {:ok, response, _} = Test.request(%Test{script: [reply]}, messages, settings, params)
      {:ok, response, model}
    end

    @impl true
    def request_stream(model, messages, settings, params) do
      {:ok, response, _} = request(model, messages, settings, params)
      Stream.map([response], &Dragonex.Test.Harness.stream_response(&1, model))
    end

    @impl true
    def model_name(_), do: "counting-turnmaster"
    @impl true
    def system(_), do: "counting-turnmaster"
    @impl true
    def profile(_), do: %ExAgent.ModelProfile{supports_tools: true}
  end

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp roller(20), do: 15
  defp roller(_), do: 1

  defp game(order) do
    {:ok, game} =
      Games.create_game(
        title: "Deterministic combat handoffs",
        roster: [
          {Archetypes.fighter(), :human},
          {Archetypes.wizard(), :human},
          {Monsters.goblin(name: "g1"), :ai},
          {Monsters.goblin(name: "g2"), :ai}
        ],
        initiative: order
      )

    game
  end

  defp state(order) do
    game = game(order)

    session =
      start_supervised!(
        {Session,
         shared_state: Games.load_world(Games.get_game(game.id)),
         policy: {WorldDriven, dm: "dm"},
         participants: [p("dm", :other), p("Thane", :human), p("Lyra", :human)]}
      )

    assert {:ok, _} = Session.start(session)

    %Game{
      game_id: game.id,
      session: session,
      status: :paused,
      roller: &roller/1,
      participants: %{
        "dm" => %{kind: :other},
        "Thane" => %{kind: :human},
        "Lyra" => %{kind: :human}
      }
    }
  end

  defp change(state, transition) do
    assert {:ok, _} =
             Session.update_state(state.session, Session.current(state.session), transition)

    state
  end

  defp mark(state, names),
    do: Enum.reduce(names, state, fn name, acc -> change(acc, World.mark_acted(name)) end)

  defp waiting(name), do: fn s -> s.status == :waiting and s.current == name end
  defp give(name), do: tool_calls([call("give_turn_to", %{"participant" => name})])

  defp observe(owner, name) do
    fn messages, _params ->
      send(owner, {:actor_context, name, inspect(messages, limit: :infinity)})
      narration("#{name} observa el combate.")
    end
  end

  test "a named main handoff cannot skip an earlier unspent slot" do
    state = state(["g1", "Thane", "g2", "Lyra"]) |> mark(["g1", "Thane"])
    state = Turnmaster.apply_turnmaster_decision(state, %{action: :give_turn_to, to: "Lyra"})
    world = Session.read_state(state.session)

    assert world.current_combatant == "g2"
    assert Session.current(state.session) == "dm"
    assert world.acted_this_round == MapSet.new(["g1", "Thane"])
  end

  test "a named monster cannot replay its spent main turn" do
    state = state(["g1", "Thane", "g2", "Lyra"]) |> mark(["g1"])
    state = Turnmaster.apply_turnmaster_decision(state, %{action: :give_turn_to, to: "g1"})

    assert Session.read_state(state.session).current_combatant == "Thane"
    assert Session.current(state.session) == "Thane"
  end

  test "pass_to_dm cannot skip the PC who owns the next initiative slot" do
    state = state(["g1", "Thane", "g2", "Lyra"]) |> mark(["g1"])
    state = Turnmaster.apply_turnmaster_decision(state, %{action: :pass_to_dm})

    assert Session.read_state(state.session).current_combatant == "Thane"
    assert Session.current(state.session) == "Thane"
  end

  test "a human reaction stays a mini-turn even when the TM gives that same human the floor" do
    state = state(["g1", "Thane", "g2", "Lyra"]) |> mark(["g1"])
    state = Turnmaster.apply_turnmaster_decision(state, %{action: :give_turn_to, to: "Thane"})

    state = %{
      state
      | intents: %{"Lyra" => Dragonex.Intents.encode("me pongo delante del golpe", :combat)},
        tm_reeval: true
    }

    state = Turnmaster.apply_turnmaster_decision(state, %{action: :give_turn_to, to: "Lyra"})
    world = Session.read_state(state.session)
    assert state.pending_mini
    assert world.turn_kind == "reaction"
    assert world.turn_owner == "Thane"
    assert world.current_combatant == "Lyra"
    assert world.acted_this_round == MapSet.new(["g1"])
  end

  test "a successful mini-turn returns to its unfinished owner without refunding a bonus action" do
    state = state(["g1", "Thane", "g2", "Lyra"]) |> mark(["g1"])
    state = Turnmaster.apply_turnmaster_decision(state, %{action: :give_turn_to, to: "Thane"})
    world = Session.read_state(state.session)
    {:ok, _, wind} = Actions.second_wind(world, "Thane", &roller/1)
    state = change(state, wind)
    budget = Session.read_state(state.session).turn_state["Thane"]

    state = Turnmaster.apply_turnmaster_decision(state, %{action: :cut_in, to: "Lyra"})
    state = %{state | last_was_mini: true, last_actor: "Lyra"}
    state = Turnmaster.apply_turnmaster_decision(state, %{action: :give_turn_to, to: "g2"})
    world = Session.read_state(state.session)

    assert Session.current(state.session) == "Thane"
    assert world.current_combatant == "Thane"
    assert world.turn_kind == "main"
    assert world.turn_state["Thane"] == budget
    assert world.characters["Thane"].second_wind_used
    assert world.round == 1
    refute state.pending_mini
    assert state.interrupted == nil
  end

  test "ordinary combat opener and two named monster turns require no TM requests" do
    game = game(["g1", "g2", "Thane", "Lyra"])
    spy = CountingModel.new()
    owner = self()

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: [observe(owner, "g1"), observe(owner, "g2")]},
            turnmaster_model: spy,
            roller: &roller/1
          ]}}
      )

    assert :ok == Game.await(pid, waiting("Thane"), 10_000)
    assert CountingModel.calls(spy) == 0

    for name <- ["g1", "g2"] do
      assert_receive {:actor_context, ^name, context}
      assert context =~ "Es TU turno (DM) -- actúa por: #{name}."
    end

    world = Game.world(pid)
    assert world.current_combatant == "Thane"
    assert world.acted_this_round == MapSet.new(["g1", "g2"])
    assert Games.load_world(Games.get_game(game.id)) == world
    assert world.round == 1
    refute Enum.any?(Games.list_events(game.id), &(&1.payload["kind"] == "turnmaster_fallback"))
  end

  test "the final slot advances once and starts the next round without TM requests" do
    game = game(["Thane", "g1", "g2", "Lyra"])
    spy = CountingModel.new()

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{
              script: [
                narration("Thane observa."),
                narration("g1 espera."),
                narration("g2 espera."),
                narration("Lyra observa.")
              ]
            },
            turnmaster_model: spy,
            roller: &roller/1
          ]}}
      )

    assert :ok == Game.await(pid, waiting("Thane"), 10_000)
    assert {:ok, _} = Game.declare(pid, "Thane", "Vigilo el flanco.")
    assert :ok == Game.await(pid, waiting("Lyra"), 10_000)
    assert {:ok, _} = Game.declare(pid, "Lyra", "Observo el combate.")
    assert :ok == Game.await(pid, waiting("Thane"), 10_000)
    assert CountingModel.calls(spy) == 0
    world = Game.world(pid)
    assert world.round == 2
    assert world.current_combatant == "Thane"
    assert world.acted_this_round == MapSet.new()
    assert world.turn_state["Thane"]["round"] == 2
    assert Games.load_world(Games.get_game(game.id)) == world
  end

  test "a reaction during a human wait consults the TM and then returns to the waiting owner" do
    game = game(["Thane", "g1", "Lyra", "g2"])
    spy = CountingModel.new([give("Lyra"), text("listo"), give("g1"), text("listo")])

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: [narration("Lyra se interpone sin atacar.")]},
            turnmaster_model: spy,
            roller: &roller/1
          ]}}
      )

    assert :ok == Game.await(pid, waiting("Thane"), 10_000)
    assert CountingModel.calls(spy) == 0
    assert {:ok, :queued} = Game.declare(pid, "Lyra", "me pongo delante del golpe")

    assert :ok ==
             Game.await(
               pid,
               fn snapshot ->
                 snapshot.status == :waiting and snapshot.current == "Thane" and
                   Enum.any?(snapshot.events, &(&1.type == :action and &1.actor == "Lyra"))
               end,
               10_000
             )

    assert CountingModel.calls(spy) >= 2
    world = Game.world(pid)
    assert world.turn_owner == "Thane"
    assert world.turn_kind == "main"
    assert world.round == 1
    assert world.acted_this_round == MapSet.new()
    refute Map.has_key?(Games.get_game(game.id).intents, "Lyra")
  end

  test "a queued ordinary declaration consults the TM but cannot take another human's main turn" do
    game = game(["Thane", "g1", "Lyra", "g2"])
    spy = CountingModel.new([give("Lyra"), text("listo")])

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Test{}, turnmaster_model: spy, roller: &roller/1]}}
      )

    assert :ok == Game.await(pid, waiting("Thane"), 10_000)
    assert CountingModel.calls(spy) == 0
    assert {:ok, :queued} = Game.declare(pid, "Lyra", "Observo la puerta.")
    assert :ok == Game.await(pid, waiting("Thane"), 10_000)
    assert CountingModel.calls(spy) >= 1
    world = Game.world(pid)
    assert world.current_combatant == "Thane"
    assert world.turn_kind == "main"
    assert world.acted_this_round == MapSet.new()
    assert Map.has_key?(Games.get_game(game.id).intents, "Lyra")
    refute Enum.any?(Games.list_events(game.id), &(&1.type == :action and &1.actor == "Lyra"))
  end

  test "the ordinary path skips a defeated enemy and preserves a downed PC's death-save slot" do
    game = game(["g1", "Thane", "g2", "Lyra"])
    world = Games.load_world(Games.get_game(game.id))
    {:ok, world} = World.apply_damage("g1", 7).(world)
    {:ok, world} = World.apply_damage("Thane", 12).(world)
    {:ok, _} = Games.save_state(game.id, world, nil, world.round, :running)
    spy = CountingModel.new()

    pid =
      Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{}, turnmaster_model: spy]}})

    assert :ok == Game.await(pid, waiting("Thane"), 10_000)
    assert CountingModel.calls(spy) == 0
    assert Game.world(pid).current_combatant == "Thane"
    assert "Thane" in World.combat_cycle(Game.world(pid))
    refute "g1" in World.combat_cycle(Game.world(pid))
    assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)
  end

  test "a forced main handoff records its aura dice and closes combat before waiting" do
    caster =
      Character.new(
        name: "Cora",
        class: "cleric",
        side: "pc",
        level: 5,
        hp: 30,
        max_hp: 30,
        wis: 16,
        spells: [
          Dragonex.Heroes.Spells.to_character_spell(
            Dragonex.Heroes.Spells.get("spirit guardians"),
            :wis
          )
        ]
      )

    enemy = Character.new(name: "Goblin", side: "enemy", hp: 3, max_hp: 3, wis: 8)

    {:ok, game} =
      Games.create_game(title: "Forced handoff aura", roster: [{caster, :human}, {enemy, :ai}])

    world = Games.load_world(Games.get_game(game.id))
    {:ok, _, spell} = Actions.spell(world, "Cora", "spirit guardians", "Goblin", &roller/1)
    {:ok, world} = spell.(world)
    {:ok, world} = World.begin_combat(["Cora", "Goblin"]).(world)
    {:ok, _} = Games.save_state(game.id, world, nil, world.round, :running)
    spy = CountingModel.new()
    roller = fn sides -> if sides == 20, do: 2, else: 1 end
    Phoenix.PubSub.subscribe(Dragonex.PubSub, Dragonex.Game.Persistence.topic(game.id))

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Test{}, turnmaster_model: spy, roller: roller]}}
      )

    assert :ok == Game.await(pid, waiting("Cora"), 10_000)
    assert CountingModel.calls(spy) == 0
    world = Game.world(pid)
    assert world.phase == :exploration
    assert world.characters["Goblin"].hp == 0
    assert Games.load_world(Games.get_game(game.id)) == world
    events = Games.list_events(game.id)
    assert Enum.count(events, &(&1.payload["note"] == "⚔ El combate termina.")) == 1
    assert Enum.count(events, &(&1.type == :dice)) == 2
    assert_receive {:dice_group, game_id, %{kind: :save, who: "Goblin"}}
    assert game_id == game.id
  end
end
