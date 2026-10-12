defmodule Dragonex.GuardrailsEnTest do
  @moduledoc """
  Guardrail detection follows the game's language (D236): English games detect
  English hostile appearances, English system notes and drift into Spanish;
  Spanish games keep their original heuristics.
  """
  use ExUnit.Case, async: true
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{Archetypes, I18n, World}
  alias Dragonex.Game.Guardrails

  @base "BASE INSTRUCTION"

  defp en(fun), do: I18n.with_locale(:en, fun)
  defp es(fun), do: I18n.with_locale(:es, fun)

  defp dm(text, seq), do: %{type: :narration, actor: "dm", seq: seq, payload: %{"text" => text}}

  defp note(text, seq),
    do: %{type: :system, actor: "system", seq: seq, payload: %{"note" => text}}

  defp world, do: World.new(characters: %{"Lyra" => Archetypes.wizard()})

  describe "unspawned hostile" do
    test "English creature-first and verb-first appearances nudge in :en" do
      for text <- [
            "A skeleton bursts in through the broken door.",
            "Three goblins emerge from the bushes, blades drawn.",
            "Out of the mist appear two wolves."
          ] do
        out =
          en(fn -> Guardrails.with_dm_unspawned_hostile_nudge([dm(text, 1)], world(), @base) end)

        assert out != @base, text
        assert String.ends_with?(out, @base)
      end
    end

    test "English scenery without a hostile appearing is not a hit" do
      text = "The innkeeper appears behind the bar, wiping a mug."

      assert en(fn ->
               Guardrails.with_dm_unspawned_hostile_nudge([dm(text, 1)], world(), @base)
             end) == @base
    end

    test "Spanish detection is unchanged" do
      hit = [dm("De entre las sombras aparece un esqueleto.", 1)]
      miss = [dm("A skeleton bursts in through the broken door.", 1)]

      assert es(fn -> Guardrails.with_dm_unspawned_hostile_nudge(hit, world(), @base) end) !=
               @base

      assert es(fn -> Guardrails.with_dm_unspawned_hostile_nudge(miss, world(), @base) end) ==
               @base
    end
  end

  describe "post-combat limbo" do
    test "the combat-end note is recognized through the engine msgid in :en" do
      events =
        en(fn -> [note(dgettext("engine", "⚔ El combate termina."), 1), dm("Silence.", 2)] end)

      assert en(fn -> Guardrails.post_combat_limbo?(events) end)
    end

    test "an English combat-end note counts in :en; a scene change ends the limbo" do
      assert en(fn -> Guardrails.post_combat_limbo?([note("⚔ Combat ends.", 1)]) end)

      refute en(fn ->
               Guardrails.post_combat_limbo?([
                 note("⚔ Combat ends.", 1),
                 note("Scene changed: the road north.", 2)
               ])
             end)
    end

    test "Spanish keeps matching its literal note" do
      assert es(fn -> Guardrails.post_combat_limbo?([note("⚔ El combate termina.", 1)]) end)
      refute es(fn -> Guardrails.post_combat_limbo?([note("⚔ Combat ends.", 1)]) end)
    end
  end

  describe "exploration limbo" do
    test "English progress notes break the stall in :en" do
      stalled = for i <- 1..7, do: dm("We keep talking about the circle.", i)
      assert en(fn -> Guardrails.exploration_limbo?(stalled, world()) end)

      moved = stalled ++ [note("⚔ Hostiles appear — the engine rolls initiative.", 8)]
      refute en(fn -> Guardrails.exploration_limbo?(moved, world()) end)
    end
  end

  describe "language drift" do
    @english "The goblin was standing there with their spear, and they would not move from the door."
    @spanish "El goblin está junto a la puerta con una lanza, y los aldeanos dicen que para entrar hay que pagar."

    test ":es flags English prose; :en flags Spanish prose" do
      assert es(fn -> Guardrails.with_dm_spanish_nudge([dm(@english, 1)], @base) end) != @base
      assert es(fn -> Guardrails.with_dm_spanish_nudge([dm(@spanish, 1)], @base) end) == @base

      assert en(fn -> Guardrails.with_dm_language_nudge([dm(@english, 1)], @base) end) == @base
      en_nudge = en(fn -> Guardrails.with_dm_language_nudge([dm(@spanish, 1)], @base) end)
      assert en_nudge != @base
      assert String.ends_with?(en_nudge, @base)
    end

    test "the English nudge is its own prompt, not the Spanish-game one" do
      es_nudge = es(fn -> Guardrails.with_dm_language_nudge([dm(@english, 1)], @base) end)
      en_nudge = en(fn -> Guardrails.with_dm_language_nudge([dm(@spanish, 1)], @base) end)
      assert es_nudge != en_nudge
    end
  end

  describe "anti-repeat stopwords" do
    test "English function words do not inflate similarity in :en" do
      # Same function words, different content: a repeat only by stopwords.
      a = "It was there, and they were with them at the door of the old dragon."
      b = "It was there, and they were with them at the door of the old tower."
      events = [dm(a, 1), dm(b, 2)]
      assert en(fn -> Guardrails.with_dm_anti_repeat(events, @base) end) == @base
      assert es(fn -> Guardrails.with_dm_anti_repeat(events, @base) end) != @base

      repeat = [
        dm("The fog rolls over the silent graves.", 1),
        dm("The fog rolls over the silent graves!", 2)
      ]

      assert en(fn -> Guardrails.with_dm_anti_repeat(repeat, @base) end) != @base
    end
  end
end
