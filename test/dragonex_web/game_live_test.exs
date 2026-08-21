defmodule DragonexWeb.GameLiveTest do
  @moduledoc """
  The creator/list/table flow against the live endpoints.

  All routes except `/` and auth require a logged-in user, so each test
  registers a user and seeds the session cookie.
  """

  use DragonexWeb.ConnCase, async: false

  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Accounts, Game, Games, Monsters}
  alias ExAgent.Models.Test

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragonex.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Dragonex.Repo, {:shared, self()})

    {:ok, user} =
      Accounts.register(%{
        email: "test#{System.unique_integer([:positive])}@dragonex.test",
        password: "password123",
        display_name: "TestHero"
      })

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> DragonexWeb.UserAuth.log_in(user)

    {:ok, conn: conn, user: user}
  end

  defp await_render(view, pred, timeout_ms \\ 4_000)
       when is_function(pred, 1) or is_binary(pred) do
    test? = if is_binary(pred), do: &(&1 =~ pred), else: pred
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> render(view) end)
    |> Enum.find_value(fn html ->
      cond do
        test?.(html) ->
          html

        System.monotonic_time(:millisecond) >= deadline ->
          nil

        true ->
          Process.sleep(15)
          nil
      end
    end)
  end

  # --------------------------------------------------------------- index

  describe "the lobby at /" do
    test "lists existing partidas and offers to create one", %{conn: conn, user: user} do
      {:ok, _game} =
        Games.create_game(
          title: "La Cámara",
          scene: "x",
          user_id: user.id,
          roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
          initiative: ["goblin", "Thane"]
        )

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Dragonex — partidas"
      assert html =~ "La Cámara"
      assert html =~ "Nueva partida"
    end

    test "deletes a partida", %{conn: conn, user: user} do
      {:ok, game} =
        Games.create_game(
          title: "Efímera",
          scene: "x",
          user_id: user.id,
          roster: [{Archetypes.fighter(), :human}]
        )

      {:ok, view, _html} = live(conn, "/")

      view |> element("button", "Borrar") |> render_click(%{"id" => to_string(game.id)})

      refute render(view) =~ "Efímera"
    end

    test "cannot delete another user's partida (forged phx-value-id)", %{conn: conn} do
      # Owner is a different user than the one logged into this conn.
      {:ok, owner} =
        Accounts.register(%{
          email: "owner#{System.unique_integer([:positive])}@dragonex.test",
          password: "password123",
          display_name: "Owner"
        })

      {:ok, game} =
        Games.create_game(
          title: "Ajena",
          scene: "x",
          user_id: owner.id,
          roster: [{Archetypes.fighter(), :human}]
        )

      {:ok, view, _html} = live(conn, "/")

      # Simulate a forged delete event targeting the owner's game id.
      view |> render_click("delete", %{"id" => to_string(game.id)})

      # The partida must survive.
      assert Games.get_game(game.id) != nil
      refute render(view) =~ "Ajena"
    end
  end

  # --------------------------------------------------------------- wizard

  describe "the creator wizard at /games/new" do
    test "builds a partida via the 2-step wizard", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, "/games/new")

      # Step 1: details — pick a scenario
      assert render(view) =~ "Detalles"
      view |> element(".scenario-card", "Taberna") |> render_click()

      # Advance to step 2
      view |> render_click("next")
      assert render(view) =~ "Tu personaje"

      # Pick the fighter as your hero
      view |> element(".hero-opt", "Thane") |> render_click()

      # Create the game
      view |> render_click("next")

      [game] = Games.list_games(user.id)
      assert_redirect(view, "/games/#{game.id}")
      assert game.title == "La Taberna del Dragón Rojo"
      assert Games.load_world(game).scene =~ "taberna"
    end

    test "refuses to create without picking a hero", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/games/new")

      # Skip to step 2 without picking anything
      view |> render_click("next")

      # Try to create without a hero
      view |> render_click("next")

      assert render(view) =~ "Elige tu personaje"
    end
  end

  # --------------------------------------------------------------- table

  describe "the table at /games/:id" do
    test "auto-assigns the viewer to their character (no picker)", %{conn: conn, user: user} do
      {:ok, game} =
        Games.create_game(
          title: "Mesa",
          scene: "x",
          user_id: user.id,
          roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
          initiative: ["goblin", "Thane"]
        )

      {:ok, view, html} = live(conn, "/games/#{game.id}")

      # No picker — the viewer is auto-assigned to their character
      refute html =~ "¿Quién eres?"

      # The DM auto-acts (goblin) then it's Thane's turn
      html =
        await_render(view, fn h -> h =~ "Es tu turno" and not (h =~ "el DM está pensando") end)

      assert html =~ "TÚ"
    end

    test "a missing partida redirects to the lobby", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/games/999999")
      assert to == "/"
    end

    test "a non-creator viewer cannot start the partida (forged start_game)", %{conn: conn} do
      {:ok, owner} =
        Accounts.register(%{
          email: "owner#{System.unique_integer([:positive])}@dragonex.test",
          password: "password123",
          display_name: "Owner"
        })

      {:ok, game} =
        Games.create_game(
          title: "Espera",
          scene: "x",
          user_id: owner.id,
          open_slots: 1,
          roster: [{Archetypes.fighter(), :human}]
        )

      # The logged-in user (not the owner) reaches the waiting room via open slots.
      {:ok, view, _html} = live(conn, "/games/#{game.id}")

      # Forged privileged event: only the creator may start the game.
      view |> render_click("start_game")

      # Status must remain :configuring — the forged start was rejected.
      assert Games.get_game(game.id).status == :configuring
    end
  end
end
