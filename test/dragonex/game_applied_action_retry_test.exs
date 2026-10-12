defmodule Dragonex.GameAppliedActionRetryTest.Model do
  @behaviour ExAgent.Model
  alias ExAgent.{Message, RequestError}
  alias ExAgent.Message.Part

  defstruct [
    :counter,
    :observer,
    :first_args,
    :repeat_args,
    :repeat_calls,
    fault: :transient,
    calls: 1
  ]

  @args %{"caster" => "Mara", "spell" => "magic missile", "target" => "Goblin"}

  @impl true
  def request(model, messages, _settings, _params) do
    step = Agent.get_and_update(model.counter, &{&1 + 1, &1 + 1})
    fault_step = model.calls + 1
    repeats = if model.fault == :mixed, do: 3, else: model.repeat_calls || model.calls

    cond do
      step == fault_step and model.fault in [:length, :mixed] ->
        {:ok,
         Message.new_response([%Part.Text{content: "La frase queda a medias"}],
           finish_reason: :length
         ), model}

      step == fault_step or (model.fault == :mixed and step == 4) ->
        {:error,
         %RequestError{
           provider: :openrouter,
           status: 503,
           reason: :http_error,
           body: "overloaded"
         }}

      step <= model.calls or step in (fault_step + 1)..(fault_step + repeats) ->
        args =
          if step <= model.calls, do: model.first_args || @args, else: model.repeat_args || @args

        calls = [
          %Part.ToolCall{
            tool_name: "cast_spell",
            tool_call_id: "request-#{step}",
            args: args
          }
        ]

        {:ok, Message.new_response(calls), model}

      true ->
        if step == fault_step + repeats + 1 and is_pid(model.observer),
          do: send(model.observer, {:retry_context, messages})

        {:ok, Dragonex.Test.Harness.narration_response("Mara, ¿qué quieres observar?"), model}
    end
  end

  @impl true
  def request_stream(model, messages, settings, params) do
    case request(model, messages, settings, params) do
      {:ok, response, updated} -> [Dragonex.Test.Harness.stream_response(response, updated)]
      {:error, reason} -> [{:error, reason}]
    end
  end

  @impl true
  def model_name(_), do: "applied-action-retry"
  @impl true
  def system(_), do: "test"
  @impl true
  def profile(_), do: %ExAgent.ModelProfile{supports_tools: true}
end

