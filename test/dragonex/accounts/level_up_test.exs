defmodule Dragonex.Accounts.LevelUpTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Accounts, Heroes, Heroes.Progression}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragonex.Repo)

    {:ok, user} =
      Accounts.register(%{email: "xp@test", password: "password123", display_name: "XP"})

    {:ok, char} =
      Heroes.build(%{name: "Thane", race: "human", class: "fighter", background: "soldier"})

    {:ok, hero} = Accounts.save_hero(user, char)
    %{user: user, hero: hero, char: char}
  end

  describe "grant_xp/3" do
    test "suma XP sin cambiar el nivel", %{user: user, hero: hero} do
      {:ok, updated} = Accounts.grant_xp(user, hero.id, 300)
      sheet = Accounts.hero_sheet(updated)
      assert sheet.xp == 300
      assert updated.level == 1
    end

    test "no se bloquea aunque el héroe esté en partida", %{user: user, hero: hero} do
      # Aunque marque hero_used? false aquí, el punto es que grant_xp no consulta hero_used?
      {:ok, _} = Accounts.grant_xp(user, hero.id, 100)
      assert Accounts.hero_sheet(Accounts.get_user_hero(user, hero.id)).xp == 100
    end
  end

  describe "level_up_hero/3" do
    test "aplica la subida al héroe de biblioteca", %{user: user, hero: hero} do
      {:ok, _} = Accounts.grant_xp(user, hero.id, Progression.xp_threshold(2))

      {:ok, leveled} = Accounts.level_up_hero(user, hero.id, %{})
      assert leveled.level == 2
      sheet = Accounts.hero_sheet(leveled)
      assert sheet.level == 2
      assert sheet.max_hp > 0
    end

    test "respeta elecciones de ASI al subir a 4", %{user: user, hero: hero} do
      # Lleva al héroe a nivel 3 acumulando XP
      {:ok, h2} = Accounts.level_up_hero(user, hero.id, %{})
      {:ok, h3} = Accounts.level_up_hero(user, h2.id, %{})

      str_before = Accounts.hero_sheet(h3).str
      {:ok, h4} = Accounts.level_up_hero(user, h3.id, %{asi: %{str: 2}})

      assert h4.level == 4
      assert Accounts.hero_sheet(h4).str == min(20, str_before + 2)
    end

    test "an expected level permits one confirmation and rejects a stale retry", %{
      user: user,
      hero: hero
    } do
      assert {:ok, leveled} = Accounts.level_up_hero(user, hero.id, %{expected_level: 1})
      assert leveled.level == 2
      assert {:ok, credited} = Accounts.grant_xp(user, hero.id, 100)
      assert {:error, :stale_level} = Accounts.level_up_hero(user, hero.id, %{expected_level: 1})
      assert Accounts.get_user_hero(user, hero.id).sheet == credited.sheet
      assert Accounts.hero_sheet(credited).level == 2
      assert Accounts.hero_sheet(credited).xp == 400
    end

    test "a stale confirmation cannot spend ASI choices on a later level", %{
      user: user,
      hero: hero
    } do
      assert {:ok, leveled} = Accounts.level_up_hero(user, hero.id, %{expected_level: 1})
      assert {:ok, third} = Accounts.level_up_hero(user, hero.id, %{expected_level: 2})
      assert third.level == 3

      assert {:error, :stale_level} =
               Accounts.level_up_hero(user, hero.id, %{expected_level: 2, asi: %{str: 2}})

      assert Accounts.get_user_hero(user, hero.id).sheet == third.sheet
      assert Accounts.hero_sheet(third).str == Accounts.hero_sheet(leveled).str
    end

    test "malformed expected levels return an error without applying a progression", %{
      user: user,
      hero: hero
    } do
      for value <- [nil, "1", %{}, -1] do
        assert {:error, :invalid_level} =
                 Accounts.level_up_hero(user, hero.id, %{expected_level: value})
      end

      assert Accounts.get_user_hero(user, hero.id).sheet == hero.sheet
    end
  end
end
