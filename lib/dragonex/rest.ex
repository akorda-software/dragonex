defmodule Dragonex.Rest do
  @moduledoc "Finite hit dice and once-per-day long rests, measured by the world clock."
  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.{World, WorldClock}

  def remaining(w, who) do
    c = World.character(w, who)
    max(0, c.level - (get_in(w.rest_state, [who, "hit_dice_used"]) || 0))
  end

  @doc "Seconds until the daily long-rest limit allows another benefit; other actor/phase guards still apply."
  @spec long_rest_wait(World.t(), String.t()) :: non_neg_integer()
  def long_rest_wait(w, who) do
    case get_in(w.rest_state, [who, "last_long_rest_start"]) do
      last when is_integer(last) -> max(0, last + 86400 - w.elapsed_seconds)
      _ -> 0
    end
  end

  def validate(w, who, kind) do
    with :ok <- World.validate_actor(w, who) do
      cond do
        w.phase == :combat ->
          {:error, dgettext("engine", "no se puede descansar en combate")}

        kind == :long and long_rest_wait(w, who) > 0 ->
          {:error,
           dgettext(
             "engine",
             "%{who} solo puede beneficiarse de un descanso largo cada 24 horas",
             who: who
           )}

        true ->
          :ok
      end
    end
  end

  def complete(w, who, kind, dice_spent \\ 0) do
    with :ok <- validate(w, who, kind) do
      if remaining(w, who) < dice_spent do
        {:error, dgettext("engine", "%{who} ya no tiene dados de golpe suficientes", who: who)}
      else
        entry = Map.get(w.rest_state, who, %{})
        used = (entry["hit_dice_used"] || 0) + dice_spent

        entry =
          if kind == :long do
            recovered = max(1, div(World.character(w, who).level, 2))

            entry
            |> Map.put("hit_dice_used", max(0, used - recovered))
            |> Map.put("last_long_rest_start", w.elapsed_seconds)
          else
            Map.put(entry, "hit_dice_used", used)
          end

        w = %{w | rest_state: Map.put(w.rest_state, who, entry)}
        {:ok, WorldClock.advance(w, if(kind == :long, do: 28800, else: 3600))}
      end
    end
  end
end
