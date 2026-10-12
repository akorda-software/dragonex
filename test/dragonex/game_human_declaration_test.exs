defmodule Dragonex.GameHumanDeclarationTest.Model do
  @behaviour ExAgent.Model
  alias ExAgent.{Message, Message.Part}
  defstruct [:counter, :owner, mode: :normal]

  @impl true
  def request(model, messages, _settings, _params) do
    step = Agent.get_and_update(model.counter, &{&1, &1 + 1})
    send(model.owner, {:human_resolution_request, step, messages})

    cond do
      step == 1 and model.mode == :retry ->
        {:error,
         %ExAgent.RequestError{
           provider: :req_llm,
           status: 503,
           reason: :http_error,
           body: "overloaded"
         }}

      step == 1 and model.mode in [:failed, :failed_replay, :failed_twice] ->
        {:error, %ExAgent.RequestError{provider: :req_llm, status: 400, reason: :http_error}}

      step == 2 and model.mode == :failed_twice ->
        {:error, %ExAgent.RequestError{provider: :req_llm, status: 400, reason: :http_error}}

      step == 0 or (step == 2 and model.mode in [:retry, :failed_replay]) ->
        call = %Part.ToolCall{
          tool_name: "make_attack",
          tool_call_id: "attack-#{step}",
          args: %{"attacker" => "Thane", "target" => "g1", "weapon" => "longsword"}
        }

        {:ok,
         Message.new_response([%Part.Text{content: "Sonrío y prometo acabar con él."}, call]),
         model}

      step == 1 and model.mode == :blocked ->
        send(model.owner, {:human_attack_applied, self()})

        receive do: (:finish ->
                       {:ok,
                        Dragonex.Test.Harness.narration_response("Invento un grito de victoria."),
                        model})

      (step == 1 and model.mode == :normal) or
          (step == 3 and model.mode in [:retry, :failed_replay]) ->
        {:ok,
         Dragonex.Test.Harness.narration_response(
           "«No dejaré supervivientes», grito, girando la espada."
         ), model}

      true ->
        {:ok,
         Dragonex.Test.Harness.narration_response(
           "El goblin yace inmóvil y el patio está en calma."
         ), model}
    end
  end

  @impl true
  def request_stream(model, messages, settings, params) do
    case request(model, messages, settings, params) do
      {:error, reason} ->
        [{:error, reason}]

      {:ok, response, updated} ->
        [
          {:text_delta, ExAgent.Message.Response.text(response)},
          Dragonex.Test.Harness.stream_response(response, updated)
        ]
    end
  end

  @impl true
  def model_name(_), do: "human-declaration-test"
  @impl true
  def system(_), do: "test"
  @impl true
  def profile(_), do: %ExAgent.ModelProfile{supports_tools: true}
end

