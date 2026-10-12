defmodule Dragonex.TurnmasterContextTest do
  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Game, Intents, Monsters, TurnMaster, World}
  alias Dragonex.Game.{Beats, Bootstrap}
  alias ExAgent.{Models.Test, Server}

  test "each handoff receives one current snapshot, without accumulating earlier worlds" do
    owner = self()

    script =
      for n <- 1..3, item <- [observe(owner, n, give("Thane")), "listo"], do: item

    {state, world} = setup_turnmaster(script)

    for n <- 1..3 do
      {:ok, current_world} = World.set_scene("Escena vigente #{n}").(world)
      assert {:ok, %{to: "Thane"}, _} = run_beat(state, current_world)
      assert_receive {:tm_context, ^n, context}
      assert length(Regex.scan(~r/WORLD:/, context)) == 1
      assert context =~ "Escena vigente #{n}"

      for earlier <- 1..3, earlier != n do
        refute context =~ "Escena vigente #{earlier}"
      end
    end
  end

  test "validation feedback survives inside a beat and is dropped before the next handoff" do
    owner = self()

    script = [
      give("fantasma-inexistente"),
      observe(owner, :retry, give("Thane")),
      "listo",
      observe(owner, :next, give("dm")),
      "listo"
    ]

    {state, world} = setup_turnmaster(script)
    assert {:ok, %{to: "Thane"}, _} = run_beat(state, world)
    assert_receive {:tm_context, :retry, retry_context}
    assert retry_context =~ "fantasma-inexistente"
    assert retry_context =~ "no es un participante"

    assert {:ok, %{to: "dm"}, _} = run_beat(state, world)
    assert_receive {:tm_context, :next, next_context}
    refute next_context =~ "fantasma-inexistente"
    assert length(Regex.scan(~r/WORLD:/, next_context)) == 1
  end

  test "fresh context still carries pending human reactions and the interrupted actor" do
    owner = self()
    reaction = tool_calls([call("react", %{"participant" => "Thane"})])
    {state, world} = setup_turnmaster([observe(owner, :reaction, reaction), "listo"])
    {:ok, world} = World.begin_combat(["goblin", "Thane"]).(world)

    state = %{
      state
      | last_actor: "goblin",
        interrupted: "goblin",
        intents: %{"Thane" => Intents.encode("Interrumpo para proteger a Lyra", :combat)}
    }

    assert {:ok, %{action: :react, to: "Thane"}, _} = run_beat(state, world)
    assert_receive {:tm_context, :reaction, context}
    assert context =~ "Interrumpo para proteger a Lyra"
    assert context =~ "actor interrumpido esperando retomar: goblin"
    assert context =~ "Combate ronda 1"
  end

  defp give(to), do: tool_calls([call("give_turn_to", %{"participant" => to})])

  defp observe(owner, label, response) do
    fn messages, _params ->
      send(
        owner,
        {:tm_context, label, inspect(messages, limit: :infinity, printable_limit: :infinity)}
      )

      response
    end
  end

  defp setup_turnmaster(script) do
    id = System.unique_integer([:positive])
    agent = TurnMaster.new(%Test{script: script})

    server =
      start_supervised!(
        {Server, agent: agent, agent_id: Bootstrap.turnmaster_agent_id(id), pubsub: :local}
      )

    world =
      Enum.reduce([Archetypes.fighter(), Monsters.goblin()], World.new(), fn c, w ->
        {:ok, w} = World.add_character(c).(w)
        w
      end)

    state = %Game{
      game_id: id,
      turnmaster: server,
      participants: %{"Thane" => %{kind: :human}, "dm" => %{kind: :ai}}
    }

    {state, world}
  end

  defp run_beat(state, world) do
    state =
      Beats.run_turnmaster_beat(state, "context-#{System.unique_integer([:positive])}", world)

    ref = state.busy.ref
    assert_receive {^ref, result}, 4_000
    result
  end
end
