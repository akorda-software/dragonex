defmodule Dragonex.InventoryDeclarationTest do
  use ExUnit.Case, async: true

  alias Dragonex.InventoryDeclaration, as: Decl

  describe "castellano" do
    test "recogidas reales de playtests" do
      for text <- [
            "—Ahí está… —Cojo el libro con cuidado, pasando el pulgar por la cubierta gastada—.",
            "Entro en el almacén y recojo la campanilla de cobre de Berta.",
            "Subo al altillo, abro el arcón azul y tomo el libro de cuentas.",
            "Me guardo la llave en el cinturón.",
            "Meto el farol en mi mochila.",
            "Lo cojo y lo examino."
          ] do
        assert Decl.kind(text) == :pickup, text
      end
    end

    test "entregas, también en voz citada" do
      for text <- [
            "Bajo y le entrego el libro a Mira.",
            "Se lo doy a Berta sin decir nada.",
            "Le devuelvo la campanilla.",
            "—Aquí tienes tu dichoso libro. Espero que valga lo que ha costado.",
            "«Toma, es tuyo», le digo a Mira.",
            "Dejo el botón de latón sobre el pretil de piedra junto a mí."
          ] do
        assert Decl.kind(text) == :delivery, text
      end
    end

    test "recoger y entregar en la misma declaración" do
      assert Decl.kind("Cojo el libro, bajo y se lo doy a Mira.") == :both
    end

    test "gestos y armas no cuentan" do
      for text <- [
            "¡Malditas ratas! Avanzo hacia la que queda y le doy un tajo con la espada.",
            "Le doy las gracias a Mira y salgo.",
            "Tomo aire y subo la escalera.",
            "Desenvaino la espada y me coloco en la entrada.",
            "Asiento, guardo la espada y me vuelvo hacia Lyra y Vex.",
            "Levanto la vista hacia el altillo.",
            "Doy un paso atrás y guardo silencio.",
            "Me doy cuenta de que la escalera cruje.",
            "Miro a Mira y le pregunto dónde está el arcón.",
            # Falsos positivos reales de playtests (2026-10-12).
            "Me siento en un saco de harina y le pregunto a Mira qué hará ahora.",
            "—Tranquila —digo, limpiando la hoja en un saco de harina antes de envainarla—.",
            "Subo con cuidado, y si ese peldaño está podrido, le doy un buen pisotón.",
            "Le doy una palmada al hombro bueno y guardo el cuchillo.",
            "Saco el cuchillo de caza con la mano izquierda y ataco a la rata.",
            "Levanto la jarra de estaño en un brindis hacia la tabernera.",
            "Examino los arbustos. Solo observo este tramo: no avanzo ni recojo nada.",
            "Yo me quedo con mi guiso y escucho vuestras ideas.",
            "Dejo que el calor de la taberna me reciba."
          ] do
        assert Decl.kind(text) == nil, text
      end
    end
  end

  describe "inglés" do
    test "recogidas y entregas" do
      assert Decl.kind("I climb up and take the ledger from the chest.", :en) == :pickup
      assert Decl.kind("I pick it up and put it in my pack.", :en) == :pickup
      assert Decl.kind("I hand the ledger to Mira.", :en) == :delivery
      assert Decl.kind("\"Here's your ledger,\" I tell her.", :en) == :delivery
      assert Decl.kind("I grab the bell and give it to Berta.", :en) == :both
    end

    test "gestos y armas no cuentan" do
      for text <- [
            "I take a deep breath and climb the ladder.",
            "I draw my sword and charge the rat.",
            "I give her a nod and leave.",
            "I take cover behind the sacks.",
            "I look around the loft."
          ] do
        assert Decl.kind(text, :en) == nil, text
      end
    end
  end

  test "sin texto no hay intención" do
    assert Decl.kind(nil) == nil
    assert Decl.kind("") == nil
  end

  describe "préstamo temporal con devolución inmediata" do
    test "el caso 19467/63 exige los dos tramos aunque el saldo final sea cero" do
      text =
        "Ada, ¿me prestas el sello un instante para ver mejor la efigie? " <>
          "Cuando ella me lo presta, lo miro y se lo devuelvo inmediatamente a Ada. " <>
          "El encargo sigue terminado."

      assert Decl.kind(text) == :round_trip
      assert Decl.legacy_kind(text) == :delivery
    end

    test "recibir o prestar y devolver de inmediato, en ambos idiomas" do
      for text <- [
            "Tomo prestado el sello y lo devuelvo enseguida.",
            "Cojo el sello un instante y acto seguido se lo devuelvo a Ada.",
            "Le presto mi sello a Ada y ella me lo devuelve inmediatamente.",
            "Me prestas el sello un momento, lo examino y te lo devuelvo.",
            "Te presto mi trofeo un momento y me lo devuelves.",
            "Le pido prestado el sello a Ada, lo examino y se lo devuelvo inmediatamente."
          ] do
        assert Decl.kind(text) == :round_trip, text
      end

      for text <- [
            "Ada, can I borrow the seal for a moment? I examine it and immediately return it to Ada.",
            "I take the seal briefly and hand it back right away.",
            "I lend Ada my seal and get it back immediately.",
            "I borrow the seal for a moment, examine it and give it back.",
            "I lend you my trophy for a moment and you return it."
          ] do
        assert Decl.kind(text, :en) == :round_trip, text
      end
    end

    test "una petición, entrega ordinaria o devolución negada no implica ida y vuelta" do
      for {text, locale} <- [
            {"Ada, ¿me prestas el sello?", :es},
            {"Cojo el libro y se lo doy a Mira.", :es},
            {"Tomo prestado el sello, pero no se lo devuelvo inmediatamente.", :es},
            {"Le presto el sello, pero ella no me lo devuelve inmediatamente.", :es},
            {"Miro el sello sin tocarlo.", :es},
            {"Can I borrow the seal?", :en},
            {"I borrow the seal but do not return it immediately.", :en},
            {"I take the ledger and give it to Mira.", :en},
            {"Me prestas el sello un momento y te lo devuelvo mañana.", :es},
            {"Te presto mi trofeo un momento y me lo devuelves otro día.", :es},
            {"I borrow the seal briefly and return it tomorrow.", :en},
            {"I lend you my trophy for a moment and get it back later.", :en}
          ] do
        refute Decl.kind(text, locale) == :round_trip, text
      end
    end
  end

  test "legacy classification preserves D239 instead of imposing a new contract on a paid beat" do
    assert Decl.legacy_kind("Cojo el libro.") == :pickup
    assert Decl.legacy_kind("Cojo el libro y se lo doy a Mira.") == :both

    assert Decl.legacy_kind("I borrow the seal briefly and return it immediately.", :en) ==
             :delivery

    assert Decl.legacy_kind("Solo miro el sello.") == nil
    assert Decl.legacy_kind(nil) == nil
  end
end
