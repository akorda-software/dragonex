defmodule Dragones.Heroes.CatalogTest do
  @moduledoc """
  La capa de localización y catálogo:

    1. resuelve etiquetas en español por defecto,
    2. cae al otro idioma / a la key cuando falta traducción,
    3. las `key` que usa el motor NO se traducen nunca (contrato estable),
    4. cada listado del creador cubre TODA la base builtin con etiquetas.

  Esto fija el contrato de display y garantiza que añadir SRD/custom más tarde
  no rompe nada: el motor sigue recibiendo keys, la UI sigue recibiendo labels.
  """

  use ExUnit.Case, async: true

  alias Dragones.{Heroes.Catalog, Heroes.Translations, I18n}

  # --------------------------------------------------------- locale default

  test "la locale por defecto es :es y la app es monolingüe por ejecución" do
    assert I18n.locale() == :es
    assert :es in I18n.supported()
  end

  test "with_locale/2 aísla un bloque en otro idioma" do
    assert I18n.with_locale(:en, fn -> Translations.race("elf") end) == "Elf"
    # al salir, la locale global vuelve a :es
    assert I18n.locale() == :es
  end

  # --------------------------------------------------------- resolución

  describe "I18n.label/3 (resolución con fallback)" do
    test "usa la locale primaria" do
      assert I18n.label(%{es: "Elfo", en: "Elf"}, :es) == "Elfo"
      assert I18n.label(%{es: "Elfo", en: "Elf"}, :en) == "Elf"
    end

    test "cae a la otra locale si falta la primaria" do
      assert I18n.label(%{es: nil, en: "Elf"}, :es) == "Elf"
    end

    test "cae al fallback si no hay traducción alguna" do
      assert I18n.label(nil, :es, "elf") == "elf"
      assert I18n.label(%{}, :es, "elf") == "elf"
    end
  end

  # --------------------------------------------------------- contrato keys

  describe "las keys NO se traducen (contrato del motor)" do
    test "race/class/weapon/spell devuelven la key si no hay traducción" do
      assert Translations.race("unknown_race") == "unknown_race"
      assert Translations.class("unknown") == "unknown"
      assert Translations.weapon("katana") == "katana"
      assert Translations.spell("wish") == "wish"
    end

    test "la key 'fire bolt' se traduce a 'Rayo ígneo' pero la key permanece" do
      assert Translations.spell("fire bolt") == "Rayo ígneo"
      # el motor y los tests siguen usando "fire bolt" como clave interna
    end
  end

  # --------------------------------------------------------- razas

  describe "races/1" do
    test "devuelve TODAS las razas builtin con key y label en español" do
      keys = Enum.map(Catalog.races(:es), & &1.key)
      # 9 razas del SRD 5.1
      assert length(keys) == 9

      for k <- ~w(dwarf elf halfling human dragonborn gnome half-elf half-orc tiefling) do
        assert k in keys
      end
    end

    test "cada raza trae sus subrazas localizadas" do
      elf = Enum.find(Catalog.races(:es), &(&1.key == "elf"))
      sub_keys = Enum.map(elf.subraces, & &1.key)
      assert "high elf" in sub_keys
      assert "wood elf" in sub_keys
      high = Enum.find(elf.subraces, &(&1.key == "high elf"))
      assert high.label == "Alto Elfo"
    end

    test "human no tiene subrazas" do
      human = Enum.find(Catalog.races(:es), &(&1.key == "human"))
      assert human.subraces == []
    end

    test "en inglés devuelve las etiquetas inglesas" do
      elf = Enum.find(Catalog.races(:en), &(&1.key == "elf"))
      assert elf.label == "Elf"
    end
  end

  describe "race_label/2 para un Character ya almacenado" do
    test "resuelve la subraza guardada como nombre ('high elf')" do
      assert Catalog.race_label("high elf", :es) == "Alto Elfo"
    end

    test "resuelve la raza guardada como key ('human')" do
      assert Catalog.race_label("human", :es) == "Humano"
    end

    test "unknown capitaliza como cortesía" do
      assert Catalog.race_label("customthing", :es) == "Customthing"
    end
  end

  # --------------------------------------------------------- clases

  describe "classes/1" do
    test "devuelve las 12 clases con metadata (caster, hit_die)" do
      list = Catalog.classes(:es)
      assert length(list) == 12
      wiz = Enum.find(list, &(&1.key == "wizard"))
      assert wiz.label == "Mago"
      assert wiz.caster == true
      assert wiz.hit_die == 6

      ftr = Enum.find(list, &(&1.key == "fighter"))
      assert ftr.label == "Guerrero"
      assert ftr.caster == false
      assert ftr.hit_die == 10
    end
  end

  # --------------------------------------------------------- trasfondos

  test "backgrounds/1 cubre el catálogo builtin en español" do
    list = Catalog.backgrounds(:es)
    sage = Enum.find(list, &(&1.key == "sage"))
    assert sage.label == "Sabio"
  end

  # --------------------------------------------------------- armas / armaduras

  describe "weapons/1 y weapon_label/2" do
    test "todas las armas tienen etiqueta en español" do
      list = Catalog.weapons(:es)
      ls = Enum.find(list, &(&1.key == "longsword"))
      assert ls.label == "Espada larga"
      assert ls.dice == "1d8"
      assert ls.damage_type_label == "cortante"
    end

    test "weapon_label resuelve un mapa de arma almacenado" do
      assert Catalog.weapon_label(%{name: "rapier"}, :es) == "Estoque"
      assert Catalog.weapon_label("dagger", :es) == "Daga"
    end
  end

  test "armors/1 incluye el escudo y las armaduras, localizados" do
    list = Catalog.armors(:es)
    assert Enum.find(list, &(&1.key == "shield")).label == "Escudo"
    assert Enum.find(list, &(&1.key == "chain mail")).label == "Cota de malla"
  end

  # --------------------------------------------------------- hechizos

  describe "spells/2 y spells_for_class/2" do
    test "filtra por nivel (cantrips vs nivel 1)" do
      cans = Catalog.cantrips(:es)
      l1 = Catalog.spells_level1(:es)
      assert Enum.all?(cans, &(&1.level == 0))
      assert Enum.all?(l1, &(&1.level == 1))
      fb = Enum.find(cans, &(&1.key == "fire bolt"))
      assert fb.label == "Rayo ígneo"
      assert fb.kind_label == "ataque"
    end

    test "spells_for_class trae los defaults de wizard separados por nivel" do
      %{cantrips: cans, level1: l1} = Catalog.spells_for_class("wizard", :es)
      assert Enum.any?(cans, &(&1.key == "fire bolt"))
      assert Enum.any?(l1, &(&1.key == "magic missile"))
      # los labels vienen en español
      assert Enum.any?(l1, &(&1.label == "Proyectil mágico"))
    end

    test "una clase no conjuradora devuelve listas vacías" do
      %{cantrips: cans, level1: l1} = Catalog.spells_for_class("fighter", :es)
      assert cans == [] and l1 == []
    end

    test "spell_label resuelve un hechizo almacenado" do
      assert Catalog.spell_label(%{name: "shield"}, :es) == "Escudo"
    end
  end

  # --------------------------------------------------------- skills / abilities / saving throws

  test "abilities y skills se traducen (largo y corto)" do
    assert Translations.ability("str") == "Fuerza"
    assert Translations.ability_short("str") == "FUE"
    assert Translations.skill("arcana") == "Arcano"
  end

  test "saving_throws/2 devuelve un string legible localizado" do
    assert Catalog.saving_throws(["str", "con"], :es) == "Fuerza, Constitución"
    assert Catalog.saving_throws(["wis", "cha"], :es) == "Sabiduría, Carisma"
  end

  # --------------------------------------------------------- tipos de daño / kinds

  test "damage_type y kind se traducen" do
    assert Translations.damage_type("fire") == "fuego"
    assert Translations.damage_type("slashing") == "cortante"
    assert Translations.kind(:save) == "salvación"
    assert Translations.kind(:attack) == "ataque"
    assert Translations.kind(:automatic) == "automático"
  end

  # --------------------------------------------------------- items genéricos

  test "item_label prueba arma, armadura, gear y cae a capitalizar" do
    assert Translations.item("longsword") == "Espada larga"
    assert Translations.item("chain mail") == "Cota de malla"
    assert Translations.item("thieves' tools") == "Herramientas de ladrón"
    assert Translations.item("algo inventado") == "Algo inventado"
  end

  # --------------------------------------------------------- fuente (source)

  test "todas las entradas builtin declaran source: :builtin (prepara custom/srd)" do
    for r <- Catalog.races(:es), do: assert(r.source == :builtin)
    for c <- Catalog.classes(:es), do: assert(c.source == :builtin)
    for w <- Catalog.weapons(:es), do: assert(w.source == :builtin)
    for s <- Catalog.spells(:es), do: assert(s.source == :builtin)
  end
end
