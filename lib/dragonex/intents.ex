defmodule Dragonex.Intents do
  @moduledoc """
  Pending human declarations (`games.intents`).

  Stored values are either a legacy bare string or
  `%{"text" => ..., "phase" => "combat" | "exploration"}`.
  Combat-queued reactions must not fire after the fight ends (D28).
  """

  @type raw :: String.t() | map() | nil
  @type phase :: :combat | :exploration | atom()

  @reaction ~r/(interrump|reaccion|reacciono|escudo|ataque de oportunidad|me pongo delante|me interpongo|protejo a |cubro a )/iu

  @spec put(map(), String.t(), String.t(), phase()) :: map()
  def put(intents, name, text, phase) when is_map(intents) and is_binary(name) do
    Map.put(intents, name, encode(text, phase))
  end

  @spec encode(String.t(), phase()) :: map()
  def encode(text, phase) when is_binary(text) do
    %{"text" => text, "phase" => phase_name(phase)}
  end

  @spec text(raw()) :: String.t()
  def text(val) when is_binary(val), do: val
  def text(%{"text" => t}) when is_binary(t), do: t
  def text(%{text: t}) when is_binary(t), do: t
  def text(_), do: ""

  @spec phase(raw()) :: phase() | nil
  def phase(%{"phase" => p}), do: decode_phase(p)
  def phase(%{phase: p}), do: decode_phase(p)
  def phase(_), do: nil

  @spec present?(raw()) :: boolean()
  def present?(raw), do: String.trim(text(raw)) != ""

  @spec stale?(raw(), phase()) :: boolean()
  def stale?(raw, current_phase) do
    phase(raw) == :combat and current_phase != :combat
  end

  @spec reaction?(raw()) :: boolean()
  def reaction?(raw) do
    t = raw |> text() |> String.trim()
    t != "" and Regex.match?(@reaction, t)
  end

  @spec display(map()) :: %{optional(String.t()) => String.t()}
  def display(intents) when is_map(intents) do
    Map.new(intents, fn {name, raw} -> {name, text(raw)} end)
  end

  def display(_), do: %{}

  @spec drop_stale(map(), phase()) :: {map(), [String.t()]}
  def drop_stale(intents, current_phase) when is_map(intents) do
    Enum.reduce(intents, {%{}, []}, fn {name, raw}, {kept, dropped} ->
      if stale?(raw, current_phase) do
        {kept, [to_string(name) | dropped]}
      else
        {Map.put(kept, name, raw), dropped}
      end
    end)
  end

  def drop_stale(_, _), do: {%{}, []}

  defp phase_name(phase) when is_atom(phase), do: Atom.to_string(phase)
  defp phase_name(phase) when is_binary(phase), do: phase
  defp phase_name(_), do: "exploration"

  defp decode_phase(p) when p in [:combat, "combat"], do: :combat
  defp decode_phase(p) when p in [:exploration, "exploration"], do: :exploration
  defp decode_phase(_), do: nil
end
