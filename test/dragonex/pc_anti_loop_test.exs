defmodule Dragonex.PCAntiLoopTest do
  @moduledoc """
  Bug #3 — ANTIBUCLE. A bot re-declaring the same non-action ("¿subimos al
  círculo?" x N, "voy a calentar el brazo" x N) stalled the partida. The system
  prompt already forbids it; prompts alone weren't enough.

  `Dragonex.Game.Guardrails.with_pc_anti_loop/4` compares the newest two public
  narrations within 40 events (Jaccard, threshold 0.75). A near-duplicate nudges
  a free turn toward a different local proposal. A pending answer instead
  permits confirmed facts and needs no new action or gesture (D187).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Dragonex.Test.Harness, only: [narration: 1]

  alias Dragonex.{Archetypes, Games, Game}
  alias Dragonex.Game.Guardrails
  alias ExAgent.{Models.Test, Server}

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp transcript(lines) do
    {:ok, game} =
      Games.create_game(title: "Últimas voces", roster: [{Archetypes.wizard(), :ai}])

    for {text, visibility} <- lines do
      assert {:ok, _} =
               Games.append_event(game.id, :narration, "Lyra", visibility, %{text: text})
    end

    game.id
  end

  @repeat "Prefiero estudiar el mapa antes de elegir el camino."

  test "the detector compares the newest two public narrations and quotes the latest one" do
    latest = "Prefiero estudiar el mapa antes de elegir el camino, Thane."

    id =
      transcript([
        {"Recuerdo la flecha del goblin.", "all"},
        {"No conozco a la posadera.", "all"},
        {@repeat, "all"},
        {latest, "all"}
      ])

    instruction = Guardrails.with_pc_anti_loop(id, "Lyra", "Turno local.")
    assert instruction =~ "ANTIBUCLE DETECTADO"
    assert instruction =~ "«#{latest}»"
    assert instruction =~ "haz algo DISTINTO y LOCAL"
  end

  test "old duplicates do not nudge a PC whose latest answers are different" do
    id =
      transcript([
        {@repeat, "all"},
        {@repeat, "all"},
        {"Recuerdo la flecha del goblin.", "all"},
        {"No conozco a la posadera.", "all"}
      ])

    assert Guardrails.with_pc_anti_loop(id, "Lyra", "Turno local.") == "Turno local."
  end

  test "a private narration cannot seed a public PC nudge" do
    private = [
      {"PrivateLoopMarker plan secreto duplicado.", "dm"},
      {"PrivateLoopMarker plan secreto duplicado.", "dm"}
    ]

    public = [
      {"Recuerdo la flecha del goblin.", "all"},
      {"No conozco a la posadera.", "all"}
    ]

    for lines <- [private ++ public, public ++ private] do
      id = transcript(lines)
      assert Guardrails.with_pc_anti_loop(id, "Lyra", "Turno local.") == "Turno local."
    end
  end

  test "a pending answer permits repeated facts without forcing a new action or gesture" do
    id = transcript([{@repeat, "all"}, {@repeat, "all"}])

    instruction =
      Guardrails.with_pc_anti_loop(id, "Lyra", "Responde a Thane.", context: :response)

    assert instruction =~ "ANTIBUCLE DETECTADO"
    assert instruction =~ "Puedes repetir un dato confirmado si vuelve a preguntarse"
    assert instruction =~ "No necesitas añadir un gesto ni proponer una acción"
    assert instruction =~ "Responde a Thane."
    refute instruction =~ "ESTÁ PROHIBIDO repetir"
    refute instruction =~ "haz algo DISTINTO y LOCAL"
    refute instruction =~ "ability_check("
  end

  # Count :narration events produced by `actor`.
  defp narration_count(game_id, actor) do
    game_id
    |> Games.list_events()
    |> Enum.count(fn e -> e.type == :narration and e.actor == actor end)
  end

  test "a bot repeating itself triggers the anti-loop nudge" do
    {:ok, game} =
      Games.create_game(
        title: "loop",
        scene: "una sala con varias puertas",
        roster: [{Archetypes.fighter(), :ai}]
      )

    # The model always replies with the SAME line — the classic loop where a bot
    # re-declares an intention without ever acting on it.
    model = %Dragonex.Test.Narrator{text: "¿Empezamos a subir al círculo superior?"}

    log =
      capture_log(fn ->
        pid =
          Dragonex.Test.GameFixture.start!(
            {Game, {game.id, [model: model, roller: fn _ -> 10 end]}}
          )

        # Wait until the fighter has produced at least 3 narrations — by the 3rd
        # turn its previous two lines are near-identical, so the engine injects
        # the anti-loop nudge before that beat runs.
        assert :ok ==
                 Game.await(
                   pid,
                   fn _s -> narration_count(game.id, "Thane") >= 3 end,
                   10_000
                 )
      end)

    assert log =~ "anti-loop nudge",
           "the anti-loop nudge should fire once a bot repeats its own line"
  end

  test "a bot that varies its lines does NOT trip the anti-loop" do
    owner = self()

    {:ok, game} =
      Games.create_game(
        title: "loop",
        scene: "una sala con varias puertas",
        roster: [{Archetypes.fighter(), :ai}]
      )

    # Distinct lines each turn — no repetition, no nudge.
    script = [
      "Inspecciono las puertas del norte.",
      "Camino hacia el altar y lo examino.",
      "Escucho con atención los sonidos detrás de la puerta."
    ]

    before = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, before, nil, before.round, :paused)

    # Give only the PC the finite script. Pause before its final answer is
    # released so the test checks three completed turns without a fourth beat.
    finish = fn _, _ ->
      send(owner, {:anti_loop_narrations_completed, self()})

      receive do
        :finish_anti_loop_check -> narration(List.last(script))
      after
        5_000 -> flunk("the completed anti-loop check was not released")
      end
    end

    log =
      capture_log(fn ->
        pid =
          Dragonex.Test.GameFixture.start!(
            {Game,
             {game.id,
              [
                model: %Dragonex.Test.Narrator{text: "Las puertas permanecen abiertas."},
                roller: fn _ -> 10 end
              ]}}
          )

        state = :sys.get_state(pid)

        assert :ok ==
                 Server.set_model(state.pc_agents["Thane"], %Test{
                   script: Enum.map(Enum.take(script, 2), &narration/1) ++ [finish]
                 })

        assert :ok == Game.resume(pid)
        assert_receive {:anti_loop_narrations_completed, request}, 2_000
        assert :ok == Game.pause(pid)
        send(request, :finish_anti_loop_check)

        assert :ok ==
                 Game.await(
                   pid,
                   &(&1.status == :paused and :sys.get_state(pid).busy == nil),
                   5_000
                 )

        events = Games.list_events(game.id)

        lines =
          for e <- events, e.type == :narration and e.actor == "Thane", do: e.payload["text"]

        assert lines == script
        refute Enum.any?(events, &String.contains?(&1.payload["note"] || "", "el turno falló"))
      end)

    refute log =~ "anti-loop nudge",
           "distinct lines must not trip the anti-loop detector"
  end
end
