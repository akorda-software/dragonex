defmodule Dragonex.I18nProcessLocaleTest do
  use ExUnit.Case, async: true
  alias Dragonex.I18n

  test "the locale is per process, so two tables in different languages never mix" do
    assert I18n.locale() == :es
    parent = self()

    spawn(fn ->
      I18n.put_locale("en")
      send(parent, {:other, I18n.locale()})
    end)

    assert_receive {:other, :en}
    assert I18n.locale() == :es
  end

  test "with_locale restores the previous process locale, and unknown values fall back" do
    I18n.put_locale(:en)
    assert I18n.with_locale(:es, fn -> I18n.locale() end) == :es
    assert I18n.locale() == :en
    I18n.put_locale(nil)
    assert I18n.locale() == :es
    assert I18n.normalize("fr") == :es
  end
end
