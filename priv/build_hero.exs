#!/usr/bin/env elixir
#
# priv/build_hero.exs — demo the character creator.
#
# Builds two canonical level-1 heroes and prints their full sheets:
#
#   1. Lyra — High Elf Wizard (Sage):  standard array, INT caster, 3 cantrips + 6 spells
#   2. Thane — Mountain Dwarf Fighter (Soldier):  standard array, chain mail + shield, AC 18
#
# Run:  mix run priv/build_hero.exs
#
# This is a smoke test for the builder: every field is derived from 5e rules.

defmodule Dragonex.BuildHeroDemo do
  @moduledoc false
  alias Dragonex.{Character, Heroes}

  def run do
    IO.puts("\n╔══════════════════════════════════════════════════════════╗")
    IO.puts("║         Dragonex Character Creator — Demo Output        ║")
    IO.puts("╚══════════════════════════════════════════════════════════╝")

    {:ok, lyra} = Heroes.build(%{
      name: "Lyra",
      race: "elf",
      subrace: "high elf",
      class: "wizard",
      background: "sage"
    })

    print_sheet(lyra)

    {:ok, thane} = Heroes.build(%{
      name: "Thane",
      race: "dwarf",
      subrace: "mountain",
      class: "fighter",
      background: "soldier"
    })

    print_sheet(thane)

    IO.puts("\n┌──────────────────────────────────────────────────────────┐")
    IO.puts("│  Catalogue summary                                       │")
    IO.puts("├──────────────────────────────────────────────────────────┤")
    IO.puts("│  Races:       #{pad(Heroes.list_races())}│")
    IO.puts("│  Classes:     #{pad(Heroes.list_classes())}│")
    IO.puts("│  Backgrounds: #{pad(Heroes.list_backgrounds())}│")
    IO.puts("└──────────────────────────────────────────────────────────┘")

    IO.puts("\nChangeset validation:")

    for c <- [lyra, thane] do
      attrs = c |> Map.from_struct() |> Map.delete(:__meta__)
      valid = Character.changeset(%Character{}, attrs).valid?
      IO.puts("  #{c.name}: #{if valid, do: "PASS", else: "FAIL"}")
    end

    IO.puts("")
  end

  defp print_sheet(c) do
    bar = String.duplicate("─", 58)
    title = "#{c.name} — #{String.capitalize(c.race)} #{String.capitalize(c.class)} (Lvl #{c.level})"

    IO.puts("\n┌#{bar}┐")
    IO.puts("│  #{String.pad_trailing(title, 56)}│")
    IO.puts("├#{bar}┤")

    mods =
      [:str, :dex, :con, :int, :wis, :cha]
      |> Enum.map(fn ab ->
        score = Map.get(c, ab)
        mod = Character.modifier(c, ab)
        sign = if mod >= 0, do: "+", else: ""
        "#{String.upcase(to_string(ab))} #{score}(#{sign}#{mod})"
      end)

    line("Abilities:  #{Enum.join(mods, "  ")}")
    line("HP: #{c.hp}/#{c.max_hp}   AC: #{c.ac}   Speed: #{c.speed} ft   Side: #{c.side}")
    line("Save proficiencies: #{Enum.join(c.saving_proficiencies, ", ")}")

    IO.puts("│#{bar}│")
    IO.puts("│  Weapons:                                                │")

    for w <- c.weapons do
      props = []
      props = if w.finesse, do: props ++ ["finesse"], else: props
      props = if w.ranged, do: props ++ ["ranged"], else: props
      prop_str = if props != [], do: " (#{Enum.join(props, ", ")})", else: ""
      line("  #{w.name}  #{w.dice} #{w.damage_type} [#{w.attack_ability}]#{prop_str}")
    end

    if c.spells != [] do
      IO.puts("│#{bar}│")
      IO.puts("│  Spells:                                                 │")

      for s <- c.spells do
        level_label = if s.level == 0, do: "cantrip", else: "L#{s.level}"
        dice_str = if s.dice, do: " #{s.dice}", else: ""
        dmg_str = if s.damage_type, do: " #{s.damage_type}", else: ""
        line("  #{s.name} (#{level_label}, #{s.kind}, #{s.casting_ability})#{dice_str}#{dmg_str}")
      end
    end

    IO.puts("│#{bar}│")
    IO.puts("│  Inventory:                                              │")

    for item <- c.inventory do
      qty_str = if item.qty > 1, do: " x#{item.qty}", else: ""
      line("  #{item.name}#{qty_str} [#{item.kind}]")
    end

    IO.puts("│#{bar}│")
    line("Backstory: #{c.backstory}")
    IO.puts("└#{bar}┘")
  end

  defp line(text), do: IO.puts("│  #{String.pad_trailing(text, 56)}│")

  defp pad(list) do
    text = Enum.join(list, ", ")
    String.pad_trailing(text, 53)
  end
end

Dragonex.BuildHeroDemo.run()
