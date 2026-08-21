defmodule Dragonex.Heroes.SheetFieldsTest do
  @moduledoc """
  El builder de nivel 1 ahora persiste y deriva habilidades, idiomas y rasgos
  (raciales + de clase + característica de trasfondo), y el codec los hace
  sobrevivir el round-trip a jsonb.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Codec, Heroes}

  defp build(overrides \\ []) do
    base = %{name: "X", race: "human", class: "fighter", background: "soldier"}
    Heroes.build(Map.merge(base, Map.new(overrides)))
  end

  # ----------------------------------------------------- habilidades

  describe "habilidades (skills)" do
    test "sin picks usa los defaults de la clase y suma los del trasfondo" do
      {:ok, c} = build()

      # fighter skill_count 2 (default: acrobatics, animal_handling) + soldier (athletics, intimidation)
      assert c.skill_proficiencies == [
               "acrobatics",
               "animal_handling",
               "athletics",
               "intimidation"
             ]
    end

    test "respeta los picks del jugador (dentro de la lista de la clase)" do
      {:ok, c} = build(class: "fighter", skills: ["perception", "survival"])
      assert c.skill_proficiencies == ["perception", "survival", "athletics", "intimidation"]
    end

    test "rechaza skill fuera de la lista de la clase" do
      assert {:error, _} = build(class: "fighter", skills: ["arcana", "history"])
    end

    test "rechaza nº incorrecto de skills" do
      assert {:error, _} = build(class: "fighter", skills: ["perception"])
    end

    test "clase con skill_list :any acepta cualquier nº correcto" do
      {:ok, c} =
        build(class: "bard", background: "sage", skills: ["stealth", "arcana", "athletics"])

      assert "stealth" in c.skill_proficiencies
      # sage añade arcana + history; arcana ya está → dedup
      assert "arcana" in c.skill_proficiencies
      assert "history" in c.skill_proficiencies
    end

    test "rechaza skills duplicadas en los picks del jugador" do
      assert {:error, _} = build(class: "fighter", skills: ["perception", "perception"])

      assert {:error, _} =
               build(class: "bard", background: "sage", skills: ["arcana", "arcana", "stealth"])
    end

    test "dedup entre skills de clase y de trasfondo" do
      # fighter (athletics en lista) + soldier (athletics, intimidation) → sin duplicados
      {:ok, c} =
        build(class: "fighter", skills: ["athletics", "perception"], background: "soldier")

      assert Enum.uniq(c.skill_proficiencies) == c.skill_proficiencies
      assert "athletics" in c.skill_proficiencies
    end
  end

  # ----------------------------------------------------- idiomas

  describe "idiomas (languages)" do
    test "raza concede sus idiomas fijos" do
      {:ok, c} = build(race: "dwarf", subrace: "mountain")
      assert "common" in c.languages and "dwarvish" in c.languages
    end

    test "humano/acólito/alto elfo tienen slots de idioma extra" do
      assert Heroes.extra_language_slots("human", nil, "soldier") == 1
      assert Heroes.extra_language_slots("elf", "high elf", "sage") == 1
      assert Heroes.extra_language_slots("elf", "high elf", "acolyte") == 3
    end

    test "los idiomas extra elegidos se persisten (únicos)" do
      {:ok, c} =
        build(
          race: "high elf",
          class: "wizard",
          background: "acolyte",
          extra_languages: ["draconic", "sylvan", "infernal"]
        )

      # common + elvish (raza) + 3 elegidos
      assert "common" in c.languages
      assert "elvish" in c.languages
      assert "draconic" in c.languages and "sylvan" in c.languages and "infernal" in c.languages
      assert Enum.uniq(c.languages) == c.languages
    end

    test "si faltan picks, se rellena con defaults (no se queda sin idioma)" do
      {:ok, c} = build(race: "human", class: "wizard", background: "acolyte")
      # humano +1, acólito +2 → 3 extras; sin picks se rellenan
      extras = c.languages -- ["common"]
      assert length(extras) == 3
    end

    test "no pierde slots si el usuario elige idiomas solapados con los raciales o duplicados" do
      # alto elfo acólito: 3 extras; el usuario repite 'elvish' (ya racial) y 'draconic'
      {:ok, c} =
        build(
          race: "high elf",
          class: "wizard",
          background: "acolyte",
          extra_languages: ["elvish", "draconic", "draconic"]
        )

      # common + elvish (racial) + 3 extras reales → 5 idiomas totales
      assert length(c.languages) == 5
      assert Enum.uniq(c.languages) == c.languages
      assert "draconic" in c.languages
    end
  end

  # ----------------------------------------------------- rasgos

  describe "rasgos y características" do
    test "racial_traits vienen de la raza (subraza incluida)" do
      {:ok, c} = build(race: "elf", subrace: "high elf", class: "wizard")
      assert "darkvision" in c.racial_traits
      assert "fey_ancestry" in c.racial_traits
      assert "extra_language" in c.racial_traits
    end

    test "class_features vienen de la clase" do
      {:ok, c} = build(class: "barbarian")
      assert "rage" in c.class_features
      assert "unarmored_defense" in c.class_features
    end

    test "background_feature viene del trasfondo (key estable)" do
      {:ok, c} = build(background: "sage")
      assert c.background_feature == "researcher"
    end
  end

  # ----------------------------------------------------- round-trip

  describe "codec round-trip de los campos nuevos" do
    test "skills/idiomas/rasgos/features sobreviven encode→decode" do
      {:ok, c} =
        build(
          race: "high elf",
          class: "wizard",
          background: "acolyte",
          skills: ["arcana", "investigation"],
          extra_languages: ["draconic", "sylvan", "infernal"]
        )

      encoded = Codec.encode_character(c)
      decoded = Codec.decode_character(encoded)

      assert decoded.skill_proficiencies == c.skill_proficiencies
      assert decoded.languages == c.languages
      assert decoded.racial_traits == c.racial_traits
      assert decoded.class_features == c.class_features
      assert decoded.background_feature == c.background_feature
    end
  end
end