defmodule Dragonex.GameHumanDeclarationTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Game, Games, History, Monsters}
  alias Dragonex.GameHumanDeclarationTest.Model
  alias Dragonex.Test.ModelMessages
  alias ExAgent.Models.Test
  @declaration "Ataco al goblin con mi espada larga y digo: «Atrás»."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    old = Application.get_env(:dragonex, :transient_backoffs)
    Application.put_env(:dragonex, :transient_backoffs, [10, 10, 10])

    on_exit(fn ->
      if old,
        do: Application.put_env(:dragonex, :transient_backoffs, old),
        else: Application.delete_env(:dragonex, :transient_backoffs)
    end)

    {:ok, game} =
      Games.create_game(
        title: "Declaro, el motor resuelve",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(name: "g1"), :ai}],
        initiative: ["Thane", "g1"]
      )

    world = Games.load_world(game) |> put_in([Access.key(:characters), "g1", Access.key(:hp)], 1)
    {:ok, _} = Games.save_state(game.id, world, "Thane", world.round, :paused)
    counter = start_supervised!({Agent, fn -> 0 end})
    %{game: game, before: world, counter: counter}
  end

  defp options(model) do
    [
      model: model,
      scene_model: %Test{label: "El patio sigue igual."},
      roller: fn
        20 -> 15
        8 -> 1
      end,
      turnmaster_model: %Test{
        script: [tool_calls([call("give_turn_to", %{"participant" => "Thane"})]), "listo"]
      }
    ]
  end

  defp finish(pid) do
    assert :ok ==
             Game.await(
               pid,
               &(&1.status == :waiting and &1.current == "Thane" and
                   &1.world.phase == :exploration),
               5_000
             )

    assert :ok == Game.pause(pid)
  end

  defp verify(game, pid, before) do
    after_world = Game.world(pid)
    assert after_world.characters["g1"].hp == 0
    assert after_world.characters["Thane"] == before.characters["Thane"]
    assert after_world.elapsed_seconds == before.elapsed_seconds
    assert Games.load_world(Games.get_game(game.id)) == after_world
    events = Games.list_events(game.id)
    assert Enum.count(events, &(&1.type == :dice)) == 2

    assert [
             %{
               payload: %{
                 "text" => @declaration,
                 "kind" => "human_declaration",
                 "complete" => true
               }
             }
           ] = Enum.filter(events, &(&1.type == :narration and &1.actor == "Thane"))

    assert Enum.count(events, &(&1.type == :action and &1.actor == "Thane")) == 1

    context =
      History.import_events(events) |> ModelMessages.project() |> inspect(limit: :infinity)

    refute context =~ "No dejaré supervivientes"
    refute context =~ "Sonrío y prometo"
    assert context =~ "Thane declara" and context =~ "Atrás"
  end

  for mode <- [:normal, :retry] do
    test "#{mode} preserves the human's exact voice and acknowledged attack, without generated previews",
         %{game: game, before: before, counter: counter} do
      model = %Model{counter: counter, owner: self(), mode: unquote(mode)}
      pid = Dragonex.Test.GameFixture.start!({Game, {game.id, options(model)}})
      :ok = Phoenix.PubSub.subscribe(Dragonex.PubSub, "dragonex:game:#{game.id}")
      assert :ok == Game.resume(pid)
      assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
      assert {:ok, :resolving} = Game.declare(pid, "Thane", @declaration)
      finish(pid)
      verify(game, pid, before)
      game_id = game.id
      refute_received {:text_delta, ^game_id, _, "Thane", _}
      # Neither actor exposes free response text as a public preview.
      refute_received {:text_delta, ^game_id, _, "dm", _}

      assert Enum.any?(
               Games.list_events(game.id),
               &(&1.type == :narration and &1.actor == "dm" and
                   &1.payload["text"] =~ "El goblin yace inmóvil")
             )

      assert_receive {:human_resolution_request, 1, messages}
      # Native private continuation keeps the provider's original content;
      # verify/4 independently rejects it from SQL and shared public history.
      assert inspect(messages, limit: :infinity) =~ "Sonrío y prometo"
    end
  end

  test "restarting after tools recovers the same durable declaration without a second attack", %{
    game: game,
    before: before,
    counter: counter
  } do
    model = %Model{counter: counter, owner: self(), mode: :blocked}
    {:ok, pid} = Game.ensure_started(game.id, options(model))
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert {:ok, :resolving} = Game.declare(pid, "Thane", @declaration)
    assert_receive {:human_attack_applied, run}, 2_000

    try do
      assert Game.world(pid).characters["g1"].hp == 0
      assert :ok == Game.pause(pid)
      reopened_model = %Model{counter: counter, owner: self()}
      {:ok, reopened} = Game.restart(game.id, options(reopened_model))
      assert :ok == Game.resume(reopened)
      finish(reopened)
      verify(game, reopened, before)
    after
      Dragonex.Game.Supervisor.stop_game(game.id)
      if Process.alive?(run), do: Process.exit(run, :kill)
    end
  end

  test "autoplay keeps its own model voice instead of a previous human declaration", %{game: game} do
    {:ok, _} =
      Games.append_event(game.id, :action, "Thane", "all", %{
        text: "Me quedo aquí.",
        turn_id: "previous"
      })

    voice = "Bajo la espada y observo el patio."

    model = %Test{
      script: [
        tool_calls([
          call("make_attack", %{"attacker" => "Thane", "target" => "g1", "weapon" => "longsword"})
        ]),
        narration(voice)
      ],
      label: "El patio está en calma."
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, options(model)}})
    assert :ok == Game.enable_auto_play(pid, "Thane")
    assert :ok == Game.resume(pid)

    assert :ok ==
             Game.await(
               pid,
               &Enum.any?(&1.events, fn e ->
                 e.actor == "Thane" and e.type == :narration and e.payload["text"] == voice
               end)
             )

    assert :ok == Game.pause(pid)

    assert Enum.any?(
             Games.list_events(game.id),
             &(&1.actor == "Thane" and &1.type == :narration and &1.payload["text"] == voice and
                 &1.payload["kind"] != "human_declaration")
           )
  end

  # 19447/52 returned the floor with the declaration unresolved. A hard
  # failure now pauses the same turn; resume finishes it without new effects.
  for mode <- [:failed, :failed_replay] do
    test "#{mode}: a failed manual resolver pauses its turn and resume completes it once", %{
      game: game,
      before: before,
      counter: counter
    } do
      model = %Model{counter: counter, owner: self(), mode: unquote(mode)}
      pid = Dragonex.Test.GameFixture.start!({Game, {game.id, options(model)}})
      assert :ok == Game.resume(pid)
      assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
      assert {:ok, :resolving} = Game.declare(pid, "Thane", @declaration)
      assert :ok == Game.await(pid, &(&1.status == :paused), 5_000)

      events = Games.list_events(game.id)
      turn = Enum.find(events, &(&1.type == :action)).payload["turn_id"]
      assert Enum.count(events, &(&1.type == :dice)) == 2
      refute Enum.any?(events, &(&1.type == :narration and &1.actor == "Thane"))

      assert [note] =
               Enum.filter(events, &(&1.type == :system and &1.payload["turn_id"] == turn))

      assert note.visible_to == "all"
      assert note.payload["kind"] == "turn_retained"
      assert note.payload["note"] =~ "Thane no pudo completarse"
      assert note.payload["note"] =~ "Reanuda"
      assert Games.load_world(Games.get_game(game.id)).actor_checkpoint["turn_id"] == turn
      assert Game.world(pid).characters["g1"].hp == 0

      assert :ok == Game.resume(pid)
      finish(pid)
      events = Games.list_events(game.id)
      assert Enum.count(events, &(&1.type == :dice)) == 2
      assert Games.completed_narration(game.id, "Thane", turn) == @declaration

      assert Enum.count(
               events,
               &(&1.type == :turn and &1.actor == "Thane" and &1.payload["turn_id"] == turn)
             ) == 1

      assert Game.world(pid).characters["Thane"] == before.characters["Thane"]
    end
  end

  test "a turn that fails again after resume is skipped with a note, never invented prose", %{
    game: game,
    before: before,
    counter: counter
  } do
    model = %Model{counter: counter, owner: self(), mode: :failed_twice}
    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, options(model)}})
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert {:ok, :resolving} = Game.declare(pid, "Thane", @declaration)
    assert :ok == Game.await(pid, &(&1.status == :paused), 5_000)
    assert :ok == Game.resume(pid)
    finish(pid)

    events = Games.list_events(game.id)
    assert Enum.count(events, &(&1.type == :dice)) == 2
    refute Enum.any?(events, &(&1.type == :narration and &1.actor == "Thane"))

    assert Enum.any?(
             events,
             &(&1.type == :system and &1.visible_to == "all" and
                 (&1.payload["note"] || "") =~ "La declaración de Thane no pudo completarse")
           )

    assert Game.world(pid).characters["Thane"] == before.characters["Thane"]
    assert Game.world(pid).characters["g1"].hp == 0
    turn = Enum.find(events, &(&1.type == :action)).payload["turn_id"]
    assert Games.completed_narration(game.id, "Thane", turn) == nil
    assert Games.declaration_for_turn(game.id, "Thane", turn) == @declaration
  end

  # 19451/26–30: the creature existed only in prose; the resolver kept trying
  # spawn_monster until the turn failed. The rejection now says how to close.
  test "an attack on a creature without a sheet is closed by the resolver, not retried to failure" do
    {:ok, game} =
      Games.create_game(title: "Ratas sin ficha", roster: [{Archetypes.fighter(), :human}])

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)
    owner = self()
    declaration = "Ataco a la rata más cercana con mi espada larga."

    model = %Test{
      script: [
        tool_calls([
          call("make_attack", %{
            "attacker" => "Thane",
            "target" => "rata",
            "weapon" => "longsword",
            "mode" => "normal"
          })
        ]),
        tool_calls([call("spawn_monster", %{"kind" => "giant_rat", "name" => "rata"})]),
        fn messages, _ ->
          send(owner, {:resolver_feedback, ModelMessages.project(messages)})
          narration("Ataco.")
        end,
        narration("Dos ratas gigantes salen de entre los sacos.")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, options(model)}})
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert {:ok, :resolving} = Game.declare(pid, "Thane", declaration)
    finish(pid)

    assert_receive {:resolver_feedback, context}
    context = inspect(context, limit: :infinity)
    assert context =~ "no existe el objetivo: rata"
    assert context =~ "Una criatura sin ficha solo la registra el DM"
    assert context =~ "si el objetivo aún no tiene ficha, no lo crees ni lo ataques"

    events = Games.list_events(game.id)
    turn = Enum.find(events, &(&1.type == :action)).payload["turn_id"]
    assert Games.completed_narration(game.id, "Thane", turn) == declaration
    refute Enum.any?(events, &(&1.payload["kind"] in ["turn_retained", "turn_skipped"]))
    assert Game.world(pid).characters["Thane"] == before.characters["Thane"]
    refute Map.has_key?(Game.world(pid).characters, "rata")
  end

  test "a pickup keeps the typed quotation and lets only the following DM register possession" do
    {:ok, game} =
      Games.create_game(title: "Sin palabras prestadas", roster: [{Archetypes.fighter(), :human}])

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)
    owner = self()
    declaration = "Recojo la campanilla y digo: «Aquí está»."

    model = %Test{
      script: [
        narration("Ya la tengo, digo, mientras vuelvo a la puerta."),
        fn messages, _ ->
          send(owner, {:pickup_dm, ModelMessages.project(messages)})

          tool_calls([
            call("grant_item", %{"who" => "Thane", "item" => "campanilla", "quantity" => 1})
          ])
        end,
        narration("La campanilla queda en tu mano.")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, options(model)}})
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"))
    assert {:ok, :resolving} = Game.declare(pid, "Thane", declaration)
    finish(pid)
    assert_receive {:pickup_dm, context}
    context = inspect(context, limit: :infinity)
    assert context =~ "Thane declara" and context =~ "Aquí está"
    refute context =~ "Ya la tengo"
    world = Game.world(pid)

    assert world.characters["Thane"].inventory ==
             before.characters["Thane"].inventory ++
               [%Dragonex.Item{name: "campanilla", kind: :gear, qty: 1}]

    assert %{
             world
             | characters: before.characters,
               scene_refresh_pending: before.scene_refresh_pending,
               log: before.log
           } == before

    assert world.scene_refresh_pending
    assert Games.load_world(Games.get_game(game.id)) == world

    assert [%{payload: %{"text" => ^declaration, "kind" => "human_declaration"}}] =
             Enum.filter(
               Games.list_events(game.id),
               &(&1.type == :narration and &1.actor == "Thane")
             )
  end
end
