defmodule Dragonex.TurnmasterTokenBudgetTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness
  import ExUnit.CaptureLog

  alias Dragonex.{Archetypes, Game, Games, Monsters, TurnMaster, World}
  alias ExAgent.Models.Test

  defmodule BudgetModel do
    @behaviour ExAgent.Model
    defstruct [:observer, :inner, required_tokens: 259]

    @impl true
    def request(model, messages, settings, params) do
      send(model.observer, {:turnmaster_budget, settings.max_tokens})

      if settings.max_tokens < model.required_tokens do
        {:error, :max_tokens_exceeded}
      else
        case Test.request(model.inner, messages, settings, params) do
          {:ok, response, inner} -> {:ok, response, %{model | inner: inner}}
          {:error, _} = error -> error
        end
      end
    end

    @impl true
    def model_name(_), do: "budget-test"
    @impl true
    def system(_), do: "test"
    @impl true
    def profile(_), do: %ExAgent.ModelProfile{supports_tools: true}
  end

  setup do
    previous = System.get_env("DRAGONEX_TURNMASTER_MAX_TOKENS")
    System.delete_env("DRAGONEX_TURNMASTER_MAX_TOKENS")

    on_exit(fn ->
      if previous,
        do: System.put_env("DRAGONEX_TURNMASTER_MAX_TOKENS", previous),
        else: System.delete_env("DRAGONEX_TURNMASTER_MAX_TOKENS")
    end)

    :ok
  end

  for {label, override, budget} <- [{"default", nil, 1024}, {"configured", "4096", 4096}] do
    test "the #{label} budget reaches the Game's real TM request and avoids token fallback" do
      Dragonex.Test.Sandbox.start_shared!()
      put_budget(unquote(override))

      {:ok, game} =
        Games.create_game(
          title: "Un coordinador con margen",
          roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
          initiative: ["goblin", "Thane"]
        )

      {:ok, before} = World.set_current_combatant("goblin").(Games.load_world(game))
      {:ok, _} = Games.save_state(game.id, before, "dm", 1, :paused)

      tm = %BudgetModel{
        observer: self(),
        inner: %Test{
          script: [tool_calls([call("give_turn_to", %{"participant" => "Thane"})]), "listo"]
        }
      }

      log =
        capture_log(fn ->
          pid =
            Dragonex.Test.GameFixture.start!(
              {Game,
               {game.id,
                [
                  model: %Dragonex.Test.Narrator{text: "El goblin vigila la puerta."},
                  turnmaster_model: tm,
                  combat_handoffs: :turnmaster
                ]}}
            )

          assert :ok = Game.resume(pid)
          assert :ok = Game.await(pid, &(&1.current == "Thane" and &1.status == :waiting))
          assert :ok = Game.pause(pid)
          assert_receive {:turnmaster_budget, unquote(budget)}
          assert Game.world(pid).characters == before.characters
          assert Games.load_world(Games.get_game(game.id)) == Game.world(pid)

          assert Enum.any?(Games.list_events(game.id), fn event ->
                   event.type == :system and event.actor == "turnmaster" and
                     event.payload["note"] == "El turno pasa a Thane." and
                     event.payload["kind"] != "turnmaster_fallback"
                 end)
        end)

      refute log =~ "turnmaster beat failed"
      refute log =~ "max_tokens_exceeded"
    end
  end

  test "an explicit agent budget wins over the environment and reaches the provider" do
    System.put_env("DRAGONEX_TURNMASTER_MAX_TOKENS", "4096")
    model = %BudgetModel{observer: self(), inner: %Test{label: "listo"}, required_tokens: 0}
    agent = TurnMaster.new(model, max_tokens: 256)
    assert {:ok, _} = ExAgent.run(agent, "Decide el relevo.")
    assert_receive {:turnmaster_budget, 256}
  end

  test "blank, invalid and nonpositive environment budgets retain the usable default" do
    for value <- ["", "  ", "no-es-un-número", "0", "-1", "1024sobrantes"] do
      System.put_env("DRAGONEX_TURNMASTER_MAX_TOKENS", value)
      assert TurnMaster.new(%Test{}).settings.max_tokens == 1024
    end

    System.put_env("DRAGONEX_TURNMASTER_MAX_TOKENS", " 2048 ")
    assert TurnMaster.new(%Test{}).settings.max_tokens == 2048
  end

  defp put_budget(nil), do: :ok
  defp put_budget(value), do: System.put_env("DRAGONEX_TURNMASTER_MAX_TOKENS", value)
end
