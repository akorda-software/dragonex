defmodule Dragones.Actions do
  @moduledoc """
  Pure orchestration that turns an actor's *intent* into a narrated outcome plus
  a world change — the bridge between `Dragones.Rules` (the math) and
  `Dragones.World` (the state).

  Every function returns `{:ok, message, change_fn} | {:error, reason}`, where:

    * `message`    — a factual string the tool hands back to the LLM (the LLM
                     never computes the math; it only reads results);
    * `change_fn`  — a `(world -> {:ok, world} | {:error, reason})` ready for
                     `SharedState.propose_change/2`.

  No exAgent here: deterministic and unit-testable with a fixed roller.
  """

  alias Dragones.{Character, Dice, Rules.Ability, Rules.Combat, World}

  @type roller :: (pos_integer() -> pos_integer())
  @type result ::
          {:ok, String.t(), (World.t() -> {:ok, World.t()} | {:error, term()})}
          | {:error, String.t()}

  @doc "Roll one or more dice and report the total (no world side-effect)."
  @spec roll(pos_integer(), pos_integer(), :normal | :advantage | :disadvantage, roller()) ::
          {:ok, String.t()}
  def roll(count, sides, mode \\ :normal, roller) do
    case mode do
      :normal ->
        {:ok, "rolled #{count}d#{sides} = #{sum(count, sides, roller)}"}

      mode when mode in [:advantage, :disadvantage] ->
        kept =
          for _ <- 1..max(count, 1) do
            {k, _, _} = Dice.roll_advantage(sides, mode, roller)
            k
          end

        {:ok, "rolled #{count}d#{sides} (#{mode}) = #{Enum.sum(kept)}"}
    end
  end

  @doc """
  Resolve a weapon attack: attack roll (with crit/fumble) then, on a hit, a
  damage roll, applied to the target's hp. The attacker and target must already
  be in the world, and the attacker must wield the named weapon.
  """
  @spec attack(World.t(), String.t(), String.t(), String.t(), roller(), :normal | :advantage | :disadvantage) :: result()
  def attack(world, attacker, target, weapon_name, roller, mode \\ :normal) do
    cond do
      is_nil(World.character(world, attacker)) ->
        {:error, "no such attacker: #{attacker}"}

      is_nil(World.character(world, target)) ->
        {:error, "no such target: #{target}"}

      true ->
        a = World.character(world, attacker)
        t = World.character(world, target)

        case find_weapon(a, weapon_name) do
          nil ->
            {:error, "#{attacker} has no weapon #{weapon_name}"}

          weapon ->
            effective_mode = adjust_mode_for_conditions(mode, a, t, weapon)
            {kind, d20, total} = Combat.attack_roll(a, weapon, t.ac, roller, effective_mode)

            case kind do
              :miss ->
                {:ok,
                 "#{attacker} swings at #{target} — miss (d20 #{d20}: #{total} vs AC #{t.ac})#{mode_tag(effective_mode)}.",
                 noop()}

              k ->
                dmg = Combat.damage_roll(a, weapon, k, roller)
                verb = if k == :crit, do: "CRITS", else: "hits"

                {:ok,
                 "#{attacker} #{verb} #{target} (d20 #{d20}: #{total} vs AC #{t.ac}) for #{dmg} #{weapon.damage_type}#{mode_tag(effective_mode)}.",
                 World.apply_damage(target, dmg)}
            end
        end
    end
  end

  # 5e condition-aware mode adjustment: certain conditions grant advantage or
  # disadvantage on attack rolls. When both apply, they cancel (normal).
  defp adjust_mode_for_conditions(mode, attacker, target, weapon) do
    attacker_conds = condition_names(attacker)
    target_conds = condition_names(target)

    disadvantage? =
      Enum.any?(attacker_conds, &(&1 in ~w(poisoned frightened blinded restrained))) or
        ("prone" in target_conds and weapon.ranged)

    advantage? =
      cond do
        "prone" in target_conds and not weapon.ranged -> true
        Enum.any?(target_conds, &(&1 in ~w(blinded stunned paralyzed unconscious restrained))) -> true
        true -> false
      end

    cond do
      advantage? and disadvantage? -> :normal
      advantage? -> :advantage
      disadvantage? -> :disadvantage
      true -> mode
    end
  end

  defp condition_names(%Character{conditions: conds}) do
    Enum.map(conds, fn
      %{condition: c} -> c
      %{"condition" => c} -> c
      c when is_binary(c) -> c
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Resolve a spell against a single target by its `kind`:

    * `:automatic` — always hits (e.g. magic missile); full dice damage.
    * `:attack`    — spell attack vs AC (nat 20 auto-hits, nat 1 auto-misses).
    * `:save`      — target saves vs DC; success halves the damage (5e default).
  """
  @spec spell(World.t(), String.t(), String.t(), String.t(), roller()) :: result()
  def spell(world, caster_name, spell_name, target_name, roller) do
    cond do
      is_nil(World.character(world, caster_name)) ->
        {:error, "no such caster: #{caster_name}"}

      is_nil(World.character(world, target_name)) ->
        {:error, "no such target: #{target_name}"}

      true ->
        c = World.character(world, caster_name)
        t = World.character(world, target_name)

        case find_spell(c, spell_name) do
          nil ->
            {:error, "#{caster_name} doesn't know #{spell_name}"}

          spell ->
            # Check spell slot for leveled spells (cantrips are free)
            if spell.level > 0 and not World.has_slot?(world, caster_name, spell.level) do
              {:error,
               "#{caster_name} has no level-#{spell.level} spell slots remaining " <>
                 "(rest to recover). Cantrips are always available."}
            else
              result = resolve_spell(c, caster_name, t, target_name, spell, roller)
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
  @spec initiative(World.t(), roller()) :: result()
  def initiative(world, roller) do
    ordered =
      world.characters
      |> Enum.filter(fn {_, %Character{hp: hp}} -> hp > 0 end)
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, c} -> {name, Combat.roll_initiative(c, roller)} end)
      |> Enum.sort_by(fn {name, {_d20, total}} -> {-total, name} end)

    summary =
      Enum.map_join(ordered, ", ", fn {name, {d20, total}} -> "#{name} #{d20}→#{total}" end)

    names = Enum.map(ordered, &elem(&1, 0))

    {:ok, "Initiative — #{summary}.", World.begin_combat(names)}
  end

  @doc "Make a death saving throw for a down character and apply the result."
  @spec death_save(World.t(), String.t(), roller()) :: result()
  def death_save(world, name, roller) do
    case World.character(world, name) do
      nil ->
        {:error, "no such character: #{name}"}

      %Character{hp: hp} when hp > 0 ->
        {:error, "#{name} is not down (hp #{hp})"}

      %Character{} ->
        result = Combat.death_save(roller)
        {:ok, describe_death_save(name, result), World.apply_death_save(name, result)}
    end
  end

  @doc """
  Heal a character by a dice expression (e.g. "1d8+3"), capped at max_hp.
  Healing also clears the death-save tracker (reviving a downed character).
  """
  @spec heal(World.t(), String.t(), String.t(), roller()) :: result()
  def heal(world, target, dice_expr, roller) do
    case World.character(world, target) do
      nil ->
        {:error, "no such character: #{target}"}

      %Character{hp: hp, max_hp: max_hp} ->
        rolled = Dice.roll_expr(dice_expr, roller)
        applied = min(rolled, max_hp - hp)

        {:ok,
         "#{target} is healed for #{applied} hp (#{hp} → #{hp + applied}).",
         World.heal(target, rolled)}
    end
  end

  @doc """
  A short rest: the character spends hit dice to recover HP.

  At level 1, a character has 1 hit die. The heal is `roll(hit_die) + con_mod`.
  """
  @spec short_rest(World.t(), String.t(), roller()) :: result()
  def short_rest(world, name, roller) do
    case World.character(world, name) do
      nil ->
        {:error, "no such character: #{name}"}

      %Character{hp: hp, max_hp: max_hp} = c ->
        if hp <= 0 do
          {:error, "#{name} is down and cannot rest"}
        else
          hit_die = hit_die_for(c.class)
          con_mod = Character.modifier(c, :con)
          rolled = roller.(hit_die) + con_mod
          applied = min(rolled, max_hp - hp)

          {:ok,
           "#{name} takes a short rest and recovers #{applied} hp (1d#{hit_die}#{signed(con_mod)} = #{rolled}, now #{hp + applied}/#{max_hp}).",
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
        {:error, "no such character: #{name}"}

      %Character{hp: hp, max_hp: max_hp} ->
        if hp <= 0 do
          {:error, "#{name} is down and cannot rest"}
        else
          healed = max_hp - hp

          change = fn w ->
            {:ok, w2} = World.heal(name, healed).(w)
            {:ok, w3} = World.restore_slots(name).(w2)
            {:ok, w3}
          end

          {:ok,
           "#{name} takes a long rest and recovers #{healed} hp (#{hp} → #{max_hp}, full restore). Spell slots recovered.",
           change}
        end
    end
  end

  @doc """
  Resolve an ability check (non-combat): the DM sets the `dc`, the engine rolls
  `d20 + ability modifier` and reports success/failure. No world side-effect —
  the DM narrates the consequences and may then call other tools.
  """
  @spec check(World.t(), String.t(), atom(), integer(), boolean(), roller(), :normal | :advantage | :disadvantage) :: result()
  def check(world, who, ability, dc, proficient, roller, mode \\ :normal) do
    case World.character(world, who) do
      nil ->
        {:error, "no such character: #{who}"}

      %Character{} = c ->
        {d20, total, success?} = Combat.ability_check(c, ability, dc, roller, proficient, mode)
        mod = Character.modifier(c, ability)
        prof = if proficient, do: Ability.proficiency(c.level), else: 0
        verdict = if success?, do: "success", else: "failure"

        parts =
          ["d20 #{d20}"]
          |> then(fn p -> if mod != 0, do: p ++ ["#{signed(mod)} (#{ability})"], else: p end)
          |> then(fn p -> if prof != 0, do: p ++ ["#{prof} (prof)"], else: p end)

        {:ok,
         "#{who} makes a #{ability_label(ability)} check#{mode_tag(mode)}: #{Enum.join(parts, " + ")} = #{total} vs DC #{dc} — #{verdict}.",
         noop()}
    end
  end

  # ------------------------------------------------------------- spell helpers

  defp resolve_spell(c, caster_name, t, target_name, spell, roller) do
    case spell.kind do
      :automatic ->
        amount = dice(spell, roller)

        cond do
          # Healing spell: no damage_type but has dice → heal the target
          spell.damage_type == nil and amount > 0 ->
            # Add casting ability modifier to healing (5e: spell save DC modifier applies)
            cast_mod = Character.modifier(c, spell.casting_ability)
            total_heal = amount + cast_mod

            {:ok,
             "#{caster_name} casts #{spell.name}; #{target_name} is healed for #{total_heal} hp (#{amount} + #{cast_mod}).",
             World.heal(target_name, total_heal)}

          # Damage spell (magic missile, etc.)
          amount > 0 ->
            verb = spell_damage_verb(spell, amount)

            {:ok,
             "#{caster_name} casts #{spell.name}; #{target_name} takes #{amount} #{spell.damage_type}#{verb}.",
             World.apply_damage(target_name, amount)}

          # Utility spell (shield, bless, etc.): no dice → just report
          true ->
            {:ok,
             "#{caster_name} casts #{spell.name} on #{target_name}. #{spell.effect || ""}",
             noop()}
        end

      :attack ->
        bonus = Combat.spell_attack_bonus(c, spell)
        d20 = roller.(20)
        total = d20 + bonus

        if d20 == 20 or (d20 != 1 and total >= t.ac) do
          dmg = dice(spell, roller)

          {:ok,
           "#{caster_name} casts #{spell.name}; hits #{target_name} (d20 #{d20}: #{total} vs AC #{t.ac}) for #{dmg} #{spell.damage_type}.",
           World.apply_damage(target_name, dmg)}
        else
          {:ok,
           "#{caster_name} casts #{spell.name}; misses #{target_name} (d20 #{d20}: #{total} vs AC #{t.ac}).",
           noop()}
        end

      :save ->
        dc = Combat.spell_save_dc(c, spell)
        {d20, stotal, success?} = Combat.saving_throw(t, spell.save_ability, dc, roller)
        full = dice(spell, roller)
        dmg = if success?, do: div(full, 2), else: full

        verdict =
          if success?,
            do: "saves (d20 #{d20}: #{stotal} vs DC #{dc}), half",
            else: "fails (d20 #{d20}: #{stotal} vs DC #{dc})"

        {:ok,
         "#{caster_name} casts #{spell.name}; #{target_name} #{verdict} — #{dmg} #{spell.damage_type}.",
         World.apply_damage(target_name, dmg)}
    end
  end

  defp dice(%{dice: nil}, _roller), do: 0
  defp dice(%{dice: expr}, roller), do: Dice.roll_expr(expr, roller)

  defp spell_damage_verb(%{name: "magic missile"}, _dmg), do: " (3 darts of force)"
  defp spell_damage_verb(_spell, _dmg), do: ""

  defp describe_death_save(name, {:revive, _d20, _, _}),
    do: "#{name} rolls a natural 20 — revives at 1 hp!"

  defp describe_death_save(name, {:crit_fail, 1, _, _}),
    do: "#{name} rolls a natural 1 — two death-save failures!"

  defp describe_death_save(name, {:fail, d20, _, _}),
    do: "#{name} rolls #{d20} — one death-save failure."

  defp describe_death_save(name, {:success, d20, _, _}),
    do: "#{name} rolls #{d20} — one death-save success."

  # ----------------------------------------------------------------- helpers

  defp find_weapon(%Character{weapons: weapons}, name),
    do: Enum.find(weapons, &(&1.name == name))

  defp hit_die_for("barbarian"), do: 12
  defp hit_die_for(c) when c in ~w(fighter paladin ranger), do: 10
  defp hit_die_for(c) when c in ~w(bard cleric druid monk rogue warlock), do: 8
  defp hit_die_for(c) when c in ~w(sorcerer wizard), do: 6
  defp hit_die_for(_), do: 8

  defp find_spell(%Character{spells: spells}, name),
    do: Enum.find(spells, &(&1.name == name))

  defp noop, do: fn w -> {:ok, w} end

  defp sum(count, sides, roller), do: Enum.sum(for _ <- 1..count, do: roller.(sides))

  defp signed(n) when n >= 0, do: "+#{n}"
  defp signed(n), do: "#{n}"

  defp mode_tag(:advantage), do: " (advantage)"
  defp mode_tag(:disadvantage), do: " (disadvantage)"
  defp mode_tag(_), do: ""

  @abilities %{
    str: "Strength",
    dex: "Dexterity",
    con: "Constitution",
    int: "Intelligence",
    wis: "Wisdom",
    cha: "Charisma"
  }

  defp ability_label(a) when is_atom(a), do: Map.get(@abilities, a, inspect(a))
end
