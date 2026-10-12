defmodule Dragonex.GameNarrationPreviewTest.StreamingModel do
  @behaviour ExAgent.Model
  alias Dragonex.Test.Harness

  defstruct [:texts, :counter]

  @impl true
  def request(%__MODULE__{} = model, _messages, _settings, _params) do
    {:ok, Harness.narration_response(next(model)), model}
  end

  # Streams final_result the way the provider does: a named opening, then raw
  # argument JSON fragments in exAgent's envelope, then the terminal response.
  @impl true
  def request_stream(%__MODULE__{} = model, _messages, _settings, _params) do
    text = next(model)
    json = Jason.encode!(%{"arguments" => %{"text" => text}})

    fragments =
      json
      |> String.codepoints()
      |> Enum.chunk_every(6)
      |> Enum.map(&{:tool_call_delta, %{index: 0, name: nil, fragment: Enum.join(&1)}})

    [{:tool_call_delta, %{index: 0, name: "final_result", fragment: ""}}] ++
      fragments ++ [Harness.stream_response(Harness.narration_response(text), model)]
  end

  defp next(%{texts: texts, counter: counter}) do
    index = Agent.get_and_update(counter, &{&1, &1 + 1})
    Enum.at(texts, index, List.last(texts))
  end

  @impl true
  def model_name(_), do: "streaming-preview"
  @impl true
  def system(_), do: "test"
  @impl true
  def profile(_), do: %ExAgent.ModelProfile{supports_tools: true}
end

defmodule Dragonex.GameNarrationPreviewTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Dragonex.{Archetypes, Game, Games}
  alias Dragonex.GameNarrationPreviewTest.StreamingModel

  # The published exAgent (Hex 2.0) does not forward tool-argument previews.
  @previews Map.has_key?(struct(ExAgent.ModelRequestParameters), :tool_call_deltas)
  @moduletag skip: if(@previews, do: false, else: "exAgent without tool-call previews")

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp game do
    {:ok, game} =
      Games.create_game(title: "Narración en vivo", roster: [{Archetypes.fighter(), :human}])

    world = %{Games.load_world(game) | scene_refresh_pending: false}
    {:ok, _} = Games.save_state(game.id, world, "dm", world.round, :paused)
    game
  end

  defp model(texts) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    %StreamingModel{texts: texts, counter: counter}
  end

  defp previews(game_id, acc \\ []) do
    receive do
      {:text_delta, ^game_id, _turn, actor, chunk} -> previews(game_id, [{actor, chunk} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # R16: the DM's narration appears on the table as it is generated, then the
  # validated final_result replaces the bubble with the durable event.
  test "the DM's final_result text previews on the table before it is published" do
    game = game()
    text = "Del fondo del molino llega un correteo: «¿Quién anda ahí?», chilla una rata."
    :ok = Phoenix.PubSub.subscribe(Dragonex.PubSub, "dragonex:game:#{game.id}")

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model([text])]}})
    assert :ok = Game.resume(pid)
    assert :ok = Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)

    shown = previews(game.id)
    assert length(shown) > 3
    assert Enum.all?(shown, &match?({"dm", _}, &1))
    assert Enum.map_join(shown, &elem(&1, 1)) == text

    assert Enum.any?(
             Games.list_events(game.id),
             &(&1.type == :narration and &1.actor == "dm" and &1.payload["text"] == text)
           )
  end

  test "a human declaration never previews the resolver's words" do
    game = game()
    :ok = Phoenix.PubSub.subscribe(Dragonex.PubSub, "dragonex:game:#{game.id}")
    model = model(["El patio está en calma.", "Invento palabras que nadie dijo."])

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    assert :ok = Game.resume(pid)
    assert :ok = Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    _dm_opening = previews(game.id)

    assert {:ok, :resolving} = Game.declare(pid, "Thane", "Miro alrededor.")
    assert :ok = Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    refute Enum.any?(previews(game.id), &match?({"Thane", _}, &1))
  end
end
