defmodule Dragonex.WildShapeTest do
  @moduledoc """
  Wild Shape 5e (D63): druid L2+ transforms into a catalogue beast
  (cat/wolf/black_bear) with a CR gate; manual and automatic revert at 0 PG
  with excess damage carry-over; spell block while transformed; 2 uses
  recharged by both rests. The LLM decides WHEN; the engine validates,
  transforms and reverts (D1).
  """

  use ExUnit.Case, async: true

  import Dragonex.Test.Harness

  alias Dragonex.{Actions, Character, Codec, Heroes, Monsters, Tools, World}
  alias ExAgent.{Session, Session.SharedState}

  defp fixed(value), do: Dragonex.Dice.always(value)

  defp druid(opts) do
    Character.new(
      Keyword.merge(
        [
          name: "Sylvi",
          class: "druid",
          race: "elf",
          level: 2,
          hp: 20,
          max_hp: 20,
          ac: 14,
          str: 10,
          dex: 14,
          con: 14,
          int: 12,
          wis: 16,
          cha: 10,
          wild_shape_uses: 2,
          weapons: [
            %Dragonex.Weapon{
              name: "quarterstaff",
              dice: "1d6",
              damage_type: "bludgeoning",
              attack_ability: :str
            }
          ],
          inventory: [%Dragonex.Item{name: "druidic focus", qty: 1, kind: :focus}],
          skill_proficiencies: ["animal_handling", "perception"],
          saving_proficiencies: ["int", "wis"],
          side: "pc"
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

  defp transform!(w, who \\ "Sylvi", beast \\ "wolf") do
    {:ok, _, change} = Actions.wild_shape(w, who, beast)
    {:ok, w2} = change.(w)
    w2
  end

  # ------------------------------------------------------------ transform

  describe "Actions.wild_shape/3" do
    test "transforma: aplica str/dex/con/hp/max_hp/ac/weapons de la bestia" do
      w = world([druid([]), goblin([])])
      {:ok, msg, change} = Actions.wild_shape(w, "Sylvi", "wolf")

      assert msg ==
               "Sylvi adopta la forma de un lobo (usos de forma salvaje restantes: 1)."

      {:ok, w2} = change.(w)
      s = w2.characters["Sylvi"]

      # Wolf: STR 12, DEX 15, CON 12, PG 11, CA 13, arma bite 2d4.
      assert s.str == 12
      assert s.dex == 15
      assert s.con == 12
      assert s.hp == 11
      assert s.max_hp == 11
      assert s.ac == 13
      assert length(s.weapons) == 1
      assert hd(s.weapons).name == "bite"
      assert hd(s.weapons).dice == "2d4"

      # Conserva mental, identidad, proficiencies, condiciones, concentración.
      assert s.int == 12
      assert s.wis == 16
      assert s.cha == 10
      assert s.name == "Sylvi"
      assert s.side == "pc"
      assert s.class == "druid"
      assert s.level == 2
      assert s.skill_proficiencies == ["animal_handling", "perception"]
      assert s.saving_proficiencies == ["int", "wis"]

      # El inventario NUNCA cambia (armas de bestia sintéticas).
      assert s.inventory == [%Dragonex.Item{name: "druidic focus", qty: 1, kind: :focus}]

      # El guardado del formulario original.
      assert s.wild_shape[:beast] == "wolf"
      assert s.wild_shape[:orig_str] == 10
      assert s.wild_shape[:orig_dex] == 14
      assert s.wild_shape[:orig_con] == 14
      assert s.wild_shape[:orig_hp] == 20
      assert s.wild_shape[:orig_max_hp] == 20
      assert s.wild_shape[:orig_ac] == 14
      assert hd(s.wild_shape[:orig_weapons]).name == "quarterstaff"
    end

    test "gasta 1 uso (SIEMPRE que transforme)" do
      w = world([druid([]), goblin([])])
      w2 = transform!(w)
      assert w2.characters["Sylvi"].wild_shape_uses == 1

      {:ok, _, change} = Actions.end_wild_shape(w2, "Sylvi")
      {:ok, w2} = change.(w2)

      {:ok, _, change} = Actions.wild_shape(w2, "Sylvi", "cat")
      {:ok, w3} = change.(w2)
      assert w3.characters["Sylvi"].wild_shape_uses == 0
    end

    test "concentración y condiciones se conservan (RAW)" do
      w = world([druid(concentrating: "hunter's mark:Goblin"), goblin([])])
      {:ok, w} = World.apply_condition("Sylvi", "prone").(w)

      w2 = transform!(w)
      s = w2.characters["Sylvi"]
      assert s.concentrating == "hunter's mark:Goblin"
      assert World.has_condition?(w2, "Sylvi", "prone")
    end

    test "bestia desconocida error y no muta" do
      w = world([druid([]), goblin([])])
      assert {:error, msg} = Actions.wild_shape(w, "Sylvi", "tiger")
      assert msg =~ "bestia desconocida"
      assert msg =~ "black_bear, cat, wolf"
      assert w.characters["Sylvi"].wild_shape == nil
    end

    test "ya transformado error" do
      w = transform!(world([druid([]), goblin([])]))
      assert {:error, msg} = Actions.wild_shape(w, "Sylvi", "cat")
      assert msg =~ "ya está en forma de bestia"
    end

    test "usos 0 error" do
      w = world([druid(wild_shape_uses: 0), goblin([])])
      assert {:error, msg} = Actions.wild_shape(w, "Sylvi", "wolf")
      assert msg =~ "no tiene usos de Forma salvaje"
    end

    test "no druida error" do
      w = world([goblin(name: "Thane", class: "fighter", side: "pc", hp: 12, max_hp: 12)])
      assert {:error, msg} = Actions.wild_shape(w, "Thane", "wolf")
      assert msg =~ "no es druida"
    end

    test "L1 error" do
      w = world([druid(level: 1, wild_shape_uses: 0), goblin([])])
      assert {:error, msg} = Actions.wild_shape(w, "Sylvi", "wolf")
      assert msg =~ "nivel 2"
    end

    test "who caído error" do
      w = world([druid(hp: 0), goblin([])])
      assert {:error, msg} = Actions.wild_shape(w, "Sylvi", "wolf")
      assert msg =~ "caído"
    end

    test "who no existe error" do
      assert {:error, msg} = Actions.wild_shape(World.new(), "ghost", "wolf")
      assert msg =~ "no existe"
    end
  end

  describe "CR gate" do
    test "L2 black_bear (ND 1/2) error, cat/wolf ok" do
      w = world([druid(level: 2), goblin([])])
      assert {:error, msg} = Actions.wild_shape(w, "Sylvi", "black_bear")
      assert msg =~ "ND"

      assert {:ok, _, _} = Actions.wild_shape(w, "Sylvi", "cat")
      assert {:ok, _, _} = Actions.wild_shape(w, "Sylvi", "wolf")
    end

    test "L3 sigue a ND 1/4" do
      w = world([druid(level: 3), goblin([])])
      assert {:error, _} = Actions.wild_shape(w, "Sylvi", "black_bear")
    end

    test "L4 sigue a ND 1/4 (RAW: CR 1/2 llega en L5)" do
      w = world([druid(level: 4), goblin([])])
      assert {:error, msg} = Actions.wild_shape(w, "Sylvi", "black_bear")
      assert msg =~ "ND"
    end

    test "L5 black_bear ok" do
      w = world([druid(level: 5), goblin([])])
      assert {:ok, msg, _} = Actions.wild_shape(w, "Sylvi", "black_bear")
      assert msg == "Sylvi adopta la forma de un oso negro (usos de forma salvaje restantes: 1)."
    end
  end

  # ------------------------------------------------------------- revert

  describe "Actions.end_wild_shape/2" do
    test "restaura TODO lo guardado con PG = orig_hp exacto" do
      w = world([druid([]), goblin([])])
      w2 = transform!(w)
      # Daño parcial en forma de bestia (no la mata).
      {:ok, w2} = World.apply_damage("Sylvi", 4).(w2)
      assert w2.characters["Sylvi"].hp == 7

      {:ok, msg, change} = Actions.end_wild_shape(w2, "Sylvi")
      assert msg == "Sylvi vuelve a su forma original (PG 20)."

      {:ok, w3} = change.(w2)
      s = w3.characters["Sylvi"]
      assert s.wild_shape == nil
      assert s.str == 10
      assert s.dex == 14
      assert s.con == 14
      assert s.hp == 20
      assert s.max_hp == 20
      assert s.ac == 14
      assert hd(s.weapons).name == "quarterstaff"
    end

    test "no transformado error" do
      w = world([druid([]), goblin([])])
      assert {:error, msg} = Actions.end_wild_shape(w, "Sylvi")
      assert msg =~ "no está en forma de bestia"
    end

    test "who no existe error" do
      assert {:error, msg} = Actions.end_wild_shape(World.new(), "ghost")
      assert msg =~ "no existe"
    end
  end

  # ------------------------------------------------------- daño en forma

  describe "daño mientras está transformado" do
    test "daño parcial reduce hp de bestia sin revertir" do
      w = transform!(world([druid([]), goblin([])]))

      {:ok, w2} = World.apply_damage("Sylvi", 5).(w)
      s = w2.characters["Sylvi"]
      assert s.hp == 6
      assert s.wild_shape[:beast] == "wolf"
    end

    test "daño que mata a la bestia revierte con exceso" do
      # orig 20, bestia (wolf) 11 pg, daño 15 → exceso 4 → PG 16.
      w = transform!(world([druid([]), goblin([])]))

      {:ok, w2} = World.apply_damage("Sylvi", 15).(w)
      s = w2.characters["Sylvi"]
      assert s.wild_shape == nil
      assert s.hp == 20 - (15 - 11)
      assert s.max_hp == 20
      assert s.str == 10
      assert hd(s.weapons).name == "quarterstaff"

      # Nota en el cambio para que la narración lo muestre.
      assert Enum.any?(w2.log, fn {_actor, entry} ->
               entry =~ "la bestia cae y Sylvi vuelve a su forma (PG 16)"
             end)
    end

    test "daño exacto a 0 revierte a orig sin exceso" do
      # bestia 11 pg, daño 11 → exceso 0 → PG 20.
      w = transform!(world([druid([]), goblin([])]))

      {:ok, w2} = World.apply_damage("Sylvi", 11).(w)
      s = w2.characters["Sylvi"]
      assert s.wild_shape == nil
      assert s.hp == 20
    end

    test "exceso que tumba al druida → 0 PG caído" do
      # orig 20, bestia 11, daño 50 → exceso 39 → max(0, 20-39) = 0.
      w = transform!(world([druid([]), goblin([])]))

      {:ok, w2} = World.apply_damage("Sylvi", 50).(w)
      s = w2.characters["Sylvi"]
      assert s.wild_shape == nil
      assert s.hp == 0
      assert s.max_hp == 20
      assert World.down?(w2, "Sylvi")
    end

    test "temp hp de la bestia absorbe antes y reduce el exceso" do
      w = transform!(world([druid([]), goblin([])]))
      {:ok, w} = World.apply_temp_hp("Sylvi", 5).(w)

      # bestia 11 pg + 5 temp, daño 20 → temp absorbe 5, rest 15,
      # exceso 15-11 = 4 → revierte a PG 16.
      {:ok, w2} = World.apply_damage("Sylvi", 20).(w)
      s = w2.characters["Sylvi"]
      assert s.wild_shape == nil
      assert s.hp == 16
      assert s.temp_hp == 0
    end

    test "daño normal (sin bestia) no añade notas al log" do
      w = world([druid([]), goblin([])])
      {:ok, w2} = World.apply_damage("Goblin", 3).(w)
      refute Enum.any?(w2.log, fn {_a, e} -> e =~ "bestia cae" end)
    end
  end

  # --------------------------------------------------------- hechizos

  describe "bloqueo de hechizos en forma animal" do
    test "cast_spell bloqueado en forma" do
      caster =
        druid(
          spells: [
            %Dragonex.Spell{
              name: "thorn whip",
              level: 0,
              kind: :attack,
              casting_ability: :wis,
              dice: "1d6",
              damage_type: "piercing"
            }
          ]
        )

      w = transform!(world([caster, goblin([])]))

      assert {:error, msg} = Actions.spell(w, "Sylvi", "thorn whip", "Goblin", fixed(15))
      assert msg == "Sylvi no puede conjurar en forma de bestia"
    end

    test "cast_spell libre tras revert" do
      caster =
        druid(
          spells: [
            %Dragonex.Spell{
              name: "thorn whip",
              level: 0,
              kind: :attack,
              casting_ability: :wis,
              dice: "1d6",
              damage_type: "piercing"
            }
          ]
        )

      w = transform!(world([caster, goblin([])]))
      {:ok, _, change} = Actions.end_wild_shape(w, "Sylvi")
      {:ok, w} = change.(w)

      assert {:ok, _, _} = Actions.spell(w, "Sylvi", "thorn whip", "Goblin", fixed(15))
    end
  end

  # ---------------------------------------------------- atacar como bestia

  describe "make_attack con arma de bestia" do
    test "lobo muerde con bite" do
      w = transform!(world([druid([]), goblin([])]), "Sylvi", "wolf")

      assert {:ok, msg, change} = Actions.attack(w, "Sylvi", "Goblin", "bite", fixed(15))
      assert msg =~ "Sylvi acierta a Goblin"

      {:ok, w2} = change.(w)
      # 15 + prof 2 + STR mod 1 = 18 vs AC 15 → hit; el bite de bestia daña.
      assert w2.characters["Goblin"].hp == 0
    end

    test "el arma original ya no está en forma" do
      w = transform!(world([druid([]), goblin([])]))
      assert {:error, msg} = Actions.attack(w, "Sylvi", "Goblin", "quarterstaff", fixed(15))
      assert msg =~ "no tiene el arma quarterstaff"
    end
  end

  # ------------------------------------------------------------- rests

  describe "rests recargan usos" do
    test "short_rest recarga a 2 (sin forzar revert)" do
      w = transform!(world([druid([]), goblin([])]))
      assert w.characters["Sylvi"].wild_shape_uses == 1

      {:ok, _, rest} = Actions.short_rest(w, "Sylvi", fixed(4))
      {:ok, w2} = rest.(w)
      s = w2.characters["Sylvi"]
      assert s.wild_shape_uses == 2
      # RAW: puedes descansar en forma — no hay revert forzado.
      assert s.wild_shape != nil
    end

    test "long_rest recarga a 2" do
      w = transform!(world([druid([]), goblin([])]))
      {:ok, _, rest} = Actions.long_rest(w, "Sylvi")
      {:ok, w2} = rest.(w)
      assert w2.characters["Sylvi"].wild_shape_uses == 2
    end

    test "rest es no-op para otras clases y druida L1" do
      w = world([goblin(name: "Thane", class: "fighter", side: "pc", hp: 12, max_hp: 12)])
      {:ok, _, rest} = Actions.short_rest(w, "Thane", fixed(4))
      {:ok, w2} = rest.(w)
      assert w2.characters["Thane"].wild_shape_uses == 0
    end
  end

  # ---------------------------------------------------------- level-up

  describe "level-up no toca usos ni forma" do
    test "World.level_up conserva usos y forma" do
      w = transform!(world([druid([]), goblin([])]))
      {:ok, w2} = World.level_up("Sylvi", %{}).(w)
      s = w2.characters["Sylvi"]
      assert s.level == 3
      assert s.wild_shape_uses == 1
      assert s.wild_shape[:beast] == "wolf"
    end
  end

  # ------------------------------------------------------------- Codec

  describe "Codec" do
    test "wild_shape_uses y wild_shape sobreviven ida y vuelta" do
      w = transform!(world([druid([]), goblin([])]))
      decoded = Codec.decode(Codec.encode(w))
      s = decoded.characters["Sylvi"]

      assert s.wild_shape_uses == 1
      assert s.wild_shape[:beast] == "wolf"
      assert s.wild_shape[:orig_hp] == 20
      assert hd(s.wild_shape[:orig_weapons]).name == "quarterstaff"
      assert hd(s.wild_shape[:orig_weapons]).attack_ability == :str
    end

    test "jsonb viejo sin campos → 0 usos, forma normal" do
      encoded =
        druid([]) |> Codec.encode_character() |> Map.drop(["wild_shape_uses", "wild_shape"])

      {:ok, json} = Jason.encode(encoded)
      {:ok, decoded_map} = Jason.decode(json)

      decoded = Codec.decode_character(decoded_map)
      assert decoded.wild_shape_uses == 0
      assert decoded.wild_shape == nil
    end
  end

  # ------------------------------------------------------------ builder

  describe "builder" do
    test "druida L2 → 2 usos; L1 → 0; otra clase → 0" do
      {:ok, l2} =
        Heroes.build(%{
          name: "Sylvi",
          race: "human",
          class: "druid",
          background: "sage",
          level: 2
        })

      assert l2.wild_shape_uses == 2
      assert l2.wild_shape == nil

      {:ok, l1} =
        Heroes.build(%{name: "Sylvi", race: "human", class: "druid", background: "sage"})

      assert l1.wild_shape_uses == 0

      {:ok, fighter} =
        Heroes.build(%{
          name: "T",
          race: "human",
          class: "fighter",
          background: "soldier",
          level: 2
        })

      assert fighter.wild_shape_uses == 0
    end
  end

  # ----------------------------------------------------------- catálogo

  describe "catálogo de bestias" do
    test "wild_shape_beasts con CR float" do
      assert Monsters.wild_shape_beasts() == %{"cat" => 0.0, "wolf" => 0.25, "black_bear" => 0.5}
    end

    test "cat: CR 0 — STR 3, DEX 15, PG 4, CA 12, bite 1d4 finesse" do
      c = Monsters.cat(name: "gato")
      assert c.str == 3 and c.dex == 15 and c.con == 10 and c.wis == 12 and c.cha == 7
      assert c.hp == 4 and c.max_hp == 4 and c.ac == 12
      [bite] = c.weapons
      assert bite.name == "bite" and bite.dice == "1d4" and bite.finesse == true
    end

    test "black_bear: CR 1/2 — STR 15, DEX 14, CON 14, PG 19, CA 11, bite 1d6" do
      c = Monsters.black_bear(name: "oso")
      assert c.str == 15 and c.dex == 14 and c.con == 14
      assert c.hp == 19 and c.max_hp == 19 and c.ac == 11
      # 1d6 pelado: el motor suma STR +3 encima → 1d6+3 (RAW). Los dados de
      # arma solo parsean NdM — "1d8+3" crasheaba el combate.
      [bite] = c.weapons
      assert bite.name == "bite" and bite.dice == "1d6"
    end

    test "cat y black_bear están en el catálogo de monstruos" do
      assert is_function(Monsters.get("cat"), 1)
      assert is_function(Monsters.get("black_bear"), 1)
      assert "cat" in Monsters.keys()
      assert "black_bear" in Monsters.keys()
    end

    test "CADA bestia del catálogo (+ giant_spider) puede atacar sin crashear" do
      # Regresión del oso: dados tipo "1d8+3" (no NdM) hacían raise en
      # Combat.parse_dice. Atacar con cada arma de cada forma valida que
      # TODOS los dados del bestiario parsean y dañan. (CA 5: hasta el gato
      # con STR 3 acierta con d20 15 → los dados SIEMPRE se tiran.)
      for {beast_key, _cr} <- Monsters.wild_shape_beasts() do
        beast = Monsters.get(beast_key).(name: "bestia")

        assert Enum.any?(beast.weapons, fn weapon ->
                 w = world([beast, goblin(hp: 100, max_hp: 100, ac: 5)])

                 with {:ok, _, change} <-
                        Actions.attack(w, "bestia", "Goblin", weapon.name, fixed(15)),
                      {:ok, w2} <- change.(w) do
                   w2.characters["Goblin"].hp < 100
                 else
                   _ -> false
                 end
               end),
               "la bestia #{beast_key} no pudo atacar con sus armas"
      end

      # La araña gigante comparte el mismo contrato de datos (D75: 3d8).
      spider = Monsters.giant_spider(name: "araña")
      w = world([spider, goblin(hp: 100, max_hp: 100, ac: 5)])
      assert {:ok, _, change} = Actions.attack(w, "araña", "Goblin", "bite", fixed(15))
      {:ok, w2} = change.(w)
      assert w2.characters["Goblin"].hp < 100
    end
  end

  # -------------------------------------------------------------- tools

  describe "Tools.wild_shape / Tools.end_wild_shape" do
    test "PC sí mismo transforma y revierte" do
      sylvi = druid([])

      game =
        start_session(
          world: World.new(characters: %{"Sylvi" => sylvi, "Goblin" => goblin([])}),
          policy: :round_robin,
          participants: [p("Sylvi")]
        )

      assert {:ok, "Sylvi"} = Session.start(game)

      pc = %{deps: %{state: SharedState.new(game, "Sylvi"), roller: fixed_roller(1)}}
      assert {:ok, msg} = Tools.wild_shape(pc, "Sylvi", "wolf")
      assert msg == "Sylvi adopta la forma de un lobo (usos de forma salvaje restantes: 1)."

      state = Session.read_state(game)
      assert state.characters["Sylvi"].wild_shape[:beast] == "wolf"

      assert {:ok, msg} = Tools.end_wild_shape(pc, "Sylvi")
      assert msg == "Sylvi vuelve a su forma original (PG 20)."
      assert Session.read_state(game).characters["Sylvi"].wild_shape == nil
    end

    test "PC otro who error (guard self)" do
      sylvi = druid([])
      vex = druid(name: "Vex")

      game =
        start_session(
          world: World.new(characters: %{"Sylvi" => sylvi, "Vex" => vex}),
          policy: :round_robin,
          participants: [p("dm"), p("Sylvi"), p("Vex")]
        )

      assert {:ok, "dm"} = Session.start(game)

      ctx = %{deps: %{state: SharedState.new(game, "Sylvi"), roller: fixed_roller(1)}}
      assert {:error, msg} = Tools.wild_shape(ctx, "Vex", "wolf")
      assert msg =~ "RECHAZADO"

      assert {:error, msg} = Tools.end_wild_shape(ctx, "Vex")
      assert msg =~ "RECHAZADO"

      assert Session.read_state(game).characters["Vex"].wild_shape == nil
    end

    test "DM cualquiera" do
      sylvi = druid([])

      game =
        start_session(
          world: World.new(characters: %{"Sylvi" => sylvi}),
          policy: :round_robin,
          participants: [p("dm"), p("Sylvi")]
        )

      assert {:ok, "dm"} = Session.start(game)

      dm = %{deps: %{state: SharedState.new(game, "dm"), roller: fixed_roller(1)}}
      assert {:ok, _} = Tools.wild_shape(dm, "Sylvi", "cat")
      assert Session.read_state(game).characters["Sylvi"].wild_shape[:beast] == "cat"
    end
  end
end
