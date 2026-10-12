defmodule Dragonex.Playtest.Player do
  @moduledoc """
  Jugador bot del arnés de playtest: escribe la siguiente declaración del héroe
  humano como lo haría una persona en el cuadro de la mesa.

  `prompt/1` es puro (instrucciones + transcripción de los eventos públicos);
  `declare/1` lo envía al modelo barato. El bot no ve notas del DM ni secretos:
  solo eventos `visible_to: "all"`, igual que el jugador real.
  """

  alias Dragonex.Models

  @transcript_events 30
  @max_chars 400

  @doc "Pide al modelo la siguiente declaración. Devuelve `{:ok, texto}` o `{:error, motivo}`."
  @spec declare(map()) :: {:ok, String.t()} | {:error, term()}
  def declare(context) do
    {instructions, prompt} = prompt(context)
    agent = ExAgent.new(model: Models.summarizer(), instructions: instructions)

    case ExAgent.run(agent, prompt) do
      {:ok, %{output: text}} when is_binary(text) ->
        case clean(text, context.name) do
          "" -> {:error, :empty_declaration}
          text -> {:ok, text}
        end

      {:ok, other} ->
        {:error, {:unexpected_output, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Instrucciones y mensaje para el modelo a partir del contexto de la mesa."
  @spec prompt(map()) :: {String.t(), String.t()}
  def prompt(%{name: name, locale: locale} = context) do
    {instructions(locale, name, context[:sheet], context[:goal]),
     request(locale, context[:phase], transcript(context[:events] || []))}
  end

  @doc "Limpia la respuesta: sin comillas envolventes, prefijo con el nombre propio ni saltos."
  @spec clean(String.t(), String.t()) :: String.t()
  def clean(text, name) do
    text
    |> String.trim()
    |> String.replace(~r/^\**#{Regex.escape(name)}(?::\**|\**:)\s*/u, "")
    |> unwrap()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, @max_chars)
  end

  # Quita comillas que envuelven toda la respuesta, salvo si dentro hay otra
  # cita (entonces son parte de lo que el personaje dice).
  defp unwrap(text) do
    case Regex.run(~r/^["“«](.*)["”»]$/us, text) do
      [_, inner] -> if String.match?(inner, ~r/["“”«»]/u), do: text, else: inner
      nil -> text
    end
  end

  @doc "Transcripción legible de los últimos eventos públicos."
  @spec transcript([map()]) :: String.t()
  def transcript(events) do
    events
    |> Enum.filter(&(to_string(&1.visible_to) == "all"))
    |> Enum.map(&line/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(-@transcript_events)
    |> Enum.join("\n")
  end

  defp line(%{type: type, actor: actor, payload: payload}) do
    case {to_string(type), payload} do
      {t, %{"text" => text}} when t in ["narration", "action"] and is_binary(text) ->
        "#{actor}: #{text}"

      {"dice", p} ->
        "[#{p["who"]} · #{p["kind"]} → #{p["total"]}]"

      {"system", %{"note" => note}} when is_binary(note) ->
        "(#{note})"

      _ ->
        nil
    end
  end

  defp instructions(:en, name, sheet, goal) do
    """
    You are a human player at a D&D 5e table run by an AI Dungeon Master. You \
    control #{name}#{describe(sheet)}. Write ONLY your character's next \
    declaration, as you would type it into the table's input box: first \
    person, one or two sentences, in English. Declare intentions, not results: \
    never decide whether you hit, how much damage you deal or what the NPCs \
    answer, and do not roll dice. In combat, act on your turn (attack, move, use \
    an ability). Out of combat, explore, talk to NPCs or move the goal forward; \
    you may speak in quotes. Behave like an engaged, ordinary player.#{goal_line(:en, goal)}
    """
  end

  defp instructions(_es, name, sheet, goal) do
    """
    Eres un jugador humano en una mesa de D&D 5e con un Dungeon Master IA. \
    Controlas a #{name}#{describe(sheet)}. Escribe SOLO la siguiente \
    declaración de tu personaje, tal como la teclearías en el cuadro de la mesa: \
    en primera persona, una o dos frases, en español. Declara intenciones, no \
    resultados: nunca decidas si aciertas, cuánto daño haces ni qué responden \
    los PNJ, y no tires dados. En combate, actúa en tu turno (atacar, moverte, \
    usar una capacidad). Fuera de combate, explora, habla con los PNJ o avanza \
    hacia el objetivo; puedes hablar entre comillas. Compórtate como un jugador \
    implicado y normal.#{goal_line(:es, goal)}
    """
  end

  defp goal_line(_, nil), do: ""
  defp goal_line(:en, goal), do: " The group's goal: #{goal}"
  defp goal_line(_, goal), do: " Objetivo del grupo: #{goal}"

  defp describe(%{class: class, race: race, hp: hp, max_hp: max_hp}),
    do: " (#{race} #{class}, #{hp}/#{max_hp} HP)"

  defp describe(_), do: ""

  defp request(:en, phase, transcript),
    do:
      "Recent table events:\n#{transcript}\n\nPhase: #{phase}. It is your turn. Write your declaration."

  defp request(_es, phase, transcript),
    do:
      "Últimos eventos de la mesa:\n#{transcript}\n\nFase: #{phase}. Es tu turno. Escribe tu declaración."
end
