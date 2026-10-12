defmodule Dragonex.GuidingBoltTest do
  @moduledoc """
  Guiding Bolt ejecutable (ADR D95): 4d6 radiante al impactar y el objetivo
  queda GUIADO — la próxima tirada de ataque contra él gana ventaja y
  consume la marca (hit o miss, cualquier atacante). Caduca al iniciar el
  lanzador su siguiente turno (derivado de turn_state) y en end_combat;
  la ventaja combina/cancela vía combine (patrón D57).

  Rollers fijos → oráculos con conteo exacto de dados consumidos. Como en
  partida real, el turno del lanzador queda registrado (set_current_combatant)
  antes de conjurar, y los cambios se aplican entre acciones.
  """

  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Character, Codec, Rules.Guided, Spell, World, Weapon}

  defp seq(values) do
    Process.put(:seq, values)

    fn _sides ->
      [h | rest] = Process.get(:seq)
      Process.put(:seq, rest)
      h
    end
  end

  defp spent?, do: Process.get(:seq, [])

  defp sheet_spell(name, level, kind, dice, opts) do
    %Spell{
      name: name,
      level: level,
      kind: kind,
      casting_ability: Keyword.get(opts, :casting_ability, :wis),
      dice: dice,
      damage_type: Keyword.get(opts, :damage_type),
      save_ability: Keyword.get(opts, :save_ability)
    }
  end

  defp cleric(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Cora",
          class: "cleric",
          level: 3,
          hp: 24,
          max_hp: 24,
          ac: 16,
          str: 12,
          dex: 10,
          con: 14,
          int: 10,
          wis: 16,
          cha: 12,
          side: "pc",
          spells: [sheet_spell("guiding bolt", 1, :attack, "4d6", damage_type: "radiant")]
        ],
        opts
      )
    )
  end

  defp sorcerer(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Sylas",
          class: "sorcerer",
          level: 5,
          hp: 28,
          max_hp: 28,
          ac: 12,
          str: 8,
          dex: 14,
          con: 13,
          int: 10,
          wis: 12,
          cha: 16,
          side: "pc",
          sorcery_points: 5,
          spells: [
            sheet_spell("guiding bolt", 1, :attack, "4d6",
              casting_ability: :cha,
              damage_type: "radiant"
            )
          ]
        ],
        opts
      )
    )
  end

  defp fighter(opts \\ []) do
    Character.new(
      Keyword.merge(
        [
          name: "Thane",
          class: "fighter",
          level: 1,
          hp: 20,
          max_hp: 20,
          ac: 16,
          str: 16,
          dex: 12,
          con: 14,
          int: 10,
          wis: 10,
          cha: 10,
          side: "pc",
          weapons: [
            %Weapon{name: "longsword", dice: "1d8", damage_type: "slashing", attack_ability: :str}
          ]
        ],
        opts
      )
    )
  end

  defp wizard_thane(opts \\ []) do
    fighter(
      Keyword.merge(
        [
          class: "wizard",
          str: 8,
          int: 16,
          weapons: [],
          spells: [
            sheet_spell("fire bolt", 0, :attack, "1d10",
              casting_ability: :int,
              damage_type: "fire"
            )
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

  defp kobold(opts \\ []) do
    Character.new(
      Keyword.merge(
        [name: "kobold", class: "monster", hp: 20, max_hp: 20, ac: 12, side: "enemy", dex: 10],
        opts
      )
    )
  end

  defp world(chars) do
    chars
    |> Enum.reduce(World.new(phase: :combat), fn c, w ->
      {:ok, w} = World.add_character(c).(w)
      w
    end)
    |> World.init_spell_slots()
  end

  defp turn!(w, name) do
    {:ok, w} = World.set_current_combatant(name).(w)
    w
  end

  defp cast!(w, caster, target, roller) do
    assert {:ok, _msg, change} = Actions.spell(w, caster, "guiding bolt", target, roller, nil)
    elem(change.(w), 1)
  end

  defp attack!(w, attacker, target, roller, mode \\ :normal) do
    # Como en partida: el atacante tiene el turno antes de actuar.
    w = turn!(w, attacker)
    assert {:ok, _msg, change} = Actions.attack(w, attacker, target, "longsword", roller, mode)
    elem(change.(w), 1)
  end

  defp guided_entry(w, name),
    do: Enum.find(w.characters[name].conditions, &match?(%{"condition" => "guided"}, &1))

  # Cora L3: SAB 16 (+3), prof 2 → ataque +5. Goblin CA 12.
  # Thane L1: FUE 16 (+3), prof 2 → ataque +5; longsword 1d8+3.

  describe "Rules.Guided (unidad)" do
    test "combine: la ventaja guiada combina y cancela vía D57" do
      assert Guided.combine(:normal, true) == :advantage
      assert Guided.combine(:disadvantage, true) == :normal
      assert Guided.combine(:advantage, true) == :advantage
      assert Guided.combine(:normal, false) == :normal
      assert Guided.combine(:disadvantage, false) == :disadvantage
      assert Guided.combine(:advantage, false) == :advantage
    end

    test "active?: en combate hasta el siguiente turno del LANZADOR" do
      w = world([cleric(), fighter(), goblin()])
      w = turn!(w, "Cora")
      w = elem(World.mark_guided("goblin", "Cora").(w), 1)
      assert Guided.active?(w, w.characters["goblin"])

      # Fuera de combate (end_combat u exploración) nunca activa.
      refute Guided.active?(%{w | phase: :exploration}, w.characters["goblin"])

      # Ronda 2: el turno de Thane NO caduca la marca de Cora.
      {:ok, w} = World.next_round().(w)
      w = turn!(w, "Thane")
      assert Guided.active?(w, w.characters["goblin"])

      # El siguiente turno de Cora (ronda 2) sí la caduca.
      w = turn!(w, "Cora")
      refute Guided.active?(w, w.characters["goblin"])
    end
  end

  describe "marca on-hit" do
    test "impactar marca al objetivo con fuente y ronda; fallar no marca" do
      w = world([cleric(), goblin()])
      w = turn!(w, "Cora")

      # d20 15 → 20 vs CA 12: impacto; 4d6 = 6+6+6+6 = 24.
      w2 = cast!(w, "Cora", "goblin", seq([15, 6, 6, 6, 6]))
      assert spent?() == []

      entry = guided_entry(w2, "goblin")
      assert entry["source"] == "Cora"
      assert entry["round"] == w2.round

      # Fallo (d20 2 → 7 vs CA 12): sin marca.
      w3 = cast!(w, "Cora", "goblin", seq([2]))
      assert guided_entry(w3, "goblin") == nil
      assert spent?() == []
    end

    test "una reaplicación que impacta deja una sola entrada fresca" do
      w = world([cleric(), goblin()])
      w = turn!(w, "Cora")

      w = cast!(w, "Cora", "goblin", seq([15, 6, 6, 6, 6]))

      # Ronda 2, turno nuevo de Cora (la acción por turno es una): la marca
      # vieja ya no está activa; el nuevo impacto la sustituye.
      {:ok, w} = World.next_round().(w)
      w = turn!(w, "Cora")
      w2 = cast!(w, "Cora", "goblin", seq([15, 6, 6, 6, 6]))

      entries =
        Enum.filter(w2.characters["goblin"].conditions, &match?(%{"condition" => "guided"}, &1))

      assert length(entries) == 1
      assert hd(entries)["round"] == w2.round
      assert Guided.active?(w2, w2.characters["goblin"])
    end
  end

  describe "consumo en la primera tirada posterior" do
    test "arma: ventaja en la tirada y marca consumida acierte o falle" do
      w = world([cleric(), fighter(), goblin()])
      w = turn!(w, "Cora")
      w = cast!(w, "Cora", "goblin", seq([15, 6, 6, 6, 6]))

      # Ventaja: 2 dados d20 (3, 18) → guarda 18 → 23 vs CA 12: impacto;
      # daño 1d8 (5) + 3 = 8. La acción consume la marca.
      w = turn!(w, "Thane")

      assert {:ok, msg, change} =
               Actions.attack(w, "Thane", "goblin", "longsword", seq([3, 18, 5]))

      assert msg =~ "(ventaja)"
      assert spent?() == []
      w2 = elem(change.(w), 1)
      assert guided_entry(w2, "goblin") == nil

      # Ronda 2: Cora re-marca y Thane FALLA — el fallo también consume.
      {:ok, w2} = World.next_round().(w2)
      w2 = turn!(w2, "Cora")
      w2 = cast!(w2, "Cora", "goblin", seq([15, 6, 6, 6, 6]))
      w2 = turn!(w2, "Thane")

      assert {:ok, msg2, change2} =
               Actions.attack(w2, "Thane", "goblin", "longsword", seq([3, 4]))

      assert msg2 =~ "(ventaja)"
      w3 = elem(change2.(w2), 1)
      assert guided_entry(w3, "goblin") == nil
      assert spent?() == []
    end

    test "la segunda tirada ya NO lleva ventaja (un solo d20)" do
      w = world([cleric(), fighter(), goblin()])
      w = turn!(w, "Cora")
      w = cast!(w, "Cora", "goblin", seq([15, 6, 6, 6, 6]))

      # Primera (r1, turno de Thane): ventaja — 2 d20 + daño; consume.
      w2 = attack!(w, "Thane", "goblin", seq([3, 18, 5]))

      # Segunda (r2, turno nuevo de Thane): la marca ya no existe —
      # un solo d20 y sin etiqueta.
      {:ok, w2} = World.next_round().(w2)
      w2 = turn!(w2, "Thane")

      assert {:ok, msg, _} = Actions.attack(w2, "Thane", "goblin", "longsword", seq([18, 5]))
      refute msg =~ "(ventaja)"
      assert spent?() == []
    end

    test "ataque con hechizo también ventajea y consume" do
      w = world([cleric(), wizard_thane(), goblin()])
      w = turn!(w, "Cora")
      w = cast!(w, "Cora", "goblin", seq([15, 6, 6, 6, 6]))

      # fire bolt con ventaja: 2 d20 (3, 15) → 15+5=20 vs CA 12: impacto; 1d10.
      w = turn!(w, "Thane")

      assert {:ok, msg, change} =
               Actions.spell(w, "Thane", "fire bolt", "goblin", seq([3, 15, 10]), nil)

      assert msg =~ "(ventaja)"
      assert msg =~ "10 de daño de fuego"
      assert spent?() == []

      w2 = elem(change.(w), 1)
      assert guided_entry(w2, "goblin") == nil
    end

    test "cancelación D57: desventaja pedida + guiado = tirada normal (1 d20)" do
      w = world([cleric(), fighter(), goblin()])
      w = turn!(w, "Cora")
      w = cast!(w, "Cora", "goblin", seq([15, 6, 6, 6, 6]))

      w = turn!(w, "Thane")

      assert {:ok, msg, change} =
               Actions.attack(w, "Thane", "goblin", "longsword", seq([18, 5]), :disadvantage)

      # Sin etiqueta de ventaja/desventaja: modo normal combinado (1 d20).
      refute msg =~ "(ventaja)"
      assert spent?() == []
      w2 = elem(change.(w), 1)
      assert guided_entry(w2, "goblin") == nil
    end
  end

  describe "caducidad" do
    test "expira al iniciar el lanzador su siguiente turno (no el de otro)" do
      w = world([cleric(), fighter(), goblin()])
      w = turn!(w, "Cora")
      w = cast!(w, "Cora", "goblin", seq([15, 6, 6, 6, 6]))

      # Ronda 2: turno de Thane — la marca sigue viva.
      {:ok, w} = World.next_round().(w)
      w = turn!(w, "Thane")
      assert Guided.active?(w, w.characters["goblin"])

      # Turno de Cora en ronda 2: caduca. En ronda 3 Thane ataca de nuevo:
      # la marca (ronda 1) ya no ventajea y consume un solo d20.
      w = turn!(w, "Cora")
      refute Guided.active?(w, w.characters["goblin"])
      {:ok, w} = World.next_round().(w)
      w = turn!(w, "Thane")

      assert {:ok, msg, _} = Actions.attack(w, "Thane", "goblin", "longsword", seq([18, 5]))
      refute msg =~ "(ventaja)"
      assert spent?() == []
    end

    test "end_combat desactiva la marca" do
      w = world([cleric(), fighter(), goblin()])
      w = turn!(w, "Cora")
      w = cast!(w, "Cora", "goblin", seq([15, 6, 6, 6, 6]))

      {:ok, w} = World.end_combat().(w)
      refute Guided.active?(w, w.characters["goblin"])

      assert {:ok, msg, _} = Actions.attack(w, "Thane", "goblin", "longsword", seq([18, 5]))
      refute msg =~ "(ventaja)"
      assert spent?() == []
    end

    test "end_combat BORRA la marca: no revive en un combate nuevo (guided zombie)" do
      w = world([cleric(), fighter(), goblin()])
      w = turn!(w, "Cora")
      w = cast!(w, "Cora", "goblin", seq([15, 6, 6, 6, 6]))

      # El combate acaba en la MISMA ronda del impacto.
      {:ok, w} = World.end_combat().(w)
      # La entrada guided ya no existe físicamente.
      assert guided_entry(w, "goblin") == nil

      # Nuevo combate en la misma ronda: el primer turno de Cora reescribe
      # turn_state[Cora] a ESA ronda — sin el barrido, ts == round habría
      # revivido la marca (hallazgo de revisión cruzada D96).
      w = %{w | phase: :combat}
      w = turn!(w, "Cora")
      w = turn!(w, "Thane")

      assert {:ok, msg, _} = Actions.attack(w, "Thane", "goblin", "longsword", seq([18, 5]))
      refute msg =~ "(ventaja)"
      assert spent?() == []
    end
  end

  describe "Twinned (D65) y persistencia" do
    test "twinned marca dos objetivos independientes y se consumen por separado" do
      w = world([sorcerer(), fighter(), goblin(), kobold()])
      w = turn!(w, "Sylas")
      {:ok, w} = World.set_metamagic("Sylas", %{option: "twinned", target: "kobold"}).(w)

      # Dos resoluciones: d20 15 (impacto) + 4d6 cada una.
      w2 = cast!(w, "Sylas", "goblin", seq([15, 6, 6, 6, 6, 15, 6, 6, 6, 6]))

      assert guided_entry(w2, "goblin")["source"] == "Sylas"
      assert guided_entry(w2, "kobold")["source"] == "Sylas"

      # Se consume la del goblin; el kobold conserva su marca.
      w3 = attack!(w2, "Thane", "goblin", seq([3, 18, 5]))
      assert guided_entry(w3, "goblin") == nil
      assert guided_entry(w3, "kobold") != nil
    end

    test "Codec ida/vuelta conserva la marca (jsonb viejo la ignora)" do
      w = world([cleric(), goblin()])
      w = turn!(w, "Cora")
      w = cast!(w, "Cora", "goblin", seq([15, 6, 6, 6, 6]))

      again = Codec.decode(Codec.encode(w))
      entry = guided_entry(again, "goblin")
      assert entry["source"] == "Cora"
      assert entry["round"] == w.round
      assert Guided.active?(again, again.characters["goblin"])

      # Un mundo codificado SIN marca (jsonb viejo) decodifica sin romper.
      plain = Codec.decode(Codec.encode(world([cleric(), goblin()])))
      assert guided_entry(plain, "goblin") == nil
    end

    test "errores no mutan: objetivo inexistente" do
      w = world([cleric(), goblin()])

      assert {:error, _} = Actions.spell(w, "Cora", "guiding bolt", "orco", seq([]), nil)
      assert guided_entry(w, "goblin") == nil
    end
  end
end
