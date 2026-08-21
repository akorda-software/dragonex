defmodule Dragonex.Weapon do
  @moduledoc """
  A weapon.

  `dice` is a 5e expression like "1d8". `attack_ability` is the ability used to
  hit; it is ignored when `finesse: true` (Combat then picks max(str, dex)) or
  `ranged: true` (Combat always uses dex, per 5e ranged-weapon rules).
  """

  @type ability :: :str | :dex | :con | :int | :wis | :cha

  defstruct [:name, :dice, :damage_type, :attack_ability, finesse: false, ranged: false]

  @type t :: %__MODULE__{
          name: String.t(),
          dice: String.t(),
          damage_type: String.t(),
          attack_ability: ability(),
          finesse: boolean(),
          ranged: boolean()
        }
end
