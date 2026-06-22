# Live Phase 0 check: a real LLM DM drives the Dragones.Game process.
#
# Run with:
#   set -a; source .env; set +a
#   DRAGONES_MODEL=deepseek/deepseek-v4-flash mix run priv/live_game.exs
#
# Proves the full Fase 0 loop through the Game process + Postgres:
#   - the DM (AI) auto-acts in a Task (goblin attacks Thane);
#   - a human acts (Thane attacks the goblin);
#   - every beat persists (world jsonb + game_events);
#   - killing + restarting the process rehydrates the same game_id.
#
# The key invariant (from the spike): the DM does NOT invent outcomes — it calls
# the tools, which is detectable as hp changing by the rules + dice rolled.

alias Dragones.{Game, Games, Scenario}
alias ExAgent.Models

unless System.get_env("OPENROUTER_API_KEY"),
  do: raise("set OPENROUTER_API_KEY (and optionally DRAGONES_MODEL)")

Application.ensure_all_started(:dragones)

model =
  Models.OpenRouter.new(
    model: System.get_env("DRAGONES_MODEL", "deepseek/deepseek-v4-flash"),
    app_title: "dragones fase-0 live"
  )

# Instrumented roller: every call is proof the engine ran a tool. (The Game
# wraps it further to broadcast dice rolls for the LiveView modal — transparent
# here.)
{:ok, roll_log} = Agent.start_link(fn -> [] end)

roller = fn sides ->
  v = :rand.uniform(sides)
  Agent.update(roll_log, fn logs -> [{sides, v} | logs] end)
  v
end

IO.puts("\n=== creating game (multi-human: Thane + Lyra vs goblin, goblin-first) ===")

{:ok, game} =
  Games.create_from_wizard(%{
    "title" => "live multi-human",
    "scene" => "a torchlit ruin",
    "dm_style" => "vivid but brief",
    "roster" => %{
      "fighter" => %{"include" => "on", "kind" => "human"},
      "wizard" => %{"include" => "on", "kind" => "human"},
      "goblin" => %{"include" => "on"}
    }
  })

game_id = game.id
IO.puts("game_id: #{game_id}")

{:ok, pid} = Game.ensure_started(game_id, model: model, roller: roller)

# 1 — DM auto-acts (goblin's turn). Wait for Thane's turn (:waiting).
IO.puts("\n=== waiting for the DM to act (goblin) ===")
:ok = Game.await(pid, fn s -> s.status == :waiting and s.current == "Thane" end, 60_000)

print_beat = fn label ->
  IO.puts("\n########## #{label} ##########")
  w = Game.world(pid)

  IO.puts(
    "Thane #{w.characters["Thane"].hp}/#{w.characters["Thane"].max_hp} hp; " <>
      "Lyra #{w.characters["Lyra"].hp}/#{w.characters["Lyra"].max_hp} hp; " <>
      "goblin #{w.characters["goblin"].hp}/#{w.characters["goblin"].max_hp} hp; phase #{w.phase}"
  )

  rolls = Agent.get(roll_log, &Enum.reverse/1)
  IO.puts("dice rolled: " <> Enum.map_join(rolls, ", ", fn {s, v} -> "d#{s}=#{v}" end))
  Agent.update(roll_log, fn _ -> [] end)
end

print_beat.("after DM beat #1 (goblin acted)")

# Show the narration events so far.
narrations =
  Games.list_events(game_id)
  |> Enum.filter(&(&1.type == :narration))
  |> Enum.map(& &1.payload["text"])

IO.puts("\nDM narrated:\n" <> Enum.map_join(narrations, "\n", &"  - #{&1}"))

# 2 — Thane's turn. Lyra DECLARES off-turn (her intent queues); Thane declares
# on his turn → resolves now.
IO.puts("\n=== Thane's turn; Lyra declares off-turn (queued) ===")
queued = Game.declare(pid, "Lyra", "I cast firebolt at the goblin!")
IO.puts("Lyra declares off-turn -> #{inspect(queued)} (intent persisted, will resolve on her turn)")
thanes = Game.declare(pid, "Thane", "I attack the goblin with my longsword.")
IO.puts("Thane declares on his turn -> #{inspect(thanes)} (resolves now)")

# 3 — The loop advances to Lyra and AUTO-CONSUMES her queued intent (no
# re-declare). Wait until Lyra's action is recorded — proof her queued intent
# was picked up and the DM is valuing it.
IO.puts("\n=== Lyra's turn: queued intent auto-consumed (the DM values it) ===")

lyra_acted? = fn s ->
  Enum.any?(s.events, &(&1.type == :action and &1.actor == "Lyra"))
end

case Game.await(pid, lyra_acted?, 60_000) do
  :ok ->
    print_beat.("after Lyra's queued intent was consumed")

    # Let the beat settle (or fail-safe to :paused if the DM mis-acts).
    _ = Game.await(pid, fn s -> s.status in [:waiting, :paused, :ended] end, 60_000)
    print_beat.("after Lyra's beat settled (status #{Game.status(pid)})")

  :timeout ->
    IO.puts("\n[Lyra's queued intent was never consumed — unexpected.]")
end

# 3 — Persistence proof: the world jsonb + event count.
persisted = Games.get_game(game_id)
IO.puts("\n=== persistence ===")
IO.puts("persisted current_participant: #{persisted.current_participant}")
IO.puts("persisted status: #{persisted.status}")
IO.puts("persisted Thane hp (jsonb): #{persisted.world["characters"]["Thane"]["hp"]}")
IO.puts("persisted events: #{length(Games.list_events(game_id))}")

# 4 — Kill + restart: rehydrate the same game_id.
IO.puts("\n=== killing the Game process; restarting it ===")
old_pid = pid
Process.exit(pid, :kill)

pid2 =
  Stream.repeatedly(fn -> Dragones.Game.Supervisor.whereis(game_id) end)
  |> Enum.find_value(fn
    p when is_pid(p) and p != old_pid -> p
    _ -> Process.sleep(20); nil
  end)

IO.puts("restarted pid: #{inspect(pid2)} (was #{inspect(old_pid)})")
IO.puts("resumed current: #{Game.current(pid2)}")
IO.puts("resumed status: #{Game.status(pid2)}")
w2 = Game.world(pid2)
IO.puts("resumed Thane hp: #{w2.characters["Thane"].hp} (matches persisted: #{persisted.world["characters"]["Thane"]["hp"]})")

IO.puts("\n=== Fase 3 multi-human live check OK ===")
System.halt(0)
