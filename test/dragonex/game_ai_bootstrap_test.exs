defmodule Dragonex.GameAIBootstrapTest do
  @moduledoc """
  A table rebuilds its AI from `games.ai` (D242): a crash or a server restart
  keeps the payer and the model the creator chose.
  """

  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Dragonex.{Accounts, Archetypes, Game, Games}

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "boot-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Paga"
      })

    {:ok, game} =
      Games.create_game(title: "IA", user_id: user.id, roster: [{Archetypes.fighter(), :human}])

    {:ok, game} = Games.save_state(game.id, Games.load_world(game), "Thane", 1, :paused, %{})
    on_exit(fn -> Game.Supervisor.stop_game(game.id) end)
    %{user: user, game: game}
  end

  test "an own-key table starts on the player's model", %{user: user, game: game} do
    :ok = Accounts.put_api_key(user, "google", "g-player-key-4242")

    :ok =
      Games.set_ai(game.id, %{
        "source" => "own",
        "provider" => "google",
        "model" => "gemini-2.5-flash",
        "metadata" => nil
      })

    {:ok, pid} = Game.Supervisor.start_game(game.id, [])
    state = :sys.get_state(pid)
    assert state.model.inner.model.id == "gemini-2.5-flash"
    assert state.model.inner.api_key == "g-player-key-4242"
    assert state.summarizer == state.model
  end

  test "without the key the table still starts, on the default models", %{game: game} do
    :ok =
      Games.set_ai(game.id, %{
        "source" => "own",
        "provider" => "google",
        "model" => "gemini-2.5-flash",
        "metadata" => nil
      })

    {:ok, pid} = Game.Supervisor.start_game(game.id, [])
    assert %ExAgent.Models.Test{} = :sys.get_state(pid).model
  end
end
