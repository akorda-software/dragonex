defmodule Dragonex.GameAttackAliasReplayTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Character, Codec, Game, Games, Weapon}
  alias ExAgent.Models.Test

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    :ok
  end

  defp attack(weapon, mode \\ :omitted) do
    args = %{"attacker" => "Thane", "target" => "g1", "weapon" => weapon}
    args = if mode == :omitted, do: args, else: Map.put(args, "mode", mode)
    tool_calls([call("make_attack", args)])
  end

  defp truncated, do: ExAgent.Message.new_response([], finish_reason: :length)
  defp closure, do: narration("La declaración queda registrada.")
  defp world_answer, do: narration("Thane, ¿qué haces ahora?")
  defp shape, do: tool_calls([call("wild_shape", %{"who" => "Thane", "beast" => "wolf"})])

  defp feedback(owner) do
    fn messages, _params ->
      text = inspect(messages, limit: :infinity)

      send(
        owner,
        {:paid_feedback, String.contains?(text, "Resultado ya aplicado antes del fallo")}
      )

      closure()
    end
  end

  defp boot(script, opts \\ []) do
    hero = Keyword.get(opts, :hero, Archetypes.fighter())
    enemy = Character.new(name: "g1", side: "enemy", hp: 50, max_hp: 50, ac: 12)

    {:ok, game} =
      Games.create_game(
        title: "Un golpe pagado conserva su identidad",
        locale: Keyword.get(opts, :locale, "es"),
        roster: [{hero, :human}, {enemy, :ai}]
      )

    before = %{Games.load_world(game) | scene_refresh_pending: false}
    {:ok, _} = Games.save_state(game.id, before, "Thane", before.round, :paused)
    rolls = start_supervised!({Agent, fn -> [] end})

    roller = fn sides ->
      Agent.update(rolls, &(&1 ++ [sides]))
      if sides == 20, do: 15, else: 4
    end

    context = %{game: game, before: before, rolls: rolls, roller: roller}
    pid = start_game(context, script)
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)
    assert {:ok, :resolving} == Game.declare(pid, "Thane", "Ataco al enemigo con mi arma.")
    Map.put(context, :pid, pid)
  end

  defp start_game(context, script) do
    Dragonex.Test.GameFixture.start!(
      {Game,
       {context.game.id,
        [
          model: %Test{script: script},
          roller: context.roller,
          scene_model: %Test{
            script: [
              tool_calls([
                call("final_result", %{"scene" => "El enemigo sigue junto a la puerta."})
              ])
            ]
          },
          turnmaster_model: %Test{
            script: [tool_calls([call("give_turn_to", %{"participant" => "Thane"})]), "Listo."]
          }
        ]}}
    )
  end

  defp finish(context) do
    assert :ok ==
             Game.await(context.pid, &(&1.status == :waiting and &1.current == "Thane"), 5_000)

    assert :ok == Game.pause(context.pid)
    world = Game.world(context.pid)
    assert Games.load_world(Games.get_game(context.game.id)) == world
    assert world.actor_checkpoint == nil
    events = Games.list_events(context.game.id)
    assert Enum.count(events, &(&1.type == :action and &1.actor == "Thane")) == 1
    assert Enum.count(events, &(&1.type == :narration and &1.actor == "Thane")) == 1
    world
  end

  for {first_weapon, first_mode, next_weapon, next_mode} <- [
        {"longsword", :omitted, " LONG SWORD ", "normal"},
        {"longsword", "normal", "sword", nil},
        {"longsword", nil, "longsword", "normal"}
      ] do
    test "retry reuses #{inspect({first_weapon, first_mode})} as #{inspect({next_weapon, next_mode})}" do
      context =
        boot([
          attack(unquote(first_weapon), unquote(first_mode)),
          truncated(),
          attack(unquote(next_weapon), unquote(next_mode)),
          feedback(self()),
          world_answer()
        ])

      world = finish(context)
      assert world.characters["g1"].hp == 43
      assert Agent.get(context.rolls, & &1) == [20, 8]
      assert_receive {:paid_feedback, true}
    end
  end

  defp legacy_attack(weapon, opts \\ []) do
    initial = if opts[:transform], do: [attack("longsword"), shape()], else: [attack("longsword")]
    context = boot(initial ++ [fn _, _ -> raise "after paid attack" end], opts)
    assert :ok == Game.await(context.pid, &(&1.status == :paused), 5_000)
    saved = Game.world(context.pid)
    assert saved.characters["g1"].hp == 43
    turn = saved.actor_checkpoint["turn_id"]
    stop_supervised!({Game, context.game.id})

    legacy =
      update_in(saved.actor_checkpoint["tools"], fn entries ->
        Enum.map(entries, fn
          %{"name" => "make_attack"} = entry ->
            entry
            |> Map.delete("key_version")
            |> update_in(["args"], &Map.merge(&1, %{"mode" => "normal", "weapon" => weapon}))

          entry ->
            entry
        end)
      end)

    {:ok, _} = Games.save_state(context.game.id, legacy, "Thane", legacy.round, :paused)
    {context, turn}
  end

  for {legacy, requested} <- [{"longsword", "SWORD"}, {"long sword", "longsword"}] do
    test "restart reuses legacy #{legacy} with normal mode as #{requested}" do
      {context, turn} = legacy_attack(unquote(legacy))
      pid = start_game(context, [attack(unquote(requested)), feedback(self()), world_answer()])
      assert :ok == Game.resume(pid)
      context = %{context | pid: pid}
      world = finish(context)
      assert world.characters["g1"].hp == 43
      assert Agent.get(context.rolls, & &1) == [20, 8]
      assert_receive {:paid_feedback, true}

      assert Enum.count(
               Games.list_events(context.game.id),
               &(&1.type == :turn and &1.payload["turn_id"] == turn)
             ) == 1
    end
  end

  test "a fuzzy legacy alias requires its exact receipt argument before another hit can run" do
    {context, _turn} = legacy_attack("sword")
    owner = self()

    corrected = fn messages, _params ->
      text = inspect(messages, limit: :infinity)
      send(owner, {:legacy_feedback, text =~ "nombre de arma exacto del comprobante"})
      attack("sword")
    end

    pid = start_game(context, [attack("longsword"), corrected, feedback(self()), world_answer()])
    assert :ok == Game.resume(pid)
    world = finish(%{context | pid: pid})
    assert world.characters["g1"].hp == 43
    assert Agent.get(context.rolls, & &1) == [20, 8]
    assert_receive {:legacy_feedback, true}
    assert_receive {:paid_feedback, true}
  end

  test "a removed weapon does not make a fuzzy legacy alias authoritative" do
    {context, _turn} = legacy_attack("sword", hero: druid(), transform: true)
    owner = self()

    corrected = fn messages, _params ->
      text = inspect(messages, limit: :infinity)
      send(owner, {:removed_legacy_feedback, text =~ "nombre de arma exacto del comprobante"})
      attack("sword")
    end

    pid = start_game(context, [attack("longsword"), corrected, feedback(self()), world_answer()])
    assert :ok == Game.resume(pid)
    world = finish(%{context | pid: pid})
    assert world.characters["g1"].hp == 43
    assert world.characters["Thane"].wild_shape != nil
    assert world.characters["Thane"].wild_shape_uses == 1
    assert Agent.get(context.rolls, & &1) == [20, 8]
    assert_receive {:removed_legacy_feedback, true}
    assert_receive {:paid_feedback, true}
  end

  test "new checkpoint writes preserve legacy identity and version only new attack keys" do
    {context, _turn} = legacy_attack("sword")
    pid = start_game(context, [attack("javelin"), truncated(), truncated()])
    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.status == :paused), 5_000)
    saved = Game.world(pid)
    assert saved.characters["g1"].hp == 36
    roundtrip = saved |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    entries = roundtrip.actor_checkpoint["tools"] |> Map.new(&{&1["args"]["weapon"], &1})
    refute Map.has_key?(entries["sword"], "key_version")
    assert entries["javelin"]["key_version"] == 1
    legacy = Dragonex.Game.ToolReplay.restore(roundtrip, "Thane").legacy_attack_keys
    assert MapSet.member?(legacy, {"make_attack", entries["sword"]["args"]})
    refute MapSet.member?(legacy, {"make_attack", entries["javelin"]["args"]})
    stop_supervised!({Game, context.game.id})
    owner = self()

    corrected = fn messages, _params ->
      send(
        owner,
        {:legacy_still_guarded,
         inspect(messages, limit: :infinity) =~ "nombre de arma exacto del comprobante"}
      )

      attack("sword")
    end

    pid =
      start_game(context, [
        attack("longsword"),
        corrected,
        attack("JAVELIN", "normal"),
        feedback(self()),
        world_answer()
      ])

    assert :ok == Game.resume(pid)
    world = finish(%{context | pid: pid})
    assert world.characters["g1"].hp == 36
    assert Agent.get(context.rolls, & &1) == [20, 8, 20, 6]
    assert_receive {:legacy_still_guarded, true}
    assert_receive {:paid_feedback, true}
  end

  test "an English table explains the ambiguous legacy receipt before any new roll" do
    {context, _turn} = legacy_attack("sword", locale: "en")

    corrected = fn messages, _params ->
      text = inspect(messages, limit: :infinity)
      assert text =~ "use the exact weapon name from the receipt"
      refute text =~ "nombre de arma exacto del comprobante"
      attack("sword")
    end

    pid = start_game(context, [attack("longsword"), corrected, closure(), world_answer()])
    assert :ok == Game.resume(pid)
    world = finish(%{context | pid: pid})
    assert world.characters["g1"].hp == 43
    assert Agent.get(context.rolls, & &1) == [20, 8]
  end

  test "different modes remain separate attacks" do
    context =
      boot([
        attack("longsword", "advantage"),
        truncated(),
        attack("longsword", "normal"),
        feedback(self()),
        world_answer()
      ])

    world = finish(context)
    assert world.characters["g1"].hp == 36
    assert Agent.get(context.rolls, & &1) == [20, 20, 8, 20, 8]
    assert_receive {:paid_feedback, false}
  end

  test "different weapons remain separate attacks" do
    context =
      boot([
        attack("longsword"),
        truncated(),
        attack("javelin", "normal"),
        feedback(self()),
        world_answer()
      ])

    world = finish(context)
    assert world.characters["g1"].hp == 36
    assert Agent.get(context.rolls, & &1) == [20, 8, 20, 6]
    assert_receive {:paid_feedback, false}
  end

  defp druid(weapons \\ Archetypes.fighter().weapons),
    do: %{Archetypes.fighter() | class: "druid", level: 2, wild_shape_uses: 2, weapons: weapons}

  test "a weapon removed by Wild Shape still replays its unambiguous paid alias" do
    context =
      boot(
        [
          attack("longsword"),
          shape(),
          truncated(),
          attack("sword"),
          feedback(self()),
          world_answer()
        ],
        hero: druid()
      )

    world = finish(context)
    assert world.characters["g1"].hp == 43
    assert world.characters["Thane"].wild_shape != nil
    assert world.characters["Thane"].wild_shape_uses == 1
    assert Agent.get(context.rolls, & &1) == [20, 8]
    assert_receive {:paid_feedback, true}
  end

  for requested <- ["bite", "wolfbite"] do
    test "the current weapon selected by #{requested} wins over its historical identity" do
      weapon = %Weapon{
        name: "wolfbite",
        dice: "1d8",
        damage_type: "piercing",
        attack_ability: :str
      }

      context =
        boot(
          [
            attack("wolfbite"),
            shape(),
            truncated(),
            attack(unquote(requested)),
            feedback(self()),
            world_answer()
          ],
          hero: druid([weapon])
        )

      world = finish(context)
      assert world.characters["g1"].hp == 34
      assert world.characters["Thane"].wild_shape_uses == 1
      assert Agent.get(context.rolls, & &1) == [20, 8, 20, 4, 4]
      assert_receive {:paid_feedback, false}
    end
  end

  test "an ambiguous alias cannot choose between two paid weapons that are no longer equipped" do
    short = %Weapon{
      name: "shortsword",
      dice: "1d6",
      damage_type: "piercing",
      attack_ability: :str
    }

    long = hd(Archetypes.fighter().weapons)

    context =
      boot(
        [
          attack("longsword"),
          attack("shortsword"),
          shape(),
          truncated(),
          attack("sword"),
          feedback(self()),
          world_answer()
        ],
        hero: druid([long, short])
      )

    world = finish(context)
    assert world.characters["g1"].hp == 36
    assert Agent.get(context.rolls, & &1) == [20, 8, 20, 6]
    assert_receive {:paid_feedback, false}
  end
end
