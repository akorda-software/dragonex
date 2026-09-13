defmodule Dragonex.Rules.Combat do
  @moduledoc """
  Pure 5e combat resolution. Every roll goes through an injected `roller`
  (a `(sides -> value)` fn) so tests are deterministic; production passes
  `&Dragonex.Dice.roll/1`.

  These functions only *compute* outcomes from inputs — they never touch the
  shared world. The Session/tools layer applies the results.
  """

  alias Dragonex.{Character, Spell, Weapon}
  alias Dragonex.Rules.Ability

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

  Archery (D48): +2 to the total when `attacker.fighting_style == "archery"`
  and `weapon.ranged == true`.
  """
  @spec attack_roll(
          Character.t(),
          Weapon.t(),
          non_neg_integer(),
          roller(),
          :normal | :advantage | :disadvantage
        ) :: attack_outcome()
  def attack_roll(%Character{} = attacker, %Weapon{} = weapon, target_ac, roller, mode \\ :normal) do
    d20 = roll_d20(roller, mode)

    total =
      d20 + Ability.proficiency(attacker.level) + ability_for_weapon(attacker, weapon) +
        fighting_style_attack_bonus(attacker, weapon)

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
  flat modifier). Dueling (D48): +2 when `attacker.fighting_style == "dueling"`
  and `weapon.ranged != true`.
  """
  @spec damage_roll(Character.t(), Weapon.t(), :hit | :crit, roller()) :: integer()
  def damage_roll(%Character{} = attacker, %Weapon{} = weapon, outcome, roller) do
    multiplier = if outcome == :crit, do: 2, else: 1
    dice = sum_weapon_dice(weapon.dice, multiplier, roller)
    dice + ability_for_weapon(attacker, weapon) + fighting_style_damage_bonus(attacker, weapon)
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
  @spec saving_throw(
          Character.t(),
          ability(),
          integer(),
          roller(),
          :normal | :advantage | :disadvantage
        ) ::
          {pos_integer(), integer(), boolean()}
  def saving_throw(%Character{} = target, save_ability, dc, roller, mode \\ :normal) do
    d20 = roll_d20(roller, mode)
    total = d20 + Character.modifier(target, save_ability) + save_prof(target, save_ability)
    {d20, total, total >= dc}
  end

  @doc """
  Resolve an ability check against a DC the DM sets.

  By 5e RAW: `d20 + ability modifier (+ proficiency if the character is trained
  for this check)`, vs the DC. No natural-1/20 auto outcomes (those only apply
  to attack rolls).

  `proficient` (default false) adds the character's proficiency bonus —
  `Actions.check` derives it from the sheet's `skill_proficiencies` when the
  caller names a skill (D60). When not proficient, a bard of level 2+ adds
  half proficiency instead (Jack of All Trades, D60) — never both: RAW JoaT
  only covers checks that don't already include the bonus.
  """
  @spec ability_check(
          Character.t(),
          ability(),
          integer(),
          roller(),
          boolean(),
          :normal | :advantage | :disadvantage
        ) ::
          {pos_integer(), integer(), boolean()}
  def ability_check(%Character{} = c, ability, dc, roller, proficient \\ false, mode \\ :normal) do
    d20 = roll_d20(roller, mode)
    {prof, _kind} = check_proficiency(c, proficient)
    total = d20 + Character.modifier(c, ability) + prof
    {d20, total, total >= dc}
  end

  @doc """
  Proficiency bonus added to an ability check, with its kind (D60).

    * `{:full, :prof}` — trained (`proficient` true): the whole bonus.
    * `{:half, :joat}` — untrained but bard L2+ (Jack of All Trades):
      `div(proficiency, 2)`, floored.
    * `{:none, 0}` — anything else, as in v1.

  Public so `Actions.check` renders the same breakdown the roll used.
  """
  @spec check_proficiency(Character.t(), boolean()) :: {integer(), :prof | :joat | :none}
  def check_proficiency(%Character{} = c, proficient) do
    prof = Ability.proficiency(c.level)

    cond do
      proficient -> {prof, :prof}
      joat?(c) -> {div(prof, 2), :joat}
      true -> {0, :none}
    end
  end

  # Jack of All Trades (D60): bard L2+ adds half proficiency to ability
  # checks that don't already include it. Reached only when not proficient.
  defp joat?(%Character{class: "bard", level: level}), do: is_integer(level) and level >= 2
  defp joat?(_), do: false

  @doc """
  A death saving throw (d20, no ability modifier).

  Returns a tagged tuple with deltas to apply to the death-save tracker:

    * `{:success, d20, 0, 1}` — rolled 10-19.
    * `{:fail, d20, 1, 0}`    — rolled 2-9.
    * `{:crit_fail, 1, 2, 0}` — nat 1 counts as two fails.
    * `{:revive, 20, 0, 0}`   — nat 20: regain 1 hp and become conscious.

  Three fails = death; three successes = stable (enforced by the caller).

  `bonus` (default 0) is a flat modifier to the save total — Aura of
  Protection (D61) applies to death saves (RAW). It shifts the 10 threshold
  only; nat 1/20 keep their special outcomes (they key off the die).
  """
  @spec death_save(roller(), integer()) ::
          {:success, pos_integer(), 0, 1}
          | {:fail, pos_integer(), 1, 0}
          | {:crit_fail, 1, 2, 0}
          | {:revive, 20, 0, 0}
  def death_save(roller, bonus \\ 0) do
    d20 = roller.(20)

    cond do
      d20 == 20 -> {:revive, 20, 0, 0}
      d20 == 1 -> {:crit_fail, 1, 2, 0}
      d20 + bonus >= 10 -> {:success, d20, 0, 1}
      true -> {:fail, d20, 1, 0}
    end
  end

  # Roll a d20, honouring advantage (keep higher of two) / disadvantage (lower).
  # Both dice go through `roller`, so instrumentation (the UI dice modal) sees them.
  defp roll_d20(roller, :advantage) do
    {a, b} = {roller.(20), roller.(20)}
    max(a, b)
  end

  defp roll_d20(roller, :disadvantage) do
    {a, b} = {roller.(20), roller.(20)}
    min(a, b)
  end

  defp roll_d20(roller, _), do: roller.(20)

  # Ability modifier applied to hit and damage for a given weapon.
  defp fighting_style_attack_bonus(%Character{fighting_style: "archery"}, %Weapon{ranged: true}),
    do: 2

  defp fighting_style_attack_bonus(_, _), do: 0

  defp fighting_style_damage_bonus(%Character{fighting_style: "dueling"}, %Weapon{ranged: ranged})
       when ranged != true,
       do: 2

  defp fighting_style_damage_bonus(_, _), do: 0

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
