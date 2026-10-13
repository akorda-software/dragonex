defmodule Dragonex.BestiaryCRTest do
  @moduledoc """
  The bestiary has SRD giant rats and tells the DM each kind's challenge, so
  an unknown creature is replaced by one of similar strength (game 19466:
  two giant rats played as CR 1 giant spiders wiped a level-1 party).
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Monsters, Tools}

  test "giant rat has its SRD numbers" do
    rat = Monsters.get("giant_rat").(name: "rata")
    assert {rat.hp, rat.max_hp, rat.ac, rat.dex} == {7, 7, 12, 15}
    assert [%{dice: "1d4", damage_type: "piercing", attack_ability: :dex}] = rat.weapons
    assert rat.side == "enemy"
  end

  test "every kind has a challenge rating and the list goes weakest first" do
    for key <- Monsters.keys(), do: assert(Monsters.cr(key), "#{key} has no CR")

    listing = Monsters.catalogue_by_cr()
    assert listing =~ "giant_rat (CR 1/8)"
    {rat, _} = :binary.match(listing, "giant_rat")
    {spider, _} = :binary.match(listing, "giant_spider")
    {ogre, _} = :binary.match(listing, "ogre")
    assert rat < spider and spider < ogre
  end

  test "an unknown kind answers with the catalogue by challenge" do
    # An unknown kind is answered before any world change is proposed.
    ctx = %{deps: %{state: %{participant_id: "dm"}}}
    assert {:ok, msg} = Tools.spawn_monster(ctx, "dire_badger", "tejón")
    assert msg =~ "dire_badger"
    assert msg =~ "giant_rat (CR 1/8)"
    assert msg =~ "nunca uno más fuerte"
  end
end
