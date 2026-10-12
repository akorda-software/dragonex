defmodule Dragonex.TurnMaster.Tools do
  @moduledoc """
  Orchestration tools for the TurnMaster agent.

  These are **not** 5e resolution tools (`Dragonex.Tools`). They only validate
  the chosen participant against the World snapshot in `ctx.deps` and write a
  decision into the per-beat `Dragonex.TurnMaster.Decision` recorder. The Game
  applies the decision after the beat closes (D6 single-writer).
  """

  use ExAgent.Tools
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.TurnMaster.Decision
  alias Dragonex.World

  @doc "Give the turn / the floor to the participant (default tool)."
  deftool give_turn_to(ctx, participant :: String.t()) do
    with {:ok, to} <- resolve_target(ctx, participant),
         :ok <- record(ctx, %{action: :give_turn_to, to: to}) do
      {:ok, dgettext("engine", "turno entregado a %{to}", to: to)}
    end
  end

  @doc """
  Dramatic interruption in combat: the participant gets a mini-turn and the
  flow then returns to the interrupted actor. It does not spend the reactor's
  main turn in the round.
  """
  deftool cut_in(ctx, participant :: String.t()) do
    with :ok <- require_combat(ctx),
         {:ok, to} <- resolve_target(ctx, participant),
         :ok <- record(ctx, %{action: :cut_in, to: to}) do
      {:ok, dgettext("engine", "%{to} interrumpe", to: to)}
    end
  end

  @doc """
  Out-of-order reaction (opportunity attack, reactive Shield, etc.).
  Mini-turn; it does not spend the reactor's main turn.
  """
  deftool react(ctx, participant :: String.t()) do
    with :ok <- require_combat(ctx),
         {:ok, to} <- resolve_target(ctx, participant),
         :ok <- record(ctx, %{action: :react, to: to}) do
      {:ok, dgettext("engine", "%{to} reacciona", to: to)}
    end
  end

  @doc "Explicitly hand over to the DM (open/close a scene, environment, NPC voice)."
  deftool pass_to_dm(ctx) do
    record(ctx, %{action: :pass_to_dm, to: "dm"})
    {:ok, dgettext("engine", "turno entregado al DM")}
  end

  @doc "Close the combat encounter/scene and return the party to exploration."
  deftool end_scene(ctx) do
    record(ctx, %{action: :end_scene, to: "dm"})
    {:ok, dgettext("engine", "escena cerrada — vuelve a exploración")}
  end

  # ----------------------------------------------------------------- helpers

  defp record(ctx, decision) do
    case ctx.deps[:decision] do
      pid when is_pid(pid) ->
        Decision.record(pid, decision)
        :ok

      _ ->
        # Unit tests may call tools without a recorder — treat as ok so the
        # model path still returns a factual result.
        :ok
    end
  end

  defp require_combat(ctx) do
    case world(ctx) do
      %World{phase: :combat} -> :ok
      _ -> {:error, dgettext("engine", "cut_in/react solo en combate")}
    end
  end

  # Validate the chosen target AND canonicalize it: LLMs happily emit
  # `"thane"`, `" thane "` or `"THANE"` for the participant `"Thane"`. We match
  # case-insensitively (trim included) and record the roster's canonical name,
  # so the Game's `Session.handoff/2` always receives a real participant id
  # instead of a near-miss that would fall through to WorldDriven.
  defp resolve_target(ctx, name) when is_binary(name) do
    name = String.trim(name)
    world = world(ctx)
    roster = participants(ctx)
    down = String.downcase(name)

    canonical =
      roster
      |> Kernel.++(Map.keys(world.characters))
      # "dm" is always a valid target (prompt rule 5), even in unit tests that
      # pass no roster.
      |> Kernel.++(["dm"])
      |> Enum.uniq()
      |> Enum.find(&(String.downcase(&1) == down))

    cond do
      name == "" ->
        {:error, dgettext("engine", "participante vacío")}

      canonical != nil ->
        check_vitality(world, canonical)

      roster != [] ->
        {:error, dgettext("engine", "%{name} no es un participante de esta partida", name: name)}

      true ->
        {:error, dgettext("engine", "%{name} no existe en la escena", name: name)}
    end
  end

  defp resolve_target(_ctx, name),
    do: {:error, dgettext("engine", "%{name} no es un participante válido", name: inspect(name))}

  defp check_vitality(world, name) do
    cond do
      not Map.has_key?(world.characters, name) ->
        # Roster-only participant (e.g. "dm") — nothing to vitality-check.
        {:ok, name}

      not World.present?(world, name) ->
        {:error,
         dgettext("engine", "%{name} está fuera de escena — elige un combatiente presente",
           name: name
         )}

      World.dead?(world, name) ->
        {:error, dgettext("engine", "%{name} está muerto — elige a otro", name: name)}

      World.down?(world, name) and world.phase == :combat ->
        # Downed PCs still take death-save turns; enemies at 0 are skipped.
        case World.character(world, name) do
          %{side: "pc"} -> {:ok, name}
          _ -> {:error, dgettext("engine", "%{name} está caído — elige a otro", name: name)}
        end

      true ->
        {:ok, name}
    end
  end

  defp world(ctx) do
    case ctx.deps do
      %{world: %World{} = w} -> w
      _ -> World.new()
    end
  end

  defp participants(ctx) do
    case ctx.deps do
      %{participants: list} when is_list(list) -> list
      _ -> []
    end
  end
end
