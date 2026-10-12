defmodule DragonexWeb.GamePartyVisibilityTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log

  alias Dragonex.{Accounts, Archetypes, Character, Game, Games, World}
  import Dragonex.Test.Harness

  setup do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "party-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Grupo"
      })

    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    %{conn: conn, user: user}
  end

  test "exploration shows all six PCs and places the viewer first", %{conn: conn, user: user} do
    pcs = party()
    {view, _game} = table(conn, user, pcs)

    for pc <- pcs do
      assert has_element?(view, ".game-rail .sheet .card-name", pc.name)
    end

    assert has_element?(view, ".game-rail-left > .sheet:first-child .card.mine", "Zuria")
    assert length(nodes(view, ".game-rail > .sheet .card-name")) == 6
  end

  for phase <- [:exploration, :combat] do
    test "mobile companions expose all other PCs including a fallen one in #{phase}", %{
      conn: conn,
      user: user
    } do
      [first | rest] = party()
      first = %{first | hp: 0, death_saves: %{successes: 1, fails: 1}}
      pcs = [first | rest]
      {view, _game} = table(conn, user, pcs, phase: unquote(phase))

      assert has_element?(view, "#mobile-companions summary", "Compañeros (5)")

      for pc <- Enum.drop(pcs, -1) do
        assert has_element?(view, "#mobile-companions .card-name", pc.name)
      end

      refute has_element?(view, "#mobile-companions .card-name", "Zuria")
      assert has_element?(view, "#mobile-companions .is-down", "Caído")
      assert has_element?(view, "#mobile-companions .card-stats", "HP 0/12")
    end
  end

  test "an absent NPC is removed from scene sheets and returns with stored HP", %{
    conn: conn,
    user: user
  } do
    pcs = [List.last(party())]
    npc = Character.new(name: "A retirado", side: "npc", hp: 3, max_hp: 12)
    {view, game} = table(conn, user, pcs, extra: [npc], absent: npc.name)
    refute has_element?(view, ".game-rail .card-name", npc.name)
    assert Games.load_world(Games.get_game(game.id)).characters[npc.name].hp == 3

    {returned, _game} = table(conn, user, pcs, extra: [npc])
    assert has_element?(returned, ".game-rail .card-name", npc.name)
    assert has_element?(returned, ".game-rail .card.side-npc", "HP 3/12")
  end

  test "scene NPCs do not displace PCs and supplemental sheets stay bounded", %{
    conn: conn,
    user: user
  } do
    pcs = party()

    extras =
      for i <- 1..10, do: Character.new(name: "A visitante #{i}", side: "npc", hp: 5, max_hp: 5)

    {view, _game} = table(conn, user, pcs, extra: extras)

    for pc <- pcs do
      assert has_element?(view, ".game-rail > .sheet .card-name", pc.name)
    end

    assert length(nodes(view, ".game-rail > .sheet .card.side-pc")) == 6
    assert length(nodes(view, ".game-rail > .sheet .card.side-npc")) == 2
  end

  test "creator DM inspection can consult the full group on mobile", %{conn: conn, user: user} do
    pcs = party()
    {_view, game} = table(conn, user, pcs)
    {:ok, dm, _} = live(conn, "/games/#{game.id}?as=dm")

    assert has_element?(dm, "#mobile-companions summary", "Grupo (6)")
    assert length(nodes(dm, "#mobile-companions .card-name")) == 6
    refute has_element?(dm, ".card.mine")
  end

  test "a real DM attack updates a companion's HP in the mobile group", %{conn: conn, user: user} do
    pcs = party()
    goblin = Dragonex.Monsters.goblin()

    model = %ExAgent.Models.Test{
      script: [
        tool_calls([
          call("make_attack", %{
            "attacker" => goblin.name,
            "target" => "Aina",
            "weapon" => "scimitar"
          })
        ]),
        narration("El goblin alcanza a Aina.")
      ]
    }

    {view, game} =
      table(conn, user, pcs,
        phase: :combat,
        extra: [goblin],
        initiative: [goblin.name, "Zuria" | Enum.map(Enum.drop(pcs, -1), & &1.name)],
        current: "dm",
        combatant: goblin.name,
        model: model,
        roller: fn sides -> if sides == 20, do: 20, else: 1 end
      )

    assert has_element?(view, "#mobile-companions .card-stats", "HP 12/12")
    pid = Dragonex.Game.Supervisor.whereis(game.id)
    assert :ok = Game.resume(pid)
    assert :ok = Game.await_turn(pid, "Zuria")
    assert Game.world(pid).characters["Aina"].hp == 8
    assert has_element?(view, "#mobile-companions .card-stats", "HP 8/12")
    assert Games.load_world(Games.get_game(game.id)).characters["Aina"].hp == 8
  end

  test "the initiative strip marks sides, HP and the fallen for the mobile table",
       %{conn: conn, user: user} do
    pcs = party()
    goblin = %{Dragonex.Monsters.goblin() | hp: 0}

    {view, _game} =
      table(conn, user, pcs,
        phase: :combat,
        extra: [goblin],
        initiative: ["Zuria", goblin.name | Enum.map(Enum.drop(pcs, -1), & &1.name)]
      )

    assert has_element?(view, ".initiative li.active.side-pc", "Zuria")
    assert has_element?(view, ".initiative li.side-enemy.is-down", goblin.name)
    assert has_element?(view, ".initiative li[title*='HP 12/12'] .ini-hp.hp-high span")
    assert has_element?(view, ".game-rail-right .mobile-combat-tracker", goblin.name)
  end

  defp party do
    for name <- ["Aina", "Bran", "Cira", "Dara", "Eira", "Zuria"],
        do: %{Archetypes.fighter() | name: name}
  end

  defp table(conn, user, pcs, opts \\ []) do
    viewer = List.last(pcs)
    others = Enum.drop(pcs, -1) ++ Keyword.get(opts, :extra, [])
    roster = [{viewer, :human} | Enum.map(others, &{&1, :ai})]

    {:ok, game} = Games.create_game(title: "El grupo completo", user_id: user.id, roster: roster)
    world = Games.load_world(game)

    world =
      if name = opts[:absent] do
        {:ok, absent} = World.leave_scene(name, "Se retira de la posada").(world)
        absent
      else
        world
      end

    world =
      if opts[:phase] == :combat do
        order = Keyword.get(opts, :initiative, Enum.map(pcs, & &1.name))
        {:ok, combat} = World.begin_combat(order).(world)
        {:ok, combat} = World.set_current_combatant(opts[:combatant] || viewer.name).(combat)
        combat
      else
        world
      end

    {:ok, game} = Games.save_state(game.id, world, opts[:current] || viewer.name, 1, :paused)

    game_opts =
      Keyword.take(opts, [:roller]) |> Keyword.put(:model, opts[:model] || %ExAgent.Models.Test{})

    Dragonex.Test.GameFixture.start!({Game, {game.id, game_opts}})
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    {view, game}
  end

  defp nodes(view, selector),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.to_list()
end
