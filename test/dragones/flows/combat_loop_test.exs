defmodule Dragones.Flows.CombatLoopTest do
  @moduledoc """
  The end-to-end combat loop against a real ExAgent.Session, driven by the
  WorldDriven policy and the bridge tools.

  Arc: exploration -> DM rolls initiative -> Thane attacks the goblin by the
  rules -> the goblin drops, combat is over -> DM ends combat -> exploration.

  The DM never computes math: it only invokes tools and reads their results.
  Initiative comes from the dice (stored in the World) and the policy enforces
  it — the DM cannot skip or reorder turns.
  """

  use ExUnit.Case, async: true

  import Dragones.Test.Harness

  alias Dragones.{Archetypes, Monsters, Tools, TurnPolicy.WorldDriven, World}
  alias ExAgent.{Models.Test, Server, Session}

  # A roller that pops from a shared queue — survives cross-process tool calls
  # (tools run inside the agent's Server, not the test process).
  defp seq_roller(values) do
    {:ok, agent} = Agent.start_link(fn -> values end)

    fn _sides ->
      Agent.get_and_update(agent, fn
        [h | t] -> {h, t}
        [] -> raise "seq_roller exhausted"
      end)
    end
  end

  defp agent(script, instructions),
    do:
      ExAgent.new(model: %Test{script: script}, instructions: instructions, tools: Tools.tools())

  defp seed(world, change) do
    assert {:ok, w} = change.(world)
    w
  end

  test "exploration -> initiative -> attack -> combat over -> exploration" do
    # dice, in order: initiative(Thane=15, goblin=10), attack(d20=12 hit, d8=4 -> +3 = 7).
    roller = seq_roller([15, 10, 12, 4])

    dm =
      ExUnit.Callbacks.start_supervised!(
        {Server,
         agent:
           agent(
             [
               tool_calls([call("roll_initiative", %{})]),
               text("Roll for initiative!"),
               tool_calls([call("end_combat", %{})]),
               text("The goblin falls. Combat ends.")
             ],
             "You are the DM."
           ),
         agent_id: "loop-dm"}
      )

    fighter =
      ExUnit.Callbacks.start_supervised!(
        {Server,
         agent:
           agent(
             [
               tool_calls([
                 call("make_attack", %{
                   "attacker" => "Thane",
                   "target" => "goblin",
                   "weapon" => "longsword"
                 })
               ]),
               text("I swing at the goblin!")
             ],
             "You are Thane, a fighter."
           ),
         agent_id: "loop-fighter"}
      )

    world =
      World.new()
      |> seed(World.add_character(Archetypes.fighter()))
      |> seed(World.add_character(Monsters.goblin()))

    {:ok, session} =
      Session.start_link(
        shared_state: world,
        policy: {WorldDriven, dm: "dm"},
        participants: [p("dm", :agent, dm), p("Thane", :agent, fighter)],
        session_id: "combat-loop-#{System.unique_integer([:positive])}"
      )

    # DM narrates first (exploration round-robin).
    assert {:ok, "dm"} = Session.start(session)

    # Turn 1 — DM rolls initiative. Thane (dex +1) beats the goblin (dex +2)?
    # roller 15 vs 10 -> 16 vs 12, so Thane first.
    assert :ok = take_turn(session, "dm", dm, roller)

    world = Session.read_state(session)
    assert world.phase == :combat
    assert world.initiative_order == ["Thane", "goblin"]
    assert Session.current(session) == "Thane"

    # Turn 2 — Thane attacks the goblin by the rules. d20 12 -> 17 vs AC 15 hit;
    # d8 4 + str 3 = 7 damage -> goblin drops to 0.
    assert :ok = take_turn(session, "Thane", fighter, roller)

    world = Session.read_state(session)
    assert world.characters["goblin"].hp == 0
    assert World.combat_over?(world)
    # Initiative advanced to the goblin's slot, which maps to the DM.
    assert Session.current(session) == "dm"

    # Turn 3 — DM ends combat (the engine already says it's over).
    assert :ok = take_turn(session, "dm", dm, roller)

    world = Session.read_state(session)
    assert world.phase == :exploration
  end

  test "wizard: magic missile (automatic) always hits and drops the goblin" do
    # dice: initiative(Lyra=10, goblin=10 — tie at 12, Lyra first by name), then 3d4 for MM.
    roller = seq_roller([10, 10, 2, 2, 2])

    dm =
      ExUnit.Callbacks.start_supervised!(
        {Server,
         agent:
           agent(
             [
               tool_calls([call("roll_initiative", %{})]),
               text("Roll for initiative!"),
               tool_calls([call("end_combat", %{})]),
               text("The goblin is no more.")
             ],
             "You are the DM."
           ),
         agent_id: "wiz-dm"}
      )

    wizard =
      ExUnit.Callbacks.start_supervised!(
        {Server,
         agent:
           agent(
             [
               tool_calls([
                 call("cast_spell", %{
                   "caster" => "Lyra",
                   "spell" => "magic missile",
                   "target" => "goblin"
                 })
               ]),
               text("I unleash three darts of force!")
             ],
             "You are Lyra, a wizard."
           ),
         agent_id: "wiz-lyra"}
      )

    world =
      World.new()
      |> seed(World.add_character(Archetypes.wizard()))
      |> seed(World.add_character(Monsters.goblin()))

    {:ok, session} =
      Session.start_link(
        shared_state: world,
        policy: {WorldDriven, dm: "dm"},
        participants: [p("dm", :agent, dm), p("Lyra", :agent, wizard)],
        session_id: "wizard-loop-#{System.unique_integer([:positive])}"
      )

    assert {:ok, "dm"} = Session.start(session)

    # DM rolls initiative. Tie -> Lyra first (name).
    assert :ok = take_turn(session, "dm", dm, roller)
    assert Session.read_state(session).initiative_order == ["Lyra", "goblin"]
    assert Session.current(session) == "Lyra"

    # Lyra casts magic missile: 3d4+3 (roller 2) = 9 -> goblin 7 -> 0.
    assert :ok = take_turn(session, "Lyra", wizard, roller)

    world = Session.read_state(session)
    assert world.characters["goblin"].hp == 0
    assert World.combat_over?(world)
  end

  test "wizard: firebolt (spell attack) misses on a low roll, no damage" do
    # dice: initiative(Lyra=10, goblin=10), then firebolt d20=4 -> 4+5=9 vs AC 15 miss.
    roller = seq_roller([10, 10, 4])

    dm =
      ExUnit.Callbacks.start_supervised!(
        {Server,
         agent:
           agent(
             [
               tool_calls([call("roll_initiative", %{})]),
               text("Roll for initiative!")
             ],
             "You are the DM."
           ),
         agent_id: "fb-dm"}
      )

    wizard =
      ExUnit.Callbacks.start_supervised!(
        {Server,
         agent:
           agent(
             [
               tool_calls([
                 call("cast_spell", %{
                   "caster" => "Lyra",
                   "spell" => "firebolt",
                   "target" => "goblin"
                 })
               ]),
               text("I hurl a bolt of fire!")
             ],
             "You are Lyra, a wizard."
           ),
         agent_id: "fb-lyra"}
      )

    world =
      World.new()
      |> seed(World.add_character(Archetypes.wizard()))
      |> seed(World.add_character(Monsters.goblin()))

    {:ok, session} =
      Session.start_link(
        shared_state: world,
        policy: {WorldDriven, dm: "dm"},
        participants: [p("dm", :agent, dm), p("Lyra", :agent, wizard)],
        session_id: "firebolt-#{System.unique_integer([:positive])}"
      )

    assert {:ok, "dm"} = Session.start(session)
    assert :ok = take_turn(session, "dm", dm, roller)
    assert :ok = take_turn(session, "Lyra", wizard, roller)

    # The goblin is untouched; combat continues.
    world = Session.read_state(session)
    assert world.characters["goblin"].hp == 7
    assert world.phase == :combat
  end

  test "the engine refuses a monster acting on the player's turn (control guard)" do
    # On Thane's turn, the agent scripts the GOBLIN attacking Thane — the guard
    # must reject it (Thane doesn't control the goblin), so Thane is unharmed.
    roller = seq_roller([20, 10])

    dm =
      ExUnit.Callbacks.start_supervised!(
        {Server, agent: agent([text("...")], "You are the DM."), agent_id: "guard-dm"}
      )

    fighter =
      ExUnit.Callbacks.start_supervised!(
        {Server,
         agent:
           agent(
             [
               tool_calls(
                 [call("make_attack", %{"attacker" => "goblin", "target" => "Thane", "weapon" => "scimitar"})]
               ),
               text("done")
             ],
             "You are Thane."
           ),
         agent_id: "guard-fighter"}
      )

    world =
      [
        World.add_character(Archetypes.fighter()),
        World.add_character(Monsters.goblin()),
        World.begin_combat(["Thane", "goblin"])
      ]
      |> Enum.reduce(World.new(), fn ch, w ->
        {:ok, nw} = ch.(w)
        nw
      end)

    {:ok, session} =
      Session.start_link(
        shared_state: world,
        policy: {Dragones.TurnPolicy.WorldDriven, dm: "dm"},
        participants: [p("dm", :agent, dm), p("Thane", :agent, fighter)],
        session_id: "guard-#{System.unique_integer([:positive])}"
      )

    # Initiative [Thane, goblin] -> Thane first.
    assert {:ok, "Thane"} = Session.start(session)
    assert :ok = take_turn(session, "Thane", fighter, roller)

    # The goblin's attack was refused; Thane is at full hp.
    assert Session.read_state(session).characters["Thane"].hp == 12
  end
end
