defmodule Dragones.WizardCreateTest do
  use ExUnit.Case, async: true

  alias Dragones.Games

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragones.Repo)
    :ok
  end

  test "builds a roster from wizard params and begins combat (monsters first)" do
    params = %{
      "title" => "La Ruina",
      "scene" => "una ruina iluminada por antorchas",
      "dm_style" => "sombrío",
      "roster" => %{
        "fighter" => %{"include" => "on", "kind" => "human"},
        "goblin" => %{"include" => "on"}
      }
    }

    assert {:ok, game} = Games.create_from_wizard(params)

    assert game.title == "La Ruina"
    assert game.dm_style == "sombrío"

    world = Games.load_world(game)
    assert world.scene == "una ruina iluminada por antorchas"
    assert world.phase == :combat
    # Monsters first in initiative (DM auto-acts on open), then the PC.
    assert world.initiative_order == ["goblin", "Thane"]

    reloaded = Games.get_game(game.id)
    assert Enum.find(reloaded.participants, &(&1.name == "Thane")).kind == :human
    assert Enum.find(reloaded.participants, &(&1.name == "dm")).kind == :ai
  end

  test "an AI PC is marked :ai" do
    params = %{
      "roster" => %{
        "wizard" => %{"include" => "on", "kind" => "ai"},
        "goblin" => %{"include" => "on"}
      }
    }

    assert {:ok, game} = Games.create_from_wizard(params)
    assert Enum.find(game.participants, &(&1.name == "Lyra")).kind == :ai
  end

  test "without a monster it stays in exploration" do
    params = %{
      "roster" => %{
        "fighter" => %{"include" => "on", "kind" => "human"},
        "rogue" => %{"include" => "on", "kind" => "human"}
      }
    }

    assert {:ok, game} = Games.create_from_wizard(params)
    assert Games.load_world(game).phase == :exploration
  end

  test "with no selection it refuses" do
    assert {:error, :no_characters} = Games.create_from_wizard(%{"roster" => %{}})
  end
end
