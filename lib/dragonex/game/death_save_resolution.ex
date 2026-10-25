defmodule Dragonex.Game.DeathSaveResolution do
  @moduledoc """
  A manual combat beat that starts dying must record its death save before
  publishing a successful closure. Eligibility is captured once by Game and
  travels with retries/checkpoints; this module never rolls or writes World.
  """
  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.{Character, World}
  alias ExAgent.Session.SharedState

  def required?(
        %World{phase: :combat, turn_kind: "main", current_combatant: actor} = world,
        actor,
        true,
        false
      ),
      do: dying?(world, actor)

  def required?(_world, _actor, _manual?, _mini?), do: false

  def waiting?(%{
        state: %SharedState{} = shared,
        beat: %{death_save_required: true, actor: actor, round: round}
      }) do
    world = SharedState.read(shared)
    not resolved?(world, actor, round)
  end

  def waiting?(_), do: false

  def resolved?(world, actor, round) do
    budget = Map.get(world.turn_state, actor, %{})
    paid? = world.round == round and budget["round"] == round and budget["death_save"] == true
    world.phase != :combat or not dying?(world, actor) or paid?
  end

  defp dying?(world, actor) do
    case World.present_character(world, actor) do
      %Character{side: "pc", hp: hp, max_hp: max, death_saves: saves}
      when is_integer(hp) and hp <= 0 and is_integer(max) and max > 0 and is_map(saves) ->
        (saves[:fails] || 0) < 3 and (saves[:successes] || 0) < 3

      _ ->
        false
    end
  end

  def instruction(false, _actor), do: ""

  def instruction(true, actor) do
    "\n\n" <>
      dgettext(
        "prompts",
        "SALVACIÓN DE MUERTE PENDIENTE: %{actor} empezó este turno caído, vivo e inestable. " <>
          "Antes de cerrar con final_result, llama make_death_save para %{actor}, salvo que " <>
          "la salvación de este turno ya esté registrada o ya no esté moribundo. " <>
          "No repitas una tirada registrada. Esta salvación tiene su propio cupo, no gasta la acción. " <>
          "Si un 20 natural lo deja con 1 PG, puedes resolver después su declaración con las " <>
          "herramientas permitidas; si sigue caído, no puede atacar ni actuar.",
        actor: actor
      )
  end
end
