defmodule Dragonex.WaitDeclarationEnTest do
  use ExUnit.Case, async: true
  alias Dragonex.{I18n, WaitDeclaration}

  defp en(fun), do: I18n.with_locale(:en, fun)

  test "English tables recognize explicit affirmative waits" do
    en(fn ->
      assert WaitDeclaration.seconds("I wait here for ten minutes.") == 600
      assert WaitDeclaration.seconds("I wait for an hour") == 3600
      assert WaitDeclaration.seconds("I stay by the bar for twenty-five minutes") == 1500
      assert WaitDeclaration.seconds("I wait 30 seconds") == 30
    end)
  end

  test "questions, conditions and rests are not waits" do
    en(fn ->
      assert WaitDeclaration.seconds("I wait ten minutes until the guard leaves") == nil
      assert WaitDeclaration.seconds("Do I wait ten minutes?") == nil
      assert WaitDeclaration.seconds("I wait ten minutes for a short rest") == nil
    end)
  end

  test "a purely passive English wait is literal speech; Spanish stays Spanish" do
    en(fn ->
      assert WaitDeclaration.literal_speech("I wait here for ten minutes.") ==
               "I wait here for ten minutes."

      assert WaitDeclaration.literal_speech("I wait ten minutes and search the room.") == nil
      assert WaitDeclaration.seconds("Espero diez minutos.") == nil
    end)

    assert WaitDeclaration.seconds("Espero diez minutos.") == 600
  end
end
