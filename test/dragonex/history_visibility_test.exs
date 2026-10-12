defmodule Dragonex.HistoryVisibilityTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, History, World}
  alias Dragonex.Game.SceneRefresh
  alias Dragonex.Games.GameEvent
  alias ExAgent.Models.Test
  alias Dragonex.Test.ModelMessages

  defp event(type, visibility, seq, text) do
    %GameEvent{
      type: type,
      actor: "dm",
      visible_to: visibility,
      seq: seq,
      payload: %{
        "text" => text,
        "note" => text,
        "reason" => text,
        "kind" => "start",
        "round" => 1,
        "phase" => "exploration"
      }
    }
  end

  defp wire(events), do: History.from_events(events) |> ModelMessages.project()

  defp wire(events, viewer),
    do: History.from_events(events, viewer) |> ModelMessages.project()

  defp contents(messages), do: Enum.map_join(messages, "\n", & &1["content"])

  test "shared history removes every private event type before reconstruction" do
    events =
      for {type, index} <- Enum.with_index([:narration, :action, :dice, :system, :turn], 1),
          visibility <- ["all", "dm"],
          do: event(type, visibility, index, "#{visibility}-#{type}-marker")

    shared = contents(wire(events))

    for type <- [:narration, :action, :dice, :system] do
      assert shared =~ "all-#{type}-marker"
      refute shared =~ "dm-#{type}-marker"
    end

    assert wire(events, "Lyra") == wire(events)
    assert wire(events, "Vex") == wire(events)
  end

  test "only an explicit DM history sees DM notes while unknown audiences stay excluded" do
    events = [
      event(:system, "all", 1, "PublicMarker"),
      event(:system, "dm", 2, "PrivateMarker"),
      event(:system, "Lyra", 3, "UnsupportedPrivateMarker"),
      event(:system, "DM", 4, "InvalidMarker")
    ]

    refute contents(wire(events)) =~ "PrivateMarker"
    dm = contents(wire(events, "dm"))
    assert dm =~ "PublicMarker"
    assert dm =~ "PrivateMarker"
    refute dm =~ "UnsupportedPrivateMarker"
    refute dm =~ "InvalidMarker"

    for viewer <- [nil, "", "DM", :dm, "Lyra"],
        do: assert(wire(events, viewer) == wire(events))
  end

  test "hidden turn markers and hidden old prose cannot affect public headers or compression" do
    hidden = %{event(:turn, "dm", 1, "HiddenMarker") | actor: "HiddenActor"}
    public = %{event(:narration, "all", 2, "VisibleOpening") | actor: "Thane"}
    old = for n <- 3..20, do: event(:narration, "dm", n, String.duplicate("HiddenMarker ", 40))

    recent =
      for n <- 21..32,
          do: %{
            event(:narration, "all", n, String.duplicate("palabra ", 40) <> "VisibleTail#{n}.")
            | actor: "PC#{n}"
          }

    shared = contents(wire([hidden, public] ++ old ++ recent))
    refute shared =~ "HiddenActor"
    refute shared =~ "HiddenMarker"
    assert shared =~ "[Thane]: VisibleOpening"
    for n <- 21..32, do: assert(shared =~ "VisibleTail#{n}.")
    assert Enum.all?(wire([hidden, public] ++ old ++ recent), &String.valid?(&1["content"]))
  end

  test "unrecognized or missing visibility is not silently promoted to public history" do
    events = [
      event(:system, nil, 1, "NilMarker"),
      event(:system, "", 2, "EmptyMarker"),
      event(:system, "unknown", 3, "UnknownMarker"),
      event(:tool, "all", 4, "ToolMarker"),
      %{type: :system, payload: %{"note" => "MissingMarker"}},
      event(:system, "all", 5, "PublicMarker")
    ]

    assert [%{"role" => "user", "content" => "[sistema]: PublicMarker"}] = wire(events)
    assert wire(events, "dm") == wire(events)
  end

  test "the actual scene recorder request uses public evidence rather than private DM notes" do
    parent = self()
    world = World.new(scene: "La plaza.", characters: %{"Thane" => Archetypes.fighter()})
    events = [event(:system, "all", 1, "PublicMarker"), event(:system, "dm", 2, "PrivateMarker")]

    model = %Test{
      script: [
        fn messages, _ ->
          send(parent, {:visible_scene_request, ModelMessages.project(messages)})
          tool_calls([call("final_result", %{"scene" => world.scene})])
        end
      ]
    }

    assert :skip == SceneRefresh.propose(model, world, events, allow_unchanged: true)
    assert_receive {:visible_scene_request, messages}
    assert contents(messages) =~ "PublicMarker"
    refute contents(messages) =~ "PrivateMarker"
    assert Enum.any?(messages, &(&1["role"] == "system"))
  end
end
