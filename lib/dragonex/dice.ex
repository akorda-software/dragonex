defmodule Dragonex.Dice do
  @moduledoc """
  Dice rolling for the game.

  Real games want randomness; deterministic tests want fixed results. The tools
  never roll directly — they call `ctx.deps.roller.(sides)`, so a test injects a
  fixed roller (e.g. `fn _sides -> 20 end`) while production passes `&Dragonex.Dice.roll/1`.

  The actual RNG is delegated to the `dic_ex` package (`DicEx.RNG.Default`), so
  every die draw flows through the same roller the `dic_ex` component and
  notation parser use. The D&D expression parser/evaluator is available directly
  via `DicEx.roll/1` (advantage, explode, keep/drop, reroll); `roll_expr/2` here
  keeps the narrower `(sides -> value)`-injectable contract the combat engine
  and tests rely on.
  """

  alias DicEx.RNG.Default, as: DicExRNG

  # The one grammar for simple dice expressions ("NdM", "NdM+K", "NdM-K").
  # Shared by `parse_expr/1`, `roll_expr/2` and `valid?/1` — and by the
  # callers that only need the pieces (`Rules.Upcast` combines expressions,
  # `Actions.empowered_roll/3` rerolls the first dice) so the parser lives
  # here instead of being duplicated at each site.
  # Entradas inválidas (auditoría 7): count y sides >= 1 — "0d6" (cero
  # dados) y "1d0" (dado sin caras) se colaban por `(\d+)` y producían
  # basura o un roller d0 que crasheaba.
  @dice_expr ~r/^([1-9]\d*)d([1-9]\d*)(?:([+-])(\d+))?$/

  # Rangos sanos compartidos por gramática y roll (revisión cruzada D96):
  # expresiones tipo "101d6" o "1d99999" son válidas para la gramática pero
  # cuelgan la tirada; "1d1" es un dado sin sentido. Una sola fuente de
  # verdad para Actions.roll, Tools.roll y heal (que valida con valid?/1).
  @max_count 100
  @min_sides 2
  @max_sides 1000

  @doc """
  Parse a simple dice expression into `{count, sides, mod}` (mod is 0 when
  absent). Raises on anything else — callers validate with `valid?/1` when
  the input is user/model-facing. Also raises when count/sides fall outside
  the sane ranges (1..100 dados, 2..1000 caras).
  """
  @spec parse_expr(String.t()) :: {pos_integer(), pos_integer(), integer()}
  def parse_expr(expr) do
    case Regex.run(@dice_expr, String.trim(expr)) do
      [_, count, sides, sign, mod] ->
        m = String.to_integer(mod)
        {count, sides} = {String.to_integer(count), String.to_integer(sides)}
        enforce_ranges!(count, sides, expr)
        {count, sides, if(sign == "-", do: -m, else: m)}

      [_, count, sides] ->
        {count, sides} = {String.to_integer(count), String.to_integer(sides)}
        enforce_ranges!(count, sides, expr)
        {count, sides, 0}

      _ ->
        raise ArgumentError, "unparseable dice expression: #{inspect(expr)}"
    end
  end

  defp enforce_ranges!(count, sides, expr) do
    unless count in 1..@max_count and sides in @min_sides..@max_sides do
      raise ArgumentError,
            "dice expression out of range: #{inspect(expr)} " <>
              "(1..#{@max_count} dados, #{@min_sides}..#{@max_sides} caras)"
    end

    :ok
  end

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
    {count, sides, mod} = parse_expr(expr)
    Enum.sum(for _ <- 1..count, do: roller.(sides)) + mod
  end

  @doc """
  True when `expr` is a well-formed dice expression (e.g. "2d6", "1d8+2")
  WITHIN the sane ranges (1..100 dados, 2..1000 caras) — "101d6", "1d1" o
  "1d99999" son inválidos aunque casen con la gramática.
  """
  @spec valid?(String.t() | nil) :: boolean()
  def valid?(expr) when is_binary(expr) do
    case Regex.run(@dice_expr, String.trim(expr)) do
      [_, count, sides, _, _] -> in_range?(count, sides)
      [_, count, sides] -> in_range?(count, sides)
      _ -> false
    end
  end

  def valid?(_), do: false

  defp in_range?(count, sides) do
    n = String.to_integer(count)
    m = String.to_integer(sides)
    n in 1..@max_count and m in @min_sides..@max_sides
  end

  # Convenience rollers for deps injection in tests.
  def always(value), do: fn _sides -> value end
end
