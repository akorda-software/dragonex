defmodule Dragonex.NPCStatement do
  @moduledoc "Bounded NPC testimony with attribution and its first world-clock reference."
  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.{Text, World}

  @max_speaker 80
  @max_statement 800
  # The stored attribution follows the game's language (D236). Both grammars
  # stay readable forever: a saved Spanish game keeps parsing in any locale.
  # The Spanish form is byte-identical to the original one.
  @formats %{
    es: %{
      marker: " afirma: «",
      close: "»",
      clock: " [Registrado a los %{seconds} s del reloj del mundo.]",
      body: ~r/\A(.*)»(?: \[Registrado a los \d+ s del reloj del mundo\.\])?\z/su
    },
    en: %{
      marker: " states: “",
      close: "”",
      clock: " [Recorded at %{seconds} s of the world clock.]",
      body: ~r/\A(.*)”(?: \[Recorded at \d+ s of the world clock\.\])?\z/su
    }
  }
  def max_speaker, do: @max_speaker
  def max_statement, do: @max_statement

  @doc "Recognize stored attribution for presentation, without validating or inferring its clock."
  def attributed?(fact), do: is_binary(speaker(fact))

  @doc "Return the literal source of a stored attribution, without interpreting its claim or clock."
  def speaker(fact) when is_binary(fact) do
    Enum.find_value([:es, :en], fn lang ->
      case String.split(fact, @formats[lang].marker, parts: 2) do
        [speaker, _claim] -> if valid_speaker?(speaker), do: speaker
        _ -> nil
      end
    end)
  end

  def speaker(_), do: nil

  def fact(%World{} = world, speaker, statement)
      when is_binary(speaker) and is_binary(statement) do
    speaker = speaker |> Text.scrub() |> normalize() |> apposition()
    raw_statement = normalize(Text.scrub(statement))

    statement =
      if String.length(raw_statement) <= @max_statement,
        do: canonical_statement(raw_statement),
        else: ""

    cond do
      not valid_speaker?(speaker) ->
        {:error,
         dgettext(
           "engine",
           "Usa el nombre o rol del PNJ, sin diálogo, de 1 a %{max} caracteres: " <>
             "p. ej. «Mira» o «Mira (la molinera)»; sin comas, dos puntos ni comillas.",
           max: @max_speaker
         )}

      statement == "" or String.length(raw_statement) > @max_statement ->
        {:error,
         dgettext("engine", "Registra una afirmación concreta de 1 a %{max} caracteres.",
           max: @max_statement
         )}

      pc_speaker?(world, speaker) ->
        {:error,
         dgettext(
           "engine",
           "No registres la voz de un PC como testimonio de PNJ; cada PC habla en su turno."
         )}

      true ->
        # Inner quotes stay inside the attributed span. A quoted allegation
        # about a PC is testimony, never a committed action by that PC.
        format = format()
        fact = attribution(format, speaker, statement)
        pcs = for {name, %{side: "pc"}} <- world.characters, do: name

        if Text.puppets_pc?(fact, "dm", pcs, Map.keys(world.characters)) do
          {:error,
           dgettext(
             "engine",
             "Usa solo el nombre o rol de un PNJ como fuente, sin decidir acciones de PCs."
           )}
        else
          # Keep the original reference on retries or a repeated claim after
          # time advances. Legacy testimony has no known collection clock;
          # repeating it must not manufacture one.
          existing = Enum.find(world.facts, &same_statement?(&1, speaker, statement))

          {:ok,
           existing ||
             fact <>
               String.replace(
                 format.clock,
                 "%{seconds}",
                 Integer.to_string(world.elapsed_seconds)
               )}
        end
    end
  end

  def fact(%World{}, _speaker, _statement),
    do: {:error, dgettext("engine", "Indica una fuente PNJ y su afirmación como textos.")}

  # Dedup reads both grammars, so retries never duplicate a claim whatever
  # language it was first stored in.
  defp same_statement?(stored, speaker, statement) when is_binary(stored) do
    Enum.any?(Map.values(@formats), fn format ->
      prefix = speaker <> format.marker

      if String.starts_with?(stored, prefix) do
        case Regex.run(format.body, String.replace_prefix(stored, prefix, "")) do
          [_, body] ->
            body == statement or
              (String.length(body) <= @max_statement and
                 canonical_statement(normalize(body)) == statement)

          _ ->
            false
        end
      else
        false
      end
    end)
  end

  defp same_statement?(_, _, _), do: false

  defp format, do: Map.get(@formats, Dragonex.I18n.locale(), @formats.es)

  defp attribution(format, speaker, statement),
    do: speaker <> format.marker <> statement <> format.close

  defp canonical_statement(text),
    do: text |> unwrap_quotes() |> String.replace(["«", "»", "“", "”", "\""], "'")

  # Remove only complete, unambiguous envelopes. In particular, the first
  # closing quote in «one» and «two» closes early, so both inner spans survive.
  defp unwrap_quotes(text) do
    inner =
      case text do
        <<"«", _::binary>> -> paired_envelope(text, "«", "»")
        <<"“", _::binary>> -> paired_envelope(text, "“", "”")
        <<"\"", _::binary>> -> symmetric_envelope(text, "\"")
        <<"'", _::binary>> -> symmetric_envelope(text, "'")
        _ -> nil
      end

    if is_nil(inner), do: text, else: unwrap_quotes(String.trim(inner))
  end

  defp paired_envelope(text, opening, closing) do
    if String.ends_with?(text, closing) and
         whole_pair?(String.graphemes(text), opening, closing, 0) do
      binary_part(text, byte_size(opening), byte_size(text) - byte_size(opening <> closing))
    end
  end

  defp whole_pair?([opening | rest], opening, closing, depth),
    do: whole_pair?(rest, opening, closing, depth + 1)

  defp whole_pair?([closing | rest], opening, closing, depth) do
    if depth == 1,
      do: rest == [],
      else: whole_pair?(rest, opening, closing, depth - 1)
  end

  defp whole_pair?([_ | rest], opening, closing, depth),
    do: whole_pair?(rest, opening, closing, depth)

  defp whole_pair?([], _, _, _), do: false

  defp symmetric_envelope(text, quote) do
    run = text |> String.graphemes() |> Enum.take_while(&(&1 == quote)) |> length()
    delimiter = String.duplicate(quote, run)

    cond do
      text == delimiter and run > 1 ->
        ""

      byte_size(text) >= 2 * byte_size(delimiter) and String.ends_with?(text, delimiter) ->
        inner =
          binary_part(text, byte_size(delimiter), byte_size(text) - 2 * byte_size(delimiter))

        # An apostrophe inside a word is not a closing quotation mark. Inspect
        # a copy: D'Artagnan and the actual inner quotations remain unchanged.
        inspection =
          if quote == "'" and run == 1,
            do: String.replace(inner, ~r/(?<=[\p{L}\p{M}\p{N}])'(?=[\p{L}\p{M}\p{N}])/u, ""),
            else: inner

        if not String.contains?(inspection, delimiter), do: inner

      true ->
        nil
    end
  end

  defp valid_speaker?(speaker),
    do:
      speaker != "" and String.length(speaker) <= @max_speaker and
        Regex.match?(~r/^[\p{L}\p{N}][\p{L}\p{M}\p{N} .'’()\-]*$/u, speaker)

  # «Mira, la molinera» is how Spanish names a source with its role. Store it
  # in the unambiguous form the attribution grammar already accepts.
  defp apposition(speaker) do
    case String.split(speaker, ",") do
      [name, role] ->
        {name, role} = {String.trim(name), String.trim(role)}
        if name != "" and role != "", do: "#{name} (#{role})", else: speaker

      _ ->
        speaker
    end
  end

  defp normalize(text),
    do: text |> String.normalize(:nfc) |> String.replace(~r/\s+/u, " ") |> String.trim()

  # A role in parentheses describes the source; the name before it decides
  # whether a PC is being used as testimony.
  defp pc_speaker?(world, speaker) do
    base = speaker |> String.split(" (", parts: 2) |> hd()
    pc_name?(world, speaker) or (base != speaker and pc_name?(world, base))
  end

  defp pc_name?(world, speaker) do
    key = String.downcase(speaker)

    case Enum.find(world.characters, fn {name, _} ->
           name |> normalize() |> String.downcase() == key
         end) do
      {_name, %{side: "pc"}} ->
        true

      {_name, _npc} ->
        false

      nil ->
        Enum.any?(world.characters, fn
          {name, %{side: "pc"}} ->
            name |> normalize() |> String.split() |> hd() |> String.downcase() == key

          _ ->
            false
        end)
    end
  end
end
