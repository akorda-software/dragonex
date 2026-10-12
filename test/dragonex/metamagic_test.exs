defmodule Dragonex.MetamagicTest do
  @moduledoc """
  D65 Metamagic: hechicero L3+ arma UNA opción gastando puntos de
  hechicería (Empowered 1 / Heightened 3 / Twinned 2); el motor la aplica
  y consume con el próximo hechizo que califique (consume-on-apply —
  divergencia menor de RAW documentada en el ADR). El LLM decide CUÁNDO
  armar; el motor aplica (D1).
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Codec, PCAgent, Spell, Tools, World}
  alias ExAgent.{Session, Session.SharedState}

  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  # Hechicero L5, CAR 16 (mod +3 → Empowered mejora 3 dados), prof 3,
  # bonus de hechizo +6, CD de salvación 14.
  defp sorcerer(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Sylas",
          class: "sorcerer",
          level: 5,
          sorcery_points: 5,
          hp: 20,
          max_hp: 20,
          ac: 13,
          str: 9,
          dex: 14,
          con: 12,
          cha: 16,
          side: "pc",
          spells: [
            %Spell{
              name: "scorch",
              level: 1,
              kind: :attack,
              casting_ability: :cha,
              dice: "4d6",
              damage_type: "fire"
            },
            %Spell{
              name: "poison spray",
              level: 0,
              kind: :save,
              casting_ability: :cha,
              save_ability: :con,
              dice: "2d6",
              damage_type: "poison"
            },
            %Spell{
              name: "hold person",
              level: 1,
              kind: :save,
              casting_ability: :cha,
              save_ability: :wis,
              dice: nil,
              damage_type: nil,
              effect: "Paralizado"
            },
            %Spell{
              name: "mend",
              level: 0,
              kind: :automatic,
              casting_ability: :cha,
              dice: "1d4",
              damage_type: nil
            },
            %Spell{
              name: "mage armor",
              level: 1,
              kind: :automatic,
              casting_ability: :cha,
              dice: nil,
              damage_type: nil,
              effect: "Armadura arcana"
            }
          ]
        ],
        opts
      )
    )
  end

  defp goblin(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Goblin",
          class: "monster",
          hp: 30,
          max_hp: 30,
          ac: 12,
          side: "enemy"
        ],
        opts
      )
    )
  end

  defp kobold(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Kobold",
          class: "monster",
          hp: 20,
          max_hp: 20,
          ac: 12,
          side: "enemy"
        ],
        opts
      )
    )
  end

  defp world(chars) do
    chars
    |> Enum.reduce(World.new(), fn c, w ->
      {:ok, w} = World.add_character(c).(w)
      w
    end)
    |> World.init_spell_slots()
  end

  defp arm!(w, option, target \\ "") do
    {:ok, _, change} = Actions.arm_metamagic(w, "Sylas", option, target)
    {:ok, w2} = change.(w)
    w2
  end

  # -------------------------------------------------------------- armar

  describe "Actions.arm_metamagic/4" do
    test "empowered L3+: gasta 1 punto, fija el mapa y mensaje ES exacto" do
      w = world([sorcerer([]), goblin()])

      assert {:ok, msg, change} = Actions.arm_metamagic(w, "Sylas", "empowered")

      assert msg ==
               "Sylas arma Metamagia: Empowered (1 punto de hechicería, quedan 4). " <>
                 "El próximo hechizo que califique la aplicará."

      {:ok, w2} = change.(w)
      assert w2.characters["Sylas"].metamagic == %{option: "empowered", target: nil}
      assert w2.characters["Sylas"].sorcery_points == 4
    end

    test "heightened con target: gasta 3 puntos y lo menciona" do
      w = world([sorcerer([]), goblin()])

      assert {:ok, msg, change} = Actions.arm_metamagic(w, "Sylas", "heightened", "Goblin")

      assert msg ==
               "Sylas arma Metamagia: Heightened (3 puntos de hechicería, quedan 2) sobre Goblin. " <>
                 "El próximo hechizo que califique la aplicará."

      {:ok, w2} = change.(w)
      assert w2.characters["Sylas"].metamagic == %{option: "heightened", target: "Goblin"}
      assert w2.characters["Sylas"].sorcery_points == 2
    end

    test "twinned: gasta 2 puntos exactos" do
      w = world([sorcerer([]), goblin(), kobold()])

      assert {:ok, msg, change} = Actions.arm_metamagic(w, "Sylas", "twinned", "Kobold")

      assert msg =~ "(2 puntos de hechicería, quedan 3) sobre Kobold"

      {:ok, w2} = change.(w)
      assert w2.characters["Sylas"].metamagic == %{option: "twinned", target: "Kobold"}
      assert w2.characters["Sylas"].sorcery_points == 3
    end

    test "opción tolerante a mayúsculas y espacios" do
      w = world([sorcerer([])])
      assert {:ok, _, change} = Actions.arm_metamagic(w, "Sylas", " Empowered ")
      {:ok, w2} = change.(w)
      assert w2.characters["Sylas"].metamagic.option == "empowered"
    end

    test "L2 error (nivel 3) y no muta" do
      w = world([sorcerer(level: 2)])
      assert {:error, msg} = Actions.arm_metamagic(w, "Sylas", "empowered")
      assert msg =~ "no tiene Metamagia (nivel 3)"
      assert w.characters["Sylas"].metamagic == nil
      assert w.characters["Sylas"].sorcery_points == 5
    end

    test "no hechicero error" do
      w = world([goblin(class: "wizard", side: "pc", level: 5)])
      assert {:error, msg} = Actions.arm_metamagic(w, "Goblin", "empowered")
      assert msg =~ "no es hechicero"
    end

    test "who inexistente / caído error" do
      w = world([sorcerer([])])
      assert {:error, msg} = Actions.arm_metamagic(w, "ghost", "empowered")
      assert msg =~ "no existe"

      w = world([sorcerer(hp: 0)])
      assert {:error, msg} = Actions.arm_metamagic(w, "Sylas", "empowered")
      assert msg =~ "caído"
    end

    test "opción desconocida lista las tres válidas" do
      w = world([sorcerer([])])
      assert {:error, msg} = Actions.arm_metamagic(w, "Sylas", "quickened")
      assert msg =~ "válidas: empowered, heightened, twinned"
      assert w.characters["Sylas"].sorcery_points == 5
    end

    test "ya armada error (no hay un-arm en v1) y no gasta" do
      w = arm!(world([sorcerer([])]), "empowered")

      assert {:error, msg} = Actions.arm_metamagic(w, "Sylas", "twinned", "Goblin")
      assert msg =~ "ya tiene Metamagia armada: Empowered"
      assert msg =~ "próximo hechizo que califique"
      assert w.characters["Sylas"].metamagic.option == "empowered"
      assert w.characters["Sylas"].sorcery_points == 4
    end

    test "puntos insuficientes error con coste exacto" do
      w = world([sorcerer(sorcery_points: 2), goblin()])

      assert {:error, msg} = Actions.arm_metamagic(w, "Sylas", "heightened", "Goblin")
      assert msg =~ "le quedan 2"
      assert msg =~ "Heightened cuesta 3"
      assert w.characters["Sylas"].metamagic == nil
    end

    test "heightened sin target / twinned sin target, inexistente o self error" do
      w = world([sorcerer([]), goblin(), kobold()])

      assert {:error, msg} = Actions.arm_metamagic(w, "Sylas", "heightened")
      assert msg =~ "heightened requiere un objetivo"

      assert {:error, msg} = Actions.arm_metamagic(w, "Sylas", "twinned", "")
      assert msg =~ "twinned requiere un segundo objetivo"

      assert {:error, msg} = Actions.arm_metamagic(w, "Sylas", "twinned", "Nadie")
      assert msg =~ "no existe el objetivo: Nadie"

      assert {:error, msg} = Actions.arm_metamagic(w, "Sylas", "twinned", "Sylas")
      assert msg =~ "twinned no puede gemarse a sí mismo"
    end
  end

  # ------------------------------------------------------ empowered

  describe "Empowered en resolve_spell" do
    test "hechizo de ataque: los primeros 3 dados de 4d6 se tiran dos veces (conserva el mayor)" do
      w = arm!(world([sorcerer([]), goblin()]), "empowered")

      # d20 15 → 15+6=21 vs CA 12 (acierta, no crit). Daño 4d6 con CAR
      # +3 → 3 dados mejorados: (2,5)→5, (1,6)→6, (3,3)→3 + el 4º normal 4
      # = 18 (sin Metamagia sería 2+5+1+6=14).
      assert {:ok, msg, change} =
               Actions.spell(w, "Sylas", "scorch", "Goblin", seq([15, 2, 5, 1, 6, 3, 3, 4]))

      assert msg =~ "por 18 de daño de fuego (Metamagia: Empowered)"

      {:ok, w2} = change.(w)
      assert w2.characters["Goblin"].hp == 30 - 18
      # Consumida al aplicarse; los puntos gastados no se reembolsan.
      assert w2.characters["Sylas"].metamagic == nil
      assert w2.characters["Sylas"].sorcery_points == 4
    end

    test "hechizo de salvación: los dados de daño también se mejoran" do
      w = arm!(world([sorcerer([]), goblin()]), "empowered")

      # Salvación CON 10 → 10 vs CD 14 falla. 2d6 (ambos mejorados, CAR
      # +3 ≥ 2 dados): (3,6)→6, (1,2)→2 = 8 (sin Metamagia 3+6=9 de las
      # primeras tiradas — conserva el mayor por dado).
      assert {:ok, msg, change} =
               Actions.spell(w, "Sylas", "poison spray", "Goblin", seq([10, 3, 6, 1, 2]))

      assert msg =~ "8 de daño de veneno (Metamagia: Empowered)"

      {:ok, w2} = change.(w)
      assert w2.characters["Sylas"].metamagic == nil
    end

    test "crítico dobla la base mejorada SIN duplicar los rerolls" do
      w = arm!(world([sorcerer([]), goblin()]), "empowered")

      # d20 20 → crítico. Base mejorada: (1,4)→4, (2,2)→2, (5,2)→5, 6 →
      # 17 con 7 tiradas del roller; el crítico la dobla → 34 (no 14 dados).
      assert {:ok, msg, _change} =
               Actions.spell(w, "Sylas", "scorch", "Goblin", seq([20, 1, 4, 2, 2, 5, 2, 6]))

      assert msg =~ "por 34 de daño de fuego (Metamagia: Empowered)"
    end

    test "hechizo de ataque que falla igualmente consume (el hechizo califica)" do
      w = arm!(world([sorcerer([]), goblin()]), "empowered")

      assert {:ok, _msg, change} = Actions.spell(w, "Sylas", "scorch", "Goblin", seq([2]))

      {:ok, w2} = change.(w)
      assert w2.characters["Sylas"].metamagic == nil
    end

    test "hechizo sin dados de daño (curación) NO consume ni etiqueta" do
      w = arm!(world([sorcerer([]), goblin()]), "empowered")

      # Curación 1d4: 3 + mod CAR 3 = 6 pg al Goblin (aliado aquí no, pero
      # el motor no valida side en spells).
      assert {:ok, msg, change} = Actions.spell(w, "Sylas", "mend", "Goblin", seq([3]))

      assert msg =~ "se cura 6 pg"
      refute msg =~ "Metamagia"

      {:ok, w2} = change.(w)
      assert w2.characters["Sylas"].metamagic == %{option: "empowered", target: nil}
    end
  end

  # ------------------------------------------------------ heightened

  describe "Heightened en resolve_spell" do
    test "salvación del objetivo armado con desventaja, etiqueta y consumo" do
      w = arm!(world([sorcerer([]), goblin()]), "heightened", "Goblin")

      # Desventaja: dos d20 (16, 5) → conserva 5 → 5 vs CD 14 falla (con
      # 16 habría superado). Daño 2d6 = 2+2 = 4 completo.
      assert {:ok, msg, change} =
               Actions.spell(w, "Sylas", "poison spray", "Goblin", seq([16, 5, 2, 2]))

      assert msg =~ "(desventaja) (Metamagia: Heightened)"
      assert msg =~ "4 de daño de veneno"

      {:ok, w2} = change.(w)
      assert w2.characters["Goblin"].hp == 30 - 4
      assert w2.characters["Sylas"].metamagic == nil
    end

    test "otro objetivo: salvación normal, NO aplica NI consume" do
      w = world([sorcerer([]), goblin(), kobold()])
      w = arm!(w, "heightened", "Kobold")

      # Sin desventaja: un solo d20 (16) → 16 vs CD 14 supera → mitad.
      assert {:ok, msg, change} =
               Actions.spell(w, "Sylas", "poison spray", "Goblin", seq([16, 3, 6]))

      assert msg =~ "supera la salvación (d20 16"
      refute msg =~ "Metamagia: Heightened"

      {:ok, w2} = change.(w)
      assert w2.characters["Sylas"].metamagic == %{option: "heightened", target: "Kobold"}
    end

    test "hechizo que no exige salvación (:attack) NO consume" do
      w = arm!(world([sorcerer([]), goblin()]), "heightened", "Goblin")

      assert {:ok, _msg, change} =
               Actions.spell(w, "Sylas", "scorch", "Goblin", seq([15, 1, 1, 1, 1]))

      {:ok, w2} = change.(w)
      assert w2.characters["Sylas"].metamagic == %{option: "heightened", target: "Goblin"}
    end
  end

  # ------------------------------------------------------ twinned

  describe "Twinned en resolve_spell" do
    test "hechizo ofensivo golpea a ambos objetivos, una casilla, bloque por objetivo" do
      w = world([sorcerer([]), goblin(), kobold()])
      w = arm!(w, "twinned", "Kobold")

      # Goblin: d20 15 → 21 vs CA 12 acierta; 4d6 = 2+5+1+6 = 14.
      # Kobold: d20 8 → 14 vs CA 12 acierta; 4d6 = 1+1+1+1 = 4 (dados
      # propios de cada resolución, no re-uso).
      assert {:ok, msg, change} =
               Actions.spell(w, "Sylas", "scorch", "Goblin", seq([15, 2, 5, 1, 6, 8, 1, 1, 1, 1]))

      assert msg ==
               "Sylas conjura scorch (Metamagia: Twinned): " <>
                 "en Goblin: impacta a Goblin (d20 15: 21 vs CA 12) por 14 de daño de fuego; " <>
                 "en Kobold: impacta a Kobold (d20 8: 14 vs CA 12) por 4 de daño de fuego."

      {:ok, w2} = change.(w)
      assert w2.characters["Goblin"].hp == 30 - 14
      assert w2.characters["Kobold"].hp == 20 - 4
      # UNA casilla (el hechizo es uno): sorcerer L5 → 4 de nivel 1, gasta 1.
      assert w2.spell_slots["Sylas"][1] == 3
      assert w2.characters["Sylas"].metamagic == nil
    end

    test "concentración se fija UNA sola vez (hechizo de concentración)" do
      w = world([sorcerer([]), goblin(), kobold()])
      w = arm!(w, "twinned", "Kobold")

      # Salvaciones SAB: Goblin 16 falla (16 < 18? no — CD 14: supera).
      # Daño 0 (sin dados): sólo importa la concentración.
      assert {:ok, msg, change} =
               Actions.spell(w, "Sylas", "hold person", "Goblin", seq([16, 8]))

      assert msg =~ "en Goblin:"
      assert msg =~ "en Kobold:"
      assert msg =~ "Sylas concentra en Inmovilizar persona"

      {:ok, w2} = change.(w)
      assert w2.characters["Sylas"].concentrating == "hold person"
      assert w2.characters["Sylas"].metamagic == nil
    end

    test "hechizo sobre sí mismo (self-buff) NO aplica NI consume" do
      w = world([sorcerer([]), goblin(), kobold()])
      w = arm!(w, "twinned", "Kobold")

      # mage armor: self-buff SIN restricción de combate (D96 exige combate
      # para shield; este test verifica Twinned, no la postura de shield).
      assert {:ok, msg, change} = Actions.spell(w, "Sylas", "mage armor", "Sylas", seq([]))

      assert msg =~ "conjura Armadura de mago sobre Sylas"
      refute msg =~ "Twinned"

      {:ok, w2} = change.(w)
      assert w2.characters["Sylas"].metamagic == %{option: "twinned", target: "Kobold"}
    end

    test "hechizo de curación gemado cura a ambos objetivos" do
      w = world([sorcerer(hp: 10), goblin(hp: 10), kobold(hp: 10)])
      w = arm!(w, "twinned", "Kobold")

      # 1d4 = 4 + mod CAR 3 → 7 pg a cada objetivo.
      assert {:ok, msg, change} = Actions.spell(w, "Sylas", "mend", "Goblin", seq([4, 4]))

      assert msg =~ "en Goblin: se cura 7 pg"
      assert msg =~ "en Kobold: se cura 7 pg"

      {:ok, w2} = change.(w)
      assert w2.characters["Goblin"].hp == 17
      assert w2.characters["Kobold"].hp == 17
      assert w2.characters["Sylas"].metamagic == nil
    end
  end

  # ------------------------------------------------------ rests y codec

  describe "rests y Codec" do
    test "long rest recarga puntos pero NO toca la metamagia armada" do
      w = world([sorcerer(sorcery_points: 5)])
      w = arm!(w, "heightened", "Goblin")
      assert w.characters["Sylas"].sorcery_points == 2

      {:ok, _, rest} = Actions.long_rest(w, "Sylas")
      {:ok, w2} = rest.(w)

      assert w2.characters["Sylas"].sorcery_points == 5
      assert w2.characters["Sylas"].metamagic == %{option: "heightened", target: "Goblin"}
    end

    test "Codec ida y vuelta conserva el mapa (claves átomo)" do
      w = arm!(world([sorcerer([]), kobold()]), "twinned", "Kobold")

      encoded = Codec.encode_character(w.characters["Sylas"])
      assert encoded["metamagic"] == %{"option" => "twinned", "target" => "Kobold"}

      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)

      decoded = Codec.decode_character(decoded_map)
      assert decoded.metamagic == %{option: "twinned", target: "Kobold"}
    end

    test "jsonb viejo sin campo → nil; opción malformada → nil" do
      encoded = sorcerer([]) |> Codec.encode_character() |> Map.drop(["metamagic"])
      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)
      assert Codec.decode_character(decoded_map).metamagic == nil

      malformed =
        sorcerer([])
        |> Codec.encode_character()
        |> Map.put("metamagic", %{"option" => "quickened"})

      {:ok, json} = Jason.encode(malformed)
      {:ok, decoded_map} = Jason.decode(json)
      assert Codec.decode_character(decoded_map).metamagic == nil
    end

    test "default nil en Character.new y changeset" do
      assert Character.new(name: "X", class: "sorcerer").metamagic == nil

      {:ok, sheet} =
        Character.new(name: "X", class: "sorcerer")
        |> Ecto.Changeset.change(%{})
        |> Ecto.Changeset.apply_action(:insert)

      assert sheet.metamagic == nil
    end
  end

  # ------------------------------------------------------ tools

  describe "Tools.arm_metamagic" do
    test "PC sí mismo arma vía Session" do
      game =
        start_session(
          world: world([sorcerer([]), goblin()]),
          policy: :round_robin,
          participants: [p("Sylas")]
        )

      assert {:ok, "Sylas"} = Session.start(game)

      pc = %{deps: %{state: SharedState.new(game, "Sylas"), roller: fixed_roller(1)}}

      assert {:ok, msg} = Tools.arm_metamagic(pc, "Sylas", "empowered", "")

      assert msg =~ "arma Metamagia: Empowered (1 punto de hechicería, quedan 4)"

      state = Session.read_state(game)
      assert state.characters["Sylas"].metamagic == %{option: "empowered", target: nil}
      assert state.characters["Sylas"].sorcery_points == 4
    end

    test "PC otro who error (guard self)" do
      game =
        start_session(
          world: world([sorcerer([]), sorcerer(name: "Mira")]),
          policy: :round_robin,
          participants: [p("dm"), p("Sylas"), p("Mira")]
        )

      assert {:ok, "dm"} = Session.start(game)

      ctx = %{deps: %{state: SharedState.new(game, "Sylas"), roller: fixed_roller(1)}}
      assert {:error, msg} = Tools.arm_metamagic(ctx, "Mira", "empowered", "")
      assert msg =~ "RECHAZADO"

      assert Session.read_state(game).characters["Mira"].metamagic == nil
    end

    test "DM cualquiera" do
      game =
        start_session(
          world: world([sorcerer([]), goblin()]),
          policy: :round_robin,
          participants: [p("dm"), p("Sylas")]
        )

      assert {:ok, "dm"} = Session.start(game)

      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: fixed_roller(1)}}
      assert {:ok, _} = Tools.arm_metamagic(dm, "Sylas", "heightened", "Goblin")
      assert Session.read_state(game).characters["Sylas"].metamagic.option == "heightened"
    end
  end

  # ------------------------------------------------------ agentes

  describe "agentes" do
    test "PCAgent expone la tool y la línea de combate del hechicero L3+" do
      names = PCAgent.tools() |> Enum.map(&to_string(&1.name))
      assert "arm_metamagic" in names

      sylas = sorcerer([])

      combat =
        World.new(phase: :combat, characters: %{"Sylas" => sylas, "Goblin" => goblin()})

      instr = PCAgent.instruction("Sylas", sylas, combat)
      assert instr =~ "arm_metamagic"
      assert instr =~ "1/3/2"

      # L2 no tiene Metamagia: sin línea.
      young = sorcerer(level: 2)

      refute PCAgent.instruction("Sylas", young, combat) =~ "arm_metamagic"

      # Armada: la línea recuerda que el próximo hechizo la consume.
      armed = %{sylas | metamagic: %{option: "twinned", target: "Goblin"}}

      assert PCAgent.instruction("Sylas", armed, combat) =~ "Metamagia ARMADA (Twinned)"
    end

    test "DM prompt menciona la tool" do
      assert Dragonex.DM.system_prompt() =~ "arm_metamagic"
    end

    test "Text.scrub elimina las calls narradas en prosa" do
      scrubbed = Dragonex.Text.scrub(~s{Sylas arma arm_metamagic("Sylas", "empowered", "").})
      refute scrubbed =~ "arm_metamagic"
    end
  end
end
