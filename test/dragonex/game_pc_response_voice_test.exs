defmodule Dragonex.GamePCResponseVoiceTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness, only: [narration: 1]
  alias Dragonex.{Archetypes, Game, Games, Text}
  alias ExAgent.{Models.Test, Server}
  alias Dragonex.Test.ModelMessages

  @question "Lyra y Vex, ¿qué os apetece de la invitación de Maribel: guiso con pan y una jarra, o preferís otra cosa? Yo acepto el guiso y la jarra para mí; sigo junto a la barra."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "the next companion receives its own voice contract while retaining the predecessor's real choice" do
    {:ok, game} =
      Games.create_game(
        title: "Cada compañero elige su comida",
        scene: "El interior de la taberna junto a la barra.",
        roster: [
          {Archetypes.fighter(name: "Mara de la Bruma"), :human},
          {Archetypes.wizard(), :ai},
          {Archetypes.rogue(), :ai}
        ]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Mara de la Bruma", before.round, :paused)
    parent = self()

    model = %Test{
      script: [
        narration("—Para mí, guiso y jarra. ¿Qué os apetece?"),
        narration("Maribel sirve los cuencos prometidos.")
      ]
    }

    tm = %Test{
      script: [
        fn _, _ ->
          send(parent, :voice_tm_requested)
          "(no decision)"
        end
      ]
    }

    pid =
      Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model, turnmaster_model: tm]}})

    state = :sys.get_state(pid)

    answers =
      for actor <- ["Lyra", "Vex"], into: %{} do
        raw =
          File.read!(
            Path.expand(
              "../fixtures/narration/pc_#{String.downcase(actor)}_meal_answer.txt",
              __DIR__
            )
          )
          |> String.trim()

        {actor, raw}
      end

    for {actor, answer} <- answers do
      callback = fn messages, _ ->
        send(parent, {:voice_request, actor, ModelMessages.project(messages)})
        narration(answer)
      end

      assert :ok == Server.set_model(state.pc_agents[actor], %Test{script: [callback]})
    end

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Mara de la Bruma"))
    assert {:ok, :resolving} == Game.declare(pid, "Mara de la Bruma", @question)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Mara de la Bruma"))
    assert :ok == Game.pause(pid)
    assert_receive {:voice_request, "Lyra", lyra}
    assert_receive {:voice_request, "Vex", vex}

    for {actor, wire, trait} <- [
          {"Lyra", lyra, "curioso, metódico"},
          {"Vex", vex, "astuto, sigiloso"}
        ] do
      assert [%{"role" => "system", "content" => role} | _] = wire
      assert role =~ "Eres #{actor},"

      prompt =
        wire |> Enum.filter(&(&1["role"] == "user")) |> List.last() |> Map.fetch!("content")

      assert prompt =~ "Voz de #{actor}: Eres #{trait}"
      assert prompt =~ "Puedes coincidir con su elección"
      assert prompt =~ "No copies sus frases ni sus gestos"
      assert prompt =~ @question
    end

    assert Enum.any?(vex, &ModelMessages.imported?(&1, answers["Lyra"]))
    events = Games.list_events(game.id)
    narrations = Enum.filter(events, &(&1.type == :narration and &1.payload["turn_id"] != nil))
    assert Enum.map(narrations, & &1.actor) == ["Mara de la Bruma", "Lyra", "Vex", "dm"]

    for {actor, raw} <- answers do
      expected =
        Text.scrub(raw, actor,
          pc_names: ["Mara de la Bruma", "Lyra", "Vex"],
          character_names: ["Mara de la Bruma", "Lyra", "Vex"]
        )

      assert Enum.count(narrations, &(&1.actor == actor and &1.payload["text"] == expected)) == 1
    end

    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    refute Enum.any?(events, &(&1.type == :dice))
    refute_received :voice_tm_requested
  end
end
