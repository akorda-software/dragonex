defmodule Dragonex.CastSpellContractTest do
  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, DM, PCAgent, Tools, World}
  alias ExAgent.{Models.Test, Server, Session}

  test "live DM and PC schemas let optional spell arguments be omitted or null" do
    for tools <- [DM.tools(), PCAgent.tools()] do
      schema = Enum.find(tools, &(&1.name == "cast_spell")).parameters_json_schema

      for field <- ~w(cast_level additional_targets) do
        refute field in schema.required
        assert "null" in List.wrap(schema.properties[field].type)
      end

      refute "condition_to_remove" in schema.required
      [selection, blank] = schema.properties["condition_to_remove"].anyOf
      assert "null" in selection.type
      assert blank == %{type: "string", pattern: "^\\s*$"}

      assert selection.enum ==
               [nil, "blinded", "deafened", "paralyzed", "poisoned", "diseased"]
    end
  end

  defp session do
    wizard = Archetypes.wizard()
    goblin = Dragonex.Monsters.goblin()

    world =
      World.new(
        characters: %{wizard.name => wizard, goblin.name => goblin},
        spell_slots: %{wizard.name => %{1 => 0}}
      )

    {:ok, world} = World.begin_combat([wizard.name, goblin.name]).(world)
    {:ok, world} = World.set_current_combatant(wizard.name).(world)
    session = start_session(world: world, policy: :round_robin, participants: [p(wizard.name)])
    assert {:ok, "Lyra"} = Session.start(session)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)
    {session, wizard}
  end

  for empty <- ["", "   "] do
    test "a scripted PC can cast a cantrip with blank optional selection #{inspect(empty)}" do
      {session, wizard} = session()
      rolls = start_supervised!({Agent, fn -> [] end})

      roller = fn sides ->
        Agent.update(rolls, &[sides | &1])
        if sides == 20, do: 15, else: 1
      end

      args = %{
        "caster" => "Lyra",
        "spell" => "fire bolt",
        "target" => "goblin",
        "cast_level" => nil,
        "additional_targets" => [],
        "condition_to_remove" => unquote(empty)
      }

      model = %Test{
        script: [tool_calls([call("cast_spell", args)]), narration("El dardo alcanza al goblin.")]
      }

      server =
        start_supervised!(
          {Server,
           agent: PCAgent.new(model, wizard),
           agent_id: "cantrip-#{System.unique_integer([:positive])}"}
        )

      assert {:ok, _} =
               Server.chat(server, "lanza un truco", deps: deps_for(session, "Lyra", roller))

      world = Session.read_state(session)
      assert world.characters["goblin"].hp == 6
      assert world.spell_slots["Lyra"][1] == 0
      assert world.turn_state["Lyra"]["action"] == true
      assert Agent.get(rolls, &Enum.reverse/1) == [20, 10]
    end
  end

  test "a nonempty selection for another spell remains rejected without spending or rolling" do
    {session, _wizard} = session()
    world = Session.read_state(session)
    ctx = %{deps: deps_for(session, "Lyra", fn _ -> flunk("invalid selection must not roll") end)}

    assert {:error, message} =
             Tools.cast_spell(ctx, "Lyra", "fire bolt", "goblin", nil, [], "poisoned")

    assert message =~ "null"
    assert Session.read_state(session) == world
  end
end
