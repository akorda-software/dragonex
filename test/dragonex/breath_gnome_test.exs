defmodule Dragonex.BreathGnomeTest do
  @moduledoc """
  D70 Breath Weapon (dragontino, tool de combate con salvación DES y daño
  de fuego por nivel) y D71 Astucia gnoma (gnomo, ventaja pasiva en
  salvaciones mentales INT/SAB/CAR contra "magia" — equivalencia engine:
  toda salvación de `cast_spell` rama :save y de `turn_undead`).

  * **D70 (M54)**: `breath_weapon(who, target)` — dragontino (`race ==
    "dragonborn"`, cualquier clase/nivel), 1 uso por descanso (short Y
    long recargan, patrón ki D54), CD = 8 + CON + competencia, éxito →
    mitad (floor). Gasta el uso SIEMPRE que se resuelve. Target caído
    permitido; no es hechizo (funciona en Forma salvaje D63).
  * **D71 (M55)**: sin campos, sin rests, sin tools — ventaja inyectada
    como fuente extra en `Conditions.save_mode` (combine/2 la cancela
    contra Heightened D65 o desventaja de condición) + etiqueta
    "(Astucia gnoma: ventaja)". NO aplica a checks, death saves,
    concentración (CON) ni salvaciones DES.
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Codec, Rules.Conditions, Spell, Tools, World}
  alias Dragonex.Heroes.Progression
  alias ExAgent.{Session, Session.SharedState}

  defp fixed(n), do: Dragonex.Dice.always(n)

  # A roller that pops values from a queue, so advantage (two dice per
  # roll), damage dice and rerolls are distinct and countable.
  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp consumed?, do: Process.get(:seq) == []

  # Dragontino L2: CON 14 (+2), prof L2 (+2) → CD 12. breath L2 = 2d6.
  defp dragonborn(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Draco",
          race: "dragonborn",
          class: "fighter",
          level: 2,
          hp: 20,
          max_hp: 20,
          ac: 16,
          str: 16,
          dex: 12,
          con: 14,
          int: 10,
          wis: 10,
          cha: 10,
          side: "pc"
        ],
        opts
      )
    )
  end

  # Objetivo con DES 14 (+1), sin prof de salvación.
  defp goblin(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Goblin",
          class: "monster",
          race: "goblinoid",
          level: 1,
          hp: 20,
          max_hp: 20,
          ac: 13,
          str: 10,
          dex: 14,
          con: 10,
          int: 10,
          wis: 10,
          cha: 10,
          side: "enemy"
        ],
        opts
      )
    )
  end

  # Hechicero enemigo L1: INT 16 → CD 13. Cuatro trucos :save (SAB/INT/
  # CAR/DES) para ejercitar los cuatro abilities del gnomo.
  defp mage(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "mage",
          race: "human",
          class: "wizard",
          level: 1,
          hp: 7,
          max_hp: 7,
          ac: 12,
          str: 8,
          dex: 14,
          con: 13,
          int: 16,
          wis: 12,
          cha: 10,
          side: "enemy",
          spells: [
            %Spell{
              name: "psionic bolt",
              level: 0,
              kind: :save,
              casting_ability: :int,
              save_ability: :wis,
              dice: "1d8",
              damage_type: "psychic"
            },
            %Spell{
              name: "mind sliver",
              level: 0,
              kind: :save,
              casting_ability: :int,
              save_ability: :int,
              dice: "1d6",
              damage_type: "psychic"
            },
            %Spell{
              name: "word of fear",
              level: 0,
              kind: :save,
              casting_ability: :int,
              save_ability: :cha,
              dice: "1d6",
              damage_type: "psychic"
            },
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
        ],
        opts
      )
    )
  end

  # Gnomo L1 con mentales a 10 (mods 0, sin prof de salvación).
  defp gnome(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Bim",
          race: "gnome",
          class: "wizard",
          level: 1,
          hp: 10,
          max_hp: 10,
          ac: 12,
          str: 8,
          dex: 12,
          con: 12,
          int: 10,
          wis: 10,
          cha: 10,
          side: "pc"
        ],
        opts
      )
    )
  end

  defp paladin6 do
    Character.new(
      name: "Pali",
      race: "human",
      class: "paladin",
      level: 6,
      hp: 30,
      max_hp: 30,
      ac: 18,
      str: 16,
      dex: 10,
      con: 14,
      int: 10,
      wis: 10,
      cha: 16,
      side: "pc"
    )
  end

  defp world(chars) do
    Enum.reduce(chars, World.new(), fn c, w ->
      {:ok, w} = World.add_character(c).(w)
      w
    end)
  end

  # --------------------------------------------- D70 Progression.breath_dice

  describe "Progression.breath_dice (D70)" do
    test "escala por nivel: L1–4 2d6, L5–10 3d6, L11–16 4d6, L17+ 5d6" do
      assert Progression.breath_dice(1) == "2d6"
      assert Progression.breath_dice(4) == "2d6"
      assert Progression.breath_dice(5) == "3d6"
      assert Progression.breath_dice(10) == "3d6"
      assert Progression.breath_dice(11) == "4d6"
      assert Progression.breath_dice(16) == "4d6"
      assert Progression.breath_dice(17) == "5d6"
      assert Progression.breath_dice(20) == "5d6"
    end
  end

  # ------------------------------------------- D70 Actions.breath_weapon

  describe "Aliento de dragón (D70) — Actions" do
    test "L2: 2d6, salvación DES superada → mitad (floor), mensaje ES exacto" do
      w = world([dragonborn(), goblin()])

      # salvación 15+1=16 ≥ CD 12 → éxito; daño 2d6(3+5)=8 → mitad 4.
      assert {:ok, msg, change} = Actions.breath_weapon(w, "Draco", "Goblin", seq([15, 3, 5]))

      assert msg ==
               "Draco exhala aliento de dragón (fuego, usos restantes: 0): " <>
                 "Goblin supera la salvación de Destreza (d20 15: 17 vs CD 12), " <>
                 "mitad de daño — 4 de daño de fuego."

      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Goblin"].hp == 16
      assert w2.characters["Draco"].breath_weapon_used == true
    end

    test "salvación fallada → daño completo, CD = 8 + CON + prof" do
      w = world([dragonborn(), goblin()])

      # salvación 5+1=6 < CD 12 → fallo; daño 2d6(4+6)=10 completo.
      assert {:ok, msg, change} = Actions.breath_weapon(w, "Draco", "Goblin", seq([5, 4, 6]))

      assert msg =~ "falla la salvación de Destreza (d20 5: 7 vs CD 12)"
      assert msg =~ "— 10 de daño de fuego"

      {:ok, w2} = change.(w)
      assert w2.characters["Goblin"].hp == 10
    end

    test "escalado: L5 tira 3d6" do
      w = world([dragonborn(level: 5), goblin()])

      # CD 8+CON(+2)+prof(+3)=13; salvación 10+2=12 falla; 3d6(2+2+2)=6.
      assert {:ok, msg, change} =
               Actions.breath_weapon(w, "Draco", "Goblin", seq([10, 2, 2, 2]))

      assert msg =~ "vs CD 13"
      assert msg =~ "— 6 de daño de fuego"
      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Goblin"].hp == 14
    end

    test "escalado: L11 tira 4d6" do
      w = world([dragonborn(level: 11), goblin()])

      # CD 8+CON(+2)+prof(+4)=14; salvación 10+2=12 falla; 4d6(2+2+2+2)=8.
      assert {:ok, msg, _change} =
               Actions.breath_weapon(w, "Draco", "Goblin", seq([10, 2, 2, 2, 2]))

      assert msg =~ "— 8 de daño de fuego"
      assert consumed?()
    end

    test "escalado: L17 tira 5d6" do
      w = world([dragonborn(level: 17), goblin()])

      # CD 8+CON(+2)+prof(+6)=16; salvación 10+2=12 falla; 5d6(2+2+2+2+2)=10.
      assert {:ok, msg, _change} =
               Actions.breath_weapon(w, "Draco", "Goblin", seq([10, 2, 2, 2, 2, 2]))

      assert msg =~ "vs CD 16"
      assert msg =~ "— 10 de daño de fuego"
      assert consumed?()
    end

    test "gasta el uso siempre que resuelve y el repetido es error" do
      w = world([dragonborn(), goblin()])

      assert {:ok, _msg, change} = Actions.breath_weapon(w, "Draco", "Goblin", seq([15, 3, 5]))
      {:ok, w2} = change.(w)
      assert w2.characters["Draco"].breath_weapon_used == true

      assert {:error, reason} = Actions.breath_weapon(w2, "Draco", "Goblin", seq([15, 1, 1]))
      assert reason == "Draco ya ha usado su aliento de dragón (se recarga con un descanso)"
    end

    test "short rest recarga el aliento" do
      w = world([dragonborn(), goblin()])

      assert {:ok, _, change} = Actions.breath_weapon(w, "Draco", "Goblin", seq([15, 3, 5]))
      {:ok, w} = change.(w)
      assert w.characters["Draco"].breath_weapon_used == true

      assert {:ok, _, rest} = Actions.short_rest(w, "Draco", fixed(4))
      {:ok, w2} = rest.(w)
      assert w2.characters["Draco"].breath_weapon_used == false

      assert {:ok, _, _} = Actions.breath_weapon(w2, "Draco", "Goblin", seq([15, 3, 5]))
    end

    test "long rest recarga el aliento" do
      w = world([dragonborn(), goblin()])

      assert {:ok, _, change} = Actions.breath_weapon(w, "Draco", "Goblin", seq([15, 3, 5]))
      {:ok, w} = change.(w)

      assert {:ok, _, rest} = Actions.long_rest(w, "Draco")
      {:ok, w2} = rest.(w)
      assert w2.characters["Draco"].breath_weapon_used == false
    end

    test "no dragontino es error (sin mutar)" do
      w = world([dragonborn(race: "human"), goblin()])

      assert {:error, reason} = Actions.breath_weapon(w, "Draco", "Goblin", seq([]))
      assert reason == "Draco no es dragontino y no tiene aliento de dragón"
    end

    test "dragontino caído es error" do
      w = world([dragonborn(hp: 0), goblin()])

      assert {:error, reason} = Actions.breath_weapon(w, "Draco", "Goblin", seq([]))
      assert reason == "Draco está caído (0 pg) y no puede actuar"
    end

    test "who o target inexistentes son error" do
      w = world([dragonborn(), goblin()])

      assert {:error, "no existe el personaje: Nadie"} =
               Actions.breath_weapon(w, "Nadie", "Goblin", seq([]))

      assert {:error, "no existe el objetivo: Cosa"} =
               Actions.breath_weapon(w, "Draco", "Cosa", seq([]))
    end

    test "objetivo caído permitido: se resuelve y gasta el uso" do
      w = world([dragonborn(), goblin(hp: 0)])

      # Salvación normal (el 0 pg no impide salvar); daño floored a 0 pg.
      assert {:ok, msg, change} = Actions.breath_weapon(w, "Draco", "Goblin", seq([15, 3, 5]))

      assert msg =~ "exhala aliento de dragón (fuego, usos restantes: 0)"
      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Goblin"].hp == 0
      assert w2.characters["Draco"].breath_weapon_used == true
    end

    test "funciona en Forma salvaje (racial, no cast_spell)" do
      druid_dragonborn =
        dragonborn(class: "druid", wild_shape: %{beast: "cat", orig_hp: 20, orig_max_hp: 20})

      w = world([druid_dragonborn, goblin()])

      assert {:ok, msg, change} = Actions.breath_weapon(w, "Draco", "Goblin", seq([15, 3, 5]))
      assert msg =~ "exhala aliento de dragón"

      {:ok, w2} = change.(w)
      assert w2.characters["Draco"].breath_weapon_used == true
    end

    test "Evasión (D59): pícaro L7+ salva → 0 daño; falla → mitad" do
      rogue7 = goblin(name: "Vex", class: "rogue", level: 7, hp: 30, max_hp: 30)
      w = world([dragonborn(), rogue7])

      # Salva (15+2=17 ≥ 12) → Evasión: sin daño (el daño 2d6 se tira igual).
      assert {:ok, msg, _change} = Actions.breath_weapon(w, "Draco", "Vex", seq([15, 4, 4]))
      assert msg =~ "supera la salvación de Destreza (d20 15: 17 vs CD 12) (Evasión: sin daño)"
      assert msg =~ "— 0 de daño de fuego"

      # Falla (5+2=7 < 12) → Evasión: mitad (8 → 4).
      assert {:ok, msg2, change2} = Actions.breath_weapon(w, "Draco", "Vex", seq([5, 4, 4]))

      assert msg2 =~ "falla la salvación de Destreza (d20 5: 7 vs CD 12) (Evasión: mitad)"
      assert msg2 =~ "— 4 de daño de fuego"

      {:ok, w2} = change2.(w)
      assert w2.characters["Vex"].hp == 26
    end
  end

  # ------------------- D70: mismo stack de sitio de salvación que los hechizos

  # El ADR D70 promete que el aliento pasa por el MISMO stack que la rama
  # :save de cast_spell: Danger Sense (D58), Lucky (D66), aura (D61),
  # inspiración bárdica (D50), Indomitable (D68) y el chequeo de
  # concentración del objetivo (with_conc_damage). Evasión ya está arriba.
  describe "Aliente de dragón (D70) — stack completo de salvación" do
    test "el daño del aliento provoca el chequeo de concentración del objetivo" do
      w = world([dragonborn(), goblin(concentrating: "bless", con: 14)])

      # Salvación 5+1=6 < CD 12 → fallo; daño 2d6(3+5)=8; concentración CD
      # max(10, div(8,2))=10 → CON 3+2=5 < 10 → la pierde.
      assert {:ok, msg, change} =
               Actions.breath_weapon(w, "Draco", "Goblin", seq([5, 3, 5, 3]))

      assert msg =~ "Goblin pierde la concentración en Bendición"
      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Goblin"].concentrating == nil
      assert w2.characters["Draco"].breath_weapon_used == true
    end

    test "Danger Sense (D58): bárbaro L2+ salva la DES con ventaja" do
      w = world([dragonborn(), goblin(class: "barbarian", level: 2, con: 14)])

      # Ventaja max(1,15)=15 +2 = 17 ≥ CD 12 → éxito; daño 2d6(3+3)=6 → mitad 3.
      assert {:ok, msg, _change} =
               Actions.breath_weapon(w, "Draco", "Goblin", seq([1, 15, 3, 3]))

      assert msg =~ "(d20 15: 17 vs CD 12) (ventaja)"
      assert msg =~ "— 3 de daño de fuego"
      assert consumed?()
    end

    test "Lucky (D66): el 1 del mediano se rerrollea en la salvación del aliento" do
      w = world([dragonborn(), goblin(race: "halfling")])

      # 1 → Lucky → 18: 18+2=20 ≥ CD 12 → éxito; 2d6(3+5)=8 → mitad 4.
      assert {:ok, msg, _change} =
               Actions.breath_weapon(w, "Draco", "Goblin", seq([1, 18, 3, 5]))

      assert msg =~ "(d20 18 (Lucky: 1→18): 20 vs CD 12)"
      assert msg =~ "— 4 de daño de fuego"
      assert consumed?()
    end

    test "inspiración bárdica (D50): el d6 salva la tirada y se consume" do
      w = world([dragonborn(), goblin(inspired: true)])

      # 5+2=7 < CD 12 → fallo; +6 inspiración → 13 ≥ 12 → éxito; 2d6(4+4)=8
      # → mitad 4. El d6 se gasta (no re-tira en ningún segundo intento).
      assert {:ok, msg, change} =
               Actions.breath_weapon(w, "Draco", "Goblin", seq([5, 6, 4, 4]))

      assert msg =~ "(d20 5: 13 vs CD 12 +6 inspiración)"
      assert msg =~ "— 4 de daño de fuego"
      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Goblin"].inspired == false
    end

    test "Aura de Protección (D61): el aliado del paladín L6 suma +3" do
      w = world([dragonborn(), goblin(side: "pc", name: "Aliado"), paladin6()])

      # 10+2=12 < CD 12 → fallo... 12 ≥ 12 sería éxito; usamos 9: 9+2=11
      # < CD 12 → fallo; +3 aura → 14 ≥ 12 → éxito; 2d6(4+4)=8 → mitad 4.
      assert {:ok, msg, _change} =
               Actions.breath_weapon(w, "Draco", "Aliado", seq([9, 4, 4]))

      assert msg =~ "Aliado supera la salvación de Destreza (d20 9: 14 vs CD 12 +3 aura)"
      assert msg =~ "— 4 de daño de fuego"
      assert consumed?()
    end

    test "Indomitable (D68): el guerrero L9+ rerrollea la salvación fallida" do
      w = world([dragonborn(), goblin(class: "fighter", level: 9, dex: 12)])

      # 5+1=6 < CD 12 → fallo; reroll 15+1=16 ≥ 12 → éxito; 2d6(4+4)=8 → 4.
      assert {:ok, msg, change} =
               Actions.breath_weapon(w, "Draco", "Goblin", seq([5, 15, 4, 4]))

      assert msg =~ "(d20 15 (Indomitable: 6→16): 16 vs CD 12)"
      assert msg =~ "— 4 de daño de fuego"
      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Goblin"].indomitable_used == true
    end
  end

  # ------------------------------------------- D70 Character / Codec

  describe "Aliento de dragón (D70) — Character/Codec" do
    test "default false en Character.new y changeset" do
      assert Character.new(name: "X", class: "fighter").breath_weapon_used == false

      {:ok, sheet} =
        Character.new(name: "X", class: "fighter")
        |> Ecto.Changeset.change(%{})
        |> Ecto.Changeset.apply_action(:insert)

      assert sheet.breath_weapon_used == false
    end

    test "ida y vuelta Codec conserva la flag" do
      w = world([dragonborn(breath_weapon_used: true)])
      assert Codec.decode(Codec.encode(w)).characters["Draco"].breath_weapon_used == true
    end

    test "jsonb viejo sin campo → false" do
      encoded = dragonborn() |> Codec.encode_character() |> Map.drop(["breath_weapon_used"])

      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)

      decoded = Codec.decode_character(decoded_map)
      assert decoded.breath_weapon_used == false
    end
  end

  # --------------------------------------------------- D70 Tools.breath_weapon

  describe "Tools.breath_weapon (D70)" do
    test "PC otro who error" do
      game =
        start_session(
          world: World.new(characters: %{"Draco" => dragonborn(), "Goblin" => goblin()}),
          policy: :round_robin,
          participants: [p("dm"), p("Draco"), p("Vex")]
        )

      assert {:ok, "dm"} = Session.start(game)

      ctx = %{deps: %{state: SharedState.new(game, "Vex"), roller: fixed(15)}}
      assert {:error, msg} = Tools.breath_weapon(ctx, "Draco", "Goblin")
      assert msg =~ "RECHAZADO"
      refute Session.read_state(game).characters["Draco"].breath_weapon_used
    end

    test "PC sí mismo" do
      game =
        start_session(
          world: World.new(characters: %{"Draco" => dragonborn(), "Goblin" => goblin()}),
          policy: :round_robin,
          participants: [p("Draco")]
        )

      assert {:ok, "Draco"} = Session.start(game)

      pc = %{deps: %{state: SharedState.new(game, "Draco"), roller: fixed(15)}}
      assert {:ok, msg} = Tools.breath_weapon(pc, "Draco", "Goblin")
      assert msg =~ "Draco exhala aliento de dragón"
      assert Session.read_state(game).characters["Draco"].breath_weapon_used == true
    end

    test "DM cualquiera" do
      game =
        start_session(
          world: World.new(characters: %{"Draco" => dragonborn(), "Goblin" => goblin()}),
          policy: :round_robin,
          participants: [p("dm"), p("Draco")]
        )

      assert {:ok, "dm"} = Session.start(game)

      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: fixed(15)}}
      assert {:ok, msg} = Tools.breath_weapon(dm, "Draco", "Goblin")
      assert msg =~ "Draco exhala aliento de dragón"
      assert Session.read_state(game).characters["Draco"].breath_weapon_used == true
    end
  end

  # ------------------------------------- D71 Astucia gnoma (spell :save)

  describe "Astucia gnoma (D71) — hechizo :save" do
    test "salvación SAB con ventaja: dos dados, etiqueta y mitad" do
      w = world([mage(), gnome()])

      # ventaja max(3,14)=14 ≥ CD 13 → éxito; daño 1d8(5) → mitad 2.
      assert {:ok, msg, change} = Actions.spell(w, "mage", "psionic bolt", "Bim", seq([3, 14, 5]))

      assert msg =~
               "Bim supera la salvación (d20 14: 14 vs CD 13) (Astucia gnoma: ventaja), " <>
                 "mitad de daño — 2 de daño psíquico"

      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Bim"].hp == 8
    end

    test "salvación DES SIN ventaja: un dado, sin etiqueta" do
      w = world([mage(), gnome()])

      # DES no es mental: UN dado (14 ≥ 13 → mitad de 1d6(5)=2).
      assert {:ok, msg, _change} = Actions.spell(w, "mage", "acid splash", "Bim", seq([14, 5]))

      assert msg =~ "Bim supera la salvación (d20 14: 15 vs CD 13), mitad de daño"
      refute msg =~ "Astucia gnoma"
      assert consumed?()
    end

    test "salvación INT con ventaja" do
      w = world([mage(), gnome()])

      # ventaja max(8,15)=15 ≥ 13 → mitad de 1d6(4)=2.
      assert {:ok, msg, _change} = Actions.spell(w, "mage", "mind sliver", "Bim", seq([8, 15, 4]))

      assert msg =~ "(d20 15: 15 vs CD 13) (Astucia gnoma: ventaja)"
      assert msg =~ "— 2 de daño psíquico"
      assert consumed?()
    end

    test "salvación CAR con ventaja" do
      w = world([mage(), gnome()])

      # ventaja max(2,16)=16 ≥ 13 → mitad de 1d6(6)=3.
      assert {:ok, msg, _change} =
               Actions.spell(w, "mage", "word of fear", "Bim", seq([2, 16, 6]))

      assert msg =~ "(d20 16: 16 vs CD 13) (Astucia gnoma: ventaja)"
      assert msg =~ "— 3 de daño psíquico"
      assert consumed?()
    end

    test "no gnomo: SAB sin ventaja (un dado)" do
      w = world([mage(), gnome(race: "human")])

      assert {:ok, msg, _change} = Actions.spell(w, "mage", "psionic bolt", "Bim", seq([14, 5]))

      refute msg =~ "Astucia gnoma"
      refute msg =~ "(ventaja)"
      assert consumed?()
    end

    test "Heightened (D65) + Astucia gnoma = normal (un dado)" do
      w = world([mage(metamagic: %{option: "heightened", target: "Bim"}), gnome()])

      # ventaja gnoma + desventaja Heightened → normal: UN dado (14 ≥ 13).
      assert {:ok, msg, change} = Actions.spell(w, "mage", "psionic bolt", "Bim", seq([14, 5]))

      assert msg =~ "Bim supera la salvación (d20 14: 14 vs CD 13) (Metamagia: Heightened)"
      refute msg =~ "Astucia gnoma"
      refute msg =~ "(ventaja)"
      refute msg =~ "(desventaja)"
      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["mage"].metamagic == nil
    end

    test "Indomitable (D68): el reroll conserva la ventaja gnoma" do
      w = world([mage(), gnome(class: "fighter", level: 9)])

      # ventaja max(2,5)=5 < 13 falla → reroll ventaja max(4,15)=15 ≥ 13.
      assert {:ok, msg, change} =
               Actions.spell(w, "mage", "psionic bolt", "Bim", seq([2, 5, 4, 15, 6]))

      assert msg =~
               "Bim supera la salvación (d20 15 (Indomitable: 5→15): 15 vs CD 13) " <>
                 "(Astucia gnoma: ventaja), mitad de daño — 3 de daño psíquico"

      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Bim"].indomitable_used == true
    end

    test "Aura de Protección (D61) se apila: ventaja + bonus" do
      w = world([mage(), gnome(), paladin6()])

      # ventaja max(2,15)=15 + aura +3 = 18 ≥ 13 → mitad de 1d8(4)=2.
      assert {:ok, msg, _change} =
               Actions.spell(w, "mage", "psionic bolt", "Bim", seq([2, 15, 4]))

      assert msg =~ "(d20 15: 18 vs CD 13 +3 aura) (Astucia gnoma: ventaja)"
      assert consumed?()
    end

    test "concentración (CON): sin ventaja gnoma" do
      w = world([mage(), gnome(concentrating: "bless")])

      # DES salva (14+1=15 ≥ 13) → mitad de 1d6(4)=2; CON de concentración:
      # UN dado (12+1=13 ≥ CD 10) — mental gnomo no aplica a CON.
      assert {:ok, msg, _change} =
               Actions.spell(w, "mage", "acid splash", "Bim", seq([14, 4, 12]))

      assert msg =~ "Bim mantiene la concentración en Bendición (d20 12: 13 vs CD 10)"
      refute msg =~ "Astucia gnoma"
      assert consumed?()
    end

    test "Evasión (D59) independiente: DES salva sin ventaja y sin daño" do
      w = world([mage(), gnome(class: "rogue", level: 7)])

      # DES: sin ventaja gnoma (un dado); éxito + Evasión → 0 daño.
      assert {:ok, msg, _change} = Actions.spell(w, "mage", "acid splash", "Bim", seq([14, 5]))

      assert msg =~ "Bim supera la salvación (d20 14: 15 vs CD 13) (Evasión: sin daño)"
      refute msg =~ "Astucia gnoma"
      assert consumed?()
    end
  end

  # ------------------------------------------ D71 Conditions.save_mode

  describe "Astucia gnoma (D71) — Conditions.save_mode" do
    test "gnome_advantage añade ventaja y combine/2 la cancela" do
      assert {:roll, :advantage} =
               Conditions.save_mode(gnome(), :wis, :normal, gnome_advantage: true)

      assert {:roll, :normal} =
               Conditions.save_mode(gnome(), :wis, :disadvantage, gnome_advantage: true)

      assert {:roll, :normal} = Conditions.save_mode(gnome(), :wis, :normal)

      # El gate mental (INT/SAB/CAR) vive en los sitios que inyectan la
      # opt — save_mode/4 aplica la fuente que le pasen a cualquier ability.
      assert {:roll, :advantage} =
               Conditions.save_mode(gnome(), :dex, :normal, gnome_advantage: true)
    end
  end
end
