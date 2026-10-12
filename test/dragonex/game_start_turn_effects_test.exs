defmodule Dragonex.GameStartTurnEffectsTest do
  use ExUnit.Case, async: false
  # These cases exercise the skip path of a failed actor turn (D228).
  setup {Dragonex.Test.Harness, :skip_failed_turns}
  @moduletag :capture_log

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Game, Games, World}
  alias Dragonex.Heroes.Spells
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp cleric do
    Character.new(
      name: "Cora",
      class: "cleric",
      level: 5,
      side: "pc",
      hp: 30,
      max_hp: 30,
      wis: 16,
      spells: [Spells.to_character_spell(Spells.get("spirit guardians"), :wis)]
    )
  end

  defp guardians_game(enemy_hp \\ 100) do
    enemy =
      Character.new(
        name: "Goblin",
        side: "enemy",
        hp: enemy_hp,
        max_hp: enemy_hp,
        wis: 8,
        con: 10,
        concentrating: "bless"
      )

    {:ok, game} =
      Games.create_game(title: "Start-turn aura", roster: [{cleric(), :human}, {enemy, :ai}])

    world = Games.load_world(Games.get_game(game.id))
    {:ok, _, cast} = Actions.spell(world, "Cora", "spirit guardians", "Goblin", &no_roll/1)
    {:ok, world} = cast.(world)
    {:ok, world} = World.begin_combat(["Goblin", "Cora"]).(world)
    {:ok, _} = Games.save_state(game.id, world, nil, world.round, :running)
    game
  end

  defp no_roll(_), do: flunk("this operation must not roll dice")

  defp tracked_roller(d20 \\ 2) do
    recorder = start_supervised!({Agent, fn -> [] end})

    roller = fn sides ->
      value = if sides == 20, do: d20, else: 1
      Agent.update(recorder, &[{sides, value} | &1])
      value
    end

    {roller, recorder}
  end

  defp rolls(recorder), do: Agent.get(recorder, &Enum.reverse/1)

  defp give(name), do: tool_calls([call("give_turn_to", %{"participant" => name})])

  defp models(:decision),
    do:
      {%Dragonex.Test.Narrator{text: "El goblin espera."},
       %Test{script: [give("dm"), "listo", give("Cora"), "listo"]}}

  defp models(:no_decision),
    do: {%Dragonex.Test.Narrator{text: "El goblin espera."}, %Test{label: "sin decisión"}}

  defp models(:tm_error),
    do:
      {%Dragonex.Test.Narrator{text: "El goblin espera."},
       %Test{script: [fn -> raise "fallo de TM" end]}}

  defp models(:actor_error),
    do: {%Test{script: [fn -> raise "fallo del actor" end]}, %Test{script: [give("dm")]}}

  defp start_game(game, route, roller, opts \\ []) do
    {model, tm} = models(route)

    Dragonex.Test.GameFixture.start!(
      {Game,
       {game.id,
        Keyword.merge(
          [model: model, combat_handoffs: :turnmaster, turnmaster_model: tm, roller: roller],
          opts
        )}}
    )
  end

  defp waiting_on_cora(pid) do
    assert :ok = Game.await(pid, &(&1.status == :waiting and &1.current == "Cora"), 5_000)
  end

  defp dice_events(game_id), do: Enum.filter(Games.list_events(game_id), &(&1.type == :dice))

  for route <- [:decision, :no_decision, :tm_error, :actor_error] do
    test "the last enemy killed by an aura closes combat before waiting via #{route}" do
      game = guardians_game(3)
      {roller, recorder} = tracked_roller()
      pid = start_game(game, unquote(route), roller)
      waiting_on_cora(pid)

      world = Game.world(pid)
      assert world.characters["Goblin"].hp == 0
      assert world.phase == :exploration
      assert world.current_combatant == nil
      assert Games.load_world(Games.get_game(game.id)) == world

      events = Games.list_events(game.id)

      assert Enum.count(
               events,
               &(&1.type == :system and &1.payload["note"] == "⚔ El combate termina.")
             ) == 1

      assert Enum.all?(dice_events(game.id), &(&1.payload["phase"] == "combat"))
      assert rolls(recorder) |> Enum.take(4) == [{20, 2}, {8, 1}, {8, 1}, {8, 1}]
    end

    test "start-turn effects use the Game roller and reach the timeline via #{route}" do
      game = guardians_game()
      {roller, recorder} = tracked_roller()
      Phoenix.PubSub.subscribe(Dragonex.PubSub, Dragonex.Game.Persistence.topic(game.id))

      pid = start_game(game, unquote(route), roller)
      waiting_on_cora(pid)

      assert rolls(recorder) == [{20, 2}, {8, 1}, {8, 1}, {8, 1}, {20, 2}]
      world = Game.world(pid)
      assert world.current_combatant == "Cora"
      assert world.characters["Goblin"].hp == 97
      assert world.characters["Goblin"].concentrating == nil
      assert world.turn_state["Cora"]["round"] == world.round

      [save, damage, concentration] = dice_events(game.id)
      assert save.payload["dice"] == [[20, 2]]
      assert save.payload["total"] == 1
      assert save.payload["against"] == ["dc", 14]
      assert save.payload["outcome"] == "failure"
      assert damage.payload["dice"] == [[8, 1], [8, 1], [8, 1]]
      assert damage.payload["total"] == 3
      assert concentration.payload["dice"] == [[20, 2]]
      assert concentration.payload["total"] == 2
      assert concentration.payload["against"] == ["dc", 10]

      for event <- [save, damage, concentration] do
        assert event.payload["who"] == "Goblin"
        assert event.payload["timing"] == "turn_start"
        assert event.payload["combatant"] == "Cora"
      end

      assert_receive {:dice_group, game_id, %{kind: :save, who: "Goblin"}}
      assert game_id == game.id
      persisted = Games.load_world(Games.get_game(game.id))
      assert persisted == world
    end
  end

  test "Hold Person's repeated save uses the Game roller and is recorded" do
    enemy =
      Character.new(
        name: "Goblin",
        class: "cleric",
        level: 5,
        side: "enemy",
        hp: 100,
        max_hp: 100,
        wis: 16,
        spells: [Spells.to_character_spell(Spells.get("hold person"), :wis)]
      )

    {:ok, game} =
      Games.create_game(title: "Repeated Hold Person", roster: [{cleric(), :human}, {enemy, :ai}])

    world = Games.load_world(Games.get_game(game.id))
    {:ok, _, cast} = Actions.spell(world, "Goblin", "hold person", "Cora", fn _ -> 1 end)
    {:ok, world} = cast.(world)
    assert "paralyzed" in Character.condition_names(world.characters["Cora"])
    {:ok, world} = World.begin_combat(["Goblin", "Cora"]).(world)
    {:ok, _} = Games.save_state(game.id, world, nil, world.round, :running)
    {roller, recorder} = tracked_roller(18)

    pid = start_game(game, :decision, roller)
    waiting_on_cora(pid)

    assert rolls(recorder) == [{20, 18}]
    refute "paralyzed" in Character.condition_names(Game.world(pid).characters["Cora"])
    assert Game.world(pid).characters["Goblin"].concentrating == nil
    [save] = dice_events(game.id)
    assert save.payload["who"] == "Cora"
    assert save.payload["total"] == 21
    assert save.payload["outcome"] == "success"
    assert save.payload["reason"] =~ "Inmovilizar persona"
  end

  test "reloading a paused turn preserves the aura result without rolling again" do
    game = guardians_game()
    {roller, recorder} = tracked_roller()
    pid = start_game(game, :decision, roller)
    waiting_on_cora(pid)
    assert rolls(recorder) == [{20, 2}, {8, 1}, {8, 1}, {8, 1}, {20, 2}]

    assert :ok = Game.pause(pid)
    before = Game.world(pid)
    events = dice_events(game.id)
    assert :ok = stop_supervised({Game, game.id})

    reloaded = start_game(game, :decision, roller)
    assert Game.status(reloaded) == :paused
    assert Game.world(reloaded) == before
    assert :ok = Game.resume(reloaded)
    waiting_on_cora(reloaded)

    assert Game.world(reloaded) == before
    assert dice_events(game.id) == events
    assert rolls(recorder) == [{20, 2}, {8, 1}, {8, 1}, {8, 1}, {20, 2}]
  end

  for narrator <- [:human_dm, :auto_pc] do
    test "#{narrator} receives the committed aura state and dice in its next request" do
      owner = self()

      observe = fn messages, _params ->
        context =
          Enum.map_join(messages, "\n", fn message ->
            Enum.map_join(message.parts, "\n", fn
              %{content: text} when is_binary(text) -> text
              _ -> ""
            end)
          end)

        if context =~ "97/100 pg", do: send(owner, {:factual_context, context})
        narration("Observa los espíritus a su alrededor.")
      end

      game = guardians_game()
      {roller, _recorder} = tracked_roller()
      model = %Test{script: List.duplicate(observe, 12)}
      pid = start_game(game, :decision, roller, model: model)
      waiting_on_cora(pid)

      case unquote(narrator) do
        :human_dm ->
          assert {:ok, :resolving} = Game.declare(pid, "Cora", "Observa los espíritus.")

        :auto_pc ->
          assert :ok = Game.enable_auto_play(pid, "Cora")
      end

      assert :ok = Game.pause(pid)
      assert_receive {:factual_context, context}, 2_000
      assert context =~ "97/100 pg"
      assert context =~ "[🎲 Goblin]"
      assert context =~ "salvación de Sabiduría contra Guardianes espirituales"
      assert context =~ "daño de Guardianes espirituales (radiante)"
      assert context =~ "salvación de Constitución (concentración)"
      assert :ok = Game.await(pid, fn _ -> :sys.get_state(pid).busy == nil end)
    end
  end
end
