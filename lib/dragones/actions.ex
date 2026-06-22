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

  alias Dragones.{Character, Dice, Rules.Combat, World}

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
  @spec attack(World.t(), String.t(), String.t(), String.t(), roller()) :: result()
  def attack(world, attacker, target, weapon_name, roller) do
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
            {kind, d20, total} = Combat.attack_roll(a, weapon, t.ac, roller)

            case kind do
              :miss ->
                {:ok,
                 "#{attacker} swings at #{target} — miss (d20 #{d20}: #{total} vs AC #{t.ac}).",
                 noop()}

              k ->
                dmg = Combat.damage_roll(a, weapon, k, roller)
                verb = if k == :crit, do: "CRITS", else: "hits"

                {:ok,
                 "#{attacker} #{verb} #{target} (d20 #{d20}: #{total} vs AC #{t.ac}) for #{dmg} #{weapon.damage_type}.",
                 World.apply_damage(target, dmg)}
            end
        end
    end
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
            resolve_spell(c, caster_name, t, target_name, spell, roller)
        end
    end
  end

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

        {:ok, "#{target} is healed for #{applied} hp (#{hp} → #{hp + applied}).",
         World.heal(target, rolled)}
    end
  end

  # ------------------------------------------------------------- spell helpers

  defp resolve_spell(c, caster_name, t, target_name, spell, roller) do
    case spell.kind do
      :automatic ->
        dmg = dice(spell, roller)
        verb = spell_damage_verb(spell, dmg)

        {:ok,
         "#{caster_name} casts #{spell.name}; #{target_name} takes #{dmg} #{spell.damage_type}#{verb}.",
         World.apply_damage(target_name, dmg)}

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

  defp find_spell(%Character{spells: spells}, name),
    do: Enum.find(spells, &(&1.name == name))

  defp noop, do: fn w -> {:ok, w} end

  defp sum(count, sides, roller), do: Enum.sum(for _ <- 1..count, do: roller.(sides))
end
