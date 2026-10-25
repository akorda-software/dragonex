defmodule DragonexWeb.AccountLiveTest do
  @moduledoc """
  Tu cuenta (D242): a player's own AI keys are checked with the provider,
  saved sealed and only ever shown by their last characters.
  """

  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log

  alias Dragonex.Accounts

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "cuenta-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Cuentas"
      })

    Application.put_env(:dragonex, :ai_http, plug: &stub/1)
    on_exit(fn -> Application.delete_env(:dragonex, :ai_http) end)

    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    %{conn: conn, user: user}
  end

  test "lists every provider with a link to get a key", %{conn: conn} do
    {:ok, view, _} = live(conn, "/cuenta")

    for id <- Dragonex.AIProviders.ids(),
        do: assert(has_element?(view, "#key-form-#{id}"))

    assert has_element?(
             view,
             "#key-anthropic a[href='https://console.anthropic.com/settings/keys']"
           )
  end

  test "logging out is on the page too (phones hide it in the header)", %{conn: conn} do
    {:ok, view, _} = live(conn, "/cuenta")

    assert has_element?(
             view,
             "form.account-logout[action='/logout'] input[name=_method][value=delete]"
           )

    assert has_element?(view, "form.account-logout input[name=_csrf_token]")
  end

  test "a working key is saved and only its hint is shown", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, "/cuenta")

    view
    |> form("#key-form-openai", provider: "openai", key: "sk-good-key-abcd")
    |> render_submit()

    eventually(fn -> has_element?(view, "#key-openai .key-saved", "abcd") end)
    assert has_element?(view, "#key-openai [role=status]")
    refute render(view) =~ "sk-good-key-abcd"
    assert Accounts.api_key(user.id, "openai") == {:ok, "sk-good-key-abcd"}
  end

  test "a key the provider rejects is not saved", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, "/cuenta")

    view
    |> form("#key-form-openai", provider: "openai", key: "sk-bad-key-0000")
    |> render_submit()

    eventually(fn -> has_element?(view, "#key-error-openai", "no acepta esta clave") end)
    assert Accounts.list_api_keys(user) == []
  end

  test "a saved key can be removed", %{conn: conn, user: user} do
    :ok = Accounts.put_api_key(user, "anthropic", "sk-ant-saved-7777")
    {:ok, view, _} = live(conn, "/cuenta")
    assert has_element?(view, "#key-anthropic .key-saved", "7777")

    view |> element("#key-anthropic button", "Quitar") |> render_click()
    refute has_element?(view, "#key-anthropic .key-saved")
    assert Accounts.api_key(user.id, "anthropic") == :error
  end

  test "removing a key cancels its replacement without affecting a newer check", ctx do
    %{conn: conn, user: user} = ctx
    :ok = Accounts.put_api_key(user, "openai", "sk-original-key-1111")
    block_key_checks()
    {:ok, view, _} = live(conn, "/cuenta")

    view
    |> form("#key-form-openai", provider: "openai", key: "sk-cancelled-key-2222")
    |> render_submit()

    first = pending_check()
    view |> element("#key-openai button", "Quitar") |> render_click()
    refute has_element?(view, "#key-openai .key-saved")
    assert Accounts.api_key(user.id, "openai") == :error

    view
    |> form("#key-form-openai", provider: "openai", key: "sk-current-key-3333")
    |> render_submit()

    second = pending_check()
    release_check(first)
    assert has_element?(view, "#key-form-openai button[disabled]", "Comprobando")
    assert Accounts.api_key(user.id, "openai") == :error
    refute has_element?(view, "#key-openai .key-saved")

    :ok = :sys.suspend(view.pid)

    try do
      release_check(second)
      {:messages, messages} = Process.info(view.pid, :messages)
      assert Enum.any?(messages, &match?({:key_checked, _, "openai", {:ok, _}}, &1))
      refute inspect(messages) =~ "sk-current-key-3333"
    after
      :sys.resume(view.pid)
    end

    eventually(fn -> has_element?(view, "#key-openai .key-saved", "3333") end)
    assert Accounts.api_key(user.id, "openai") == {:ok, "sk-current-key-3333"}
    refute render(view) =~ "sk-cancelled-key-2222"
    refute render(view) =~ "sk-current-key-3333"
    refute inspect(:sys.get_state(view.pid).socket.assigns) =~ "sk-current-key-3333"
  end

  test "closing the account page before validation finishes does not save a key", ctx do
    %{conn: conn, user: user} = ctx
    block_key_checks()
    {:ok, view, _} = live(conn, "/cuenta")

    view
    |> form("#key-form-openai", provider: "openai", key: "sk-abandoned-key-4444")
    |> render_submit()

    checker = pending_check()
    assert :ok == stop_supervised({Dragonex.Test.LiveViewFixture, view.pid})
    release_check(checker)
    assert Accounts.api_key(user.id, "openai") == :error
  end

  defp block_key_checks do
    test_pid = self()

    Application.put_env(:dragonex, :ai_http,
      plug: fn conn ->
        send(test_pid, {:key_check_started, self()})

        receive do
          :finish -> Req.Test.json(conn, %{"data" => [%{"id" => "gpt-test"}]})
        end
      end
    )
  end

  defp pending_check do
    assert_receive {:key_check_started, pid}
    on_exit(fn -> send(pid, :finish) end)
    pid
  end

  defp release_check(pid) do
    ref = Process.monitor(pid)
    send(pid, :finish)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  defp stub(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer sk-good-key-abcd"] -> Req.Test.json(conn, %{"data" => [%{"id" => "gpt-5-mini"}]})
      _ -> Plug.Conn.send_resp(conn, 401, "")
    end
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end
end
