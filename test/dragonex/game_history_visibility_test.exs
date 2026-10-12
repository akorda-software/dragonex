defmodule Dragonex.GameHistoryVisibilityTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness, only: [narration: 1]

  alias Dragonex.{Archetypes, Game, Games}
  alias ExAgent.{Models.Test, Server}
  alias Dragonex.Test.ModelMessages

  # An extra spoken declaration retains the human resolver whose audience
  # this test exercises; a lone informative question now publishes locally.
  @question "Lyra, Vex, ¿qué preferís, y qué puede confirmar la posadera? Añado que sigo aquí."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp model(actor) do
    parent = self()

    %Test{
      script: [
        fn messages, _ ->
          send(parent, {:visible_role_request, actor, ModelMessages.project(messages)})
          narration(if actor == "Thane", do: "—#{@question}", else: "—Prefiero seguir esperando.")
        end
      ]
    }
  end

  defp boot do
    {:ok, game} =
      Games.create_game(
        title: "Contexto por visibilidad",
        scene: "Una taberna en calma.",
        roster: [
          {Archetypes.fighter(), :human},
          {Archetypes.wizard(), :ai},
          {Archetypes.rogue(), :ai}
        ]
      )

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)

    for {visibility, marker} <- [
          {"all", "PublicMarker"},
          {"dm", "PrivateMarker"},
          {"Lyra", "UnsupportedMarker"}
        ],
        do: Games.append_event(game.id, :system, "system", visibility, %{note: marker})

    # A hidden turn must not relabel the next public narration either.
    Games.append_event(game.id, :turn, "HiddenActor", "dm", %{
      kind: "start",
      round: 1,
      phase: "exploration"
    })

    Games.append_event(game.id, :narration, "dm", "all", %{text: "PublicNarrationMarker"})
    historical = Games.list_events(game.id)
    parent = self()

    tm = %Test{
      script: [
        fn _, _ ->
          send(parent, :visibility_tm_request)
          "(no decision)"
        end
      ]
    }

    {:ok, pid} = Game.ensure_started(game.id, model: model("Thane"), turnmaster_model: tm)
    install(pid, true)
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
    {game, pid, before, historical}
  end

  defp install(pid, include_human \\ false) do
    state = :sys.get_state(pid)

    dm =
      if include_human,
        do: %Test{script: model("Thane").script ++ model("dm").script},
        else: model("dm")

    assert :ok == Server.set_model(state.dm, dm)

    for {actor, server} <- state.pc_agents,
        do: assert(:ok == Server.set_model(server, model(actor)))
  end

  defp assert_request(actor) do
    assert_receive {:visible_role_request, ^actor, messages}, 2_000
    content = Enum.map_join(messages, "\n", & &1["content"])
    assert content =~ "PublicMarker"
    assert content =~ "PublicNarrationMarker"
    refute content =~ "UnsupportedMarker"

    if actor == "dm",
      do: assert(content =~ "PrivateMarker"),
      else: refute(content =~ "PrivateMarker")

    if actor != "dm", do: refute(content =~ "HiddenActor")

    assert Enum.any?(
             messages,
             &(&1["role"] == "system" and
                 &1["content"] =~
                   if(actor in ["dm", "Thane"],
                     do: "Eres el Dungeon Master",
                     else: "Eres #{actor},"
                   ))
           )

    assert Enum.all?(messages, &String.valid?(&1["content"]))
  end

  defp finish(game, pid, before, historical) do
    assert :ok == Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting), 5_000)
    assert :ok == Game.pause(pid)
    for actor <- ["Thane", "Lyra", "Vex", "dm"], do: assert_request(actor)
    refute_received :visibility_tm_request
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    assert Enum.take(Games.list_events(game.id), length(historical)) == historical

    refute Enum.any?(
             Enum.drop(Games.list_events(game.id), length(historical)),
             &(&1.type == :dice)
           )
  end

  test "the human resolver and both PCs receive only public history while the DM keeps its notes" do
    {game, pid, before, historical} = boot()

    try do
      assert {:ok, :resolving} == Game.declare(pid, "Thane", @question)
      finish(game, pid, before, historical)
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end

  test "reopening during a PC response reapplies visibility without deleting private events" do
    {game, pid, before, historical} = boot()
    parent = self()

    blocked = %Test{
      script: [
        fn _, _ ->
          send(parent, {:visibility_blocked, self()})
          receive do: (:finish -> narration("—Prefiero esperar."))
        end
      ]
    }

    try do
      assert :ok == Server.set_model(:sys.get_state(pid).pc_agents["Lyra"], blocked)
      assert {:ok, :resolving} == Game.declare(pid, "Thane", @question)
      assert_receive {:visibility_blocked, run}, 2_000
      assert :ok == Game.pause(pid)
      pending = Game.world(pid)
      ref = Process.monitor(run)
      assert {:ok, fresh} = Game.restart(game.id, model: model("Thane"))
      assert fresh != pid
      assert_receive {:DOWN, ^ref, :process, ^run, _}, 1_000
      assert Game.world(fresh) == pending
      install(fresh)
      assert :ok == Game.resume(fresh)
      finish(game, fresh, before, historical)
      events = Enum.drop(Games.list_events(game.id), length(historical))

      assert Enum.map(Enum.filter(events, &(&1.type == :narration)), & &1.actor) == [
               "Thane",
               "Lyra",
               "Vex",
               "dm"
             ]
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
    end
  end
end
