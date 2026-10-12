defmodule Dragonex.GameAddressedIdentityTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Game, Games, Monsters, World}
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp tm(targets) do
    counter = start_supervised!({Agent, fn -> 0 end})

    script =
      for target <- targets,
          step <- [
            fn _, _ ->
              Agent.update(counter, &(&1 + 1))
              tool_calls([call("give_turn_to", %{"participant" => target})])
            end,
            "listo"
          ],
          do: step

    {%Test{script: script}, counter}
  end

  defp game(roster, opts \\ []) do
    {:ok, game} =
      Games.create_game(
        title: "Una pregunta bien dirigida",
        roster: roster,
        scene: "Una sala tranquila."
      )

    world = Games.load_world(game)
    world = Keyword.get(opts, :change, fn w -> w end).(world)
    {:ok, _} = Games.save_state(game.id, world, Keyword.get(opts, :current), world.round, :paused)
    {game, world}
  end

  defp boot(game, script, tm) do
    Dragonex.Test.GameFixture.start!(
      {Game, {game.id, [model: %Test{script: script}, turnmaster_model: tm]}}
    )
  end

  defp wait(pid, name) do
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == name), 5_000)
    assert :ok == Game.pause(pid)
  end

  test "a short-name opening gives the full human name the floor with no TM request" do
    name = "Sylvi del Roble"

    {game, before} =
      game([
        {Archetypes.fighter(name: name), :human},
        {Archetypes.wizard(), :ai},
        {Archetypes.rogue(), :ai}
      ])

    {tm, counter} = tm(["Lyra", name])

    pid =
      boot(
        game,
        [narration("Sylvi, ¿qué quieres observar?"), narration("La sala sigue tranquila.")],
        tm
      )

    assert :ok == Game.resume(pid)
    wait(pid, name)
    assert Agent.get(counter, & &1) == 0
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
  end

  test "a question to another human's short name outranks the previous human speaker" do
    iria = "Iria del Alba"
    mara = "Mara del Río"

    {game, before} =
      game(
        [
          {Archetypes.fighter(name: iria), :human},
          {Archetypes.wizard(name: mara), :human}
        ],
        current: iria
      )

    {tm, counter} = tm([iria])

    pid =
      boot(
        game,
        [narration("Miro el pergamino."), narration("Mara, ¿qué prefieres observar?")],
        tm
      )

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == iria))
    assert {:ok, :resolving} = Game.declare(pid, iria, "Miro el pergamino sin abrirlo.")
    wait(pid, mara)
    assert Agent.get(counter, & &1) == 0
    assert Game.world(pid) == before
    assert Games.get_game(game.id).current_participant == mara
  end

  test "a registered NPC with a human prefix does not steal the floor for that human" do
    {game, before} =
      game([
        {Archetypes.fighter(), :human},
        {Archetypes.wizard(), :human},
        {Monsters.bandit(name: "Lyra del Muelle"), :ai}
      ])

    {tm, counter} = tm(["Thane"])
    pid = boot(game, [narration("Lyra del Muelle, ¿qué sabes del camino?")], tm)
    assert :ok == Game.resume(pid)
    wait(pid, "Thane")
    assert Agent.get(counter, & &1) == 1
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
  end

  test "an incapacitated addressed human is not forced ahead of an available player" do
    {game, before} =
      game(
        [
          {Archetypes.fighter(), :human},
          {Archetypes.wizard(), :human}
        ],
        change: fn world -> elem(World.set_conditions("Thane", ["stunned"]).(world), 1) end
      )

    {tm, counter} = tm(["Lyra"])
    pid = boot(game, [narration("Thane, ¿qué quieres observar?")], tm)
    assert :ok == Game.resume(pid)
    wait(pid, "Lyra")
    assert Agent.get(counter, & &1) == 1
    assert Game.world(pid) == before
  end

  test "a generic reply remembers the last human through hundreds of intervening events" do
    {game, before} = game([{Archetypes.fighter(), :human}], current: "Thane")
    game_id = game.id
    {tm, counter} = tm(["Thane"])

    reply = fn _, _ ->
      for _ <- 1..220 do
        {:ok, _} =
          Games.append_event(game_id, :system, "system", "all", %{
            note: "La sala sigue tranquila."
          })
      end

      narration("Ábrelo tú, si quieres.")
    end

    pid = boot(game, [narration("Miro el pergamino."), reply], tm)
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Miro el pergamino sin abrirlo.")
    wait(pid, "Thane")
    assert Agent.get(counter, & &1) == 0
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
  end
end
