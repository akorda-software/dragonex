defmodule Dragones.Spell do
  @moduledoc """
  A spell.

  `kind` is one of:
    * `:save`      — the target rolls a save (vs `spell_save_dc/2`).
    * `:attack`    — the caster rolls a spell attack (vs the target's AC).
    * `:automatic` — no roll needed (e.g. magic missile).

  `casting_ability` derives the save DC / attack bonus. `save_ability` is
  required when `kind == :save`.
  """

  @type ability :: :str | :dex | :con | :int | :wis | :cha
  @type kind :: :save | :attack | :automatic

  defstruct [:name, :level, :kind, :casting_ability, :save_ability, :dice, :damage_type, :effect]

  @type t :: %__MODULE__{
          name: String.t(),
          level: non_neg_integer(),
          kind: kind(),
          casting_ability: ability(),
          save_ability: ability() | nil,
          dice: String.t() | nil,
          damage_type: String.t() | nil,
          effect: String.t() | nil
        }
end
