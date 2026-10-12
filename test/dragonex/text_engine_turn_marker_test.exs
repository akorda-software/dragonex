defmodule Dragonex.TextEngineTurnMarkerTest do
  use ExUnit.Case, async: true
  alias Dragonex.Text

  # 19451/70 published the engine's "Es TU turno (DM)" cue as narration.
  test "a sentence carrying the engine's DM turn cue is dropped, the fiction stays" do
    raw =
      "Es TU turno (DM) y ya has narrado el silencio tras la pelea. Queda el altillo: " <>
        "la escalera cruje y el arcón azul aguarda arriba."

    assert Text.scrub(raw) ==
             "Queda el altillo: la escalera cruje y el arcón azul aguarda arriba."

    assert Text.scrub("El molino calla. Pero el motor dice «Es TU turno (DM)», así que sigo.") ==
             "El molino calla."
  end

  test "ordinary prose about turns is untouched" do
    text = "Thane espera su turno junto a la puerta mientras Mira cuenta los sacos."
    assert Text.scrub(text) == text
  end
end
