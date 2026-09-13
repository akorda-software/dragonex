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

  alias Dragonex.{
    Character,
    Dice,
    RollLog,
    Rules.Ability,
    Rules.Combat,
    Rules.Conditions,
    SpellSlots,
    Weapon,
    World
  }

  alias Dragonex.Heroes.{Progression, Spells}

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
  wield the named weapon. Sneak Attack (D41) adds N d6 to the first hit
  of this call when the rogue qualifies.   Rage (D42) adds
  `Progression.rage_damage/1` to every melee hit (`weapon.ranged != true`)
  while the attacker is raging. Divine Smite (D46) spends a pending
  `smite_slot` on the first melee hit (or crit) of this call: extra
  radiant dice through `apply_damage/3`, then `consume_slot`. Miss,
  ranged, and spells leave the pending slot. Fighting Style (D48):
  archery/dueling in `Combat`;   defense raises this target's effective AC
  by 1 without mutating `Character.ac`. Bardic Inspiration (D50) adds 1d6
  to the first swing's attack total (hit or miss consumes; not damage).
  Hunter's Mark (D55) adds 1d6 to every hit against the marked prey while
  the attacker concentrates `"hunter's mark:prey"` (crit doubles the mark
  dice; damage type is the weapon's, like Sneak Attack). Spells and
  Flurry never benefit from the mark.
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
              Conditions.attack_mode(a, t,
                requested: mode,
                ranged: weapon.ranged == true,
                attack_ability: weapon.attack_ability,
                finesse: weapon.finesse == true
              )

            n = Progression.attack_count(a.class, a.level)
            sneak = sneak_opts(world, a, attacker, target, weapon, effective_mode)
            smite = smite_opts(a, weapon)
            inspired? = a.inspired == true
            mark? = mark_target?(a, target)
            hidden? = "hidden" in Character.condition_names(a)

            swings =
              resolve_swings(
                a,
                t,
                attacker,
                target,
                weapon,
                roller,
                roll_log,
                effective_mode,
                n,
                sneak,
                smite,
                inspired?,
                mark?
              )

            ac = target_ac(t)

            {notes, change} =
              pipe_attack_damage(target, swings, roller, roll_log, t, weapon.damage_type)

            change = compose_smite_spend(attacker, a.smite_slot, swings, change)
            change = compose_inspired_clear(attacker, inspired?, change)
            # D57: attacking (hit or miss, every swing) reveals a hidden attacker.
            change = compose_hidden_clear(attacker, hidden?, change)

            {:ok,
             append_notes(
               format_attack_message(attacker, target, weapon, ac, effective_mode, swings),
               notes
             ), change}
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

      World.character(world, caster_name).raging == true ->
        {:error, "#{caster_name} está en furia y no puede conjurar"}

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

              result
              |> compose_slot_consumption(caster_name, spell.level)
              |> compose_concentration(caster_name, spell)
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
  and produce a `begin_combat` change. Ties break by DEX score desc, then name
  asc (D39). 5e would then roll off — skipped so fixed rollers stay deterministic.
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
        {name, rolled, c.dex}
      end)
      |> Enum.sort_by(fn {name, {_d20, total}, dex} -> {-total, -dex, name} end)

    summary =
      Enum.map_join(ordered, ", ", fn {name, {d20, total}, _dex} -> "#{name} #{d20}→#{total}" end)

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

      %Character{} = c ->
        inspired? = c.inspired == true
        {r, close} = RollLog.open(roll_log, roller, name, :death_save, "salvación de muerte")
        result = Combat.death_save(r)
        {result, bardic} = apply_inspired_death(c, result, r)
        RollLog.close(close, total: elem(result, 1), against: {:dc, 10}, outcome: elem(result, 0))
        change = compose_inspired_clear(name, inspired?, World.apply_death_save(name, result))
        {:ok, describe_death_save(name, result, bardic), change}
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
  Second Wind (5e, D45): a fighter heals 1d10 + level, once until a rest.

  Capped at max_hp; same heal path (clears death saves if hp > 0). Does not
  touch temp_hp.
  """
  @spec second_wind(World.t(), String.t(), roller(), RollLog.t() | nil) :: result()
  def second_wind(world, who, roller, roll_log \\ nil) do
    case World.character(world, who) do
      nil ->
        {:error, "no existe el personaje: #{who}"}

      %Character{class: class} when class != "fighter" ->
        {:error, "#{who} no es guerrero y no puede usar Segundo aliento"}

      %Character{second_wind_used: true} ->
        {:error, "#{who} ya ha usado Segundo aliento (se recarga con un descanso)"}

      %Character{hp: hp, max_hp: max_hp, level: level} ->
        hp = hp || 0
        max_hp = max_hp || 0
        level = level || 1

        {r, close} =
          RollLog.open(roll_log, roller, who, :heal, "Segundo aliento (1d10+#{level})")

        rolled = r.(10) + level
        RollLog.close(close, total: rolled, against: nil, outcome: nil)
        applied = min(rolled, max(0, max_hp - hp))

        {:ok,
         "#{who} usa Segundo aliento y se cura #{applied} pg (1d10+#{level} = #{rolled}, ahora #{hp + applied}/#{max_hp}).",
         World.second_wind(who, rolled)}
    end
  end

  @doc """
  Lay on Hands (5e, D49): a paladin spends pool points to heal `target`.

  `applied = min(amount, remaining_pool, max(0, target.max_hp - target.hp))`.
  Spends `applied`, not the requested amount. Capped at max_hp; same heal
  path (clears death saves if hp > 0). Does not touch temp_hp.
  """
  @spec lay_on_hands(World.t(), String.t(), String.t(), term()) :: result()
  def lay_on_hands(world, who, target, amount) do
    case World.character(world, who) do
      nil ->
        {:error, "no existe el personaje: #{who}"}

      %Character{} ->
        case World.character(world, target) do
          nil ->
            {:error, "no existe el personaje: #{target}"}

          %Character{} = tgt ->
            lay_on_hands_apply(world, who, target, amount, tgt)
        end
    end
  end

  defp lay_on_hands_apply(world, who, target, amount, tgt) do
    case World.character(world, who) do
      %Character{class: class} when class != "paladin" ->
        {:error, "#{who} no es paladín y no puede usar Manos impositoras"}

      %Character{lay_on_hands_pool: pool} ->
        pool = pool || 0

        cond do
          not is_integer(amount) or amount < 1 ->
            {:error, "la cantidad de Manos impositoras debe ser un entero ≥ 1"}

          pool == 0 ->
            {:error, "#{who} no tiene puntos de Manos impositoras"}

          amount > pool ->
            {:error,
             "#{who} no tiene suficientes puntos de Manos impositoras (pide #{amount}, quedan #{pool})"}

          lay_on_hands_blocked_race?(tgt.race) ->
            {:error, "#{target} no puede recibir Manos impositoras (no-muerto o constructo)"}

          true ->
            hp = tgt.hp || 0
            max_hp = tgt.max_hp || 0
            applied = min(amount, min(pool, max(0, max_hp - hp)))

            if applied == 0 do
              {:error, "#{target} ya está a tope de puntos de golpe"}
            else
              remaining = pool - applied

              {:ok,
               "#{who} usa Manos impositoras en #{target} y cura #{applied} pg (ahora #{hp + applied}/#{max_hp}, pool #{remaining}).",
               World.lay_on_hands(who, target, applied)}
            end
        end
    end
  end

  defp lay_on_hands_blocked_race?(race) when is_binary(race) do
    String.downcase(race) in ["undead", "construct"]
  end

  defp lay_on_hands_blocked_race?(_), do: false

  @divine_sense_races ~w(celestial fiend undead)
  @divine_sense_labels %{
    "celestial" => "celestial",
    "fiend" => "infernal",
    "undead" => "no-muerto"
  }

  @doc """
  Divine Sense (5e, D52): a paladin spends 1 use and the engine reports
  every other character whose `race` is celestial, fiend or undead.
  Allowed in combat. Spends even if the scan is empty. The LLM does not
  list types.
  """
  @spec divine_sense(World.t(), String.t()) :: result()
  def divine_sense(world, who) do
    case World.character(world, who) do
      nil ->
        {:error, "no existe el personaje: #{who}"}

      %Character{class: class} when class != "paladin" ->
        {:error, "#{who} no es paladín y no puede usar Sentido divino"}

      %Character{divine_sense_uses: uses} ->
        uses = uses || 0

        if uses < 1 do
          {:error, "#{who} no tiene usos de Sentido divino"}
        else
          remaining = uses - 1
          detected = divine_sense_targets(world, who)

          {:ok, divine_sense_message(who, detected, remaining), World.spend_divine_sense(who)}
        end
    end
  end

  defp divine_sense_targets(%World{characters: chars}, who) do
    chars
    |> Enum.reject(fn {name, _} -> name == who end)
    |> Enum.map(fn {_name, c} -> c end)
    |> Enum.filter(&divine_sense_race?(&1.race))
    |> Enum.sort_by(& &1.name)
  end

  defp divine_sense_race?(race) when is_binary(race) do
    String.downcase(race) in @divine_sense_races
  end

  defp divine_sense_race?(_), do: false

  defp divine_sense_label(race) when is_binary(race) do
    Map.get(@divine_sense_labels, String.downcase(race), String.downcase(race))
  end

  defp divine_sense_message(who, [], remaining) do
    "#{who} usa Sentido divino y no percibe celestiales, infernales ni no-muertos (usos restantes #{remaining})."
  end

  defp divine_sense_message(who, detected, remaining) do
    listed =
      detected
      |> Enum.map(fn c -> "#{c.name} (#{divine_sense_label(c.race)})" end)
      |> Enum.join(", ")

    "#{who} usa Sentido divino y percibe: #{listed} (usos restantes #{remaining})."
  end

  @doc """
  Turn Undead (5e, D53): a cleric level 2+ spends Channel Divinity.

  Other living undead (`race` downcase `"undead"`, hp > 0) roll a Wisdom
  save vs DC `8 + proficiency + cleric Wisdom modifier`. Failure applies
  frightened (M06). Spends even if there are no targets. Combat allowed.
  """
  @spec turn_undead(World.t(), String.t(), roller(), RollLog.t() | nil) :: result()
  def turn_undead(world, who, roller, roll_log \\ nil) do
    case World.character(world, who) do
      nil ->
        {:error, "no existe el personaje: #{who}"}

      %Character{class: class} when class != "cleric" ->
        {:error, "#{who} no es clérigo y no puede usar Expulsar no-muertos"}

      %Character{level: level} when not is_integer(level) or level < 2 ->
        {:error, "#{who} no tiene Expulsar no-muertos (nivel 2)"}

      %Character{channel_divinity_used: true} ->
        {:error, "#{who} ya ha usado Canalizar divinidad (se recarga con un descanso)"}

      %Character{} = cleric ->
        dc = 8 + Ability.proficiency(cleric.level) + Character.modifier(cleric, :wis)
        {failed, saved} = turn_undead_resolutions(world, who, dc, roller, roll_log)

        {:ok, turn_undead_message(who, dc, failed, saved), compose_turn_undead(who, failed)}
    end
  end

  defp turn_undead_resolutions(world, who, dc, roller, roll_log) do
    world
    |> turn_undead_targets(who)
    |> Enum.reduce({[], []}, fn target, {failed, saved} ->
      if turn_undead_save_success?(target, dc, roller, roll_log) do
        {failed, saved ++ [target.name]}
      else
        {failed ++ [target.name], saved}
      end
    end)
  end

  defp turn_undead_targets(%World{characters: chars}, who) do
    chars
    |> Enum.reject(fn {name, _} -> name == who end)
    |> Enum.map(fn {_name, c} -> c end)
    |> Enum.filter(&turn_undead_target?/1)
    |> Enum.sort_by(& &1.name)
  end

  defp turn_undead_target?(%Character{hp: hp, race: race})
       when is_integer(hp) and hp > 0 and is_binary(race) do
    String.downcase(race) == "undead"
  end

  defp turn_undead_target?(_), do: false

  defp turn_undead_save_success?(target, dc, roller, roll_log) do
    case Conditions.save_mode(target, :wis) do
      :auto_fail ->
        false

      {:roll, save_mode} ->
        {r, close} =
          RollLog.open(
            roll_log,
            roller,
            target.name,
            :save,
            "salvación de Sabiduría contra Expulsar no-muertos"
          )

        {_d20, total, success?} = Combat.saving_throw(target, :wis, dc, r, save_mode)

        RollLog.close(close,
          total: total,
          against: {:dc, dc},
          outcome: if(success?, do: :success, else: :failure)
        )

        success?
    end
  end

  defp turn_undead_message(who, dc, [], []) do
    "#{who} usa Expulsar no-muertos (CD #{dc}) y no hay no-muertos que Expulsar no-muertos pueda afectar (usos restantes 0)."
  end

  defp turn_undead_message(who, dc, failed, saved) do
    bits =
      [frightened_clause(failed), saved_clause(saved)]
      |> Enum.reject(&is_nil/1)

    "#{who} usa Expulsar no-muertos (CD #{dc}): #{Enum.join(bits, "; ")} (usos restantes 0)."
  end

  defp frightened_clause([]), do: nil
  defp frightened_clause([name]), do: "#{name} queda asustado"
  defp frightened_clause(names), do: "#{Enum.join(names, ", ")} quedan asustados"

  defp saved_clause([]), do: nil
  defp saved_clause([name]), do: "#{name} supera la salvación"
  defp saved_clause(names), do: "#{Enum.join(names, ", ")} superan la salvación"

  defp compose_turn_undead(who, failed) do
    fn w ->
      with {:ok, w} <- World.set_channel_divinity_used(who, true).(w) do
        Enum.reduce_while(failed, {:ok, w}, fn name, {:ok, acc} ->
          case World.apply_condition(name, "frightened").(acc) do
            {:ok, w2} -> {:cont, {:ok, w2}}
            err -> {:halt, err}
          end
        end)
      end
    end
  end

  @doc """
  Bardic Inspiration (5e, D50): a bard spends 1 use to grant `target` a
  pending d6 (`inspired = true`). The die is applied by the engine on the
  target's next attack/check/save/death save. Target may be another
  character or the bard. Does not stack or refresh.
  """
  @spec bardic_inspiration(World.t(), String.t(), String.t()) :: result()
  def bardic_inspiration(world, who, target) do
    case World.character(world, who) do
      nil ->
        {:error, "no existe el personaje: #{who}"}

      %Character{class: class} when class != "bard" ->
        {:error, "#{who} no es bardo y no puede usar Inspiración bárdica"}

      %Character{bardic_inspiration_uses: uses} ->
        uses = uses || 0

        case World.character(world, target) do
          nil ->
            {:error, "no existe el personaje: #{target}"}

          %Character{inspired: true} ->
            {:error, "#{target} ya está inspirado"}

          %Character{} when uses < 1 ->
            {:error, "#{who} no tiene usos de Inspiración bárdica"}

          %Character{} ->
            remaining = uses - 1

            {:ok,
             "#{who} inspira a #{target} (Inspiración bárdica d6, usos restantes #{remaining}).",
             World.spend_bardic(who, target)}
        end
    end
  end

  @doc """
  Arcane Recovery (5e, D51): a wizard restores expended spell slots
  outside combat, once until a long rest. Budget `div(level + 1, 2)`.
  No slot above 5th. Greedy highest-to-lowest. The LLM does not pick slots.
  """
  @spec arcane_recovery(World.t(), String.t()) :: result()
  def arcane_recovery(world, who) do
    case World.character(world, who) do
      nil ->
        {:error, "no existe el personaje: #{who}"}

      %Character{} when world.phase == :combat ->
        {:error, "no se puede usar Recuperación arcana en combate"}

      %Character{class: class} when class != "wizard" ->
        {:error, "#{who} no es mago y no puede usar Recuperación arcana"}

      %Character{arcane_recovery_used: true} ->
        {:error, "#{who} ya ha usado Recuperación arcana (se recarga con un descanso largo)"}

      %Character{} ->
        case World.arcane_recovery_plan(world, who) do
          {:error, reason} ->
            {:error, reason}

          {:ok, new_slots, restored} ->
            {:ok, arcane_recovery_message(who, restored),
             World.apply_arcane_recovery(who, new_slots)}
        end
    end
  end

  defp arcane_recovery_message(who, restored) do
    "#{who} usa Recuperación arcana y recupera #{format_restored_slots(restored)}."
  end

  defp format_restored_slots(restored) do
    items =
      restored
      |> Enum.sort_by(fn {level, _} -> -level end)
      |> Enum.with_index()
      |> Enum.map(fn {{level, n}, i} -> slot_fragment(n, level, i == 0) end)

    case items do
      [only] ->
        only

      [first, last] ->
        "#{first} y #{last}"

      [first | rest] ->
        {last, mids} = List.pop_at(rest, -1)
        "#{first}, #{Enum.join(mids, ", ")} y #{last}"
    end
  end

  defp slot_fragment(n, level, true) do
    noun = if n == 1, do: "hueco", else: "huecos"
    "#{n} #{noun} de nivel #{level}"
  end

  defp slot_fragment(n, level, false), do: "#{n} de nivel #{level}"

  @doc """
  Action Surge (5e, D47): a fighter of level 2+ takes one extra Attack
  action (N swings via Extra Attack D35), once until a rest.

  The tool IS the extra action (simplified action economy). Hit or miss
  marks the use; errors (missing, 0 hp, no weapon, not fighter, L1,
  already used) do not.
  """
  @spec action_surge(
          World.t(),
          String.t(),
          String.t(),
          String.t(),
          roller(),
          :normal | :advantage | :disadvantage,
          RollLog.t() | nil
        ) :: result()
  def action_surge(world, who, target, weapon_name, roller, mode \\ :normal, roll_log \\ nil) do
    case World.character(world, who) do
      nil ->
        {:error, "no existe el personaje: #{who}"}

      %Character{class: class} when class != "fighter" ->
        {:error, "#{who} no es guerrero y no puede usar Oleada de acción"}

      %Character{level: level} when not is_integer(level) or level < 2 ->
        {:error, "#{who} no tiene Oleada de acción (nivel 2)"}

      %Character{action_surge_used: true} ->
        {:error, "#{who} ya ha usado Oleada de acción (se recarga con un descanso)"}

      %Character{} ->
        case attack(world, who, target, weapon_name, roller, mode, roll_log) do
          {:ok, msg, change} ->
            {:ok, "#{who} usa Oleada de acción. #{msg}", compose_mark_action_surge(who, change)}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Flurry of Blows (5e, D54): a monk of level 2+ spends 1 ki point and makes
  two unarmed strikes (martial arts die, DEX) against `target`.

  The tool IS the bonus action (simplified action economy); no prior attack
  required. N is fixed at 2 — never `Progression.attack_count/2` — and no
  Sneak Attack, Divine Smite or Extra Attack stacking. The unarmed strike is
  a synthetic weapon: not required in inventory. Hit or miss spends the ki;
  errors (missing who/target, 0 hp, not a monk, L1, 0 ki) do not. If the
  target drops (hp ≤ 0) mid-flurry, the second swing is skipped.
  """
  @spec flurry_of_blows(
          World.t(),
          String.t(),
          String.t(),
          roller(),
          :normal | :advantage | :disadvantage,
          RollLog.t() | nil
        ) :: result()
  def flurry_of_blows(world, who, target, roller, mode \\ :normal, roll_log \\ nil) do
    monk = World.character(world, who)

    cond do
      is_nil(monk) ->
        {:error, "no existe el personaje: #{who}"}

      is_nil(World.character(world, target)) ->
        {:error, "no existe el objetivo: #{target}"}

      (monk.hp || 0) <= 0 ->
        {:error, "#{who} está caído (0 pg) y no puede atacar"}

      monk.class != "monk" ->
        {:error, "#{who} no es monje y no puede usar Ráfaga de golpes"}

      not is_integer(monk.level) or monk.level < 2 ->
        {:error, "#{who} no tiene Ráfaga de golpes (nivel 2)"}

      (monk.ki || 0) < 1 ->
        {:error, "#{who} no tiene ki (se recarga con un descanso)"}

      true ->
        t = World.character(world, target)
        weapon = unarmed_strike(monk.level)
        inspired? = monk.inspired == true

        effective_mode =
          Conditions.attack_mode(monk, t,
            requested: mode,
            ranged: false,
            attack_ability: :dex,
            finesse: true
          )

        # N=2 fijo (D54): sin sneak, sin smite, sin Extra Attack, sin marca (D55).
        swings =
          resolve_swings(
            monk,
            t,
            who,
            target,
            weapon,
            roller,
            roll_log,
            effective_mode,
            2,
            nil,
            nil,
            inspired?,
            false
          )

        ac = target_ac(t)

        {notes, change} =
          pipe_attack_damage(target, swings, roller, roll_log, t, weapon.damage_type)

        change = compose_inspired_clear(who, inspired?, change)

        {:ok,
         append_notes(
           "#{who} usa Ráfaga de golpes (ki restantes #{(monk.ki || 0) - 1}). " <>
             format_attack_message(who, target, weapon, ac, effective_mode, swings),
           notes
         ), compose_spend_ki(who, change)}
    end
  end

  defp unarmed_strike(level) do
    %Weapon{
      name: "unarmed strike",
      dice: Progression.martial_arts_die(level || 1),
      damage_type: "bludgeoning",
      attack_ability: :dex,
      finesse: true,
      ranged: false
    }
  end

  @doc """
  Hunter's Mark (5e, D55): a ranger of level 2+ spends a level-1 spell
  slot and marks `target` as prey, concentrating on the mark.

  While the concentration holds, `attack/6` adds +1d6 per weapon hit
  against that prey (crit doubles the mark dice; damage type is the
  weapon's). Spells and Flurry never benefit. The mark ends only through
  the existing concentration paths (`drop_concentration`, breaking
  conditions, rage, 0 hp) — nothing new. Errors spend no slot and never
  touch concentration.
  """
  @spec hunters_mark(World.t(), String.t(), String.t(), roller(), RollLog.t() | nil) ::
          result()
  def hunters_mark(world, who, target, _roller, _roll_log \\ nil) do
    hunter = World.character(world, who)

    cond do
      is_nil(hunter) ->
        {:error, "no existe el personaje: #{who}"}

      is_nil(World.character(world, target)) ->
        {:error, "no existe el objetivo: #{target}"}

      (hunter.hp || 0) <= 0 ->
        {:error, "#{who} está caído (0 pg) y no puede marcar presa"}

      hunter.class != "ranger" ->
        {:error, "#{who} no es explorador y no puede usar Marca del cazador"}

      not is_integer(hunter.level) or hunter.level < 2 ->
        {:error, "#{who} no tiene Marca del cazador (nivel 2)"}

      (World.character(world, target).hp || 0) <= 0 ->
        {:error, "#{target} está caído (0 pg) y no puede ser presa"}

      not World.has_slot?(world, who, 1) ->
        {:error,
         "a #{who} no le quedan casillas de hechizo de nivel 1 " <>
           "(debe descansar para recuperarlas)."}

      not is_nil(hunter.concentrating) ->
        {:error,
         "#{who} ya concentra en #{hunter.concentrating} — debe soltar la concentración antes (drop_concentration)"}

      true ->
        {:ok,
         "#{who} marca a #{target} como presa (Hunter's Mark, concentración, casilla nivel 1 gastada).",
         fn w ->
           with {:ok, w} <- World.consume_slot(who, 1).(w) do
             World.set_concentration(who, "hunter's mark:#{target}").(w)
           end
         end}
    end
  end

  @doc """
  Cunning Action: Hide (5e, D57): a rogue of level 2+ attempts to hide.

  The engine rolls the check — `1d20 + DEX mod (+ proficiency when "stealth"
  is in `skill_proficiencies`)`, mode from `Conditions.check_mode/3` —
  against the highest passive perception among conscious enemies
  (`side != who.side`, hp > 0): `10 + WIS mod (+ proficiency when
  "perception" is trained)`. With no conscious enemy the DC is 10 (RAW
  minimum). Success applies the "hidden" condition (advantage on the
  rogue's attacks — and Sneak Attack, D41); attacking (hit or miss)
  reveals and removes it. Combat allowed (bonus action RAW; action
  economy out of scope). Errors do not mutate.
  """
  @spec cunning_action_hide(World.t(), String.t(), roller(), RollLog.t() | nil) :: result()
  def cunning_action_hide(world, who, roller, roll_log \\ nil) do
    rogue = World.character(world, who)

    cond do
      is_nil(rogue) ->
        {:error, "no existe el personaje: #{who}"}

      (rogue.hp || 0) <= 0 ->
        {:error, "#{who} está caído (0 pg) y no puede esconderse"}

      rogue.class != "rogue" ->
        {:error, "#{who} no es pícaro y no puede usar Astucia de pícaro"}

      not is_integer(rogue.level) or rogue.level < 2 ->
        {:error, "#{who} no tiene Astucia de pícaro (nivel 2)"}

      World.has_condition?(world, who, "hidden") ->
        {:error, "#{who} ya está oculto"}

      true ->
        hide_check(rogue, world, who, roller, roll_log)
    end
  end

  defp hide_check(%Character{} = rogue, world, who, roller, roll_log) do
    dc = hide_dc(world, rogue)
    stealth? = skill_trained?(rogue, "stealth")
    mode = Conditions.check_mode(rogue, :dex, :normal)

    {r, close} =
      RollLog.open(roll_log, roller, who, :check, "Sigilo para esconderse")

    {d20, total, success?} = Combat.ability_check(rogue, :dex, dc, r, stealth?, mode)

    RollLog.close(close,
      total: total,
      against: {:dc, dc},
      outcome: if(success?, do: :success, else: :failure)
    )

    dex_mod = Character.modifier(rogue, :dex)
    prof = if stealth?, do: Ability.proficiency(rogue.level), else: 0

    breakdown =
      ["1d20(#{d20})"]
      |> then(fn p -> if dex_mod != 0, do: p ++ ["#{signed(dex_mod)}"], else: p end)
      |> then(fn p -> if prof != 0, do: p ++ ["+#{prof}"], else: p end)
      |> Enum.join("")

    verdict = if success?, do: "oculto", else: "falla y sigue a la vista"

    {:ok, "#{who} se esconde: #{breakdown}=#{total} vs #{dc} — #{verdict}",
     if(success?, do: World.apply_condition(who, "hidden"), else: noop())}
  end

  # DC: the highest passive perception among conscious enemies; 10 when
  # there is none (RAW minimum).
  defp hide_dc(%World{} = world, %Character{} = who) do
    world.characters
    |> Map.values()
    |> Enum.filter(fn c -> c.side != who.side and (c.hp || 0) > 0 end)
    |> Enum.map(&passive_perception/1)
    |> Enum.max(fn -> 10 end)
  end

  @doc "Passive perception: 10 + WIS mod (+ proficiency if trained)."
  @spec passive_perception(Character.t()) :: integer()
  def passive_perception(%Character{} = c) do
    prof = if skill_trained?(c, "perception"), do: Ability.proficiency(c.level), else: 0
    10 + Character.modifier(c, :wis) + prof
  end

  defp skill_trained?(%Character{skill_proficiencies: profs}, skill) when is_list(profs) do
    skill in profs
  end

  defp skill_trained?(_, _), do: false

  @doc """
  Create a Spell Slot (5e, D56 Font of Magic): a sorcerer of level 2+ spends
  sorcery points (RAW cost 2/3/5/6/7 for slots 1–5) and gains one slot of
  `level`. RAW allows exceeding the daily slot maximum. Combat allowed
  (bonus action RAW; action economy out of scope). Errors (nothing spent):
  missing who, 0 hp, not a sorcerer, level < 2, invalid slot level,
  insufficient points.
  """
  @spec create_spell_slot(World.t(), String.t(), integer()) :: result()
  def create_spell_slot(world, who, level) do
    sorcerer = World.character(world, who)
    cost = Progression.sorcery_slot_cost(level)

    cond do
      is_nil(sorcerer) ->
        {:error, "no existe el personaje: #{who}"}

      (sorcerer.hp || 0) <= 0 ->
        {:error, "#{who} está caído (0 pg) y no puede usar Fuente de magia"}

      sorcerer.class != "sorcerer" ->
        {:error, "#{who} no es hechicero y no puede usar Fuente de magia"}

      not is_integer(sorcerer.level) or sorcerer.level < 2 ->
        {:error, "#{who} no tiene Fuente de magia (nivel 2)"}

      is_nil(cost) ->
        {:error, "nivel de casilla inválido: #{inspect(level)} (1 a 5)"}

      (sorcerer.sorcery_points || 0) < cost ->
        {:error,
         "#{who} no tiene suficientes puntos de hechicería (le quedan #{sorcerer.sorcery_points || 0}; la casilla de nivel #{level} cuesta #{cost})"}

      true ->
        remaining = (sorcerer.sorcery_points || 0) - cost

        {:ok,
         "#{who} teje magia: convierte #{cost} puntos de hechicería en 1 casilla de nivel #{level} (quedan #{remaining} puntos).",
         compose_create_slot(who, level, cost)}
    end
  end

  @doc """
  Convert to Sorcery Points (5e, D56 Font of Magic): a sorcerer of level 2+
  spends one slot of `level` (1–5, same range as create) and gains `level`
  sorcery points, capped at the pool maximum (`Progression.sorcery_points/2`).
  The excess is silently discarded (RAW) — never an error — and the message
  reports the real result. Errors (nothing spent): missing who, 0 hp, not a
  sorcerer, level < 2, invalid slot level, no slot of that level left.
  """
  @spec convert_to_sorcery_points(World.t(), String.t(), integer()) :: result()
  def convert_to_sorcery_points(world, who, level) do
    sorcerer = World.character(world, who)

    cond do
      is_nil(sorcerer) ->
        {:error, "no existe el personaje: #{who}"}

      (sorcerer.hp || 0) <= 0 ->
        {:error, "#{who} está caído (0 pg) y no puede usar Fuente de magia"}

      sorcerer.class != "sorcerer" ->
        {:error, "#{who} no es hechicero y no puede usar Fuente de magia"}

      not is_integer(sorcerer.level) or sorcerer.level < 2 ->
        {:error, "#{who} no tiene Fuente de magia (nivel 2)"}

      not (is_integer(level) and level >= 1 and level <= 5) ->
        {:error, "nivel de casilla inválido: #{inspect(level)} (1 a 5)"}

      not World.has_slot?(world, who, level) ->
        {:error, "#{who} no le quedan casillas de nivel #{level}"}

      true ->
        max = Progression.sorcery_points("sorcerer", sorcerer.level)
        before = sorcerer.sorcery_points || 0
        after_points = min(before + level, max)
        gained = after_points - before
        cap_note = if before + level > max, do: " El exceso se disipa en la Fuente.", else: ""

        {:ok,
         "#{who} drena una casilla de nivel #{level} y recupera #{gained} " <>
           "punto#{if gained == 1, do: "", else: "s"} de hechicería " <>
           "(#{after_points}/#{max} máx).#{cap_note}", compose_convert_slot(who, level)}
    end
  end

  @doc """
  A short rest: the character spends hit dice to recover HP.

  At level 1, a character has 1 hit die. The heal is `roll(hit_die) + con_mod`.
  Warlocks (D40) also restore Pact Magic slots; other casters do not.
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

          msg =
            "#{name} hace un descanso corto y recupera #{applied} pg (1d#{hit_die}#{signed(con_mod)} = #{rolled}, ahora #{hp + applied}/#{max_hp})."

          {msg, restore?} =
            if SpellSlots.pact_caster?(c.class) do
              {msg <> " Casillas de pacto recuperadas.", true}
            else
              {msg, false}
            end

          {:ok, msg, compose_rest(name, applied, restore?)}
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

          {:ok,
           "#{name} hace un descanso largo y recupera #{healed} pg (#{hp} → #{max_hp}, recuperación completa). Casillas de hechizo recuperadas.",
           compose_long_rest(name, healed)}
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

        {d20, total, _success?} =
          Combat.ability_check(c, ability, dc, r, proficient, effective_mode)

        inspired? = c.inspired == true
        {total, success?, bardic} = apply_inspired_vs_dc(c, total, dc, r)

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
          |> then(fn p -> if bardic != 0, do: p ++ ["#{bardic} (inspiración)"], else: p end)

        {:ok,
         "#{who} hace un chequeo de #{ability_es(ability)}#{mode_tag(effective_mode)}: #{Enum.join(parts, " + ")} = #{total} vs CD #{dc} — #{verdict}.",
         compose_inspired_clear(who, inspired?, noop())}
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
          # False Life (SRD): 1d4+4 temp_hp on the caster. No Spell-shape change (D36).
          false_life?(spell) ->
            rolled = Dice.roll_expr("1d4+4", r)

            RollLog.close(close,
              kind: :heal,
              reason: "pg temporales de #{spell.name}",
              total: rolled,
              outcome: nil
            )

            {:ok, "#{caster_name} conjura #{spell.name}; obtiene #{rolled} pg temporales.",
             World.apply_temp_hp(caster_name, rolled)}

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

            with_conc_damage(
              "#{caster_name} conjura #{spell.name}; #{target_name} recibe #{amount} de daño #{spell.damage_type}#{verb}.",
              target_name,
              amount,
              roller,
              roll_log,
              t,
              spell.damage_type
            )

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
        # D57: a hidden caster keeps the advantage for free (attack_mode),
        # but the spell attack reveals them just like a weapon swing.
        hidden? = "hidden" in Character.condition_names(c)

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

          with_conc_damage(
            "#{caster_name} conjura #{spell.name}; impacta a #{target_name} (d20 #{d20}: #{total} vs CA #{t.ac}) por #{dmg} de daño #{spell.damage_type}#{mode_tag(effective_mode)}.",
            target_name,
            dmg,
            roller,
            roll_log,
            t,
            spell.damage_type
          )
          |> clear_hidden_after_attack_spell(caster_name, hidden?)
        else
          {:ok,
           "#{caster_name} conjura #{spell.name}; falla contra #{target_name} (d20 #{d20}: #{total} vs CA #{t.ac})#{mode_tag(effective_mode)}.",
           noop()}
          |> clear_hidden_after_attack_spell(caster_name, hidden?)
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

        with_conc_damage(
          "#{caster_name} conjura #{spell.name}; #{target_name} falla automáticamente la salvación de #{ability_es(spell.save_ability)} vs CD #{dc} — #{full} de daño #{spell.damage_type}.",
          target_name,
          full,
          roller,
          roll_log,
          t,
          spell.damage_type
        )

      {:roll, save_mode} ->
        {r, close_save} =
          RollLog.open(
            roll_log,
            roller,
            target_name,
            :save,
            "salvación de #{ability_es(spell.save_ability)} contra #{spell.name}"
          )

        inspired? = t.inspired == true
        {d20, stotal, _success?} = Combat.saving_throw(t, spell.save_ability, dc, r, save_mode)
        {stotal, success?, bardic} = apply_inspired_vs_dc(t, stotal, dc, r)

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
        bardic_bit = if bardic != 0, do: " +#{bardic} inspiración", else: ""

        verdict =
          if success?,
            do:
              "supera la salvación (d20 #{d20}: #{stotal} vs CD #{dc}#{bardic_bit})#{mode_tag(save_mode)}, mitad de daño",
            else:
              "falla la salvación (d20 #{d20}: #{stotal} vs CD #{dc}#{bardic_bit})#{mode_tag(save_mode)}"

        {:ok, msg, change} =
          with_conc_damage(
            "#{caster_name} conjura #{spell.name}; #{target_name} #{verdict} — #{dmg} de daño #{spell.damage_type}.",
            target_name,
            dmg,
            roller,
            roll_log,
            t,
            spell.damage_type
          )

        {:ok, msg, compose_inspired_clear(target_name, inspired?, change)}
    end
  end

  defp kept_d20(roller, mode) when mode in [:advantage, :disadvantage] do
    {kept, _, _} = Dice.roll_advantage(20, mode, roller)
    kept
  end

  defp kept_d20(roller, _), do: roller.(20)

  # D57: reveal a hidden caster once their attack spell resolves.
  defp clear_hidden_after_attack_spell({:ok, msg, change}, name, true) do
    {:ok, msg, compose_hidden_clear(name, true, change)}
  end

  defp clear_hidden_after_attack_spell(result, _name, false), do: result

  defp dice_with(%{dice: nil}, _roller), do: 0
  defp dice_with(%{dice: expr}, roller), do: Dice.roll_expr(expr, roller)

  defp spell_damage_verb(%{name: "magic missile"}, _dmg), do: " (3 dardos de fuerza)"
  defp spell_damage_verb(_spell, _dmg), do: ""

  defp describe_death_save(name, {:revive, _d20, _, _}, bardic),
    do: "#{name} saca un 20 natural#{bardic_death_bit(bardic)} — ¡revive con 1 pg!"

  defp describe_death_save(name, {:crit_fail, 1, _, _}, bardic),
    do:
      "#{name} saca un 1 natural#{bardic_death_bit(bardic)} — ¡dos fallos de salvación de muerte!"

  defp describe_death_save(name, {:fail, d20, _, _}, bardic),
    do: "#{name} saca #{d20}#{bardic_death_bit(bardic)} — un fallo de salvación de muerte."

  defp describe_death_save(name, {:success, d20, _, _}, bardic),
    do: "#{name} saca #{d20}#{bardic_death_bit(bardic)} — un éxito de salvación de muerte."

  defp bardic_death_bit(n) when is_integer(n) and n > 0, do: " (+#{n} inspiración)"
  defp bardic_death_bit(_), do: ""

  # ----------------------------------------------------------------- helpers

  defp resolve_swings(
         a,
         t,
         attacker,
         target,
         weapon,
         roller,
         roll_log,
         mode,
         n,
         sneak,
         smite,
         inspired?,
         mark?
       ) do
    {swings, _hp, _sneak, _smite, _inspired} =
      Enum.reduce_while(1..n, {[], t.hp, sneak, smite, inspired?}, fn _i,
                                                                      {acc, hp, sneak_left,
                                                                       smite_left, inspired_left} ->
        if hp <= 0 do
          {:halt, {acc, hp, sneak_left, smite_left, inspired_left}}
        else
          swing =
            resolve_one_swing(
              a,
              t,
              attacker,
              target,
              weapon,
              roller,
              roll_log,
              mode,
              sneak_left,
              smite_left,
              inspired_left,
              mark?
            )

          incoming =
            Character.incoming_damage(t, swing.dmg, weapon.damage_type) +
              Character.incoming_damage(t, swing.smite, "radiant")

          new_hp = if incoming > 0, do: max(0, hp - incoming), else: hp
          sneak_left = if swing.sneak > 0, do: nil, else: sneak_left
          smite_left = if swing.smite > 0, do: nil, else: smite_left
          {:cont, {acc ++ [swing], new_hp, sneak_left, smite_left, false}}
        end
      end)

    swings
  end

  defp target_ac(%Character{fighting_style: "defense", ac: ac}), do: ac + 1
  defp target_ac(%Character{ac: ac}), do: ac

  defp resolve_one_swing(
         a,
         t,
         attacker,
         target,
         weapon,
         roller,
         roll_log,
         mode,
         sneak,
         smite,
         inspired?,
         mark?
       ) do
    {r, close_atk} =
      RollLog.open(
        roll_log,
        roller,
        attacker,
        :attack,
        "ataque a #{target} con #{weapon.name}"
      )

    ac = target_ac(t)
    {kind, d20, total} = Combat.attack_roll(a, weapon, ac, r, mode)
    {kind, total, bardic} = apply_inspired_attack(inspired?, kind, d20, total, ac, r)
    RollLog.close(close_atk, total: total, against: {:ac, ac}, outcome: kind)

    case kind do
      :miss ->
        %{
          kind: :miss,
          d20: d20,
          total: total,
          dmg: 0,
          sneak: 0,
          rage: 0,
          smite: 0,
          smite_dice: 0,
          mark: 0,
          bardic: bardic
        }

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
        sneak_dmg = sneak_damage(sneak, k, r2)
        rage_dmg = rage_bonus(a, weapon)
        mark_dmg = mark_damage(mark?, k, r2)
        total_dmg = dmg + sneak_dmg + rage_dmg + mark_dmg

        RollLog.close(close_dmg,
          total: total_dmg,
          against: nil,
          outcome: if(k == :crit, do: :crit, else: nil)
        )

        {smite_dmg, smite_dice} = smite_roll(smite, t, attacker, target, roller, roll_log)

        %{
          kind: k,
          d20: d20,
          total: total,
          dmg: total_dmg,
          sneak: sneak_dmg,
          rage: rage_dmg,
          smite: smite_dmg,
          smite_dice: smite_dice,
          mark: mark_dmg,
          bardic: bardic
        }
    end
  end

  defp format_attack_message(attacker, target, _weapon, ac, mode, [%{kind: :miss} = s]) do
    "#{attacker} lanza un golpe a #{target} — fallo (d20 #{s.d20}: #{s.total} vs CA #{ac})#{bardic_tag(s)}#{mode_tag(mode)}."
  end

  defp format_attack_message(attacker, target, weapon, ac, mode, [s]) do
    verb = if s.kind == :crit, do: "CRÍTICO", else: "acierta"

    "#{attacker} #{verb} a #{target} (d20 #{s.d20}: #{s.total} vs CA #{ac}) por #{s.dmg} de daño #{weapon.damage_type}#{sneak_tag(s)}#{rage_tag(s)}#{mark_tag(s)}#{smite_tag(s)}#{bardic_tag(s)}#{mode_tag(mode)}."
  end

  defp format_attack_message(attacker, target, weapon, ac, mode, swings) do
    parts = Enum.map_join(swings, "; ", &describe_swing(&1, weapon, ac))
    "#{attacker} ataca a #{target} (#{length(swings)} golpes)#{mode_tag(mode)}: #{parts}."
  end

  defp describe_swing(%{kind: :miss, d20: d20, total: total} = s, _weapon, ac) do
    "fallo (d20 #{d20}: #{total} vs CA #{ac})#{bardic_tag(s)}"
  end

  defp describe_swing(%{kind: k, d20: d20, total: total, dmg: dmg} = s, weapon, ac) do
    verb = if k == :crit, do: "CRÍTICO", else: "acierta"

    "#{verb} (d20 #{d20}: #{total} vs CA #{ac}) por #{dmg} de daño #{weapon.damage_type}#{sneak_tag(s)}#{rage_tag(s)}#{mark_tag(s)}#{smite_tag(s)}#{bardic_tag(s)}"
  end

  defp swing_amounts(swings), do: for(%{dmg: dmg} <- swings, dmg > 0, do: dmg)

  defp smite_amounts(swings), do: for(%{smite: n} <- swings, n > 0, do: n)

  defp pipe_attack_damage(target, swings, roller, roll_log, char, weapon_type) do
    {weapon_notes, weapon_change} =
      pipe_damage(target, swing_amounts(swings), roller, roll_log, char, weapon_type)

    char_after = Enum.reduce(swing_amounts(swings), char, &simulate_damage(&2, &1, weapon_type))

    {smite_notes, smite_change} =
      pipe_damage(target, smite_amounts(swings), roller, roll_log, char_after, "radiant")

    change = fn w ->
      with {:ok, w} <- weapon_change.(w) do
        smite_change.(w)
      end
    end

    {weapon_notes ++ smite_notes, change}
  end

  defp compose_smite_spend(attacker, slot, swings, change) do
    if is_integer(slot) and slot in 1..5 and Enum.any?(swings, &(&1.smite > 0)) do
      fn w ->
        with {:ok, w} <- change.(w),
             {:ok, w} <- World.consume_slot(attacker, slot).(w) do
          World.set_smite_slot(attacker, nil).(w)
        end
      end
    else
      change
    end
  end

  defp compose_concentration({:ok, msg, change}, caster, spell) do
    if Spells.concentration?(spell.name) do
      combined = fn w ->
        case change.(w) do
          {:ok, w2} -> World.set_concentration(caster, spell.name).(w2)
          error -> error
        end
      end

      {:ok, "#{msg} #{caster} concentra en #{spell.name}.", combined}
    else
      {:ok, msg, change}
    end
  end

  defp compose_concentration(result, _caster, _spell), do: result

  defp with_conc_damage(msg, target_name, amount, roller, roll_log, target_char, type) do
    {notes, change} = pipe_damage(target_name, [amount], roller, roll_log, target_char, type)
    {:ok, append_notes(msg, notes), change}
  end

  defp pipe_damage(_target, [], _roller, _roll_log, _char, _type), do: {[], noop()}

  defp pipe_damage(target, amounts, roller, roll_log, char, type) do
    amounts = Enum.filter(amounts, &(&1 > 0))

    {pairs, _char} =
      Enum.map_reduce(amounts, char, fn amount, c ->
        {note, break?, c2, clear_inspired?} =
          one_hit_concentration(c, amount, roller, roll_log, type)

        {{note, break?, clear_inspired?}, c2}
      end)

    notes = pairs |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1)
    flags = Enum.map(pairs, fn {_, break?, clear_inspired?} -> {break?, clear_inspired?} end)

    change = fn w ->
      Enum.reduce_while(Enum.zip(amounts, flags), {:ok, w}, fn {amount, {break?, clear_inspired?}},
                                                               {:ok, acc} ->
        case World.character(acc, target) do
          %Character{hp: hp} when hp <= 0 ->
            {:halt, {:ok, acc}}

          %Character{} ->
            case World.apply_damage(target, amount, type).(acc) do
              {:ok, next} ->
                next =
                  if break? do
                    case World.clear_concentration(target).(next) do
                      {:ok, cleared} -> cleared
                      _ -> next
                    end
                  else
                    next
                  end

                next =
                  if clear_inspired? do
                    case World.set_inspired(target, false).(next) do
                      {:ok, cleared} -> cleared
                      _ -> next
                    end
                  else
                    next
                  end

                {:cont, {:ok, next}}

              error ->
                {:halt, error}
            end

          nil ->
            {:halt, {:error, "no such character: #{target}"}}
        end
      end)
    end

    {notes, change}
  end

  defp one_hit_concentration(%Character{concentrating: nil} = c, amount, _roller, _roll_log, type) do
    {nil, false, simulate_damage(c, amount, type), false}
  end

  defp one_hit_concentration(%Character{} = c, amount, roller, roll_log, type) do
    incoming = Character.incoming_damage(c, amount, type)
    c2 = simulate_damage(c, amount, type)

    cond do
      c2.hp <= 0 ->
        {"#{c.name} cae a 0 pg y pierde la concentración en #{c.concentrating}.", true,
         %{c2 | concentrating: nil}, false}

      incoming > 0 ->
        dc = max(10, div(incoming, 2))
        {:roll, mode} = Conditions.save_mode(c, :con)
        inspired? = c.inspired == true

        {r, close} =
          RollLog.open(
            roll_log,
            roller,
            c.name,
            :save,
            "salvación de Constitución (concentración)"
          )

        {d20, total, _success?} = Combat.saving_throw(c, :con, dc, r, mode)
        {total, success?, bardic} = apply_inspired_vs_dc(c, total, dc, r)

        RollLog.close(close,
          total: total,
          against: {:dc, dc},
          outcome: if(success?, do: :success, else: :failure)
        )

        bardic_bit = if bardic != 0, do: " +#{bardic} inspiración", else: ""
        c2 = if inspired?, do: %{c2 | inspired: false}, else: c2

        if success? do
          {"#{c.name} mantiene la concentración en #{c.concentrating} (d20 #{d20}: #{total} vs CD #{dc}#{bardic_bit}).",
           false, c2, inspired?}
        else
          {"#{c.name} pierde la concentración en #{c.concentrating} (d20 #{d20}: #{total} vs CD #{dc}#{bardic_bit}).",
           true, %{c2 | concentrating: nil}, inspired?}
        end

      true ->
        {nil, false, c2, false}
    end
  end

  defp simulate_damage(%Character{} = c, amount, type) do
    incoming = Character.incoming_damage(c, amount, type)
    temp = c.temp_hp || 0
    absorbed = min(temp, incoming)
    rest = incoming - absorbed
    %{c | temp_hp: temp - absorbed, hp: max(0, (c.hp || 0) - rest)}
  end

  defp append_notes(msg, []), do: msg
  defp append_notes(msg, notes), do: msg <> " " <> Enum.join(notes, " ")

  @incapacitating_ally ~w(unconscious incapacitated stunned paralyzed petrified)

  defp sneak_opts(world, attacker, attacker_name, target_name, weapon, mode) do
    dice = Progression.sneak_attack_dice(attacker.class, attacker.level)
    weapon_ok? = weapon.finesse == true or weapon.ranged == true

    circumstance? =
      case mode do
        :disadvantage -> false
        :advantage -> true
        _ -> conscious_ally?(world, attacker, attacker_name, target_name)
      end

    if dice > 0 and weapon_ok? and circumstance?, do: %{dice: dice}, else: nil
  end

  defp conscious_ally?(
         %World{characters: chars},
         %Character{} = attacker,
         attacker_name,
         target_name
       ) do
    Enum.any?(chars, fn {name, c} ->
      name != attacker_name and name != target_name and c.side == attacker.side and
        (c.hp || 0) > 0 and
        not Enum.any?(Character.condition_names(c), &(&1 in @incapacitating_ally))
    end)
  end

  defp sneak_damage(nil, _kind, _roller), do: 0

  defp sneak_damage(%{dice: n}, kind, roller) when n > 0 do
    count = if kind == :crit, do: n * 2, else: n
    Enum.sum(for _ <- 1..count, do: roller.(6))
  end

  defp sneak_tag(%{sneak: n}) when is_integer(n) and n > 0, do: " (+#{n} sneak)"
  defp sneak_tag(_), do: ""

  @mark_prefix "hunter's mark:"

  # D55: the attacker concentrates on "hunter's mark:<prey>" — exact
  # case-insensitive name match, never fuzzy (a similar name doesn't count).
  defp mark_target?(%Character{concentrating: conc}, target)
       when is_binary(conc) and is_binary(target) do
    conc = String.downcase(conc)

    if String.starts_with?(conc, @mark_prefix) do
      String.replace_prefix(conc, @mark_prefix, "") == String.downcase(target)
    else
      false
    end
  end

  defp mark_target?(_, _), do: false

  defp mark_damage(false, _kind, _roller), do: 0

  defp mark_damage(true, kind, roller) do
    count = if kind == :crit, do: 2, else: 1
    Enum.sum(for _ <- 1..count, do: roller.(6))
  end

  defp mark_tag(%{mark: n}) when is_integer(n) and n > 0, do: " (+#{n} presa marcada)"
  defp mark_tag(_), do: ""

  defp rage_bonus(%Character{raging: true, level: level}, weapon) when weapon.ranged != true do
    Progression.rage_damage(level)
  end

  defp rage_bonus(_, _), do: 0

  defp rage_tag(%{rage: n}) when is_integer(n) and n > 0, do: " (+#{n} furia)"
  defp rage_tag(_), do: ""

  defp smite_opts(%Character{class: "paladin", smite_slot: slot}, weapon)
       when is_integer(slot) and slot in 1..5 and weapon.ranged != true,
       do: slot

  defp smite_opts(_, _), do: nil

  defp smite_roll(nil, _target, _attacker, _tname, _roller, _roll_log), do: {0, 0}

  defp smite_roll(slot, target, attacker, tname, roller, roll_log) when is_integer(slot) do
    n = smite_dice(slot, target)

    {r, close} =
      RollLog.open(
        roll_log,
        roller,
        attacker,
        :damage,
        "Castigo divino (radiante) a #{tname}"
      )

    amount = Enum.sum(for _ <- 1..n, do: r.(8))
    RollLog.close(close, total: amount, against: nil, outcome: nil)
    {amount, n}
  end

  defp smite_dice(slot, %Character{race: race}) do
    base = min(slot + 1, 5)
    extra = if smite_foe?(race), do: 1, else: 0
    min(base + extra, 6)
  end

  defp smite_foe?(race) when is_binary(race) do
    String.downcase(race) in ["undead", "fiend"]
  end

  defp smite_foe?(_), do: false

  defp smite_tag(%{smite: n, smite_dice: d}) when is_integer(n) and n > 0 do
    " (+#{n} smite #{d}d8 radiante)"
  end

  defp smite_tag(_), do: ""

  defp bardic_tag(%{bardic: n}) when is_integer(n) and n > 0, do: " (+#{n} inspiración)"
  defp bardic_tag(_), do: ""

  defp apply_inspired_attack(true, _kind, d20, total, ac, roller) do
    bonus = roller.(6)
    new_total = total + bonus

    new_kind =
      cond do
        d20 == 20 -> :crit
        d20 == 1 -> :miss
        new_total >= ac -> :hit
        true -> :miss
      end

    {new_kind, new_total, bonus}
  end

  defp apply_inspired_attack(_, kind, _d20, total, _ac, _roller), do: {kind, total, 0}

  defp apply_inspired_vs_dc(%Character{inspired: true}, total, dc, roller) do
    bonus = roller.(6)
    new_total = total + bonus
    {new_total, new_total >= dc, bonus}
  end

  defp apply_inspired_vs_dc(_, total, dc, _), do: {total, total >= dc, 0}

  defp apply_inspired_death(%Character{inspired: true}, result, roller) do
    d20 = elem(result, 1)
    bonus = roller.(6)

    new_result =
      case result do
        {:revive, _, _, _} -> result
        {:crit_fail, _, _, _} -> result
        _ when d20 + bonus >= 10 -> {:success, d20, 0, 1}
        _ -> {:fail, d20, 1, 0}
      end

    {new_result, bonus}
  end

  defp apply_inspired_death(_, result, _), do: {result, 0}

  defp compose_inspired_clear(_name, false, change), do: change

  defp compose_inspired_clear(name, true, change) do
    fn w ->
      with {:ok, w} <- change.(w) do
        World.set_inspired(name, false).(w)
      end
    end
  end

  # D57: an attack (or attack spell) reveals a hidden attacker — strip
  # "hidden" once the change resolves, hit or miss.
  defp compose_hidden_clear(_name, false, change), do: change

  defp compose_hidden_clear(name, true, change) do
    fn w ->
      with {:ok, w} <- change.(w) do
        World.remove_condition(name, "hidden").(w)
      end
    end
  end

  defp find_weapon(%Character{weapons: weapons}, name), do: match_named(weapons, name)

  defp find_spell(%Character{spells: spells}, name), do: match_named(spells, name)

  defp false_life?(%{name: name, dice: dice}) when dice in [nil, ""] and is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[\s_-]+/, "")
    |> Kernel.==("falselife")
  end

  defp false_life?(_), do: false

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

  defp compose_rest(name, heal_amount, restore_slots?) do
    fn w ->
      with {:ok, w} <- World.heal(name, heal_amount).(w),
           {:ok, w} <- maybe_restore_slots(w, name, restore_slots?),
           {:ok, w} <- World.set_second_wind_used(name, false).(w),
           {:ok, w} <- World.set_action_surge_used(name, false).(w),
           {:ok, w} <- World.set_channel_divinity_used(name, false).(w),
           {:ok, w} <- World.restore_ki(name).(w) do
        {:ok, w}
      end
    end
  end

  defp compose_long_rest(name, heal_amount) do
    fn w ->
      with {:ok, w} <- compose_rest(name, heal_amount, true).(w),
           {:ok, w} <- World.restore_lay_on_hands(name).(w),
           {:ok, w} <- World.restore_divine_sense(name).(w),
           {:ok, w} <- World.restore_bardic_inspiration(name).(w),
           {:ok, w} <- World.set_inspired(name, false).(w),
           {:ok, w} <- World.set_arcane_recovery_used(name, false).(w),
           {:ok, w} <- World.restore_sorcery_points(name).(w) do
        {:ok, w}
      end
    end
  end

  defp compose_mark_action_surge(who, change) do
    fn w ->
      with {:ok, w} <- change.(w) do
        World.set_action_surge_used(who, true).(w)
      end
    end
  end

  defp compose_spend_ki(who, change) do
    fn w ->
      with {:ok, w} <- change.(w) do
        World.spend_ki(who, 1).(w)
      end
    end
  end

  # Font of Magic (D56): spend points first, then grant the slot. The chain
  # re-validates, so a mid-chain failure leaves the world untouched.
  defp compose_create_slot(who, level, cost) do
    fn w ->
      with {:ok, w} <- World.spend_sorcery_points(who, cost).(w) do
        World.gain_slot(who, level).(w)
      end
    end
  end

  defp compose_convert_slot(who, level) do
    fn w ->
      with {:ok, w} <- World.consume_slot(who, level).(w) do
        World.gain_sorcery_points(who, level).(w)
      end
    end
  end

  defp maybe_restore_slots(w, name, true), do: World.restore_slots(name).(w)
  defp maybe_restore_slots(w, _name, false), do: {:ok, w}

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
