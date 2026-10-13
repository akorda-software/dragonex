defmodule DragonexWeb.AuthTest do
  @moduledoc """
  Entrar y Crear cuenta (D245): the sign-up form repeats the password and
  reports each mistake on its field, and Sign in with Google runs the OIDC
  code flow against a stubbed token endpoint (`config :dragonex, :google_http`).
  """

  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log

  import Phoenix.ConnTest

  alias Dragonex.Accounts
  alias Dragonex.Accounts.User
  alias Dragonex.Repo

  setup do
    Dragonex.Test.Sandbox.start_shared!()
    old = Map.new(~w(GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET), &{&1, System.get_env(&1)})
    Enum.each(old, fn {name, _} -> System.delete_env(name) end)

    on_exit(fn ->
      Application.delete_env(:dragonex, :google_http)

      Enum.each(old, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)
    end)

    :ok
  end

  describe "pages" do
    test "show the pixel wordmark and the Entrar / Crear cuenta tabs" do
      html = html_response(get(build_conn(), "/login"), 200)
      assert html =~ ~s(class="auth-mark" src="/assets/wordmark.svg")
      assert html =~ ~s(<a href="/login" class="is-current" aria-current="page">)
      refute html =~ "<h1>Dragonex</h1>"

      html = html_response(get(build_conn(), "/register"), 200)
      assert html =~ ~s(<a href="/register" class="is-current" aria-current="page">)
      assert html =~ ~s(name="password_confirmation")
    end

    test "offer Google only when the deployment has a client" do
      refute html_response(get(build_conn(), "/login"), 200) =~ "/auth/google"

      google_env()
      assert html_response(get(build_conn(), "/login"), 200) =~ ~s(href="/auth/google")
      assert html_response(get(build_conn(), "/register"), 200) =~ "Continuar con Google"
    end
  end

  describe "sign-up" do
    test "repeated password opens the account" do
      conn = post(build_conn(), "/register", signup("password123", "password123"))
      assert redirected_to(conn) == "/"
      assert Repo.get_by(User, email: "nueva@dragonex.test")
    end

    test "a different repetition keeps the form and marks the field" do
      conn = post(build_conn(), "/register", signup("password123", "password124"))
      html = html_response(conn, 200)

      assert html =~ ~s(id="reg-password-confirmation-error")
      assert html =~ "las dos contraseñas no coinciden"
      assert html =~ ~s(value="nueva@dragonex.test")
      assert html =~ ~s(value="Nueva")
      refute Repo.get_by(User, email: "nueva@dragonex.test")
    end

    test "a missing repetition never matches" do
      params = Map.delete(signup("password123", "x"), "password_confirmation")
      conn = post(build_conn(), "/register", params)
      assert html_response(conn, 200) =~ ~s(id="reg-password-confirmation-error")
      refute Repo.get_by(User, email: "nueva@dragonex.test")
    end

    test "a blank adventurer name is a field error, not a crash" do
      params = %{signup("password123", "password123") | "display_name" => "  "}
      conn = post(build_conn(), "/register", params)
      assert html_response(conn, 200) =~ ~s(id="reg-name-error")
      refute Repo.get_by(User, email: "nueva@dragonex.test")
    end

    test "a failed login keeps the typed email" do
      params = %{"email" => "nadie@dragonex.test", "password" => "password123"}
      html = html_response(post(build_conn(), "/login", params), 200)
      assert html =~ "Email o contraseña incorrectos."
      assert html =~ ~s(value="nadie@dragonex.test")
    end
  end

  describe "Sign in with Google" do
    setup do
      google_env()
      :ok
    end

    test "sends the browser to Google with state, nonce and a PKCE challenge" do
      conn = get(build_conn(), "/auth/google")
      %URI{host: "accounts.google.com", query: query} = URI.parse(redirected_to(conn))
      q = URI.decode_query(query)
      secrets = get_session(conn, "google_oauth")

      assert q["client_id"] == "client-id.apps.googleusercontent.com"
      assert q["redirect_uri"] == DragonexWeb.Endpoint.url() <> "/auth/google/callback"
      assert q["scope"] == "openid email profile"
      assert q["state"] == secrets["state"]
      assert q["nonce"] == secrets["nonce"]
      assert q["code_challenge_method"] == "S256"

      assert q["code_challenge"] ==
               Base.url_encode64(:crypto.hash(:sha256, secrets["verifier"]), padding: false)
    end

    test "a new Google player gets an account without password" do
      conn = sign_in(%{"sub" => "g-1", "email" => "Ana@Gmail.com", "name" => "Ana Pérez"})

      assert redirected_to(conn) == "/"
      user = Repo.get_by(User, google_sub: "g-1")
      assert %User{email: "ana@gmail.com", display_name: "Ana Pérez", password_hash: nil} = user
      assert get_session(conn, "user_id") == user.id
      assert get_session(conn, "google_oauth") == nil
      assert Accounts.authenticate("ana@gmail.com", "") == {:error, :invalid}

      # The second visit finds the same account by its Google id.
      conn = sign_in(%{"sub" => "g-1", "email" => "otro@gmail.com", "name" => "Ana"})
      assert get_session(conn, "user_id") == user.id
    end

    test "a verified email joins the existing account" do
      {:ok, user} =
        Accounts.register(%{
          email: "bea@dragonex.test",
          password: "password123",
          display_name: "Bea"
        })

      conn = sign_in(%{"sub" => "g-2", "email" => "bea@dragonex.test"})
      assert get_session(conn, "user_id") == user.id
      assert Repo.get!(User, user.id).google_sub == "g-2"
      assert {:ok, _} = Accounts.authenticate("bea@dragonex.test", "password123")
    end

    test "an unverified email neither joins nor opens an account" do
      conn = sign_in(%{"sub" => "g-3", "email" => "cai@dragonex.test", "email_verified" => false})

      assert redirected_to(conn) == "/login"
      assert get_session(conn, "user_id") == nil
      refute Repo.get_by(User, google_sub: "g-3")
    end

    test "a forged state, a foreign token or a wrong nonce log nobody in" do
      for {tamper, claims} <- [
            {:state, %{}},
            {:none, %{"aud" => "someone-else"}},
            {:none, %{"nonce" => "replayed"}},
            {:none, %{"exp" => System.os_time(:second) - 10}}
          ] do
        conn = sign_in(Map.merge(%{"sub" => "g-4", "email" => "dan@gmail.com"}, claims), tamper)
        assert redirected_to(conn) == "/login"
        assert get_session(conn, "user_id") == nil
      end

      refute Repo.get_by(User, google_sub: "g-4")
    end
  end

  defp signup(password, confirmation) do
    %{
      "display_name" => "Nueva",
      "email" => "nueva@dragonex.test",
      "password" => password,
      "password_confirmation" => confirmation
    }
  end

  defp google_env do
    System.put_env("GOOGLE_CLIENT_ID", "client-id.apps.googleusercontent.com")
    System.put_env("GOOGLE_CLIENT_SECRET", "client-secret")
  end

  # Goes to Google, then comes back with a code that the stubbed token
  # endpoint trades for an ID token carrying `claims` over the defaults.
  defp sign_in(claims, tamper \\ :none) do
    conn = get(build_conn(), "/auth/google")
    secrets = get_session(conn, "google_oauth")
    test_pid = self()

    Application.put_env(:dragonex, :google_http,
      plug: fn token_conn ->
        {:ok, body, token_conn} = Plug.Conn.read_body(token_conn)
        send(test_pid, {:token_request, URI.decode_query(body)})

        defaults = %{
          "iss" => "https://accounts.google.com",
          "aud" => "client-id.apps.googleusercontent.com",
          "exp" => System.os_time(:second) + 300,
          "nonce" => secrets["nonce"],
          "email_verified" => true
        }

        Req.Test.json(token_conn, %{"id_token" => id_token(Map.merge(defaults, claims))})
      end
    )

    state = if tamper == :state, do: "forged", else: secrets["state"]
    conn = get(recycle(conn), "/auth/google/callback", %{"code" => "the-code", "state" => state})

    if tamper == :none do
      assert_received {:token_request, %{"code" => "the-code", "code_verifier" => verifier}}
      assert verifier == secrets["verifier"]
    end

    conn
  end

  defp id_token(claims) do
    part = &Base.url_encode64(Jason.encode!(&1), padding: false)
    part.(%{"alg" => "RS256"}) <> "." <> part.(claims) <> ".signature"
  end
end
