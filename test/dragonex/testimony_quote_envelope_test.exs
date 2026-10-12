defmodule Dragonex.TestimonyQuoteEnvelopeTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Codec, World}

  @speaker "El zagal de las cabras"
  @claim "Ese hilo es del mismo gris apagado del abrigo del forastero, pero lo vi de lejos y no puedo jurar que sea la misma lana; eso sigue siendo una suposición."
  @stored "#{@speaker} afirma: «''#{@claim}''» [Registrado a los 41535 s del reloj del mundo.]"

  test "the retained real double-quoted claim keeps its first clock and position at the fact cap" do
    before = %{
      World.new()
      | facts: [@stored | Enum.map(1..29, &"Hecho #{&1}.")],
        elapsed_seconds: 50_000
    }

    for text <- [
          @claim,
          "«#{@claim}»",
          "“#{@claim}”",
          "\"#{@claim}\"",
          "'#{@claim}'",
          "«“#{@claim}”»"
        ] do
      assert {:ok, ^before} = World.record_npc_statement(@speaker, text).(before)
    end

    assert Codec.decode(Codec.encode(before)) == before
    assert hd(before.facts) == @stored
  end

  test "new complete quote envelopes produce one canonical claim including nested wrappers" do
    before = %{World.new() | elapsed_seconds: 60}

    expected =
      "Maribel afirma: «Quizá vuelva mañana.» [Registrado a los 60 s del reloj del mundo.]"

    for text <- [
          "Quizá vuelva mañana.",
          "«Quizá vuelva mañana.»",
          "“Quizá vuelva mañana.”",
          "\"Quizá vuelva mañana.\"",
          "'Quizá vuelva mañana.'",
          "''Quizá vuelva mañana.''",
          "«“\"Quizá vuelva mañana.\"”»",
          "  «  Quizá  vuelva mañana.  »  "
        ] do
      assert {:ok, saved} = World.record_npc_statement("Maribel", text).(before)
      assert saved.facts == [expected]
      later = %{saved | elapsed_seconds: 86_460}
      assert {:ok, ^later} = World.record_npc_statement("Maribel", "Quizá vuelva mañana.").(later)
    end
  end

  test "inner quotations and apostrophes remain part of the claim rather than disappearing" do
    before = World.new()
    claim = "D'Artagnan dijo: «quizá vuelva»; yo no lo vi."

    expected =
      "Maribel afirma: «D'Artagnan dijo: 'quizá vuelva'; yo no lo vi.» [Registrado a los 0 s del reloj del mundo.]"

    for text <- [
          claim,
          "«#{claim}»",
          "“#{claim}”",
          "'#{claim}'",
          "''D'Artagnan dijo: 'quizá vuelva'; yo no lo vi.''"
        ] do
      assert {:ok, saved} = World.record_npc_statement("Maribel", text).(before)
      assert saved.facts == [expected]
    end

    assert {:ok, saved} = World.record_npc_statement("Maribel", claim).(before)

    assert {:ok, changed} =
             World.record_npc_statement("Maribel", "D'Artagnan dijo: quizá vuelva; yo no lo vi.").(
               saved
             )

    assert length(changed.facts) == 2
  end

  test "quoted legacy without a known clock is returned verbatim and never dated by a repeat" do
    legacy = "Maribel afirma: «''Ayer lo vi; no sé si sigue allí.''»"

    before = %{
      World.new()
      | facts: ["El molino está cerrado.", legacy],
        elapsed_seconds: 100_000,
        scene_refresh_pending: true
    }

    assert {:ok, ^before} =
             World.record_npc_statement("Maribel", "«Ayer lo vi; no sé si sigue allí.»").(before)

    assert {:ok, ^before} =
             World.record_npc_statement("Maribel", "Ayer lo vi; no sé si sigue allí.").(before)

    assert Codec.decode(Codec.encode(before)) == before
  end

  test "partial or mismatched quotes are not mistaken for an envelope around the whole statement" do
    for {text, body} <- [
          {"«No lo vi» y «quizá volvió»", "'No lo vi' y 'quizá volvió'"},
          {"\"No lo vi\" y \"quizá volvió\"", "'No lo vi' y 'quizá volvió'"},
          {"'No lo vi' y 'quizá volvió'", "'No lo vi' y 'quizá volvió'"},
          {"«No lo vi\"", "'No lo vi'"},
          {"«No lo vi", "'No lo vi"}
        ] do
      assert {:ok, saved} = World.record_npc_statement("Maribel", text).(World.new())

      assert saved.facts == [
               "Maribel afirma: «#{body}» [Registrado a los 0 s del reloj del mundo.]"
             ]

      assert {:ok, ^saved} = World.record_npc_statement("Maribel", text).(saved)
    end
  end

  test "empty quoted contents and oversized raw claims stay invalid" do
    before = World.new()

    for text <- ["«»", "“ ”", "\"\"", "''", "«“ ”»", "\"#{String.duplicate("x", 799)}\""] do
      assert {:error, _} = World.record_npc_statement("Maribel", text).(before)
    end

    assert before.facts == []

    assert {:ok, boundary} =
             World.record_npc_statement("Maribel", String.duplicate("x", 800)).(before)

    assert length(boundary.facts) == 1
  end

  test "source, uncertainty and literal embedded clock labels distinguish genuinely different claims" do
    claim = "No sé si volvió. [Registrado a los 999999 s del reloj del mundo.]"
    speaker = "El zagal (I)."
    first = "#{speaker} afirma: «''#{claim}''» [Registrado a los 60 s del reloj del mundo.]"
    malformed = "#{speaker} afirma: «''Otra cosa.''» [Registrado a los ? s del reloj del mundo.]"
    before = %{World.new() | facts: [first, malformed], elapsed_seconds: 120}
    assert {:ok, ^before} = World.record_npc_statement(speaker, "«#{claim}»").(before)
    assert {:ok, other_source} = World.record_npc_statement("El zagal XIa", claim).(before)
    assert length(other_source.facts) == 3
    assert {:ok, changed} = World.record_npc_statement(speaker, "Sé que volvió.").(before)
    assert length(changed.facts) == 3
    assert hd(changed.facts) == first
    assert List.last(changed.facts) =~ "Registrado a los 120 s"
    assert {:ok, unknown_clock} = World.record_npc_statement(speaker, "Otra cosa.").(before)
    assert length(unknown_clock.facts) == 3
    assert Enum.take(unknown_clock.facts, 2) == before.facts
  end
end
