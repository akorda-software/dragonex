defmodule Dragonex.RollLog do
  @moduledoc """
  Collects structured, per-group roll records during a single beat so that every
  die roll reaches the timeline with WHO rolled, WHY, the actual dice, the total,
  what it was contested against, and whether it was effective (hit/miss/crit,
  save/fail, …).

  The unit of logging is a **roll group** — e.g. one attack's d20, one weapon's
  damage dice, one saving throw, one ability check. A group is opened with a
  reason and closed with the computed outcome; everything rolled in between (one
  d20, or 2d6, or 2d20 under advantage) is attached to it.

  ## Why an Agent (and per-group ids)

  Tools do NOT run in the beat Task's process: `ExAgent.Server` runs each agent
  turn in its own supervised Task, and `ExAgent` executes function tools in
  **parallel** (`Task.async_stream`). So:

    * a process dictionary is useless — the writer and the reader are different
      processes, and the entries could never come back;
    * a single "current group" slot would corrupt under concurrent tools.

  The recorder is therefore a short-lived `Agent` (one per beat) addressed by
  pid, and each open group gets a unique id with its own recording roller that
  writes only to that group. `Dragonex.Rules.Combat` stays pure — it keeps
  taking a plain `(sides -> value)` roller; the `Dragonex.Actions` layer is what
  knows the semantics (attack vs damage vs save …) and opens/closes groups.

  When no recorder is wired in (plain unit tests), `open/5` degrades to a
  pass-through of the fallback roller, so `Actions` code is uniform and tests
  stay unchanged.
  """

  @type die :: {pos_integer(), pos_integer()}

  @type entry :: %{
          optional(:raw_total) => number(),
          optional(:hp) => [[String.t() | integer()]],
          who: String.t() | nil,
          kind: atom(),
          reason: String.t(),
          dice: [die()],
          total: number() | nil,
          against: term() | nil,
          outcome: atom() | nil
        }

  defstruct base: nil, recorder: nil, execution: nil

  @type t :: %__MODULE__{
          base: (pos_integer() -> pos_integer()) | nil,
          recorder: pid() | nil,
          execution: reference() | nil
        }

  @doc """
  Start a per-beat recorder. Link it to the caller (the beat Task) so it dies
  with it. Optional `:on_close` callback is invoked with each finalized entry —
  used for standalone groups. `for_tool/2` defers a tool execution's groups
  until Game has saved them with its effect or successful result.
  """
  @spec start(keyword()) :: Agent.on_start()
  def start(opts \\ []) do
    Agent.start_link(fn ->
      %{groups: %{}, entries: [], deferred: %{}, on_close: Keyword.get(opts, :on_close)}
    end)
  end

  @doc "All closed groups this beat, in the order they were closed."
  @spec entries(pid()) :: [entry()]
  def entries(recorder), do: Agent.get(recorder, & &1.entries)

  @doc "Buffer this tool's groups until Game commits their effect or successful result."
  def for_tool(nil, _execution), do: nil

  def for_tool(%{__struct__: __MODULE__} = log, execution),
    do: Map.put(log, :execution, execution)

  @doc "Closed groups awaiting this execution's durable commit."
  def pending(%__MODULE__{recorder: recorder, execution: execution})
      when is_reference(execution),
      do: Agent.get(recorder, &Map.get(Map.get(&1, :deferred, %{}), execution, []))

  def pending(_log), do: []

  @doc "Remove only the committed prefix, preserving any later groups."
  def acknowledge(%__MODULE__{recorder: recorder, execution: execution}, entries)
      when is_reference(execution) do
    Agent.update(recorder, fn state ->
      pending = Map.get(state, :deferred, %{})
      remaining = Enum.drop(Map.get(pending, execution, []), length(entries))

      deferred =
        if remaining == [],
          do: Map.delete(pending, execution),
          else: Map.put(pending, execution, remaining)

      Map.put(state, :deferred, deferred)
    end)
  catch
    :exit, _ -> :ok
  end

  def acknowledge(_log, _entries), do: :ok

  @doc """
  Attach the hit points a tool left behind to its last roll, as
  `hp: [[name, hp, max_hp]]` for every creature whose HP changed. The
  chronicle then reads "goblin queda a 3/7 PG" under the damage that caused it,
  without each roll site having to know who it ends up hitting.
  """
  def with_hp_changes([], _before, _after), do: []

  def with_hp_changes(entries, %{characters: was}, %{characters: now})
      when is_map(was) and is_map(now) do
    changes =
      for {name, c} <- Enum.sort_by(now, &elem(&1, 0)),
          b = was[name],
          b != nil and b.hp != c.hp,
          do: [name, c.hp, c.max_hp]

    if changes == [], do: entries, else: List.update_at(entries, -1, &Map.put(&1, :hp, changes))
  end

  def with_hp_changes(entries, _before, _after), do: entries

  @doc "Stop the recorder (called when the beat finishes)."
  def stop(recorder), do: Agent.stop(recorder)

  @doc """
  Open a roll group and return `{roller, closer}`:

    * `roller` — a `(sides -> value)` bound to THIS group; pass it to
      `Rules.Combat` / `Dice`. Each die it rolls is recorded here.
    * `closer` — `close.(opts)` finalizes the group with `:total`, optional
      `:raw_total` before a damage minimum, `:against`
      and `:outcome`, appending it to the log.

  Pass `nil` for `log` (no recorder) and a fallback roller to get uniform,
  no-op logging — useful for unit tests and any path that doesn't care.
  """
  @spec open(t() | nil, (pos_integer() -> pos_integer()), String.t() | nil, atom(), String.t()) ::
          {(pos_integer() -> pos_integer()), (keyword() -> entry() | nil)}
  def open(nil, fallback_roller, _who, _kind, _reason),
    do: {fallback_roller, fn _opts -> nil end}

  def open(
        %__MODULE__{base: base, recorder: rec} = log,
        _fallback,
        who,
        kind,
        reason
      ) do
    id = System.unique_integer([:positive])
    execution = Map.get(log, :execution)

    :ok =
      Agent.update(rec, fn s ->
        put_in(s.groups[id], %{
          who: who,
          kind: kind,
          reason: reason,
          dice: [],
          execution: execution
        })
      end)

    roller = fn sides ->
      value = base.(sides)

      try do
        Agent.update(rec, fn s -> update_in(s.groups[id].dice, &(&1 ++ [{sides, value}])) end)
      catch
        :exit, _ -> :ok
      end

      value
    end

    closer = fn opts -> close_group(rec, id, opts) end
    {roller, closer}
  end

  @doc "Finalize a group's closer with `:total` / `:against` / `:outcome` and optional `:raw_total`."
  @spec close((keyword() -> entry() | nil), keyword()) :: entry() | nil
  def close(closer, opts) when is_function(closer, 1), do: closer.(opts)

  defp normalize_against({:ac, n}), do: ["ac", n]
  defp normalize_against({:dc, n}), do: ["dc", n]
  defp normalize_against(other), do: other

  defp close_group(rec, id, opts) do
    {entry, on_close} =
      Agent.get_and_update(rec, fn s ->
        case get_in(s.groups, [id]) do
          nil ->
            {{nil, nil}, s}

          g ->
            extra = opts |> Enum.into(%{}) |> Map.take([:total, :raw_total, :against, :outcome])

            # Store a JSON-safe entry (the timeline persists it as jsonb): dice as
            # [[sides, value]] and `against` as ["ac"|"dc", n] — no tuples.
            entry = %{
              who: g.who,
              kind: g.kind,
              reason: g.reason,
              dice: Enum.map(g.dice, fn {s, v} -> [s, v] end),
              total: extra[:total],
              against: normalize_against(extra[:against]),
              outcome: extra[:outcome]
            }

            entry = Map.merge(entry, Map.take(extra, [:raw_total]))

            next = %{s | groups: Map.delete(s.groups, id), entries: s.entries ++ [entry]}

            execution = Map.get(g, :execution)

            if is_reference(execution) do
              deferred =
                Map.update(Map.get(next, :deferred, %{}), execution, [entry], &(&1 ++ [entry]))

              next = Map.put(next, :deferred, deferred)

              {{entry, nil}, next}
            else
              {{entry, s.on_close}, next}
            end
        end
      end)

    # Persist/broadcast AFTER leaving the Agent so a slow Postgres write does
    # not serialize every concurrent roll on the recorder.
    if entry && on_close, do: safe_call(on_close, entry)
    entry
  end

  defp safe_call(fun, entry) when is_function(fun, 1) do
    fun.(entry)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