defmodule Dragonex.GameAppliedActionRetryTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Dragonex.{Character, Game, Games}
  alias Dragonex.Heroes.Spells
  alias Dragonex.GameAppliedActionRetryTest.Model
  alias ExAgent.{Models.Test, Server}
  import Dragonex.Test.Harness

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    prior = Application.get_env(:dragonex, :transient_backoffs)
    Application.put_env(:dragonex, :transient_backoffs, [10, 10, 10])

    on_exit(fn ->
      if is_nil(prior),
        do: Application.delete_env(:dragonex, :transient_backoffs),
        else: Application.put_env(:dragonex, :transient_backoffs, prior)
    end)

    :ok
  end

  test "a transient narration retry does not cast an acknowledged exploration spell twice" do
    {game, pid, before, world} = resolve_retry()
    assert world.spell_slots["Mara"][1] == before.spell_slots["Mara"][1] - 1
    assert world.characters["Goblin"].hp == 14
    assert Games.load_world(Games.get_game(game.id)) == world
    assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 1
    assert Game.status(pid) == :paused
    assert_receive {:retry_context, messages}
    assert inspect(messages, limit: :infinity) =~ "Resultado ya aplicado antes del fallo"
  end

  test "a max-token retry retains resolved tools while raw partial narration stays private" do
    {game, _, before, world} = resolve_retry(fault: :length)
    assert world.spell_slots["Mara"][1] == before.spell_slots["Mara"][1] - 1
    assert world.characters["Goblin"].hp == 14

    refute Enum.any?(
             Games.list_events(game.id),
             &(&1.payload["text"] == "La frase queda a medias")
           )

    assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 1
  end

  test "explicit null optional spell arguments and new call IDs replay the same resolved action" do
    {_, _, before, world} =
      resolve_retry(
        repeat_args: %{
          "caster" => "Mara",
          "spell" => "magic missile",
          "target" => "Goblin",
          "cast_level" => nil,
          "additional_targets" => nil,
          "condition_to_remove" => nil
        }
      )

    assert world.spell_slots["Mara"][1] == before.spell_slots["Mara"][1] - 1
    assert world.characters["Goblin"].hp == 14
  end

  test "two legitimate initial casts remain two, even when both calls are retried" do
    {game, _, before, world} = resolve_retry(calls: 2)
    assert world.spell_slots["Mara"][1] == before.spell_slots["Mara"][1] - 2
    assert world.characters["Goblin"].hp == 8
    assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 2
  end

  test "equivalent spell names, base levels and empty optional arguments reuse the same result" do
    {game, _, before, world} =
      resolve_retry(
        repeat_args: %{
          "caster" => "Mara",
          "spell" => " Magic_Missile ",
          "target" => "Goblin",
          "cast_level" => "1",
          "additional_targets" => [],
          "condition_to_remove" => " "
        }
      )

    assert world.spell_slots["Mara"][1] == before.spell_slots["Mara"][1] - 1
    assert world.characters["Goblin"].hp == 14
    assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 1
  end

  test "a rejected call is not cached and a corrected retry still resolves" do
    {game, _, before, world} =
      resolve_retry(
        first_args: %{"caster" => "Mara", "spell" => "magic missile", "target" => "Absent"}
      )

    assert world.spell_slots["Mara"][1] == before.spell_slots["Mara"][1] - 1
    assert world.characters["Goblin"].hp == 14
    assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 1
  end

  test "extra copies of a resolved call in a retry do not spend another slot" do
    {game, _, before, world} = resolve_retry(repeat_calls: 2)
    assert world.spell_slots["Mara"][1] == before.spell_slots["Mara"][1] - 1
    assert world.characters["Goblin"].hp == 14
    assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 1
  end

  test "resolved tools survive a max-token retry followed by a transient retry" do
    {game, _, before, world} = resolve_retry(fault: :mixed)
    assert world.spell_slots["Mara"][1] == before.spell_slots["Mara"][1] - 1
    assert world.characters["Goblin"].hp == 14
    assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 1
  end

  test "a newly declared beat can cast the same spell again" do
    {game, pid, _, first} = resolve_retry()
    state = :sys.get_state(pid)

    assert :ok ==
             Server.set_model(state.dm, %Test{
               script: [
                 tool_calls([
                   call("cast_spell", %{
                     "caster" => "Mara",
                     "spell" => "magic missile",
                     "target" => "Goblin"
                   })
                 ]),
                 narration("Invoco los proyectiles."),
                 narration("Mara, ¿qué quieres observar?")
               ]
             })

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
    assert {:ok, :resolving} == Game.declare(pid, "Mara", "Vuelvo a lanzar un proyectil mágico.")
    assert :ok == Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
    assert :ok == Game.pause(pid)
    world = Game.world(pid)
    assert world.spell_slots["Mara"][1] == first.spell_slots["Mara"][1] - 1
    assert world.characters["Goblin"].hp == 8
    assert Enum.count(Games.list_events(game.id), &(&1.type == :dice)) == 2
  end

  defp resolve_retry(opts \\ []) do
    caster =
      Character.new(
        name: "Mara",
        class: "wizard",
        side: "pc",
        hp: 8,
        max_hp: 8,
        int: 16,
        spells: [Spells.to_character_spell(Spells.get("magic missile"), :int)]
      )

    enemy = Character.new(name: "Goblin", side: "enemy", hp: 20, max_hp: 20)

    {:ok, game} =
      Games.create_game(
        title: "Una magia y un reintento",
        roster: [{caster, :human}, {enemy, :ai}]
      )

    world = Games.load_world(game)
    {:ok, _} = Games.save_state(game.id, world, "Mara", world.round, :paused)
    counter = start_supervised!({Agent, fn -> 0 end})

    pid =
      Dragonex.Test.GameFixture.start!(
        {Game,
         {game.id,
          [
            model: struct!(Model, Keyword.merge([counter: counter, observer: self()], opts)),
            roller: fn _ -> 1 end
          ]}}
      )

    assert :ok == Game.resume(pid)
    assert :ok == Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))

    assert {:ok, :resolving} ==
             Game.declare(
               pid,
               "Mara",
               if(Keyword.get(opts, :calls, 1) == 2,
                 do: "Lanzo el hechizo dos veces contra el goblin.",
                 else: "Lanzo un proyectil mágico contra el goblin."
               )
             )

    assert :ok == Game.await(pid, &(&1.current == "Mara" and &1.status == :waiting))
    assert :ok == Game.pause(pid)
    after_world = Game.world(pid)
    {game, pid, world, after_world}
  end
end
