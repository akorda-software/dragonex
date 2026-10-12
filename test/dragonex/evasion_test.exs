defmodule Dragonex.EvasionTest do
  @moduledoc """
  D59 Evasión: rogue L7+ takes no damage on a successful DEX save against a
  spell and half (floored) on a failed one. L6 and non-rogues keep the
  normal mitigation; non-DEX saves ignore Evasión.
  """
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Spell, World}

  defp fixed(value), do: Dragonex.Dice.always(value)

  # A roller that pops values from a queue, so the d20, the bardic d6 and
  # the damage die are distinct and countable.
  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp add(world, change) do
    {:ok, w} = change.(world)
    w
  end

  # Wizard L1: int 16 → save CD 13 (8 + prof 2 + mod 3).
  defp mage do
    Character.new(
      name: "mage",
      class: "wizard",
      hp: 7,
      max_hp: 7,
      ac: 12,
      str: 8,
      dex: 14,
      con: 13,
      int: 16,
      wis: 12,
      cha: 10,
      side: "pc",
      spells: [
        %Spell{
          name: "acid splash",
          level: 0,
          kind: :save,
          casting_ability: :int,
          save_ability: :dex,
          dice: "1d6",
          damage_type: "acid"
        },
        %Spell{
          name: "vicious mockery",
          level: 0,
          kind: :save,
          casting_ability: :int,
          save_ability: :wis,
          dice: "1d4",
          damage_type: "psychic"
        },
        %Spell{
          name: "daze",
          level: 0,
          kind: :save,
          casting_ability: :int,
          save_ability: :dex,
          dice: nil,
          damage_type: nil
        }
      ]
    )
  end

  defp world_with(%Character{} = target) do
    World.new()
    |> add(World.add_character(mage()))
    |> add(World.add_character(target))
  end

  defp rogue(level) do
    Character.new(
      name: "vex",
      class: "rogue",
      level: level,
      hp: 20,
      max_hp: 20,
      ac: 14,
      str: 10,
      dex: 14,
      con: 12,
      int: 10,
      wis: 10,
      cha: 10,
      side: "enemy"
    )
  end

  describe "Evasión (D59)" do
    test "rogue L7 success: no damage at all" do
      w = world_with(rogue(7))

      # Save 20+2=22 vs CD 13 → success; damage roll 20 → Evasión → 0.
      {:ok, msg, change} = Actions.spell(w, "mage", "acid splash", "vex", fixed(20))
      assert msg =~ "(Evasión: sin daño)"

      {:ok, w2} = change.(w)
      assert w2.characters["vex"].hp == 20
    end

    test "rogue L7 failure: half damage" do
      w = world_with(rogue(7))

      # Save 5+2=7 vs CD 13 → fail; damage 5 → Evasión → 2.
      {:ok, msg, change} = Actions.spell(w, "mage", "acid splash", "vex", fixed(5))
      assert msg =~ "(Evasión: mitad)"

      {:ok, w2} = change.(w)
      assert w2.characters["vex"].hp == 20 - 2
    end

    test "odd damage rounds down on a failed save" do
      w = world_with(rogue(7))

      # Save 7+2=9 vs CD 13 → fail; damage 7 → Evasión → 3 (7 |> div(2)).
      {:ok, _msg, change} = Actions.spell(w, "mage", "acid splash", "vex", fixed(7))

      {:ok, w2} = change.(w)
      assert w2.characters["vex"].hp == 20 - 3
    end

    test "rogue L6: no Evasión — normal half damage on success" do
      w = world_with(rogue(6))

      # Save 20+2=22 vs CD 13 → success; damage 20 → normal half → 10.
      {:ok, msg, change} = Actions.spell(w, "mage", "acid splash", "vex", fixed(20))
      refute msg =~ "Evasión"

      {:ok, w2} = change.(w)
      assert w2.characters["vex"].hp == 20 - 10
    end

    test "non-rogue L7: no Evasión" do
      w =
        world_with(
          Character.new(
            name: "figh",
            class: "fighter",
            level: 7,
            hp: 20,
            max_hp: 20,
            dex: 14,
            side: "enemy"
          )
        )

      {:ok, msg, change} = Actions.spell(w, "mage", "acid splash", "figh", fixed(20))
      refute msg =~ "Evasión"

      {:ok, w2} = change.(w)
      assert w2.characters["figh"].hp == 20 - 10
    end

    test "non-DEX save ignores Evasión" do
      w = world_with(rogue(7))

      # WIS save 20+0=20 vs CD 13 → success; damage 20 → normal half → 10.
      {:ok, msg, change} = Actions.spell(w, "mage", "vicious mockery", "vex", fixed(20))
      refute msg =~ "Evasión"

      {:ok, w2} = change.(w)
      assert w2.characters["vex"].hp == 20 - 10
    end

    test "spell that deals 0 damage stays 0 with Evasión" do
      w = world_with(rogue(7))

      # dice nil → full 0; success → 0 with or without Evasión.
      {:ok, msg, change} = Actions.spell(w, "mage", "daze", "vex", fixed(20))
      assert msg =~ "(Evasión: sin daño)"

      {:ok, w2} = change.(w)
      assert w2.characters["vex"].hp == 20
    end

    # ADR D59: la inspiración bárdica (D50) se aplica ANTES — un éxito
    # gracias al d6 también activa Evasión.
    test "a save rescued by bardic inspiration still triggers Evasión" do
      %Character{} = inspired = rogue(7)
      w = world_with(%Character{inspired | inspired: true})

      # d20 8+2=10 < CD 13 → fallo; +5 inspiración → 15 ≥ 13 → éxito
      # gracias al d6 → Evasión: 0 daño (el 1d6 de daño se tira igual).
      {:ok, msg, change} = Actions.spell(w, "mage", "acid splash", "vex", seq([8, 5, 4]))

      assert msg =~ "(d20 8: 15 vs CD 13 +5 inspiración)"
      assert msg =~ "(Evasión: sin daño)"
      assert Process.get(:seq) == []

      {:ok, w2} = change.(w)
      assert w2.characters["vex"].hp == 20
      assert w2.characters["vex"].inspired == false
    end
  end
end
