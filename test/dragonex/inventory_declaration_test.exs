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
end
