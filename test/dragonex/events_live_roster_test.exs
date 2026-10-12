defmodule Dragonex.EventsLiveRosterTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Events, Game, Games, History, Monsters}
  alias ExAgent.{Message, Models.Test}
  alias ExAgent.Session.SharedState

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  for {pc_name, new_name} <- [{"Lyra", "Lyra del Muelle"}, {"Mara de la Bruma", "Mara del Río"}] do
    test "the current roster preserves #{new_name} created in the same DM beat" do
      pc = Archetypes.wizard(name: unquote(pc_name))
      new_name = unquote(new_name)
      {:ok, game} = Games.create_game(title: "Voces nuevas", roster: [{pc, :human}])
      before = Games.load_world(game)

      ambiguous =
        if pc.name == "Mara de la Bruma", do: " «¿Hay sitio en la barca?», dice Mara.", else: ""

      raw = "«Volved al amanecer», dice #{new_name}. «Aceptamos», dice #{pc.name}." <> ambiguous

      model = %Test{
        script: [
          tool_calls([call("spawn_monster", %{"kind" => "bandit", "name" => new_name})]),
          narration(raw)
        ]
      }

      pid =
        Dragonex.Test.GameFixture.start!(
          {Game, {game.id, [model: model, roller: fixed_roller(10)]}}
        )

      assert :ok = Game.await(pid, &(&1.current == pc.name and &1.status == :waiting))
      assert :ok = Game.pause(pid)

      world = Game.world(pid)
      assert world.characters[pc.name] == before.characters[pc.name]
      assert world.characters[new_name] == Monsters.bandit(name: new_name)
      assert world.spell_slots == before.spell_slots
      assert world.rest_state == before.rest_state
      assert world.elapsed_seconds == before.elapsed_seconds
      assert Games.load_world(Games.get_game(game.id)) == world
      history = History.from_events(Games.list_events(game.id)) |> inspect()
      assert history =~ "Volved al amanecer"
      assert history =~ "dice #{new_name}"
      refute history =~ "Aceptamos"
      if ambiguous != "", do: assert(history =~ "¿Hay sitio en la barca?")
    end
  end

  test "an uncommitted tool argument does not acquire a registered character's voice" do
    pc = Archetypes.wizard()
    {:ok, game} = Games.create_game(title: "Alta rechazada", roster: [{pc, :human}])
    before = Games.load_world(game)

    model = %Test{
      script: [
        tool_calls([call("spawn_monster", %{"kind" => "unknown", "name" => "Lyra del Muelle"})]),
        narration("«Volved al amanecer», dice Lyra del Muelle. El muelle está en calma.")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    assert :ok = Game.await(pid, &(&1.current == pc.name and &1.status == :waiting))
    assert :ok = Game.pause(pid)
    assert Game.world(pid) == before
    history = History.from_events(Games.list_events(game.id)) |> inspect()
    refute history =~ "Volved al amanecer"
    assert history =~ "El muelle está en calma"
  end

  test "event publication keeps snapshot context when no usable shared-state handle exists" do
    {:ok, game} =
      Games.create_game(title: "Contexto compatible", roster: [{Archetypes.wizard(), :human}])

    beat = %{
      game_id: game.id,
      actor: "dm",
      turn_id: "fallback",
      pc_names: ["Lyra"],
      character_names: ["Lyra", "Lyra del Muelle"]
    }

    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _}
    handle = SharedState.new(dead, "dm")
    raw = "«Volved al amanecer», dice Lyra del Muelle. «Aceptamos», dice Lyra."

    for deps <- [%{beat: beat}, %{beat: beat, state: %{}}, %{beat: beat, state: handle}] do
      state = %{deps: deps, messages: [Message.new_response([%Message.Part.Text{content: raw}])]}
      assert Events.after_model_request(Events, state) == state
    end

    events = Games.list_events(game.id) |> Enum.filter(&(&1.payload["turn_id"] == "fallback"))
    assert length(events) == 3

    for event <- events do
      assert event.payload["text"] =~ "Volved al amanecer"
      assert event.payload["text"] =~ "dice Lyra del Muelle"
      refute event.payload["text"] =~ "Aceptamos"
    end
  end
end
