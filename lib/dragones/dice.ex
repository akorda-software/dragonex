defmodule Dragones.Dice do
  @moduledoc """
  Dice rolling for the game.

  Real games want randomness; deterministic tests want fixed results. The tools
  never roll directly — they call `ctx.deps.roller.(sides)`, so a test injects a
  fixed roller (e.g. `fn _sides -> 20 end`) while production passes `&Dragones.Dice.roll/1`.

  The actual RNG is delegated to the `dic_ex` package (`DicEx.RNG.Default`), so
  every die draw flows through the same roller the `dic_ex` component and
  notation parser use. The D&D expression parser/evaluator is available directly
  via `DicEx.roll/1` (advantage, explode, keep/drop, reroll); `roll_expr/2` here
  keeps the narrower `(sides -> value)`-injectable contract the combat engine
  and tests rely on.
  """

  alias DicEx.RNG.Default, as: DicExRNG

  @doc "Roll a d`n` (1..n) via the dic_ex default RNG."
  @spec roll(pos_integer()) :: pos_integer()
  def roll(n) when is_integer(n) and n > 0 do
    DicExRNG.roll(n)
  end

  @doc """
  Roll with advantage / disadvantage (roll twice, keep highest / lowest).
  Returns the kept value plus both rolls for transparency.
  """
  @spec roll_advantage(pos_integer(), :advantage | :disadvantage, (pos_integer() -> pos_integer())) ::
          {pos_integer(), pos_integer(), pos_integer()}
  def roll_advantage(n, mode, roller \\ &roll/1) do
    a = roller.(n)
    b = roller.(n)
    kept = if mode == :advantage, do: max(a, b), else: min(a, b)
    {kept, a, b}
  end

  @doc "Roll a dice expression like \"2d6+3\". Returns the total."
  @spec roll_expr(String.t(), (pos_integer() -> pos_integer())) :: integer()
  def roll_expr(expr, roller \\ &roll/1) do
    case Regex.run(~r/^(\d+)d(\d+)(?:([+-])(\d+))?$/, String.trim(expr)) do
      [_, count, sides, sign, mod] ->
        n = String.to_integer(count)
        s = String.to_integer(sides)
        m = String.to_integer(mod)
        rolls = for _ <- 1..n, do: roller.(s)
        sum = Enum.sum(rolls)
        if sign == "-", do: sum - m, else: sum + m

      [_, count, sides] ->
        n = String.to_integer(count)
        s = String.to_integer(sides)
        Enum.sum(for _ <- 1..n, do: roller.(s))

      _ ->
        raise ArgumentError, "unparseable dice expression: #{inspect(expr)}"
    end
  end

  @doc "True when `expr` is a well-formed dice expression (e.g. \"2d6\", \"1d8+2\")."
  @spec valid?(String.t() | nil) :: boolean()
  def valid?(expr) when is_binary(expr) do
    String.trim(expr) != "" and
      Regex.match?(~r/^(\d+)d(\d+)(?:([+-])(\d+))?$/, String.trim(expr))
  end

  def valid?(_), do: false

  # Convenience rollers for deps injection in tests.
  def always(value), do: fn _sides -> value end
end
