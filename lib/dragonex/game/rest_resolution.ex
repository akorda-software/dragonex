defmodule Dragonex.Game.RestResolution do
  @moduledoc "One explicitly grouped rest interval per DM beat, without a second clock charge."
  use Gettext, backend: Dragonex.Gettext

  @rests ~w(short_rest long_rest rest_party)

  # Receipts are owned by Game and restored with a failed beat. Check here
  # before tool preparation, and again at commit for concurrent tool calls.
  def validate(%{participant: "dm", tool_results: results}, {tool, _args})
      when tool in ["short_rest", "long_rest", "rest_party", "advance_time"] do
    paid = for {{name, _}, [_ | _]} <- results, do: name

    cond do
      tool in ["short_rest", "long_rest"] ->
        {:error,
         dgettext(
           "engine",
           "Para resolver un descanso como DM usa rest_party con todos los participantes, aunque sea uno. El intervalo se registra una sola vez."
         )}

      tool == "rest_party" and Enum.any?(paid, &(&1 in @rests or &1 == "advance_time")) ->
        interval_recorded()

      tool == "advance_time" and Enum.any?(paid, &(&1 in @rests)) ->
        interval_recorded()

      true ->
        :ok
    end
  end

  def validate(_, _), do: :ok

  defp interval_recorded do
    {:error,
     dgettext(
       "engine",
       "Este turno ya registró el intervalo. No añadas otro descanso ni sumes su duración con advance_time. Consulta el reloj y cierra la narración; un viaje o descanso posterior requiere otra declaración."
     )}
  end
end
