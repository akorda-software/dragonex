defmodule Dragonex.ScenariosEnTest do
  @moduledoc """
  English bibles (D236): NPC strings parse into facts, the enemies line is a
  translatable prompt, and a game created from a scenario is written in the
  GAME's language even when the wizard resolved the scenario in another one.
  """
  use ExUnit.Case, async: true
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{Games, I18n, Scenarios}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragonex.Repo)
    :ok
  end

  defp en(fun), do: I18n.with_locale(:en, fun)
  defp es(fun), do: I18n.with_locale(:es, fun)

  describe "npc facts" do
    test "English NPC strings produce named-role facts in :en" do
      npcs =
        "Borin the innkeeper (human, nervous), the guard Sable (human, stoic), " <>
          "the ghost of Aldric (apparition), old Mira (brave villager)"

      facts = en(fn -> Scenarios.seed_facts(%{"npcs" => npcs}) end)

      expected =
        en(fn ->
          [
            dgettext("prompts", "El %{role} se llama %{name}.", role: "innkeeper", name: "Borin"),
            dgettext("prompts", "%{article} %{role} se llama %{name}.",
              article: "The",
              role: "guard",
              name: "Sable"
            ),
            dgettext("prompts", "%{name} está en esta aventura.", name: "Aldric"),
            dgettext("prompts", "%{name} está en esta aventura.", name: "Mira")
          ]
        end)

      assert facts == expected
    end

    test "a Spanish custom bible still parses inside an English game" do
      facts = en(fn -> Scenarios.seed_facts(%{"npcs" => "Borin el posadero (humano)"}) end)

      assert facts ==
               en(fn ->
                 [
                   dgettext("prompts", "El %{role} se llama %{name}.",
                     role: "posadero",
                     name: "Borin"
                   )
                 ]
               end)
    end

    test "Spanish parsing is unchanged" do
      assert es(fn ->
               Scenarios.seed_facts(%{
                 "npcs" => "Borin el posadero (humano, nervioso), la guardia Sable (humana)"
               })
             end) == ["El posadero se llama Borin.", "La guardia se llama Sable."]

      # English grammar is not applied to Spanish games.
      assert es(fn -> Scenarios.seed_facts(%{"npcs" => "Borin the innkeeper"}) end) ==
               ["Borin está en esta aventura."]
    end
  end

  describe "bible enemies line" do
    test "Spanish games no longer carry the hard-coded English sentence" do
      bible = es(fn -> Scenarios.bible(Scenarios.get("tavern")) end)

      assert bible["enemies"] ==
               "El DM puede introducir estos enemigos cuando la historia lo pida: goblin, goblin, wolf"

      refute bible["enemies"] =~ "The DM may introduce"

      assert "Los enemigos previstos son: goblin, wolf." in es(fn ->
               Scenarios.seed_facts(bible)
             end)
    end

    test "the enemies line follows the locale through the prompts catalog" do
      bible = en(fn -> Scenarios.bible(Scenarios.get("tavern")) end)

      assert bible["enemies"] ==
               en(fn ->
                 dgettext(
                   "prompts",
                   "El DM puede introducir estos enemigos cuando la historia lo pida: %{enemies}",
                   enemies: "goblin, goblin, wolf"
                 )
               end)
    end
  end

  describe "wizard creation in the game's locale" do
    test "an English game re-resolves a scenario picked in a Spanish UI" do
      # The UI process runs in Spanish; the stale title proves re-resolution.
      ui_scenario = es(fn -> %{Scenarios.get("tavern") | title: "TÍTULO DE LA UI"} end)

      assert {:ok, game} =
               es(fn ->
                 Games.create_from_wizard_choices(%{
                   scenario: ui_scenario,
                   my_hero: "fighter",
                   companions: [],
                   locale: "en"
                 })
               end)

      english = en(fn -> Scenarios.get("tavern") end)
      english_bible = en(fn -> Scenarios.bible(english) end)

      assert game.locale == "en"
      assert game.title == english.title
      assert game.dm_style == english.dm_style
      assert game.story_bible == english_bible

      world = Games.load_world(game)
      assert world.scene == english.scene

      for fact <- en(fn -> Scenarios.seed_facts(english_bible) end) do
        assert fact in world.facts
      end
    end

    test "a Spanish game keeps the Spanish scenario" do
      assert {:ok, game} =
               en(fn ->
                 Games.create_from_wizard_choices(%{
                   scenario: en(fn -> Scenarios.get("crypt") end),
                   my_hero: "fighter",
                   companions: [],
                   locale: "es"
                 })
               end)

      spanish = es(fn -> Scenarios.get("crypt") end)
      assert game.title == spanish.title
      assert game.story_bible == es(fn -> Scenarios.bible(spanish) end)
      assert "El lugar inicial es la cripta del Rey Olvidado." in Games.load_world(game).facts
    end
  end
end
