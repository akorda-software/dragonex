defmodule Dragonex.TestimonyBriefTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Brief, Codec, NPCStatement, World}
  alias Dragonex.Game.Instructions

  @clue "Un hilo de lana oscura apareció donde se pierden las huellas."
  @claim "El zagal de las cabras afirma: «''Ese hilo es del mismo gris apagado del abrigo del forastero, pero lo vi de lejos y no puedo jurar que sea la misma lana; eso sigue siendo una suposición.''» [Registrado a los 41535 s del reloj del mundo.]"
  @legacy "Maribel afirma: «El herrero dice que partió ayer; yo no lo vi.»"
  @latest "el zagal de las cabras afirma: «Vi al forastero de lejos, pero no su tela de cerca. Lo del hilo lo sé por lo que me contasteis; no puedo confirmarlo.» [Registrado a los 41535 s del reloj del mundo.]"
  @last_marker "Última entrada conservada de esta fuente (no confirma su contenido):"

  test "attribution recognizes the stored envelope independently of an optional clock" do
    for fact <- [@claim, @legacy, @legacy <> " [Registrado a los ?]"] do
      assert apply(NPCStatement, :attributed?, [fact])
    end

    for fact <- [
          nil,
          42,
          @clue,
          "La puerta afirma su posición en el marco.",
          "¿Quién? afirma: «Sí.»"
        ] do
      refute apply(NPCStatement, :attributed?, [fact])
    end
  end

  test "DM, PC and TurnMaster see the witness claim outside confirmed facts without changing storage" do
    world = %{World.new() | facts: [@clue, @claim, @legacy], elapsed_seconds: 50_000}
    encoded = Codec.encode(world)

    for brief <- [
          Brief.world_brief(world, "dm"),
          Brief.world_brief(world, "Lyra"),
          Brief.turnmaster_brief(world, "Lyra")
        ] do
      [confirmed, testimony] =
        String.split(brief, "Testimonios atribuidos (contenido sin confirmar):", parts: 2)

      assert confirmed =~ "Hechos establecidos"
      assert confirmed =~ @clue
      refute confirmed =~ @claim
      refute confirmed =~ @legacy
      assert testimony =~ @claim
      assert testimony =~ @legacy
      assert testimony =~ "no al reloj actual"
      assert testimony =~ "no infieras cuándo se recogieron"
    end

    assert world.facts == [@clue, @claim, @legacy]
    assert Codec.encode(world) == encoded
    assert Codec.decode(encoded) == world
  end

  test "a testimony-only brief never labels its contents as confirmed facts" do
    world = %{World.new() | facts: [@claim]}

    for brief <- [Brief.world_brief(world, "Vex"), Brief.turnmaster_brief(world, "dm")] do
      assert brief =~ "Testimonios atribuidos"
      refute brief =~ "Hechos establecidos"
      refute brief =~ "verdad canónica"
      assert brief =~ @claim
    end

    refute Brief.world_brief(World.new(), "dm") =~ "Testimonios atribuidos"
  end

  test "projection preserves each source verbatim and its order within its section" do
    other = "El molino tiene una compuerta rota."
    world = %{World.new() | facts: [@legacy, @clue, @claim, other]}
    brief = Brief.world_brief(world, "dm")

    [confirmed, testimony] =
      String.split(brief, "Testimonios atribuidos (contenido sin confirmar):", parts: 2)

    assert confirmed =~ "- #{@clue}\n- #{other}"
    assert testimony =~ "- #{@legacy}\n- #{@claim}"
    for fact <- world.facts, do: assert(length(:binary.matches(brief, fact)) == 1)
  end

  test "source guidance is conditional, actor-specific and also available in combat" do
    world = %{World.new() | facts: [@claim], phase: :combat}
    pc = apply(Instructions, :testimony_instruction, [world, "Lyra"])
    dm = apply(Instructions, :testimony_instruction, [world, "dm"])
    assert pc =~ "FUENTES Y CERTEZA"
    assert pc =~ "Lyra"
    assert pc =~ "lo vimos"
    assert pc =~ "prosa anterior"
    assert pc =~ "según"
    assert dm =~ "voz del PNJ"
    assert dm =~ "observación de los PCs"
    assert apply(Instructions, :testimony_instruction, [%{world | facts: [@clue]}, "Lyra"]) == ""
  end

  test "same-clock later testimony is identified by retained order without changing either version" do
    world = %{World.new() | facts: [@claim, @clue, @legacy, @latest], elapsed_seconds: 50_000}
    encoded = Codec.encode(world)

    for brief <- [
          Brief.world_brief(world, "dm"),
          Brief.world_brief(world, "Lyra"),
          Brief.turnmaster_brief(world, "Lyra")
        ] do
      assert brief =~ "#{@last_marker}\n- #{@latest}"
      refute brief =~ "#{@last_marker}\n- #{@claim}"
      refute brief =~ "#{@last_marker}\n- #{@legacy}"
      assert length(:binary.matches(brief, @last_marker)) == 1
      for fact <- world.facts, do: assert(length(:binary.matches(brief, fact)) == 1)
      assert {older, _} = :binary.match(brief, @claim)
      assert {later, _} = :binary.match(brief, @latest)
      assert older < later
      assert brief =~ "orden conservado"
      assert brief =~ "no determina cuándo ocurrió"
    end

    assert Codec.encode(world) == encoded
    assert Codec.decode(encoded) == world
  end

  test "source identity preserves the full name and only folds case, NFC and spacing" do
    old = "José (molinero) afirma: «La compuerta estaba abierta.»"
    later = "JOSÉ  (molinero) afirma: «Ahora está cerrada.»"
    alias_source = "José afirma: «No recuerdo la compuerta.»"
    distinct = "Jose (molinero) afirma: «Yo no estuve allí.»"
    role = "José (guardia) afirma: «No conozco el molino.»"
    world = %{World.new() | facts: [old, alias_source, distinct, role, later]}
    brief = Brief.world_brief(world, "dm")
    assert brief =~ "#{@last_marker}\n- #{later}"
    assert length(:binary.matches(brief, @last_marker)) == 1
    for fact <- world.facts, do: assert(length(:binary.matches(brief, fact)) == 1)
  end

  test "each source keeps its own last position independently of clock values and legacy collection dates" do
    first = "Maribel afirma: «Lo oí ayer.» [Registrado a los 50000 s del reloj del mundo.]"

    second =
      "El herrero afirma: «No estuve allí.» [Registrado a los 80000 s del reloj del mundo.]"

    last_maribel = "Maribel afirma: «Me lo contó el guardia; yo no lo vi.»"

    last_smith =
      "El herrero afirma: «Vi una capa, no su rostro.» [Registrado a los 10 s del reloj del mundo.]"

    world = %{World.new() | facts: [first, second, last_maribel, last_smith]}
    brief = Brief.world_brief(world, "dm")
    assert brief =~ "#{@last_marker}\n- #{last_maribel}"
    assert brief =~ "#{@last_marker}\n- #{last_smith}"
    assert length(:binary.matches(brief, @last_marker)) == 2
    assert world.facts == [first, second, last_maribel, last_smith]
    refute brief =~ last_maribel <> " [Registrado"
    assert brief =~ "no infieras cuándo se recogieron"
  end

  test "repeating retained legacy testimony does not promote its position or manufacture a clock" do
    clarification = "Maribel afirma: «El herrero no me indicó qué camino tomó.»"
    world = %{World.new() | facts: [@legacy, clarification], elapsed_seconds: 50_000}
    encoded = Codec.encode(world)
    before = Brief.world_brief(world, "dm")

    assert {:ok, repeated} =
             World.record_npc_statement(
               "Maribel",
               "El herrero dice que partió ayer; yo no lo vi."
             ).(world)

    assert repeated == world
    assert Brief.world_brief(repeated, "dm") == before
    assert before =~ "#{@last_marker}\n- #{clarification}"
    refute before =~ "#{@last_marker}\n- #{@legacy}"
    assert Codec.encode(repeated) == encoded
  end
end
