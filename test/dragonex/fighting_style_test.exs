defmodule Dragonex.FightingStyleTest do
  @moduledoc """
  Fighting Style 5e (D48): archery +2 attack (ranged), defense +1 AC when
  targeted, dueling +2 melee weapon damage. No Protection, TWF, GWF.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Codec, Heroes, Rules.Combat, Weapon, World}

  defp always(n), do: fn _sides -> n end

  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp longsword do
    %Weapon{
      name: "longsword",
      dice: "1d8",
      damage_type: "slashing",
      attack_ability: :str
    }
  end

  defp longbow do
    %Weapon{
      name: "longbow",
      dice: "1d8",
      damage_type: "piercing",
      attack_ability: :dex,
      ranged: true
    }
  end

  defp fighter(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Thane",
          class: "fighter",
          level: 1,
          hp: 12,
          max_hp: 12,
          ac: 16,
          str: 16,
          dex: 16,
          con: 14,
          side: "pc",
          weapons: [longsword(), longbow()]
        ],
        opts
      )
    )
  end

  defp goblin(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "goblin",
          class: "monster",
          hp: 30,
          max_hp: 30,
          ac: 16,
          side: "enemy"
        ],
        opts
      )
    )
  end

  defp world(chars) do
    Enum.reduce(chars, World.new(), fn c, w ->
      {:ok, w} = World.add_character(c).(w)
      w
    end)
  end

  describe "archery" do
    test "longbow total is d20 + prof + dex + 2" do
      a = fighter(fighting_style: "archery")
      # d20 10 + prof 2 + dex 3 + archery 2 = 17
      assert {:hit, 10, 17} = Combat.attack_roll(a, longbow(), 10, always(10))
    end

    test "melee does not get the +2" do
      a = fighter(fighting_style: "archery")
      # d20 10 + prof 2 + str 3 = 15
      assert {:hit, 10, 15} = Combat.attack_roll(a, longsword(), 10, always(10))
    end
  end

  describe "defense" do
    test "hit vs AC 16 misses when target has defense (effective 17)" do
      w = world([fighter([]), goblin(fighting_style: "defense")])
      # d20 11 + prof 2 + str 3 = 16 vs CA 17 → miss; sheet AC stays 16
      assert {:ok, msg, change} = Actions.attack(w, "Thane", "goblin", "longsword", always(11))
      assert msg =~ "fallo"
      assert msg =~ "vs CA 17"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 30
      assert w2.characters["goblin"].ac == 16
    end

    test "same total hits when target has no defense" do
      w = world([fighter([]), goblin()])
      # d20 11 + 5 = 16 vs CA 16 → hit; d8=4 + str 3 = 7
      assert {:ok, msg, change} =
               Actions.attack(w, "Thane", "goblin", "longsword", seq([11, 4]))

      assert msg =~ "acierta"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 23
    end
  end

  describe "dueling" do
    test "melee weapon damage includes +2" do
      a = fighter(fighting_style: "dueling")
      # 1d8=5 + str 3 + dueling 2 = 10
      assert Combat.damage_roll(a, longsword(), :hit, always(5)) == 10
    end

    test "ranged weapon damage does not include +2" do
      a = fighter(fighting_style: "dueling")
      # 1d8=5 + dex 3 = 8
      assert Combat.damage_roll(a, longbow(), :hit, always(5)) == 8
    end
  end

  describe "nil" do
    test "no attack or damage bonus" do
      a = fighter(fighting_style: nil)
      assert {:hit, 10, 15} = Combat.attack_roll(a, longbow(), 10, always(10))
      assert {:hit, 10, 15} = Combat.attack_roll(a, longsword(), 10, always(10))
      assert Combat.damage_roll(a, longsword(), :hit, always(5)) == 8
    end

    test "unknown style is a no-op" do
      a = fighter(fighting_style: "protection")
      assert {:hit, 10, 15} = Combat.attack_roll(a, longbow(), 10, always(10))
      assert Combat.damage_roll(a, longsword(), :hit, always(5)) == 8
    end
  end

  describe "codec" do
    test "roundtrip of the three styles" do
      for style <- ~w(archery defense dueling) do
        c = fighter(fighting_style: style)
        w = world([c])
        again = Codec.decode(Codec.encode(w)).characters["Thane"]
        assert again.fighting_style == style
      end
    end

    test "old jsonb without fighting_style is nil" do
      encoded = fighter([]) |> Codec.encode_character() |> Map.delete("fighting_style")
      refute Map.has_key?(encoded, "fighting_style")

      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)

      decoded = Codec.decode_character(decoded_map)
      assert decoded.fighting_style == nil
    end

    test "invalid stored style decodes to nil" do
      encoded = fighter([]) |> Codec.encode_character() |> Map.put("fighting_style", "protection")
      assert Codec.decode_character(encoded).fighting_style == nil
    end
  end

  describe "Heroes.build" do
    test "fighter defaults to defense" do
      {:ok, c} =
        Heroes.build(%{name: "Thane", race: "human", class: "fighter", background: "soldier"})

      assert c.fighting_style == "defense"
      assert c.ac == 18
    end

    test "fighter honors an explicit style" do
      {:ok, c} =
        Heroes.build(%{
          name: "Thane",
          race: "human",
          class: "fighter",
          background: "soldier",
          fighting_style: "archery"
        })

      assert c.fighting_style == "archery"
    end

    test "non-fighter is nil" do
      {:ok, c} =
        Heroes.build(%{
          name: "Lyra",
          race: "elf",
          subrace: "high elf",
          class: "wizard",
          background: "sage"
        })

      assert c.fighting_style == nil
    end
  end
end
