defmodule Dragonex.LocalSceneReviewTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, World, WorldClock}
  alias Dragonex.Game.SceneRefresh
  alias ExAgent.Models.Test

  test "only literal first-person movement to a place requests a scene review" do
    for text <- [
          "Entro en la taberna.",
          "Yo salgo al patio.",
          "Me acerco a la barra.",
          "Cruzo por el puente.",
          "Me despido de la posadera, bajo al patio.",
          "Agradezco a Maribel su invitación, entro en la taberna del Ciervo."
        ] do
      assert SceneRefresh.movement_declared?(text), text
    end
  end

  test "mentions, quotes, negations, plans, questions and others' actions do not request that review" do
    for text <- [
          nil,
          "",
          "No entro en la taberna.",
          "Si me invitan, entro en la taberna.",
          "Quiero entrar en la taberna.",
          "¿Entro en la taberna?",
          "Vex entra en la taberna.",
          "Le digo a Vex: «Entro en la taberna». Espero su opinión.",
          "Observo la puerta.",
          "Lyra, ¿entramos en la taberna?",
          "Entramos en la taberna."
        ] do
      refute SceneRefresh.movement_declared?(text), inspect(text)
    end
  end

  test "an optional local review can confirm unchanged surroundings without a write" do
    world = World.new(scene: "La plaza.", characters: %{"Thane" => Archetypes.fighter()})
    model = %Test{script: [tool_calls([call("final_result", %{"scene" => world.scene})])]}
    assert :skip == SceneRefresh.propose(model, world, [], allow_unchanged: true)
  end

  test "confirmation cannot clear an already pending engine change" do
    world =
      World.new(scene: "La plaza.", characters: %{"Thane" => Archetypes.fighter()})
      |> WorldClock.advance(3600)

    model = %Test{script: [tool_calls([call("final_result", %{"scene" => world.scene})])]}

    assert {:error, :unchanged_scene} ==
             SceneRefresh.propose(model, world, [], allow_unchanged: true)

    assert world.scene_refresh_pending
  end
end
