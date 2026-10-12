defmodule DragonexWeb.GameSettingsCompatibilityTest do
  @moduledoc """
  Ajustes de IA (D242): who pays for the table and which model plays it.
  Every apply keeps world, turn and chronicle; a rejected choice keeps the
  live table and its saved AI untouched. Provider HTTP is stubbed through
  `config :dragonex, :ai_http` and the own-key probe through `:ai_probe`.
  """

  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log
  alias Dragonex.{Accounts, Archetypes, Game, Games}

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

    env_names = ["OPENROUTER_API_KEY", "DRAGONEX_SERVER_MODELS"]
    old_env = Map.new(env_names, &{&1, System.get_env(&1)})
    key = {Dragonex.Models, :catalogue, "https://openrouter.ai/api/v1"}
    old_catalogue = :persistent_term.get(key, :missing)
    test_pid = self()

    Application.put_env(:dragonex, :ai_http, plug: &stub_provider(&1, test_pid))

    on_exit(fn ->
      Application.delete_env(:dragonex, :ai_http)
      Application.delete_env(:dragonex, :ai_probe)

      Enum.each(old_env, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)

      if old_catalogue == :missing,
        do: :persistent_term.erase(key),
        else: :persistent_term.put(key, old_catalogue)
    end)

    %{conn: conn, user: user, game: game}
  end

  test "the house restarts a paused table with the exact saved world", ctx do
    %{conn: conn, game: game} = ctx
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    old = Game.Supervisor.whereis(game.id)
    before = Game.world(old)
    events = Games.list_events(game.id)

    render_click(view, "open_settings")
    assert has_element?(view, ".settings-pbtn.sel", "De la casa")
    render_click(view, "settings_apply")

    refute has_element?(view, ".settings-modal")
    pid = Game.Supervisor.whereis(game.id)
    assert pid != old
    assert Game.world(pid) == before
    assert Games.load_world(Games.get_game(game.id)) == before
    assert Games.list_events(game.id) == events
    assert Game.snapshot(pid).status == :paused
    assert Games.get_game(game.id).ai == %{"source" => "house"}
  end

  test "an own key lists its models, probes the choice and persists it", ctx do
    %{conn: conn, user: user, game: game} = ctx
    test_pid = self()
    :ok = Accounts.put_api_key(user, "openai", "sk-test-own-key-1234")

    Application.put_env(:dragonex, :ai_probe, fn model ->
      send(test_pid, {:probed, model})
      :ok
    end)

    {:ok, view, _} = live(conn, "/games/#{game.id}")
    old = Game.Supervisor.whereis(game.id)
    before = Game.world(old)

    render_click(view, "open_settings")
    render_click(view, "settings_select_source", %{"source" => "own:openai"})
    eventually(fn -> has_element?(view, "#settings-select-model option", "gpt-test") end)
    refute has_element?(view, "#settings-select-model option", "text-embedding-3-small")
    # Nothing is chosen yet, and the browser must show that rather than the first model.
    assert has_element?(view, "#settings-select-model option[value=''][selected]")
    assert_received {:provider_request, "/v1/models", "Bearer sk-test-own-key-1234"}

    view |> form("#settings-select-model", model: "gpt-test") |> render_change()
    render_click(view, "settings_apply")

    assert_receive {:probed, model}
    assert model.base_url == "https://api.openai.com/v1"
    assert model.tool_profile == :chat_tools_v1
    eventually(fn -> not has_element?(view, ".settings-modal") end)

    pid = Game.Supervisor.whereis(game.id)
    assert pid != old
    assert Game.world(pid) == before

    assert %{"source" => "own", "provider" => "openai", "model" => "gpt-test"} =
             Games.get_game(game.id).ai

    eventually(fn -> has_element?(view, ".ai-label", "OpenAI · gpt-test") end)
    refute render(view) =~ "sk-test-own-key-1234"
  end

  test "a failed probe keeps the live table and its saved AI", ctx do
    %{conn: conn, user: user, game: game} = ctx
    :ok = Accounts.put_api_key(user, "openai", "sk-test-own-key-1234")
    Application.put_env(:dragonex, :ai_probe, fn _model -> {:error, :boom} end)

    {:ok, view, _} = live(conn, "/games/#{game.id}")
    pid = Game.Supervisor.whereis(game.id)
    before = Game.world(pid)
    events = Games.list_events(game.id)

    render_click(view, "open_settings")
    render_click(view, "settings_select_source", %{"source" => "own:openai"})
    eventually(fn -> has_element?(view, "#settings-select-model option", "gpt-test") end)
    view |> form("#settings-select-model", model: "gpt-test") |> render_change()
    render_click(view, "settings_apply")

    eventually(fn -> has_element?(view, "[role=alert]", "no funciona con la mesa") end)
    assert has_element?(view, ".settings-modal")
    assert Game.Supervisor.whereis(game.id) == pid
    assert Game.world(pid) == before
    assert Games.list_events(game.id) == events
    assert Games.get_game(game.id).ai == %{}
  end

  test "a key removed meanwhile is reported instead of restarting", ctx do
    %{conn: conn, user: user, game: game} = ctx
    :ok = Accounts.put_api_key(user, "openai", "sk-test-own-key-1234")
    Application.put_env(:dragonex, :ai_probe, fn _model -> :ok end)

    {:ok, view, _} = live(conn, "/games/#{game.id}")
    pid = Game.Supervisor.whereis(game.id)

    render_click(view, "open_settings")
    render_click(view, "settings_select_source", %{"source" => "own:openai"})
    eventually(fn -> has_element?(view, "#settings-select-model option", "gpt-test") end)
    view |> form("#settings-select-model", model: "gpt-test") |> render_change()
    :ok = Accounts.delete_api_key(user, "openai")
    render_click(view, "settings_apply")

    eventually(fn -> has_element?(view, "[role=alert]", "Ya no tienes una clave") end)
    assert Game.Supervisor.whereis(game.id) == pid
    assert Games.get_game(game.id).ai == %{}
  end

  test "server keys with enabled-only reasoning are rejected before restart", ctx do
    %{conn: conn, game: game} = ctx
    # The table starts on the offline default; the key only feeds the modal.
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    System.put_env("OPENROUTER_API_KEY", "synthetic")
    pid = Game.Supervisor.whereis(game.id)
    before = Game.world(pid)

    render_click(view, "open_settings")
    assert has_element?(view, ".settings-pbtn", "Servidor: OpenRouter")
    render_click(view, "settings_select_source", %{"source" => "server:openrouter"})
    eventually(fn -> has_element?(view, "#settings-select-model option", "xiaomi/mimo") end)

    view |> form("#settings-select-model", model: "xiaomi/mimo") |> render_change()
    html = render_click(view, "settings_apply")

    assert html =~ "No se pudo confirmar un perfil compatible"
    assert has_element?(view, ".settings-modal")
    assert Game.Supervisor.whereis(game.id) == pid
    assert Game.world(pid) == before
    assert Games.get_game(game.id).ai == %{}
  end

  test "production offers only the house and own keys", ctx do
    %{conn: conn, game: game} = ctx
    System.put_env("OPENROUTER_API_KEY", "synthetic")
    System.put_env("DRAGONEX_SERVER_MODELS", "fixed")
    {:ok, view, _} = live(conn, "/games/#{game.id}")

    render_click(view, "open_settings")
    refute has_element?(view, ".settings-pbtn", "Servidor")
    assert has_element?(view, ".settings-msg", "deepseek/deepseek-v4.1-flash")
    assert has_element?(view, ".settings-hint a[href='/cuenta']")

    # A forged source is ignored: the selection stays on the house.
    render_click(view, "settings_select_source", %{"source" => "server:openrouter"})
    assert has_element?(view, ".settings-pbtn.sel", "De la casa")
  end

  # Fake provider APIs: an OpenAI listing and an OpenRouter catalogue with a
  # model whose reasoning can be enabled but not switched off by effort.
  defp stub_provider(conn, test_pid) do
    auth = conn |> Plug.Conn.get_req_header("authorization") |> List.first()
    send(test_pid, {:provider_request, conn.request_path, auth})

    case conn.request_path do
      "/v1/models" ->
        Req.Test.json(conn, %{
          "data" => [%{"id" => "gpt-test"}, %{"id" => "text-embedding-3-small"}]
        })

      "/api/v1/models" ->
        Req.Test.json(conn, %{
          "data" => [
            %{
              "id" => "xiaomi/mimo",
              "supported_parameters" => ["tools", "reasoning"],
              "reasoning" => %{"mandatory" => false}
            }
          ]
        })

      _ ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
    end
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
