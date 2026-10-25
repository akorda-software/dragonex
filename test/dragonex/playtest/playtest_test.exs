defmodule Dragonex.PlaytestTest.InterruptedNarrator do
  @behaviour ExAgent.Model
  defstruct [:failures]

  @impl true
  def request(model, messages, settings, params) do
    fail? =
      Agent.get_and_update(model.failures, fn
        0 -> {false, 0}
        n -> {true, n - 1}
      end)

    if fail? do
      {:error,
       %ExAgent.RequestError{
         provider: :test,
         reason: :bad_request,
         status: 400,
         body: "synthetic playtest failure"
       }}
    else
      {:ok, response, _} =
        Dragonex.Test.Narrator.request(%Dragonex.Test.Narrator{}, messages, settings, params)

      {:ok, response, model}
    end
  end

  @impl true
  def request_stream(model, messages, settings, params) do
    case request(model, messages, settings, params) do
      {:ok, response, updated} -> [Dragonex.Test.Harness.stream_response(response, updated)]
      {:error, error} -> [{:error, error}]
    end
  end

  @impl true
  def model_name(_), do: "interrupted-playtest-narrator"
  @impl true
  def system(_), do: "test"
  @impl true
  def profile(_), do: ExAgent.Models.Test.profile(%ExAgent.Models.Test{})
end

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

  test "señala recogidas declaradas que no cambian el inventario" do
    lines = ["Cojo el libro de cuentas del arcón.", "Miro alrededor."]
    {:ok, agent} = Agent.start_link(fn -> lines end)

    player = fn _ ->
      {:ok, Agent.get_and_update(agent, fn [h | t] -> {h, t ++ [h]} end)}
    end

    result =
      Playtest.run(
        companions: [],
        turns: 2,
        minutes: 1,
        player: player,
        game_opts: [model: %Dragonex.Test.Narrator{}]
      )

    assert [%{kind: :pickup, changed: false, text: "Cojo el libro de cuentas del arcón."}] =
             result.inventory_checks
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

  test "reanuda un fallo de la última declaración antes de dar por terminada la tanda" do
    test_pid = self()
    failures = start_supervised!({Agent, fn -> 0 end})

    result =
      Playtest.run(
        companions: [],
        turns: 1,
        minutes: 1,
        max_resumes: 1,
        player: fn _ ->
          send(test_pid, :player_called)
          Agent.update(failures, fn _ -> 1 end)
          {:ok, "Miro a mi alrededor con calma."}
        end,
        on_event: &send(test_pid, &1),
        game_opts: [model: %__MODULE__.InterruptedNarrator{failures: failures}]
      )

    assert result.stop == :turns_reached
    assert result.resumes == 1
    assert result.declarations == 1
    assert_received {:resume, 1}
    assert_received :player_called
    refute_received :player_called
    assert result.metrics.retained == 1
    assert result.metrics.skipped == 0

    events = Dragonex.Games.list_events(result.game_id)
    assert Enum.count(events, &(&1.type == :action)) == 1
    assert List.last(events).payload["to"] == "Thane"
  end

  test "un fallo final sin presupuesto de reanudación devuelve paused, no éxito" do
    failures = start_supervised!({Agent, fn -> 0 end})

    result =
      Playtest.run(
        companions: [],
        turns: 1,
        minutes: 1,
        max_resumes: 0,
        player: fn _ ->
          Agent.update(failures, fn _ -> 1 end)
          {:ok, "Miro a mi alrededor con calma."}
        end,
        game_opts: [model: %__MODULE__.InterruptedNarrator{failures: failures}]
      )

    assert result.stop == :paused
    assert result.resumes == 0
    assert result.declarations == 1
    assert result.metrics.retained == 1
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
