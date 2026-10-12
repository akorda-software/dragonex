defmodule Dragonex.Flows.LayOnHandsPurifyTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Character, PCAgent, Tools, World}
  alias ExAgent.{Models.Test, Server, Session}

  for purify <- [true, false] do
    test "Lay on Hands JSON compatibility, purification #{purify}, and actor control" do
      c =
        Character.new(
          name: "C",
          class: "paladin",
          level: 4,
          hp: 20,
          max_hp: 20,
          lay_on_hands_pool: 20
        )

      t = Character.new(name: "T", hp: 5, max_hp: 20, conditions: ["poisoned", "diseased"])
      w = World.new(characters: %{"C" => c, "T" => t})
      session = start_session(world: w, policy: :round_robin, participants: [p("C"), p("T")])
      assert {:ok, "C"} = Session.start(session)
      on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)
      roller = fn _ -> flunk("no dice") end

      assert {:error, _} =
               Tools.lay_on_hands(%{deps: deps_for(session, "T", roller)}, "C", "T", 5, [
                 "poisoned"
               ])

      assert Session.read_state(session) == w
      args = %{"who" => "C", "target" => "T", "amount" => 5}

      args =
        if unquote(purify), do: Map.put(args, "conditions_to_remove", ["poisoned"]), else: args

      model = %Test{
        script: [
          tool_calls([call("lay_on_hands", args)]),
          narration("Ayudo a mi compañero con mis manos.")
        ]
      }

      server =
        start_supervised!(
          {Server,
           agent: PCAgent.new(model, c), agent_id: "hands-#{System.unique_integer([:positive])}"}
        )

      assert {:ok, _} = Server.chat(server, "ayuda a T", deps: deps_for(session, "C", roller))
      next = Session.read_state(session)
      assert next.characters["T"].hp == 10
      assert next.characters["C"].lay_on_hands_pool == if(unquote(purify), do: 10, else: 15)

      assert Character.condition_names(next.characters["T"]) ==
               if(unquote(purify), do: ["diseased"], else: ["poisoned", "diseased"])
    end
  end
end
