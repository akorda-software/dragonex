# Run with:
#   OPENROUTER_API_KEY=... DRAGONES_MODEL=deepseek/deepseek-v4-flash mix run priv/live_check.exs
#
# Verifies the DM adjudicates a non-combat action through ability_check: the DM
# sets the DC, the engine rolls d20 + WIS modifier, the DM narrates the result.

alias Dragones.{Archetypes, Brief, World}
alias ExAgent.{Models, Server, Session}
alias ExAgent.Session.{Participant, SharedState}

unless System.get_env("OPENROUTER_API_KEY"),
  do: raise("set OPENROUTER_API_KEY (and optionally DRAGONES_MODEL)")

model =
  Models.OpenRouter.new(
    model: System.get_env("DRAGONES_MODEL", "deepseek/deepseek-v4-flash"),
    app_title: "dragones ability-check dev"
  )

{:ok, dm} = Server.start_link(agent: DM.new(model), agent_id: "dm-check", pubsub: :local)

world =
  [World.add_character(Archetypes.fighter()), World.set_scene("a stone corridor; one flagstone looks slightly raised")]
  |> Enum.reduce(World.new(), fn ch, w -> {:ok, nw} = ch.(w); nw end)

{:ok, game} =
  Session.start_link(
    shared_state: world,
    policy: {Dragones.TurnPolicy.WorldDriven, dm: "dm"},
    participants: [Participant.new(id: "dm", kind: :agent), Participant.new(id: "Thane", kind: :human)],
    session_id: "check-#{:erlang.unique_integer([:positive])}"
  )

{:ok, _} = Session.start(game)
{:ok, _} = Session.end_turn(game, "dm")  # Thane's turn

{:ok, roll_log} = Agent.start_link(fn -> [] end)
roller = fn sides -> v = :rand.uniform(sides); Agent.update(roll_log, fn l -> l ++ [{sides, v}] end); v end

prompt =
  Brief.turn_prompt(
    Session.read_state(game),
    "Thane",
    "Thane (the player) declares: \"I examine the raised flagstone for traps before stepping on it.\". " <>
      "Resolve this with an ability_check (Wisdom / Perception, DC 13) and narrate what Thane finds.",
    "dm"
  )

{:ok, %{output: text}} =
  Server.chat(dm, prompt, deps: %{state: SharedState.new(game, "Thane"), roller: roller})

IO.puts("\n=== DM ===")
IO.puts(text)
IO.puts("\n=== dice rolled by the engine ===")
rolls = Agent.get(roll_log, & &1)

if rolls == [] do
  IO.puts("(none — the DM did NOT call ability_check)")
else
  Enum.each(rolls, fn {s, v} -> IO.puts("  d#{s} -> #{v}") end)
end
