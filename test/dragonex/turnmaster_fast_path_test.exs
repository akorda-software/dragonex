defmodule Dragonex.TurnmasterFastPathTest do
  @moduledoc """
  D30 fast path: after a DM beat in exploration whose narration unambiguously
  addresses an eligible human (and no pending human intent / re-eval / mini
  turn outranks them), the TurnMaster beat is skipped — every possible TM
  outcome for that state is already forced to `give_turn_to(name)` by
  `honor_exploration_floor` / `fallback_world_driven`.

  Evidence strategy: `TMSpy`, a counting model (same `@behaviour ExAgent.Model`
  contract as `RetryModel` in `game_live_test.exs`). Every real model request
  bumps an Agent counter readable from the test, so the oracle is the NUMBER
  of TM invocations: forced cases assert zero calls, control cases (ambiguous
  exploration, combat, mini cut_in, re-eval with a pending intent) assert at
  least one. The spy also replays a deterministic script, so control flows
  still exercise real (honored) decisions.
  """

  use ExUnit.Case, async: false

  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Games, Game, Monsters}
  alias ExAgent.Models.Test

  defmodule TMSpy do
    @moduledoc """
    TurnMaster model that counts every `request/4` in an Agent.

    `script` items replay in order (`{:tool_calls, calls}` or a text string);
    past the end (or with no script) it answers a fixed text — a mute TM that
    records no decision, i.e. the deterministic offline default.
    """
    @behaviour ExAgent.Model

    alias ExAgent.Message, as: Msg
    alias ExAgent.Message.{Part, Response, Usage}

    defstruct [:counter, :script]

    def start!(script \\ []) do
      # Register the counter before its Game so ExUnit closes the Game and
      # its outstanding model requests first. Linking it to the test process
      # would lose the counter as soon as the assertions finish.
      counter =
        ExUnit.Callbacks.start_supervised!(
          Supervisor.child_spec({Agent, fn -> 0 end}, id: {__MODULE__, make_ref()})
        )

      %__MODULE__{counter: counter, script: script}
    end

    def calls(%__MODULE__{counter: counter}), do: Agent.get(counter, & &1)

    @impl true
    def request(%__MODULE__{counter: counter, script: script} = m, _messages, _settings, _params) do
      n = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
      {:ok, build(Enum.at(script, n - 1)), m}
    end

    @impl true
    def request_stream(m, messages, settings, params) do
      {:ok, resp, updated} = request(m, messages, settings, params)

      Stream.concat([
        Stream.map(word_chunks(Response.text(resp)), &{:text_delta, &1}),
        [Dragonex.Test.Harness.stream_response(resp, updated)]
      ])
    end

    defp word_chunks(text), do: String.split(text, ~r/(?<=\s)/, include_captures: true)

    defp build({:tool_calls, calls}) do
      Msg.new_response(calls,
        usage: %Usage{input_tokens: 1, output_tokens: length(calls)},
        model_name: "tm-spy"
      )
    end

    defp build(text) when is_binary(text) do
      Msg.new_response([%Part.Text{content: text}],
        usage: %Usage{input_tokens: 1, output_tokens: 1},
        model_name: "tm-spy"
      )
    end

    defp build(_), do: build("(no decision)")

    @impl true
    def model_name(_), do: "tm-spy"
    @impl true
    def system(_), do: "tm-spy"
    @impl true
    def profile(_), do: %ExAgent.ModelProfile{supports_tools: true}
  end

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp hit_roller do
    fn
      20 -> 15
      _n -> 1
    end
  end

  defp give(to), do: {:tool_calls, [call("give_turn_to", %{"participant" => to})]}
  defp cut_in(to), do: {:tool_calls, [call("cut_in", %{"participant" => to})]}

  defp waiting_on(name), do: fn s -> s.status == :waiting and s.current == name end

  defp dm_script do
    [
      narration("El DM sitúa la escena en la ruina."),
      tool_calls([
        call("make_attack", %{"attacker" => "goblin", "target" => "Thane", "weapon" => "scimitar"})
      ]),
      narration("El goblin ataca."),
      narration("El DM cierra.")
    ]
  end

  defp two_humans_game(title) do
    {:ok, game} =
      Games.create_game(
        title: title,
        scene: "una taberna",
        roster: [{Archetypes.fighter(), :human}, {Archetypes.wizard(), :human}]
      )

    game
  end

  defp turnmaster_notes(game_id) do
    game_id
    |> Games.list_events()
    |> Enum.filter(&(&1.actor == "turnmaster" and &1.type == :system))
    |> Enum.map(&(&1.payload["note"] || ""))
  end

  defp system_notes(game_id) do
    game_id
    |> Games.list_events()
    |> Enum.filter(&(&1.type == :system))
    |> Enum.map(&(&1.payload["note"] || ""))
  end

  # ------------------------------------------------------------------ guards

  describe "exploration_dm_addressed_human/2 (predicate guards, via public APIs)" do
    defp state_for(game_id, overrides) do
      base = %Dragonex.Game{
        game_id: game_id,
        participants: %{
          "dm" => %{kind: :other},
          "Thane" => %{kind: :human},
          "Lyra" => %{kind: :human}
        },
        pc_agents: %{},
        intents: %{},
        last_actor: "dm",
        tm_reeval: false
      }

      struct(base, overrides)
    end

    test "fires on a named question to an eligible human after a DM beat" do
      game = two_humans_game("fp unit named")

      {:ok, _} =
        Games.append_event(game.id, :narration, "dm", "all", %{
          text: "Thane, el pergamino está cerrado. ¿Lo abres?"
        })

      assert Dragonex.Game.Turnmaster.exploration_dm_addressed_human(
               state_for(game.id, []),
               Games.load_world(game)
             ) == "Thane"
    end

    test "nil with mini/reaction bookkeeping even when the DM was just addressed" do
      game = two_humans_game("fp unit mini dm guards")

      {:ok, _} =
        Games.append_event(game.id, :narration, "dm", "all", %{
          text: "Thane, el pergamino está cerrado. ¿Lo abres?"
        })

      exploration = Games.load_world(game)

      # A parked cut_in/react mini turn: the TM must route it itself.
      refute Dragonex.Game.Turnmaster.exploration_dm_addressed_human(
               state_for(game.id, pending_mini: true),
               exploration
             )

      # The settled beat was a mini turn whose actor was the DM (a monster
      # reaction that survived a combat → exploration transition).
      refute Dragonex.Game.Turnmaster.exploration_dm_addressed_human(
               state_for(game.id, last_was_mini: true),
               exploration
             )

      # The brief still owes the word back to the interrupted actor.
      refute Dragonex.Game.Turnmaster.exploration_dm_addressed_human(
               state_for(game.id, interrupted: "Thane"),
               exploration
             )
    end

    test "nil outside exploration, on a PC last actor, on re-eval, with a pending intent or on ambiguous narration" do
      game = two_humans_game("fp unit guards")

      {:ok, _} =
        Games.append_event(game.id, :narration, "dm", "all", %{
          text: "Thane, el pergamino está cerrado. ¿Lo abres?"
        })

      state = state_for(game.id, [])
      exploration = Games.load_world(game)

      # Combat is never fast-pathed.
      refute Dragonex.Game.Turnmaster.exploration_dm_addressed_human(
               state,
               %{exploration | phase: :combat}
             )

      # Last actor a PC — the DM already answered (D28 path).
      refute Dragonex.Game.Turnmaster.exploration_dm_addressed_human(
               state_for(game.id, last_actor: "Thane"),
               exploration
             )

      refute Dragonex.Game.Turnmaster.exploration_dm_addressed_human(
               state_for(game.id, last_actor: nil),
               exploration
             )

      # A pending human intent outranks the addressed name (D27): the TM must
      # still be consulted because a mute TM would WorldDriven-cycle instead.
      refute Dragonex.Game.Turnmaster.exploration_dm_addressed_human(
               state_for(game.id,
                 intents: %{"Lyra" => %{"text" => "abro la puerta", "phase" => "exploration"}}
               ),
               exploration
             )

      # A re-eval from :waiting must keep the TM (mute TM parks the waiter).
      refute Dragonex.Game.Turnmaster.exploration_dm_addressed_human(
               state_for(game.id, tm_reeval: true),
               exploration
             )

      # Ambiguous narration: no forced handoff, the TM decides.
      {:ok, _} =
        Games.append_event(game.id, :narration, "dm", "all", %{
          text: "El posadero limpia un vaso."
        })

      refute Dragonex.Game.Turnmaster.exploration_dm_addressed_human(state, exploration)
    end
  end

  # ---------------------------------------------------------- forced (skip)

  test "named DM question in exploration hands off with ZERO TurnMaster calls" do
    game = two_humans_game("fp named zero calls")

    # If the fast path were broken, the spy WOULD be consulted and its script
    # would hand the floor to Lyra. Both the counter and the final floor prove
    # the bypass.
    spy = TMSpy.start!([give("Lyra"), "ok"])

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: [narration("Thane, el pergamino está cerrado. ¿Lo abres?")]},
            turnmaster_model: spy
          ]}}
      )

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)

    assert TMSpy.calls(spy) == 0

    snap = Game.snapshot(pid)
    assert snap.current == "Thane"
    assert snap.status == :waiting
    assert snap.world.phase == :exploration

    events = Games.list_events(game.id)

    # Same timeline a honored TM decision would produce: one turnmaster note
    # for the forced handoff, one DM narration, no relevo, no duplicated
    # actions.
    notes = turnmaster_notes(game.id)
    assert Enum.count(notes, &(&1 =~ "El turno pasa a Thane.")) == 1
    assert Enum.any?(notes, &(&1 =~ "El turno pasa al DM."))

    assert Enum.count(events, fn e ->
             e.type == :narration and e.actor == "dm" and
               (e.payload["text"] || "") =~ "pergamino"
           end) == 1

    refute Enum.any?(system_notes(game.id), &(&1 =~ "relevo"))
  end

  test "tú/si-quieres question to the last human speaker hands off with ZERO extra TurnMaster calls" do
    game = two_humans_game("fp tu zero calls")

    # Item 1 serves the FIRST (ambiguous) TM beat — a real, honored decision.
    # The tail must never run: the second handoff is forced by the tú/si
    # -quieres rule without consulting the TM.
    spy = TMSpy.start!([give("Thane"), "ok", give("Lyra"), "ok"])

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{
              script:
                [narration("El pergamino descansa sobre la mesa.")] ++
                  [narration("Thane se acerca.")] ++ [narration("Ábrelo tú, si quieres.")]
            },
            turnmaster_model: spy
          ]}}
      )

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)
    calls_after_first_tm = TMSpy.calls(spy)
    assert calls_after_first_tm >= 1

    assert {:ok, _} = Game.declare(pid, "Thane", "Miro el pergamino.")

    assert :ok ==
             Game.await(
               pid,
               fn s ->
                 Enum.any?(s.events, fn e ->
                   e.type == :narration and e.actor == "dm" and
                     (e.payload["text"] || "") =~ "si quieres"
                 end)
               end,
               10_000
             )

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)

    # The forced handoff added ZERO calls beyond the first ambiguous beat.
    assert TMSpy.calls(spy) == calls_after_first_tm

    notes = turnmaster_notes(game.id)
    # Two give-Thane notes: one from the real TM beat, one from the fast path.
    assert Enum.count(notes, &(&1 =~ "El turno pasa a Thane.")) == 2
    refute Enum.any?(notes, &(&1 =~ "Lyra"))
  end

  # -------------------------------------------------------- preserved calls

  test "ambiguous DM narration in exploration still consults the TurnMaster" do
    game = two_humans_game("fp ambiguous keeps tm")

    # Mute spy: records no decision, so the beat falls back to WorldDriven —
    # but it WAS consulted.
    spy = TMSpy.start!()

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: [narration("El posadero limpia un vaso tras otro.")]},
            turnmaster_model: spy
          ]}}
      )

    assert :ok ==
             Game.await(
               pid,
               fn s -> s.status in [:waiting, :running] and s.current != "dm" end,
               10_000
             )

    assert TMSpy.calls(spy) >= 1
  end

  test "ambiguous exploration honors the TM decision (no forced override)" do
    game = two_humans_game("fp ambiguous honored")

    spy = TMSpy.start!([give("Lyra"), "ok"])

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: [narration("El posadero limpia un vaso tras otro.")]},
            turnmaster_model: spy
          ]}}
      )

    # Lyra can ONLY hold the floor through the TM's own decision: the opener
    # goes to the DM and the fast path never fires on ambiguous narration.
    assert :ok == Game.await(pid, waiting_on("Lyra"), 10_000)
    assert TMSpy.calls(spy) >= 1
    assert Enum.any?(turnmaster_notes(game.id), &(&1 =~ "El turno pasa a Lyra."))
  end

  test "explicit consultation mode still runs the TurnMaster after a combat actor beat" do
    {:ok, game} =
      Games.create_game(
        title: "fp combat keeps tm",
        scene: "a torchlit ruin",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
        initiative: ["goblin", "Thane"]
      )

    # Beat 1 decides (give dm); beat 2 (after the DM's actor beat, still in
    # combat) goes mute — but it IS consulted and WorldDriven keeps the
    # partida going.
    spy = TMSpy.start!([give("dm"), "ok"])

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: dm_script() ++ [narration("ok")]},
            combat_handoffs: :turnmaster,
            turnmaster_model: spy,
            roller: hit_roller()
          ]}}
      )

    assert :ok == Game.await(pid, waiting_on("Thane"), 15_000)

    # Beat 1 (give dm) plus the post-actor beat: the latter is proven by the
    # WorldDriven relevo note — without it the loop would spin on DM beats and
    # never reach Thane's waiting floor.
    assert TMSpy.calls(spy) >= 2
    assert Enum.any?(system_notes(game.id), &(&1 =~ "relevo"))
  end

  test "mini cut_in turn still consults the TurnMaster afterwards" do
    {:ok, game} =
      Games.create_game(
        title: "fp mini keeps tm",
        scene: "a torchlit ruin",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
        initiative: ["goblin", "Thane"]
      )

    # Beat 1: give dm. Beat 2: cut_in Thane (mini). Beat 3 (after the mini
    # turn settles): mute tail — consulted again, falls back to WorldDriven.
    spy = TMSpy.start!([give("dm"), "ok", cut_in("Thane"), "ok"])

    pid =
      Dragonex.Test.GameFixture.start!({Dragonex.Game,
       {game.id,
        [
          # Contiguous per consumer: the DM's beat narrates the scene, then
          # Thane's mini beat narrates his reaction. (dm_script's tool item
          # would land on Thane's beat and be rejected by the control guard.)
          model: %Test{
            script: [
              narration("El DM sitúa la escena en la ruina."),
              narration("Thane se interpone con el escudo alzado."),
              narration("ok")
            ]
          },
          combat_handoffs: :turnmaster,
          turnmaster_model: spy,
          roller: hit_roller()
        ]}})

    # TM gives the goblin's floor to the DM, then cuts Thane in (mini).
    assert :ok ==
             Game.await(pid, fn s -> s.current == "Thane" and s.status == :waiting end, 15_000)

    # The human's mini beat resolves tools and publishes the literal reaction
    # (a cut_in mini turn runs with turn_kind "reaction", and the turn budget
    # rejects action-cost tools like make_attack — only reaction-slot costs
    # would resolve mechanically):
    assert {:ok, _} = Game.declare(pid, "Thane", "me interpongo ante el goblin")

    assert :ok ==
             Game.await(
               pid,
               fn s ->
                 Enum.any?(s.events, fn e ->
                   e.type == :narration and e.actor == "Thane" and
                     e.payload["text"] == "me interpongo ante el goblin" and
                     e.payload["kind"] == "human_declaration"
                 end)
               end,
               15_000
             )

    # …and the TurnMaster IS consulted after the mini turn settles: the
    # WorldDriven relevo note lands (the third beat went mute).
    assert :ok ==
             Game.await(
               pid,
               fn s ->
                 Enum.any?(s.events, fn e ->
                   e.type == :system and (e.payload["note"] || "") =~ "relevo"
                 end)
               end,
               15_000
             )

    # Three TM beats, at least one model request each.
    assert TMSpy.calls(spy) >= 3
    assert Enum.any?(turnmaster_notes(game.id), &(&1 =~ "interrumpe"))
  end

  test "pending human intent at re-eval keeps the TM and D27 outranks the addressed name" do
    game = two_humans_game("fp reeval pending")

    spy = TMSpy.start!(Enum.flat_map(1..6, fn _ -> [give("Thane"), "ok"] end))

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{
              script:
                [narration("Thane, el pergamino está cerrado. ¿Lo abres?")] ++
                  [narration("Lyra se adelanta.")] ++ [narration("ok")]
            },
            turnmaster_model: spy
          ]}}
      )

    # Fast path: the named question hands the floor to Thane with no TM call.
    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)
    assert TMSpy.calls(spy) == 0

    # Lyra declares off-turn → the TM IS re-consulted (no fast path on
    # re-eval/pending intent)…
    assert {:ok, :queued} = Game.declare(pid, "Lyra", "me pongo delante")

    # …and its give-Thane decision is overridden by the pending intent: Lyra
    # acts, which is impossible without a real (honored-then-overridden) TM
    # beat — the fast path alone would have parked the partida on Thane.
    assert :ok ==
             Game.await(
               pid,
               fn s ->
                 Enum.any?(s.events, fn e -> e.type == :action and e.actor == "Lyra" end)
               end,
               10_000
             )

    assert TMSpy.calls(spy) >= 1
    assert Enum.any?(turnmaster_notes(game.id), &(&1 =~ "El turno pasa a Lyra."))
    refute Map.has_key?(Games.get_game(game.id).intents, "Lyra")
  end

  # ------------------------------------------------------------------ pause

  test "pause after a forced handoff stays paused with no duplicated handoffs" do
    game = two_humans_game("fp pause")

    spy = TMSpy.start!([give("Lyra"), "ok"])

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: %Test{script: [narration("Thane, el pergamino está cerrado. ¿Lo abres?")]},
            turnmaster_model: spy
          ]}}
      )

    assert :ok == Game.await(pid, waiting_on("Thane"), 10_000)
    assert :ok == Game.pause(pid)
    assert TMSpy.calls(spy) == 0

    before_notes = Enum.count(turnmaster_notes(game.id), &(&1 =~ "El turno pasa a Thane."))

    Process.sleep(150)

    assert Game.status(pid) == :paused
    assert Game.current(pid) == "Thane"

    assert Enum.count(turnmaster_notes(game.id), &(&1 =~ "El turno pasa a Thane.")) ==
             before_notes
  end
end
