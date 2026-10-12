defmodule Dragonex.I18nCatalogTest do
  use ExUnit.Case, async: true

  # D236: an English table must never fall back to a Spanish msgid. Every
  # extracted message has an English translation with the same placeholders.
  @domains ~w(engine prompts ui)
  @placeholder ~r/%\{(\w+)\}/

  defp entries(domain) do
    path = Path.join([:code.priv_dir(:dragonex), "gettext", "en", "LC_MESSAGES", "#{domain}.po"])
    Expo.PO.parse_file!(path).messages
  end

  defp text(parts), do: IO.iodata_to_binary(parts)

  defp keys(text),
    do: @placeholder |> Regex.scan(text) |> Enum.map(&List.last/1) |> Enum.sort() |> Enum.uniq()

  for domain <- @domains do
    test "the English #{domain} catalog is complete and keeps every placeholder" do
      problems =
        for message <- entries(unquote(domain)),
            problem = check(message),
            do: problem

      assert problems == [], Enum.join(Enum.take(problems, 15), "\n")
    end
  end

  defp check(%Expo.Message.Singular{msgid: id, msgstr: str} = message) do
    {id, str} = {text(id), text(str)}

    cond do
      "fuzzy" in List.flatten(message.flags) -> "fuzzy: #{id}"
      str == "" -> "untranslated: #{id}"
      keys(id) != keys(str) -> "placeholders differ: #{id}"
      true -> nil
    end
  end

  defp check(%Expo.Message.Plural{msgid: id, msgstr: forms} = message) do
    id = text(id)
    forms = forms |> Map.values() |> Enum.map(&text/1)

    cond do
      "fuzzy" in List.flatten(message.flags) -> "fuzzy: #{id}"
      Enum.any?(forms, &(&1 == "")) -> "untranslated plural: #{id}"
      Enum.any?(forms, &(keys(&1) -- keys(id) != [])) -> "placeholders differ: #{id}"
      true -> nil
    end
  end
end
