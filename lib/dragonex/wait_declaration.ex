defmodule Dragonex.WaitDeclaration do
  @moduledoc """
  Literal affirmative waits with an explicit duration. This recognizes a
  declaration, not elapsed time: the DM still resolves completion/interruption.
  Questions, conditional plans, retellings and rests keep their existing path.
  """

  @duration ~r/^(?:(?:yo\s+)?(?:espero|aguardo)(?:\s+aqu[ií])?\s+(?:durante\s+)?|(?:yo\s+)?(?:me\s+quedo|permanezco)\s+[^.:!?¿«»"“”]{0,80}?\bdurante\s+)(\d{1,5}|\p{L}+(?:\s+y\s+\p{L}+)?)\s+(segundos?|minutos?|horas?)\b(.*)\z/isu
  @uncertain_tail ~r/[?¿«»"“”]|\b(?:si|cuando|hasta\s+que|quizás?|tal\s+vez|descanso\s+(?:corto|largo)|segundos?|minutos?|horas?)\b/iu
  @passive_place "(?:aqu[ií]|all[ií]|junto\\s+a\\s+la\\s+(?:barra|mesa|puerta))"
  @literal_wait ~r/^(?:(?:yo\s+)?(?:espero|aguardo)(?:\s+aqu[ií])?\s+(?:durante\s+)?[^.!?¿:;«»"“”]{1,50}\s+(?:segundos?|minutos?|horas?)(?:\s+(?:#{@passive_place}|sin\s+moverme))?|(?:yo\s+)?(?:me\s+quedo|permanezco)\s+#{@passive_place}\s+durante\s+[^.!?¿:;«»"“”]{1,50}\s+(?:segundos?|minutos?|horas?))\.?$/iu
  @counts Map.new(
            Enum.with_index(
              ~w(cero uno dos tres cuatro cinco seis siete ocho nueve diez once doce trece catorce quince dieciseis diecisiete dieciocho diecinueve veinte veintiuno veintidos veintitres veinticuatro veinticinco veintiseis veintisiete veintiocho veintinueve)
            ),
            fn {word, count} -> {word, count} end
          )
          |> Map.merge(%{"un" => 1, "una" => 1, "veintiun" => 21})
  @tens %{
    "treinta" => 30,
    "cuarenta" => 40,
    "cincuenta" => 50,
    "sesenta" => 60,
    "setenta" => 70,
    "ochenta" => 80,
    "noventa" => 90
  }

  # English declarations for English tables (D236): «I wait here for ten minutes».
  @en_duration ~r/^(?:(?:I\s+)?(?:wait|hold\s+on)(?:\s+here)?\s+(?:for\s+)?|(?:I\s+)?(?:stay|remain)\s+[^.:!?"“”]{0,80}?\bfor\s+)((?:an?|\d{1,5}|[a-z]+(?:[-\s][a-z]+)?))\s+(seconds?|minutes?|hours?)\b(.*)\z/isu
  @en_uncertain_tail ~r/[?"“”]|\b(?:if|when|until|maybe|perhaps|short\s+rest|long\s+rest|seconds?|minutes?|hours?)\b/iu
  @en_passive_place "(?:here|there|by\\s+the\\s+(?:bar|table|door))"
  @en_literal_wait ~r/^(?:(?:I\s+)?(?:wait|hold\s+on)(?:\s+here)?\s+(?:for\s+)?[^.!?:;"“”]{1,50}\s+(?:seconds?|minutes?|hours?)(?:\s+(?:#{@en_passive_place}|without\s+moving))?|(?:I\s+)?(?:stay|remain)\s+#{@en_passive_place}\s+for\s+[^.!?:;"“”]{1,50}\s+(?:seconds?|minutes?|hours?))\.?$/iu
  @en_counts Map.new(
               Enum.with_index(
                 ~w(zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty)
               )
             )
             |> Map.merge(%{"a" => 1, "an" => 1})
  @en_tens %{
    "twenty" => 20,
    "thirty" => 30,
    "forty" => 40,
    "fifty" => 50,
    "sixty" => 60,
    "seventy" => 70,
    "eighty" => 80,
    "ninety" => 90
  }

  def seconds(text) when is_binary(text) do
    {duration, uncertain} = patterns()

    with [_, amount, unit, tail] <- Regex.run(duration, String.trim(text)),
         false <- Regex.match?(uncertain, tail),
         count when is_integer(count) and count > 0 <- count(amount),
         seconds = count * multiplier(unit),
         true <- seconds <= 86400 do
      seconds
    else
      _ -> nil
    end
  end

  def seconds(_), do: nil

  @doc "Exact, scrubbed declaration for a purely passive wait; mixed actions keep their human beat."
  def literal_speech(text) when is_binary(text) do
    text = String.trim(text)

    literal = if english?(), do: @en_literal_wait, else: @literal_wait
    if seconds(text) && Regex.match?(literal, text), do: Dragonex.Text.scrub(text)
  end

  def literal_speech(_), do: nil

  defp english?, do: Dragonex.I18n.locale() == :en

  defp patterns,
    do:
      if(english?(),
        do: {@en_duration, @en_uncertain_tail},
        else: {@duration, @uncertain_tail}
      )

  defp count(amount) do
    amount =
      amount |> String.downcase() |> String.normalize(:nfd) |> String.replace(~r/\p{Mn}/u, "")

    case Integer.parse(amount) do
      {value, ""} -> value
      _ -> if english?(), do: en_word_count(amount), else: word_count(String.split(amount))
    end
  end

  defp word_count([word]), do: @counts[word] || @tens[word]

  defp word_count([tens, "y", ones]) do
    with ten when is_integer(ten) <- @tens[tens],
         one when one in 1..9 <- @counts[ones],
         do: ten + one
  end

  defp word_count(_), do: nil

  # «ten», «a», «twenty-five», «twenty five».
  defp en_word_count(amount) do
    case String.split(amount, ~r/[-\s]+/, trim: true) do
      [word] ->
        @en_counts[word] || @en_tens[word]

      [tens, ones] ->
        with ten when is_integer(ten) <- @en_tens[tens],
             one when one in 1..9 <- @en_counts[ones],
             do: ten + one

      _ ->
        nil
    end
  end

  defp multiplier(unit) do
    unit = String.downcase(unit)

    cond do
      String.starts_with?(unit, ["segundo", "second"]) -> 1
      String.starts_with?(unit, ["minuto", "minute"]) -> 60
      true -> 3600
    end
  end
end
