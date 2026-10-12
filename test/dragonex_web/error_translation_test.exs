defmodule DragonexWeb.ErrorTranslationTest do
  use ExUnit.Case, async: true
  alias Dragonex.I18n
  alias DragonexWeb.ErrorTranslation

  # The register page showed «should be at least %{count} character(s)» raw.
  test "Ecto's default messages read in the active language with their counts" do
    error = {"should be at least %{count} character(s)", count: 8, validation: :length}

    assert I18n.with_locale(:es, fn -> ErrorTranslation.translate_error(error) end) ==
             "debe tener al menos 8 caracteres"

    assert I18n.with_locale(:en, fn -> ErrorTranslation.translate_error(error) end) ==
             "should be at least 8 character(s)"

    assert I18n.with_locale(:es, fn ->
             ErrorTranslation.translate_error({"can't be blank", []})
           end) ==
             "no puede estar vacío"
  end

  test "messages Dragonex already localized pass through" do
    assert ErrorTranslation.translate_error({"debe ser un email válido", []}) ==
             "debe ser un email válido"
  end
end
