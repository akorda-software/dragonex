defmodule Dragonex.Heroes.Scoring do
  @moduledoc """
  SRD 5.1 ability-score generation: standard array and point buy.

    * **Standard array**: `[15, 14, 13, 12, 10, 8]` — assigned one per ability.
    * **Point buy**: 27 points. Scores 8–15 pre-racial. Costs per the SRD table:
      8→0, 9→1, 10→2, 11→3, 12→4, 13→5, 14→7, 15→9.

  When the builder is given `:standard_array` or no explicit scores, it
  auto-assigns the array by the class's `priority` order — the highest value to
  the class's most important ability.
  """

  alias Dragonex.Rules.Ability

  @abilities [:str, :dex, :con, :int, :wis, :cha]

  @standard_array [15, 14, 13, 12, 10, 8]

  @point_buy_costs %{
    8 => 0,
    9 => 1,
    10 => 2,
    11 => 3,
    12 => 4,
    13 => 5,
    14 => 7,
    15 => 9
  }

  @point_buy_budget 27

  @type method :: :standard_array | :point_buy | :custom

  @type score_map :: %{
          str: integer(),
          dex: integer(),
          con: integer(),
          int: integer(),
          wis: integer(),
          cha: integer()
        }

  @doc "The standard array values."
  @spec standard_array() :: [integer()]
  def standard_array, do: @standard_array

  @doc "The point-buy budget (27)."
  @spec point_buy_budget() :: pos_integer()
  def point_buy_budget, do: @point_buy_budget

  @doc "Point-buy cost of a single score value (0 for anything outside 8–15)."
  @spec cost_for(integer()) :: non_neg_integer()
  def cost_for(value), do: Map.get(@point_buy_costs, value, 0)

  @doc "Total point-buy cost of a score map (lenient: out-of-range values count 0)."
  @spec point_buy_cost(score_map()) :: non_neg_integer()
  def point_buy_cost(scores) when is_map(scores) do
    Enum.reduce(@abilities, 0, fn ab, acc -> acc + cost_for(Map.get(scores, ab)) end)
  end

  @doc "Points still spendable under the point-buy budget (budget − cost)."
  @spec point_buy_remaining(score_map()) :: integer()
  def point_buy_remaining(scores), do: @point_buy_budget - point_buy_cost(scores)

  @doc """
  Adjust one ability by `delta`, clamping to the 8–15 point-buy range. Lowering
  a score is always allowed; raising is only allowed while the budget holds.
  Returns `{:ok, new_scores}` or `{:error, :no_budget}`.
  """
  @spec apply_delta(score_map(), atom(), integer()) :: {:ok, score_map()} | {:error, :no_budget}
  def apply_delta(scores, ability, delta) do
    current = Map.get(scores, ability, 8)
    desired = max(8, min(15, current + delta))
    tentative = Map.put(scores, ability, desired)

    if point_buy_remaining(tentative) >= 0 or desired < current do
      {:ok, tentative}
    else
      {:error, :no_budget}
    end
  end

  @doc """
  Resolve the user's score input into a concrete `score_map` of base scores
  (pre-racial).

  Accepted inputs:
    * `nil` or `:standard_array` → auto-assign via class priority.
    * `%{method: :standard_array, values: [6 ints]}` → assign by class priority.
    * `%{method: :point_buy, scores: %{str: .., ...}}` → validate point-buy total.
    * `%{str: .., dex: .., ...}` → explicit pre-racial scores (validated 8–20).
  """
  @spec resolve(term(), [atom()]) :: {:ok, score_map()} | {:error, String.t()}
  def resolve(nil, priority), do: assign_array(@standard_array, priority)

  def resolve(:standard_array, priority), do: assign_array(@standard_array, priority)

  def resolve(%{method: :standard_array, values: values}, priority)
      when is_list(values) do
    with :ok <- validate_array(values) do
      assign_array(values, priority)
    end
  end

  def resolve(%{method: :point_buy, scores: scores}, _priority) when is_map(scores) do
    validate_point_buy(scores)
  end

  def resolve(scores, _priority) when is_map(scores) do
    validate_explicit(scores)
  end

  def resolve(other, _priority) do
    {:error, "unrecognized score input: #{inspect(other)}"}
  end

  # --- standard array ---

  defp validate_array(values) when length(values) != 6,
    do: {:error, "standard array must have exactly 6 values"}

  defp validate_array(values) do
    if Enum.sort(values) == Enum.sort(@standard_array) do
      :ok
    else
      {:error,
       "standard array must be exactly #{inspect(@standard_array)}, got: #{inspect(values)}"}
    end
  end

  defp assign_array(values, priority) do
    sorted = Enum.sort(values, :desc)
    ordered_abilities = order_by_priority(priority)
    pairs = Enum.zip(ordered_abilities, sorted)
    {:ok, Map.new(pairs)}
  end

  # Ensures every ability is covered, placing unprioritized ones at the end
  # in canonical order.
  defp order_by_priority(priority) do
    extra = Enum.filter(@abilities, &(&1 not in priority))
    priority ++ extra
  end

  # --- point buy ---

  defp validate_point_buy(scores) do
    with :ok <- check_six_abilities(scores),
         :ok <- check_ranges(scores, 8, 15),
         {:ok, cost} <- compute_point_buy_cost(scores) do
      if cost == @point_buy_budget do
        {:ok, Map.take(scores, @abilities)}
      else
        {:error, "point buy total is #{cost}, must be exactly #{@point_buy_budget}"}
      end
    end
  end

  defp compute_point_buy_cost(scores) do
    costs =
      Enum.map(@abilities, fn ab ->
        val = Map.get(scores, ab)
        Map.get(@point_buy_costs, val)
      end)

    if Enum.any?(costs, &is_nil/1) do
      {:error, "point buy scores must be between 8 and 15"}
    else
      {:ok, Enum.sum(costs)}
    end
  end

  # --- explicit ---

  defp validate_explicit(scores) do
    with :ok <- check_six_abilities(scores),
         :ok <- check_ranges(scores, 1, 20) do
      {:ok, Map.take(scores, @abilities)}
    end
  end

  defp check_six_abilities(scores) do
    missing = Enum.reject(@abilities, &Map.has_key?(scores, &1))

    if missing == [] do
      :ok
    else
      {:error, "missing abilities: #{inspect(missing)}"}
    end
  end

  defp check_ranges(scores, min, max) do
    out_of_range =
      Enum.filter(@abilities, fn ab ->
        v = Map.get(scores, ab)
        not (is_integer(v) and v >= min and v <= max)
      end)

    if out_of_range == [] do
      :ok
    else
      {:error, "abilities #{inspect(out_of_range)} out of range [#{min}, #{max}]"}
    end
  end

  @doc "Apply racial bonuses to a base score map."
  @spec apply_bonuses(score_map(), %{atom() => integer()}) :: score_map()
  def apply_bonuses(scores, bonuses) do
    Enum.reduce(bonuses, scores, fn {ability, bonus}, acc ->
      Map.update!(acc, ability, &(&1 + bonus))
    end)
  end

  @doc "Modifier for a score value (delegates to Rules.Ability)."
  @spec modifier(integer()) :: integer()
  def modifier(score), do: Ability.modifier(score)
end
