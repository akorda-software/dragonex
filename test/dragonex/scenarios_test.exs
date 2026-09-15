defmodule Dragonex.ScenariosTest do
  @moduledoc """
  AC-10.1: cada escenario predefinido (`Scenarios.all`) arranca una partida
  con su story bible horneada en el system prompt del DM (D20).

  Dos eslabones de la misma cadena: el wizard persiste la biblia del
  escenario en `games.story_bible`, y `DM.new/2` (lo que `Game.Bootstrap`
  construye al arrancar) la cuece en las instrucciones del agente vía
  `DM.system_prompt/1`.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{DM, Games, Scenarios}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragonex.Repo)
    :ok
  end

  test "Scenarios.all expone los escenarios con biblia completa" do
    scenarios = Scenarios.all()
    assert length(scenarios) >= 5

    for scenario <- scenarios do
      assert is_binary(scenario.key) and scenario.key != ""
      assert is_binary(scenario.title) and scenario.title != ""
      assert is_binary(scenario.scene) and scenario.scene != ""
      assert is_binary(scenario.hook) and scenario.hook != ""
      assert is_binary(scenario.tone) and scenario.tone != ""
      assert is_binary(scenario.npcs) and scenario.npcs != ""
      assert is_binary(scenario.locations) and scenario.locations != ""
      assert scenario.suggested_enemies != []
    end
  end

  test "AC-10.1: cada escenario arranca una partida con su biblia en el system prompt" do
    for scenario <- Scenarios.all() do
      # La vía real del wizard: crear la partida desde la selección de escenario.
      assert {:ok, game} =
               Games.create_from_wizard_choices(%{
                 scenario: Scenarios.get(scenario.key),
                 my_hero: "fighter",
                 companions: [],
                 dice_engine: "2d",
                 user_id: nil
               }),
             "el escenario #{scenario.key} no pudo arrancar la partida"

      bible = Scenarios.bible(scenario)

      # Eslabón 1: la biblia del escenario queda persistida en la partida
      # (y su escena, en el world).
      assert game.title == scenario.title
      assert Games.load_world(game).scene == scenario.scene

      for key <- ~w(hook tone npcs locations enemies) do
        assert game.story_bible[key] == bible[key],
               "la biblia de #{scenario.key} perdió #{key} al crear la partida"
      end

      # Eslabón 2 (D20): el DM cuece la biblia en su system prompt —
      # exactamente lo que Game.Bootstrap pasa a DM.new/2 al arrancar.
      assert DM.system_prompt(game.story_bible) =~ scenario.hook
      assert DM.system_prompt(game.story_bible) =~ scenario.tone
      assert DM.system_prompt(game.story_bible) =~ scenario.npcs
      assert DM.system_prompt(game.story_bible) =~ scenario.locations
      assert DM.system_prompt(game.story_bible) =~ "BIBLIA DE LA CAMPAÑA"

      # …y el agente construido la lleva como instrucción estable (prefijo
      # cacheable, no por-turno).
      agent = DM.new(%ExAgent.Models.Test{}, story_bible: game.story_bible)
      [%ExAgent.Message.Part.System{content: prompt}] = agent.instructions
      assert prompt =~ scenario.hook
      assert prompt =~ scenario.npcs
    end
  end
end
