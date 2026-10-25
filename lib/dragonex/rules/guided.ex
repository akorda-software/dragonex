defmodule Dragonex.Rules.Guided do
  @moduledoc """
  Marcador de Guiding Bolt (ADR D95): el objetivo impactado queda guiado —
  la PRÓXIMA tirada de ataque contra él se hace con ventaja y consume el
  marcador (hit o miss, cualquier atacante).

  Caducidad perezosa, sin tocar los hot paths de `world.ex`: el marcador
  solo está activo en combate y mientras el lanzador no haya iniciado un
  turno posterior (derivado de `turn_state`, que `TurnBudget.start`
  reescribe al iniciar cada turno principal y `end_combat` limpia).
  """

  alias Dragonex.Character
  alias Dragonex.World

  @condition "guided"

  @doc "¿El objetivo tiene un marcador guided activo (no caducado)?"
  @spec active?(World.t() | nil, Character.t() | nil) :: boolean()
  def active?(%World{phase: :combat} = world, %Character{} = target) do
    Enum.any?(target.conditions, fn entry ->
      case entry do
        %{"condition" => @condition, "source" => source, "round" => round}
        when is_binary(source) and is_integer(round) ->
          case get_in(world.turn_state, [source, "round"]) do
            # El lanzador marcó en su turno `round`; su siguiente turno
            # principal reescribe turn_state a un valor mayor → caducado.
            ts when is_integer(ts) -> ts == round
            # Sin turno registrado (combate terminado o nuevo combate sin
            # actuar aún) → caducado.
            _ -> false
          end

        _ ->
          false
      end
    end)
  end

  def active?(_world, _target), do: false
end
