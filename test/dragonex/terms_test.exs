defmodule Dragonex.TermsTest do
  use ExUnit.Case, async: true
  alias Dragonex.Terms

  test "weapons and natural attacks read as common nouns in each locale" do
    assert Terms.weapon("shortbow", :es) == "arco corto"
    assert Terms.weapon("longsword", :es) == "espada larga"
    assert Terms.weapon("Scimitar", :es) == "cimitarra"
    assert Terms.weapon("bite", :es) == "mordisco"
    assert Terms.weapon("longsword", :en) == "longsword"
    assert Terms.weapon("bite", :en) == "bite"
    assert Terms.weapon("espada rúnica", :es) == "espada rúnica"
  end

  test "spells keep their proper name, translated when known" do
    assert Terms.spell("firebolt", :es) == "Rayo ígneo"
    assert Terms.spell("fire bolt", :es) == "Rayo ígneo"
    assert Terms.spell("magic missile", :es) == "Proyectil mágico"
    assert Terms.spell("magic missile", :en) == "Magic Missile"
    assert Terms.spell("Conjuro casero", :es) == "Conjuro casero"
    # Spells outside the creator's catalog come from the SRD import.
    assert Terms.spell("poison spray", :es) == "Rociar veneno"
    assert Terms.spell("poison spray", :en) == "Poison Spray"
  end

  test "damage phrases agree in Spanish and read naturally in English" do
    assert Terms.damage("piercing", :es) == "daño perforante"
    assert Terms.damage("radiant", :es) == "daño radiante"
    assert Terms.damage("fire", :es) == "daño de fuego"
    assert Terms.damage("force", :es) == "daño de fuerza"
    assert Terms.damage("lightning", :es) == "daño de relámpago"
    assert Terms.damage(:slashing, :es) == "daño cortante"
    assert Terms.damage("piercing", :en) == "piercing damage"
    assert Terms.damage(nil, :es) == "daño"
    assert Terms.damage_type("fire", :es) == "fuego"
  end

  test "conditions read as states" do
    assert Terms.condition("poisoned", :es) == "envenenado"
    assert Terms.condition("Prone", :es) == "derribado"
    assert Terms.condition("poisoned", :en) == "poisoned"
    assert Terms.condition("maldito", :es) == "maldito"
  end
end
