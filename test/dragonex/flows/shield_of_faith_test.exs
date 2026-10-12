defmodule Dragonex.Flows.ShieldOfFaithTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Character, Tools, World}
  alias Dragonex.Heroes.Spells
  alias Dragonex.Rules.Effects
  alias ExAgent.{Server, Session}

  test "TestModel casts Faith through cast_spell and dropping concentration removes its AC bonus" do
    c =
      Character.new(
        name: "C",
        class: "cleric",
        hp: 20,
        max_hp: 20,
        spells: [Spells.to_character_spell(Spells.get("shield of faith"), :wis)]
      )

    a = Character.new(name: "A", hp: 10, max_hp: 10, ac: 12)
    w = World.new(characters: %{"C" => c, "A" => a}, spell_slots: %{"C" => %{1 => 2}})
    session = start_session(world: w, policy: :round_robin, participants: [p("C"), p("A")])
    assert {:ok, "C"} = Session.start(session)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    agent =
      start_dm(
        id: "faith-#{System.unique_integer([:positive])}",
        script: [
          tool_calls([
            call("cast_spell", %{"caster" => "C", "spell" => "shield of faith", "target" => "A"})
          ]),
          text("El escudo protege a A.")
        ]
      )

    assert {:ok, _} =
             Server.chat(agent, "protege a A", deps: deps_for(session, "C", fixed_roller(2)))

    protected = Session.read_state(session)
    assert protected.spell_slots["C"][1] == 1
    assert protected.characters["A"].ac == 12
    assert Effects.effective_ac(protected.characters["A"]) == 14
    assert protected.effect_expiries["C"]["concentrating"] == 600

    assert {:error, _} =
             Tools.drop_concentration(%{deps: deps_for(session, "A", fixed_roller(2))}, "C")

    assert Session.read_state(session) == protected

    dropper =
      start_dm(
        id: "faith-drop-#{System.unique_integer([:positive])}",
        script: [
          tool_calls([call("drop_concentration", %{"who" => "C"})]),
          text("La protección termina.")
        ]
      )

    assert {:ok, _} =
             Server.chat(dropper, "termina la concentración",
               deps: deps_for(session, "C", fixed_roller(2))
             )

    assert Effects.effective_ac(Session.read_state(session).characters["A"]) == 12
  end
end
