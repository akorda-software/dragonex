defmodule Dragonex.GameResourceContextTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness
  alias Dragonex.{Game, Games, Heroes}
  alias ExAgent.{Models.Test, Server}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "the next DM beat reads the human's paid class reserve from the current World" do
    {:ok, sheet} =
      Heroes.build(%{
        name: "Sira de la Chispa",
        race: "human",
        class: "sorcerer",
        level: 2,
        background: "sage"
      })

    {:ok, game} = Games.create_game(title: "La reserva", roster: [{sheet, :human}])
    owner = self()

    observe = fn stage ->
      fn messages, _params ->
        send(
          owner,
          {:resource_context, stage,
           inspect(messages, limit: :infinity, printable_limit: :infinity)}
        )

        narration("La puerta permanece cerrada. ¿Qué quieres comprobar?")
      end
    end

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Test{script: [observe.(:before)]}]}}
      )

    assert :ok = Game.await(pid, &(&1.current == sheet.name and &1.status == :waiting))
    assert_receive {:resource_context, :before, context}
    assert context =~ "Puntos de hechicería: 2/2"
    before = Game.world(pid)
    state = :sys.get_state(pid)

    assert :ok =
             Server.set_model(state.dm, %Test{
               script: [
                 tool_calls([call("create_spell_slot", %{"who" => sheet.name, "level" => 1})]),
                 narration("Anoto la conversión en mi cuaderno."),
                 observe.(:after)
               ]
             })

    assert {:ok, :resolving} =
             Game.declare(
               pid,
               sheet.name,
               "Convierto mis dos puntos en una casilla de nivel uno."
             )

    assert :ok = Game.await(pid, &(&1.current == sheet.name and &1.status == :waiting))
    assert_receive {:resource_context, :after, context}
    assert context =~ "Puntos de hechicería: 0/2"
    assert context =~ "Casillas: N1:4"
    assert :ok = Game.pause(pid)
    paid = Game.world(pid)
    assert paid.characters[sheet.name].sorcery_points == 0
    assert paid.spell_slots[sheet.name] == %{1 => 4}
    assert paid.characters[sheet.name].hp == before.characters[sheet.name].hp
    assert paid.elapsed_seconds == before.elapsed_seconds
    assert paid.rest_state == before.rest_state
    assert Games.load_world(Games.get_game(game.id)) == paid
  end
end
