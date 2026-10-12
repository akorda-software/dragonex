defmodule Dragonex.GameNPCQuestionTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Archetypes, Game, Games}
  alias ExAgent.{Models.Test, Server}
  import Dragonex.Test.Harness

  @question "Desde la ventana le pregunto a la posadera: «Antes de salir, ¿qué camino lleva al pueblo y hay algo de lo que deba tener cuidado?» Lyra y Vex pueden escuchar; yo espero aquí su respuesta."
  @answer "La posadera señala el camino de tierra. —Todo recto os lleva al pueblo en media hora de paseo."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp boot(script) do
    parent = self()

    tm = %Test{
      script: [
        fn _, _ ->
          send(parent, :npc_question_tm_called)
          tool_calls([call("give_turn_to", %{"participant" => "Lyra"})])
        end
      ]
    }

    {:ok, game} =
      Games.create_game(
        title: "La posadera responde antes del siguiente plan",
        roster: [
          {Archetypes.fighter(), :human},
          {Archetypes.wizard(), :ai},
          {Archetypes.rogue(), :ai}
        ]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)

    {:ok, pid} = Game.ensure_started(game.id, model: %Test{script: script}, turnmaster_model: tm)

    state = :sys.get_state(pid)

    for agent <- Map.values(state.pc_agents),
        do: Server.set_model(agent, %Dragonex.Test.Narrator{text: "Propongo mirar el patio."})

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    {game, pid, before, tm}
  end

  test "an explicit NPC question returns to the human without consulting TurnMaster or another PC" do
    parent = self()

    dm = fn messages, _ ->
      send(parent, {:npc_question_context, inspect(messages, limit: :infinity)})
      narration(@answer)
    end

    {game, pid, before, _tm} = boot([dm])
    assert Dragonex.Text.explicit_npc_question(@question) == "la posadera"
    assert {:ok, :resolving} = Game.declare(pid, "Thane", @question)
    assert_receive {:npc_question_context, context}, 2_000
    assert context =~ "Responde como ese PNJ"
    assert context =~ "—¿qué camino lleva al pueblo y hay algo de lo que deba tener cuidado?"
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    assert :ok == Game.pause(pid)
    turns = Games.list_events(game.id) |> Enum.filter(&(&1.type == :turn)) |> Enum.map(& &1.actor)
    assert turns == ["Thane", "dm"]
    refute_received :npc_question_tm_called
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
  end

  test "the NPC response queue survives a restart while the DM is waiting" do
    parent = self()

    dm = fn messages, _ ->
      send(parent, {:npc_waiting, self(), inspect(messages, limit: :infinity)})
      receive do: (:finish -> narration(@answer))
    end

    {game, pid, before, tm} = boot([dm])
    assert {:ok, :resolving} = Game.declare(pid, "Thane", @question)
    assert_receive {:npc_waiting, old_run, context}, 2_000
    assert context =~ "Responde como ese PNJ"
    assert :ok == Game.pause(pid)
    asked = Game.world(pid)
    assert asked.conversation["world_recipient"] == "la posadera"
    assert asked.conversation["pending"] == []
    assert asked.conversation["stage"] == "world"
    assert Games.load_world(Games.get_game(game.id)) == asked
    monitor = Process.monitor(old_run)

    {:ok, reopened} =
      Game.restart(game.id, model: %Test{script: [narration(@answer)]}, turnmaster_model: tm)

    assert Game.world(reopened) == asked
    assert_receive {:DOWN, ^monitor, :process, ^old_run, _}, 1_000
    assert :ok == Game.resume(reopened)
    assert :ok == Game.await(reopened, &(&1.current == "Thane" and &1.status == :waiting))
    assert :ok == Game.pause(reopened)
    assert Game.world(reopened) == before
    assert Games.load_world(Games.get_game(game.id)) == before

    narrations =
      Games.list_events(game.id) |> Enum.filter(&(&1.type == :narration and &1.actor != "dm"))

    assert Enum.map(narrations, & &1.actor) == ["Thane"]
    refute_received :npc_question_tm_called
    assert :ok == Dragonex.Game.Supervisor.stop_game(game.id)
  end

  test "clearing a paused NPC question removes only the draft, before starting a response" do
    {game, pid, before, _tm} =
      boot([narration("—¿Qué camino lleva al pueblo?"), narration(@answer)])

    assert :ok == Game.pause(pid)
    assert {:ok, :queued} = Game.declare(pid, "Thane", @question)
    assert Game.world(pid) == before
    assert :ok == Game.clear_intent(pid, "Thane")
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    assert :ok == Game.pause(pid)
    assert Game.world(pid) == before
    refute Enum.any?(Games.list_events(game.id), &(&1.type == :turn))
    refute_received :npc_question_tm_called
  end

  test "a model cannot replace the human's NPC question with a companion response request" do
    replace =
      tool_calls([
        call("request_response", %{
          "recipients" => ["Lyra"],
          "question" => "¿Quieres mirar el patio?"
        })
      ])

    {game, pid, before, _tm} =
      boot([replace, narration("—¿Qué camino lleva al pueblo?"), narration(@answer)])

    # A richer declaration still uses the human model, whose attempted
    # request replacement must remain rejected by the registered NPC queue.
    assert {:ok, :resolving} = Game.declare(pid, "Thane", @question <> " Observo sus manos.")
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    assert :ok == Game.pause(pid)
    turns = Games.list_events(game.id) |> Enum.filter(&(&1.type == :turn)) |> Enum.map(& &1.actor)
    assert turns == ["Thane", "dm"]
    assert Game.world(pid) == before
    refute_received :npc_question_tm_called
  end
end
