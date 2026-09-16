defmodule Dragonex.TurnMaster.Tools do
  @moduledoc """
  Orchestration tools for the TurnMaster agent.

  These are **not** 5e resolution tools (`Dragonex.Tools`). They only validate
  the chosen participant against the World snapshot in `ctx.deps` and write a
  decision into the per-beat `Dragonex.TurnMaster.Decision` recorder. The Game
  applies the decision after the beat closes (D6 single-writer).
  """

  use ExAgent.Tools

  alias Dragonex.TurnMaster.Decision
  alias Dragonex.World

  @doc "Entrega el turno / la palabra al participante (herramienta por defecto)."
  deftool give_turn_to(ctx, participant :: String.t()) do
    with {:ok, to} <- resolve_target(ctx, participant),
         :ok <- record(ctx, %{action: :give_turn_to, to: to}) do
      {:ok, "turno entregado a #{to}"}
    end
  end

  @doc """
  Interrupción dramática en combate: el participante recibe un mini-turno y el
  flujo vuelve después al actor interrumpido. No gasta el turno principal del
  reactor en la ronda.
  """
  deftool cut_in(ctx, participant :: String.t()) do
    with :ok <- require_combat(ctx),
         {:ok, to} <- resolve_target(ctx, participant),
         :ok <- record(ctx, %{action: :cut_in, to: to}) do
      {:ok, "#{to} interrumpe"}
    end
  end

  @doc """
  Reacción fuera de orden (ataque de oportunidad, escudo reactivo, etc.).
  Mini-turno; no gasta el turno principal del reactor.
  """
  deftool react(ctx, participant :: String.t()) do
    with :ok <- require_combat(ctx),
         {:ok, to} <- resolve_target(ctx, participant),
         :ok <- record(ctx, %{action: :react, to: to}) do
      {:ok, "#{to} reacciona"}
    end
  end

  @doc "Cede explícitamente al máster (abrir/cerrar escena, entorno, voz de PNJ)."
  deftool pass_to_dm(ctx) do
    record(ctx, %{action: :pass_to_dm, to: "dm"})
    {:ok, "turno entregado al DM"}
  end

  @doc "Cierra el encuentro/escena de combate y deja el grupo en exploración."
  deftool end_scene(ctx) do
    record(ctx, %{action: :end_scene, to: "dm"})
    {:ok, "escena cerrada — vuelve a exploración"}
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
      _ -> {:error, "cut_in/react solo en combate"}
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
        {:error, "participante vacío"}

      canonical != nil ->
        check_vitality(world, canonical)

      roster != [] ->
        {:error, "#{name} no es un participante de esta partida"}

      true ->
        {:error, "#{name} no existe en la escena"}
    end
  end

  defp resolve_target(_ctx, name), do: {:error, "#{inspect(name)} no es un participante válido"}

  defp check_vitality(world, name) do
    cond do
      not Map.has_key?(world.characters, name) ->
        # Roster-only participant (e.g. "dm") — nothing to vitality-check.
        {:ok, name}

      World.dead?(world, name) ->
        {:error, "#{name} está muerto — elige a otro"}

      World.down?(world, name) and world.phase == :combat ->
        # Downed PCs still take death-save turns; enemies at 0 are skipped.
        case World.character(world, name) do
          %{side: "pc"} -> {:ok, name}
          _ -> {:error, "#{name} está caído — elige a otro"}
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
