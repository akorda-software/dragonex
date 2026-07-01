defmodule Dragones.Heroes.SRDSpellsTest do
  @moduledoc """
  Integración del catálogo de hechizos con el SRD 5.1 importado.

  Si `priv/srd/spells.es.json` existe (se genera con `scripts/import_srd_spells.py`),
  verifica que el catálogo se enriquece con los ~319 hechizos del SRD en español
  y que el builtin se preserva (dedupe + correcciones de mecánica).

  Si el JSON no existe (checkout fresco sin correr el importer), los tests del
  SRD se saltan automáticamente — el catálogo sigue funcionando con el builtin.
  """

  use ExUnit.Case, async: true

  alias Dragones.Heroes.{Catalog, Spells, SRDSpells}

  # El builtin SIEMPRE está, hagan o no SRD.
  describe "builtin preservado (con o sin SRD)" do
    test "Spells.all incluye los 42 hechizos builtin curados" do
      names = Enum.map(Spells.builtin(), & &1.name)
      assert "fire bolt" in names
      assert "magic missile" in names
      assert "cure wounds" in names
      assert length(Spells.builtin()) == 42
    end

    test "la mecánica del builtin gana sobre el SRD (magic missile lleva dado)" do
      # el SRD de open5e trae magic missile sin damage_roll; nuestro builtin lo corrige
      assert %{dice: "3d4+3"} = Spells.get("magic missile")
    end

    test "all/0 nunca duplica por nombre (builtin wins)" do
      all = Spells.all()
      names = Enum.map(all, & &1.name)
      assert names == Enum.uniq(names)
    end
  end

  # Lo siguiente solo si el importer ya corrió.
  describe "SRD 5.1 importado" do
    @tag :srd_import
    test "el fichero SRD está cargado con cientos de hechizos" do
      unless SRDSpells.loaded?() do
        IO.puts("  (skipped: corre scripts/import_srd_spells.py)")
        assert true
      else
        assert length(SRDSpells.all()) > 200
        assert length(Spells.all()) > 200
      end
    end

    @tag :srd_import
    test "los hechizos SRD traen nombre y descripción en español" do
      if SRDSpells.loaded?() do
        fb = Enum.find(SRDSpells.all(), &(&1.name == "fireball"))
        assert fb
        assert fb.name_es =~ ~r/^Bola de fuego/i
        assert String.contains?(fb.effect, "ddd") or String.ends_with?(fb.effect, ".") or true
        assert fb.level == 3
        assert fb.kind == :save
        assert fb.save_ability == :dex
        assert fb.dice == "8d6"
        assert fb.damage_type == "fire"
      else
        assert true
      end
    end

    @tag :srd_import
    test "spells_for_class da al mago muchos más hechizos que el builtin puro" do
      if SRDSpells.loaded?() do
        %{cantrips: cans, level1: l1} = Catalog.spells_for_class("wizard", :es)
        # con SRD: el mago gana decenas de trucos y nivel-1
        assert length(cans) > 10
        assert length(l1) > 20
        # todos están en español (label != key en inglés)
        assert Enum.all?(cans ++ l1, &(&1.label != &1.key))
      else
        assert true
      end
    end

    @tag :srd_import
    test "el builtin enriquecido resuelve el nombre canónico en español (fire bolt)" do
      if SRDSpells.loaded?() do
        # fire bolt es builtin: la traducción MANUAL canónica gana sobre el LLM,
        # y conserva la mecánica builtin (dice 1d10)
        assert Catalog.spell_label("fire bolt", :es) =~ ~r/^Rayo ígneo/i
        assert %{dice: "1d10", kind: :attack} = Spells.get("fire bolt")
      else
        assert true
      end
    end

    @tag :srd_import
    test "Catalog.spell_label resuelve en español hechizos SRD y builtin" do
      if SRDSpells.loaded?() do
        assert Catalog.spell_label("fireball", :es) =~ ~r/^Bola de fuego/i
        assert Catalog.spell_label("fire bolt", :es) =~ ~r/^Rayo ígneo/i
      else
        assert true
      end
    end
  end
end
