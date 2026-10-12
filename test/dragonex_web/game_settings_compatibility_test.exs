defmodule DragonexWeb.GameSettingsCompatibilityTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  alias Dragonex.{Accounts, Archetypes, Game, Games, ModelConfig, Models}

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "settings-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Jugador"
      })

    {:ok, game} =
      Games.create_game(
        title: "Ajustes",
        user_id: user.id,
        roster: [{Archetypes.fighter(), :human}]
      )

    {:ok, game} = Games.save_state(game.id, Games.load_world(game), "Thane", 1, :paused, %{})
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    old_config = ModelConfig.get()
    env_names = ["OPENROUTER_API_KEY", "DRAGONEX_SUMMARIZER_MODEL", "DRAGONEX_TURNMASTER_MODEL"]
    old_env = Map.new(env_names, &{&1, System.get_env(&1)})
    key = {Models, :catalogue, "https://openrouter.ai/api/v1"}
    old_catalogue = :persistent_term.get(key, :missing)

    on_exit(fn ->
      ModelConfig.set(Map.from_struct(old_config) |> Map.to_list())

      Enum.each(old_env, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)

      if old_catalogue == :missing,
        do: :persistent_term.erase(key),
        else: :persistent_term.put(key, old_catalogue)
    end)

    %{view: view, game: game, cache_key: key}
  end

  test "a missing provider key keeps the current process, world and configuration", %{
    view: view,
    game: game
  } do
    pid = Dragonex.Game.Supervisor.whereis(game.id)
    before = Game.world(pid)
    config = ModelConfig.get()
    open_settings(view)
    view |> form("#settings-custom-model", value: "xiaomi/mimo-v2.6-flash") |> render_change()
    html = render_click(view, "settings_apply")
    assert html =~ "no tiene una clave configurada"
    assert has_element?(view, ".settings-modal")
    assert Dragonex.Game.Supervisor.whereis(game.id) == pid
    assert ModelConfig.get() == config
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
  end

  if Code.ensure_loaded?(ExAgent.Models.ReqLLM) do
    test "enabled-only reasoning is rejected before restart without losing the live table", ctx do
      %{view: view, game: game, cache_key: key} = ctx
      open_settings(view)
      System.put_env("OPENROUTER_API_KEY", "synthetic")

      metadata = %{
        "supported_parameters" => ["tools", "reasoning"],
        "reasoning" => %{"mandatory" => false}
      }

      :persistent_term.put(
        key,
        {System.monotonic_time(:millisecond),
         [%{id: "xiaomi/mimo-v2.6-flash", metadata: metadata}]}
      )

      pid = Dragonex.Game.Supervisor.whereis(game.id)
      before = Game.world(pid)
      events = Games.list_events(game.id)
      config = ModelConfig.get()
      view |> form("#settings-custom-model", value: "xiaomi/mimo-v2.6-flash") |> render_change()
      html = render_click(view, "settings_apply")
      assert html =~ "No se pudo confirmar un perfil compatible"
      assert has_element?(view, ".settings-modal")
      assert has_element?(view, ".settings-msg", "razonamiento desactivado")
      refute has_element?(view, ".settings-rbtn")
      assert Process.alive?(view.pid)
      assert Dragonex.Game.Supervisor.whereis(game.id) == pid
      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      assert Games.list_events(game.id) == events
      assert ModelConfig.get() == config
    end

    test "a confirmed profile restarts a paused table with the exact saved world", %{
      view: view,
      game: game,
      cache_key: key
    } do
      open_settings(view)
      System.put_env("OPENROUTER_API_KEY", "synthetic")
      System.put_env("DRAGONEX_SUMMARIZER_MODEL", "deepseek/deepseek-v4.1-flash")
      System.put_env("DRAGONEX_TURNMASTER_MODEL", "deepseek/deepseek-v4.1-flash")

      metadata = %{
        "supported_parameters" => ["tools", "reasoning_effort"],
        "reasoning" => %{"mandatory" => false}
      }

      :persistent_term.put(
        key,
        {System.monotonic_time(:millisecond),
         [%{id: "deepseek/deepseek-v4.1-flash", metadata: metadata}]}
      )

      old = Dragonex.Game.Supervisor.whereis(game.id)
      before = Game.world(old)
      events = Games.list_events(game.id)

      view
      |> form("#settings-custom-model", value: "deepseek/deepseek-v4.1-flash")
      |> render_change()

      render_click(view, "settings_apply")
      refute has_element?(view, ".settings-modal")
      pid = Dragonex.Game.Supervisor.whereis(game.id)
      assert pid != old
      assert Game.world(pid) == before
      assert Games.load_world(Games.get_game(game.id)) == before
      assert Games.list_events(game.id) == events
      assert Game.snapshot(pid).status == :paused
      assert ModelConfig.get().model == "deepseek/deepseek-v4.1-flash"
    end
  end

  defp open_settings(view) do
    render_click(view, "open_settings")
    wait_for_key_notice(view, 100)
  end

  # Finish the no-key catalogue task before installing synthetic credentials;
  # otherwise a delayed task could read them and contact the real endpoint.
  defp wait_for_key_notice(view, attempts) do
    if has_element?(view, ".settings-msg", "sin API key") do
      :ok
    else
      assert attempts > 0
      Process.sleep(10)
      wait_for_key_notice(view, attempts - 1)
    end
  end
end
