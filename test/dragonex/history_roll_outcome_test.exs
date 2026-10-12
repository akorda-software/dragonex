defmodule Dragonex.HistoryRollOutcomeTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Archetypes, Dice, History, Monsters, RollLog, World}
  alias Dragonex.Games.GameEvent
  alias Dragonex.Test.ModelMessages

  defp attack(d20) do
    world =
      World.new(characters: %{"Thane" => Archetypes.fighter(), "goblin" => Monsters.goblin()})

    roller = fn
      20 -> d20
      _ -> 4
    end

    {:ok, recorder} = RollLog.start()

    try do
      log = %RollLog{base: roller, recorder: recorder}

      {:ok, _, change} =
        Actions.attack(world, "Thane", "goblin", "longsword", roller, :normal, log)

      {:ok, after_world} = change.(world)
      {RollLog.entries(recorder), after_world}
    after
      RollLog.stop(recorder)
    end
  end

  defp death_save(d20) do
    world = World.new(characters: %{"Thane" => %{Archetypes.fighter() | hp: 0}})
    roller = Dice.always(d20)
    {:ok, recorder} = RollLog.start()

    try do
      log = %RollLog{base: roller, recorder: recorder}
      {:ok, _, change} = Actions.death_save(world, "Thane", roller, log)
      {:ok, after_world} = change.(world)
      [entry] = RollLog.entries(recorder)
      {entry, after_world}
    after
      RollLog.stop(recorder)
    end
  end

  defp context(entry) do
    # Exercise both the engine's atom keys and the jsonb representation.
    for payload <- [entry, entry |> Jason.encode!() |> Jason.decode!()] do
      [%{"role" => "user", "content" => content}] =
        History.from_events([%GameEvent{type: :dice, actor: "dm", payload: payload}])
        |> ModelMessages.project()

      content
    end
  end

  test "a real critical attack and its doubled damage retain their confirmed outcome through JSON" do
    {[attack, damage], world} = attack(20)
    assert attack.outcome == :crit and damage.outcome == :crit
    assert attack.total == 25 and damage.total == 11
    assert damage.dice == [[8, 4], [8, 4]]
    assert world.characters["goblin"].hp == 0

    for line <- context(attack) ++ context(damage) do
      assert line =~ "[🎲 Thane]"
      assert String.ends_with?(line, "→ ¡CRÍTICO!")
      refute line =~ "¡ACIERTO!"
    end
  end

  test "one failed death save and the natural-one double failure stay distinct in shared history" do
    for {die, outcome, fails, label} <- [
          {2, :fail, 1, "→ fallo"},
          {1, :crit_fail, 2, "→ dos fallos de salvación de muerte"}
        ] do
      {entry, world} = death_save(die)
      assert entry.outcome == outcome
      assert world.characters["Thane"].death_saves.fails == fails

      for line <- context(entry) do
        assert line =~ "d20:#{die}"
        assert String.ends_with?(line, label)
      end
    end
  end

  test "ordinary hits, successful death saves and revival keep their own engine outcomes" do
    {[attack, _damage], _world} = attack(19)
    assert attack.outcome == :hit
    assert Enum.all?(context(attack), &String.ends_with?(&1, "→ ¡ACIERTO!"))

    for {die, outcome, label} <- [{10, :success, "→ éxito"}, {20, :revive, "→ ¡revive!"}] do
      {entry, world} = death_save(die)
      assert entry.outcome == outcome
      assert world.characters["Thane"].hp == if(die == 20, do: 1, else: 0)

      for line <- context(entry) do
        assert String.ends_with?(line, label)
        refute line =~ "¡CRÍTICO!"
      end
    end
  end
end
