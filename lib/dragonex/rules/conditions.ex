defmodule Dragonex.Rules.Conditions do
  @moduledoc """
  5e condition → attack / save / check effects.

  Combines condition sources with the model's requested mode using RAW
  cancellation: any advantage + any disadvantage = `:normal`.

  Auto-fail STR/DEX saves (paralyzed, stunned, unconscious, petrified) skip
  the roll. Death saves are not ability saves and are not adjusted here.

  Danger Sense (D58): a barbarian L2+ has advantage on DEX saves through
  every route that consults `save_mode/3`. The RAW "unless incapacitated"
  cutoff is the auto-fail set: those conditions short-circuit STR/DEX
  saves before the advantage is computed.

  v1 simplifications: frightened always applies (no line-of-sight to the
  source); blinded/deafened do not auto-fail checks (the engine does not
  know if a check requires sight/hearing); spell attacks are treated as
  ranged for prone.
  """

  alias Dragonex.Character

  @type mode :: :normal | :advantage | :disadvantage
  @type save_outcome :: :auto_fail | {:roll, mode()}

  @attack_self_disadvantage ~w(poisoned frightened blinded restrained prone)
  @attack_self_advantage ~w(invisible hidden)
  @attack_vs_advantage ~w(blinded stunned paralyzed unconscious restrained petrified)
  @attack_vs_disadvantage ~w(invisible)
  @check_disadvantage ~w(poisoned frightened)
  @auto_fail_saves ~w(paralyzed stunned unconscious petrified)

  @doc """
  Effective attack-roll mode for `attacker` vs `target`.

  Reckless Attack (D44): melee Strength attacks by a reckless attacker have
  advantage; any attack against a reckless target has advantage. Combines
  with conditions via `combine/2`.
  """
  @spec attack_mode(Character.t(), Character.t(), keyword()) :: mode()
  def attack_mode(%Character{} = attacker, %Character{} = target, opts \\ []) do
    requested = Keyword.get(opts, :requested, :normal)
    ranged? = Keyword.get(opts, :ranged, false) == true
    attacker_conds = Character.condition_names(attacker)
    target_conds = Character.condition_names(target)

    advantage? =
      requested == :advantage or
        Enum.any?(attacker_conds, &(&1 in @attack_self_advantage)) or
        target_grants_attack_advantage?(target_conds, ranged?) or
        reckless_attacker_advantage?(attacker, opts) or
        target.reckless == true

    disadvantage? =
      requested == :disadvantage or
        Enum.any?(attacker_conds, &(&1 in @attack_self_disadvantage)) or
        target_grants_attack_disadvantage?(target_conds, ranged?)

    combine(advantage?, disadvantage?)
  end

  @doc """
  Save outcome for `target` on `ability`. Auto-fail short-circuits STR/DEX.

  Danger Sense (D58): barbarian L2+ gets advantage on DEX saves (combined
  via `combine/2` — a condition's disadvantage, e.g. restrained, cancels
  to normal). Incapacitating conditions never reach this advantage: the
  auto-fail set short-circuits DEX saves first.

  Gnome Cunning (D71): `gnome_advantage: true` adds one more advantage
  source for mental saves (INT/WIS/CHA against magic — the cast_spell and
  turn_undead sites inject it); it cancels against any disadvantage
  (Heightened D65, conditions) through the same `combine/2`.

  Dwarven Resilience (D76): `dwarf_advantage: true` adds one more
  advantage source for saves against poison (the cast_spell :save branch
  injects it when the spell's damage_type is "poison" and the target is
  a dwarf — any save ability); same `combine/2` cancellation.
  """
  @spec save_mode(Character.t(), atom(), mode(), keyword()) :: save_outcome()
  def save_mode(%Character{} = target, ability, requested \\ :normal, opts \\ []) do
    conds = Character.condition_names(target)

    if ability in [:str, :dex] and Enum.any?(conds, &(&1 in @auto_fail_saves)) do
      :auto_fail
    else
      advantage? =
        requested == :advantage or danger_sense?(target, ability) or
          Keyword.get(opts, :gnome_advantage) == true or
          Keyword.get(opts, :dwarf_advantage) == true

      disadvantage? =
        requested == :disadvantage or (ability == :dex and "restrained" in conds)

      {:roll, combine(advantage?, disadvantage?)}
    end
  end

  @doc "Effective ability-check mode for `character`."
  @spec check_mode(Character.t(), atom(), mode()) :: mode()
  def check_mode(%Character{} = character, ability, requested \\ :normal) do
    conds = Character.condition_names(character)

    advantage? =
      requested == :advantage or (ability == :str and character.raging == true)

    disadvantage? =
      requested == :disadvantage or Enum.any?(conds, &(&1 in @check_disadvantage))

    combine(advantage?, disadvantage?)
  end

  @doc "5e cancellation: any advantage + any disadvantage = normal."
  @spec combine(boolean(), boolean()) :: mode()
  def combine(true, true), do: :normal
  def combine(true, false), do: :advantage
  def combine(false, true), do: :disadvantage
  def combine(false, false), do: :normal

  # D58 Danger Sense: barbarian L2+ gains advantage on DEX saves. The
  # incapacitating conditions modeled here (@auto_fail_saves) auto-fail DEX
  # and short-circuit in save_mode/3, so the defensive re-check below is the
  # RAW "unless incapacitated" cutoff for v1.
  defp danger_sense?(%Character{} = target, :dex) do
    target.class == "barbarian" and (target.level || 1) >= 2 and
      not Enum.any?(Character.condition_names(target), &(&1 in @auto_fail_saves))
  end

  defp danger_sense?(_target, _ability), do: false

  defp reckless_attacker_advantage?(%Character{} = attacker, opts) do
    attacker.reckless == true and
      Keyword.get(opts, :ranged, false) != true and
      uses_strength?(attacker, opts)
  end

  defp uses_strength?(%Character{} = attacker, opts) do
    ability = Keyword.get(opts, :attack_ability, :str)
    finesse? = Keyword.get(opts, :finesse, false) == true

    cond do
      finesse? ->
        Character.modifier(attacker, :str) >= Character.modifier(attacker, :dex)

      ability in [:str, "str"] ->
        true

      true ->
        false
    end
  end

  defp target_grants_attack_advantage?(conds, ranged?) do
    (not ranged? and "prone" in conds) or
      Enum.any?(conds, &(&1 in @attack_vs_advantage))
  end

  defp target_grants_attack_disadvantage?(conds, ranged?) do
    (ranged? and "prone" in conds) or
      Enum.any?(conds, &(&1 in @attack_vs_disadvantage))
  end
end
