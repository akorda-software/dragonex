defmodule Dragonex.UncannyDodgeTest do
  @moduledoc """
  D64 Uncanny Dodge: rogue L5+ arms a defensive posture (boolean flag,
  pattern `inspired`/`reckless`); the engine halves ANY incoming damage
  (floor) at the entry of `World.apply_damage/3` — before resistances
  (D38) and temp_hp (D36) — and consumes the flag. amount <= 0 never
  consumes it. Stacks with Evasión (D59): half of half. The LLM decides
  WHEN to arm; the engine mitigates (D1).
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Codec, Spell, Tools, World}
  alias ExAgent.{Session, Session.SharedState}

  defp fixed(value), do: Dragonex.Dice.always(value)

  defp rogue(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Vex",
          class: "rogue",
          race: "human",
          level: 5,
          hp: 20,
          max_hp: 20,
          ac: 14,
          str: 10,
          dex: 14,
          con: 12,
          int: 10,
          wis: 10,
          cha: 10,
          side: "pc",
          weapons: [
            %Dragonex.Weapon{
              name: "shortsword",
              dice: "1d6",
              damage_type: "piercing",
              attack_ability: :dex,
              finesse: true
            }
          ]
        ],
        opts
      )
    )
  end

  defp goblin(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Goblin",
          class: "monster",
          race: "humanoid",
          level: 1,
          hp: 7,
          max_hp: 7,
          ac: 15,
          dex: 14,
          side: "enemy",
          weapons: [
            %Dragonex.Weapon{
              name: "scimitar",
              dice: "1d6",
              damage_type: "slashing",
              attack_ability: :dex,
              finesse: true
            }
          ]
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

  defp arm!(w, who \\ "Vex") do
    {:ok, _, change} = Actions.start_uncanny_dodge(w, who)
    {:ok, w2} = change.(w)
    w2
  end

  # ------------------------------------------------------------- armar

  describe "Actions.start_uncanny_dodge/2" do
    test "pícaro L5 arma con mensaje ES exacto" do
      w = world([rogue([]), goblin([])])
      refute w.characters["Vex"].uncanny_dodge

      assert {:ok, msg, change} = Actions.start_uncanny_dodge(w, "Vex")

      assert msg ==
               "Vex se prepara para esquivar (Uncanny Dodge armado: el próximo daño se reduce a la mitad)."

      {:ok, w2} = change.(w)
      assert w2.characters["Vex"].uncanny_dodge == true
    end

    test "ya armada error y no muta" do
      w = arm!(world([rogue([]), goblin([])]))
      assert {:error, msg} = Actions.start_uncanny_dodge(w, "Vex")
      assert msg =~ "ya tiene Esquiva asombrosa armada"
      assert w.characters["Vex"].uncanny_dodge == true
    end

    test "no pícaro error" do
      w = world([goblin(name: "Thane", class: "fighter", side: "pc", hp: 12, max_hp: 12)])
      assert {:error, msg} = Actions.start_uncanny_dodge(w, "Thane")
      assert msg =~ "no es pícaro"
    end

    test "L4 error" do
      w = world([rogue(level: 4), goblin([])])
      assert {:error, msg} = Actions.start_uncanny_dodge(w, "Vex")
      assert msg =~ "nivel 5"
    end

    test "caído error" do
      w = world([rogue(hp: 0), goblin([])])
      assert {:error, msg} = Actions.start_uncanny_dodge(w, "Vex")
      assert msg =~ "caído"
    end

    test "who no existe error" do
      assert {:error, msg} = Actions.start_uncanny_dodge(World.new(), "ghost")
      assert msg =~ "no existe"
    end
  end

  # -------------------------------------------- mitigación en apply_damage

  describe "World.apply_damage/3 mitiga y consume" do
    test "próximo daño a la mitad (floor) y flag consumida" do
      w = arm!(world([rogue([]), goblin([])]))

      {:ok, w2} = World.apply_damage("Vex", 9).(w)
      assert w2.characters["Vex"].hp == 20 - 4
      assert w2.characters["Vex"].uncanny_dodge == false
    end

    test "segundo daño completo" do
      w = arm!(world([rogue([]), goblin([])]))
      {:ok, w} = World.apply_damage("Vex", 9).(w)

      {:ok, w2} = World.apply_damage("Vex", 10).(w)
      assert w2.characters["Vex"].hp == 20 - 4 - 10
    end

    test "amount 1 → mitad 0 y SÍ consume" do
      w = arm!(world([rogue([]), goblin([])]))

      {:ok, w2} = World.apply_damage("Vex", 1).(w)
      assert w2.characters["Vex"].hp == 20
      assert w2.characters["Vex"].uncanny_dodge == false
    end

    test "amount 0 no consume la flag" do
      w = arm!(world([rogue([]), goblin([])]))

      {:ok, w2} = World.apply_damage("Vex", 0).(w)
      assert w2.characters["Vex"].uncanny_dodge == true
    end

    test "temp_hp absorbe tras la mitad (orden documentado)" do
      w = arm!(world([rogue([]), goblin([])]))
      {:ok, w} = World.apply_temp_hp("Vex", 5).(w)

      # Daño 10 → mitad 5 → temp 5 absorbe todo → PG intactos.
      {:ok, w2} = World.apply_damage("Vex", 10).(w)
      s = w2.characters["Vex"]
      assert s.hp == 20
      assert s.temp_hp == 0
      assert s.uncanny_dodge == false
    end

    test "daño de ataque (make_attack) también se mitiga" do
      w = arm!(world([rogue([]), goblin([])]))

      # fixed(15): golpe 15+prof 2+DES 2=19 vs CA 14 → acierta; daño
      # 1d6(15)+DES 2=17 → mitad 8 → PG 12.
      assert {:ok, msg, change} = Actions.attack(w, "Goblin", "Vex", "scimitar", fixed(15))
      assert msg =~ "por 17 de daño slashing"

      {:ok, w2} = change.(w)
      assert w2.characters["Vex"].hp == 20 - 8
      assert w2.characters["Vex"].uncanny_dodge == false
    end

    test "rearmar tras consumir es gratis" do
      w = arm!(world([rogue([]), goblin([])]))
      {:ok, w} = World.apply_damage("Vex", 10).(w)
      assert w.characters["Vex"].uncanny_dodge == false

      assert {:ok, _, change} = Actions.start_uncanny_dodge(w, "Vex")
      {:ok, w2} = change.(w)
      assert w2.characters["Vex"].uncanny_dodge == true
    end

    test "rests NO gestionan la flag (armada persiste)" do
      w = arm!(world([rogue([]), goblin([])]))

      {:ok, _, rest} = Actions.long_rest(w, "Vex")
      {:ok, w2} = rest.(w)
      assert w2.characters["Vex"].uncanny_dodge == true

      {:ok, _, rest} = Actions.short_rest(w2, "Vex", fixed(4))
      {:ok, w3} = rest.(w2)
      assert w3.characters["Vex"].uncanny_dodge == true
    end
  end

  # ------------------------------------------------- apila con Evasión

  describe "apila con Evasión (D59)" do
    # Wizard L1: int 16 → save CD 13 (8 + prof 2 + mod 3).
    defp mage do
      Character.new(
        name: "mage",
        class: "wizard",
        hp: 7,
        max_hp: 7,
        ac: 12,
        dex: 14,
        int: 16,
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
          }
        ]
      )
    end

    test "save DES fallado: mitad (Evasión) → mitad (dodge) = cuarto, floor" do
      vex = rogue(name: "vex", level: 7, side: "enemy")
      w = world([mage(), vex])
      w = arm!(w, "vex")

      # fixed(5): salvación 5+2=7 vs CD 13 → falla; daño 5 → Evasión
      # div(5,2)=2 → apply_damage mitiga div(2,2)=1 → PG 19.
      {:ok, msg, change} = Actions.spell(w, "mage", "acid splash", "vex", fixed(5))
      assert msg =~ "(Evasión: mitad)"

      {:ok, w2} = change.(w)
      assert w2.characters["vex"].hp == 20 - 1
      assert w2.characters["vex"].uncanny_dodge == false
    end
  end

  # ------------------------------------------------------------- Codec

  describe "Codec" do
    test "ida y vuelta conserva la flag" do
      w = arm!(world([rogue([]), goblin([])]))
      decoded = Codec.decode(Codec.encode(w))
      assert decoded.characters["Vex"].uncanny_dodge == true

      {:ok, w2} = World.apply_damage("Vex", 9).(w)
      decoded = Codec.decode(Codec.encode(w2))
      assert decoded.characters["Vex"].uncanny_dodge == false
    end

    test "jsonb viejo sin campo → false" do
      encoded = rogue([]) |> Codec.encode_character() |> Map.drop(["uncanny_dodge"])

      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)

      decoded = Codec.decode_character(decoded_map)
      assert decoded.uncanny_dodge == false
    end

    test "default false en Character.new y changeset" do
      assert Character.new(name: "X", class: "rogue").uncanny_dodge == false

      {:ok, sheet} =
        Character.new(name: "X", class: "rogue")
        |> Ecto.Changeset.change(%{})
        |> Ecto.Changeset.apply_action(:insert)

      assert sheet.uncanny_dodge == false
    end
  end

  # ------------------------------------------------------------- tools

  describe "Tools.start_uncanny_dodge" do
    test "PC sí mismo arma y el daño posterior se mitiga" do
      vex = rogue([])

      game =
        start_session(
          world: World.new(characters: %{"Vex" => vex, "Goblin" => goblin([])}),
          policy: :round_robin,
          participants: [p("Vex")]
        )

      assert {:ok, "Vex"} = Session.start(game)

      pc = %{deps: %{state: SharedState.new(game, "Vex"), roller: fixed_roller(1)}}

      assert {:ok, msg} = Tools.start_uncanny_dodge(pc, "Vex")

      assert msg ==
               "Vex se prepara para esquivar (Uncanny Dodge armado: el próximo daño se reduce a la mitad)."

      assert Session.read_state(game).characters["Vex"].uncanny_dodge == true

      # El daño que pasa por el Session propuesto ya se mitiga (cuello único).
      {:ok, _} = SharedState.propose_change(pc.deps.state, World.apply_damage("Vex", 9))

      state = Session.read_state(game)
      assert state.characters["Vex"].hp == 20 - 4
      assert state.characters["Vex"].uncanny_dodge == false
    end

    test "PC otro who error (guard self)" do
      vex = rogue([])
      thane = rogue(name: "Thane")

      game =
        start_session(
          world: World.new(characters: %{"Vex" => vex, "Thane" => thane}),
          policy: :round_robin,
          participants: [p("dm"), p("Vex"), p("Thane")]
        )

      assert {:ok, "dm"} = Session.start(game)

      ctx = %{deps: %{state: SharedState.new(game, "Vex"), roller: fixed_roller(1)}}
      assert {:error, msg} = Tools.start_uncanny_dodge(ctx, "Thane")
      assert msg =~ "RECHAZADO"

      assert Session.read_state(game).characters["Thane"].uncanny_dodge == false
    end

    test "DM cualquiera" do
      vex = rogue([])

      game =
        start_session(
          world: World.new(characters: %{"Vex" => vex}),
          policy: :round_robin,
          participants: [p("dm"), p("Vex")]
        )

      assert {:ok, "dm"} = Session.start(game)

      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: fixed_roller(1)}}
      assert {:ok, _} = Tools.start_uncanny_dodge(dm, "Vex")
      assert Session.read_state(game).characters["Vex"].uncanny_dodge == true
    end
  end
end
