defmodule Dragonex.WorldClock do
  @moduledoc "Explicit game time in seconds and expiry of represented effects. No wall clock."
  alias Dragonex.World

  def track(w, who, key, seconds) when is_integer(seconds) and seconds > 0 do
    entries = Map.get(w.effect_expiries, who, %{}) |> Map.put(key, w.elapsed_seconds + seconds)
    %{w | effect_expiries: Map.put(w.effect_expiries, who, entries)}
  end

  def track(w, _, _, _), do: w

  def forget(w, who, key) do
    case Map.fetch(w.effect_expiries, who) do
      :error ->
        w

      {:ok, entries} ->
        %{w | effect_expiries: Map.put(w.effect_expiries, who, Map.delete(entries, key))}
    end
  end

  def concentration(w, who, spell),
    do: track(w, who, "concentrating", concentration_seconds(spell))

  def seed_legacy(w) do
    Enum.reduce(w.characters, w, fn {_name, c}, acc ->
      observe(acc, %{c | concentrating: nil, raging: false, inspired: false, wild_shape: nil}, c)
    end)
  end

  def observe(w, nil, _after), do: w

  def observe(w, before, after_char) do
    w =
      if is_binary(before.concentrating) and before.concentrating != after_char.concentrating,
        do: World.clear_sourced_effects(w, before.name),
        else: w

    Enum.reduce([:concentrating, :raging, :inspired, :wild_shape], w, fn field, acc ->
      if same_effect?(field, Map.get(before, field), Map.get(after_char, field)) do
        acc
      else
        key = Atom.to_string(field)
        entries = Map.get(acc.effect_expiries, after_char.name, %{}) |> Map.delete(key)
        acc = %{acc | effect_expiries: Map.put(acc.effect_expiries, after_char.name, entries)}

        duration =
          case {field, Map.get(after_char, field)} do
            {:concentrating, name} when is_binary(name) -> concentration_seconds(name)
            {:raging, true} -> 60
            {:inspired, true} -> 600
            {:wild_shape, shape} when is_map(shape) -> max(1, div(after_char.level, 2)) * 3600
            _ -> nil
          end

        track(acc, after_char.name, key, duration)
      end
    end)
  end

  # Progression updates the saved native stats inside an ongoing form. That
  # metadata change is not a new transformation and must not renew its timer.
  defp same_effect?(:wild_shape, before, after_form) when is_map(before) and is_map(after_form),
    do: before[:beast] == after_form[:beast]

  defp same_effect?(_field, before, after_effect), do: before == after_effect

  def advance(w, seconds) when is_integer(seconds) and seconds >= 0 do
    w =
      if seconds > 0 and w.phase == :exploration,
        do: Map.put(w, :scene_refresh_pending, true),
        else: w

    w = %{w | elapsed_seconds: w.elapsed_seconds + seconds}

    Enum.reduce(w.effect_expiries, w, fn {who, effects}, acc ->
      Enum.reduce(effects, acc, fn {key, deadline}, current ->
        if deadline <= current.elapsed_seconds do
          current = expire(current, who, key)
          entries = Map.get(current.effect_expiries, who, %{}) |> Map.delete(key)
          %{current | effect_expiries: Map.put(current.effect_expiries, who, entries)}
        else
          current
        end
      end)
    end)
  end

  defp expire(w, who, key) do
    change =
      case key do
        "concentrating" -> World.clear_concentration(who)
        "raging" -> World.end_rage(who)
        "inspired" -> World.set_inspired(who, false)
        "wild_shape" -> World.revert_wild_shape(who)
        "temp_hp" -> World.clear_temp_hp(who)
        "condition:" <> condition -> World.remove_condition(who, condition)
        _ -> fn w -> {:ok, w} end
      end

    case change.(w) do
      {:ok, next} -> next
      _ -> w
    end
  end

  defp concentration_seconds("hunter's mark:" <> _), do: 3600

  defp concentration_seconds(name) do
    data = Enum.find(Dragonex.Heroes.SRDSpells.all(), &(&1.name == name)) || %{}

    case Regex.run(~r/(\d+)\s*(round|minute|hour|day)/, data[:duration] || "") do
      [_, count, unit] ->
        String.to_integer(count) *
          Map.fetch!(%{"round" => 6, "minute" => 60, "hour" => 3600, "day" => 86400}, unit)

      _ ->
        nil
    end
  end
end
