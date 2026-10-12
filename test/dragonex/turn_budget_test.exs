defmodule Dragonex.TurnBudgetTest do
  use ExUnit.Case, async: true
  alias Dragonex.{Actions, Character, World, Weapon, Codec, TurnBudget}

  defp world do
    a =
      Character.new(
        name: "A",
        class: "fighter",
        level: 5,
        hp: 10,
        max_hp: 40,
        weapons: [
          %Weapon{name: "sword", dice: "1d8", damage_type: "slashing", attack_ability: :str}
        ]
      )

    b = Character.new(name: "B", hp: 100, max_hp: 100, side: "enemy")
    w = World.new(characters: %{"A" => a, "B" => b})
    {:ok, w} = World.begin_combat(["A", "B"]).(w)
    {:ok, w} = World.set_current_combatant("A").(w)
    w
  end

  defp attack(w) do
    {:ok, _, change} = Actions.attack(w, "A", "B", "sword", fn _ -> 1 end)
    {:ok, w} = change.(w)
    w
  end

  test "Extra Attack is one action, cannot be repeated or refreshed by repeated handoff" do
    w = attack(world()) |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    {:ok, w} = World.set_current_combatant("A").(w)
    assert {:error, _} = Actions.attack(w, "A", "B", "sword", fn _ -> flunk("must not roll") end)
    {:ok, w} = World.next_round().(w)
    {:ok, w} = World.set_current_combatant("A").(w)
    assert {:ok, _, _} = Actions.attack(w, "A", "B", "sword", fn _ -> 1 end)
  end

  test "bonus action is separate, surge grants an extra Attack without refunding the first" do
    w = attack(world())
    {:ok, _, bonus} = Actions.second_wind(w, "A", fn _ -> 1 end)
    {:ok, w} = bonus.(w)
    {:ok, _, surge} = Actions.action_surge(w, "A", "B", "sword", fn _ -> 1 end)
    {:ok, w} = surge.(w)

    assert {:error, _} =
             Actions.attack(w, "A", "B", "sword", fn _ -> flunk("no third action") end)

    assert {:error, _} =
             Actions.action_surge(w, "A", "B", "sword", fn _ -> flunk("spent surge") end)
  end

  test "out of turn main actions are rejected" do
    {:ok, w} = World.set_current_combatant("B").(world())
    assert {:error, _} = Actions.second_wind(w, "A", fn _ -> flunk("out of turn") end)
  end

  test "an off-turn rejection names the current combatant and delegates the handoff" do
    {:ok, w} = World.set_current_combatant("B").(world())
    assert {:error, message} = Dragonex.TurnBudget.check(w, "A", :action)
    assert message =~ "A no está en su turno"
    assert message =~ "combatiente actual es B"
    assert message =~ "TurnMaster"
    assert message =~ "sin ejecutar acciones de otros combatientes"
    assert w.current_combatant == "B"
    assert w.turn_state["A"]["action"] != true
  end

  test "a prepared action cannot spend a budget that has since been consumed" do
    w = world()
    {:ok, _, pending} = Actions.attack(w, "A", "B", "sword", fn _ -> 1 end)
    spent = attack(w)
    assert {:error, _} = pending.(spent)
  end

  test "a reaction interruption grants no main action and refreshes only at the actual turn" do
    w = world()
    {:ok, w} = World.set_current_combatant("B", "reaction").(w)
    assert {:error, _} = Dragonex.TurnBudget.check(w, "B", :action)
    {:ok, w} = Dragonex.TurnBudget.spend(w, "B", :reaction)
    {:ok, w} = World.set_current_combatant("B", "reaction").(w)
    assert {:error, _} = Dragonex.TurnBudget.check(w, "B", :reaction)
    {:ok, w} = World.set_current_combatant("B").(w)
    assert :ok = Dragonex.TurnBudget.check(w, "B", :reaction)
    assert :ok = Dragonex.TurnBudget.check(w, "B", :action)
  end

  test "reaction spell does not incorrectly forbid a bonus spell on a later actor's turn" do
    w = world()
    {:ok, w} = Dragonex.TurnBudget.spend(w, "B", {:spell, :reaction, 1})
    {:ok, w} = World.set_current_combatant("B").(w)
    assert :ok = Dragonex.TurnBudget.check(w, "B", {:spell, :bonus, 1})
  end

  test "bonus spell rule is enforced in both orders, while an action cantrip is allowed" do
    for first <- [{:spell, :bonus, 1}, {:spell, :action, 1}] do
      {:ok, w} = Dragonex.TurnBudget.spend(world(), "A", first)
      other = if first == {:spell, :bonus, 1}, do: {:spell, :action, 1}, else: {:spell, :bonus, 1}
      assert {:error, _} = Dragonex.TurnBudget.check(w, "A", other)
    end

    {:ok, w} = Dragonex.TurnBudget.spend(world(), "A", {:spell, :bonus, 1})
    assert :ok = Dragonex.TurnBudget.check(w, "A", {:spell, :action, 0})
  end

  test "Flurry requires Attack and shares the bonus action budget" do
    assert {:error, _} = Dragonex.TurnBudget.check(world(), "A", :flurry)
    {:ok, w} = Dragonex.TurnBudget.spend(world(), "A", :attack)
    assert :ok = Dragonex.TurnBudget.check(w, "A", :flurry)
    {:ok, w} = Dragonex.TurnBudget.spend(w, "A", :bonus)
    assert {:error, _} = Dragonex.TurnBudget.check(w, "A", :flurry)
  end

  test "invalid attacks leave the main action available" do
    w = world()
    assert {:error, _} = Actions.attack(w, "A", "missing", "sword", fn _ -> flunk("invalid") end)
    assert {:error, _} = Actions.attack(w, "A", "B", "missing", fn _ -> flunk("invalid") end)
    assert {:ok, _, _} = Actions.attack(w, "A", "B", "sword", fn _ -> 1 end)
  end

  test "prepared actions cannot be carried into a later turn" do
    w = world()
    {:ok, _, change} = Actions.attack(w, "A", "B", "sword", fn _ -> 1 end)
    {:ok, later} = World.next_round().(w)
    {:ok, later} = World.set_current_combatant("A").(later)
    assert {:error, _} = change.(later)
  end

  test "bonus spell restriction ends with the turn, but reaction remains spent until own turn" do
    {:ok, w} = Dragonex.TurnBudget.spend(world(), "A", {:spell, :bonus, 1})
    assert {:error, _} = Dragonex.TurnBudget.check(w, "A", {:spell, :reaction, 1})
    {:ok, w} = World.set_current_combatant("B").(w)
    assert :ok = Dragonex.TurnBudget.check(w, "A", {:spell, :reaction, 1})
    {:ok, w} = Dragonex.TurnBudget.spend(w, "A", {:spell, :reaction, 1})
    {:ok, w} = World.next_round().(w)
    assert {:error, _} = Dragonex.TurnBudget.check(w, "A", :reaction)
    {:ok, w} = World.set_current_combatant("A").(w)
    assert :ok = Dragonex.TurnBudget.check(w, "A", :reaction)
  end

  test "spell costs come from SRD metadata" do
    for {name, kind} <- [
          {"healing word", :bonus},
          {"shield", :reaction},
          {"cure wounds", :action},
          {"prayer of healing", :long}
        ] do
      assert {:spell, ^kind, 1} =
               Dragonex.TurnBudget.spell_cost(%Dragonex.Spell{name: name, level: 1})
    end
  end

  test "the implicit first combatant still obeys the bonus spell restriction" do
    w = %{world() | current_combatant: nil, turn_owner: nil, turn_state: %{}}
    {:ok, w} = Dragonex.TurnBudget.spend(w, "A", {:spell, :bonus, 1})
    assert {:error, _} = Dragonex.TurnBudget.check(w, "A", {:spell, :action, 1})
  end

  test "ending a turn forfeits unspent actions even if the actor is selected again" do
    w = world()
    {:ok, w} = World.set_current_combatant("B").(w)
    {:ok, w} = World.set_current_combatant("A").(w)
    assert {:error, _} = Actions.attack(w, "A", "B", "sword", fn _ -> flunk("ended turn") end)
  end

  test "only one death save per personal turn; natural 20 still permits an action" do
    w = world()
    w = %{w | characters: Map.update!(w.characters, "A", &%{&1 | hp: 0})}
    {:ok, _, save} = Actions.death_save(w, "A", fn _ -> 10 end)
    {:ok, after_save} = save.(w)

    assert {:error, _} =
             Actions.death_save(after_save, "A", fn _ -> flunk("second death save") end)

    {:ok, _, revive} = Actions.death_save(w, "A", fn _ -> 20 end)
    {:ok, revived} = revive.(w)
    assert revived.characters["A"].hp == 1
    assert {:ok, _, _} = Actions.attack(revived, "A", "B", "sword", fn _ -> 1 end)
  end

  test "rage ends on an inactive turn, but attacks against enemies maintain it" do
    for attack? <- [false, true] do
      w = world()
      a = %{w.characters["A"] | class: "barbarian"}
      w = %{w | characters: Map.put(w.characters, "A", a)}
      {:ok, w} = World.start_rage("A").(w)
      w = if attack?, do: attack(w), else: w
      {:ok, w} = World.set_current_combatant("B").(w)
      assert w.characters["A"].raging == attack?
    end
  end

  test "damage since the previous turn can maintain rage on the next inactive turn" do
    w = world()
    a = %{w.characters["A"] | class: "barbarian"}
    w = %{w | characters: Map.put(w.characters, "A", a)}
    {:ok, w} = World.start_rage("A").(w)
    w = attack(w)
    {:ok, w} = World.set_current_combatant("B").(w)
    {:ok, w} = World.apply_damage("A", 1, "fire").(w)
    {:ok, w} = World.next_round().(w)
    {:ok, w} = World.set_current_combatant("A").(w)
    {:ok, w} = World.set_current_combatant("B").(w)
    assert w.characters["A"].raging
    {:ok, w} = World.next_round().(w)
    {:ok, w} = World.set_current_combatant("A").(w)
    {:ok, w} = World.set_current_combatant("B").(w)
    refute w.characters["A"].raging
  end

  test "remaining reads what the table should show for this round" do
    w = world()
    assert TurnBudget.remaining(w, "A") == %{action: true, bonus: true, reaction: true}

    w = attack(w)
    assert TurnBudget.remaining(w, "A") == %{action: false, bonus: true, reaction: true}

    {:ok, w} = TurnBudget.spend(w, "A", :reaction)
    {:ok, w} = World.set_current_combatant("B").(w)
    # A's turn is over: nothing left until their next one, reaction included.
    assert TurnBudget.remaining(w, "A") == %{action: false, bonus: false, reaction: false}

    {:ok, w} = World.next_round().(w)
    assert TurnBudget.remaining(w, "A") == %{action: true, bonus: true, reaction: false}
    {:ok, w} = World.set_current_combatant("A").(w)
    assert TurnBudget.remaining(w, "A") == %{action: true, bonus: true, reaction: true}

    assert TurnBudget.remaining(%{w | phase: :exploration}, "A") == nil
  end
end
