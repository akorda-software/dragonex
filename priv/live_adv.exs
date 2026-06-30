# Run with:
#   OPENROUTER_API_KEY=... DRAGONES_MODEL=deepseek/deepseek-v4-flash mix run priv/live_adv.exs
#
# Verifies advantage end-to-end live: the DM, told the goblin is prone, should
# pass mode "advantage" to make_attack, and the engine rolls 2d20 (kept higher).

alias Dragones.{Archetypes, Brief, Monsters, World}
alias ExAgent.{Models, Server, Session}
alias ExAgent.Session.{Participant, SharedState}

unless System.get_env("OPENROUTER_API_KEY"),
  do: raise("set OPENROUTER_API_KEY (and optionally DRAGONES_MODEL)")

model =
  Models.OpenRouter.new(
    model: System.get_env("DRAGONES_MODEL", "deepseek/deepseek-v4-flash"),
    app_title: "dragones advantage dev"
  )

{:ok, dm} = Server.start_link(agent: DM.new(model), agent_id: "dm-adv", pubsub: :local)

world =
  [World.add_character(Archetypes.fighter()), World.add_character(Monsters.goblin()), World.begin_combat(["Thane", "goblin"])]
  |> Enum.reduce(World.new(), fn ch, w -> {:ok, nw} = ch.(w); nw end)

{:ok, game} =
  Session.start_link(
    shared_state: world,
    policy: {Dragones.TurnPolicy.WorldDriven, dm: "dm"},
    participants: [Participant.new(id: "dm", kind: :agent), Participant.new(id: "Thane", kind: :human)],
    session_id: "adv-#{:erlang.unique_integer([:positive])}"
  )

{:ok, _} = Session.start(game)
# begin_combat(["Thane","goblin"]) -> first actor is Thane (pc).

{:ok, roll_log} = Agent.start_link(fn -> [] end)
roller = fn sides -> v = :rand.uniform(sides); Agent.update(roll_log, fn l -> l ++ [{sides, v}] end); v end

prompt =
  Brief.turn_prompt(
    Session.read_state(game),
    "Thane",
    "Thane declares: \"The goblin is prone on the ground — I bring my longsword down on it.\". " <>
      "The goblin is prone, so Thane has advantage on this melee attack. Resolve it with make_attack (mode advantage) and narrate.",
    "dm"
  )

{:ok, %{output: text}} =
  Server.chat(dm, prompt, deps: %{state: SharedState.new(game, "Thane"), roller: roller})

IO.puts("\n=== DM ===")
IO.puts(text)

d20s = Agent.get(roll_log, & &1) |> Enum.filter(fn {s, _} -> s == 20 end) |> Enum.map(&elem(&1, 1))
IO.puts("\n=== d20s rolled: #{inspect(d20s)} (#{length(d20s)} -> #{if length(d20s) == 2, do: "advantage worked", else: "single roll"}) ===")
