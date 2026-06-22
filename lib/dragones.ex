defmodule Dragones do
  @moduledoc """
  A D&D 5e game built on `exAgent`.

  Layered so the rules and the agents never blur:

    * `Dragones.Rules`        — pure 5e math (abilities, combat resolution).
    * `Dragones.World`        — the shared game state + combat state machine.
    * `Dragones.Actions`      — intent → rules → world change (pure bridge).
    * `Dragones.Tools`        — `deftool` wrappers an LLM calls; the LLM only
                                reads their textual results, never the math.
    * `Dragones.TurnPolicy.WorldDriven` — enforces the world's impartial
                                initiative order; the DM cannot skip/reorder.
  """
end
