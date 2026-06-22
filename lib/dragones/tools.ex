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

  # --- legacy spike stubs ----------------------------------------------------
  # These apply a raw effect without rolling — they predate the rules engine and
  # are kept only so the original exAgent capability tests (combat/round-robin,
  # multi-participant, dice) keep exercising the framework. The real,
  # rules-driven versions are `make_attack` and `roll_dice` below. Retire once
  # those flows migrate.

  @doc "Attack a target for `damage` hp (after a successful hit roll elsewhere)."
  deftool attack(ctx, target :: String.t(), damage :: integer()) do
    case propose(ctx, Dragones.World.apply_damage(target, damage)) do
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
    c =
      Dragones.Character.new(
        name: name,
        class: "monster",
        hp: hp,
        max_hp: hp,
        ac: 10,
        side: "enemy"
      )

    {:ok, _} = propose(ctx, Dragones.World.add_character(c))
    {:ok, "#{name} appears (#{hp} hp)"}
  end

  @doc "Advance to the next round."
  deftool next_round(ctx) do
    {:ok, _} = propose(ctx, Dragones.World.next_round())
    {:ok, "round advanced"}
  end

  # --- real bridge tools (Rules -> World) -------------------------------
  # These resolve intents through Dragones.Actions (deterministic math) and
  # propose the resulting change. The LLM only ever sees the returned message;
  # it never computes damage, hit chance or saves itself.

  @doc "Roll `count` d`sides`, optionally with advantage/disadvantage."
  deftool roll_dice(ctx, count :: pos_integer(), sides :: pos_integer()) do
    {:ok, msg} = Dragones.Actions.roll(count, sides, :normal, ctx.deps.roller)
    {:ok, msg}
  end

  @doc "Roll initiative for every conscious combatant and begin combat."
  deftool roll_initiative(ctx) do
    with {:ok, msg, change} <- Dragones.Actions.initiative(world(ctx), ctx.deps.roller),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc "Resolve a weapon attack from `attacker` onto `target` by the rules."
  deftool make_attack(ctx, attacker :: String.t(), target :: String.t(), weapon :: String.t()) do
    with {:ok, msg, change} <-
           Dragones.Actions.attack(world(ctx), attacker, target, weapon, ctx.deps.roller),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc "Resolve a spell cast by `caster` onto `target` by the rules."
  deftool cast_spell(ctx, caster :: String.t(), spell :: String.t(), target :: String.t()) do
    with {:ok, msg, change} <-
           Dragones.Actions.spell(world(ctx), caster, spell, target, ctx.deps.roller),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc "Make a death saving throw for a down `character`."
  deftool make_death_save(ctx, character :: String.t()) do
    with {:ok, msg, change} <- Dragones.Actions.death_save(world(ctx), character, ctx.deps.roller),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc "End combat and return to free-form exploration (DM call, once combat is over)."
  deftool end_combat(ctx) do
    {:ok, _} = propose(ctx, Dragones.World.end_combat())
    {:ok, "combat ends"}
  end

  @doc "Heal `target` by a dice expression (e.g. \"1d8+3\"); caps at max hp, clears death saves."
  deftool heal(ctx, target :: String.t(), dice :: String.t()) do
    with {:ok, msg, change} <- Dragones.Actions.heal(world(ctx), target, dice, ctx.deps.roller),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  # Read the current shared world through the Session handle.
  defp world(ctx), do: ExAgent.Session.SharedState.read(ctx.deps.state)

  # Propose a world change through the Session handle. Tools must not mutate the
  # world directly; they propose through SharedState (single-writer rule).
  defp propose(ctx, change_fn) do
    ExAgent.Session.SharedState.propose_change(ctx.deps.state, change_fn)
  end
end
