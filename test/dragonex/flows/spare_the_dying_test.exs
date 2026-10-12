defmodule Dragonex.Flows.SpareTheDyingTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Character, PCAgent, Tools, World}
  alias Dragonex.Heroes.Spells
  alias ExAgent.{Models.Test, Server, Session}

  test "PCAgent stabilizes through old cast_spell JSON, then stable recipient takes no death save" do
    c =
      Character.new(
        name: "C",
        class: "cleric",
        hp: 12,
        max_hp: 12,
        spells: [Spells.to_character_spell(Spells.get("spare the dying"), :wis)]
      )

    a = Character.new(name: "A", hp: 0, max_hp: 20, death_saves: %{successes: 0, fails: 2})
    w = World.new(characters: %{"C" => c, "A" => a}, spell_slots: %{"C" => %{1 => 0}})
    session = start_session(world: w, policy: :round_robin, participants: [p("C"), p("A")])
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)
    assert {:ok, "C"} = Session.start(session)
    roller = fn _ -> flunk("no dice when stabilizing or stable") end

    assert {:error, _} =
             Tools.cast_spell(
               %{deps: deps_for(session, "A", roller)},
               "C",
               "spare the dying",
               "A",
               nil
             )

    assert Session.read_state(session) == w

    model = %Test{
      script: [
        tool_calls([
          call("cast_spell", %{
            "caster" => "C",
            "spell" => "spare the dying",
            "target" => "A"
          })
        ]),
        narration("Mantengo con vida a mi compañero.")
      ]
    }

    agent = PCAgent.new(model, c)

    server =
      start_supervised!(
        {Server, agent: agent, agent_id: "spare-#{System.unique_integer([:positive])}"}
      )

    assert {:ok, _} = Server.chat(server, "estabiliza a A", deps: deps_for(session, "C", roller))
    next = Session.read_state(session)
    assert next.characters["A"].hp == 0
    assert next.characters["A"].death_saves == %{successes: 3, fails: 0}
    assert next.spell_slots == w.spell_slots
    assert {:ok, "A"} = Session.end_turn(session, "C")

    stable = next.characters["A"]
    instruction = PCAgent.instruction("A", stable, next)
    assert instruction =~ "ESTABLE"
    refute instruction =~ "make_death_save("

    agent =
      PCAgent.new(%Test{script: [narration("Mi respiración permanece débil y regular.")]}, stable)

    stable_server =
      start_supervised!(
        {Server, agent: agent, agent_id: "stable-#{System.unique_integer([:positive])}"},
        id: :stable_pc
      )

    assert {:ok, _} =
             Server.chat(stable_server, instruction, deps: deps_for(session, "A", roller))

    assert Session.read_state(session).characters["A"] == stable
  end
end
