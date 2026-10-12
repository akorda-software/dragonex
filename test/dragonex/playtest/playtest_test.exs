defmodule Dragonex.PlaytestTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Dragonex.Playtest
  alias Dragonex.Playtest.Player

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  test "juega declaraciones humanas por el camino de la mesa y devuelve métricas" do
    test_pid = self()

    player = fn context ->
      send(test_pid, {:asked, context.name, context.phase})
      {:ok, "Miro a mi alrededor con calma."}
    end

    result =
      Playtest.run(
        companions: [],
        turns: 2,
        minutes: 1,
        player: player,
        game_opts: [model: %Dragonex.Test.Narrator{}]
      )

    assert {result.stop, result.declarations} == {:turns_reached, 2}
    assert_received {:asked, "Thane", _phase}

    actions =
      for e <- Dragonex.Games.list_events(result.game_id),
          e.type == :action,
          do: e.payload["text"]

    assert actions == ["Miro a mi alrededor con calma.", "Miro a mi alrededor con calma."]
    assert result.metrics.turns.human >= 2
    assert Dragonex.Games.get_game(result.game_id).status == :paused
  end

  test "un fallo del jugador bot detiene el arnés con su motivo" do
    result =
      Playtest.run(
        companions: [],
        minutes: 1,
        player: fn _ -> {:error, :no_idea} end,
        game_opts: [model: %Dragonex.Test.Narrator{}]
      )

    assert result.stop == {:player_failed, :no_idea}
    assert result.declarations == 0
  end

  describe "Player" do
    test "la transcripción solo usa eventos públicos y resume las tiradas" do
      events = [
        %{
          type: :narration,
          actor: "dm",
          visible_to: "all",
          payload: %{"text" => "Una rata chilla."}
        },
        %{type: :system, actor: "system", visible_to: "dm", payload: %{"note" => "secreto"}},
        %{
          type: :dice,
          actor: "Vex",
          visible_to: "all",
          payload: %{"who" => "Vex", "kind" => "attack", "total" => 19}
        },
        %{type: :turn, actor: "Thane", visible_to: "all", payload: %{"kind" => "start"}}
      ]

      assert Player.transcript(events) == "dm: Una rata chilla.\n[Vex · attack → 19]"
    end

    test "el prompt va en el idioma de la partida e incluye objetivo y ficha" do
      sheet = %{class: :fighter, race: :human, hp: 9, max_hp: 12}

      {es, _} =
        Player.prompt(%{
          name: "Thane",
          locale: :es,
          sheet: sheet,
          goal: "Traer el libro.",
          events: []
        })

      {en, req} = Player.prompt(%{name: "Thane", locale: :en, phase: :combat, events: []})

      assert es =~ "Controlas a Thane (human fighter, 9/12 HP)"
      assert es =~ "Objetivo del grupo: Traer el libro."
      assert en =~ "You control Thane."
      assert req =~ "Phase: combat"
    end

    test "clean quita el nombre propio y comillas envolventes, pero respeta citas internas" do
      assert Player.clean("Thane: «Ataco a la rata.»", "Thane") == "Ataco a la rata."
      assert Player.clean("**Thane:** Subo   la\nescalera.", "Thane") == "Subo la escalera."
      assert Player.clean("Digo a Mira: «Ya vamos».", "Thane") == "Digo a Mira: «Ya vamos»."

      assert Player.clean("«Hola», le digo a Mira, «¿y el libro?»", "Thane") ==
               "«Hola», le digo a Mira, «¿y el libro?»"
    end
  end
end
