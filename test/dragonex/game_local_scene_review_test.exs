defmodule Dragonex.GameLocalSceneReviewTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games, History}
  alias ExAgent.{Models.Test, Server}

  @human "Mara de la Bruma"
  @old "La plaza del pueblo, junto a la puerta de la taberna del Ciervo."
  @inside "El interior de la taberna del Ciervo. Una barra de madera, estantes de botellas y un caldero de guiso ocupan la sala."
  @action "Agradezco a Maribel su invitación, entro en la taberna del Ciervo y me acerco a la barra. Me detengo allí para mirar qué ofrece el lugar."
  @human_entry File.read!(Path.expand("../fixtures/narration/human_tavern_entry.txt", __DIR__))
               |> String.trim()
  @dm_entry File.read!(Path.expand("../fixtures/narration/dm_tavern_entry.txt", __DIR__))
            |> String.trim()

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp boot(script, scene_model, current \\ @human) do
    {:ok, game} =
      Games.create_game(
        title: "La taberna después de entrar",
        scene: @old,
        roster: [{Archetypes.fighter(name: @human), :human}, {Archetypes.rogue(), :ai}]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, current, before.round, :paused)
    tm = %Test{script: [tool_calls([call("give_turn_to", %{"participant" => @human})])]}

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id, [model: %Test{script: script}, scene_model: scene_model, turnmaster_model: tm]}}
      )

    {game, pid, before}
  end

  defp act(pid, action) do
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == @human and &1.status == :waiting))
    assert {:ok, :resolving} == Game.declare(pid, @human, action)
    wait(pid)
  end

  defp wait(pid) do
    assert :ok == Game.await(pid, &(&1.current == @human and &1.status == :waiting), 5_000)
    assert :ok == Game.pause(pid)
  end

  test "the real tavern entry is recorded after the DM omits set_scene, without repeating narration or rules" do
    parent = self()

    recorder = %Test{
      script: [
        fn messages, params ->
          send(
            parent,
            {:local_scene_request, inspect(messages, limit: :infinity), params.function_tools}
          )

          tool_calls([call("final_result", %{"scene" => @inside})])
        end
      ]
    }

    {game, pid, before} = boot([narration(@human_entry), narration(@dm_entry)], recorder)
    initial_events = Games.list_events(game.id)
    act(pid, @action)
    assert_receive {:local_scene_request, context, []}
    assert context =~ @action
    refute context =~ @human_entry
    assert context =~ @dm_entry
    world = Game.world(pid)
    assert world.scene == @inside
    assert Map.drop(world, [:scene, :log]) == Map.drop(before, [:scene, :log])
    assert Games.load_world(Games.get_game(game.id)) == world
    events = Games.list_events(game.id)
    added = Enum.drop(events, length(initial_events))
    assert Enum.map(Enum.filter(added, &(&1.type == :narration)), & &1.actor) == [@human, "dm"]

    assert [%{payload: %{"text" => @action, "kind" => "human_declaration"}}] =
             Enum.filter(added, &(&1.type == :narration and &1.actor == @human))

    refute Enum.any?(events, &(&1.type == :dice))
    assert inspect(History.from_events(events), limit: :infinity) =~ @dm_entry
    assert :ok == stop_supervised({Game, game.id})
    reopened = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{}]}})
    assert Game.world(reopened) == world
    assert Game.current(reopened) == @human
    assert Game.status(reopened) == :paused
    assert Games.list_events(game.id) == events
  end

  test "a failed review leaves a durable pending scene and the completed human and DM speech intact" do
    {game, pid, before} =
      boot([narration(@human_entry), narration(@dm_entry)], %Test{
        label: "Sin resultado estructurado."
      })

    initial_events = Games.list_events(game.id)
    act(pid, @action)
    world = Game.world(pid)
    assert world.scene_refresh_pending
    assert Map.delete(world, :scene_refresh_pending) == Map.delete(before, :scene_refresh_pending)
    events = Games.list_events(game.id)

    assert length(
             Enum.filter(Enum.drop(events, length(initial_events)), &(&1.type == :narration))
           ) == 2

    assert Games.load_world(Games.get_game(game.id)) == world
    assert :ok == stop_supervised({Game, game.id})
    reopened = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{}]}})
    assert Game.world(reopened) == world
    assert Games.list_events(game.id) == events
  end

  test "confirming the same surroundings performs no World write or pending review" do
    parent = self()

    recorder = %Test{
      script: [
        fn _, _ ->
          send(parent, :same_surroundings_checked)
          tool_calls([call("final_result", %{"scene" => @old})])
        end
      ]
    }

    {game, pid, before} =
      boot([narration("Me acerco a la puerta."), narration("La puerta sigue cerrada.")], recorder)

    act(pid, "Me acerco a la puerta, sin cruzarla.")
    assert_receive :same_surroundings_checked
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
  end

  test "an explicit DM record, even of the same scene, needs no extra request" do
    parent = self()

    recorder = %Test{
      script: [
        fn _, _ ->
          send(parent, :unexpected_local_record)
          "Unused"
        end
      ]
    }

    {_, pid, _} =
      boot(
        [
          narration("Me acerco a la puerta."),
          tool_calls([call("set_scene", %{"narration" => @old})]),
          narration("La puerta sigue cerrada.")
        ],
        recorder
      )

    act(pid, "Me acerco a la puerta, sin cruzarla.")
    refute_received :unexpected_local_record
    refute Game.world(pid).scene_refresh_pending
  end

  test "questions and observations do not activate local movement review" do
    parent = self()

    recorder = %Test{
      script: [
        fn _, _ ->
          send(parent, :unexpected_local_record)
          "Unused"
        end
      ]
    }

    {_, pid, before} =
      boot(
        [
          narration("La tabernera indica el precio."),
          narration("Observo el letrero."),
          narration("El letrero muestra una cornamenta.")
        ],
        recorder
      )

    act(pid, "Le pregunto a la tabernera: «¿Cuánto cuesta el guiso?» Espero aquí.")
    act(pid, "Observo el letrero desde la plaza.")
    refute_received :unexpected_local_record
    assert Game.world(pid) == before
  end

  test "a DM's already committed scene change is preserved without another record" do
    parent = self()

    recorder = %Test{
      script: [
        fn _, _ ->
          send(parent, :unexpected_local_record)
          "Unused"
        end
      ]
    }

    {_, pid, before} =
      boot(
        [
          narration(@human_entry),
          tool_calls([call("set_scene", %{"narration" => @inside})]),
          narration(@dm_entry)
        ],
        recorder
      )

    act(pid, @action)
    refute_received :unexpected_local_record
    assert Game.world(pid).scene == @inside
    assert Map.drop(Game.world(pid), [:scene, :log]) == Map.drop(before, [:scene, :log])
  end

  test "a companion's movement keeps its existing scene and orchestration path" do
    parent = self()

    recorder = %Test{
      script: [
        fn _, _ ->
          send(parent, :unexpected_local_record)
          "Unused"
        end
      ]
    }

    {_, pid, before} = boot([narration("La puerta sigue abierta.")], recorder, "Vex")

    assert :ok ==
             Server.set_model(:sys.get_state(pid).pc_agents["Vex"], %Dragonex.Test.Narrator{
               text: "Me acerco a la puerta."
             })

    assert :ok == Game.resume(pid)
    wait(pid)
    refute_received :unexpected_local_record
    assert Game.world(pid) == before
  end
end
