defmodule Dragonex.AccountsTest do
  @moduledoc """
  User registration, authentication, and hero persistence.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Accounts, Games, Heroes}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragonex.Repo)
    :ok
  end

  describe "register/1" do
    test "creates a user with a hashed password" do
      {:ok, user} =
        Accounts.register(%{
          email: "Lyra@Dragonex.test",
          password: "arcane123",
          display_name: "Lyra"
        })

      assert user.email == "lyra@dragonex.test"
      assert user.display_name == "Lyra"
      assert user.password_hash != nil
      assert user.password_hash != "arcane123"
    end

    test "rejects duplicate emails" do
      {:ok, _} =
        Accounts.register(%{email: "dup@test", password: "password123", display_name: "A"})

      {:error, cs} =
        Accounts.register(%{email: "dup@test", password: "password123", display_name: "B"})

      assert Keyword.has_key?(cs.errors, :email)
    end

    test "rejects short passwords" do
      {:error, cs} = Accounts.register(%{email: "short@test", password: "123", display_name: "X"})
      assert Keyword.has_key?(cs.errors, :password)
    end
  end

  describe "authenticate/2" do
    test "succeeds with correct credentials" do
      {:ok, _} =
        Accounts.register(%{email: "hero@test", password: "swordfish1", display_name: "Hero"})

      assert {:ok, user} = Accounts.authenticate("hero@test", "swordfish1")
      assert user.email == "hero@test"
    end

    test "fails with wrong password" do
      {:ok, _} =
        Accounts.register(%{email: "hero@test", password: "swordfish1", display_name: "Hero"})

      assert {:error, :invalid} = Accounts.authenticate("hero@test", "wrong")
    end

    test "fails with unknown email" do
      assert {:error, :invalid} = Accounts.authenticate("ghost@test", "whatever")
    end

    test "email is case-insensitive" do
      {:ok, _} =
        Accounts.register(%{
          email: "mixed@Case.test",
          password: "swordfish1",
          display_name: "Hero"
        })

      assert {:ok, _} = Accounts.authenticate("MIXED@case.test", "swordfish1")
    end
  end

  describe "hero persistence" do
    test "save_hero stores a built character and list_heroes retrieves it" do
      {:ok, user} =
        Accounts.register(%{email: "hero@test", password: "password123", display_name: "Hero"})

      {:ok, lyra} =
        Heroes.build(%{
          name: "Lyra",
          race: "elf",
          subrace: "high elf",
          class: "wizard",
          background: "sage"
        })

      {:ok, hero} = Accounts.save_hero(user, lyra)
      assert hero.name == "Lyra"
      assert hero.race == "high elf"
      assert hero.class == "wizard"

      [listed] = Accounts.list_heroes(user)
      assert listed.id == hero.id

      loaded = Accounts.hero_sheet(hero)
      assert loaded.name == "Lyra"
      assert loaded.int == lyra.int
      assert loaded.hp == lyra.hp
    end

    test "get_user_hero only returns heroes owned by the user" do
      {:ok, user_a} =
        Accounts.register(%{email: "a@test", password: "password123", display_name: "A"})

      {:ok, user_b} =
        Accounts.register(%{email: "b@test", password: "password123", display_name: "B"})

      {:ok, char} =
        Heroes.build(%{name: "Thane", race: "human", class: "fighter", background: "soldier"})

      {:ok, hero} = Accounts.save_hero(user_a, char)

      assert Accounts.get_user_hero(user_a, hero.id) != nil
      assert Accounts.get_user_hero(user_b, hero.id) == nil
    end

    test "delete_hero removes the hero" do
      {:ok, user} =
        Accounts.register(%{email: "d@test", password: "password123", display_name: "D"})

      {:ok, char} =
        Heroes.build(%{
          name: "Vex",
          race: "halfling",
          subrace: "lightfoot",
          class: "rogue",
          background: "criminal"
        })

      {:ok, hero} = Accounts.save_hero(user, char)
      {:ok, _} = Accounts.delete_hero(user, hero.id)
      assert Accounts.get_hero(hero.id) == nil
    end

    test "heroes are locked once imported into a game" do
      {:ok, user} =
        Accounts.register(%{email: "locked@test", password: "password123", display_name: "Lock"})

      {:ok, original} =
        Heroes.build(%{name: "Locke", race: "human", class: "fighter", background: "soldier"})

      {:ok, hero} = Accounts.save_hero(user, original)
      refute Accounts.hero_used?(hero)

      assert {:ok, _game} =
               Games.create_from_wizard_choices(%{
                 user_id: user.id,
                 scenario: nil,
                 my_hero: "hero_#{hero.id}",
                 companions: [],
                 dice_engine: "2d"
               })

      assert Accounts.hero_used?(hero)

      {:ok, updated} =
        Heroes.build(%{name: "Locke II", race: "human", class: "fighter", background: "soldier"})

      assert {:error, :in_game} = Accounts.update_hero(user, hero.id, updated)
      assert {:error, :in_game} = Accounts.delete_hero(user, hero.id)
    end

    test "hero_sheet round-trips through codec without data loss" do
      {:ok, user} =
        Accounts.register(%{email: "rt@test", password: "password123", display_name: "RT"})

      {:ok, original} =
        Heroes.build(%{
          name: "Bryn",
          race: "dwarf",
          subrace: "mountain",
          class: "fighter",
          background: "soldier"
        })

      {:ok, hero} = Accounts.save_hero(user, original)
      decoded = Accounts.hero_sheet(hero)

      assert decoded.str == original.str
      assert decoded.ac == original.ac
      assert decoded.hp == original.hp
      assert length(decoded.weapons) == length(original.weapons)
      assert hd(decoded.weapons).name == hd(original.weapons).name
    end
  end
end
