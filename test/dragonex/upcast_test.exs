defmodule Dragonex.UpcastTest do
  @moduledoc """
  Upcasting 5e RAW (ADR D74, M58): lanzar con casilla de nivel superior aplica
  el escalado EXACTO de la tabla curada (`Rules.Upcast`), consume la casilla
  PEDIDA y no muta nada en error. Rollers fijos → valores únicos esperados.

  Nota magic missile: RAW es +1 dardo (+1d4+1) por nivel de casilla sobre el
  1º (3 base): 2º → 4 dardos, 3º → 5 dardos (la línea del spec que decía
  "3º = 4 dardos" era un off-by-one; aquí se fija RAW — ver D74).
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Rules.Upcast, Spell, World}
  alias ExAgent.{Session, Session.SharedState}

  defp always(n), do: fn _sides -> n end

  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp spell(name, level, kind, dice, opts \\ []) do
    %Spell{
      name: name,
      level: level,
      kind: kind,
      casting_ability: Keyword.get(opts, :casting_ability, :int),
      dice: dice,
      damage_type: Keyword.get(opts, :damage_type),
      save_ability: Keyword.get(opts, :save_ability),
      effect: Keyword.get(opts, :effect)
    }
  end

  defp wizard(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Lyra",
          class: "wizard",
          level: 7,
          hp: 40,
          max_hp: 40,
          ac: 12,
          str: 8,
          dex: 14,
          con: 13,
          int: 16,
          wis: 12,
          cha: 10,
          side: "pc",
          spells: [
            spell("firebolt", 0, :attack, "1d10", damage_type: "fire"),
            spell("magic missile", 1, :automatic, "3d4+3", damage_type: "force"),
            spell("fireball", 3, :save, "8d6", damage_type: "fire", save_ability: :dex),
            spell("vampiric touch", 3, :attack, "3d6", damage_type: "necrotic"),
            spell("spiritual weapon", 2, :attack, nil),
            spell("shield of faith", 1, :automatic, nil,
              effect: "Un campo brillante otorga +2 a la CA durante la concentración."
            ),
            spell("sleep", 1, :automatic, "5d8")
          ]
        ],
        opts
      )
    )
  end

  defp cleric(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Mira",
          class: "cleric",
          level: 5,
          hp: 30,
          max_hp: 30,
          ac: 16,
          str: 12,
          dex: 10,
          con: 14,
          int: 10,
          wis: 16,
          cha: 12,
          side: "pc",
          spells: [
            %Spell{
              name: "cure wounds",
              level: 1,
              kind: :automatic,
              casting_ability: :wis,
              dice: "1d8"
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
        [name: "goblin", class: "monster", hp: 40, max_hp: 40, ac: 12, side: "enemy", dex: 12],
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

  # Hechicero L7 (casillas 1:4 2:3 3:3 4:1 5:1); goblin DES+1, CA 12.
  # CD de Lyra: 8 + prof 3 + INT 3 = 14.

  describe "Rules.Upcast (tabla curada)" do
    test "extra_dice: por nivel, cada dos niveles, dardos y sin entrada" do
      # +1 dado por nivel sobre la base.
      assert Upcast.extra_dice("fireball", 3, 4) == "1d6"
      assert Upcast.extra_dice("Fireball", 3, 9) == "6d6"
      assert Upcast.extra_dice("cure wounds", 1, 3) == "2d8"
      assert Upcast.extra_dice("cure wounds", 1, 1) == nil

      # Cada DOS niveles: los saltos impares no añaden.
      assert Upcast.extra_dice("spiritual weapon", 2, 3) == nil
      assert Upcast.extra_dice("spiritual weapon", 2, 4) == "1d8"

      # Vampiric touch: +1d6 por nivel sobre 3º (RAW 2014 — el borrador del
      # spec decía "cada dos", pero RAW es por nivel; ver ADR D74).
      assert Upcast.extra_dice("vampiric touch", 3, 4) == "1d6"
      assert Upcast.extra_dice("vampiric touch", 3, 5) == "2d6"
      assert Upcast.extra_dice("vampiric touch", 3, 6) == "3d6"

      # Magic missile: +1 dardo (+1d4+1) por nivel sobre 1º.
      assert Upcast.extra_dice("magic missile", 1, 2) == "1d4+1"
      assert Upcast.extra_dice("magic missile", 1, 3) == "2d4+2"

      # Sin entrada en la tabla no escala (nivel base o ausente).
      assert Upcast.extra_dice("shield of faith", 1, 3) == nil
      assert Upcast.extra_dice("sleep", 1, 3) == nil
    end

    test "scaled_spell combina base + extra en UNA expresión" do
      fb = spell("fireball", 3, :save, "8d6", damage_type: "fire")
      assert %Spell{dice: "9d6"} = Upcast.scaled_spell(fb, 4)
      assert %Spell{dice: "8d6"} = Upcast.scaled_spell(fb, 3)

      mm = spell("magic missile", 1, :automatic, "3d4+3", damage_type: "force")
      assert %Spell{dice: "4d4+4"} = Upcast.scaled_spell(mm, 2)

      sw = spell("spiritual weapon", 2, :attack, nil)
      assert %Spell{dice: "1d8"} = Upcast.scaled_spell(sw, 4)
      assert %Spell{dice: nil} = Upcast.scaled_spell(sw, 2)
    end
  end

  describe "fireball (save) a 4º" do
    setup do
      {:ok, world: world([wizard(), goblin()])}
    end

    test "9d6 exactos (8d6+1d6), consume casilla de 4º y etiqueta (nivel 4)", %{world: w} do
      # Save DES d20=3 → 4 vs CD 14: falla → daño completo. 9d6 con roller 3 = 27.
      assert {:ok, msg, change} =
               Actions.spell(w, "Lyra", "fireball", "goblin", always(3), nil, 4)

      assert msg =~ "conjura fireball (nivel 4)"
      refute msg =~ "(nivel 3)"

      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40 - 27
      # Se gasta la casilla PEDIDA (4º, única), no la de 3º.
      assert w2.spell_slots["Lyra"][4] == 0
      assert w2.spell_slots["Lyra"][3] == 3
    end

    test "nil = nivel base (compat): 8d6, casilla de 3º, sin etiqueta", %{world: w} do
      assert {:ok, msg, change} = Actions.spell(w, "Lyra", "fireball", "goblin", always(3))

      refute msg =~ "(nivel"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40 - 24
      assert w2.spell_slots["Lyra"][3] == 2
      assert w2.spell_slots["Lyra"][4] == 1
    end

    test "cast_level explícito == base se comporta igual que nil", %{world: w} do
      assert {:ok, msg, change} =
               Actions.spell(w, "Lyra", "fireball", "goblin", always(3), nil, 3)

      refute msg =~ "(nivel"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40 - 24
    end

    test "salvación con éxito: la mitad se calcula sobre el TOTAL escalado", %{world: w} do
      # d20=19 → 20 vs CD 14: éxito → mitad de 27 = 13.
      roller = seq([19, 3, 3, 3, 3, 3, 3, 3, 3, 3])

      assert {:ok, _msg, change} = Actions.spell(w, "Lyra", "fireball", "goblin", roller, nil, 4)
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40 - 13
    end

    test "el dado extra entra al RollLog como los base (misma etiqueta, total combinado)", %{
      world: w
    } do
      alias Dragonex.RollLog

      {:ok, rec} = RollLog.start()
      log = %RollLog{base: seq([19, 3, 3, 3, 3, 3, 3, 3, 3, 3]), recorder: rec}

      assert {:ok, _msg, _change} =
               Actions.spell(w, "Lyra", "fireball", "goblin", log.base, log, 4)

      entries = RollLog.entries(rec)
      dmg = Enum.find(entries, &(&1.kind == :damage))

      assert dmg.reason == "daño de fireball (fire)"
      assert dmg.dice == for(_ <- 1..9, do: [6, 3])
      assert dmg.total == 27

      RollLog.stop(rec)
    end
  end

  describe "validaciones (errores NO mutan)" do
    setup do
      # L5: tiene casillas de 3º pero NINGUNA de 4º.
      {:ok, world: world([wizard(level: 5), goblin()])}
    end

    test "sin casilla del nivel PEDIDO aunque tenga de la base", %{world: w} do
      assert {:error, msg} = Actions.spell(w, "Lyra", "fireball", "goblin", always(3), nil, 4)
      assert msg =~ "casillas de hechizo de nivel 4"
      # ...y con la de 3º sí puede.
      assert {:ok, _, change} = Actions.spell(w, "Lyra", "fireball", "goblin", always(3), nil, 3)
      {:ok, w2} = change.(w)
      assert w2.spell_slots["Lyra"][3] == 1
    end

    test "cast_level < nivel base → error claro", %{world: w} do
      assert {:error, msg} = Actions.spell(w, "Lyra", "fireball", "goblin", always(3), nil, 2)
      assert msg =~ "el nivel mínimo de este hechizo es 3"
    end

    test "cast_level > 9 → error", %{world: w} do
      assert {:error, msg} = Actions.spell(w, "Lyra", "fireball", "goblin", always(3), nil, 10)
      assert msg =~ "máximo 9"
    end

    test "cast_level no entero → error", %{world: w} do
      assert {:error, msg} = Actions.spell(w, "Lyra", "fireball", "goblin", always(3), nil, "4")
      assert msg =~ "debe ser un entero"
    end

    test "los trucos no se pueden lanzar a nivel superior", %{world: w} do
      assert {:error, msg} = Actions.spell(w, "Lyra", "firebolt", "goblin", always(3), nil, 1)
      assert msg =~ "trucos"
    end
  end

  describe "special-cases" do
    setup do
      {:ok, world: world([wizard(), goblin()])}
    end

    test "magic missile a 2º = 4 dardos (mensaje con el número real)", %{world: w} do
      # 4d4 con roller 2 = 8, +4 = 12.
      assert {:ok, msg, change} =
               Actions.spell(w, "Lyra", "magic missile", "goblin", always(2), nil, 2)

      assert msg =~ "4 dardos de fuerza"
      assert msg =~ "(nivel 2)"

      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40 - 12
      # Consume la casilla de 2º, no la de 1º.
      assert w2.spell_slots["Lyra"][2] == 2
      assert w2.spell_slots["Lyra"][1] == 4
    end

    test "magic missile a 3º = 5 dardos (RAW: +1 dardo por nivel sobre 1º)", %{world: w} do
      # 5d4 con roller 2 = 10, +5 = 15.
      assert {:ok, msg, change} =
               Actions.spell(w, "Lyra", "magic missile", "goblin", always(2), nil, 3)

      assert msg =~ "5 dardos de fuerza"
      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40 - 15
    end

    test "vampiric touch escala +1d6 por nivel sobre 3º (RAW 2014)" do
      # L11: casillas de 5º (2) y 6º (1). Ataque mágico: prof 4 + INT 3 = 7.
      # d20=10 → 17 vs CA 12: impacta. 5º = 5d6 (20 con roller 4); 6º = 6d6 (24).
      w11 = world([wizard(level: 11), goblin()])

      assert {:ok, _msg, change5} =
               Actions.spell(
                 w11,
                 "Lyra",
                 "vampiric touch",
                 "goblin",
                 seq([10, 4, 4, 4, 4, 4]),
                 nil,
                 5
               )

      {:ok, w2} = change5.(w11)
      assert w2.characters["goblin"].hp == 40 - 20
      assert w2.spell_slots["Lyra"][5] == 1

      assert {:ok, _msg, change6} =
               Actions.spell(
                 w11,
                 "Lyra",
                 "vampiric touch",
                 "goblin",
                 seq([10, 4, 4, 4, 4, 4, 4]),
                 nil,
                 6
               )

      {:ok, w3} = change6.(w11)
      assert w3.characters["goblin"].hp == 40 - 24
      assert w3.spell_slots["Lyra"][6] == 0
    end

    test "spiritual weapon a 4º añade 1d8 (base sin dados en el motor)", %{world: w} do
      # Ataque mágico: prof 3 + INT 3 = 6. d20=10 → 16 vs CA 12: impacta;
      # 1d8 con roller 5 = 5.
      assert {:ok, msg, change} =
               Actions.spell(w, "Lyra", "spiritual weapon", "goblin", seq([10, 5]), nil, 4)

      assert msg =~ "(nivel 4)"

      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40 - 5
      assert w2.spell_slots["Lyra"][4] == 0
    end

    test "sleep OMITIDO de la tabla: consume la casilla pedida sin dados extra" do
      # El motor modela sleep como 5d8 automáticos; sin entrada en la tabla,
      # subirlo no escala (ADR D74: escalados no modelados fuera).
      w = world([wizard(), goblin(hp: 20)])

      assert {:ok, msg, change} = Actions.spell(w, "Lyra", "sleep", "goblin", always(2), nil, 3)

      assert msg =~ "(nivel 3)"
      {:ok, w2} = change.(w)
      # 5d8 con roller 2 = 10 + INT 3 = 13 (los mismos dados que en base).
      assert w2.characters["goblin"].hp == 20 + 13
      assert w2.spell_slots["Lyra"][3] == 2
    end

    test "shield of faith (sin entrada) a 3º consume casilla 3º sin dados extra", %{world: w} do
      assert {:ok, msg, change} =
               Actions.spell(w, "Lyra", "shield of faith", "goblin", always(3), nil, 3)

      assert msg =~ "(nivel 3)"
      assert msg =~ "CA"

      {:ok, w2} = change.(w)
      assert w2.spell_slots["Lyra"][3] == 2
      assert w2.characters["goblin"].hp == 40
    end
  end

  describe "cure wounds (heal) a 3º" do
    test "+2d8 sobre 1d8 (3d8 + mod), consume casilla de 3º" do
      ally =
        Character.new(name: "Aerin", class: "fighter", hp: 10, max_hp: 30, ac: 16, side: "pc")

      w = world([cleric(), ally])

      # 3d8 con roller 4 = 12, + SAB 3 = 15.
      assert {:ok, msg, change} =
               Actions.spell(w, "Mira", "cure wounds", "Aerin", always(4), nil, 3)

      assert msg =~ "(nivel 3)"
      {:ok, w2} = change.(w)
      assert w2.characters["Aerin"].hp == 10 + 15
      assert w2.spell_slots["Mira"][3] == 1
    end
  end

  # Interacciones que el ADR D74 declara contra otros subsistemas: el gasto
  # de la casilla de PACTO del brujo (D40 vía slot_level_for), Twinned con
  # casilla superior (una sola casilla, "(nivel N)" en el outer, D65) y
  # Empowered sobre los dados COMBINADOS base+extra (D65).
  describe "interacciones D74 × D40/D65" do
    test "warlock: upcastear gasta la casilla de PACTO (slot_level_for)" do
      dark =
        Character.new(
          name: "dark",
          class: "warlock",
          level: 9,
          hp: 40,
          max_hp: 40,
          ac: 12,
          dex: 10,
          con: 14,
          cha: 16,
          side: "enemy",
          spells: [spell("fireball", 3, :save, "8d6", damage_type: "fire", save_ability: :dex)]
        )

      w = world([dark, goblin()])
      assert w.spell_slots["dark"] == %{5 => 2}

      # CD 8+prof 4+CAR 3=15; salvación 3+1=4 falla → 10d6 (8+2) con roller
      # 2 = 20 completos.
      assert {:ok, msg, change} =
               Actions.spell(w, "dark", "fireball", "goblin", always(2), nil, 5)

      assert msg =~ "conjura fireball (nivel 5)"

      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40 - 20
      # Una única casilla de pacto de 5º consumida (no hay casillas de 3º).
      assert w2.spell_slots["dark"] == %{5 => 1}
    end

    test "Twinned (D65) con cast_level: una casilla, dos resoluciones escaladas" do
      twin =
        Character.new(
          name: "Sylas",
          class: "sorcerer",
          level: 7,
          hp: 35,
          max_hp: 35,
          ac: 12,
          dex: 14,
          con: 12,
          cha: 16,
          side: "pc",
          metamagic: %{option: "twinned", target: "gob2"},
          spells: [spell("fireball", 3, :save, "8d6", damage_type: "fire", save_ability: :dex)]
        )

      w = world([twin, goblin(), goblin(name: "gob2")])

      # CD 8+prof 3+CAR 3=14; ambos fallan con 3+1=4 → 9d6 con roller 3 =
      # 27 por objetivo; UNA casilla de 4º.
      assert {:ok, msg, change} =
               Actions.spell(w, "Sylas", "fireball", "goblin", always(3), nil, 4)

      assert msg =~ "fireball (nivel 4)"
      assert msg =~ "goblin"
      assert msg =~ "gob2"
      refute msg =~ "(nivel 3)"

      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40 - 27
      assert w2.characters["gob2"].hp == 40 - 27
      assert w2.spell_slots["Sylas"][4] == 0
      assert w2.characters["Sylas"].metamagic == nil
    end

    test "Empowered (D65) boostea los dados COMBINADOS base+extra" do
      sylas =
        Character.new(
          name: "Sylas",
          class: "sorcerer",
          level: 7,
          hp: 35,
          max_hp: 35,
          ac: 12,
          dex: 14,
          con: 12,
          cha: 16,
          side: "pc",
          metamagic: %{option: "empowered"},
          spells: [spell("fireball", 3, :save, "8d6", damage_type: "fire", save_ability: :dex)]
        )

      w = world([sylas, goblin()])

      # CAR 16 → los primeros 3 dados de 9d6 tiran dos veces y conservan el
      # mayor: max(1,5)+max(2,6)+max(1,4) + 6×2 = 27. Salvación 3+1=4 falla
      # (CD 15: 8+prof 3+CAR 3... L7 prof 3) → 27 completos.
      roller = seq([3, 1, 5, 2, 6, 1, 4, 2, 2, 2, 2, 2, 2])

      assert {:ok, msg, change} = Actions.spell(w, "Sylas", "fireball", "goblin", roller, nil, 4)

      assert msg =~ "(nivel 4)"
      assert msg =~ "(Metamagia: Empowered)"
      assert msg =~ "27 de daño fire"
      assert Process.get(:seq) == []

      {:ok, w2} = change.(w)
      assert w2.characters["goblin"].hp == 40 - 27
      assert w2.spell_slots["Sylas"][4] == 0
      assert w2.characters["Sylas"].metamagic == nil
    end
  end

  describe "Tools + PCAgent" do
    setup do
      # El guard no cambia (D74): los PCs se conjuran a sí mismos; el DM, a
      # los no-PCs (aquí un mago enemigo).
      dark =
        Character.new(
          name: "dark",
          class: "wizard",
          level: 7,
          hp: 40,
          max_hp: 40,
          ac: 12,
          int: 16,
          side: "enemy",
          spells: [spell("fireball", 3, :save, "8d6", damage_type: "fire", save_ability: :dex)]
        )

      game =
        world([wizard(), dark, goblin()])
        |> then(
          &start_session(world: &1, policy: :round_robin, participants: [p("dm"), p("Lyra")])
        )

      assert {:ok, "dm"} = Session.start(game)
      %{game: game}
    end

    test "DM upcastea (entero y string); PC se conjura a sí mismo; guard sin cambio", %{
      game: game
    } do
      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: always(3)}}

      assert {:ok, msg} = Dragonex.Tools.cast_spell(dm, "dark", "fireball", "goblin", 4)
      assert msg =~ "conjura fireball (nivel 4)"
      assert Session.read_state(game).spell_slots["dark"][4] == 0

      # El string "4" del modelo se coacciona a entero — la casilla de 4º ya
      # se gastó arriba, y el error cita el nivel PEDIDO (4), no "entero".
      assert {:error, msg2} = Dragonex.Tools.cast_spell(dm, "dark", "fireball", "goblin", "4")
      assert msg2 =~ "no le quedan casillas de hechizo de nivel 4"

      # Sin cast_level sigue funcionando igual (compat hacia atrás).
      assert {:ok, _} = Dragonex.Tools.cast_spell(dm, "dark", "fireball", "goblin", nil)

      # Turno del PC: se conjura a sí misma con cast_level sin problema…
      assert {:ok, _} = Session.end_turn(game, "dm")

      pc = %{deps: %{state: SharedState.new(game, "Lyra"), roller: always(3)}}
      assert {:ok, msg4} = Dragonex.Tools.cast_spell(pc, "Lyra", "magic missile", "goblin", 2)
      assert msg4 =~ "4 dardos de fuerza"

      # …pero NO puede conjurar como otro (guard intacto).
      assert {:error, msg3} = Dragonex.Tools.cast_spell(pc, "dark", "fireball", "Lyra", 4)
      assert msg3 =~ "RECHAZADO"
    end

    test "PCAgent menciona cast_level en la línea de conjurar" do
      alias Dragonex.PCAgent

      lyra = wizard()
      combat = World.new(phase: :combat, characters: %{"Lyra" => lyra, "goblin" => goblin()})
      instr = PCAgent.instruction("Lyra", lyra, combat)

      assert instr =~ "cast_level"
      assert instr =~ "upcasting"
    end
  end
end
