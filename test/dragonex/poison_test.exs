defmodule Dragonex.PoisonTest do
  @moduledoc """
  D75 Giant Spider (araña gigante CR 1 en el bestiario — la primera fuente
  REAL de daño de veneno del motor: ni monstruos ni hechizos del catálogo
  usaban "poison" como arma) y D76 Dwarven Resilience (Resistencia enana:
  resistencia al daño de veneno + ventaja en salvaciones contra veneno).

  * **D75 (M59)**: `Monsters.giant_spider/1` en el catálogo con key
    `"giant_spider"`. Mordida "3d8+3 poison": los dados son "3d8" a secas
    porque `Combat.damage_roll` suma el mod de aptitud (DES +3) — los
    dados de arma solo parsean `NdM` (un "3d8+3" literal haría crash, ver
    bear_bite) — y DES también da el +5 al ataque RAW (prof 2 + 3).
    Simplificación documentada (ADR D75): RAW es 1d8+3 perforante MÁS 2d8
    veneno (salvación CON CD 11 para mitad); el motor modela UN tipo de
    daño por arma → combinado en un total "3d8+3 poison" sin salvación
    intermedia. Sin telaraña ni trepar (sin posicionamiento).
  * **D76 (M60)**: sin campos, sin tools, sin prompts. (1) RESISTENCIA:
    un enano (`race == "dwarf"`) recibe la MITAD (floor) del daño de
    veneno en la capa D38 de `Character.incoming_damage/3` — la misma
    capa que `World.apply_damage/3-4` aplica justo tras Uncanny Dodge
    (D64), así que se apilan multiplicativamente (mitad × mitad = cuarto,
    RAW) y las simulaciones (DC de concentración, tracking multi-golpe)
    quedan coherentes. (2) VENTAJA en la salvación de la rama :save de
    `cast_spell` cuando `spell.damage_type == "poison"`: fuente extra
    `dwarf_advantage:` en `Conditions.save_mode/4` (patrón gnome_advantage
    D71, cancelada por combine/2 contra Heightened/desventaja), etiqueta
    "(Resistencia enana: ventaja)". El catálogo tiene exactamente UN
    hechizo así hoy (cloudkill del SRD: CON, 5d8 poison); los tests usan
    un fixture con esos mismos datos.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Codec, Monsters, Rules.Conditions, Spell, Weapon, World}

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

  defp spider(opts \\ []) do
    Keyword.merge([name: "araña"], opts) |> Monsters.giant_spider()
  end

  # Enano L1: CON 12 (+1), sin prof de salvación de CON.
  defp dwarf(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Dagna",
          race: "dwarf",
          class: "fighter",
          level: 1,
          hp: 20,
          max_hp: 20,
          ac: 16,
          str: 14,
          dex: 10,
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

  # Control no-enano: mismas stats, distinta raza.
  defp human(opts \\ []), do: dwarf(Keyword.merge([name: "Thane", race: "human"], opts))

  # Enana pícara L5 (DEX 14): puede armar Esquiva asombrosa (D64).
  defp dwarf_rogue5(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Vorna",
          race: "dwarf",
          class: "rogue",
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
          side: "pc"
        ],
        opts
      )
    )
  end

  # Mago enemigo L5: INT 16 → CD de salvación 8 + prof 3 + 3 = 14. Dos
  # hechizos :save con la MISMA aptitud de salvación (CON) y dados,
  # distinto damage_type — el único delta es el veneno.
  defp mage5(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "mage",
          race: "human",
          class: "wizard",
          level: 5,
          hp: 20,
          max_hp: 20,
          ac: 12,
          str: 8,
          dex: 14,
          con: 12,
          int: 16,
          wis: 12,
          cha: 10,
          side: "enemy",
          spells: [
            %Spell{
              # Fixture con los datos del cloudkill del SRD (CON, 5d8
              # poison, nivel 5) — el único hechizo de veneno con
              # salvación del catálogo hoy.
              name: "poison cloud",
              level: 5,
              kind: :save,
              casting_ability: :int,
              save_ability: :con,
              dice: "5d8",
              damage_type: "poison"
            },
            %Spell{
              name: "frost snap",
              level: 5,
              kind: :save,
              casting_ability: :int,
              save_ability: :con,
              dice: "5d8",
              damage_type: "cold"
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

  defp arm_dodge!(w, who) do
    {:ok, _, change} = Actions.start_uncanny_dodge(w, who)
    {:ok, w2} = change.(w)
    w2
  end

  # ------------------------------------------- D75: catálogo y stats

  describe "D75 — araña gigante en el catálogo" do
    test "giant_spider está en el catálogo con stats RAW CR 1" do
      assert Monsters.get("giant_spider") != nil
      assert "giant_spider" in Monsters.keys()

      s = Monsters.giant_spider()
      assert s.name == "giant spider"
      assert s.race == "beast"
      assert s.class == "monster"
      assert s.side == "enemy"
      assert s.hp == 26 and s.max_hp == 26
      assert s.ac == 14
      assert {s.str, s.dex, s.con, s.int, s.wis, s.cha} == {15, 16, 12, 2, 12, 7}
      assert s.speed == 30
      assert s.saving_proficiencies == ["dex"]

      assert [%Weapon{} = bite] = s.weapons

      assert bite ==
               %Weapon{
                 name: "bite",
                 dice: "3d8",
                 damage_type: "poison",
                 attack_ability: :dex,
                 finesse: false,
                 ranged: false
               }

      # Sin telaraña ni otras armas (fuera de alcance, ADR D75).
      assert length(s.weapons) == 1
    end

    test "nombre custom vía opts (patrón builders)" do
      assert Monsters.giant_spider(name: "Arañón").name == "Arañón"
    end

    test "NO es forma de Wild Shape (CR 1 > tope 1/2 de D63)" do
      refute Map.has_key?(Monsters.wild_shape_beasts(), "giant_spider")
    end
  end

  # ---------------------------------------- D75: bite 3d8+3 poison

  describe "D75 — la mordida hace 3d8+3 poison (roller exacto)" do
    test "no-enano recibe el daño completo" do
      w = world([spider(), human()])

      # d20 15 + prof 2 + DES 3 = 20 vs CA 16 → acierta;
      # 3d8(4+4+4) + DES 3 = 15 de daño de veneno.
      assert {:ok, msg, change} = Actions.attack(w, "araña", "Thane", "bite", seq([15, 4, 4, 4]))

      assert msg =~ "araña acierta a Thane"
      assert msg =~ "por 15 de daño de veneno"
      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Thane"].hp == 20 - 15
    end
  end

  # ------------------------------- D76: resistencia (mitad con floor)

  describe "D76 — resistencia al veneno del enano (mitad floor)" do
    test "World.apply_damage directo: enano mitad, no-enano completo" do
      w = world([dwarf(), human()])

      {:ok, w} = World.apply_damage("Dagna", 9, "poison").(w)
      assert w.characters["Dagna"].hp == 20 - 4

      {:ok, w} = World.apply_damage("Thane", 9, "poison").(w)
      assert w.characters["Thane"].hp == 20 - 9
    end

    test "daño de otro tipo (y plano) NO se mitiga para el enano" do
      w = world([dwarf()])

      {:ok, w} = World.apply_damage("Dagna", 9, "fire").(w)
      assert w.characters["Dagna"].hp == 20 - 9

      # Sin tipo = daño plano: la resistencia no aplica (semántica D38).
      {:ok, w2} = World.apply_damage("Dagna", 5).(w)
      assert w2.characters["Dagna"].hp == 20 - 9 - 5
    end

    test "el bite de la araña: enano recibe la mitad (floor) del daño" do
      w = world([spider(), dwarf()])

      # Mismo golpe exacto: 15 poison → div(15, 2) = 7.
      assert {:ok, msg, change} = Actions.attack(w, "araña", "Dagna", "bite", seq([15, 4, 4, 4]))

      assert msg =~ "por 15 de daño de veneno"
      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Dagna"].hp == 20 - 7
    end

    test "enana pícara con Esquiva asombrosa: un cuarto (floor(floor(d/2)/2))" do
      w = arm_dodge!(world([spider(), dwarf_rogue5()]), "Vorna")

      # 15 → dodge div(15, 2) = 7 → resistencia div(7, 2) = 3. Mitad ×
      # mitad = cuarto (RAW), y la postura se consume.
      assert {:ok, _msg, change} = Actions.attack(w, "araña", "Vorna", "bite", seq([15, 4, 4, 4]))

      {:ok, w2} = change.(w)
      assert w2.characters["Vorna"].hp == 20 - 3
      assert w2.characters["Vorna"].uncanny_dodge == false
    end
  end

  # --------------------------- D76: ventaja en salvaciones contra veneno

  describe "D76 — ventaja en la salvación de hechizo :save de veneno" do
    test "enana: DOS dados, etiqueta y mitad de la mitad" do
      w = world([mage5(), dwarf()])

      # Ventaja max(3, 14) = 14 + CON 1 = 15 ≥ CD 14 → éxito;
      # 5d8(2×5) = 10 → mitad de salvación 5 → resistencia div(5, 2) = 2.
      assert {:ok, msg, change} =
               Actions.spell(w, "mage", "poison cloud", "Dagna", seq([3, 14, 2, 2, 2, 2, 2]))

      assert msg =~
               "Dagna supera la salvación (d20 14: 15 vs CD 14) (Resistencia enana: ventaja), " <>
                 "mitad de daño — 5 de daño de veneno"

      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Dagna"].hp == 20 - 2
    end

    test "no-enano: UN dado y sin etiqueta racial" do
      w = world([mage5(), human(name: "Dagna")])

      # 14 + CON 1 = 15 ≥ 14 → éxito; mitad 5, sin resistencia → 5.
      assert {:ok, msg, change} =
               Actions.spell(w, "mage", "poison cloud", "Dagna", seq([14, 2, 2, 2, 2, 2]))

      assert msg =~ "Dagna supera la salvación (d20 14: 15 vs CD 14), mitad de daño"
      refute msg =~ "Resistencia enana"
      refute msg =~ "(ventaja)"
      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["Dagna"].hp == 20 - 5
    end

    test "hechizo de otro tipo: la enana NO tiene ventaja" do
      w = world([mage5(), dwarf()])

      # Mismo save CON y dados, damage_type "cold": UN dado.
      assert {:ok, msg, _change} =
               Actions.spell(w, "mage", "frost snap", "Dagna", seq([14, 2, 2, 2, 2, 2]))

      assert msg =~
               "Dagna supera la salvación (d20 14: 15 vs CD 14), mitad de daño — 5 de daño de frío"

      refute msg =~ "Resistencia enana"
      refute msg =~ "(ventaja)"
      assert consumed?()
    end

    test "Heightened (D65) + Resistencia enana = normal (UN dado, cancelación)" do
      w = world([mage5(metamagic: %{option: "heightened", target: "Dagna"}), dwarf()])

      # Ventaja racial + desventaja Heightened → normal: UN dado (14 ≥ 14
      # con el +1 de CON → éxito) y el daño de veneno se resiste igual (la
      # MITAD de la salvación es independiente del modo).
      assert {:ok, msg, change} =
               Actions.spell(w, "mage", "poison cloud", "Dagna", seq([14, 2, 2, 2, 2, 2]))

      assert msg =~ "Dagna supera la salvación (d20 14: 15 vs CD 14) (Metamagia: Heightened)"
      refute msg =~ "Resistencia enana"
      refute msg =~ "(ventaja)"
      refute msg =~ "(desventaja)"
      assert consumed?()

      {:ok, w2} = change.(w)
      assert w2.characters["mage"].metamagic == nil
      assert w2.characters["Dagna"].hp == 20 - 2
    end
  end

  # ------------------------------------------ D76: Conditions unitario

  describe "D76 — Conditions.save_mode/4 (fuente dwarf_advantage)" do
    test "añade ventaja y combine/2 la cancela contra desventaja" do
      assert {:roll, :advantage} =
               Conditions.save_mode(dwarf(), :con, :normal, dwarf_advantage: true)

      assert {:roll, :normal} =
               Conditions.save_mode(dwarf(), :con, :disadvantage, dwarf_advantage: true)

      assert {:roll, :normal} = Conditions.save_mode(dwarf(), :con, :normal)

      # El gate de veneno vive en el sitio que inyecta la opt (damage_type
      # del hechizo + raza) — save_mode aplica la fuente a cualquier ability.
      assert {:roll, :advantage} =
               Conditions.save_mode(dwarf(), :dex, :normal, dwarf_advantage: true)
    end
  end

  # ------------------------------------------------------ Codec (sin cambios)

  describe "Codec — ida y vuelta del monstruo spider (regresión)" do
    test "encode → JSON → decode conserva bite 3d8 poison y stats" do
      encoded =
        Monsters.giant_spider(name: "Ara")
        |> Codec.encode_character()
        |> Jason.encode!()
        |> Jason.decode!()

      decoded = Codec.decode_character(encoded)

      assert decoded.name == "Ara"
      assert decoded.race == "beast"
      assert decoded.class == "monster"
      assert decoded.hp == 26 and decoded.max_hp == 26 and decoded.ac == 14
      assert decoded.dex == 16

      assert [%Weapon{} = bite] = decoded.weapons
      assert bite.name == "bite"
      assert bite.dice == "3d8"
      assert bite.damage_type == "poison"
      assert bite.attack_ability == :dex
    end
  end
end
