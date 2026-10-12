defmodule Dragonex.NPCStatementEnTest do
  @moduledoc """
  Testimony is stored in the game's language (D236) and both grammars stay
  readable: saved Spanish games keep parsing and deduplicating in any locale.
  """
  use ExUnit.Case, async: true
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{Archetypes, Brief, Codec, I18n, NPCStatement, World}

  defp en(fun), do: I18n.with_locale(:en, fun)
  defp es(fun), do: I18n.with_locale(:es, fun)

  defp world do
    World.new(
      scene: "The tavern bar.",
      characters: %{"Lyra" => Archetypes.wizard(), "Vex" => Archetypes.rogue()}
    )
    |> World.init_spell_slots()
    |> Map.put(:elapsed_seconds, 37_935)
  end

  @en_fact "Maribel states: “She left for the north yesterday.” [Recorded at 37935 s of the world clock.]"
  @es_fact "Maribel afirma: «Ayer salió hacia el norte.» [Registrado a los 37935 s del reloj del mundo.]"

  test "English games store an English attribution with its clock" do
    assert {:ok, saved} =
             en(fn ->
               World.record_npc_statement("Maribel", "She left for the north yesterday.").(
                 world()
               )
             end)

    assert saved.facts == [@en_fact]
    reloaded = saved |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert reloaded.facts == [@en_fact]
  end

  test "Spanish storage is byte-identical" do
    assert {:ok, saved} =
             es(fn ->
               World.record_npc_statement("Maribel", "Ayer salió hacia el norte.").(world())
             end)

    assert saved.facts == [@es_fact]
  end

  test "the parser reads both grammars in any locale" do
    for locale <- [:es, :en] do
      I18n.with_locale(locale, fn ->
        assert NPCStatement.speaker(@en_fact) == "Maribel"
        assert NPCStatement.speaker(@es_fact) == "Maribel"

        assert NPCStatement.speaker("Maribel (the miller) states: “Hi.”") ==
                 "Maribel (the miller)"

        assert NPCStatement.attributed?("Legacy afirma: «Sin reloj.»")
        refute NPCStatement.attributed?("The guild sealed the gate.")
      end)
    end
  end

  test "repeating an English claim later keeps its first clock" do
    saved = %{world() | facts: [@en_fact], elapsed_seconds: 124_335}

    assert {:ok, ^saved} =
             en(fn ->
               World.record_npc_statement(" Maribel ", " She left  for the north yesterday. ").(
                 saved
               )
             end)

    assert {:ok, changed} =
             en(fn -> World.record_npc_statement("Maribel", "Now she is back.").(saved) end)

    assert List.last(changed.facts) ==
             "Maribel states: “Now she is back.” [Recorded at 124335 s of the world clock.]"
  end

  test "a saved Spanish claim dedups in an English game, and vice versa" do
    spanish_saved = %{world() | facts: [@es_fact]}

    assert {:ok, ^spanish_saved} =
             en(fn ->
               World.record_npc_statement("Maribel", "Ayer salió hacia el norte.").(spanish_saved)
             end)

    english_saved = %{world() | facts: [@en_fact]}

    assert {:ok, ^english_saved} =
             es(fn ->
               World.record_npc_statement("Maribel", "She left for the north yesterday.").(
                 english_saved
               )
             end)
  end

  test "inner quotes are canonicalized inside the English envelope" do
    assert {:ok, saved} =
             en(fn ->
               World.record_npc_statement("Maribel", "“He said «run» twice”").(world())
             end)

    assert saved.facts == [
             "Maribel states: “He said 'run' twice” [Recorded at 37935 s of the world clock.]"
           ]
  end

  test "the English brief lists English testimony as attributed, not confirmed" do
    w = %{world() | facts: ["The gate is sealed.", @en_fact]}
    prompt = en(fn -> Brief.world_brief(w, "dm") end)

    testimony_heading =
      en(fn -> dgettext("prompts", "Testimonios atribuidos (contenido sin confirmar):") end)

    [confirmed, testimony] = String.split(prompt, testimony_heading, parts: 2)
    assert confirmed =~ "- The gate is sealed."
    refute confirmed =~ @en_fact
    assert testimony =~ "- " <> @en_fact
  end
end
