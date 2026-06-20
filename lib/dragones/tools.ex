defmodule Dragones.Tools do
  @moduledoc """
  The game's model-callable tools. Built with `use ExAgent.Tools`, so each
  tool's JSON Schema is derived from its `::` type annotations.

  Every tool reads what it needs from `ctx.deps`, which is a map bundling:
    * `:state` — the ExAgent.Session.SharedState handle (propose world changes)
    * `:roller` — a (sides -> value) dice fn (injected so tests are deterministic)
  """

  use ExAgent.Tools

  @doc "Narrate and set the current scene."
  deftool set_scene(ctx, narration :: String.t()) do
    {:ok, _} = propose(ctx, Dragones.World.set_scene(narration))
    {:ok, "scene set"}
  end

  @doc "Attack a target for `damage` hp (after a successful hit roll elsewhere)."
  deftool attack(ctx, target :: String.t(), damage :: integer()) do
    case propose(ctx, Dragones.World.damage(target, damage)) do
      {:ok, _} -> {:ok, "#{target} takes #{damage} damage"}
      {:error, _} = e -> e
    end
  end

  @doc "Roll a single d`n` and report the result to the model."
  deftool roll(ctx, sides :: pos_integer()) do
    roller = ctx.deps.roller
    {:ok, "rolled #{roller.(sides)} (d#{sides})"}
  end

  @doc "Add a character to the world with the given hp."
  deftool spawn_character(ctx, name :: String.t(), hp :: integer()) do
    {:ok, _} = propose(ctx, Dragones.World.add_character(name, hp))
    {:ok, "#{name} appears (#{hp} hp)"}
  end

  @doc "Advance to the next round."
  deftool next_round(ctx) do
    {:ok, _} = propose(ctx, Dragones.World.next_round())
    {:ok, "round advanced"}
  end

  # Propose a world change through the Session handle. Tools must not mutate the
  # world directly; they propose through SharedState (single-writer rule).
  defp propose(ctx, change_fn) do
    ExAgent.Session.SharedState.propose_change(ctx.deps.state, change_fn)
  end
end
