defmodule Dragonex.PCResponseGuidanceTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Archetypes, Codec, Conversation, PCAgent, World}

  defp world(actor \\ "Lyra", question \\ "¿Qué propones y por qué?") do
    world =
      World.new(
        characters: %{
          "Mara" => Archetypes.wizard(name: "Mara"),
          "Lyra" => %{
            Archetypes.wizard()
            | backstory: "Estudié tintes para contrastar testimonios."
          },
          "Vex" => %{
            Archetypes.rogue()
            | backstory: "Aprendí a obtener información sin llamar la atención."
          }
        }
      )

    {:ok, asked} = Conversation.request("Mara", [actor], question).(world)
    asked
  end

  test "pending answers use each current class and personal background as a criterion" do
    lyra = apply(PCAgent, :response_guidance, [world(), "Lyra"])
    vex = apply(PCAgent, :response_guidance, [world("Vex"), "Vex"])
    assert lyra =~ "CRITERIO PROPIO DE Lyra"
    assert lyra =~ "comprobar"
    assert lyra =~ "Estudié tintes"
    refute lyra =~ "Aprendí a obtener"
    assert vex =~ "CRITERIO PROPIO DE Vex"
    assert vex =~ "exposición"
    assert vex =~ "Aprendí a obtener"
    refute vex =~ "Estudié tintes"
    refute lyra == vex
  end

  test "agreement needs no invented disagreement and data questions need no extra proposal" do
    asked = world()
    before = Codec.encode(asked)
    guide = apply(PCAgent, :response_guidance, [asked, "Lyra"])
    assert guide =~ "Si te piden una propuesta"
    assert guide =~ "Si coincides"
    assert guide =~ "no hay otro criterio"
    assert guide =~ "sin inventar desacuerdo"
    assert guide =~ "solo pide recuerdos o datos"
    assert guide =~ "ausencia de testimonios no confirma"
    assert guide =~ "decisión sigue siendo del jugador"
    assert guide =~ "FORMATO DE ESTA RESPUESTA"
    assert guide =~ "diálogo directo"
    assert guide =~ "una idea por frase"
    assert guide =~ "Si solo te piden datos"
    assert guide =~ "salvo que te pidan una propuesta"
    assert Codec.encode(asked) == before
    assert Codec.decode(before) == asked
  end

  test "only the capable next companion in exploration receives response guidance" do
    asked = world()

    for {world, actor} <- [
          {%{asked | conversation: nil}, "Lyra"},
          {%{asked | phase: :combat}, "Lyra"},
          {asked, "Vex"},
          {asked, "Mara"},
          {asked, "dm"},
          {asked, "Nadie"},
          {put_in(asked.characters["Lyra"].hp, 0), "Lyra"}
        ] do
      assert apply(PCAgent, :response_guidance, [world, actor]) == ""
    end

    refute PCAgent.instruction("Lyra", asked.characters["Lyra"], %{asked | conversation: nil}) =~
             "CRITERIO PROPIO"

    assert PCAgent.instruction("Lyra", asked.characters["Lyra"], asked) =~
             "No necesitas añadir un gesto ni proponer una acción"

    assert PCAgent.system_prompt(asked.characters["Lyra"]) =~ "si te piden una propuesta"
  end

  test "a factual answer can agree briefly only when the previous account respects its sources and doubts" do
    asked = world("Lyra", "¿Qué dijo el zagal sobre la lana y qué sigue sin probar?")
    before = Codec.encode(asked)
    guide = PCAgent.response_guidance(asked, "Lyra")
    assert guide =~ "Si otro compañero acaba de cubrir esos datos"
    assert guide =~ "conservando la fuente y sus dudas"
    assert guide =~ "puedes reconocer el acuerdo brevemente"
    assert guide =~ "No repitas todo su resumen"
    assert guide =~ "Si su respuesta contradice lo registrado, corrige esa diferencia"
    assert Codec.encode(asked) == before
  end

  test "all playable classes have an actionable perspective without changing the agreed facts" do
    asked = world()

    guides =
      for class <-
            ~w(barbarian bard cleric druid fighter monk paladin ranger rogue sorcerer warlock wizard) do
        current = put_in(asked.characters["Lyra"].class, class)
        guide = apply(PCAgent, :response_guidance, [current, "Lyra"])
        assert guide =~ "CRITERIO PROPIO DE Lyra"
        assert guide =~ "sin inventar"
        guide
      end

    assert length(Enum.uniq(guides)) == 12
    unknown = put_in(asked.characters["Lyra"].class, nil)
    assert apply(PCAgent, :response_guidance, [unknown, "Lyra"]) =~ "CRITERIO PROPIO DE Lyra"
  end

  test "current background is bounded and scrubbed and missing background is allowed" do
    asked = world()

    current =
      put_in(
        asked.characters["Lyra"].backstory,
        "Vi al goblin en 3/7 pg. " <> String.duplicate("x", 3000)
      )

    guide = apply(PCAgent, :response_guidance, [current, "Lyra"])
    refute guide =~ "3/7"
    refute guide =~ String.duplicate("x", 1801)

    for background <- [nil, "", "  "] do
      current = put_in(asked.characters["Lyra"].backstory, background)
      refute apply(PCAgent, :response_guidance, [current, "Lyra"]) =~ "TRASFONDO ACTUAL:"
    end
  end
end
