defmodule Dragonex.DirectEffectAuthorityTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Character, Tools, World}
  alias Dragonex.Heroes.Spells
  alias ExAgent.Session
  alias ExAgent.Session.SharedState

  defp context do
    mara = %{Archetypes.fighter(name: "Mara") | hp: 5, conditions: ["poisoned"]}
    world = World.new(characters: %{"Mara" => mara, "Lyra" => Archetypes.wizard()})

    session =
      start_session(
        world: world,
        policy: :round_robin,
        participants: [p("dm"), p("Mara"), p("Lyra")]
      )

    assert {:ok, "dm"} = Session.start(session)
    {session, world}
  end

  defp ctx(session, actor, roller),
    do: %{deps: %{state: SharedState.new(session, actor), roller: roller}}

  defp effect(ctx, "heal", target), do: Tools.heal(ctx, target, "1d8")
  defp effect(ctx, "grant_temp_hp", target), do: Tools.grant_temp_hp(ctx, target, 30)
  defp effect(ctx, "apply_condition", target), do: Tools.apply_condition(ctx, target, "stunned")

  defp effect(ctx, "remove_condition", target),
    do: Tools.remove_condition(ctx, target, "poisoned")

  defp effect(ctx, "level_up", target), do: Tools.level_up(ctx, target, %{})

  for tool <- ~w(heal grant_temp_hp apply_condition remove_condition level_up) do
    test "#{tool} cannot bypass a PC's rules or affect a companion" do
      {session, before} = context()

      for actor <- ["Mara", "Lyra"] do
        assert {:ok, ^actor} = Session.handoff(session, actor)
        ctx = ctx(session, actor, fn _ -> flunk("Unauthorized RNG") end)

        for target <- ["Mara", "Lyra"] do
          assert {:error, "RECHAZADO — solo el DM" <> _} = effect(ctx, unquote(tool), target)
          assert Session.read_state(session) == before
        end
      end
    end
  end

  test "role rejection happens before shared state, target inspection or dice" do
    for actor <- [nil, "DM", "Mara"] do
      ctx = ctx(self(), actor, fn _ -> flunk("Unauthorized RNG") end)

      for tool <- ~w(heal grant_temp_hp apply_condition remove_condition level_up),
          do: assert({:error, "RECHAZADO — solo el DM" <> _} = effect(ctx, tool, "Mara"))
    end
  end

  test "the DM still applies native healing, temporary HP and conditions without changing progression" do
    {session, before} = context()
    ctx = ctx(session, "dm", fn 8 -> 4 end)
    assert {:ok, _} = Tools.heal(ctx, "Mara", "1d8")
    assert Session.read_state(session).characters["Mara"].hp == 9
    assert {:ok, _} = Tools.grant_temp_hp(ctx, "Mara", 10)
    assert {:ok, _} = Tools.grant_temp_hp(ctx, "Mara", 3)
    assert {:ok, _} = Tools.apply_condition(ctx, "Mara", "prone")
    assert {:ok, _} = Tools.remove_condition(ctx, "Mara", "poisoned")
    next = Session.read_state(session)
    assert next.characters["Mara"].temp_hp == 10
    assert Character.condition_names(next.characters["Mara"]) == ["prone"]
    assert next.characters["Lyra"] == before.characters["Lyra"]
    assert next.characters["Mara"].level == before.characters["Mara"].level
    assert next.elapsed_seconds == before.elapsed_seconds
  end

  test "a PC's Second Wind still heals with its real bonus action and finite use" do
    {session, before} = context()
    assert {:ok, combat} = World.begin_combat(["Mara", "Lyra"]).(before)

    assert {:ok, _} =
             SharedState.propose_change(SharedState.new(session, "dm"), fn _ -> {:ok, combat} end)

    assert {:ok, "Mara"} = Session.handoff(session, "Mara")
    ctx = ctx(session, "Mara", fn 10 -> 4 end)
    assert {:ok, _} = Tools.second_wind(ctx, "Mara")
    paid = Session.read_state(session)
    assert paid.characters["Mara"].hp == 10
    assert paid.characters["Mara"].second_wind_used
    assert paid.turn_state["Mara"]["bonus"]
    assert paid.characters["Lyra"] == before.characters["Lyra"]
    assert {:error, _} = Tools.second_wind(ctx, "Mara")
    assert Session.read_state(session) == paid
  end

  test "a PC's False Life still grants timed temporary HP for a paid spell slot" do
    {session, before} = context()

    mage = %{
      before.characters["Lyra"]
      | spells: [Spells.to_character_spell(Spells.get("false life"), :int)]
    }

    world = %{
      before
      | characters: Map.put(before.characters, "Lyra", mage),
        spell_slots: %{"Lyra" => %{1 => 1}}
    }

    assert {:ok, _} =
             SharedState.propose_change(SharedState.new(session, "dm"), fn _ -> {:ok, world} end)

    assert {:ok, "Lyra"} = Session.handoff(session, "Lyra")
    ctx = ctx(session, "Lyra", fn 4 -> 4 end)
    assert {:ok, _} = Tools.cast_spell(ctx, "Lyra", "false life", "Lyra", nil)
    paid = Session.read_state(session)
    assert paid.characters["Lyra"].temp_hp == 8
    assert paid.spell_slots["Lyra"][1] == 0
    assert paid.effect_expiries["Lyra"]["temp_hp"] == 3600
    assert paid.characters["Mara"] == before.characters["Mara"]
    assert {:error, _} = Tools.cast_spell(ctx, "Lyra", "false life", "Lyra", nil)
    assert Session.read_state(session) == paid
  end
end
