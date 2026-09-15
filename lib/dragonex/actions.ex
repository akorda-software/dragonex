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
    Rules.Skills,
    Rules.Upcast,
    SpellSlots,
    Weapon,
    World
  }

  alias Dragonex.Heroes.{Progression, Spells, Translations}

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
  Flurry never benefit from the mark. Savage Attacks (D69) adds one extra
  weapon die to a half-orc's melee crit (inside `Combat.damage_roll`).
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
            # D61: the attack target's concentration saves ride this aura.
            aura = aura_save_bonus(world, target)

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
              pipe_attack_damage(target, swings, roller, roll_log, t, weapon.damage_type, aura)

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

  Upcasting (D74, M58): `cast_level` (optional, `nil` = the spell's base
  level — backwards compatible) spends ONE slot of that exact level and scales
  the spell with the curated RAW table in `Rules.Upcast` (`fireball` with a
  4th-level slot rolls 9d6). Spells absent from the table never scale (the
  slot is still the requested one). Save DC and concentration are unchanged
  (RAW). Errors mutate nothing: `cast_level` below the base level, above 9,
  non-integer, upcast cantrip, or no slot left of the REQUESTED level.
  """
  @spec spell(
          World.t(),
          String.t(),
          String.t(),
          String.t(),
          roller(),
          RollLog.t() | nil,
          non_neg_integer() | nil
        ) :: result()
  def spell(
        world,
        caster_name,
        spell_name,
        target_name,
        roller,
        roll_log \\ nil,
        cast_level \\ nil
      ) do
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

      World.character(world, caster_name).wild_shape != nil ->
        {:error, "#{caster_name} no puede conjurar en forma de bestia"}

      true ->
        c = World.character(world, caster_name)
        t = World.character(world, target_name)

        case find_spell(c, spell_name) do
          nil ->
            {:error, "#{caster_name} no conoce #{spell_name}"}

          spell ->
            with {:ok, cast_level} <- validate_cast_level(spell, cast_level) do
              # Check a slot of the REQUESTED level for leveled spells
              # (cantrips are free; D74 upcasting spends the asked slot).
              if spell.level > 0 and not World.has_slot?(world, caster_name, cast_level) do
                {:error,
                 "a #{caster_name} no le quedan casillas de hechizo de nivel #{cast_level} " <>
                   "(debe descansar para recuperarlas). Los trucos siempre están disponibles."}
              else
                # D74: one combined dice expression (base + extra) rides the
                # normal resolution paths — same roll log, same halving on a
                # save, crit doubles the extra dice too.
                scaled = Upcast.scaled_spell(spell, cast_level)

                result =
                  case twinned_target(world, c, caster_name, target_name) do
                    nil ->
                      resolve_spell(
                        world,
                        c,
                        caster_name,
                        t,
                        target_name,
                        scaled,
                        roller,
                        roll_log
                      )

                    twin_name ->
                      resolve_twinned(
                        world,
                        c,
                        caster_name,
                        target_name,
                        twin_name,
                        scaled,
                        roller,
                        roll_log
                      )
                  end

                result
                |> compose_slot_consumption(caster_name, cast_level)
                |> compose_concentration(caster_name, spell)
                |> tag_upcast_level(caster_name, spell, cast_level)
              end
            end
        end
    end
  end

  # D74: validate the requested cast level against the spell's base. nil →
  # base (backwards compat). Cantrips never upcast (they cost no slot). All
  # errors leave the world untouched.
  defp validate_cast_level(%{level: 0}, nil), do: {:ok, 0}

  defp validate_cast_level(%{level: 0}, cast_level)
       when is_integer(cast_level) and cast_level >= 1,
       do: {:error, "los trucos (nivel 0) no se pueden lanzar a nivel superior"}

  defp validate_cast_level(%{level: base}, nil) when base > 0, do: {:ok, base}

  defp validate_cast_level(%{level: base}, cast_level) do
    cond do
      not is_integer(cast_level) ->
        {:error,
         "nivel de lanzamiento inválido (cast_level): #{inspect(cast_level)} " <>
           "— debe ser un entero entre #{base} y 9"}

      cast_level < base ->
        {:error,
         "no se puede lanzar a nivel #{cast_level}: el nivel mínimo de este hechizo es #{base}"}

      cast_level > 9 ->
        {:error, "nivel de lanzamiento inválido: #{cast_level} (máximo 9)"}

      true ->
        {:ok, cast_level}
    end
  end

  # D74: "X conjura Y (nivel N); …" — one tag right after the spell name,
  # covering every resolution branch (save/attack/automatic/heal/utility and
  # the Twinned outer message).
  defp tag_upcast_level({:ok, msg, change}, caster_name, spell, cast_level)
       when is_integer(cast_level) and cast_level > 0 and cast_level > spell.level do
    prefix = "#{caster_name} conjura #{spell.name}"
    {:ok, String.replace_prefix(msg, prefix, prefix <> " (nivel #{cast_level})"), change}
  end

  defp tag_upcast_level(result, _caster_name, _spell, _cast_level), do: result

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
        # D61 Aura of Protection applies to death saves (RAW).
        aura = aura_save_bonus(world, name)
        {r, close} = RollLog.open(roll_log, roller, name, :death_save, "salvación de muerte")
        result = Combat.death_save(r, aura)
        {result, bardic} = apply_inspired_death(c, result, r, aura)

        RollLog.close(close,
          total: elem(result, 1) + aura,
          against: {:dc, 10},
          outcome: elem(result, 0)
        )

        change = compose_inspired_clear(name, inspired?, World.apply_death_save(name, result))
        {:ok, describe_death_save(name, result, bardic, aura), change}
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
  Aura of Protection (D61) adds to the save; Aura of Courage (D62) makes
  a target sharing a side with a conscious paladin L10+ immune (the message
  reports it; no condition lands).
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
        {failed, saved, immune} = turn_undead_resolutions(world, who, dc, roller, roll_log)

        {:ok, turn_undead_message(who, dc, failed, saved, immune),
         compose_turn_undead(who, failed, saved)}
    end
  end

  defp turn_undead_resolutions(world, who, dc, roller, roll_log) do
    world
    |> turn_undead_targets(who)
    |> Enum.reduce({[], [], []}, fn target, {failed, saved, immune} ->
      cond do
        # D62 Aura of Courage: a same-side ally of a conscious paladin L10+
        # can't be frightened — no save needed (nothing would land).
        World.courage_immune?(world, target.name) ->
          {failed, saved, immune ++ [target.name]}

        true ->
          # D68: {saved?, indomitable_tag} — the tag rides the entry so the
          # clause renders the reroll and compose marks the spent flag.
          {success?, indom} = turn_undead_save_success?(world, target, dc, roller, roll_log)
          entry = {target.name, indom}

          if success? do
            {failed, saved ++ [entry], immune}
          else
            {failed ++ [entry], saved, immune}
          end
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

  defp turn_undead_save_success?(world, target, dc, roller, roll_log) do
    # D71 Gnome Cunning: divine magic counts (ADR D71). Today no turn_undead
    # target can be a gnome (race must be "undead"), but the contract holds.
    case Conditions.save_mode(target, :wis, :normal,
           gnome_advantage: gnome_cunning?(target, :wis)
         ) do
      # No die was rolled — Indomitable (D68) never rerolls an auto-fail.
      :auto_fail ->
        {false, nil}

      {:roll, save_mode} ->
        {r, close} =
          RollLog.open(
            roll_log,
            roller,
            target.name,
            :save,
            "salvación de Sabiduría contra Expulsar no-muertos"
          )

        {_d20, total, _success?} = Combat.saving_throw(target, :wis, dc, r, save_mode)
        # D61 Aura of Protection: covers this Wisdom save too.
        aura = aura_save_bonus(world, target.name)
        total = total + aura

        # D68 Indomitable: a fighter L9+ undead rerolls a failed WIS save
        # once per long rest — the reroll decides (aura re-applies).
        {_d20_2, total, success?, indom} =
          maybe_indomitable(target, :wis, dc, r, save_mode, {nil, total, total >= dc}, aura)

        RollLog.close(close,
          total: total,
          against: {:dc, dc},
          outcome: if(success?, do: :success, else: :failure)
        )

        {success?, indom}
    end
  end

  defp turn_undead_message(who, dc, [], [], []) do
    "#{who} usa Expulsar no-muertos (CD #{dc}) y no hay no-muertos que Expulsar no-muertos pueda afectar (usos restantes 0)."
  end

  defp turn_undead_message(who, dc, failed, saved, immune) do
    bits =
      [frightened_clause(failed), saved_clause(saved), immune_clause(immune)]
      |> Enum.reject(&is_nil/1)

    "#{who} usa Expulsar no-muertos (CD #{dc}): #{Enum.join(bits, "; ")} (usos restantes 0)."
  end

  # Entries are {name, indomitable_tag} (D68): the tag renders next to the
  # name when the reroll fired ("X (Indomitable: 9→15)"), nothing otherwise.
  defp frightened_clause([]), do: nil

  defp frightened_clause([{name, tag}]), do: "#{name}#{indom_suffix(tag)} queda asustado"

  defp frightened_clause(entries) do
    "#{turn_names(entries)} quedan asustados"
  end

  defp saved_clause([]), do: nil

  defp saved_clause([{name, tag}]), do: "#{name}#{indom_suffix(tag)} supera la salvación"

  defp saved_clause(entries), do: "#{turn_names(entries)} superan la salvación"

  defp turn_names(entries),
    do: Enum.map_join(entries, ", ", fn {name, tag} -> "#{name}#{indom_suffix(tag)}" end)

  # D62: immunity is an outcome, not an error — the message says so.
  defp immune_clause([]), do: nil

  defp immune_clause([name]), do: "#{name} es inmune al miedo (Aura de Coraje)"

  defp immune_clause(names), do: "#{Enum.join(names, ", ")} son inmunes al miedo (Aura de Coraje)"

  defp compose_turn_undead(who, failed, saved) do
    # D68: every target whose Indomitable reroll fired (saved OR frightened)
    # spends the flag.
    rerolled = for {name, tag} <- failed ++ saved, tag != nil, do: name

    fn w ->
      with {:ok, w} <- World.set_channel_divinity_used(who, true).(w),
           {:ok, w} <- mark_indomitable_all(w, rerolled) do
        Enum.reduce_while(failed, {:ok, w}, fn {name, _tag}, {:ok, acc} ->
          case World.apply_condition(name, "frightened").(acc) do
            {:ok, w2} -> {:cont, {:ok, w2}}
            err -> {:halt, err}
          end
        end)
      end
    end
  end

  defp mark_indomitable_all(w, []), do: {:ok, w}

  defp mark_indomitable_all(w, [name | rest]) do
    case World.set_indomitable(name, true).(w) do
      {:ok, w2} -> mark_indomitable_all(w2, rest)
      error -> error
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

  @wild_shape_names_es %{"cat" => "gato", "wolf" => "lobo", "black_bear" => "oso negro"}

  @doc """
  Wild Shape (5e, D63): a druid of level 2+ transforms into a beast from
  `Monsters.wild_shape_beasts/0`, spending 1 use (2 per rest).

  CR gate: L2–3 → max ND 1/4 (cat, wolf); L4+ → max ND 1/2 (all). The
  engine saves the druid's original form and applies the beast's
  str/dex/con/hp/max_hp/ac/weapons — mental scores, identity, proficiencies,
  conditions and concentration are kept (RAW). Errors (no mutation): missing
  who, downed, not a druid, L1, already transformed, unknown beast, CR above
  the level gate, 0 uses.
  """
  @spec wild_shape(World.t(), String.t(), String.t()) :: result()
  def wild_shape(world, who, beast_key) do
    beasts = Dragonex.Monsters.wild_shape_beasts()

    case World.character(world, who) do
      nil ->
        {:error, "no existe el personaje: #{who}"}

      %Character{hp: hp} when hp <= 0 ->
        {:error, "#{who} está caído (0 pg) y no puede transformarse"}

      %Character{class: class} when class != "druid" ->
        {:error, "#{who} no es druida y no puede usar Forma salvaje"}

      %Character{level: level} when not is_integer(level) or level < 2 ->
        {:error, "#{who} no tiene Forma salvaje (nivel 2)"}

      %Character{wild_shape: ws} when ws != nil ->
        {:error, "#{who} ya está en forma de bestia"}

      %Character{wild_shape_uses: uses} = c ->
        uses = uses || 0
        cr = Map.get(beasts, beast_key)
        max = wild_shape_max_cr(c.level)

        cond do
          is_nil(cr) ->
            {:error,
             "bestia desconocida: #{beast_key} (disponibles: #{Enum.join(Enum.sort(Map.keys(beasts)), ", ")})"}

          cr > max ->
            {:error,
             "#{who} no puede adoptar la forma de #{beast_key} (ND #{cr}) a nivel #{c.level} (máximo ND #{max})"}

          uses < 1 ->
            {:error, "#{who} no tiene usos de Forma salvaje (se recargan con un descanso)"}

          true ->
            beast = Dragonex.Monsters.get(beast_key).(name: who)
            name_es = Map.get(@wild_shape_names_es, beast_key, beast_key)

            {:ok,
             "#{who} adopta la forma de un #{name_es} (usos de forma salvaje restantes: #{uses - 1}).",
             World.transform_wild_shape(who, beast_key, beast)}
        end
    end
  end

  @doc """
  End Wild Shape (5e, D63): the transformed druid returns to their original
  form with the exact hit points they had when transforming. Errors (no
  mutation): missing who, not transformed. Everything else (attack with the
  beast weapons, ability checks, rests) works normally while transformed;
  only `cast_spell` is blocked.
  """
  @spec end_wild_shape(World.t(), String.t()) :: result()
  def end_wild_shape(world, who) do
    case World.character(world, who) do
      nil ->
        {:error, "no existe el personaje: #{who}"}

      %Character{wild_shape: nil} ->
        {:error, "#{who} no está en forma de bestia"}

      %Character{wild_shape: %{} = ws} ->
        {:ok, "#{who} vuelve a su forma original (PG #{ws[:orig_hp]}).",
         World.revert_wild_shape(who)}
    end
  end

  # CR gate (D63, RAW): L2–4 → máx 1/4; L5+ → máx 1/2.
  defp wild_shape_max_cr(level) when is_integer(level) and level >= 5, do: 0.5
  defp wild_shape_max_cr(_), do: 0.25

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
        # D61: the target's concentration saves ride this aura.
        aura = aura_save_bonus(world, target)

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
          pipe_attack_damage(target, swings, roller, roll_log, t, weapon.damage_type, aura)

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
  is in `skill_proficiencies`, DOUBLED with stealth Expertise D73)`, mode from
  `Conditions.check_mode/3` —
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

    # D73: stealth expertise doubles the proficiency in this roll too.
    {d20, total, success?, lucky} =
      Combat.ability_check_tagged(rogue, :dex, dc, r, stealth?, mode, "stealth")

    RollLog.close(close,
      total: total,
      against: {:dc, dc},
      outcome: if(success?, do: :success, else: :failure)
    )

    dex_mod = Character.modifier(rogue, :dex)
    {prof, prof_kind} = Combat.check_proficiency(rogue, stealth?, "stealth")

    breakdown =
      ["1d20(#{d20})"]
      |> then(fn p -> if dex_mod != 0, do: p ++ ["#{signed(dex_mod)}"], else: p end)
      |> then(fn p ->
        cond do
          prof == 0 -> p
          prof_kind == :expert -> p ++ ["+#{prof} (experto)"]
          true -> p ++ ["+#{prof}"]
        end
      end)
      |> Enum.join("")

    verdict = if success?, do: "oculto", else: "falla y sigue a la vista"

    {:ok, "#{who} se esconde: #{breakdown}=#{total} vs #{dc} — #{verdict}#{lucky_suffix(lucky)}",
     if(success?, do: World.apply_condition(who, "hidden"), else: noop())}
  end

  @doc """
  Uncanny Dodge (5e, D64): a rogue of level 5+ arms a defensive posture.

  Without reactions or rounds in the engine, this is modeled as a flag
  (pattern `inspired`/`reckless`): arming is free at any moment; the LLM
  decides WHEN. While armed, `World.apply_damage/3` halves ANY incoming
  damage (floor) at entry — before resistances (D38) and temp_hp (D36) —
  and consumes the flag. Stacks with Evasión (D59): half of half. Errors
  do not mutate.
  """
  @spec start_uncanny_dodge(World.t(), String.t()) :: result()
  def start_uncanny_dodge(world, who) do
    case World.character(world, who) do
      nil ->
        {:error, "no existe el personaje: #{who}"}

      %Character{hp: hp} when hp <= 0 ->
        {:error, "#{who} está caído (0 pg) y no puede prepararse para esquivar"}

      %Character{class: class} when class != "rogue" ->
        {:error, "#{who} no es pícaro y no puede usar Esquiva asombrosa"}

      %Character{level: level} when not is_integer(level) or level < 5 ->
        {:error, "#{who} no tiene Esquiva asombrosa (nivel 5)"}

      %Character{uncanny_dodge: true} ->
        {:error, "#{who} ya tiene Esquiva asombrosa armada"}

      %Character{} ->
        {:ok,
         "#{who} se prepara para esquivar (Uncanny Dodge armado: el próximo daño se reduce a la mitad).",
         World.set_uncanny_dodge(who, true)}
    end
  end

  @doc """
  Expertise (5e, D73): a rogue (L1+) or bard (L3+) deepens ONE trained
  skill — recorded in `Character.expertise`, doubled by the check routes
  (`check/7` and `cunning_action_hide` via `Combat.check_proficiency/3`).

  Cupo por clase y nivel (`Progression.expertise_count/2`: rogue 2 desde
  L1 y 4 desde L6; bard 2 desde L3 y 4 desde L10; resto 0). Se elige una
  vez por skill, en cualquier momento una vez elegible (la tool cubre el
  momento — nada de integración con level-up). JoaT (D60) nunca aplica a
  una skill con Expertise (ya es competente). Errors (NO mutan): who
  inexistente, caído, clase sin Expertise, nivel insuficiente para el
  PRIMER cupo (bardo L1–2), skill desconocida, skill sin competencia,
  skill ya elegida, cupo agotado.
  """
  @spec gain_expertise(World.t(), String.t(), atom() | String.t()) :: result()
  def gain_expertise(world, who, skill) do
    c = World.character(world, who)

    cond do
      is_nil(c) ->
        {:error, "no existe el personaje: #{who}"}

      (c.hp || 0) <= 0 ->
        {:error, "#{who} está caído (0 pg) y no puede elegir Expertise"}

      c.class not in ["rogue", "bard"] ->
        {:error, "#{who} no puede elegir Expertise (sólo pícaros y bardos)"}

      not expertise_eligible_level?(c) ->
        {:error, "#{who} aún no tiene Expertise (llega a nivel 3)"}

      not Skills.known?(skill) ->
        {:error, unknown_expertise_error(skill)}

      not skill_trained?(c, Skills.normalize(skill)) ->
        {:error,
         "#{who} no tiene competencia en #{Translations.skill(Skills.normalize(skill))} " <>
           "(Expertise sólo aplica a skills entrenadas)"}

      skill_expertised?(c, Skills.normalize(skill)) ->
        {:error, "#{who} ya tiene Expertise en #{Translations.skill(Skills.normalize(skill))}"}

      length(c.expertise || []) >= Progression.expertise_count(c.class, c.level) ->
        {:error,
         "#{who} ya ha elegido sus #{Progression.expertise_count(c.class, c.level)} " <>
           "expertises (" <>
           Enum.map_join(c.expertise || [], ", ", &Translations.skill/1) <> ")"}

      true ->
        normalized = Skills.normalize(skill)
        cap = Progression.expertise_count(c.class, c.level)
        position = length(c.expertise || []) + 1

        {:ok,
         "#{who} profundiza su dominio de #{Translations.skill(normalized)} " <>
           "(Expertise #{position}/#{cap}).", World.add_expertise(who, normalized)}
    end
  end

  # Bardo L1–2: sin cupo aún (el pícaro lo tiene desde L1, las demás
  # clases ya se cortaron arriba).
  defp expertise_eligible_level?(%Character{class: "bard", level: level}),
    do: is_integer(level) and level >= 3

  defp expertise_eligible_level?(_), do: true

  defp skill_expertised?(%Character{expertise: list}, skill) when is_list(list) do
    Enum.any?(list, fn e -> is_binary(e) and Skills.normalize(e) == skill end)
  end

  defp skill_expertised?(_, _), do: false

  defp unknown_expertise_error(skill) do
    "skill desconocida: #{inspect(skill)} — usa un skill entrenado " <>
      "(#{Skills.examples()}, …)"
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

  # Normalized membership (D60): sheets store canonical snake_case keys, but
  # custom/legacy data may differ in case or separators.
  defp skill_trained?(%Character{skill_proficiencies: profs}, skill) when is_list(profs) do
    Enum.any?(profs, fn p -> is_binary(p) and Skills.normalize(p) == skill end)
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
  Metamagic (5e, D65): a sorcerer of level 3+ spends sorcery points to arm
  ONE option that the NEXT qualifying spell they cast will apply and
  consume:

    * `"empowered"` (1 punto) — the first `max(1, CHA mod)` damage dice
      of the spell roll twice, keeping the higher;
    * `"heightened"` (3 puntos, `target` required) — that target's save
      against the spell is resolved with disadvantage;
    * `"twinned"` (2 puntos, `target` required) — the same spell also
      resolves against the armed second target.

  Only ONE option may be armed at a time and there is no un-arm nor
  refund: a spell that doesn't qualify leaves it armed. Rests never touch
  it. Errors (nothing spent): missing who, downed, not a sorcerer,
  level < 3, unknown option, already armed, insufficient points,
  heightened without target, twinned without/inexistent/self target.
  """
  @spec arm_metamagic(World.t(), String.t(), String.t(), String.t()) :: result()
  def arm_metamagic(world, who, option, target \\ "")

  def arm_metamagic(world, who, option, target) do
    sorcerer = World.character(world, who)
    opt = normalize_metamagic_option(option)
    target = if is_binary(target), do: String.trim(target), else: ""

    cond do
      is_nil(sorcerer) ->
        {:error, "no existe el personaje: #{who}"}

      (sorcerer.hp || 0) <= 0 ->
        {:error, "#{who} está caído (0 pg) y no puede usar Metamagia"}

      sorcerer.class != "sorcerer" ->
        {:error, "#{who} no es hechicero y no puede usar Metamagia"}

      not is_integer(sorcerer.level) or sorcerer.level < 3 ->
        {:error, "#{who} no tiene Metamagia (nivel 3)"}

      is_nil(opt) ->
        {:error,
         "opción de Metamagia desconocida: #{option} " <>
           "(válidas: empowered, heightened, twinned)"}

      sorcerer.metamagic != nil ->
        {:error,
         "#{who} ya tiene Metamagia armada: " <>
           "#{metamagic_es(sorcerer.metamagic)} — se consume con su próximo " <>
           "hechizo que califique (espera a que se consuma antes de armar otra)"}

      (sorcerer.sorcery_points || 0) < metamagic_cost(opt) ->
        {:error,
         "#{who} no tiene suficientes puntos de hechicería " <>
           "(le quedan #{sorcerer.sorcery_points || 0}; " <>
           "#{metamagic_es(opt)} cuesta #{metamagic_cost(opt)})"}

      opt == "heightened" and target == "" ->
        {:error, "heightened requiere un objetivo (target)"}

      opt == "twinned" and target == "" ->
        {:error, "twinned requiere un segundo objetivo (target)"}

      opt == "twinned" and is_nil(World.character(world, target)) ->
        {:error, "no existe el objetivo: #{target}"}

      opt == "twinned" and target == who ->
        {:error, "twinned no puede gemarse a sí mismo (target debe ser otro personaje)"}

      true ->
        cost = metamagic_cost(opt)
        remaining = (sorcerer.sorcery_points || 0) - cost

        points_label =
          if cost == 1, do: "1 punto de hechicería", else: "#{cost} puntos de hechicería"

        target_bit = if target == "", do: "", else: " sobre #{target}"

        {:ok,
         "#{who} arma Metamagia: #{metamagic_es(opt)} (#{points_label}, quedan #{remaining})" <>
           "#{target_bit}. El próximo hechizo que califique la aplicará.",
         compose_arm_metamagic(who, cost, opt, target)}
    end
  end

  defp compose_arm_metamagic(who, cost, opt, target) do
    armed = %{option: opt, target: if(target == "", do: nil, else: target)}

    fn w ->
      with {:ok, w} <- World.spend_sorcery_points(who, cost).(w) do
        World.set_metamagic(who, armed).(w)
      end
    end
  end

  @metamagic_costs %{"empowered" => 1, "heightened" => 3, "twinned" => 2}

  defp metamagic_cost(opt) when is_binary(opt), do: Map.get(@metamagic_costs, opt, 0)

  defp normalize_metamagic_option(option) when is_binary(option) do
    case String.downcase(String.trim(option)) do
      opt when opt in ~w(empowered heightened twinned) -> opt
      _ -> nil
    end
  end

  defp normalize_metamagic_option(_), do: nil

  defp metamagic_es(%{option: opt}), do: metamagic_es(opt)

  defp metamagic_es("empowered"), do: "Empowered"
  defp metamagic_es("heightened"), do: "Heightened"
  defp metamagic_es("twinned"), do: "Twinned"
  defp metamagic_es(opt), do: opt

  @doc """
  Breath Weapon (5e, D70): a dragonborn exhales dragon breath at `target`.

  Damage dice by level (`Progression.breath_dice/1`), type "fire" (no
  draconic ancestry in the engine — ADR D70). `target` rolls a DEX save
  vs DC `8 + CON mod + proficiency` of the dragonborn: success halves
  the damage (floor), failure takes it all. The use is spent on EVERY
  resolution (save or not — it is an area breath, D70); errors (missing
  who/target, downed who, not a dragonborn, already used) mutate
  nothing. Combat allowed; a downed target may be hit. Not a spell: no
  slot, no concentration set, works in Wild Shape (racial, RAW).
  """
  @spec breath_weapon(World.t(), String.t(), String.t(), roller(), RollLog.t() | nil) ::
          result()
  def breath_weapon(world, who, target, roller, roll_log \\ nil) do
    cond do
      is_nil(World.character(world, who)) ->
        {:error, "no existe el personaje: #{who}"}

      is_nil(World.character(world, target)) ->
        {:error, "no existe el objetivo: #{target}"}

      (World.character(world, who).hp || 0) <= 0 ->
        {:error, "#{who} está caído (0 pg) y no puede usar su aliento"}

      not dragonborn?(World.character(world, who)) ->
        {:error, "#{who} no es dragontino y no tiene aliento de dragón"}

      World.character(world, who).breath_weapon_used == true ->
        {:error, "#{who} ya ha usado su aliento de dragón (se recarga con un descanso)"}

      true ->
        resolve_breath_weapon(world, who, target, roller, roll_log)
    end
  end

  defp resolve_breath_weapon(world, who, target_name, roller, roll_log) do
    source = World.character(world, who)
    t = World.character(world, target_name)
    level = source.level || 1
    dice = Progression.breath_dice(level)
    # CD pattern of spells, keyed on the dragonborn's CON (D70).
    dc = 8 + Ability.proficiency(level) + Character.modifier(source, :con)
    # D61: the aura covers this save (RAW — all saves) and the target's
    # concentration saves triggered by the breath damage.
    aura = aura_save_bonus(world, target_name)

    case Conditions.save_mode(t, :dex) do
      :auto_fail ->
        {r, close_dmg} =
          RollLog.open(roll_log, roller, who, :damage, "daño de aliento de dragón (fire)")

        full = Dice.roll_expr(dice, r)
        RollLog.close(close_dmg, total: full, against: nil, outcome: nil)

        {:ok, msg, change} =
          with_conc_damage(
            "#{who} exhala aliento de dragón (fuego, usos restantes: 0): " <>
              "#{target_name} falla automáticamente la salvación de Destreza vs CD #{dc} — " <>
              "#{full} de daño fire.",
            target_name,
            full,
            roller,
            roll_log,
            t,
            "fire",
            aura
          )

        {:ok, msg, compose_breath_spend(who, change)}

      {:roll, save_mode} ->
        {r, close_save} =
          RollLog.open(
            roll_log,
            roller,
            target_name,
            :save,
            "salvación de Destreza contra aliento de dragón"
          )

        inspired? = t.inspired == true

        {d20, stotal, _success?, lucky} =
          Combat.saving_throw_tagged(t, :dex, dc, r, save_mode)

        stotal = stotal + aura
        {stotal, success?, bardic} = apply_inspired_vs_dc(t, stotal, dc, r)

        # D68 Indomitable: same save-site stack as spells — the reroll
        # rides the same mode (Danger Sense/conditions) and re-applies
        # the aura.
        {d20, stotal, success?, indom} =
          maybe_indomitable(t, :dex, dc, r, save_mode, {d20, stotal, success?}, aura)

        t = if indom, do: %{t | indomitable_used: true}, else: t

        RollLog.close(close_save,
          total: stotal,
          against: {:dc, dc},
          outcome: if(success?, do: :success, else: :failure)
        )

        {r2, close_dmg} =
          RollLog.open(roll_log, roller, who, :damage, "daño de aliento de dragón (fire)")

        full = Dice.roll_expr(dice, r2)
        RollLog.close(close_dmg, total: full, against: nil, outcome: nil)

        # D59 Evasión: RAW covers any DEX-save half-damage effect, spell or
        # not — the breath qualifies (ADR D70).
        evasion? = evasion?(t, %{save_ability: :dex})

        dmg =
          cond do
            success? and evasion? -> 0
            success? -> div(full, 2)
            evasion? -> div(full, 2)
            true -> full
          end

        bardic_bit = if bardic != 0, do: " +#{bardic} inspiración", else: ""
        aura_b = aura_bit(aura)
        lucky_b = lucky_suffix(lucky)
        indom_b = indom_suffix(indom)

        verdict =
          cond do
            success? and evasion? ->
              "supera la salvación de Destreza (d20 #{d20}#{lucky_b}#{indom_b}: #{stotal} vs CD #{dc}#{aura_b}#{bardic_bit})#{mode_tag(save_mode)} (Evasión: sin daño)"

            success? ->
              "supera la salvación de Destreza (d20 #{d20}#{lucky_b}#{indom_b}: #{stotal} vs CD #{dc}#{aura_b}#{bardic_bit})#{mode_tag(save_mode)}, mitad de daño"

            evasion? ->
              "falla la salvación de Destreza (d20 #{d20}#{lucky_b}#{indom_b}: #{stotal} vs CD #{dc}#{aura_b}#{bardic_bit})#{mode_tag(save_mode)} (Evasión: mitad)"

            true ->
              "falla la salvación de Destreza (d20 #{d20}#{lucky_b}#{indom_b}: #{stotal} vs CD #{dc}#{aura_b}#{bardic_bit})#{mode_tag(save_mode)}"
          end

        {:ok, msg, change} =
          with_conc_damage(
            "#{who} exhala aliento de dragón (fuego, usos restantes: 0): #{target_name} #{verdict} — #{dmg} de daño fire.",
            target_name,
            dmg,
            roller,
            roll_log,
            t,
            "fire",
            aura
          )

        {:ok, msg,
         compose_breath_spend(
           who,
           compose_indomitable_mark(
             target_name,
             indom,
             compose_inspired_clear(target_name, inspired?, change)
           )
         )}
    end
  end

  # D70: the use is spent on every resolution (save or not) — composed
  # last so errors above never reach it.
  defp compose_breath_spend(who, change) do
    fn w ->
      with {:ok, w} <- change.(w) do
        World.set_breath_weapon_used(who, true).(w)
      end
    end
  end

  defp dragonborn?(%Character{race: race}) when is_binary(race),
    do: String.downcase(race) == "dragonborn"

  defp dragonborn?(_), do: false

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
  total). At level 1 this means full heal + 1 hit die back. It also recharges
  the long-rest pools: rage uses and the Relentless Rage DC counter (D72)
  reset to 0 alongside Lay on Hands, sorcery points, Relentless Endurance
  and Indomitable.
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

  `ability_or_skill` (D60): either a raw ability (`"str"`, `:dex`, …) or a
  skill name (`"stealth"`, `"Animal Handling"`, `"animal-handling"`). A known
  skill resolves to its governing ability (`Rules.Skills`) and the ENGINE
  applies proficiency from the sheet (`skill_proficiencies`), plus Jack of All
  Trades (bard L2+, half proficiency) on untrained checks — the `proficient`
  argument is ignored in that branch. A raw ability keeps the caller's
  `proficient` flag (backwards compatible). Unknown input → directive error.
  Expertise (D73): a trained skill in the sheet's `expertise` DOUBLES the
  proficiency bonus ("prof N (experto)"); never on a raw ability, and JoaT
  never stacks with it (already proficient).
  """
  @spec check(
          World.t(),
          String.t(),
          atom() | String.t(),
          integer(),
          boolean(),
          roller(),
          :normal | :advantage | :disadvantage,
          RollLog.t() | nil
        ) :: result()
  def check(
        world,
        who,
        ability_or_skill,
        dc,
        proficient,
        roller,
        mode \\ :normal,
        roll_log \\ nil
      ) do
    case World.character(world, who) do
      nil ->
        {:error, "no existe el personaje: #{who}"}

      # A downed character cannot make ability checks (death saves use their
      # own path); enforce RAW rather than trusting the model.
      %Character{hp: hp} when hp <= 0 ->
        {:error, "#{who} está caído (0 pg) y no puede hacer chequeos"}

      %Character{} = c ->
        with {:ok, %{ability: ability, proficient?: prof?, skill: skill}} <-
               resolve_check_input(c, ability_or_skill, proficient) do
          effective_mode = Conditions.check_mode(c, ability, mode)

          label = check_label(ability, skill)

          {r, close} =
            RollLog.open(roll_log, roller, who, :check, "chequeo de #{label}")

          {d20, total, _success?, lucky} =
            Combat.ability_check_tagged(c, ability, dc, r, prof?, effective_mode, skill)

          inspired? = c.inspired == true
          {total, success?, bardic} = apply_inspired_vs_dc(c, total, dc, r)

          RollLog.close(close,
            total: total,
            against: {:dc, dc},
            outcome: if(success?, do: :success, else: :failure)
          )

          mod = Character.modifier(c, ability)
          {prof_bonus, prof_kind} = Combat.check_proficiency(c, prof?, skill)
          verdict = if success?, do: "éxito", else: "fallo"

          parts = check_parts(d20, mod, ability, prof_bonus, prof_kind, bardic, skill, lucky)

          {:ok,
           "#{who} hace un chequeo de #{label}#{mode_tag(effective_mode)}: #{Enum.join(parts, " + ")} = #{total} vs CD #{dc} — #{verdict}.",
           compose_inspired_clear(who, inspired?, noop())}
        end
    end
  end

  # Skill-vs-ability detection (D60): a known skill wins over ability parsing
  # ("intimidation" is a CHA skill, not the int ability — the parser matches
  # prefixes). A skill takes proficiency from the sheet; a raw ability keeps
  # the caller's flag. Unknown input gets a directive error with examples.
  defp resolve_check_input(%Character{} = c, input, proficient) do
    if Skills.known?(input) do
      skill = Skills.normalize(input)

      {:ok,
       %{skill: skill, ability: ability_from_skills(skill), proficient?: skill_trained?(c, skill)}}
    else
      case Ability.parse(input) do
        {:ok, ability} -> {:ok, %{skill: nil, ability: ability, proficient?: proficient}}
        :error -> {:error, unknown_check_input_error(input)}
      end
    end
  end

  # The fetch cannot fail: known?/1 already validated the key.
  defp ability_from_skills(skill) do
    {:ok, ability} = Skills.ability(skill)
    ability
  end

  defp unknown_check_input_error(input) do
    "característica o skill desconocidos: #{inspect(input)} — usa un skill " <>
      "(#{Skills.examples()}, …) o una característica str/dex/con/int/wis/cha"
  end

  # Roll-log label: "Sigilo (DES)" for a named skill, "Destreza" for a raw
  # ability (same string is reused in the chat message).
  defp check_label(ability, nil), do: ability_es(ability)

  defp check_label(ability, skill),
    do: "#{Translations.skill(skill)} (#{Translations.ability_short(ability)})"

  # Breakdown parts. A named skill gets the D60 format
  # ("1d20(11) + DES 3 + prof 2" / "+ JoaT 1"; D73 expertise →
  # "prof 4 (experto)"); a raw ability keeps the v1
  # format ("d20 11 + +3 (dex) + 2 (competencia)") for backwards compat.
  # The Lucky reroll tag (D66) rides right after the die value.
  defp check_parts(d20, mod, ability, prof_bonus, prof_kind, bardic, nil, lucky) do
    ["d20 #{d20}#{lucky_suffix(lucky)}"]
    |> then(fn p -> if mod != 0, do: p ++ ["#{signed(mod)} (#{ability})"], else: p end)
    |> then(fn p ->
      case prof_kind do
        :prof -> p ++ ["#{prof_bonus} (competencia)"]
        :joat -> p ++ ["#{prof_bonus} (JoaT)"]
        :none -> p
      end
    end)
    |> then(fn p -> if bardic != 0, do: p ++ ["#{bardic} (inspiración)"], else: p end)
  end

  defp check_parts(d20, mod, ability, prof_bonus, prof_kind, bardic, skill, lucky)
       when is_binary(skill) do
    abbr = Translations.ability_short(ability)

    ["1d20(#{d20})#{lucky_suffix(lucky)}"]
    |> then(fn p -> if mod != 0, do: p ++ ["#{abbr} #{mod}"], else: p end)
    |> then(fn p ->
      case prof_kind do
        :expert -> p ++ ["prof #{prof_bonus} (experto)"]
        :prof -> p ++ ["prof #{prof_bonus}"]
        :joat -> p ++ ["JoaT #{prof_bonus}"]
        :none -> p
      end
    end)
    |> then(fn p -> if bardic != 0, do: p ++ ["inspiración #{bardic}"], else: p end)
  end

  # ------------------------------------------------------------- spell helpers

  defp resolve_spell(world, c, caster_name, t, target_name, spell, roller, roll_log) do
    # D61: the aura covers the save target and the target's concentration
    # saves triggered by this spell's damage.
    aura = aura_save_bonus(world, target_name)
    # D65 Metamagic: Empowered boosts the spell's damage dice; Heightened
    # forces disadvantage on the armed target's save. Both apply (and are
    # consumed) only when the spell qualifies — see empowered_count/2 and
    # heightened?/3.
    emp = empowered_count(c, spell)
    heightened? = heightened?(c, target_name, spell)
    emp_tag = metamagic_tag(emp)

    case spell.kind do
      :automatic ->
        {r, close} = RollLog.open(roll_log, roller, caster_name, :spell, "conjura #{spell.name}")

        amount =
          case spell do
            %{dice: nil} -> 0
            # D65 Empowered: damage dice roll through the empowered path
            # (no-op for healing spells — emp is 0 without a damage_type).
            %{dice: _expr} -> dice_with(spell, r, emp)
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
              "#{caster_name} conjura #{spell.name}; #{target_name} recibe #{amount} de daño #{spell.damage_type}#{verb}#{emp_tag}.",
              target_name,
              amount,
              roller,
              roll_log,
              t,
              spell.damage_type,
              aura
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
            cond do
              # D65: a crit doubles the (already empowered) base dice —
              # the rerolls themselves are never duplicated.
              d20 == 20 and emp > 0 ->
                base = dice_with(spell, r2, emp)
                base + base

              d20 == 20 ->
                dice_with(spell, r2, 0) + dice_with(spell, r2, 0)

              true ->
                dice_with(spell, r2, emp)
            end

          RollLog.close(close_dmg, total: dmg, against: nil, outcome: nil)

          with_conc_damage(
            "#{caster_name} conjura #{spell.name}; impacta a #{target_name} (d20 #{d20}: #{total} vs CA #{t.ac}) por #{dmg} de daño #{spell.damage_type}#{emp_tag}#{mode_tag(effective_mode)}.",
            target_name,
            dmg,
            roller,
            roll_log,
            t,
            spell.damage_type,
            aura
          )
          |> clear_hidden_after_attack_spell(caster_name, hidden?)
        else
          {:ok,
           "#{caster_name} conjura #{spell.name}; falla contra #{target_name} (d20 #{d20}: #{total} vs CA #{t.ac})#{mode_tag(effective_mode)}.",
           noop()}
          |> clear_hidden_after_attack_spell(caster_name, hidden?)
        end

      :save ->
        resolve_save_spell(
          c,
          caster_name,
          t,
          target_name,
          spell,
          roller,
          roll_log,
          aura,
          heightened?,
          emp
        )
    end
    |> consume_metamagic(caster_name, emp > 0 or heightened?)
  end

  # D65 Heightened: applies when a save spell targets EXACTLY the armed
  # target — that save resolves with disadvantage (entered as `requested`,
  # so it combines with conditions through Conditions.save_mode). Any other
  # target: no apply, no consume.
  defp heightened?(%Character{metamagic: metamagic}, target_name, %{kind: :save}) do
    case metamagic do
      %{option: "heightened", target: armed}
      when is_binary(armed) and armed != "" and armed == target_name ->
        true

      _ ->
        false
    end
  end

  defp heightened?(_c, _target_name, _spell), do: false

  # D65 Empowered: applies to spells that roll damage dice (a dice
  # expression AND a damage type — heals and utility never qualify).
  # Returns how many of the dice roll twice keeping the higher:
  # `max(1, CHA mod)` of the caster.
  defp empowered_count(%Character{} = c, %{dice: dice, damage_type: dt})
       when is_binary(dt) and dt != "" do
    case c.metamagic do
      %{option: "empowered"} when dice != nil and dice != "" ->
        max(1, Character.modifier(c, :cha))

      _ ->
        0
    end
  end

  defp empowered_count(_c, _spell), do: 0

  # D65: consume the armed option once it applied (resolve_spell sites only
  # — never make_attack or anywhere else).
  defp consume_metamagic({:ok, msg, change}, caster_name, true) do
    combined = fn w ->
      with {:ok, w} <- change.(w) do
        World.set_metamagic(caster_name, nil).(w)
      end
    end

    {:ok, msg, combined}
  end

  defp consume_metamagic(result, _caster_name, _applied), do: result

  defp metamagic_tag(0), do: ""

  defp metamagic_tag(_emp), do: " (Metamagia: Empowered)"

  # D65 Twinned: applies when the armed twin target exists and differs from
  # the caster, and the spell targets someone other than the caster
  # (self-buffs never apply nor consume). Returns the twin's name or nil.
  defp twinned_target(world, %Character{} = c, caster_name, target_name) do
    case c.metamagic do
      %{option: "twinned", target: twin} when is_binary(twin) and twin != "" ->
        if twin != caster_name and target_name != caster_name and
             not is_nil(World.character(world, twin)) do
          twin
        else
          nil
        end

      _ ->
        nil
    end
  end

  # D65 Twinned: the SAME spell resolves against both targets — each
  # resolution rolls its own dice (the first one's rolls are never
  # re-used). The spell is one: the slot is consumed once and concentration
  # set once (both composed by the caller in spell/5). The option is
  # consumed here, once.
  defp resolve_twinned(world, c, caster_name, target_name, twin_name, spell, roller, roll_log) do
    t1 = World.character(world, target_name)
    t2 = World.character(world, twin_name)

    {:ok, msg1, change1} =
      resolve_spell(world, c, caster_name, t1, target_name, spell, roller, roll_log)

    {:ok, msg2, change2} =
      resolve_spell(world, c, caster_name, t2, twin_name, spell, roller, roll_log)

    change = fn w ->
      with {:ok, w} <- change1.(w),
           {:ok, w} <- change2.(w) do
        World.set_metamagic(caster_name, nil).(w)
      end
    end

    {:ok,
     "#{caster_name} conjura #{spell.name} (Metamagia: Twinned): " <>
       "#{twin_block(caster_name, spell, target_name, msg1)}; " <>
       "#{twin_block(caster_name, spell, twin_name, msg2)}.", change}
  end

  # Per-target block of a Twinned message: strip the shared
  # "X conjura Y; " prefix (or "X conjura Y sobre <target>. ") so the outer
  # message reads "en <target>: <resolution>".
  defp twin_block(caster_name, spell, target_name, msg) do
    prefix = "#{caster_name} conjura #{spell.name}"

    body =
      cond do
        String.starts_with?(msg, prefix <> "; ") ->
          msg
          |> String.replace_prefix(prefix <> "; ", "")
          |> String.replace_prefix("#{target_name} ", "")

        String.starts_with?(msg, prefix <> " sobre ") ->
          msg
          |> String.replace_prefix(prefix <> " sobre ", "")
          |> String.replace_prefix("#{target_name}. ", "")

        true ->
          msg
      end
      |> String.trim_trailing(".")

    "en #{target_name}: #{body}"
  end

  defp resolve_save_spell(
         c,
         caster_name,
         t,
         target_name,
         spell,
         roller,
         roll_log,
         aura,
         heightened?,
         emp
       ) do
    dc = Combat.spell_save_dc(c, spell)
    # D65 Heightened: the armed target's save enters as requested
    # disadvantage (combines with conditions/Danger Sense via save_mode).
    # D71 Gnome Cunning: a gnome's mental save enters as an extra
    # advantage source — combine/2 cancels it against Heightened or a
    # condition's disadvantage (normal).
    # D76 Dwarven Resilience: a dwarf's save against a POISON spell
    # enters as an extra advantage source (same combination semantics).
    gnome? = gnome_cunning?(t, spell.save_ability)
    dwarf? = dwarven_resilience?(t, spell)
    requested = if heightened?, do: :disadvantage, else: :normal
    height_tag = if heightened?, do: " (Metamagia: Heightened)", else: ""
    emp_tag = metamagic_tag(emp)

    case Conditions.save_mode(t, spell.save_ability, requested,
           gnome_advantage: gnome?,
           dwarf_advantage: dwarf?
         ) do
      :auto_fail ->
        {r2, close_dmg} =
          RollLog.open(
            roll_log,
            roller,
            caster_name,
            :damage,
            "daño de #{spell.name} (#{spell.damage_type})"
          )

        full = dice_with(spell, r2, emp)
        RollLog.close(close_dmg, total: full, against: nil, outcome: nil)

        with_conc_damage(
          "#{caster_name} conjura #{spell.name}; #{target_name} falla automáticamente la salvación de #{ability_es(spell.save_ability)} vs CD #{dc}#{height_tag} — #{full} de daño #{spell.damage_type}#{emp_tag}.",
          target_name,
          full,
          roller,
          roll_log,
          t,
          spell.damage_type,
          aura
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

        {d20, stotal, _success?, lucky} =
          Combat.saving_throw_tagged(t, spell.save_ability, dc, r, save_mode)

        # D61 Aura of Protection: added before bardic inspiration (which
        # re-derives success from the running total).
        stotal = stotal + aura
        {stotal, success?, bardic} = apply_inspired_vs_dc(t, stotal, dc, r)

        # D68 Indomitable: a fighter L9+ rerolls a FAILED save once per long
        # rest — the reroll decides the final outcome (aura re-applies; the
        # bardic die was consumed by the first attempt). The reroll goes
        # through the same roller/mode (Heightened/Danger Sense intact).
        {d20, stotal, success?, indom} =
          maybe_indomitable(
            t,
            spell.save_ability,
            dc,
            r,
            save_mode,
            {d20, stotal, success?},
            aura
          )

        # The reroll spends Indomitable: the updated struct rides into the
        # concentration simulation so a later CON save this same resolution
        # can't double-spend it.
        t = if indom, do: %{t | indomitable_used: true}, else: t

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

        full = dice_with(spell, r2, emp)
        RollLog.close(close_dmg, total: full, against: nil, outcome: nil)

        # D59 Evasión: a rogue L7+ takes no damage on a successful DEX save
        # and half on a failed one. Incapacitated rogues are cut off by the
        # auto-fail set in Conditions.save_mode (they never roll here).
        evasion? = evasion?(t, spell)

        dmg =
          cond do
            success? and evasion? -> 0
            success? -> div(full, 2)
            evasion? -> div(full, 2)
            true -> full
          end

        bardic_bit = if bardic != 0, do: " +#{bardic} inspiración", else: ""
        aura_b = aura_bit(aura)
        lucky_b = lucky_suffix(lucky)
        indom_b = indom_suffix(indom)

        # D71/D76: when a racial advantage shaped the mode, its tag
        # replaces the generic "(ventaja)" — a cancelled advantage
        # (Heightened/condition) leaves the plain mode_tag (normal = "").
        mode_b =
          cond do
            gnome? and save_mode == :advantage -> " (Astucia gnoma: ventaja)"
            dwarf? and save_mode == :advantage -> " (Resistencia enana: ventaja)"
            true -> mode_tag(save_mode)
          end

        verdict =
          cond do
            success? and evasion? ->
              "supera la salvación (d20 #{d20}#{lucky_b}#{indom_b}: #{stotal} vs CD #{dc}#{aura_b}#{bardic_bit})#{mode_b}#{height_tag} (Evasión: sin daño)"

            success? ->
              "supera la salvación (d20 #{d20}#{lucky_b}#{indom_b}: #{stotal} vs CD #{dc}#{aura_b}#{bardic_bit})#{mode_b}#{height_tag}, mitad de daño"

            evasion? ->
              "falla la salvación (d20 #{d20}#{lucky_b}#{indom_b}: #{stotal} vs CD #{dc}#{aura_b}#{bardic_bit})#{mode_b}#{height_tag} (Evasión: mitad)"

            true ->
              "falla la salvación (d20 #{d20}#{lucky_b}#{indom_b}: #{stotal} vs CD #{dc}#{aura_b}#{bardic_bit})#{mode_b}#{height_tag}"
          end

        {:ok, msg, change} =
          with_conc_damage(
            "#{caster_name} conjura #{spell.name}; #{target_name} #{verdict} — #{dmg} de daño #{spell.damage_type}#{emp_tag}.",
            target_name,
            dmg,
            roller,
            roll_log,
            t,
            spell.damage_type,
            aura
          )

        {:ok, msg,
         compose_indomitable_mark(
           target_name,
           indom,
           compose_inspired_clear(target_name, inspired?, change)
         )}
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

  defp dice_with(%{dice: nil}, _roller, _emp), do: 0

  defp dice_with(%{dice: expr}, roller, emp) when emp > 0,
    do: empowered_roll(expr, roller, emp)

  defp dice_with(%{dice: expr}, roller, _emp), do: Dice.roll_expr(expr, roller)

  # D65 Empowered: the first `emp` dice of `NdM±K` roll twice keeping the
  # higher (deterministic: two roller draws per boosted die); the rest and
  # the flat modifier pass through unchanged.
  defp empowered_roll(expr, roller, emp) do
    {count, sides, mod} = Dice.parse_expr(expr)

    rolls =
      for i <- 1..count do
        if i <= emp, do: max(roller.(sides), roller.(sides)), else: roller.(sides)
      end

    Enum.sum(rolls) + mod
  end

  # D59 Evasión: rogue L7+ — no damage on a successful DEX save, half on a
  # failed one. The auto-fail conditions short-circuit DEX saves inside
  # Conditions.save_mode, so an incapacitated rogue never reaches the roll
  # branch that applies this (RAW "unless incapacitated").
  defp evasion?(%Character{} = target, %{save_ability: :dex}) do
    target.class == "rogue" and (target.level || 1) >= 7
  end

  defp evasion?(_target, _spell), do: false

  # D71 Gnome Cunning: advantage on INT/WIS/CHA saves against MAGIC. Engine
  # equivalence (ADR D71): every save that comes out of cast_spell's :save
  # branch and turn_undead (divine = magic) is "magic"; concentration (CON)
  # and DEX saves are out of the mental scope either way.
  defp gnome_cunning?(%Character{race: race}, ability) when ability in [:int, :wis, :cha] do
    is_binary(race) and String.downcase(race) == "gnome"
  end

  defp gnome_cunning?(_, _), do: false

  # D76 Dwarven Resilience: advantage on saving throws against poison.
  # Engine equivalence (ADR D76): every :save spell with
  # damage_type "poison" counts as "against poison" regardless of the
  # save ability (RAW 2014 wording). Injected only from cast_spell's
  # :save branch. NOTE: today the catalog has exactly one such spell
  # (SRD cloudkill, CON save 5d8 poison) — usable E2E, but rare; the
  # hook is future-proof for any poison spell that arrives.
  defp dwarven_resilience?(%Character{race: race}, %{damage_type: "poison"})
       when is_binary(race) do
    String.downcase(race) == "dwarf"
  end

  defp dwarven_resilience?(_, _), do: false

  # D74: the dart count rides the dice expression (3d4+3 → 3; 4d4+4 → 4 when
  # upcast), so the verb always reports the real number of darts.
  defp spell_damage_verb(%{name: "magic missile", dice: dice}, _dmg) when is_binary(dice) do
    {count, _sides, _mod} = Dice.parse_expr(dice)
    " (#{count} dardos de fuerza)"
  end

  defp spell_damage_verb(%{name: "magic missile"}, _dmg), do: " (3 dardos de fuerza)"
  defp spell_damage_verb(_spell, _dmg), do: ""

  defp describe_death_save(name, {:revive, _d20, _, _}, bardic, aura),
    do:
      "#{name} saca un 20 natural#{aura_death_bit(aura)}#{bardic_death_bit(bardic)} — ¡revive con 1 pg!"

  defp describe_death_save(name, {:crit_fail, 1, _, _}, bardic, aura),
    do:
      "#{name} saca un 1 natural#{aura_death_bit(aura)}#{bardic_death_bit(bardic)} — ¡dos fallos de salvación de muerte!"

  defp describe_death_save(name, {:fail, d20, _, _}, bardic, aura),
    do:
      "#{name} saca #{d20}#{aura_death_bit(aura)}#{bardic_death_bit(bardic)} — un fallo de salvación de muerte."

  defp describe_death_save(name, {:success, d20, _, _}, bardic, aura),
    do:
      "#{name} saca #{d20}#{aura_death_bit(aura)}#{bardic_death_bit(bardic)} — un éxito de salvación de muerte."

  # D61: the aura shifts the 10 threshold, so the breakdown shows it.
  defp aura_death_bit(aura) when aura != 0, do: " (#{signed(aura)} aura)"
  defp aura_death_bit(_), do: ""

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
    {kind, d20, total, lucky} = Combat.attack_roll_tagged(a, weapon, ac, r, mode)
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
          savage: 0,
          mark: 0,
          bardic: bardic,
          lucky: lucky
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

        {dmg, savage_dmg} = Combat.damage_roll_tagged(a, weapon, k, r2)
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
          savage: savage_dmg,
          mark: mark_dmg,
          bardic: bardic,
          lucky: lucky
        }
    end
  end

  defp format_attack_message(attacker, target, _weapon, ac, mode, [%{kind: :miss} = s]) do
    "#{attacker} lanza un golpe a #{target} — fallo (d20 #{s.d20}#{lucky_tag(s)}: #{s.total} vs CA #{ac})#{bardic_tag(s)}#{mode_tag(mode)}."
  end

  defp format_attack_message(attacker, target, weapon, ac, mode, [s]) do
    verb = if s.kind == :crit, do: "CRÍTICO", else: "acierta"

    "#{attacker} #{verb} a #{target} (d20 #{s.d20}#{lucky_tag(s)}: #{s.total} vs CA #{ac}) por #{s.dmg} de daño #{weapon.damage_type}#{savage_tag(s)}#{sneak_tag(s)}#{rage_tag(s)}#{mark_tag(s)}#{smite_tag(s)}#{bardic_tag(s)}#{mode_tag(mode)}."
  end

  defp format_attack_message(attacker, target, weapon, ac, mode, swings) do
    parts = Enum.map_join(swings, "; ", &describe_swing(&1, weapon, ac))
    "#{attacker} ataca a #{target} (#{length(swings)} golpes)#{mode_tag(mode)}: #{parts}."
  end

  defp describe_swing(%{kind: :miss, d20: d20, total: total} = s, _weapon, ac) do
    "fallo (d20 #{d20}#{lucky_tag(s)}: #{total} vs CA #{ac})#{bardic_tag(s)}"
  end

  defp describe_swing(%{kind: k, d20: d20, total: total, dmg: dmg} = s, weapon, ac) do
    verb = if k == :crit, do: "CRÍTICO", else: "acierta"

    "#{verb} (d20 #{d20}#{lucky_tag(s)}: #{total} vs CA #{ac}) por #{dmg} de daño #{weapon.damage_type}#{savage_tag(s)}#{sneak_tag(s)}#{rage_tag(s)}#{mark_tag(s)}#{smite_tag(s)}#{bardic_tag(s)}"
  end

  defp swing_amounts(swings), do: for(%{dmg: dmg} <- swings, dmg > 0, do: dmg)

  defp smite_amounts(swings), do: for(%{smite: n} <- swings, n > 0, do: n)

  defp pipe_attack_damage(target, swings, roller, roll_log, char, weapon_type, aura) do
    {weapon_notes, weapon_change, char_after} =
      pipe_damage(target, swing_amounts(swings), roller, roll_log, char, weapon_type, aura)

    {smite_notes, smite_change, _char} =
      pipe_damage(target, smite_amounts(swings), roller, roll_log, char_after, "radiant", aura)

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

  defp with_conc_damage(msg, target_name, amount, roller, roll_log, target_char, type, aura) do
    {notes, change, _char} =
      pipe_damage(target_name, [amount], roller, roll_log, target_char, type, aura)

    {:ok, append_notes(msg, notes), change}
  end

  # D68: pipe_damage threads the simulated character through each amount's
  # concentration save, so a reroll that spent Indomitable blocks a second
  # reroll on the next hit of the same action.
  defp pipe_damage(_target, [], _roller, _roll_log, char, _type, _aura), do: {[], noop(), char}

  defp pipe_damage(target, amounts, roller, roll_log, char, type, aura) do
    amounts = Enum.filter(amounts, &(&1 > 0))

    {pairs, final_char} =
      Enum.map_reduce(amounts, char, fn amount, c ->
        {note, break?, c2, clear_inspired?, mark_indomitable?} =
          one_hit_concentration(c, amount, roller, roll_log, type, aura)

        {{note, break?, clear_inspired?, mark_indomitable?}, c2}
      end)

    notes = pairs |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1)

    flags =
      Enum.map(pairs, fn {_, break?, clear_inspired?, mark_indomitable?} ->
        {break?, clear_inspired?, mark_indomitable?}
      end)

    change = fn w ->
      Enum.reduce_while(Enum.zip(amounts, flags), {:ok, w}, fn {amount,
                                                                {break?, clear_inspired?,
                                                                 mark_indomitable?}},
                                                               {:ok, acc} ->
        case World.character(acc, target) do
          %Character{hp: hp} when hp <= 0 ->
            {:halt, {:ok, acc}}

          %Character{} ->
            # D72: the roller threads through so a raging barbarian L11+
            # takes the Relentless Rage save with the SAME deterministic
            # roller as the rest of the action.
            case World.apply_damage(target, amount, type, roller).(acc) do
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

                # D68: the Indomitable reroll spent the flag for this
                # long-rest cycle.
                next =
                  if mark_indomitable? do
                    case World.set_indomitable(target, true).(next) do
                      {:ok, marked} -> marked
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

    {notes, change, final_char}
  end

  defp one_hit_concentration(
         %Character{concentrating: nil} = c,
         amount,
         _roller,
         _roll_log,
         type,
         _aura
       ) do
    {nil, false, simulate_damage(c, amount, type), false, false}
  end

  defp one_hit_concentration(%Character{} = c, amount, roller, roll_log, type, aura) do
    incoming = Character.incoming_damage(c, amount, type)
    c2 = simulate_damage(c, amount, type)

    cond do
      c2.hp <= 0 ->
        {"#{c.name} cae a 0 pg y pierde la concentración en #{c.concentrating}.", true,
         %{c2 | concentrating: nil}, false, false}

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

        {d20, total, _success?, lucky} = Combat.saving_throw_tagged(c, :con, dc, r, mode)
        # D61: concentration is a CON save — the aura applies (RAW).
        total = total + aura
        {total, success?, bardic} = apply_inspired_vs_dc(c, total, dc, r)

        # D68 Indomitable: a fighter L9+ rerolls a failed concentration
        # save once per long rest — the reroll decides whether it holds.
        {d20, total, success?, indom} =
          maybe_indomitable(c, :con, dc, r, mode, {d20, total, success?}, aura)

        # The reroll spends Indomitable on the simulated char too, so a
        # second hit this action can't double-spend it.
        c2 = if indom, do: %{c2 | indomitable_used: true}, else: c2

        RollLog.close(close,
          total: total,
          against: {:dc, dc},
          outcome: if(success?, do: :success, else: :failure)
        )

        aura_b = aura_bit(aura)
        bardic_bit = if bardic != 0, do: " +#{bardic} inspiración", else: ""
        lucky_b = lucky_suffix(lucky)
        indom_b = indom_suffix(indom)
        c2 = if inspired?, do: %{c2 | inspired: false}, else: c2

        if success? do
          {"#{c.name} mantiene la concentración en #{c.concentrating} (d20 #{d20}#{lucky_b}#{indom_b}: #{total} vs CD #{dc}#{aura_b}#{bardic_bit}).",
           false, c2, inspired?, indom != nil}
        else
          {"#{c.name} pierde la concentración en #{c.concentrating} (d20 #{d20}#{lucky_b}#{indom_b}: #{total} vs CD #{dc}#{aura_b}#{bardic_bit}).",
           true, %{c2 | concentrating: nil}, inspired?, indom != nil}
        end

      true ->
        {nil, false, c2, false, false}
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

  # D69 Savage Attacks: the extra weapon die rides the swing map (0 when the
  # attack wasn't a melee crit by a half-orc).
  defp savage_tag(%{savage: n}) when is_integer(n) and n > 0, do: " (+#{n} Savage)"
  defp savage_tag(_), do: ""

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

  # D66 Lucky: the tagged roll returns the reroll note ("(Lucky: 1→N)") —
  # render it right after the die value (mode_tag pattern).
  defp lucky_tag(%{lucky: tag}) when is_binary(tag), do: " #{tag}"

  defp lucky_tag(_), do: ""

  defp lucky_suffix(nil), do: ""

  defp lucky_suffix(tag) when is_binary(tag), do: " #{tag}"

  # D68 Indomitable: a fighter of level 9+ rerolls a FAILED saving throw
  # once per long rest — the NEW total is used (RAW), whatever it is. The
  # reroll is the SAME `saving_throw_tagged` call with the same arguments,
  # so the mode (Heightened D65, Danger Sense D58, conditions) still shapes
  # it and Lucky (D66) can fire on the reroll for free. `extra` is the flat
  # bonus the site already added to the first roll (the D61 aura) — it
  # re-applies to the reroll; the bardic die was consumed by the first
  # attempt and never re-rolls. Auto-fails never reach here (no die rolled).
  # Returns the final {d20, total, success?} plus a breakdown tag (nil when
  # it didn't fire) — the site marks `indomitable_used` on a non-nil tag.
  defp maybe_indomitable(
         %Character{} = t,
         ability,
         dc,
         roller,
         mode,
         {d20, total, success?},
         extra
       ) do
    if success? or not indomitable?(t) do
      {d20, total, success?, nil}
    else
      {d20_2, total_2, _success?, lucky_2} =
        Combat.saving_throw_tagged(t, ability, dc, roller, mode)

      total_2 = total_2 + extra
      tag = "(Indomitable: #{total}→#{total_2})" <> lucky_suffix(lucky_2)
      {d20_2, total_2, total_2 >= dc, tag}
    end
  end

  # Fighter L9+, use still unspent this long-rest cycle.
  defp indomitable?(%Character{class: "fighter", level: level, indomitable_used: false})
       when is_integer(level) and level >= 9,
       do: true

  defp indomitable?(_), do: false

  defp indom_suffix(nil), do: ""

  defp indom_suffix(tag) when is_binary(tag), do: " #{tag}"

  # D68: a fired reroll spends Indomitable (composed into the site's change).
  defp compose_indomitable_mark(_name, nil, change), do: change

  defp compose_indomitable_mark(name, _tag, change) do
    fn w ->
      with {:ok, w} <- change.(w) do
        World.set_indomitable(name, true).(w)
      end
    end
  end

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

  # D61: the aura already shaped `result` (Combat.death_save/2); re-deriving
  # the outcome with bardic must keep it in the total.
  defp apply_inspired_death(%Character{inspired: true}, result, roller, aura) do
    d20 = elem(result, 1)
    bonus = roller.(6)

    new_result =
      case result do
        {:revive, _, _, _} -> result
        {:crit_fail, _, _, _} -> result
        _ when d20 + aura + bonus >= 10 -> {:success, d20, 0, 1}
        _ -> {:fail, d20, 1, 0}
      end

    {new_result, bonus}
  end

  defp apply_inspired_death(_, result, _, _), do: {result, 0}

  # D61 Aura of Protection: every conscious paladin (L6+) on the saver's side
  # shares their CHA modifier with ALL saves of that side (the paladin
  # included). Multiple paladins stack (RAW); a CHA below 10 gives a negative
  # bonus with no floor (RAW). 0 when the side has none. The computation
  # moved to `World.aura_save_bonus/2` so the D72 Relentless Rage save inside
  # `World.apply_damage/4` rides the same bonus.
  defp aura_save_bonus(%World{} = world, name), do: World.aura_save_bonus(world, name)

  # Breakdown bit for save messages: " +3 aura" / " -1 aura".
  defp aura_bit(aura) when aura != 0, do: " #{signed(aura)} aura"
  defp aura_bit(_), do: ""

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
           {:ok, w} <- World.restore_ki(name).(w),
           {:ok, w} <- World.restore_wild_shape_uses(name).(w),
           {:ok, w} <- World.set_breath_weapon_used(name, false).(w) do
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
           {:ok, w} <- World.restore_sorcery_points(name).(w),
           {:ok, w} <- World.set_relentless_endurance(name, false).(w),
           {:ok, w} <- World.set_indomitable(name, false).(w),
           {:ok, w} <- World.set_rage_uses_used(name, 0).(w),
           {:ok, w} <- World.set_relentless_rage_successes(name, 0).(w) do
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
