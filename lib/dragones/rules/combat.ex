defmodule Dragones.Rules.Combat do
  @moduledoc """
  Pure 5e combat resolution. Every roll goes through an injected `roller`
  (a `(sides -> value)` fn) so tests are deterministic; production passes
  `&Dragones.Dice.roll/1`.

  These functions only *compute* outcomes from inputs — they never touch the
  shared world. The Session/tools layer applies the results.
  """

  alias Dragones.{Character, Spell, Weapon}
  alias Dragones.Rules.Ability

  @type roller :: (pos_integer() -> pos_integer())
  @type ability :: :str | :dex | :con | :int | :wis | :cha

  @type attack_outcome :: {:hit | :miss | :crit, d20 :: pos_integer(), total :: integer()}

  @doc "Initiative roll: d20 + dex modifier. Returns both the die and the total."
  @spec roll_initiative(Character.t(), roller()) :: {pos_integer(), integer()}
  def roll_initiative(%Character{} = c, roller) do
    d20 = roller.(20)
    {d20, d20 + Character.modifier(c, :dex)}
  end

  @doc """
  Resolve an attack: d20 + proficiency + ability vs the target's AC.

    * nat 20 — critical hit (auto-hit).
    * nat 1  — automatic miss.
    * else   — hit when the total meets the AC.
  """
  @spec attack_roll(Character.t(), Weapon.t(), non_neg_integer(), roller()) :: attack_outcome()
  def attack_roll(%Character{} = attacker, %Weapon{} = weapon, target_ac, roller) do
    d20 = roller.(20)
    total = d20 + Ability.proficiency(attacker.level) + ability_for_weapon(attacker, weapon)

    cond do
      d20 == 20 -> {:crit, d20, total}
      d20 == 1 -> {:miss, d20, total}
      total >= target_ac -> {:hit, d20, total}
      true -> {:miss, d20, total}
    end
  end

  @doc """
  Damage for an attack outcome.

  A normal hit rolls the weapon dice once + the ability modifier; a crit rolls
  the weapon dice twice + the ability modifier (5e doubles the dice, not the
  flat modifier).
  """
  @spec damage_roll(Character.t(), Weapon.t(), :hit | :crit, roller()) :: integer()
  def damage_roll(%Character{} = attacker, %Weapon{} = weapon, outcome, roller) do
    multiplier = if outcome == :crit, do: 2, else: 1
    dice = sum_weapon_dice(weapon.dice, multiplier, roller)
    dice + ability_for_weapon(attacker, weapon)
  end

  @doc "Spell save DC: 8 + proficiency + casting ability modifier."
  @spec spell_save_dc(Character.t(), Spell.t()) :: integer()
  def spell_save_dc(%Character{} = caster, %Spell{casting_ability: ab}) do
    8 + Ability.proficiency(caster.level) + Character.modifier(caster, ab)
  end

  @doc "Spell attack bonus: proficiency + casting ability modifier."
  @spec spell_attack_bonus(Character.t(), Spell.t()) :: integer()
  def spell_attack_bonus(%Character{} = caster, %Spell{casting_ability: ab}) do
    Ability.proficiency(caster.level) + Character.modifier(caster, ab)
  end

  @doc """
  Resolve a saving throw against a DC.

  Returns `{d20, total, success?}`. Adds the proficiency bonus when the target
  is proficient in the relevant ability save.
  """
  @spec saving_throw(Character.t(), ability(), integer(), roller()) ::
          {pos_integer(), integer(), boolean()}
  def saving_throw(%Character{} = target, save_ability, dc, roller) do
    d20 = roller.(20)
    total = d20 + Character.modifier(target, save_ability) + save_prof(target, save_ability)
    {d20, total, total >= dc}
  end

  @doc """
  A death saving throw (d20, no modifier).

  Returns a tagged tuple with deltas to apply to the death-save tracker:

    * `{:success, d20, 0, 1}` — rolled 10-19.
    * `{:fail, d20, 1, 0}`    — rolled 2-9.
    * `{:crit_fail, 1, 2, 0}` — nat 1 counts as two fails.
    * `{:revive, 20, 0, 0}`   — nat 20: regain 1 hp and become conscious.

  Three fails = death; three successes = stable (enforced by the caller).
  """
  @spec death_save(roller()) ::
          {:success, pos_integer(), 0, 1}
          | {:fail, pos_integer(), 1, 0}
          | {:crit_fail, 1, 2, 0}
          | {:revive, 20, 0, 0}
  def death_save(roller) do
    d20 = roller.(20)

    cond do
      d20 == 20 -> {:revive, 20, 0, 0}
      d20 == 1 -> {:crit_fail, 1, 2, 0}
      d20 < 10 -> {:fail, d20, 1, 0}
      true -> {:success, d20, 0, 1}
    end
  end

  # Ability modifier applied to hit and damage for a given weapon.
  defp ability_for_weapon(%Character{} = c, %Weapon{finesse: true}) do
    max(Character.modifier(c, :str), Character.modifier(c, :dex))
  end

  defp ability_for_weapon(%Character{} = c, %Weapon{ranged: true}) do
    Character.modifier(c, :dex)
  end

  defp ability_for_weapon(%Character{} = c, %Weapon{attack_ability: ab}) do
    Character.modifier(c, ab)
  end

  defp sum_weapon_dice(dice_expr, multiplier, roller) do
    {count, sides} = parse_dice(dice_expr)
    Enum.sum(for _ <- 1..(count * multiplier), do: roller.(sides))
  end

  defp parse_dice(expr) do
    case Regex.run(~r/^(\d+)d(\d+)$/, String.trim(expr)) do
      [_, count, sides] ->
        {String.to_integer(count), String.to_integer(sides)}

      _ ->
        raise ArgumentError, "unparseable weapon dice: #{inspect(expr)}"
    end
  end

  defp save_prof(%Character{level: level, saving_proficiencies: profs}, ability)
       when is_list(profs) do
    if Atom.to_string(ability) in profs, do: Ability.proficiency(level), else: 0
  end
end
