defmodule Dragones.GamePhase0Test do
  @moduledoc """
  Phase 0 proof: the `Dragones.Game` process runs the full loop, persists every
  change to Postgres, and rehydrates the same `game_id` after its process dies.

  Arc (goblin-first combat, fixed roller so attacks hit for minimal damage):

    1. Game starts → DM auto-acts (goblin attacks Thane) in a Task.   [AI turn]
    2. Thane's turn → the test calls act/2 → Thane attacks the goblin. [human turn]
    3. DM auto-acts again (goblin attacks Thane).                      [AI turn]
    4. Everything persisted: world jsonb + append-only events.
    5. Kill the process → restart → same game_id resumes on Thane's turn
       with the exact hp/round/events it left.

  Uses Ecto SQL Sandbox in `:shared` mode (async: false) because the Game runs
  beats in Tasks that share the test's DB connection. Assertions wait on stable
  predicates (a human's :waiting turn, or a world change) rather than the
  transient "dm" turn the loop auto-advances past in milliseconds.
  """

  use ExUnit.Case, async: false

  import Dragones.Test.Harness

  alias Dragones.{Archetypes, Games, Game, Monsters}
  alias ExAgent.Models.Test

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragones.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Dragones.Repo, {:shared, self()})
    :ok
  end

  # d20 always 15 (a hit), every other die 1 (minimal damage) — so combat runs
  # several beats without anyone dropping.
  defp hit_roller do
    fn
      20 -> 15
      _n -> 1
    end
  end

  # One DM agent scripts every beat: tool-call then narration. Beats alternate
  # goblin-attacks-Thane (DM turn) and Thane-attacks-goblin (human turn).
  defp script do
    [
      # beat 1 — DM (goblin) attacks Thane
      tool_calls([call("make_attack", %{"attacker" => "goblin", "target" => "Thane", "weapon" => "scimitar"})]),
      text("The goblin lunges at Thane."),
      # beat 2 — Thane (human) attacks the goblin
      tool_calls([call("make_attack", %{"attacker" => "Thane", "target" => "goblin", "weapon" => "longsword"})]),
      text("Thane brings his longsword down."),
      # beat 3 — DM (goblin) attacks Thane again
      tool_calls([call("make_attack", %{"attacker" => "goblin", "target" => "Thane", "weapon" => "scimitar"})]),
      text("The goblin strikes once more.")
    ]
  end

  # A stable "human is waiting" predicate: the loop idles here, so no race.
  defp waiting_on(name),
    do: fn s -> s.status == :waiting and s.current == name end

  test "AI auto-acts, a human acts, it all persists, and it rehydrates after a kill" do
    {:ok, game} =
      Games.create_game(
        title: "phase 0",
        scene: "a torchlit ruin",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
        initiative: ["goblin", "Thane"]
      )

    game_id = game.id

    pid =
      ExUnit.Callbacks.start_supervised!({Dragones.Game, {game_id, [model: %Test{script: script()}, roller: hit_roller()]}})

    # 1 — The DM auto-acts (goblin attacks Thane), then it's Thane's turn.
    assert :ok == Game.await(pid, waiting_on("Thane"))

    world = Game.world(pid)
    assert world.characters["Thane"].hp == 9

    # 2 — The human acts: Thane attacks the goblin. Wait for the goblin's hp to
    # drop (beat #2's effect) and the loop to settle back on Thane's turn.
    assert {:ok, :resolving} = Game.declare(pid, "Thane", "I attack the goblin with my longsword.")

    assert :ok ==
             Game.await(pid, fn s ->
               s.status == :waiting and s.current == "Thane" and
                 s.world.characters["goblin"].hp < 7
             end)

    world = Game.world(pid)
    assert world.characters["goblin"].hp == 3
    # Two goblin hits (3 each): Thane 12 -> 9 -> 6.
    assert world.characters["Thane"].hp == 6
    thane_hp_before_kill = world.characters["Thane"].hp
    goblin_hp_before_kill = world.characters["goblin"].hp

    # 3 — The timeline persisted: a narration per beat + the player's action.
    events = Games.list_events(game_id)
    narrations = Enum.filter(events, &(&1.type == :narration))
    assert length(narrations) == 4
    actions = Enum.filter(events, &(&1.type == :action))
    assert Enum.any?(actions, &(&1.payload["text"] =~ "longsword"))

    # The persisted world jsonb matches the live struct.
    persisted = Games.get_game(game_id)
    assert persisted.current_participant == "Thane"
    assert persisted.status == :waiting
    assert Games.load_world(persisted).characters["Thane"].hp == thane_hp_before_kill

    # 4 — Kill the process (abnormal exit); the :transient supervisor restarts
    # it and it rehydrates the same game_id from Postgres.
    old_pid = pid
    Process.exit(pid, :kill)

    pid2 =
      poll_until(fn -> Dragones.Game.Supervisor.whereis(game_id) end, fn p -> p not in [nil, old_pid] end, 5_000) ||
        flunk("Game process did not restart after kill")

    # Resumed exactly where it left off: Thane's turn, :waiting, same hp.
    assert Game.current(pid2) == "Thane"
    assert Game.status(pid2) == :waiting
    assert Game.world(pid2).characters["Thane"].hp == thane_hp_before_kill
    assert Game.world(pid2).characters["goblin"].hp == goblin_hp_before_kill
  end

  test "pause stops the loop (from :waiting) and resume lets the human act" do
    {:ok, game} =
      Games.create_game(
        title: "pause",
        scene: "a ruin",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
        initiative: ["goblin", "Thane"]
      )

    pid =
      ExUnit.Callbacks.start_supervised!({Dragones.Game, {game.id, [model: %Test{script: script()}, roller: hit_roller()]}})

    assert :ok == Game.await(pid, waiting_on("Thane"))
    assert :ok == Game.pause(pid)
    assert Game.status(pid) == :paused

    # While paused, a declare queues (it doesn't resolve), and survives resume.
    assert {:ok, :queued} = Game.declare(pid, "Thane", "I swing at the goblin.")

    assert :ok == Game.resume(pid)
    # On resume the loop consumes the queued intent → Thane's beat runs.
    assert :ok == Game.await(pid, waiting_on("Thane"))
    assert Game.world(pid).characters["goblin"].hp < 7
  end

  test "a declare off-turn is queued and auto-resolved when the turn arrives" do
    {:ok, game} =
      Games.create_game(
        title: "queue",
        scene: "a ruin",
        roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
        initiative: ["goblin", "Thane"]
      )

    pid =
      ExUnit.Callbacks.start_supervised!({Dragones.Game, {game.id, [model: %Test{script: script()}, roller: hit_roller()]}})

    # DM (goblin) auto-acts, then Thane's turn. Thane declares while still the
    # DM is acting (busy) — it queues and persists.
    assert :ok == Game.await(pid, fn s -> s.status == :waiting and s.current == "Thane" end)

    # Pause so we can inspect the queue without the loop racing ahead, then queue.
    assert :ok == Game.pause(pid)
    assert {:ok, :queued} = Game.declare(pid, "Thane", "I attack the goblin.")
    # The intent is durable in the DB.
    assert Games.get_game(game.id).intents["Thane"] =~ "attack the goblin"

    assert :ok == Game.resume(pid)
    # The loop consumes the queued intent → Thane's beat runs → goblin hurt.
    assert :ok == Game.await(pid, waiting_on("Thane"))
    assert Game.world(pid).characters["goblin"].hp < 7
    # The intent is cleared after consumption.
    refute Map.has_key?(Games.get_game(game.id).intents, "Thane")
  end

  test "multi-human: a declare off-turn is queued and auto-resolved on that human's turn" do
    # Two human PCs (Thane, Lyra) + a goblin. Initiative: goblin → Thane → Lyra.
    {:ok, game} =
      Games.create_game(
        title: "multi-human",
        scene: "a ruin",
        roster: [{Archetypes.fighter(), :human}, {Archetypes.wizard(), :human}, {Monsters.goblin(), :ai}],
        initiative: ["goblin", "Thane", "Lyra"]
      )

    script = [
      # beat 1 — goblin (dm) attacks Thane
      tool_calls([call("make_attack", %{"attacker" => "goblin", "target" => "Thane", "weapon" => "scimitar"})]),
      text("The goblin snarls and lunges at Thane."),
      # beat 2 — Thane (human) attacks the goblin
      tool_calls([call("make_attack", %{"attacker" => "Thane", "target" => "goblin", "weapon" => "longsword"})]),
      text("Thane brings his blade down."),
      # beat 3 — Lyra (human) casts at the goblin (consumed from her queued intent)
      tool_calls([call("cast_spell", %{"caster" => "Lyra", "spell" => "firebolt", "target" => "goblin"})]),
      text("Lyra hurls a bolt of fire.")
    ]

    pid =
      ExUnit.Callbacks.start_supervised!({Dragones.Game, {game.id, [model: %Test{script: script}, roller: hit_roller()]}})

    # DM auto-acts (goblin), then it's Thane's turn.
    assert :ok == Game.await(pid, fn s -> s.status == :waiting and s.current == "Thane" end)

    # Lyra declares off-turn (it's Thane's turn) → queued, not resolved.
    assert {:ok, :queued} = Game.declare(pid, "Lyra", "I cast firebolt at the goblin.")
    # Thane declares on his own turn → resolves now.
    assert {:ok, :resolving} = Game.declare(pid, "Thane", "I attack the goblin.")

    # Thane's beat completes → the loop advances to Lyra and consumes her queued
    # intent automatically (no second declare needed). Wait until both declared
    # actions are recorded — proof Lyra's queued intent was valued on her turn.
    assert :ok ==
             Game.await(pid, fn s ->
               actors =
                 s.events |> Enum.filter(&(&1.type == :action)) |> Enum.map(& &1.actor)

               actors == ["Thane", "Lyra"]
             end)

    # Both humans' declared actions were recorded, in turn order.
    actions =
      game.id
      |> Games.list_events()
      |> Enum.filter(&(&1.type == :action))
      |> Enum.map(& &1.actor)

    assert actions == ["Thane", "Lyra"]
  end

  test "DM robustness: a mis-act (monster on a player's turn) is rejected and the DM self-corrects on retry" do
    # Thane + Lyra vs goblin. On Lyra's turn the DM is scripted to FIRST propose
    # as the goblin (refused by the control guard → directive error → retry) and
    # THEN correctly as Lyra. The directive error + max_retries budget lets the
    # beat recover instead of failing to :paused.
    {:ok, game} =
      Games.create_game(
        title: "self-correct",
        scene: "a ruin",
        roster: [{Archetypes.fighter(), :human}, {Archetypes.wizard(), :human}, {Monsters.goblin(), :ai}],
        initiative: ["goblin", "Thane", "Lyra"]
      )

    script = [
      # beat 1 — goblin (dm) attacks Thane
      tool_calls([call("make_attack", %{"attacker" => "goblin", "target" => "Thane", "weapon" => "scimitar"})]),
      text("The goblin lunges."),
      # beat 2 — Thane attacks the goblin
      tool_calls([call("make_attack", %{"attacker" => "Thane", "target" => "goblin", "weapon" => "longsword"})]),
      text("Thane swings."),
      # beat 3 — Lyra's turn: DM mis-acts (goblin) → REFUSED → retry → corrects (Lyra)
      tool_calls([call("make_attack", %{"attacker" => "goblin", "target" => "Thane", "weapon" => "scimitar"})]),
      tool_calls([call("cast_spell", %{"caster" => "Lyra", "spell" => "firebolt", "target" => "goblin"})]),
      text("Lyra hurls a bolt of fire."),
      # beat 4 — goblin (dm) attacks Thane again (keeps the loop from exhausting)
      tool_calls([call("make_attack", %{"attacker" => "goblin", "target" => "Thane", "weapon" => "scimitar"})]),
      text("The goblin snaps back.")
    ]

    pid =
      ExUnit.Callbacks.start_supervised!({Dragones.Game, {game.id, [model: %Test{script: script}, roller: hit_roller()]}})

    # DM (goblin) → Thane's turn. Thane declares on his turn.
    assert :ok == Game.await(pid, fn s -> s.status == :waiting and s.current == "Thane" end)
    assert {:ok, :resolving} = Game.declare(pid, "Thane", "I attack the goblin.")

    # Lyra's turn auto-arrives; her queued... actually she has none queued — the
    # loop reaches her turn and waits. Declare so her (self-correcting) beat runs.
    assert :ok == Game.await(pid, fn s -> s.status == :waiting and s.current == "Lyra" end)
    assert {:ok, :resolving} = Game.declare(pid, "Lyra", "I cast firebolt at the goblin.")

    # The beat recovered (NOT :paused): Lyra acted, the goblin took damage.
    assert :ok ==
             Game.await(pid, fn s ->
               Enum.any?(s.events, &(&1.type == :action and &1.actor == "Lyra")) and
                 s.status != :running
             end)

    assert Game.status(pid) != :paused
    assert Game.world(pid).characters["goblin"].hp < 7
  end

  # Round counter + turn order with the dm LAST in initiative (the user's case:
  # human first, dm last). A round is one full initiative cycle; the round must
  # bump exactly when the last combatant acts, and the human at the top of the
  # order must NOT be skipped after the wrap.
  test "dm-last initiative: round advances once per cycle and the human is not skipped" do
    {:ok, game} =
      Games.create_game(
        title: "dm-last",
        scene: "a ruin",
        roster: [{Archetypes.fighter(), :human}, {Archetypes.wizard(), :human}, {Monsters.goblin(), :ai}],
        initiative: ["Thane", "Lyra", "goblin"]
      )

    # cycle [Thane, Lyra, dm]; beats: Thane, Lyra, dm, Thane, Lyra, dm
    script = [
      tool_calls([call("make_attack", %{"attacker" => "Thane", "target" => "goblin", "weapon" => "longsword"})]),
      text("Thane ataca."),
      tool_calls([call("make_attack", %{"attacker" => "Lyra", "target" => "goblin", "spell" => "firebolt"})]),
      text("Lyra conjura."),
      tool_calls([call("make_attack", %{"attacker" => "goblin", "target" => "Thane", "weapon" => "scimitar"})]),
      text("El goblin ataca."),  # dm acts (last) → bump round 2, wrap to Thane
      tool_calls([call("make_attack", %{"attacker" => "Thane", "target" => "goblin", "weapon" => "longsword"})]),
      text("Thane ataca de nuevo.")
    ]

    pid =
      ExUnit.Callbacks.start_supervised!({Dragones.Game, {game.id, [model: %Test{script: script}, roller: hit_roller()]}})

    # Thane (human, top of order) is first → waiting immediately.
    assert :ok == Game.await(pid, waiting_on("Thane"))
    assert Game.world(pid).round == 1

    # Thane acts (beat 1) → Lyra's turn.
    assert {:ok, :resolving} = Game.declare(pid, "Thane", "attack")
    assert :ok == Game.await(pid, waiting_on("Lyra"))

    # Lyra acts (beat 2) → dm auto-acts (beat 3, last) → bump to round 2 → Thane.
    assert {:ok, :resolving} = Game.declare(pid, "Lyra", "cast firebolt")
    assert :ok == Game.await(pid, fn s -> s.status == :waiting and s.current == "Thane" and s.round == 2 end)
  end

  defp poll_until(thunk, predicate, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(thunk)
    |> Enum.find_value(fn value ->
      cond do
        predicate.(value) -> value
        System.monotonic_time(:millisecond) >= deadline -> nil
        true -> Process.sleep(10); nil
      end
    end)
  end
end
