# Run with:
#   OPENROUTER_API_KEY=... DRAGONES_MODEL=deepseek/deepseek-v4-flash mix run priv/live_dm.exs
#
# Verifies the turn flow live: a single DM agent resolves the player's action on
# Thane's turn (proposing as "thane") and acts for the goblin on the DM's turn
# (proposing as "dm"). The dice confirm the tools ran; the world confirms the
# rules were applied; the turn alternation confirms the policy drives the order.

alias Dragones.{Archetypes, DM, Monsters, TurnPolicy.WorldDriven, World}
alias ExAgent.{Models, Server, Session}
alias ExAgent.Session.{Participant, SharedState}

unless System.get_env("OPENROUTER_API_KEY"),
  do: raise("set OPENROUTER_API_KEY (and optionally DRAGONES_MODEL)")

model =
  Models.OpenRouter.new(
    model: System.get_env("DRAGONES_MODEL", "deepseek/deepseek-v4-flash"),
    app_title: "dragones turn-flow dev"
  )

{:ok, dm} = Server.start_link(agent: DM.new(model), agent_id: "dm-flow", pubsub: :local)

world =
  [
    World.add_character(Archetypes.fighter()),
    World.add_character(Monsters.goblin()),
    World.set_scene("a torchlit ruin"),
    World.begin_combat(["goblin", "Thane"])
  ]
  |> Enum.reduce(World.new(), fn ch, w -> {:ok, nw} = ch.(w); nw end)

{:ok, game} =
  Session.start_link(
    shared_state: world,
    policy: {WorldDriven, dm: "dm"},
    participants: [Participant.new(id: "dm", kind: :agent), Participant.new(id: "Thane", kind: :human)],
    session_id: "flow-#{:erlang.unique_integer([:positive])}"
  )

{:ok, _} = Session.start(game)
# Begin combat -> initiative[goblin->dm, Thane]; first is the goblin (dm).
IO.puts("\n=== current actor: #{inspect(Session.current(game))} (goblin's slot -> dm) ===")

defmodule Runner do
  def beat(label, game, dm, propose_as, instruction) do
    IO.puts("\n########## #{label} (propose as #{propose_as}) ##########")
    world = Session.read_state(game)
    prompt = Dragones.DM.turn_prompt(world, propose_as, instruction, "dm")

    {:ok, roll_log} = Agent.start_link(fn -> [] end)

    roller = fn sides ->
      v = :rand.uniform(sides)
      Agent.update(roll_log, fn l -> l ++ [{sides, v}] end)
      v
    end

    deps = %{state: SharedState.new(game, propose_as), roller: roller}

    {:ok, %{output: text}} = Server.chat(dm, prompt, deps: deps)
    IO.puts("DM: #{text}")

    IO.puts("dice rolled: " <>
      (Agent.get(roll_log, & &1) |> Enum.map_join(", ", fn {s, v} -> "d#{s}=#{v}" end)))

    {:ok, _} = Session.end_turn(game, propose_as)
    IO.puts("next actor: #{inspect(Session.current(game))}")

    w = Session.read_state(game)
    IO.puts("Thane #{w.characters["Thane"].hp}/#{w.characters["Thane"].max_hp} hp; goblin #{w.characters["goblin"].hp}/#{w.characters["goblin"].max_hp} hp; phase #{w.phase}")
  end
end

# The goblin (dm) acts first.
Runner.beat("DM turn (goblin)", game, dm, "dm", "Act for the goblin: it attacks Thane. Call the tool and narrate.")

# Now Thane (player) acts; the DM adjudicates, proposing as "Thane".
Runner.beat("Thane turn (player)", game, dm, "Thane",
  "Thane (the player) declares: \"I attack the goblin with my longsword.\". Resolve it by the rules and narrate."
)

# Back to the DM (goblin) — second round.
Runner.beat("DM turn (goblin, rd2)", game, dm, "dm", "Act for the goblin again: attack Thane. Call the tool and narrate.")

Server.abort(dm)
