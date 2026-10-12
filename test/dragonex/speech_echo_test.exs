defmodule Dragonex.SpeechEchoTest do
  use ExUnit.Case, async: true

  alias Dragonex.SpeechEcho

  defp narration(seq, actor, text, extra \\ %{}) do
    %{
      seq: seq,
      type: :narration,
      actor: actor,
      payload: Map.merge(%{"text" => text, "turn_id" => "t1", "complete" => false}, extra)
    }
  end

  defp final(seq, actor, text), do: narration(seq, actor, text, %{"complete" => true})

  defp action(seq, actor, text),
    do: %{seq: seq, type: :action, actor: actor, payload: %{"text" => text, "turn_id" => "t1"}}

  defp dice(seq), do: %{seq: seq, type: :dice, actor: "Thane", payload: %{"turn_id" => "t1"}}

  defp hidden(events), do: events |> SpeechEcho.analyze() |> Map.fetch!(:hidden) |> Enum.sort()

  # 19447/35→36: the final repeats the intermediate word for word.
  test "an exact intermediate/final copy keeps the final" do
    text = "El bandido se dobla sobre la mesa y ya no se levanta."
    assert hidden([narration(35, "dm", text), final(36, "dm", text)]) == [35]
  end

  # 19449/14→15: the final is the quoted line already inside the intermediate.
  test "a final contained in the intermediate keeps the longer intermediate" do
    events = [
      narration(
        14,
        "Vex",
        "Se desliza tras el quicio y suelta la flecha. —No te muevas más, que la siguiente te la clavo donde duele."
      ),
      final(15, "Vex", "No te muevas más, que la siguiente te la clavo donde duele.")
    ]

    assert hidden(events) == [15]
  end

  test "an intermediate contained in the final keeps the final, across dice" do
    events = [
      narration(1, "dm", "El esqueleto avanza hacia el umbral con el cuchillo."),
      dice(2),
      final(
        3,
        "dm",
        "El esqueleto avanza hacia el umbral con el cuchillo. La hoja te roza el brazo."
      )
    ]

    assert hidden(events) == [1]
  end

  # 19443/44→45: two words reworded in an otherwise identical paragraph.
  test "a near copy with light rewording keeps the final" do
    events = [
      narration(
        44,
        "dm",
        "Thane ha recorrido el sendero bajo el mediodía: el vado le ha mojado las botas. " <>
          "El barro del camino no guarda huellas frescas ni señales de paso reciente. " <>
          "Desde el umbral no se oye nada salvo el murmullo del agua."
      ),
      final(
        45,
        "dm",
        "Thane ha recorrido el sendero bajo el mediodía: el vado le ha mojado las botas. " <>
          "El barro del camino no guarda huellas frescas ni señal alguna de paso reciente. " <>
          "Desde el umbral no llega más sonido que el murmullo del agua."
      )
    ]

    assert hidden(events) == [44]
  end

  # 19445/23→26 and 19443/58→62: declaration, then the outcome after dice.
  test "a continuation with new outcomes keeps both lines" do
    events = [
      narration(23, "dm", "El bandido lanza un tajo bajo y brutal contra Thane."),
      dice(24),
      final(
        26,
        "dm",
        "La cimitarra entra por debajo de la guardia y abre un tajo en el costado del guerrero."
      )
    ]

    assert hidden(events) == []
  end

  # 19447/20→21 rewords the attack with shared nouns; folding it would need a
  # semantic judgement, so both stay.
  test "a paraphrase is not folded" do
    events = [
      narration(
        20,
        "dm",
        "El bandido suelta la cimitarra al suelo y arranca la ballesta de su espalda. " <>
          "El virote se clava en el costado de Vex. El hombre recarga junto a la mesa."
      ),
      final(
        21,
        "dm",
        "El bandido suelta la cimitarra, descolgó la ballesta y disparó: el virote hiere a Vex, " <>
          "que sangra abundantemente. Recarga con la campanilla vibrando a su lado."
      )
    ]

    assert hidden(events) == []
  end

  test "echoes never cross actors, turns or turnless events" do
    text = "La puerta del almacén cruje y se abre hacia dentro."

    assert hidden([narration(1, "dm", text), final(2, "Vex", text)]) == []

    assert hidden([narration(1, "dm", text), narration(2, "dm", text, %{"turn_id" => "t2"})]) ==
             []

    turnless = %{"turn_id" => nil}

    assert hidden([
             narration(1, "dm", text, turnless),
             final(2, "dm", text) |> Map.put(:payload, %{"text" => text})
           ]) == []
  end

  test "two completed narrations fold only when identical" do
    text = "La puerta del almacén cruje y se abre hacia dentro."
    longer = text <> " Dentro huele a polvo y a cera vieja."

    assert hidden([final(1, "dm", text), final(2, "dm", text)]) == [1]
    assert hidden([final(1, "dm", text), final(2, "dm", longer)]) == []
  end

  test "short fragments do not count as contained echoes" do
    events = [
      narration(1, "dm", "Sí, el bandido sigue ahí, junto a la mesa, sin moverse."),
      final(2, "dm", "Sí.")
    ]

    assert hidden(events) == []
  end

  # 19447/24→27: D221 publishes the literal human words again after tools.
  test "a human declaration voices its action and hides the later copy" do
    events = [
      action(24, "Thane", "Ataco al bandido con mi espada larga."),
      dice(25),
      final(27, "Thane", "Ataco al bandido con mi espada larga.")
      |> put_in([:payload, "kind"], "human_declaration")
    ]

    assert SpeechEcho.analyze(events) == %{hidden: MapSet.new([27]), voiced: MapSet.new([24])}
  end

  test "a human declaration with different words or turn is kept" do
    voice =
      final(3, "Thane", "Recojo la campanilla de cobre.")
      |> put_in([:payload, "kind"], "human_declaration")

    assert SpeechEcho.analyze([action(1, "Thane", "Ataco al bandido."), voice]) ==
             %{hidden: MapSet.new(), voiced: MapSet.new()}

    other_turn =
      put_in(action(1, "Thane", "Recojo la campanilla de cobre."), [:payload, "turn_id"], "t0")

    assert SpeechEcho.analyze([other_turn, voice]) ==
             %{hidden: MapSet.new(), voiced: MapSet.new()}
  end

  test "atom-keyed payloads from a fresh append are understood" do
    events = [
      %{
        seq: 1,
        type: :narration,
        actor: "dm",
        payload: %{text: "Una copia exacta del cierre del turno.", turn_id: "t1", complete: false}
      },
      %{
        seq: 2,
        type: :narration,
        actor: "dm",
        payload: %{text: "Una copia exacta del cierre del turno.", turn_id: "t1", complete: true}
      }
    ]

    assert hidden(events) == [1]
  end
end
