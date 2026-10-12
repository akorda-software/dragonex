defmodule Dragonex.TurnMasterTest do
  @moduledoc """
  Fase A — TurnMaster agent in isolation: tools record decisions, reject
  invalid targets, never mutate the World.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Monsters, TurnMaster, World}
  alias Dragonex.TurnMaster.{Decision, Tools}
  alias ExAgent.{Models.Test, Server}

  defp world_with_party do
    World.new()
    |> then(fn w -> elem(World.add_character(Archetypes.fighter()).(w), 1) end)
    |> then(fn w -> elem(World.add_character(Monsters.goblin()).(w), 1) end)
  end

  defp deps(world, recorder, participants \\ ["dm", "Thane", "goblin"]) do
    %{decision: recorder, world: world, participants: participants}
  end

  describe "system_prompt/0 and tools/0" do
    test "prompt forbids narration and lists the five tools" do
      prompt = TurnMaster.system_prompt()
      assert prompt =~ "TurnMaster"
      assert prompt =~ "UNA herramienta"
      assert prompt =~ "give_turn_to"
      assert prompt =~ "cut_in"
      assert prompt =~ "react"
      assert prompt =~ "INTENCIONES HUMANAS"
      refute prompt =~ "make_attack"
    end

    test "instruction cites pending human intent names" do
      world = world_with_party()

      text =
        TurnMaster.instruction("dm", world, pending_intents: %{"Lyra" => "interrumpo con Escudo"})

      assert text =~ "Lyra"
      assert text =~ "intenciones humanas"
    end

    test "instruction stays quiet when no intents are pending" do
      text = TurnMaster.instruction("dm", world_with_party(), pending_intents: %{})
      refute text =~ "intenciones humanas"
    end

    test "tools/0 exposes exactly the orchestration set" do
      names =
        TurnMaster.tools()
        |> Enum.map(fn t -> t.name |> to_string() end)
        |> Enum.sort()

      assert names == Enum.sort(~w(cut_in end_scene give_turn_to pass_to_dm react))
    end

    test "new/2 builds an agent with tools and no Events capability" do
      agent = TurnMaster.new(%Test{label: "ok"}, max_tokens: 256)
      assert length(agent.tools) == 5
      # No narration capability — TurnMaster only orchestrates.
      caps = Map.get(agent, :capabilities) || []
      refute Enum.any?(List.wrap(caps), fn c -> match?(%{__struct__: Dragonex.Events}, c) end)
    end

    test "new/2 caps max_steps at 3 by default (one decision + one retry + margin)" do
      agent = TurnMaster.new(%Test{label: "ok"})
      # Reaches ExAgent: the struct IS the agent the Server will run, and its
      # drive loop stops at agent.max_steps (playtest 2026-09-16: default 50
      # let a looping LLM stall the beat ~50s before the fallback).
      assert agent.max_steps == 3
    end

    test "new/2 max_steps is overridable" do
      agent = TurnMaster.new(%Test{label: "ok"}, max_steps: 8)
      assert agent.max_steps == 8
    end
  end

  describe "tools record decisions" do
    test "give_turn_to records a valid PC" do
      {:ok, rec} = Decision.start()
      world = world_with_party()
      ctx = %{deps: deps(world, rec)}

      assert {:ok, _} = Tools.give_turn_to(ctx, "Thane")
      assert Decision.get(rec) == %{action: :give_turn_to, to: "Thane"}
      Decision.stop(rec)
    end

    test "give_turn_to accepts dm" do
      {:ok, rec} = Decision.start()
      ctx = %{deps: deps(world_with_party(), rec)}

      assert {:ok, _} = Tools.give_turn_to(ctx, "dm")
      assert Decision.get(rec).to == "dm"
      Decision.stop(rec)
    end

    test "give_turn_to rejects unknown participant" do
      {:ok, rec} = Decision.start()
      ctx = %{deps: deps(world_with_party(), rec)}

      assert {:error, msg} = Tools.give_turn_to(ctx, "Nobody")
      assert msg =~ "no"
      assert Decision.get(rec) == nil
      Decision.stop(rec)
    end

    test "give_turn_to canonicalizes case/space near-misses of a participant" do
      for raw <- ["thane", " thane ", "THANE"] do
        {:ok, rec} = Decision.start()
        ctx = %{deps: deps(world_with_party(), rec)}

        assert {:ok, _} = Tools.give_turn_to(ctx, raw)
        # The canonical roster name is recorded, not the model's near-miss —
        # Session.handoff/2 must receive a real participant id.
        assert Decision.get(rec) == %{action: :give_turn_to, to: "Thane"}
        Decision.stop(rec)
      end
    end

    test "give_turn_to still rejects a case-variant of a nonexistent participant" do
      {:ok, rec} = Decision.start()
      ctx = %{deps: deps(world_with_party(), rec)}

      assert {:error, msg} = Tools.give_turn_to(ctx, " nobody ")
      assert msg =~ "no es un participante"
      assert Decision.get(rec) == nil
      Decision.stop(rec)
    end

    test "cut_in canonicalizes the target too" do
      world = world_with_party()
      {:ok, combat} = World.begin_combat(["Thane", "goblin"]).(world)
      {:ok, rec} = Decision.start()
      ctx = %{deps: deps(combat, rec)}

      assert {:ok, _} = Tools.cut_in(ctx, "Thane ")
      assert Decision.get(rec) == %{action: :cut_in, to: "Thane"}
      Decision.stop(rec)
    end

    test "give_turn_to rejects a dead character" do
      world = world_with_party()
      goblin = %{world.characters["goblin"] | hp: 0, death_saves: %{successes: 0, fails: 3}}
      world = %{world | characters: Map.put(world.characters, "goblin", goblin)}

      {:ok, rec} = Decision.start()
      ctx = %{deps: deps(world, rec)}

      assert {:error, msg} = Tools.give_turn_to(ctx, "goblin")
      assert msg =~ "muerto"
      Decision.stop(rec)
    end

    test "pass_to_dm and end_scene record without a target character" do
      {:ok, rec} = Decision.start()
      ctx = %{deps: deps(world_with_party(), rec)}

      assert {:ok, _} = Tools.pass_to_dm(ctx)
      assert Decision.get(rec).action == :pass_to_dm

      assert {:ok, _} = Tools.end_scene(ctx)
      assert Decision.get(rec).action == :end_scene
      Decision.stop(rec)
    end

    test "cut_in/react require combat" do
      {:ok, rec} = Decision.start()
      world = world_with_party()
      ctx = %{deps: deps(world, rec)}

      assert {:error, _} = Tools.cut_in(ctx, "Thane")
      assert {:error, _} = Tools.react(ctx, "Thane")

      {:ok, combat} = World.begin_combat(["Thane", "goblin"]).(world)
      ctx2 = %{deps: deps(combat, rec)}

      assert {:ok, _} = Tools.cut_in(ctx2, "Thane")
      assert Decision.get(rec).action == :cut_in

      assert {:ok, _} = Tools.react(ctx2, "Thane")
      assert Decision.get(rec).action == :react
      Decision.stop(rec)
    end

    test "tools never mutate the World" do
      world = world_with_party()
      before = :erlang.phash2(world)
      {:ok, rec} = Decision.start()
      ctx = %{deps: deps(world, rec)}

      _ = Tools.give_turn_to(ctx, "Thane")
      _ = Tools.pass_to_dm(ctx)
      _ = Tools.end_scene(ctx)

      assert :erlang.phash2(world) == before
      Decision.stop(rec)
    end
  end

  describe "scripted agent beat" do
    test "a scripted TurnMaster records give_turn_to via Server.chat" do
      world = world_with_party()
      {:ok, rec} = Decision.start()

      agent =
        TurnMaster.new(%Test{
          script: [
            tool_calls([call("give_turn_to", %{"participant" => "Thane"})]),
            text("ok")
          ]
        })

      server =
        start_supervised!(
          {Server, agent: agent, agent_id: "tm-iso-#{System.unique_integer([:positive])}"}
        )

      assert {:ok, _} =
               Server.chat(server, "decide",
                 deps: deps(world, rec),
                 stream_text: false
               )

      assert Decision.get(rec) == %{action: :give_turn_to, to: "Thane"}
      Decision.stop(rec)
    end

    test "a model that never stops calling tools fails at 3 steps, not 50" do
      world = world_with_party()
      {:ok, rec} = Decision.start()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      # Playtest 2026-09-16 shape: every step emits a VALID tool call and the
      # model never produces the final text — the agentic loop used to spin to
      # exAgent's default max_steps of 50 before erroring out.
      endless =
        for _ <- 1..50,
            do: fn ->
              Agent.update(counter, &(&1 + 1))
              tool_calls([call("give_turn_to", %{"participant" => "dm"})])
            end

      agent = TurnMaster.new(%Test{script: endless})

      server =
        start_supervised!(
          {Server, agent: agent, agent_id: "tm-loop-#{System.unique_integer([:positive])}"}
        )

      assert {:error, error} =
               Server.chat(server, "decide", deps: deps(world, rec), stream_text: false)

      reason = if is_map(error), do: error.reason, else: error
      assert reason == {:max_steps_exceeded, 3}

      assert Agent.get(counter, & &1) == 3
      Decision.stop(rec)
    end
  end

  describe "instruction/3 and decision_note/1" do
    test "instruction is the decision prompt; world state lives in the brief" do
      world = world_with_party()
      {:ok, combat} = World.begin_combat(["Thane", "goblin"]).(world)
      text = TurnMaster.instruction("Thane", combat, participants: ["dm", "Thane"])
      assert text =~ "Decide quién actúa ahora"
      refute text =~ "COMBATE"

      nudged = TurnMaster.instruction("Thane", combat, nudge: "elige a otro")
      assert nudged =~ "AVISO: elige a otro"
    end

    test "decision_note is human-readable Spanish" do
      assert TurnMaster.decision_note(%{action: :give_turn_to, to: "Lyra"}) =~ "Lyra"
      assert TurnMaster.decision_note(%{action: :pass_to_dm}) =~ "DM"
      assert TurnMaster.decision_note(%{action: :end_scene}) =~ "exploración"
    end
  end
end
