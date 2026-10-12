defmodule Dragonex.AgentInstructions do
  @moduledoc """
  Envía el prefijo de rol vigente junto al historial compartido de partida.

  exAgent solo inserta sus instrucciones cuando el historial está vacío; el
  adaptador de Chat usa los mensajes, no `params.instructions`. La historia
  reconstruida desde eventos no trae ese prefijo. Esta capability lo añade
  a cada petición después de compactar, conservando resúmenes y conversación.
  No cambia el historial canónico ni los índices de mensajes nuevos del run.

  Si el mismo actor ya publicó prosa intermedia en este turno, la petición
  recuerda que esa prosa ya se ve en la mesa. La guía no oculta ni elimina
  eventos, ni convierte una respuesta intermedia en un turno terminado.

  Un rechazo de argumentos puede acompañar el siguiente intento con una guía
  estática de schema. Solo recibe la causa normalizada, nunca el cuerpo del
  proveedor; la guía queda fuera del historial canónico.

  Después de una petición del mismo beat, proyecta el World vigente leído de
  Session. El resumen inicial permanece en la historia; esta foto temporal
  evita presentar sus objetivos o recursos anteriores como estado actual.
  """

  use ExAgent.Capability
  use Gettext, backend: Dragonex.Gettext

  alias ExAgent.Message.{Part, Request}
  alias ExAgent.Session.SharedState

  # Runtime texts: the table locale decides the language (D236). The world
  # prefix also identifies stale projections, so it is read per request.
  defp world_prefix, do: dgettext("prompts", "WORLD VIGENTE:")

  defp turn_continuation do
    dgettext(
      "prompts",
      "CONTINUACIÓN DEL TURNO: La prosa que emitiste antes de las herramientas " <>
        "ya se publicó en la mesa. No la vuelvas a narrar ni la reformules tras " <>
        "recibir los resultados. Añade solo una consecuencia o respuesta nueva, " <>
        "en una o dos frases, y conserva los datos reales de las herramientas. " <>
        "Si no hay información nueva, cierra con una frase breve sin repetir " <>
        "la descripción. No repitas herramientas ni efectos ya aplicados."
    )
  end

  defp argument_retry do
    dgettext(
      "prompts",
      "REINTENTO DE HERRAMIENTAS: La petición anterior fue rechazada por argumentos " <>
        "inválidos. Revisa el JSON Schema completo de cada herramienta y envía " <>
        "un objeto JSON que cumpla sus propiedades obligatorias y tipos, incluido " <>
        "cualquier objeto contenedor obligatorio. No uses parámetros posicionales " <>
        "ni campos fuera de ese esquema. No escribas la llamada como prosa ni " <>
        "inventes su resultado. Conserva los efectos ya confirmados y sus recibos; " <>
        "no vuelvas a ejecutarlos."
    )
  end

  @impl true
  def before_model_request(_cap, %{agent: %{instructions: [_ | _] = instructions}} = state) do
    Dragonex.I18n.adopt(state.deps)

    current =
      instructions
      |> Enum.map(& &1.content)
      |> MapSet.new()
      |> MapSet.put(turn_continuation())
      |> MapSet.put(argument_retry())

    prefix_mark = world_prefix()

    history =
      (state.request_messages || state.messages)
      |> Enum.flat_map(fn
        %Request{parts: parts} = message ->
          parts =
            Enum.reject(parts, fn
              %Part.System{content: content} ->
                MapSet.member?(current, content) or String.starts_with?(content, prefix_mark)

              _ ->
                false
            end)

          if parts == [], do: [], else: [%{message | parts: parts}]

        message ->
          [message]
      end)

    prefix =
      instructions ++
        argument_retry_parts(state) ++ continuation_parts(state) ++ world_parts(state)

    %{state | request_messages: [%Request{parts: prefix} | history]}
  end

  def before_model_request(_cap, state), do: state

  defp argument_retry_parts(%{deps: %{model_retry: :invalid_tool_arguments}}),
    do: [%Part.System{content: argument_retry()}]

  defp argument_retry_parts(_), do: []

  defp world_parts(%{
         run_step: step,
         deps: %{
           state: %SharedState{} = shared,
           beat: %{actor: actor},
           participant_kinds: kinds
         }
       })
       when is_integer(step) and step > 1 and is_binary(actor) and actor != "" and
              is_map(kinds) do
    case SharedState.read(shared) do
      %Dragonex.World{} = world ->
        ending =
          if Dragonex.World.combat_over?(world),
            do:
              dgettext(
                "prompts",
                "No hay enemigos presentes con PG positivos. No son objetivos de otro ataque; " <>
                  "el cierre del combate corresponde al motor."
              ) <> "\n",
            else: ""

        content =
          world_prefix() <>
            " " <>
            dgettext(
              "prompts",
              "Estado confirmado después de las herramientas de este beat. Prevalece sobre " <>
                "los objetivos, recursos y entorno del WORLD inicial. Conserva los recibos; no " <>
                "repitas efectos ni inventes acciones o cambios de turno."
            ) <>
            "\n" <>
            ending <> Dragonex.Brief.world_brief(world, actor, "dm", kinds)

        [%Part.System{content: content}]

      _ ->
        []
    end
  end

  defp world_parts(_), do: []

  defp continuation_parts(%{
         deps: %{beat: %{game_id: game_id, actor: actor, turn_id: turn_id}}
       })
       when is_integer(game_id) and is_binary(actor) and actor != "" and
              is_binary(turn_id) and turn_id != "" do
    if Dragonex.Games.intermediate_narration?(game_id, actor, turn_id),
      do: [%Part.System{content: turn_continuation()}],
      else: []
  end

  defp continuation_parts(_), do: []
end
