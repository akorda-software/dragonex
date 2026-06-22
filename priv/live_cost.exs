# Live cost check: prompt caching + compaction + modelo-por-rol.
#
# Run with a LOW compaction threshold so it fires within a few beats:
#   set -a; source .env; set +a
#   DRAGONES_MODEL=deepseek/deepseek-v4-flash \
#   DRAGONES_SUMMARIZER_MODEL=google/gemini-3.1-flash-lite \
#   DRAGONES_COMPACTION_THRESHOLD=1200 \
#   mix run priv/live_cost.exs
#
# Shows, per beat: cached vs total input tokens (prompt-caching win), and logs
# when compaction fires (the cheap summarizer recaps the old history).

alias Dragones.{Archetypes, Game, Games, Monsters}

unless System.get_env("OPENROUTER_API_KEY"),
  do: raise("set OPENROUTER_API_KEY")

Application.ensure_all_started(:dragones)

{:ok, game} =
  Games.create_game(
    title: "cost demo",
    scene: "a torchlit ruin",
    story_bible: %{"hook" => "a goblin guards a relic", "tone" => "gritty"},
    roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
    initiative: ["goblin", "Thane"]
  )

IO.puts("game_id: #{game.id}  (model #{System.get_env("DRAGONES_MODEL")}, summarizer #{System.get_env("DRAGONES_SUMMARIZER_MODEL", "google/gemini-3.1-flash-lite")})")
IO.puts("compaction threshold: #{System.get_env("DRAGONES_COMPACTION_THRESHOLD", "6000")} tokens\n")

{:ok, pid} = Game.ensure_started(game.id)

# Loop beats: Thane (human) + goblin (dm) auto. Each iteration = 2 beats.
for i <- 1..6 do
  # Wait for Thane's turn, declare an attack (resolves immediately).
  :ok = Game.await(pid, fn s -> s.status == :waiting and s.current == "Thane" end, 60_000)
  {:ok, :resolving} = Game.declare(pid, "Thane", "I attack the goblin with my longsword.")

  # Let Thane's beat + the chained goblin beat settle back to Thane.
  :ok =
    Game.await(pid, fn s -> s.status == :waiting and s.current == "Thane" end, 60_000)

  w = Game.world(pid)
  IO.puts("round #{i}: Thane #{w.characters["Thane"].hp} hp, goblin #{w.characters["goblin"].hp} hp")
end

# Report the full timeline length (compaction caps the AGENT history, not the
# persisted game_events — those stay append-only for replay).
IO.puts("\npersisted game_events: #{length(Games.list_events(game.id))}")
IO.puts("(token usage + compaction are logged above as [info] lines)")
IO.puts("\n=== cost demo OK ===")
System.halt(0)
