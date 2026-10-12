defmodule Dragonex.Flows.HealSpellTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Character, PCAgent, Tools, World}
  alias Dragonex.Heroes.Spells
  alias ExAgent.{Models.Test, Server, Session}

  test "PC TestModel casts Heal on an ally with old JSON and cannot cast as another character" do
    c =
      Character.new(
        name: "C",
        class: "cleric",
        level: 11,
        hp: 20,
        max_hp: 20,
        spells: [Spells.to_character_spell(Spells.get("heal"), :wis)]
      )

    a = Character.new(name: "A", hp: 0, max_hp: 100, conditions: ["blinded", "poisoned"])
    w = World.new(characters: %{"C" => c, "A" => a}, spell_slots: %{"C" => %{6 => 1}})
    session = start_session(world: w, policy: :round_robin, participants: [p("C"), p("A")])
    assert {:ok, "C"} = Session.start(session)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)
    roller = fn _ -> flunk("Heal does not roll") end

    assert {:error, _} =
             Tools.cast_spell(%{deps: deps_for(session, "A", roller)}, "C", "heal", "A", nil)

    assert Session.read_state(session) == w

    model = %Test{
      script: [
        tool_calls([call("cast_spell", %{"caster" => "C", "spell" => "heal", "target" => "A"})]),
        narration("Mi magia devuelve fuerzas a mi compañero.")
      ]
    }

    agent = PCAgent.new(model, c)

    server =
      start_supervised!(
        {Server, agent: agent, agent_id: "heal-#{System.unique_integer([:positive])}"}
      )

    assert {:ok, _} = Server.chat(server, "cura a A", deps: deps_for(session, "C", roller))
    next = Session.read_state(session)
    assert next.characters["A"].hp == 70
    assert Character.condition_names(next.characters["A"]) == ["poisoned"]
    assert next.spell_slots["C"][6] == 0
  end
end
