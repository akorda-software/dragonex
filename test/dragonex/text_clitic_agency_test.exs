defmodule Dragonex.TextCliticAgencyTest do
  use ExUnit.Case, async: true

  alias Dragonex.Text
  alias DragonexWeb.GameLive.Chat

  @pcs ["Iria del Alba", "Lyra", "Mara de la Bruma", "Nera del Camino", "Thane", "Vex"]
  @sample File.read!(Path.expand("../fixtures/narration/dm_iria_clitic_gesture.txt", __DIR__))

  test "the real closing keeps the observations and kitchen without borrowing the human's nod" do
    for actor <- ["dm", "Lyra"] do
      clean = Text.scrub(@sample, actor, pc_names: @pcs)
      assert clean =~ "Las tres respuestas se posan sobre la mesa"
      assert clean =~ "la luz como mapa, el bosque como memoria, la jarra como medida."
      assert clean =~ "El calor de la cocina sigue llegando por la puerta entreabierta"
      assert clean =~ "la tarde se alarga sobre el roble."
      refute clean =~ "Iria las recoge"
      refute clean =~ "asintiendo"
      assert Text.scrub(clean, actor, pc_names: @pcs) == clean
      assert Text.puppets_pc?(@sample, actor, @pcs)
    end

    assert Text.dm_puppets_pc?(@sample, @pcs)
  end

  test "object and indirect pronouns cannot hide an immediate foreign-PC action" do
    for action <- [
          "las recoge en silencio",
          "la coge con cuidado",
          "lo toma de la mesa",
          "le responde con una sonrisa",
          "les pregunta por el camino",
          "me dice que acepta",
          "nos responde que acepta",
          "se la deja a Sena"
        ],
        actor <- ["dm", "Lyra"] do
      raw = "Iria #{action}. La puerta sigue cerrada."
      assert Text.scrub(raw, actor, pc_names: @pcs) == "La puerta sigue cerrada."
      assert Text.puppets_pc?(raw, actor, @pcs)
      assert Text.dm_puppets_pc?(raw, @pcs)
    end
  end

  test "the active PC retains its own actions while passive states and NPC predicates remain" do
    own = "La sala está en calma. Iria las recoge en silencio, asintiendo apenas."
    assert Text.scrub(own, "Iria del Alba", pc_names: @pcs) == own
    refute Text.puppets_pc?(own, "Iria del Alba", @pcs)

    for raw <- [
          "Iria está herida mientras Sena las recoge.",
          "Iria la joven permanece sentada mientras Sena le responde.",
          "La jarra recoge la luz junto a Iria.",
          "Sena las recoge en silencio, y el calor llega de la cocina.",
          "Sena pregunta: «¿Iria las recoge o prefiere esperar?»",
          "Sena dice: «Iria las recoge, y el calor llega de la cocina»."
        ] do
      assert Text.scrub(raw, "dm", pc_names: @pcs, character_names: @pcs ++ ["Sena"]) == raw
      refute Text.puppets_pc?(raw, "dm", @pcs, @pcs ++ ["Sena"])
    end
  end

  test "longer registered names and ambiguous short forms retain their own identity" do
    names = @pcs ++ ["Iria del Muelle"]

    for raw <- [
          "Iria del Muelle las recoge en silencio.",
          "Iria las recoge en silencio."
        ] do
      assert Text.scrub(raw, "dm", pc_names: @pcs, character_names: names) == raw
      refute Text.puppets_pc?(raw, "dm", @pcs, names)
      refute Text.dm_puppets_pc?(raw, @pcs, names)
    end

    assert Text.scrub("Iria del Alba las recoge. La sala está en calma.", "dm",
             pc_names: @pcs,
             character_names: names
           ) == "La sala está en calma."
  end

  test "relative and temporal foreign predicates share the same pronoun boundary" do
    for actor <- ["dm", "Lyra"] do
      relative = "Miro hacia Iria, que las recoge en silencio, y pregunto por el roble."

      assert Text.scrub(relative, actor, pc_names: @pcs) ==
               "Miro hacia Iria y pregunto por el roble."

      temporal = "El fuego crepita mientras Iria le responde a Sena, y la puerta sigue cerrada."
      clean = Text.scrub(temporal, actor, pc_names: @pcs, character_names: @pcs ++ ["Sena"])
      assert clean =~ "El fuego crepita"
      assert clean =~ "la puerta sigue cerrada"
      refute clean =~ "le responde"
      assert Text.puppets_pc?(relative, actor, @pcs)
      assert Text.dm_puppets_pc?(relative, @pcs)
    end
  end

  test "a coordinated object or quoted kitchen remains part of the removed PC action" do
    for raw <- [
          "Iria las recoge, y las guarda con cuidado. La puerta cruje.",
          "Iria las recoge y dice: «Acepto, y el calor de la cocina me acompaña». La puerta cruje.",
          "Iria las recoge. «Acepto, y el calor de la cocina me acompaña», comenta. La puerta cruje."
        ] do
      assert Text.scrub(raw, "dm", pc_names: @pcs) == "La puerta cruje."
    end
  end

  test "partial streaming hides the pronoun action and preserves the following environment" do
    for tail <- ["recoge", "recoge en silencio", "recoge en silencio, asintiendo apenas"] do
      raw = "Las voces reposan sobre la mesa. Iria las #{tail}"
      assert Chat.live_shown(raw, "dm", @pcs) == "Las voces reposan sobre la mesa."
    end

    assert Chat.live_shown(@sample, "dm", @pcs) ==
             Text.scrub(@sample, "dm", pc_names: @pcs)

    assert Chat.live_shown(@sample, "dm", @pcs) =~ "El calor de la cocina"
  end
end
