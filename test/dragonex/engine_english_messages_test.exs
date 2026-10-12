defmodule Dragonex.EngineEnglishMessagesTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Archetypes, ClassResources, I18n, Monsters, Rest, TurnBudget, World}
  alias Dragonex.Heroes.Catalog

  # D236: engine feedback outside `Actions` (turn budget, rests, class pools,
  # concentration) and catalog content follow the table language.
  setup do
    I18n.put_locale(:en)
    :ok
  end

  defp seq(rolls) do
    Process.put(:rolls, rolls)

    fn _sides ->
      [roll | rest] = Process.get(:rolls)
      Process.put(:rolls, rest)
      roll
    end
  end

  defp world do
    World.new(
      characters: %{
        "Thane" => Archetypes.fighter(),
        "Lyra" => Archetypes.wizard(),
        "goblin" => Monsters.goblin(name: "goblin")
      }
    )
    |> World.init_spell_slots()
  end

  test "turn budget and rest refusals are English" do
    w = %{world() | phase: :combat, current_combatant: "Thane", initiative_order: ["Thane"]}

    assert {:error, msg} = TurnBudget.check(w, "Lyra", :action)
    assert msg =~ "It is not Lyra's turn; the current combatant is Thane."

    spent = %{w | turn_state: %{"Thane" => %{"round" => w.round, "bonus" => true}}}

    assert TurnBudget.check(spent, "Thane", :bonus) ==
             {:error, "Thane has already used their bonus action this turn"}

    assert Rest.validate(w, "Thane", :short) == {:error, "you cannot rest during combat"}
  end

  test "class pools are labelled in English" do
    labels =
      Archetypes.wizard() |> Map.merge(%{class: "sorcerer", level: 3}) |> ClassResources.pools()

    assert Enum.map(labels, & &1.label) == ["Sorcery points"]
  end

  test "losing concentration names the spell in English" do
    w = put_in(world().characters["Thane"].concentrating, "bless")
    # Hit (d20 15), 1 fire damage, failed concentration save (d20 2).
    {:ok, msg, _} = Actions.spell(w, "Lyra", "firebolt", "Thane", seq([15, 1, 2]), nil)

    assert msg =~ "Thane loses concentration on Bless (d20 2:"
    refute msg =~ ~r/concentración|Bendición/
  end

  test "spell effects in the catalog follow the locale" do
    effect = fn locale -> Enum.find(Catalog.spells(locale), &(&1.key == "fire bolt")).effect end

    assert effect.(:en) =~ "You hurl a mote of fire"
    assert effect.(:es) =~ "Lanzas una mota de fuego"
  end
end
