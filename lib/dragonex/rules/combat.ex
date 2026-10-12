defmodule Dragonex.Rules.Combat do
  @moduledoc """
  Pure 5e combat resolution. Every roll goes through an injected `roller`
  (a `(sides -> value)` fn) so tests are deterministic; production passes
  `&Dragonex.Dice.roll/1`.

  These functions only *compute* outcomes from inputs — they never touch the
  shared world. The Session/tools layer applies the results.
  """

  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.{Character, Spell, Weapon}
  alias Dragonex.Rules.{Ability, Effects, Skills}

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
  and `weapon.ranged == true`. Lucky (D66): a halfling's kept nat 1 is
  rerolled once and the new die is used.
  """
  @spec attack_roll(
          Character.t(),
          Weapon.t(),
          non_neg_integer(),
          roller(),
          :normal | :advantage | :disadvantage
        ) :: attack_outcome()
  def attack_roll(%Character{} = attacker, %Weapon{} = weapon, target_ac, roller, mode \\ :normal) do
    {kind, d20, total, _lucky} = attack_roll_tagged(attacker, weapon, target_ac, roller, mode)
    {kind, d20, total}
  end

  @doc """
  Tagged attack roll (D66 Lucky): `attack_roll/5` plus the Lucky reroll tag
  (`nil` when it didn't fire) as a fourth element, so the Actions layer can
  render the reroll in the chat breakdown. D85 appends the Bless bonus to
  the same optional tag. The mechanics live HERE — the
  plain `attack_roll/5` delegates and drops the tag.
  """
  @spec attack_roll_tagged(
          Character.t(),
          Weapon.t(),
          non_neg_integer(),
          roller(),
          :normal | :advantage | :disadvantage
        ) :: {:hit | :miss | :crit, pos_integer(), integer(), String.t() | nil}
  def attack_roll_tagged(
        %Character{} = attacker,
        %Weapon{} = weapon,
        target_ac,
        roller,
        mode \\ :normal
      ) do
    {d20, lucky} = maybe_lucky(attacker, roll_d20(roller, mode), roller)
    bless = Effects.bless_bonus(attacker, roller)
    lucky = Effects.tag(lucky, bless)

    total =
      d20 + Ability.proficiency(attacker.level) + ability_for_weapon(attacker, weapon) +
        fighting_style_attack_bonus(attacker, weapon) + bless

    cond do
      d20 == 20 -> {:crit, d20, total, lucky}
      d20 == 1 -> {:miss, d20, total, lucky}
      total >= target_ac -> {:hit, d20, total, lucky}
      true -> {:miss, d20, total, lucky}
    end
  end

  @doc """
  Damage for an attack outcome.

  A normal hit rolls the weapon dice once + the ability modifier; a crit rolls
  the weapon dice twice + the ability modifier (5e doubles the dice, not the
  flat modifier). Dueling (D48): +2 when `attacker.fighting_style == "dueling"`
  and `weapon.ranged != true`. Savage Attacks (D69): a half-orc's melee crit
  rolls ONE extra weapon die (not doubled).
  """
  @spec damage_roll(Character.t(), Weapon.t(), :hit | :crit, roller()) :: non_neg_integer()
  def damage_roll(%Character{} = attacker, %Weapon{} = weapon, outcome, roller) do
    {total, _savage} = damage_roll_tagged(attacker, weapon, outcome, roller)
    damage_total(total)
  end

  @doc "Minimum damage is zero, after summing the ability penalty and same-type bonuses."
  @spec damage_total(integer()) :: non_neg_integer()
  def damage_total(amount) when is_integer(amount), do: max(0, amount)

  @doc """
  Tagged weapon subtotal (D69 Savage Attacks): `damage_roll/4` plus the extra
  Savage die (0 when it didn't fire) as a second element, so the Actions
  layer can render it in the swing breakdown. The subtotal can be negative:
  Actions adds Sneak Attack, rage and Hunter's Mark before `damage_total/1`.
  The plain `damage_roll/4` finalizes damage without those additional bonuses.
  """
  @spec damage_roll_tagged(Character.t(), Weapon.t(), :hit | :crit, roller()) ::
          {integer(), integer()}
  def damage_roll_tagged(%Character{} = attacker, %Weapon{} = weapon, outcome, roller) do
    multiplier = if outcome == :crit, do: 2, else: 1
    dice = sum_weapon_dice(weapon.dice, multiplier, roller)
    savage = savage_die(attacker, weapon, outcome, roller)

    {dice + savage + ability_for_weapon(attacker, weapon) +
       fighting_style_damage_bonus(attacker, weapon), savage}
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
  is proficient in the relevant ability save. Lucky (D66): a halfling's kept
  nat 1 is rerolled once and the new die is used.
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
    {d20, total, _success?, _lucky} = saving_throw_tagged(target, save_ability, dc, roller, mode)
    {d20, total, total >= dc}
  end

  @doc """
  Tagged saving throw (D66 Lucky): `saving_throw/5` plus the Lucky reroll tag
  (`nil` when it didn't fire) as a fourth element — see `attack_roll_tagged/5`.
  """
  @spec saving_throw_tagged(
          Character.t(),
          ability(),
          integer(),
          roller(),
          :normal | :advantage | :disadvantage
        ) ::
          {pos_integer(), integer(), boolean(), String.t() | nil}
  def saving_throw_tagged(%Character{} = target, save_ability, dc, roller, mode \\ :normal) do
    {d20, lucky} = maybe_lucky(target, roll_d20(roller, mode), roller)
    bless = Effects.bless_bonus(target, roller)
    lucky = Effects.tag(lucky, bless)

    total =
      d20 + Character.modifier(target, save_ability) + save_prof(target, save_ability) + bless

    {d20, total, total >= dc, lucky}
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
  only covers checks that don't already include the bonus. `skill` (default
  nil) is the check's canonical skill key: when trained AND expertised (D73)
  the bonus doubles instead.
  """
  @spec ability_check(
          Character.t(),
          ability(),
          integer(),
          roller(),
          boolean(),
          :normal | :advantage | :disadvantage,
          String.t() | nil
        ) ::
          {pos_integer(), integer(), boolean()}
  def ability_check(
        %Character{} = c,
        ability,
        dc,
        roller,
        proficient \\ false,
        mode \\ :normal,
        skill \\ nil
      ) do
    {d20, total, _success?, _lucky} =
      ability_check_tagged(c, ability, dc, roller, proficient, mode, skill)

    {d20, total, total >= dc}
  end

  @doc """
  Tagged ability check (D66 Lucky): `ability_check/6` plus the Lucky reroll
  tag (`nil` when it didn't fire) as a fourth element — see
  `attack_roll_tagged/5`. `skill` (D73) rides through to
  `check_proficiency/3` for the Expertise doubling.
  """
  @spec ability_check_tagged(
          Character.t(),
          ability(),
          integer(),
          roller(),
          boolean(),
          :normal | :advantage | :disadvantage,
          String.t() | nil
        ) ::
          {pos_integer(), integer(), boolean(), String.t() | nil}
  def ability_check_tagged(
        %Character{} = c,
        ability,
        dc,
        roller,
        proficient \\ false,
        mode \\ :normal,
        skill \\ nil
      ) do
    {d20, lucky} = maybe_lucky(c, roll_d20(roller, mode), roller)
    {prof, _kind} = check_proficiency(c, proficient, skill)
    total = d20 + Character.modifier(c, ability) + prof
    {d20, total, total >= dc, lucky}
  end

  @doc """
  Proficiency bonus added to an ability check, with its kind (D60, D73).

    * `{:doubled, :expert}` — trained (`proficient` true) AND expertised
      in `skill` (D73): the bonus DOUBLED. JoaT never applies (already
      proficient).
    * `{:full, :prof}` — trained (`proficient` true): the whole bonus.
    * `{:half, :joat}` — untrained but bard L2+ (Jack of All Trades):
      `div(proficiency, 2)`, floored.
    * `{:none, 0}` — anything else, as in v1.

  `skill` (default nil) is the canonical skill key when the check names
  one — Expertise only applies on that route (never to a raw ability).
  Public so `Actions.check` renders the same breakdown the roll used.
  """
  @spec check_proficiency(Character.t(), boolean(), String.t() | nil) ::
          {integer(), :expert | :prof | :joat | :none}
  def check_proficiency(%Character{} = c, proficient, skill \\ nil) do
    prof = Ability.proficiency(c.level)

    cond do
      proficient and expertised?(c, skill) -> {prof * 2, :expert}
      proficient -> {prof, :prof}
      joat?(c) -> {div(prof, 2), :joat}
      true -> {0, :none}
    end
  end

  # D73 Expertise: the check's skill is in the sheet's `expertise` list
  # (normalized membership — custom/legacy data may differ in case or
  # separators, same as skill_trained? in Actions).
  defp expertised?(%Character{expertise: list}, skill)
       when is_binary(skill) and is_list(list) do
    Enum.any?(list, fn e -> is_binary(e) and Skills.normalize(e) == skill end)
  end

  defp expertised?(_, _), do: false

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

  # Lucky (D66): when a halfling's KEPT d20 (after advantage/disadvantage)
  # shows a 1, reroll it ONCE and use the new result (RAW "must use the new
  # roll" — not keep-best). The reroll goes through the same `roller`, so the
  # RollLog group records both dice. Death saves take no character and never
  # reach this. Returns `{die, lucky_tag}`; the tag is `nil` when it didn't
  # fire.
  defp maybe_lucky(%Character{race: "halfling"}, 1, roller) do
    reroll = roller.(20)
    {reroll, dgettext("engine", "(Lucky: 1→%{reroll})", reroll: reroll)}
  end

  defp maybe_lucky(_character, d20, _roller), do: {d20, nil}

  # D69 Savage Attacks: when a half-orc scores a melee crit, roll ONE of the
  # weapon's damage dice one additional time — a single die of the weapon's
  # size (never the whole dice expression, never doubled). Ranged weapons,
  # non-crits and non-half-orcs get 0.
  defp savage_die(
         %Character{race: "half-orc"},
         %Weapon{dice: dice, ranged: ranged},
         :crit,
         roller
       )
       when ranged != true do
    {_count, sides} = parse_dice(dice)
    roller.(sides)
  end

  defp savage_die(_attacker, _weapon, _outcome, _roller), do: 0

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
