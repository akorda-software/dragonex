defmodule Dragonex.Flows.FalseLifeTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Character, PCAgent, World}
  alias Dragonex.Heroes.Spells
  alias ExAgent.{Models.Test, Server, Session}

  test "PCAgent uses cast_level through cast_spell for scaled temporary HP" do
    c =
      Character.new(
        name: "C",
        class: "wizard",
        level: 3,
        hp: 5,
        max_hp: 20,
        spells: [Spells.to_character_spell(Spells.get("false life"), :int)]
      )

    w = World.new(characters: %{"C" => c}, spell_slots: %{"C" => %{1 => 0, 2 => 1}})
    session = start_session(world: w, policy: :round_robin, participants: [p("C")])
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)
    assert {:ok, "C"} = Session.start(session)

    model = %Test{
      script: [
        tool_calls([
          call("cast_spell", %{
            "caster" => "C",
            "spell" => "false life",
            "target" => "C",
            "cast_level" => 2
          })
        ]),
        narration("Me envuelvo en una reserva de vigor arcano.")
      ]
    }

    agent = PCAgent.new(model, c)

    server =
      start_supervised!(
        {Server, agent: agent, agent_id: "false-life-#{System.unique_integer([:positive])}"}
      )

    assert {:ok, _} =
             Server.chat(server, "usa falsa vida a nivel 2",
               deps: deps_for(session, "C", fn 4 -> 3 end)
             )

    next = Session.read_state(session)
    assert next.characters["C"].temp_hp == 12
    assert next.characters["C"].hp == 5
    assert next.spell_slots["C"][2] == 0
    assert next.effect_expiries["C"]["temp_hp"] == 3600
  end
end
