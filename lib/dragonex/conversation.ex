defmodule Dragonex.Conversation do
  @moduledoc """
  A bounded, durable request for companions or the world to answer.

  Models can declare recipients through a tool; the Game also registers literal
  leading human vocatives. The engine validates the roster and hands off each
  response. No rolls, resources or combat initiative are involved. The DM closes
  the exchange before the human questioner gets the floor back.
  Literal human NPC questions reserve just the DM response and human return;
  they never create a companion recipient or a model-callable world tool.
  """

  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.{Character, Text, World}

  @max_recipients 5
  @max_question 800

  def max_recipients, do: @max_recipients
  def max_question, do: @max_question

  @doc "Propose a request as the acting PC; identical retries are idempotent."
  def request(from, recipients, question) do
    fn world ->
      with :ok <- exploration(world),
           :ok <- valid_pc(world, from),
           :ok <- valid_recipients(world, from, recipients),
           {:ok, question} <- clean_question(question) do
        request = %{
          "from" => from,
          "recipients" => recipients,
          "pending" => recipients,
          "question" => question,
          "stage" => "responses"
        }

        put_request(world, request)
      end
    end
  end

  @doc "Reserve a literal human question to the world; the DM answers then returns the floor."
  def request_world(from, recipient, question) do
    fn world ->
      with :ok <- exploration(world),
           :ok <- valid_pc(world, from),
           true <- is_binary(recipient) and String.length(recipient) in 1..80,
           {:ok, question} <- clean_question(question) do
        recipient = recipient |> Text.scrub() |> String.trim()

        if recipient == "" do
          {:error, dgettext("engine", "La pregunta necesita un destinatario del mundo.")}
        else
          put_request(world, %{
            "from" => from,
            "recipients" => [],
            "pending" => [],
            "question" => question,
            "stage" => "world",
            "world_recipient" => recipient
          })
        end
      else
        false -> {:error, dgettext("engine", "La pregunta necesita un destinatario del mundo.")}
        error -> error
      end
    end
  end

  defp put_request(
         world,
         %{"from" => from, "recipients" => recipients, "question" => question} = request
       ) do
    case Map.get(world, :conversation) do
      nil ->
        {:ok, Map.put(world, :conversation, request)}

      %{"from" => ^from, "recipients" => ^recipients, "question" => ^question} = saved ->
        if saved["world_recipient"] == request["world_recipient"],
          do: {:ok, world},
          else: pending_error()

      _ ->
        pending_error()
    end
  end

  defp pending_error,
    do:
      {:error,
       dgettext(
         "engine",
         "Ya hay una pregunta pendiente. Responde primero; no encadenes otra conversación."
       )}

  @doc "Settle a completed or terminally failed response, once, in roster order."
  def finish_actor(actor) do
    fn world ->
      conversation =
        case Map.get(world, :conversation) do
          %{"stage" => "responses", "pending" => [^actor | rest]} = request ->
            %{
              request
              | "pending" => rest,
                "stage" => if(rest == [], do: "world", else: "responses")
            }

          %{"stage" => "world"} = request when actor == "dm" ->
            %{request | "stage" => "return"}

          request ->
            request
        end

      {:ok, Map.put(world, :conversation, conversation)}
    end
  end

  @doc "Drop unavailable recipients without pretending they answered."
  def prune(participants) do
    fn world ->
      conversation =
        case Map.get(world, :conversation) do
          %{"from" => from} = request ->
            if world.phase == :exploration and from in participants and
                 valid_pc(world, from) == :ok do
              pending =
                Enum.filter(request["pending"], fn name ->
                  name in participants and valid_pc(world, name) == :ok
                end)

              stage =
                if request["stage"] == "responses" and pending == [],
                  do: "world",
                  else: request["stage"]

              %{request | "pending" => pending, "stage" => stage}
            end

          _ ->
            nil
        end

      {:ok, Map.put(world, :conversation, conversation)}
    end
  end

  def clear, do: fn world -> {:ok, Map.put(world, :conversation, nil)} end

  def response_for(%World{phase: :exploration, conversation: request}, name) do
    case request do
      %{"stage" => "responses", "pending" => [^name | _]} -> request
      _ -> nil
    end
  end

  def response_for(_, _), do: nil

  def world_turn?(%World{phase: :exploration, conversation: %{"stage" => "world"}}), do: true
  def world_turn?(_), do: false

  @doc "Compact factual context for all agents, including the handoff agent."
  def brief(%World{phase: :exploration, conversation: request}) when is_map(request) do
    next =
      case request do
        %{"stage" => "responses", "pending" => [name | _]} -> name
        %{"stage" => "world"} -> dgettext("prompts", "DM (cierre de la conversación)")
        %{"stage" => "return"} -> request["from"]
      end

    recipient = request["world_recipient"] || Enum.join(request["recipients"], ", ")

    dgettext(
      "prompts",
      "Conversación pendiente: %{from} pregunta a %{recipient}.\n" <>
        "Pregunta: %{question}\nSiguiente respuesta: %{next}. No respondas por otro PC.",
      from: request["from"],
      recipient: recipient,
      question: request["question"],
      next: next
    )
  end

  def brief(_), do: ""

  @doc "Decode only the bounded shape we persist; legacy/malformed input means no request."
  def decode(
        %{
          "from" => from,
          "recipients" => recipients,
          "pending" => pending,
          "question" => question,
          "stage" => stage
        } = request
      )
      when is_binary(from) and is_list(recipients) and is_list(pending) and
             is_binary(question) and stage in ["responses", "world", "return"] do
    world_recipient = request["world_recipient"]

    world_request? =
      is_binary(world_recipient) and String.trim(world_recipient) != "" and
        String.length(world_recipient) <= 80 and recipients == [] and pending == [] and
        stage in ["world", "return"]

    pc_request? = is_nil(world_recipient) and length(recipients) in 1..@max_recipients

    valid? =
      from != "" and from != "dm" and (world_request? or pc_request?) and
        Enum.all?(recipients, &(is_binary(&1) and &1 != "" and &1 != from and &1 != "dm")) and
        Enum.uniq(recipients) == recipients and
        Enum.filter(recipients, &(&1 in pending)) == pending and
        String.length(question) in 1..@max_question and
        ((stage == "responses" and pending != []) or (stage != "responses" and pending == []))

    if valid? do
      decoded = Map.take(request, ~w(from recipients pending question stage world_recipient))

      case request["quiet_close"] do
        %{"world_fingerprint" => hash, "action_seq" => seq}
        when pc_request? and is_binary(hash) and is_integer(seq) and seq > 0 ->
          if Regex.match?(~r/\A[0-9a-f]{64}\z/, hash),
            do:
              Map.put(decoded, "quiet_close", %{"world_fingerprint" => hash, "action_seq" => seq}),
            else: decoded

        _ ->
          decoded
      end
    end
  end

  def decode(_), do: nil

  defp exploration(%World{phase: :exploration}), do: :ok

  defp exploration(_),
    do:
      {:error,
       dgettext(
         "engine",
         "Pide respuestas a compañeros en exploración; en combate manda la iniciativa."
       )}

  defp valid_pc(world, name) do
    case World.present_character(world, name) do
      %Character{side: "pc"} ->
        World.validate_actor(world, name)

      _ ->
        {:error,
         dgettext("engine", "%{name} no es un PC presente al que puedas pedir respuesta.",
           name: name
         )}
    end
  end

  defp valid_recipients(world, from, recipients) when is_list(recipients) do
    cond do
      length(recipients) not in 1..@max_recipients ->
        {:error,
         dgettext("engine", "Elige entre 1 y %{max} compañeros para responder.",
           max: @max_recipients
         )}

      not Enum.all?(recipients, &is_binary/1) or Enum.uniq(recipients) != recipients ->
        {:error, dgettext("engine", "Usa nombres canónicos de compañeros sin duplicados.")}

      from in recipients ->
        {:error, dgettext("engine", "No puedes pedirte respuesta a ti mismo.")}

      true ->
        Enum.reduce_while(recipients, :ok, fn name, _ ->
          case valid_pc(world, name) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
    end
  end

  defp valid_recipients(_, _, _),
    do: {:error, dgettext("engine", "recipients debe ser una lista de nombres de compañeros.")}

  defp clean_question(question) when is_binary(question) do
    question = question |> Text.scrub() |> String.trim() |> String.slice(0, @max_question)

    if question == "",
      do: {:error, dgettext("engine", "La pregunta no puede estar vacía.")},
      else: {:ok, question}
  end

  defp clean_question(_), do: {:error, dgettext("engine", "La pregunta debe ser texto.")}
end
