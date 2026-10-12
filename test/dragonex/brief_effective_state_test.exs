defmodule Dragonex.BriefEffectiveStateTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Brief, Character, Rules.Effects, Weapon, World}

  test "shield of faith shows effective AC 20 and does not mutate base 18" do
    protected = shield("Aldric")
    hero = protected.characters["Aldric"]

    assert hero.ac == 18
    assert Effects.effective_ac(hero) == 20

    line = line(Brief.world_brief(protected, "dm"), "Aldric")
    assert line =~ "CA 20 (base 18)"
    refute line =~ "CA 18,"
    refute line =~ "CA 18 "
    assert line =~ "clase fighter/Guerrero"
  end

  test "dropping concentration returns the brief to base AC 18" do
    protected = shield("Aldric")
    {:ok, dropped} = World.clear_concentration("C").(protected)

    assert dropped.characters["Aldric"].ac == 18
    line = line(Brief.world_brief(dropped, "dm"), "Aldric")
    assert line =~ "CA 18"
    refute line =~ "CA 20"
    refute line =~ "base 18"
  end

  test "expiring concentration returns the brief to base AC 18" do
    protected = shield("Aldric")
    {:ok, expired} = World.advance_time(600).(protected)

    assert expired.characters["Aldric"].ac == 18
    assert Effects.effective_ac(expired.characters["Aldric"]) == 18
    line = line(Brief.world_brief(expired, "dm"), "Aldric")
    assert line =~ "CA 18"
    refute line =~ "CA 20"
  end

  test "defense style is included by effective_ac and stacks with shield of faith" do
    bare =
      hero("Aldric", ac: 18, fighting_style: "defense")
      |> world()

    assert line(Brief.world_brief(bare, "dm"), "Aldric") =~ "CA 19 (base 18)"
    assert bare.characters["Aldric"].ac == 18

    protected = shield("Aldric", fighting_style: "defense")
    assert Effects.effective_ac(protected.characters["Aldric"]) == 21
    assert line(Brief.world_brief(protected, "dm"), "Aldric") =~ "CA 21 (base 18)"
    assert protected.characters["Aldric"].ac == 18
  end

  test "temporary HP are shown apart from normal HP and max HP" do
    w = hero("Aldric", hp: 12, max_hp: 12, ac: 18) |> world()
    {:ok, w} = World.apply_temp_hp("Aldric", 5).(w)

    assert w.characters["Aldric"].hp == 12
    assert w.characters["Aldric"].max_hp == 12
    assert w.characters["Aldric"].temp_hp == 5

    line = line(Brief.world_brief(w, "dm"), "Aldric")
    assert line =~ "12/12 pg, 5 temporales, CA 18"
    refute line =~ "17/"
    refute line =~ "/17"
  end

  test "zero HP with three successes is stable, not downed" do
    w = downed("Aldric", successes: 3, fails: 0) |> world()
    line = line(Brief.world_brief(w, "dm"), "Aldric")
    tm = Brief.turnmaster_brief(w, nil)

    assert line =~ "[ESTABLE]"
    refute line =~ "[CAÍDO]"
    refute line =~ "[MUERTO]"
    assert tm =~ "[ESTABLE]"
    refute tm =~ "[CAÍDO]"
  end

  test "pending death saves stay downed" do
    w = downed("Aldric", successes: 1, fails: 1) |> world()
    line = line(Brief.world_brief(w, "dm"), "Aldric")

    assert line =~ "[CAÍDO]"
    refute line =~ "[ESTABLE]"
    refute line =~ "[MUERTO]"
    assert Brief.turnmaster_brief(w, nil) =~ "[CAÍDO]"
  end

  test "three failed death saves are dead" do
    w = downed("Aldric", successes: 0, fails: 3) |> world()
    line = line(Brief.world_brief(w, "dm"), "Aldric")

    assert line =~ "[MUERTO]"
    refute line =~ "[CAÍDO]"
    refute line =~ "[ESTABLE]"
    assert World.dead?(w, "Aldric")
  end

  test "a level 1 human fighter and a bare NPC do not crash" do
    fighter =
      hero("Aldric",
        weapons: [
          %Weapon{
            name: "longsword",
            dice: "1d8",
            damage_type: "slashing",
            attack_ability: :str
          }
        ]
      )

    npc = %Character{name: "aldeano", side: "npc"}
    w = World.new(characters: %{"Aldric" => fighter, "aldeano" => npc})
    brief = Brief.world_brief(w, "Aldric")

    assert brief =~ "Aldric (raza human/Humano, clase fighter/Guerrero, nivel 1, pc)"
    assert brief =~ "Armas: longsword"
    refute brief =~ "paladin"
    refute brief =~ "Paladín"
    assert brief =~ "aldeano (raza —, clase —, nivel 1, npc)"
    assert Brief.turnmaster_brief(w, nil) =~ "aldeano"
    assert Brief.turn_prompt(w, "Aldric", "actúa") =~ "fighter/Guerrero"
  end

  defp shield(name, opts \\ []) do
    caster = Character.new(name: "C", class: "cleric", hp: 10, max_hp: 10, ac: 12)
    target = hero(name, opts)
    {:ok, w} = World.shield_of_faith("C", [name]).(world([caster, target]))
    w
  end

  defp hero(name, opts) do
    Character.new(
      Keyword.merge(
        [name: name, race: "human", class: "fighter", level: 1, hp: 20, max_hp: 20, ac: 18],
        opts
      )
    )
  end

  defp downed(name, saves) do
    hero(name, hp: 0, max_hp: 12, death_saves: Map.new(saves))
  end

  defp world(chars) when is_list(chars), do: World.new(characters: Map.new(chars, &{&1.name, &1}))
  defp world(%Character{} = c), do: world([c])

  defp line(brief, name) do
    brief
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "- #{name} "))
  end
end
