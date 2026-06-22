defmodule DragonesWeb.GameLiveTest do
  @moduledoc """
  The creator/list/table flow against the live endpoints:

    * `/`            — the lobby lists partidas (DragonesWeb.GameLive.Index).
    * `/games/new`   — the wizard builds a partida from a roster (GameLive.New).
    * `/games/:id`   — the table opens/resumes a partida by id (GameLive.Show).

  The Game runs beats in Tasks and notifies the LiveView via `Dragones.PubSub`,
  so the table test polls `render/1` rather than flushing a synchronous cascade.
  """

  use DragonesWeb.ConnCase, async: false

  import Dragones.Test.Harness

  alias Dragones.{Archetypes, Game, Games, Monsters}
  alias ExAgent.Models.Test

  # Every LiveView here touches the Repo (list/create/open); share the sandbox.
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragones.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Dragones.Repo, {:shared, self()})
    :ok
  end

  defp await_render(view, pred, timeout_ms \\ 4_000) when is_function(pred, 1) or is_binary(pred) do
    test? = if is_binary(pred), do: &(&1 =~ pred), else: pred
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> render(view) end)
    |> Enum.find_value(fn html ->
      cond do
        test?.(html) -> html
        System.monotonic_time(:millisecond) >= deadline -> nil
        true -> Process.sleep(15); nil
      end
    end)
  end

  # --------------------------------------------------------------- index

  describe "the lobby at /" do
    test "lists existing partidas and offers to create one", %{conn: conn} do
      {:ok, game} =
        Games.create_game(
          title: "La Cámara",
          scene: "x",
          roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
          initiative: ["goblin", "Thane"]
        )

      _ = game
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Dragones — partidas"
      assert html =~ "La Cámara"
      assert html =~ "Nueva partida"
    end

    test "deletes a partida", %{conn: conn} do
      {:ok, game} = Games.create_game(title: "Efímera", scene: "x", roster: [{Archetypes.fighter(), :human}])
      {:ok, view, _html} = live(conn, "/")

      view |> element("button", "Borrar") |> render_click(%{"id" => to_string(game.id)})

      refute render(view) =~ "Efímera"
    end
  end

  # --------------------------------------------------------------- wizard

  describe "the creator wizard at /games/new" do
    test "builds a partida from the roster and navigates to the table", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/games/new")

      assert render(view) =~ "Nueva partida"
      assert render(view) =~ "Thane"
      assert render(view) =~ "goblin"

      view
      |> element("form")
      |> render_submit(%{
        "title" => "La Ruina",
        "scene" => "una ruina tenebrosa",
        "dm_style" => "sombrío",
        "roster" => %{
          "fighter" => %{"include" => "on", "kind" => "human"},
          "goblin" => %{"include" => "on"}
        }
      })

      # The partida was persisted with the wizard's choices, and the wizard
      # navigated to its table.
      [game] = Games.list_games()
      assert_redirect(view, "/games/#{game.id}")
      assert game.title == "La Ruina"
      assert Games.load_world(game).scene == "una ruina tenebrosa"
      assert Games.load_world(game).phase == :combat
    end

    test "refuses to create with no characters selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/games/new")

      view
      |> element("form")
      |> render_submit(%{"title" => "x", "roster" => %{}})

      html = render(view)
      assert html =~ "Selecciona al menos un personaje."
      refute html =~ ~r{/games/\d+}
    end
  end

  # --------------------------------------------------------------- table

  describe "the table at /games/:id" do
    test "without ?as= it shows the seat picker; with ?as= it renders that viewer", %{conn: conn} do
      {:ok, game} =
        Games.create_game(
          title: "Mesa",
          scene: "x",
          roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
          initiative: ["goblin", "Thane"]
        )

      {:ok, view, html} = live(conn, "/games/#{game.id}")
      # No seat claimed yet → the picker is shown.
      assert html =~ "¿Quién eres?"

      # Claim Thane via the patch link; the table renders with the viewer set.
      view |> element("a", "Thane") |> render_click()
      assert_patch(view, "/games/#{game.id}?as=Thane")

      # The DM auto-acts (goblin) then it's Thane's turn → "¡Tu turno!".
      html = await_render(view, fn h -> h =~ "Es tu turno" and not (h =~ "el DM está pensando") end)
      assert html =~ "TÚ"
    end

    test "a claimed viewer can act on their turn; the DM replies", %{conn: conn} do
      {:ok, game} =
        Games.create_game(
          title: "Mesa",
          scene: "x",
          roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
          initiative: ["goblin", "Thane"]
        )

      {:ok, view, _html} = live(conn, "/games/#{game.id}?as=Thane")
      await_render(view, fn h -> h =~ "Es tu turno" and not (h =~ "el DM está pensando") end)

      view |> element("form") |> render_submit(%{"text" => "I attack the goblin."})

      html =
        await_render(view, fn h ->
          h =~ "I attack the goblin." and not (h =~ "el DM está pensando") and h =~ "Es tu turno"
        end)

      assert html =~ "OPENROUTER_API_KEY"
    end

    test "a missing partida redirects to the lobby", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/games/999999")
      assert to == "/"
    end
  end
end
