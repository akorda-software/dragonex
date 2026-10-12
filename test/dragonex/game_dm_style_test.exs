defmodule Dragonex.GameDMStyleTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Dragonex.{DM, Game, Games, Scenarios}
  alias ExAgent.{Message, Models.Test}
  alias Dragonex.Test.ModelMessages

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp observe(stage) do
    parent = self()

    callback = fn messages, _ ->
      [%{"role" => "system", "content" => prompt} | _] = ModelMessages.project(messages)
      send(parent, {:style_request, stage, prompt})
      Dragonex.Test.Harness.narration("La sala está en calma. ¿Qué quieres hacer?")
    end

    %Test{script: List.duplicate(callback, 4)}
  end

  defp waiting(pid), do: Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))

  test "a custom wizard style reaches the DM request and survives paused rehydration" do
    style =
      String.duplicate("Conserva dudas y decisiones propias, sin adornar cada respuesta.\n", 8) <>
        "Cálido y breve.\nMantén la escena tranquila y evita amenazas no solicitadas."

    {:ok, game} =
      Games.create_from_wizard_choices(%{
        scenario: %{key: "custom"},
        my_hero: "fighter",
        companions: [],
        custom_title: "Ritmo propio",
        custom_scene: "una sala tranquila",
        custom_dm_style: style
      })

    assert game.dm_style == style
    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: observe(:initial)]}})
    assert :ok = waiting(pid)
    assert_receive {:style_request, :initial, prompt}
    assert prompt =~ "ESTILO DE ESTA PARTIDA"
    assert prompt =~ style
    assert prompt =~ "NUNCA decides tú el resultado"
    assert :ok = Game.pause(pid)
    before = Game.world(pid)
    assert :ok = stop_supervised({Game, game.id})
    reopened = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: observe(:reopened)]}})
    assert Game.snapshot(reopened).status == :paused
    assert Game.world(reopened) == before
    assert :ok = Game.resume(reopened)
    assert :ok = waiting(reopened)

    assert {:ok, :resolving} =
             Game.declare(reopened, "Thane", "Compruebo cómo seguimos, sin descansar ni moverme.")

    assert :ok = waiting(reopened)
    assert_receive {:style_request, :reopened, reopened_prompt}
    assert reopened_prompt == prompt
    assert :ok = Game.pause(reopened)
    assert Game.world(reopened) == before
    assert Games.load_world(Games.get_game(game.id)) == before
  end

  test "each preset scenario sends its persisted style with its campaign bible" do
    for scenario <- Scenarios.all() do
      {:ok, game} =
        Games.create_from_wizard_choices(%{
          scenario: scenario,
          my_hero: "fighter",
          companions: []
        })

      assert game.dm_style == scenario.dm_style
      pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: observe(scenario.key)]}})
      assert :ok = waiting(pid)
      key = scenario.key
      assert_receive {:style_request, ^key, prompt}
      assert prompt =~ scenario.dm_style
      assert prompt =~ scenario.hook
      assert prompt =~ scenario.npcs
      assert prompt =~ "BIBLIA DE LA CAMPAÑA"
      assert :ok = Game.pause(pid)
    end
  end

  test "blank or unsupported legacy style values keep the default prompt and shared-history delivery" do
    for style <- [nil, "", " \n\t ", %{}, [:unknown]] do
      agent = DM.new(%Dragonex.Test.Narrator{text: "La sala sigue en calma."}, dm_style: style)

      assert Enum.map_join(agent.instructions, & &1.content) ==
               DM.system_prompt() <> "\n\n" <> Dragonex.Narration.Contract.instruction()

      history = [
        Message.new_request([%Message.Part.User{content: "La sala tiene un roble dibujado."}])
      ]

      assert {:ok, _} = ExAgent.run(agent, "Continúa.", message_history: history)
    end
  end
end
