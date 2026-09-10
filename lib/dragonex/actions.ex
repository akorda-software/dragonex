defmodule Dragonex.Actions do
  @moduledoc """
  Pure orchestration that turns an actor's *intent* into a narrated outcome plus
  a world change — the bridge between `Dragonex.Rules` (the math) and
  `Dragonex.World` (the state).

  Every function returns `{:ok, message, change_fn} | {:error, reason}`, where:

    * `message`    — a factual string the tool hands back to the LLM (the LLM
                     never computes the math; it only reads results);
    * `change_fn`  — a `(world -> {:ok, world} | {:error, reason})` ready for
                     `SharedState.propose_change/2`.

  No exAgent here: deterministic and unit-testable with a fixed roller.
  """

  alias Dragonex.{Character, Dice, RollLog, Rules.Ability, Rules.Combat, Rules.Conditions, World}
  alias Dragonex.Heroes.Progression

  @type roller :: (pos_integer() -> pos_integer())
  @type result ::
          {:ok, String.t(), (World.t() -> {:ok, World.t()} | {:error, term()})}
          | {:error, String.t()}

  @doc "Roll one or more dice and report the total (no world side-effect)."
  @spec roll(
          pos_integer(),
          pos_integer(),
          :normal | :advantage | :disadvantage,
          roller(),
          RollLog.t() | nil
        ) ::
          {:ok, String.t()}
  def roll(count, sides, mode \\ :normal, roller, roll_log \\ nil) do
    {r, close} = RollLog.open(roll_log, roller, nil, :roll, "tirada de #{count}d#{sides}")

    result =
      case mode do
        :normal ->
          {:ok, "tirada #{count}d#{sides} = #{sum(count, sides, r)}"}

        mode when mode in [:advantage, :disadvantage] ->
          kept =
            for _ <- 1..max(count, 1) do
              {k, _, _} = Dice.roll_advantage(sides, mode, r)
              k
            end

          {:ok, "tirada #{count}d#{sides} (#{mode}) = #{Enum.sum(kept)}"}
      end

    RollLog.close(close, total: nil, against: nil, outcome: nil)
    result
  end

  @doc """
  Resolve a weapon Attack action: N attack rolls (with crit/fumble) against
  the same target, then damage on each hit. N comes from
  `Progression.attack_count/2` (Extra Attack 5e, D35). If the target drops
  (hp ≤ 0) mid-action, remaining swings are skipped (no retarget). The
  attacker and target must already be in the world, and the attacker must
  wield the named weapon.
  """
  @spec attack(
          World.t(),
          String.t(),
          String.t(),
          String.t(),
          roller(),
          :normal | :advantage | :disadvantage,
          RollLog.t() | nil
        ) :: result()
  def attack(world, attacker, target, weapon_name, roller, mode \\ :normal, roll_log \\ nil) do
    cond do
      is_nil(World.character(world, attacker)) ->
        {:error, "no existe el atacante: #{attacker}"}

      is_nil(World.character(world, target)) ->
        {:error, "no existe el objetivo: #{target}"}

      # A downed actor (hp <= 0) cannot take actions — the engine enforces RAW
      # rather than trusting the model not to attack from 0 pg.
      World.character(world, attacker).hp <= 0 ->
        {:error, "#{attacker} está caído (0 pg) y no puede atacar"}

      true ->
        a = World.character(world, attacker)
        t = World.character(world, target)

        case find_weapon(a, weapon_name) do
          nil ->
            {:error, "#{attacker} no tiene el arma #{weapon_name}"}

          weapon ->
            effective_mode =
              Conditions.attack_mode(a, t, requested: mode, ranged: weapon.ranged == true)

            n = Progression.attack_count(a.class, a.level)

            swings =
              resolve_swings(a, t, attacker, target, weapon, roller, roll_log, effective_mode, n)

            {:ok, format_attack_message(attacker, target, weapon, t.ac, effective_mode, swings),
             apply_swing_damages(target, swings)}
        end
    end
  end

  @doc """
  Resolve a spell against a single target by its `kind`:

    * `:automatic` — always hits (e.g. magic missile); full dice damage.
    * `:attack`    — spell attack vs AC (nat 20 auto-hits, nat 1 auto-misses).
    * `:save`      — target saves vs DC; success halves the damage (5e default).
  """
  @spec spell(World.t(), String.t(), String.t(), String.t(), roller(), RollLog.t() | nil) ::
          result()
  def spell(world, caster_name, spell_name, target_name, roller, roll_log \\ nil) do
    cond do
      is_nil(World.character(world, caster_name)) ->
        {:error, "no existe el conjurador: #{caster_name}"}

      is_nil(World.character(world, target_name)) ->
        {:error, "no existe el objetivo: #{target_name}"}

      # A downed caster cannot cast — the engine enforces RAW.
      World.character(world, caster_name).hp <= 0 ->
        {:error, "#{caster_name} está caído (0 pg) y no puede conjurar"}

      true ->
        c = World.character(world, caster_name)
        t = World.character(world, target_name)

        case find_spell(c, spell_name) do
          nil ->
            {:error, "#{caster_name} no conoce #{spell_name}"}

          spell ->
            # Check spell slot for leveled spells (cantrips are free)
            if spell.level > 0 and not World.has_slot?(world, caster_name, spell.level) do
              {:error,
               "a #{caster_name} no le quedan casillas de hechizo de nivel #{spell.level} " <>
                 "(debe descansar para recuperarlas). Los trucos siempre están disponibles."}
            else
              result = resolve_spell(c, caster_name, t, target_name, spell, roller, roll_log)
              compose_slot_consumption(result, caster_name, spell.level)
            end
        end
    end
  end

  # Wrap a spell result's change_fn to also consume a spell slot.
  # Cantrips (level 0) pass through unchanged.
  defp compose_slot_consumption({:ok, msg, change}, caster, spell_level) when spell_level > 0 do
    combined = fn w ->
      case change.(w) do
        {:ok, w2} -> World.consume_slot(caster, spell_level).(w2)
        error -> error
      end
    end

    {:ok, msg, combined}
  end

  defp compose_slot_consumption(result, _, _), do: result

  @doc """
  Roll initiative for every conscious combatant (hp > 0), highest total first,
  and produce a `begin_combat` change. Ties break by name for determinism (5e
  would use dexterity then a roll-off — a refinement for later).
  """
  @spec initiative(World.t(), roller(), RollLog.t() | nil) :: result()
  def initiative(world, roller, roll_log \\ nil) do
    ordered =
      world.characters
      |> Enum.filter(fn {_, %Character{hp: hp}} -> hp > 0 end)
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, c} ->
        {r, close} = RollLog.open(roll_log, roller, name, :initiative, "tirada de iniciativa")
        rolled = Combat.roll_initiative(c, r)
        {_d20, total} = rolled
        RollLog.close(close, total: total, against: nil, outcome: nil)
        {name, rolled}
      end)
      |> Enum.sort_by(fn {name, {_d20, total}} -> {-total, name} end)

    summary =
      Enum.map_join(ordered, ", ", fn {name, {d20, total}} -> "#{name} #{d20}→#{total}" end)

    names = Enum.map(ordered, &elem(&1, 0))

    {:ok, "Iniciativa — #{summary}.", World.begin_combat(names)}
  end

  @doc "Make a death saving throw for a down character and apply the result."
  @spec death_save(World.t(), String.t(), roller(), RollLog.t() | nil) :: result()
  def death_save(world, name, roller, roll_log \\ nil) do
    case World.character(world, name) do
      nil ->
        {:error, "no existe el personaje: #{name}"}

      %Character{hp: hp} when hp > 0 ->
        {:error, "#{name} no está caído (pg #{hp})"}

      %Character{death_saves: %{fails: fails}} when fails >= 3 ->
        {:error,
         "#{name} ya está muerto (3 fallos de salvación de muerte) — no puede tirar más salvaciones"}

      %Character{death_saves: %{successes: successes}} when successes >= 3 ->
        {:error,
         "#{name} ya está estable (3 salvaciones de muerte) — no necesita tirar más salvaciones"}

      %Character{} ->
        {r, close} = RollLog.open(roll_log, roller, name, :death_save, "salvación de muerte")
        result = Combat.death_save(r)
        RollLog.close(close, total: elem(result, 1), against: {:dc, 10}, outcome: elem(result, 0))
        {:ok, describe_death_save(name, result), World.apply_death_save(name, result)}
    end
  end

  @doc """
  Heal a character by a dice expression (e.g. "1d8+3"), capped at max_hp.
  Healing also clears the death-save tracker (reviving a downed character).
  """
  @spec heal(World.t(), String.t(), String.t(), roller(), RollLog.t() | nil) :: result()
  def heal(world, target, dice_expr, roller, roll_log \\ nil) do
    case World.character(world, target) do
      nil ->
        {:error, "no existe el personaje: #{target}"}

      %Character{hp: hp, max_hp: max_hp} ->
        {r, close} = RollLog.open(roll_log, roller, target, :heal, "curación (#{dice_expr})")
        rolled = Dice.roll_expr(dice_expr, r)
        RollLog.close(close, total: rolled, against: nil, outcome: nil)
        applied = min(rolled, max_hp - hp)

        {:ok, "#{target} se cura #{applied} pg (#{hp} → #{hp + applied}).",
         World.heal(target, rolled)}
    end
  end

  @doc """
  A short rest: the character spends hit dice to recover HP.

  At level 1, a character has 1 hit die. The heal is `roll(hit_die) + con_mod`.
  """
  @spec short_rest(World.t(), String.t(), roller(), RollLog.t() | nil) :: result()
  def short_rest(world, name, roller, roll_log \\ nil) do
    case World.character(world, name) do
      nil ->
        {:error, "no existe el personaje: #{name}"}

      %Character{} when world.phase == :combat ->
        {:error, "no se puede descansar en combate"}

      %Character{hp: hp, max_hp: max_hp} = c ->
        if hp <= 0 do
          {:error, "#{name} está caído y no puede descansar"}
        else
          hit_die = World.hit_die_size(c.class)
          con_mod = Character.modifier(c, :con)

          {r, close} =
            RollLog.open(roll_log, roller, name, :heal, "descanso corto (1d#{hit_die})")

          rolled = r.(hit_die) + con_mod
          RollLog.close(close, total: rolled, against: nil, outcome: nil)
          applied = min(rolled, max_hp - hp)

          {:ok,
           "#{name} hace un descanso corto y recupera #{applied} pg (1d#{hit_die}#{signed(con_mod)} = #{rolled}, ahora #{hp + applied}/#{max_hp}).",
           World.heal(name, applied)}
        end
    end
  end

  @doc """
  A long rest: full HP restore (and clears short-term conditions).

  In 5e RAW, a long rest restores all hit points and hit dice (up to half the
  total). At level 1 this means full heal + 1 hit die back.
  """
  @spec long_rest(World.t(), String.t()) :: result()
  def long_rest(world, name) do
    case World.character(world, name) do
      nil ->
        {:error, "no existe el personaje: #{name}"}

      %Character{} when world.phase == :combat ->
        {:error, "no se puede descansar en combate"}

      %Character{hp: hp, max_hp: max_hp} ->
        if hp <= 0 do
          {:error, "#{name} está caído y no puede descansar"}
        else
          healed = max_hp - hp

          change = fn w ->
            {:ok, w2} = World.heal(name, healed).(w)
            {:ok, w3} = World.restore_slots(name).(w2)
            {:ok, w3}
          end

          {:ok,
           "#{name} hace un descanso largo y recupera #{healed} pg (#{hp} → #{max_hp}, recuperación completa). Casillas de hechizo recuperadas.",
           change}
        end
    end
  end

  @doc """
  Resolve an ability check (non-combat): the DM sets the `dc`, the engine rolls
  `d20 + ability modifier` and reports success/failure. No world side-effect —
  the DM narrates the consequences and may then call other tools.
  """
  @spec check(
          World.t(),
          String.t(),
          atom(),
          integer(),
          boolean(),
          roller(),
          :normal | :advantage | :disadvantage,
          RollLog.t() | nil
        ) :: result()
  def check(world, who, ability, dc, proficient, roller, mode \\ :normal, roll_log \\ nil) do
    case World.character(world, who) do
      nil ->
        {:error, "no existe el personaje: #{who}"}

      # A downed character cannot make ability checks (death saves use their
      # own path); enforce RAW rather than trusting the model.
      %Character{hp: hp} when hp <= 0 ->
        {:error, "#{who} está caído (0 pg) y no puede hacer chequeos"}

      %Character{} = c ->
        effective_mode = Conditions.check_mode(c, ability, mode)

        {r, close} =
          RollLog.open(roll_log, roller, who, :check, "chequeo de #{ability_es(ability)}")

        {d20, total, success?} =
          Combat.ability_check(c, ability, dc, r, proficient, effective_mode)

        RollLog.close(close,
          total: total,
          against: {:dc, dc},
          outcome: if(success?, do: :success, else: :failure)
        )

        mod = Character.modifier(c, ability)
        prof = if proficient, do: Ability.proficiency(c.level), else: 0
        verdict = if success?, do: "éxito", else: "fallo"

        parts =
          ["d20 #{d20}"]
          |> then(fn p -> if mod != 0, do: p ++ ["#{signed(mod)} (#{ability})"], else: p end)
          |> then(fn p -> if prof != 0, do: p ++ ["#{prof} (competencia)"], else: p end)

        {:ok,
         "#{who} hace un chequeo de #{ability_es(ability)}#{mode_tag(effective_mode)}: #{Enum.join(parts, " + ")} = #{total} vs CD #{dc} — #{verdict}.",
         noop()}
    end
  end

  # ------------------------------------------------------------- spell helpers

  defp resolve_spell(c, caster_name, t, target_name, spell, roller, roll_log) do
    case spell.kind do
      :automatic ->
        {r, close} = RollLog.open(roll_log, roller, caster_name, :spell, "conjura #{spell.name}")

        amount =
          case spell do
            %{dice: nil} -> 0
            %{dice: expr} -> Dice.roll_expr(expr, r)
          end

        cond do
          # Healing spell: no damage_type but has dice → heal the target
          spell.damage_type == nil and amount > 0 ->
            cast_mod = Character.modifier(c, spell.casting_ability)
            total_heal = amount + cast_mod

            RollLog.close(close,
              kind: :heal,
              reason: "curación de #{spell.name}",
              total: total_heal,
              outcome: nil
            )

            {:ok,
             "#{caster_name} conjura #{spell.name}; #{target_name} se cura #{total_heal} pg (#{amount} + #{cast_mod}).",
             World.heal(target_name, total_heal)}

          # Damage spell (magic missile, etc.)
          amount > 0 ->
            verb = spell_damage_verb(spell, amount)

            RollLog.close(close,
              kind: :damage,
              reason: "daño de #{spell.name} (#{spell.damage_type})",
              total: amount,
              outcome: nil
            )

            {:ok,
             "#{caster_name} conjura #{spell.name}; #{target_name} recibe #{amount} de daño #{spell.damage_type}#{verb}.",
             World.apply_damage(target_name, amount)}

          # Utility spell (shield, bless, etc.): no dice → just report
          true ->
            RollLog.close(close, total: 0, outcome: nil)

            {:ok,
             "#{caster_name} conjura #{spell.name} sobre #{target_name}. #{spell.effect || ""}",
             noop()}
        end

      :attack ->
        bonus = Combat.spell_attack_bonus(c, spell)
        effective_mode = Conditions.attack_mode(c, t, requested: :normal, ranged: true)

        {r, close_atk} =
          RollLog.open(roll_log, roller, caster_name, :attack, "ataque con #{spell.name}")

        d20 = kept_d20(r, effective_mode)
        total = d20 + bonus
        hit? = d20 == 20 or (d20 != 1 and total >= t.ac)

        RollLog.close(close_atk,
          total: total,
          against: {:ac, t.ac},
          outcome: if(d20 == 20, do: :crit, else: if(hit?, do: :hit, else: :miss))
        )

        if hit? do
          {r2, close_dmg} =
            RollLog.open(
              roll_log,
              roller,
              caster_name,
              :damage,
              "daño de #{spell.name} (#{spell.damage_type})"
            )

          dmg =
            if d20 == 20 do
              dice_with(spell, r2) + dice_with(spell, r2)
            else
              dice_with(spell, r2)
            end

          RollLog.close(close_dmg, total: dmg, against: nil, outcome: nil)

          {:ok,
           "#{caster_name} conjura #{spell.name}; impacta a #{target_name} (d20 #{d20}: #{total} vs CA #{t.ac}) por #{dmg} de daño #{spell.damage_type}#{mode_tag(effective_mode)}.",
           World.apply_damage(target_name, dmg)}
        else
          {:ok,
           "#{caster_name} conjura #{spell.name}; falla contra #{target_name} (d20 #{d20}: #{total} vs CA #{t.ac})#{mode_tag(effective_mode)}.",
           noop()}
        end

      :save ->
        resolve_save_spell(c, caster_name, t, target_name, spell, roller, roll_log)
    end
  end

  defp resolve_save_spell(c, caster_name, t, target_name, spell, roller, roll_log) do
    dc = Combat.spell_save_dc(c, spell)

    case Conditions.save_mode(t, spell.save_ability) do
      :auto_fail ->
        {r2, close_dmg} =
          RollLog.open(
            roll_log,
            roller,
            caster_name,
            :damage,
            "daño de #{spell.name} (#{spell.damage_type})"
          )

        full = dice_with(spell, r2)
        RollLog.close(close_dmg, total: full, against: nil, outcome: nil)

        {:ok,
         "#{caster_name} conjura #{spell.name}; #{target_name} falla automáticamente la salvación de #{ability_es(spell.save_ability)} vs CD #{dc} — #{full} de daño #{spell.damage_type}.",
         World.apply_damage(target_name, full)}

      {:roll, save_mode} ->
        {r, close_save} =
          RollLog.open(
            roll_log,
            roller,
            target_name,
            :save,
            "salvación de #{ability_es(spell.save_ability)} contra #{spell.name}"
          )

        {d20, stotal, success?} = Combat.saving_throw(t, spell.save_ability, dc, r, save_mode)

        RollLog.close(close_save,
          total: stotal,
          against: {:dc, dc},
          outcome: if(success?, do: :success, else: :failure)
        )

        {r2, close_dmg} =
          RollLog.open(
            roll_log,
            roller,
            caster_name,
            :damage,
            "daño de #{spell.name} (#{spell.damage_type})"
          )

        full = dice_with(spell, r2)
        RollLog.close(close_dmg, total: full, against: nil, outcome: nil)

        dmg = if success?, do: div(full, 2), else: full

        verdict =
          if success?,
            do:
              "supera la salvación (d20 #{d20}: #{stotal} vs CD #{dc})#{mode_tag(save_mode)}, mitad de daño",
            else: "falla la salvación (d20 #{d20}: #{stotal} vs CD #{dc})#{mode_tag(save_mode)}"

        {:ok,
         "#{caster_name} conjura #{spell.name}; #{target_name} #{verdict} — #{dmg} de daño #{spell.damage_type}.",
         World.apply_damage(target_name, dmg)}
    end
  end

  defp kept_d20(roller, mode) when mode in [:advantage, :disadvantage] do
    {kept, _, _} = Dice.roll_advantage(20, mode, roller)
    kept
  end

  defp kept_d20(roller, _), do: roller.(20)

  defp dice_with(%{dice: nil}, _roller), do: 0
  defp dice_with(%{dice: expr}, roller), do: Dice.roll_expr(expr, roller)

  defp spell_damage_verb(%{name: "magic missile"}, _dmg), do: " (3 dardos de fuerza)"
  defp spell_damage_verb(_spell, _dmg), do: ""

  defp describe_death_save(name, {:revive, _d20, _, _}),
    do: "#{name} saca un 20 natural — ¡revive con 1 pg!"

  defp describe_death_save(name, {:crit_fail, 1, _, _}),
    do: "#{name} saca un 1 natural — ¡dos fallos de salvación de muerte!"

  defp describe_death_save(name, {:fail, d20, _, _}),
    do: "#{name} saca #{d20} — un fallo de salvación de muerte."

  defp describe_death_save(name, {:success, d20, _, _}),
    do: "#{name} saca #{d20} — un éxito de salvación de muerte."

  # ----------------------------------------------------------------- helpers

  defp resolve_swings(a, t, attacker, target, weapon, roller, roll_log, mode, n) do
    {swings, _hp} =
      Enum.reduce_while(1..n, {[], t.hp}, fn _i, {acc, hp} ->
        if hp <= 0 do
          {:halt, {acc, hp}}
        else
          swing = resolve_one_swing(a, t, attacker, target, weapon, roller, roll_log, mode)
          new_hp = if swing.dmg > 0, do: max(0, hp - swing.dmg), else: hp
          {:cont, {acc ++ [swing], new_hp}}
        end
      end)

    swings
  end

  defp resolve_one_swing(a, t, attacker, target, weapon, roller, roll_log, mode) do
    {r, close_atk} =
      RollLog.open(
        roll_log,
        roller,
        attacker,
        :attack,
        "ataque a #{target} con #{weapon.name}"
      )

    {kind, d20, total} = Combat.attack_roll(a, weapon, t.ac, r, mode)
    RollLog.close(close_atk, total: total, against: {:ac, t.ac}, outcome: kind)

    case kind do
      :miss ->
        %{kind: :miss, d20: d20, total: total, dmg: 0}

      k ->
        {r2, close_dmg} =
          RollLog.open(
            roll_log,
            roller,
            attacker,
            :damage,
            "daño #{weapon.damage_type} a #{target}"
          )

        dmg = Combat.damage_roll(a, weapon, k, r2)

        RollLog.close(close_dmg,
          total: dmg,
          against: nil,
          outcome: if(k == :crit, do: :crit, else: nil)
        )

        %{kind: k, d20: d20, total: total, dmg: dmg}
    end
  end

  defp format_attack_message(attacker, target, _weapon, ac, mode, [%{kind: :miss} = s]) do
    "#{attacker} lanza un golpe a #{target} — fallo (d20 #{s.d20}: #{s.total} vs CA #{ac})#{mode_tag(mode)}."
  end

  defp format_attack_message(attacker, target, weapon, ac, mode, [s]) do
    verb = if s.kind == :crit, do: "CRÍTICO", else: "acierta"

    "#{attacker} #{verb} a #{target} (d20 #{s.d20}: #{s.total} vs CA #{ac}) por #{s.dmg} de daño #{weapon.damage_type}#{mode_tag(mode)}."
  end

  defp format_attack_message(attacker, target, weapon, ac, mode, swings) do
    parts = Enum.map_join(swings, "; ", &describe_swing(&1, weapon, ac))
    "#{attacker} ataca a #{target} (#{length(swings)} golpes)#{mode_tag(mode)}: #{parts}."
  end

  defp describe_swing(%{kind: :miss, d20: d20, total: total}, _weapon, ac) do
    "fallo (d20 #{d20}: #{total} vs CA #{ac})"
  end

  defp describe_swing(%{kind: k, d20: d20, total: total, dmg: dmg}, weapon, ac) do
    verb = if k == :crit, do: "CRÍTICO", else: "acierta"
    "#{verb} (d20 #{d20}: #{total} vs CA #{ac}) por #{dmg} de daño #{weapon.damage_type}"
  end

  defp apply_swing_damages(target, swings) do
    amounts = for %{dmg: dmg} <- swings, dmg > 0, do: dmg

    case amounts do
      [] ->
        noop()

      amounts ->
        fn w ->
          Enum.reduce_while(amounts, {:ok, w}, fn amount, {:ok, acc} ->
            case World.character(acc, target) do
              %Character{hp: hp} when hp <= 0 ->
                {:halt, {:ok, acc}}

              %Character{} ->
                case World.apply_damage(target, amount).(acc) do
                  {:ok, next} -> {:cont, {:ok, next}}
                  error -> {:halt, error}
                end

              nil ->
                {:halt, {:error, "no such character: #{target}"}}
            end
          end)
        end
    end
  end

  defp find_weapon(%Character{weapons: weapons}, name), do: match_named(weapons, name)

  defp find_spell(%Character{spells: spells}, name), do: match_named(spells, name)

  # Fuzzy name lookup for weapons/spells: the LLM often says "sword" for
  # "longsword", "firebolt" for "fire bolt", or varies casing. We match
  # case/space-insensitively first, then fall back to a substring containment
  # (both directions) so a short or approximate name still resolves.
  defp match_named(items, name) do
    norm = fn s -> s |> String.downcase() |> String.replace(~r/[\s_-]+/, "") end
    n = norm.(name)

    Enum.find(items, &(norm.(&1.name) == n)) ||
      Enum.find(items, fn item ->
        iname = norm.(item.name)
        String.contains?(iname, n) or String.contains?(n, iname)
      end)
  end

  defp noop, do: fn w -> {:ok, w} end

  defp sum(count, sides, roller), do: Enum.sum(for _ <- 1..count, do: roller.(sides))

  defp signed(n) when n >= 0, do: "+#{n}"
  defp signed(n), do: "#{n}"

  defp mode_tag(:advantage), do: " (ventaja)"
  defp mode_tag(:disadvantage), do: " (desventaja)"
  defp mode_tag(_), do: ""

  @abilities_es %{
    str: "Fuerza",
    dex: "Destreza",
    con: "Constitución",
    int: "Inteligencia",
    wis: "Sabiduría",
    cha: "Carisma"
  }

  # Spanish label for roll reasons (shown to players in the chat & dice modal).
  defp ability_es(a) when is_atom(a), do: Map.get(@abilities_es, a, inspect(a))

  defp ability_es(s) when is_binary(s) do
    case Dragonex.Rules.Ability.parse(s) do
      {:ok, atom} -> ability_es(atom)
      :error -> s
    end
  end
end
