defmodule Dragonex.Flows.LesserRestorationTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Character, PCAgent, Tools, World}
  alias Dragonex.Heroes.Spells
  alias ExAgent.{Models.Test, Server, Session}

  for explicit <- [true, false] do
    test "PCAgent executes Lesser Restoration with explicit selection #{explicit}" do
      c =
        Character.new(
          name: "C",
          class: "cleric",
          level: 3,
          hp: 20,
          max_hp: 20,
          spells: [Spells.to_character_spell(Spells.get("lesser restoration"), :wis)]
        )

      conditions = if unquote(explicit), do: ["blinded", "poisoned"], else: ["poisoned"]
      a = Character.new(name: "A", hp: 5, max_hp: 20, conditions: conditions)
      w = World.new(characters: %{"C" => c, "A" => a}, spell_slots: %{"C" => %{2 => 1}})
      session = start_session(world: w, policy: :round_robin, participants: [p("C"), p("A")])
      assert {:ok, "C"} = Session.start(session)
      on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)
      roller = fn _ -> flunk("no dice") end

      assert {:error, _} =
               Tools.cast_spell(
                 %{deps: deps_for(session, "A", roller)},
                 "C",
                 "lesser restoration",
                 "A",
                 nil
               )

      if unquote(explicit) do
        assert {:error, _} =
                 Tools.cast_spell(
                   %{deps: deps_for(session, "C", roller)},
                   "C",
                   "lesser restoration",
                   "A",
                   nil,
                   nil
                 )
      end

      assert Session.read_state(session) == w
      args = %{"caster" => "C", "spell" => "lesser restoration", "target" => "A"}

      args =
        if unquote(explicit), do: Map.put(args, "condition_to_remove", "poisoned"), else: args

      model = %Test{
        script: [
          tool_calls([call("cast_spell", args)]),
          narration("El veneno abandona su cuerpo.")
        ]
      }

      server =
        start_supervised!(
          {Server,
           agent: PCAgent.new(model, c),
           agent_id: "restoration-#{System.unique_integer([:positive])}"}
        )

      assert {:ok, _} =
               Server.chat(server, "elimina el veneno de A", deps: deps_for(session, "C", roller))

      next = Session.read_state(session)
      assert Character.condition_names(next.characters["A"]) == conditions -- ["poisoned"]
      assert next.characters["A"].hp == 5
      assert next.spell_slots["C"][2] == 0
    end
  end
end
