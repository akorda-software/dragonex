defmodule Dragonex.GameSceneAgencyTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Game, Games, History, Monsters}
  alias ExAgent.{Models.Test, Server}

  @hero "Sylvi del Roble"
  @sample File.read!(Path.expand("../fixtures/narration/dm_roble_collective_move.txt", __DIR__))
  @scene File.read!(Path.expand("../fixtures/narration/scene_roble_collective_move.txt", __DIR__))
  @decision File.read!(
              Path.expand("../fixtures/narration/dm_granero_group_decision.txt", __DIR__)
            )

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp game(extra \\ []) do
    {:ok, game} =
      Games.create_game(
        title: "El grupo decide por sí mismo",
        scene: "Una sala con una ventana hacia el roble.",
        roster:
          [
            {Archetypes.fighter(name: @hero), :human},
            {Archetypes.wizard(), :ai},
            {Archetypes.rogue(), :ai}
          ] ++ extra
      )

    {game, Games.load_world(game)}
  end

  defp wait(pid) do
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == @hero), 5_000)
    assert :ok == Game.pause(pid)
  end

  defp scene_feedback(messages) do
    feedback =
      for %{parts: parts} <- messages,
          %{tool_name: "set_scene", content: content} <- parts,
          do: content

    inspect(feedback, limit: :infinity, printable_limit: :infinity)
  end

  defp fact_feedback(messages) do
    inspect(
      for %{parts: parts} <- messages,
          %{tool_name: "establish_fact", content: content} <- parts,
          do: content
    )
  end

  test "the real collective scene is rejected before World, log and conversation can change" do
    {game, before} = game()
    parent = self()

    model = %Test{
      script: [
        tool_calls([call("set_scene", %{"narration" => @scene})]),
        fn messages, _ ->
          send(
            parent,
            {:scene_feedback, scene_feedback(messages)}
          )

          narration(@sample <> " #{@hero}, ¿qué quieres observar?")
        end
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    wait(pid)
    assert_receive {:scene_feedback, feedback}
    assert feedback =~ "RECHAZADO"
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before

    history = History.from_events(Games.list_events(game.id)) |> inspect(limit: :infinity)
    refute history =~ "El grupo cruza el umbral"
    refute history =~ "Decidís cruzar el umbral"
    refute history =~ "al acercaros"
    assert history =~ "El arrendajo os espera"
    assert history =~ "colgante de piedra"
    refute Enum.any?(Games.list_events(game.id), &(&1.type == :dice))
    assert :ok == stop_supervised({Game, game.id})

    reopened =
      Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{label: "quietud"}]}})

    assert Game.snapshot(reopened).status == :paused
    assert Game.world(reopened) == before
  end

  test "an NPC group and a full NPC name sharing a PC prefix remain legitimate scene text" do
    npc = Monsters.bandit(name: "Lyra del Muelle")
    {game, before} = game([{npc, :ai}])

    scene =
      "El grupo de guardias cruza el puente. Lyra del Muelle abre la ventana. El jefe queda en 3/7 pg."

    model = %Test{
      script: [
        tool_calls([call("set_scene", %{"narration" => scene})]),
        narration("#{@hero}, ¿qué quieres observar?")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    wait(pid)
    world = Game.world(pid)
    assert world.scene =~ "El grupo de guardias cruza el puente"
    assert world.scene =~ "Lyra del Muelle abre la ventana"
    refute world.scene =~ "3/7"
    assert Map.drop(world, [:scene, :log]) == Map.drop(before, [:scene, :log])
    assert Games.load_world(Games.get_game(game.id)) == world
  end

  test "a passive group decision cannot become the scene or its shared history" do
    {game, before} = game()
    parent = self()

    model = %Test{
      script: [
        tool_calls([call("set_scene", %{"narration" => @decision})]),
        fn messages, _ ->
          send(parent, {:decision_feedback, scene_feedback(messages)})
          narration(@decision <> " #{@hero}, ¿qué quieres observar?")
        end
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    wait(pid)
    assert_receive {:decision_feedback, feedback}
    assert feedback =~ "RECHAZADO"
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    history = History.from_events(Games.list_events(game.id)) |> inspect(limit: :infinity)
    refute history =~ "La decisión queda tomada"
    assert history =~ "la posadera sacude un trapo"
    refute Enum.any?(Games.list_events(game.id), &(&1.type == :dice))
  end

  test "a group decision cannot bypass scene protection through a durable fact" do
    {game, before} = game()
    parent = self()

    model = %Test{
      script: [
        tool_calls([call("establish_fact", %{"fact" => @decision})]),
        fn messages, _ ->
          send(parent, {:fact_feedback, fact_feedback(messages)})
          narration("#{@hero}, ¿qué quieres observar?")
        end
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    wait(pid)
    assert_receive {:fact_feedback, feedback}
    assert feedback =~ "RECHAZADO"
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    refute Enum.any?(Games.list_events(game.id), &(&1.type == :dice))
  end

  test "human movement keeps its literal declaration while the DM confirms the canonical surroundings" do
    {game, before} = game()
    {:ok, _} = Games.save_state(game.id, before, @hero, before.round, :paused)
    scene = "#{@hero} se acerca a la ventana. Lyra y Vex permanecen junto a la mesa."
    confirmed = "La ventana deja ver el roble. Lyra y Vex permanecen junto a la mesa."
    parent = self()

    model = %Test{
      script: [
        tool_calls([call("set_scene", %{"narration" => scene})]),
        fn messages, _ ->
          send(parent, {:own_scene_feedback, scene_feedback(messages)})
          narration("Me acerco a la ventana y miro el roble.")
        end,
        tool_calls([call("set_scene", %{"narration" => confirmed})]),
        narration("#{@hero}, ¿qué quieres observar?")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == @hero))

    assert {:ok, :resolving} =
             Game.declare(pid, @hero, "Me acerco a la ventana sin mover a mis compañeros.")

    wait(pid)
    assert_receive {:own_scene_feedback, feedback}
    assert feedback =~ "RECHAZADO — solo el DM"
    world = Game.world(pid)
    assert world.scene == confirmed
    assert Map.drop(world, [:scene, :log]) == Map.drop(before, [:scene, :log])
    assert Games.load_world(Games.get_game(game.id)) == world

    assert Enum.any?(Games.list_events(game.id), fn e ->
             e.type == :narration and e.actor == @hero and
               e.payload["text"] == "Me acerco a la ventana sin mover a mis compañeros." and
               e.payload["kind"] == "human_declaration"
           end)

    refute inspect(Games.list_events(game.id), limit: :infinity) =~
             "Me acerco a la ventana y miro el roble."
  end

  test "an acting PC cannot put another named PC's action into the canonical scene" do
    {game, before} = game()
    {:ok, _} = Games.save_state(game.id, before, @hero, before.round, :paused)
    parent = self()

    model = %Test{
      script: [
        tool_calls([
          call("set_scene", %{"narration" => "Lyra se acerca al roble. La posada está en calma."})
        ]),
        fn messages, _ ->
          send(parent, {:foreign_scene_feedback, scene_feedback(messages)})
          narration("Miro la ventana sin moverme.")
        end,
        narration("#{@hero}, ¿qué quieres observar?")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == @hero))
    assert {:ok, :resolving} = Game.declare(pid, @hero, "Miro la ventana sin moverme.")
    wait(pid)
    assert_receive {:foreign_scene_feedback, feedback}
    assert feedback =~ "RECHAZADO"
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
  end

  test "empty scene text is rejected without clearing the current surroundings" do
    {game, before} = game()
    parent = self()

    model = %Test{
      script: [
        tool_calls([call("set_scene", %{"narration" => " \n\t "})]),
        fn messages, _ ->
          send(parent, {:empty_scene_feedback, scene_feedback(messages)})
          narration("#{@hero}, ¿qué quieres observar?")
        end
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    wait(pid)
    assert_receive {:empty_scene_feedback, feedback}
    assert feedback =~ "RECHAZADO"
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
  end

  test "a scene may contain an NPC invitation to a named PC without treating it as their action" do
    {game, before} = game([{Monsters.bandit(name: "Sena"), :ai}])

    scene =
      "Sena pregunta: «¿Lyra abre la ventana o prefiere esperar?».\nLa sala sigue tranquila."

    model = %Test{
      script: [
        tool_calls([call("set_scene", %{"narration" => scene})]),
        narration("#{@hero}, ¿qué quieres observar?")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    wait(pid)
    world = Game.world(pid)
    assert world.scene == scene
    assert Map.drop(world, [:scene, :log]) == Map.drop(before, [:scene, :log])
    assert Games.load_world(Games.get_game(game.id)) == world
  end

  test "rejecting a scene preserves an already registered question and both companion responses" do
    {game, before} = game()
    {:ok, _} = Games.save_state(game.id, before, @hero, before.round, :paused)
    parent = self()

    model = %Test{
      script: [
        tool_calls([
          call("request_response", %{
            "recipients" => ["Lyra", "Vex"],
            "question" => "¿Qué observaríais en esta sala?"
          })
        ]),
        tool_calls([call("set_scene", %{"narration" => @scene})]),
        fn messages, _ ->
          send(parent, {:question_after_scene, self(), scene_feedback(messages)})

          receive do
            :continue -> narration("—¿Qué observaríais en esta sala?")
          after
            5_000 -> raise "question was not released"
          end
        end,
        narration("La sala sigue tranquila.")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    state = :sys.get_state(pid)

    for {name, answer} <- [{"Lyra", "—Observaría la jarra."}, {"Vex", "—Yo miraría la ventana."}] do
      assert :ok == Server.set_model(state.pc_agents[name], %Test{script: [narration(answer)]})
    end

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == @hero))

    assert {:ok, :resolving} =
             Game.declare(pid, @hero, "Pregunto a Lyra y Vex qué observarían en la sala.")

    assert_receive {:question_after_scene, model_pid, feedback}, 1_000

    try do
      assert feedback =~ "RECHAZADO"
      world = Game.world(pid)
      assert world.conversation["pending"] == ["Lyra", "Vex"]

      assert Map.drop(world, [:conversation, :actor_checkpoint]) ==
               Map.drop(before, [:conversation, :actor_checkpoint])

      assert world.actor_checkpoint["actor"] == @hero
      assert Enum.all?(world.actor_checkpoint["tools"], &(&1["name"] == "request_response"))
    after
      send(model_pid, :continue)
    end

    wait(pid)
    turns = Games.list_events(game.id) |> Enum.filter(&(&1.type == :turn)) |> Enum.map(& &1.actor)
    assert turns == [@hero, "Lyra", "Vex", "dm"]
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
  end

  test "an implicit plural approach is rejected before the current scene and resources change" do
    {game, before} = game()
    parent = self()

    model = %Test{
      script: [
        tool_calls([
          call("set_scene", %{"narration" => "Al acercaros al roble, el pájaro canta."})
        ]),
        fn messages, _ ->
          send(parent, {:implicit_scene_feedback, scene_feedback(messages)})
          narration("#{@hero}, ¿qué quieres observar desde la sala?")
        end
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    wait(pid)
    assert_receive {:implicit_scene_feedback, feedback}
    assert feedback =~ "RECHAZADO"
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    assert :ok == stop_supervised({Game, game.id})

    reopened =
      Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{label: "quietud"}]}})

    assert Game.world(reopened) == before
  end

  test "an NPC invitation about approaching remains a legitimate scene without moving PCs" do
    {game, before} = game([{Monsters.bandit(name: "Sena"), :ai}])
    scene = "Sena dice: «Al acercaros al roble, veréis el nido». La ventana sigue cerrada."

    model = %Test{
      script: [
        tool_calls([call("set_scene", %{"narration" => scene})]),
        narration("#{@hero}, ¿qué quieres observar?")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    wait(pid)
    world = Game.world(pid)
    assert world.scene == scene
    assert Map.drop(world, [:scene, :log]) == Map.drop(before, [:scene, :log])
    assert Games.load_world(Games.get_game(game.id)) == world
  end

  test "an object pronoun cannot commit another PC's nod through the scene tool" do
    {game, before} = game()
    parent = self()
    scene = "#{@hero} las recoge en silencio, asintiendo apenas, y el calor llega de la cocina."

    model = %Test{
      script: [
        tool_calls([call("set_scene", %{"narration" => scene})]),
        fn messages, _ ->
          send(parent, {:clitic_scene_feedback, scene_feedback(messages)})
          narration("#{@hero}, ¿qué quieres observar?")
        end
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    wait(pid)
    assert_receive {:clitic_scene_feedback, feedback}
    assert feedback =~ "RECHAZADO"
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    assert :ok == stop_supervised({Game, game.id})
    reopened = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{}]}})
    assert Game.world(reopened) == before
  end

  test "the same pronoun action by an NPC remains a legitimate scene" do
    {game, before} = game([{Monsters.bandit(name: "Sena"), :ai}])
    scene = "Sena las recoge en silencio, asintiendo apenas, y el calor llega de la cocina."

    model = %Test{
      script: [
        tool_calls([call("set_scene", %{"narration" => scene})]),
        narration("#{@hero}, ¿qué quieres observar?")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    wait(pid)
    world = Game.world(pid)
    assert world.scene == scene
    assert Map.drop(world, [:scene, :log]) == Map.drop(before, [:scene, :log])
    assert Games.load_world(Games.get_game(game.id)) == world
  end
end
