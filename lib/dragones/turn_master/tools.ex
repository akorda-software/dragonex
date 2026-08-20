defmodule Dragones.TurnMaster.Tools do
  @moduledoc """
  Orchestration tools for the TurnMaster agent.

  These are **not** 5e resolution tools (`Dragones.Tools`). They only validate
  the chosen participant against the World snapshot in `ctx.deps` and write a
  decision into the per-beat `Dragones.TurnMaster.Decision` recorder. The Game
  applies the decision after the beat closes (D6 single-writer).
  """

  use ExAgent.Tools

  alias Dragones.TurnMaster.Decision
  alias Dragones.World

  @doc "Entrega el turno / la palabra al participante (herramienta por defecto)."
  deftool give_turn_to(ctx, participant :: String.t()) do
    with :ok <- validate_target(ctx, participant),
         :ok <- record(ctx, %{action: :give_turn_to, to: participant}) do
      {:ok, "turno entregado a #{participant}"}
    end
  end

  @doc """
  Interrupción dramática en combate: el participante recibe un mini-turno y el
  flujo vuelve después al actor interrumpido. No gasta el turno principal del
  reactor en la ronda.
  """
  deftool cut_in(ctx, participant :: String.t()) do
    with :ok <- require_combat(ctx),
         :ok <- validate_target(ctx, participant),
         :ok <- record(ctx, %{action: :cut_in, to: participant}) do
      {:ok, "#{participant} interrumpe"}
    end
  end

  @doc """
  Reacción fuera de orden (ataque de oportunidad, escudo reactivo, etc.).
  Mini-turno; no gasta el turno principal del reactor.
  """
  deftool react(ctx, participant :: String.t()) do
    with :ok <- require_combat(ctx),
         :ok <- validate_target(ctx, participant),
         :ok <- record(ctx, %{action: :react, to: participant}) do
      {:ok, "#{participant} reacciona"}
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

  defp validate_target(ctx, name) when is_binary(name) do
    name = String.trim(name)
    world = world(ctx)
    roster = participants(ctx)
    known? = name in roster or Map.has_key?(world.characters, name)

    cond do
      name == "" ->
        {:error, "participante vacío"}

      name == "dm" ->
        :ok

      not known? and roster != [] ->
        {:error, "#{name} no es un participante de esta partida"}

      Map.has_key?(world.characters, name) ->
        cond do
          World.dead?(world, name) ->
            {:error, "#{name} está muerto — elige a otro"}

          World.down?(world, name) and world.phase == :combat ->
            # Downed PCs still take death-save turns; enemies at 0 are skipped.
            case World.character(world, name) do
              %{side: "pc"} -> :ok
              _ -> {:error, "#{name} está caído — elige a otro"}
            end

          true ->
            :ok
        end

      name in roster ->
        :ok

      true ->
        {:error, "#{name} no existe en la escena"}
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
