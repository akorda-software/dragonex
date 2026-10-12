defmodule DragonexWeb.GameLiveTest do
  @moduledoc """
  The creator/list/table flow against the live endpoints.

  All routes except `/` and auth require a logged-in user, so each test
  registers a user and seeds the session cookie.
  """

  use DragonexWeb.ConnCase, async: false

  import Dragonex.Test.Harness

  alias Dragonex.{Archetypes, Accounts, Character, Game, Games, Monsters}

  # AC-16.1: a model whose FIRST response is truncated at max_tokens
  # (finish_reason :length — unvalidated partial text remains private) and
  # whose subsequent response closes through the official structured output.
  # This drives the real token retry without publishing the truncated chunk.
  defmodule RetryModel do
    @behaviour ExAgent.Model

    alias ExAgent.Message, as: Msg
    alias ExAgent.Message.{Part, Response, Usage}

    defstruct [:counter]

    @partial "El goblin se abalanza y alza su cuchilla jaspeada hacia el"
    @final "El goblin gruñe, retrocede un paso y se pierde entre las sombras del pasadizo."

    def partial, do: @partial
    def final, do: @final

    @impl true
    def request(%__MODULE__{counter: counter} = m, _messages, _settings, _params) do
      if dec(counter) do
        {:ok, build_response(@partial, :length), m}
      else
        {:ok, Dragonex.Test.Harness.narration_response(@final), m}
      end
    end

    @impl true
    def request_stream(m, messages, settings, params) do
      case request(m, messages, settings, params) do
        {:ok, resp, updated} ->
          text = Response.text(resp)

          Stream.concat([
            Stream.map(word_chunks(text), &{:text_delta, &1}),
            [Dragonex.Test.Harness.stream_response(resp, updated)]
          ])
      end
    end

    defp word_chunks(text), do: String.split(text, ~r/(?<=\s)/, include_captures: true)

    defp build_response(text, finish_reason) do
      Msg.new_response([%Part.Text{content: text}],
        usage: %Usage{input_tokens: 1, output_tokens: 1},
        model_name: "retry",
        finish_reason: finish_reason
      )
    end

    # True while the truncated first response remains (then decrements).
    defp dec(counter) do
      Agent.get_and_update(counter, fn
        0 -> {false, 0}
        n -> {true, n - 1}
      end)
    end

    @impl true
    def model_name(_), do: "retry"
    @impl true
    def system(_), do: "retry"
    @impl true
    def profile(_), do: %ExAgent.ModelProfile{supports_tools: true}
  end

  setup do
    Dragonex.Test.Sandbox.start_shared!()

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

      assert html =~ "Tus partidas"
      assert html =~ "La Cámara"
      assert html =~ "Nueva partida"
      assert html =~ ~s(id="logout-form")
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

      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Dragonex.Test.Narrator{text: "El goblin observa a Thane."}]}}
      )

      {:ok, view, html} = live(conn, "/games/#{game.id}")

      assert html =~ ~s(id="sheet-drawer")
      assert html =~ "Ficha"

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

    test "AC-13.2: \"cargar más\" pagina hacia atrás sin saltos ni duplicados", %{
      conn: conn,
      user: user
    } do
      {:ok, game} =
        Games.create_game(
          title: "Crónica larga",
          scene: "x",
          user_id: user.id,
          roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
          initiative: ["goblin", "Thane"]
        )

      # 250 seeded narrations (seq 3..252): well past the initial window of
      # @chat_window (200) — the oldest ~50 only come back via "cargar más".
      markers = for i <- 1..250, do: "marcador #{String.pad_leading(to_string(i), 3, "0")}"

      for text <- markers do
        {:ok, _} = Games.append_event(game.id, :narration, "dm", "all", %{text: text})
      end

      Dragonex.Test.GameFixture.start!(
        {Game, {game.id, [model: %Dragonex.Test.Narrator{text: "El goblin observa a Thane."}]}}
      )

      {:ok, view, _html} = live(conn, "/games/#{game.id}")

      # Quiescence: the opening DM beat settles and it's Thane's turn (the
      # loop then idles, so no game_updated re-render can wipe the pager).
      html = await_render(view, "Es tu turno")

      # The initial window truncated the oldest events: the "cargar más"
      # button is there and the first markers are NOT rendered.
      assert html =~ "cargar turnos anteriores"
      refute html =~ hd(markers)

      # One click pages the rest back in (the backlog fits a single page of
      # @log_page_size, so the button disappears once everything is loaded).
      html = view |> element("button", "cargar turnos anteriores") |> render_click()

      refute html =~ "cargar turnos anteriores"

      # Sin saltos: EVERY marker is on screen — the loaded page is contiguous
      # with the initial window (nothing in between was skipped).
      for text <- markers do
        assert html =~ text, "salto en la paginación: falta #{text}"
      end

      # Sin duplicados: each marker renders exactly once.
      for i <- [1, 100, 250] do
        text = Enum.at(markers, i - 1)
        assert length(String.split(html, text)) == 2, "#{text} aparece más de una vez"
      end
    end

    test "AC-16.1: chunks duplicados por reintento no aparecen dos veces en el feed", %{
      conn: conn,
      user: user
    } do
      {:ok, game} =
        Games.create_game(
          title: "Reintento",
          scene: "x",
          user_id: user.id,
          roster: [{Archetypes.fighter(), :human}, {Monsters.goblin(), :ai}],
          initiative: ["goblin", "Thane"]
        )

      # The first response is truncated and kept private. The retry supplies
      # validated narration through final_result. Start the real Game here so
      # the model is under the fixture's control.
      {:ok, counter} = Agent.start_link(fn -> 1 end)

      pid =
        Dragonex.Test.GameFixture.start!(
          {Game, {game.id, [model: %RetryModel{counter: counter}, roller: fixed_roller(15)]}}
        )

      assert :ok =
               Game.await(pid, fn s -> s.status == :waiting and s.current == "Thane" end, 8_000)

      {:ok, view, _html} = live(conn, "/games/#{game.id}")

      # The feed shows the FINAL narration (one card, exactly once)…
      html = await_render(view, RetryModel.final())
      assert length(String.split(html, RetryModel.final())) == 2

      # …and the truncated chunk the retry duplicated is NOT on screen…
      refute html =~ "cuchilla jaspeada"

      # The truncated response never gained a publication receipt. Exactly
      # one validated final narration reaches the durable feed.
      events = Games.list_events(game.id)

      assert Enum.count(events, fn e ->
               e.type == :narration and e.payload["text"] == RetryModel.final()
             end) == 1

      assert Enum.count(events, fn e ->
               e.type == :narration and (e.payload["text"] || "") =~ "cuchilla jaspeada"
             end) == 0
    end
  end

  describe "character sheet status" do
    test "shows temporary HP, rage, inspiration and concentration" do
      card =
        Character.new(
          name: "A",
          class: "barbarian",
          hp: 10,
          max_hp: 12,
          temp_hp: 8,
          concentrating: "bless",
          raging: true,
          inspired: true
        )

      html = render_component(&DragonexWeb.GameLive.Components.detail_sheet/1, card: card)
      assert html =~ "+8 temp"
      assert html =~ "Furia"
      assert html =~ "Inspirado"
      assert html =~ "bless"
    end
  end
end
