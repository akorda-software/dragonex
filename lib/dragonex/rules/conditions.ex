defmodule Dragonex.Rules.Conditions do
  @moduledoc """
  5e condition → attack / save / check effects.

  Combines condition sources with the model's requested mode using RAW
  cancellation: any advantage + any disadvantage = `:normal`.

  Auto-fail STR/DEX saves (paralyzed, stunned, unconscious, petrified) skip
  the roll. Death saves are not ability saves and are not adjusted here.

  v1 simplifications: frightened always applies (no line-of-sight to the
  source); blinded/deafened do not auto-fail checks (the engine does not
  know if a check requires sight/hearing); spell attacks are treated as
  ranged for prone.
  """

  alias Dragonex.Character

  @type mode :: :normal | :advantage | :disadvantage
  @type save_outcome :: :auto_fail | {:roll, mode()}

  @attack_self_disadvantage ~w(poisoned frightened blinded restrained prone)
  @attack_self_advantage ~w(invisible)
  @attack_vs_advantage ~w(blinded stunned paralyzed unconscious restrained petrified)
  @attack_vs_disadvantage ~w(invisible)
  @check_disadvantage ~w(poisoned frightened)
  @auto_fail_saves ~w(paralyzed stunned unconscious petrified)

  @doc "Effective attack-roll mode for `attacker` vs `target`."
  @spec attack_mode(Character.t(), Character.t(), keyword()) :: mode()
  def attack_mode(%Character{} = attacker, %Character{} = target, opts \\ []) do
    requested = Keyword.get(opts, :requested, :normal)
    ranged? = Keyword.get(opts, :ranged, false) == true
    attacker_conds = Character.condition_names(attacker)
    target_conds = Character.condition_names(target)

    advantage? =
      requested == :advantage or
        Enum.any?(attacker_conds, &(&1 in @attack_self_advantage)) or
        target_grants_attack_advantage?(target_conds, ranged?)

    disadvantage? =
      requested == :disadvantage or
        Enum.any?(attacker_conds, &(&1 in @attack_self_disadvantage)) or
        target_grants_attack_disadvantage?(target_conds, ranged?)

    combine(advantage?, disadvantage?)
  end

  @doc "Save outcome for `target` on `ability`. Auto-fail short-circuits STR/DEX."
  @spec save_mode(Character.t(), atom(), mode()) :: save_outcome()
  def save_mode(%Character{} = target, ability, requested \\ :normal) do
    conds = Character.condition_names(target)

    if ability in [:str, :dex] and Enum.any?(conds, &(&1 in @auto_fail_saves)) do
      :auto_fail
    else
      advantage? = requested == :advantage

      disadvantage? =
        requested == :disadvantage or (ability == :dex and "restrained" in conds)

      {:roll, combine(advantage?, disadvantage?)}
    end
  end

  @doc "Effective ability-check mode for `character`."
  @spec check_mode(Character.t(), atom(), mode()) :: mode()
  def check_mode(%Character{} = character, _ability, requested \\ :normal) do
    conds = Character.condition_names(character)
    advantage? = requested == :advantage

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

  defp target_grants_attack_advantage?(conds, ranged?) do
    (not ranged? and "prone" in conds) or
      Enum.any?(conds, &(&1 in @attack_vs_advantage))
  end

  defp target_grants_attack_disadvantage?(conds, ranged?) do
    (ranged? and "prone" in conds) or
      Enum.any?(conds, &(&1 in @attack_vs_disadvantage))
  end
end
