defmodule Dragonex.GameCreationTextTest do
  use ExUnit.Case, async: false
  alias Dragonex.{Archetypes, Games, Repo}

  @style String.duplicate(
           "Narra en castellano con pocas frases. Respeta las decisiones y conserva las dudas de cada testigo.\n",
           6
         ) <> "El farol de Ada está en el cobertizo; el trayecto dura cinco minutos."

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "detailed custom DM instructions persist verbatim with unicode and line breaks" do
    assert String.length(@style) > 255

    assert {:ok, game} =
             Games.create_from_wizard_choices(%{
               scenario: %{key: "custom"},
               my_hero: "fighter",
               companions: ["wizard", "rogue"],
               custom_title: "El farol del vado",
               custom_scene: "Ada pide recuperar el farol.",
               custom_dm_style: @style
             })

    assert game.dm_style == @style
    reloaded = Games.get_game(game.id)
    assert reloaded.dm_style == @style
    assert Games.load_world(reloaded) == Games.load_world(game)
    assert Games.load_world(reloaded).scene == "Ada pide recuperar el farol."
  end

  test "title validation matches the database character limit before any insert" do
    count = Repo.aggregate(Dragonex.Games.Game, :count)

    for title <- [String.duplicate("x", 256), String.duplicate("é", 128)] do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Games.create_game(title: title, roster: [{Archetypes.fighter(), :human}])

      assert changeset.errors[:title]
      assert Ecto.Changeset.get_field(changeset, :title) == title
      assert Repo.aggregate(Dragonex.Games.Game, :count) == count
    end

    title = String.duplicate("🕯", 255)
    assert {:ok, game} = Games.create_game(title: title, roster: [{Archetypes.fighter(), :human}])
    assert Games.get_game(game.id).title == title
  end
end
