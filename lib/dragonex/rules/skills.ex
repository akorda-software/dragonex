defmodule Dragonex.Rules.Skills do
  @moduledoc """
  Pure 5e skill table: the 18 SRD skills → governing ability (D60).

  Skill keys are the English snake_case ids the sheet already stores in
  `Character.skill_proficiencies` (`"stealth"`, `"animal_handling"`, …).
  Input from the model is normalized before lookup (case, spaces, hyphens),
  so `"Animal Handling"` / `"animal-handling"` / `"animal_handling"` are the
  same skill. Lookup happens BEFORE ability parsing — `"intimidation"` is a
  CHA skill, not the `int` ability (the ability parser is prefix-based).

  No state, no IO; string keys only (never creates atoms from model input,
  D8's rule applied outside the Codec too).
  """

  @skill_abilities %{
    "athletics" => :str,
    "acrobatics" => :dex,
    "sleight_of_hand" => :dex,
    "stealth" => :dex,
    "arcana" => :int,
    "history" => :int,
    "investigation" => :int,
    "nature" => :int,
    "religion" => :int,
    "animal_handling" => :wis,
    "insight" => :wis,
    "medicine" => :wis,
    "perception" => :wis,
    "survival" => :wis,
    "deception" => :cha,
    "intimidation" => :cha,
    "performance" => :cha,
    "persuasion" => :cha
  }

  @type ability :: :str | :dex | :con | :int | :wis | :cha

  @doc "All 18 SRD skill keys."
  @spec all() :: [String.t()]
  def all, do: Map.keys(@skill_abilities)

  @doc """
  Normalize skill input to the canonical snake_case key:
  `"Animal Handling"`, `"animal-handling"`, `:"Sleight of Hand"` →
  `"animal_handling"` / `"sleight_of_hand"`. Not a guarantee that the
  result is a known skill — pair with `known?/1` or `ability/1`.
  """
  @spec normalize(String.t() | atom()) :: String.t()
  def normalize(s) when is_binary(s),
    do: s |> String.downcase() |> String.trim() |> String.replace(~r/[\s\-]+/, "_")

  def normalize(a) when is_atom(a), do: a |> Atom.to_string() |> normalize()

  @doc "Is this a known SRD skill (after normalization)?"
  @spec known?(term()) :: boolean()
  def known?(input) when is_binary(input) or is_atom(input),
    do: Map.has_key?(@skill_abilities, normalize(input))

  def known?(_), do: false

  @doc "Governing ability for a known skill; `:error` otherwise."
  @spec ability(String.t() | atom()) :: {:ok, ability()} | :error
  def ability(input) do
    case Map.fetch(@skill_abilities, normalize(input)) do
      {:ok, ab} -> {:ok, ab}
      :error -> :error
    end
  end

  @doc "Brief example list for directive error messages."
  @spec examples() :: String.t()
  def examples, do: "stealth, athletics, persuasion, investigation, animal_handling"
end
