defmodule Dragonex.PCResponseVoiceTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Archetypes, Conversation, PCAgent, World}

  defp asked do
    world =
      World.new(
        characters: %{
          "Thane" => Archetypes.fighter(),
          "Lyra" => Archetypes.wizard(),
          "Vex" => Archetypes.rogue()
        }
      )

    {:ok, world} =
      Conversation.request("Thane", ["Lyra", "Vex"], "¿Qué os apetece comer?").(world)

    world
  end

  test "response context anchors each voice and allows agreement without copying another speaker" do
    world = asked()
    lyra = PCAgent.instruction("Lyra", world.characters["Lyra"], world)
    {:ok, next} = Conversation.finish_actor("Lyra").(world)
    vex = PCAgent.instruction("Vex", next.characters["Vex"], next)

    assert lyra =~ "Voz de Lyra: Eres curioso, metódico"
    assert vex =~ "Voz de Vex: Eres astuto, sigiloso"

    for instruction <- [lyra, vex] do
      assert instruction =~ "Puedes coincidir con su elección"
      assert instruction =~ "No copies sus frases ni sus gestos"
      assert instruction =~ "No inventes un desacuerdo ni hechos nuevos"
      assert instruction =~ "no gastes magia ni hagas tiradas"
      assert instruction =~ "No llames request_response"
      assert instruction =~ "Tu respuesta basta"
      assert instruction =~ "No necesitas añadir un gesto ni proponer una acción"
      actor = if instruction == lyra, do: "Lyra", else: "Vex"
      role = PCAgent.system_prompt(world.characters[actor])
      assert role =~ "Responder una pregunta ya es una intervención completa"
      refute role =~ "hay que haber propuesto o hecho un gesto local"
    end
  end

  test "the response voice contract does not replace ordinary, combat or unconscious turns" do
    world = asked()
    wizard = world.characters["Lyra"]

    for changed <- [
          %{world | conversation: nil},
          %{world | phase: :combat},
          elem(Conversation.finish_actor("Lyra").(world), 1)
        ] do
      refute PCAgent.instruction("Lyra", wizard, changed) =~ "Puedes coincidir con su elección"
    end

    down = %{wizard | hp: 0}
    instruction = PCAgent.instruction("Lyra", down, world)
    assert instruction =~ "make_death_save"
    refute instruction =~ "Puedes coincidir con su elección"
  end
end
