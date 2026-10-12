defmodule Dragonex.Flows.BlessTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Character, World, Tools}
  alias Dragonex.Heroes.Spells
  alias Dragonex.Rules.Effects
  alias ExAgent.{Server, Session}

  test "cast_spell supports legacy JSON and additional targets through the real tool schema" do
    c =
      Character.new(
        name: "C",
        class: "cleric",
        hp: 20,
        max_hp: 20,
        spells: [Spells.to_character_spell(Spells.get("bless"), :wis)]
      )

    a = Character.new(name: "A", hp: 10, max_hp: 10)
    b = %{a | name: "B"}
    w = World.new(characters: %{"C" => c, "A" => a, "B" => b}, spell_slots: %{"C" => %{1 => 3}})

    session =
      start_session(world: w, policy: :round_robin, participants: [p("C"), p("A")])

    assert {:ok, "C"} = Session.start(session)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    old =
      start_dm(
        id: "bless-old-#{System.unique_integer([:positive])}",
        script: [
          tool_calls([
            call("cast_spell", %{"caster" => "C", "spell" => "bless", "target" => "A"})
          ]),
          text("Bendición resuelta.")
        ]
      )

    assert {:ok, _} = Server.chat(old, "bendice", deps: deps_for(session, "C", fixed_roller(2)))
    first = Session.read_state(session)
    assert first.spell_slots["C"][1] == 2
    assert Effects.blessed?(first.characters["A"])
    refute Effects.blessed?(first.characters["C"])

    agent =
      start_dm(
        id: "bless-many-#{System.unique_integer([:positive])}",
        script: [
          tool_calls([
            call("cast_spell", %{
              "caster" => "C",
              "spell" => "bless",
              "target" => "C",
              "cast_level" => 1,
              "additional_targets" => ["A", "B"]
            })
          ]),
          text("El grupo recibe la bendición.")
        ]
      )

    assert {:ok, _} =
             Server.chat(agent, "bendice al grupo", deps: deps_for(session, "C", fixed_roller(2)))

    final = Session.read_state(session)
    assert final.spell_slots["C"][1] == 1
    for name <- ["C", "A", "B"], do: assert(Effects.blessed?(final.characters[name]))

    # A PC cannot spend someone else's slot via the extended signature.
    assert {:error, _} =
             Tools.cast_spell(
               %{deps: deps_for(session, "A", fixed_roller(2))},
               "C",
               "bless",
               "A",
               1,
               ["B"]
             )

    assert Session.read_state(session) == final
  end
end
