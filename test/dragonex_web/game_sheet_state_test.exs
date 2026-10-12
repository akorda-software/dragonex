defmodule DragonexWeb.GameSheetStateTest do
  use DragonexWeb.ConnCase, async: false
  @moduletag :capture_log

  import Dragonex.Test.Harness

  alias Dragonex.{Accounts, Archetypes, Character, Game, Games, Heroes, World}
  alias DragonexWeb.GameLive.Components
  alias ExAgent.Models.Test

  test "every table sheet shows effective AC without changing the base sheet" do
    hero = Character.new(name: "Hero", hp: 12, max_hp: 12, ac: 18, fighting_style: "defense")
    cleric = Character.new(name: "Cleric", class: "cleric", hp: 12, max_hp: 12)
    world = World.new(characters: %{hero.name => hero, cleric.name => cleric})
    {:ok, world} = World.shield_of_faith(cleric.name, [hero.name]).(world)
    protected = world.characters[hero.name]

    for component <- [&Components.sheet/1, &Components.detail_sheet/1] do
      assert render_component(component, card: protected) =~ "CA 21"
    end

    assert render_component(&Components.combatant/1, world: world, name: hero.name) =~ "CA 21"
    assert protected.ac == 18

    {:ok, cleared} = World.clear_concentration(cleric.name).(world)

    assert render_component(&Components.detail_sheet/1, card: cleared.characters[hero.name]) =~
             "CA 19"

    assert cleared.characters[hero.name].ac == 18
  end

  for {label, saves} <- [
        {"Caído", %{successes: 1, fails: 1}},
        {"Estable", %{successes: 3, fails: 0}},
        {"Muerto", %{successes: 0, fails: 3}}
      ] do
    test "sheets distinguish #{label} at zero HP" do
      card =
        Character.new(name: "Hero", hp: 0, max_hp: 12, death_saves: unquote(Macro.escape(saves)))

      for component <- [&Components.sheet/1, &Components.detail_sheet/1] do
        html = render_component(component, card: card)
        assert html =~ unquote(label)
        if unquote(label) != "Caído", do: refute(html =~ "Caído")
      end

      html = render_component(&Components.detail_sheet/1, card: card)
      if unquote(label) == "Caído", do: assert(html =~ "1 éxito · 1 fallo")
    end
  end

  test "the caster sheet exposes spent slots and finite hit dice from World" do
    card = %{Archetypes.wizard() | level: 3}

    world =
      World.new(
        characters: %{card.name => card},
        spell_slots: %{card.name => %{1 => 0, 2 => 1}},
        rest_state: %{card.name => %{"hit_dice_used" => 1}}
      )

    html = render_component(&Components.detail_sheet/1, card: card, world: world)
    assert html =~ "Casillas de conjuro"
    assert html =~ "Nivel 1"
    assert html =~ "0 disponibles"
    assert html =~ "Nivel 2"
    assert html =~ "1 disponible"
    assert html =~ "Dados de golpe"
    assert html =~ "2/3 · d6"
    assert html =~ "Rayo ígneo"
    assert html =~ "Proyectil mágico"

    overview = render_component(&Components.sheet/1, card: card, world: world, mine: true)
    assert overview =~ "0 disponibles"
    assert overview =~ "2/3 · d6"
  end

  test "a fighter sees hit dice and spent Second Wind without invented spell slots" do
    card = %{Archetypes.fighter() | second_wind_used: true}

    world =
      World.new(
        characters: %{card.name => card},
        rest_state: %{card.name => %{"hit_dice_used" => 1}}
      )

    html = render_component(&Components.detail_sheet/1, card: card, world: world)
    assert html =~ "0/1 · d10"
    assert html =~ "Segundo aliento"
    assert html =~ "Gastado"
    assert html =~ "Espada larga"
    refute html =~ "Casillas de conjuro"
  end

  test "an untracked caster is not presented as having a full reserve" do
    card = Archetypes.wizard()
    world = World.new(characters: %{card.name => card})
    html = render_component(&Components.detail_sheet/1, card: card, world: world)
    assert html =~ "Casillas sin registro"
    refute html =~ "2 disponibles"
  end

  test "own sheets show the spent class pool and its capacity instead of implying a full reserve" do
    for {class, field, remaining, maximum, label} <- [
          {"monk", :ki, 0, 2, "Ki"},
          {"sorcerer", :sorcery_points, 1, 2, "Puntos de hechicería"},
          {"paladin", :lay_on_hands_pool, 7, 10, "Imposición de manos"},
          {"paladin", :divine_sense_uses, 0, 4, "Sentido divino"},
          {"bard", :bardic_inspiration_uses, 0, 3, "Inspiración bárdica"},
          {"druid", :wild_shape_uses, 1, 2, "Forma salvaje"}
        ] do
      {:ok, card} =
        Heroes.build(%{name: "Hero", race: "human", class: class, level: 2, background: "sage"})

      card = card |> Map.put(:cha, 16) |> Map.put(field, remaining)
      world = World.new(characters: %{card.name => card}) |> World.init_spell_slots()

      for component <- [&Components.detail_sheet/1, &Components.sheet/1] do
        html = render_component(component, card: card, world: world, mine: true)
        row = html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-resource='#{field}']")
        assert row |> LazyHTML.query("dt") |> LazyHTML.text() |> String.trim() == label

        assert row |> LazyHTML.query("dd") |> LazyHTML.text() |> String.trim() ==
                 "#{remaining}/#{maximum} disponibles"

        if remaining == 0, do: refute(Enum.empty?(LazyHTML.query(row, ".resource-spent")))
      end
    end
  end

  test "a live monk sheet exposes newly unlocked ki after sync and keeps it after reload" do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "ki-sheet-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Monje"
      })

    {:ok, card} = Heroes.build(%{name: "Shen", race: "human", class: "monk", background: "sage"})
    {:ok, hero} = Accounts.save_hero(user, card)

    {:ok, game} =
      Games.create_game(
        title: "Ki progression",
        user_id: user.id,
        roster: [{card, :human, hero.id}]
      )

    {:ok, _} = Games.save_state(game.id, Games.load_world(game), card.name, 1, :paused)
    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: %Test{}]}})
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    refute has_element?(view, "[data-resource=ki]")
    assert {:ok, hero} = Accounts.level_up_hero(user, hero.id, %{expected_level: 1})
    assert {:ok, _} = Games.sync_hero_level_up(game.id, hero.id, Accounts.hero_sheet(hero))
    assert has_element?(view, ".card.mine [data-resource=ki]", "2/2 disponibles")
    assert Game.world(pid).characters[card.name].ki == 2
    {:ok, reopened, _} = live(conn, "/games/#{game.id}")
    assert has_element?(reopened, ".mobile-player-sheet [data-resource=ki]", "2/2 disponibles")
    assert Game.snapshot(pid).status == :paused
  end

  test "a progressed transformed druid keeps the beast's HP on the live sheet and reload before reverting" do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "shape-sheet-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Druida"
      })

    sheet =
      Character.new(
        name: "Sylvi",
        class: "druid",
        level: 2,
        con: 18,
        dex: 14,
        wis: 16,
        hp: 7,
        max_hp: 20,
        ac: 12,
        wild_shape_uses: 2
      )

    {:ok, hero} = Accounts.save_hero(user, sheet)

    {:ok, game} =
      Games.create_game(
        title: "Ficha de dos formas",
        user_id: user.id,
        roster: [{sheet, :human, hero.id}]
      )

    {:ok, before} =
      World.transform_wild_shape(sheet.name, "wolf", Dragonex.Monsters.wolf()).(
        Games.load_world(game)
      )

    {:ok, before} = World.apply_damage(sheet.name, 5).(before)
    {:ok, _} = Games.save_state(game.id, before, sheet.name, 1, :paused)

    model = %Test{
      script: [
        tool_calls([call("end_wild_shape", %{"who" => sheet.name})]),
        narration("Vuelvo a mi forma original."),
        narration("La sala está en calma. ¿Qué haces?")
      ]
    }

    pid = Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model]}})
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    assert has_element?(view, ".card.mine .card-stats", "HP 6/11")
    assert has_element?(view, ".card.mine .cond-badge", "Forma de lobo")
    assert {:ok, hero} = Accounts.level_up_hero(user, hero.id, %{expected_level: 2})
    assert {:ok, _} = Games.sync_hero_level_up(game.id, hero.id, Accounts.hero_sheet(hero))
    assert has_element?(view, ".card.mine .card-sub", "nivel 3")
    assert has_element?(view, ".card.mine .card-stats", "HP 6/11")
    assert has_element?(view, ".card.mine [data-resource=wild_shape_uses]", "1/2 disponibles")
    assert Game.world(pid).characters[sheet.name].wild_shape.orig_max_hp == 29
    assert has_element?(view, ".card.mine [data-resource=native-hit-points]", "7/29 PG")
    {:ok, reloaded, _} = live(conn, "/games/#{game.id}")
    assert has_element?(reloaded, ".mobile-player-sheet .card-stats", "HP 6/11")
    assert has_element?(reloaded, ".mobile-player-sheet .cond-badge", "Forma de lobo")

    assert has_element?(
             reloaded,
             ".mobile-player-sheet [data-resource=native-hit-points]",
             "7/29 PG"
           )

    reloaded |> element("button[phx-click=resume]") |> render_click()
    assert :ok = Game.await(pid, &(&1.current == sheet.name and &1.status == :waiting))
    reloaded |> form("#player-input", text: "Vuelvo a mi forma original.") |> render_submit()
    assert :ok = Game.await(pid, &(&1.current == sheet.name and &1.status == :waiting))
    assert has_element?(reloaded, ".card.mine .card-stats", "HP 7/29")
    assert has_element?(reloaded, ".mobile-player-sheet .card-stats", "HP 7/29")
    refute has_element?(reloaded, "[data-resource=native-hit-points]")
    refute has_element?(reloaded, ".cond-badge", "Forma de lobo")
    assert :ok = Game.pause(pid)
    assert Game.world(pid).characters[sheet.name].wild_shape == nil
  end

  test "transformed cards identify each catalog beast and keep original vitality separate" do
    sheet =
      Character.new(
        name: "Sylvi",
        class: "druid",
        level: 4,
        con: 18,
        dex: 14,
        wis: 16,
        hp: 7,
        max_hp: 29,
        ac: 12,
        wild_shape_uses: 2,
        spells: [%Dragonex.Spell{name: "cure wounds", level: 1, casting_ability: :wis}]
      )

    for {beast, label} <- [{"cat", "gato"}, {"wolf", "lobo"}, {"black_bear", "oso negro"}] do
      world = World.new(characters: %{sheet.name => sheet})

      {:ok, transformed} =
        World.transform_wild_shape(
          sheet.name,
          beast,
          Dragonex.Monsters.get(beast).(name: sheet.name)
        ).(world)

      card = transformed.characters[sheet.name]

      for component <- [&Components.detail_sheet/1, &Components.sheet/1] do
        html = render_component(component, card: card, world: transformed, mine: true)
        assert html =~ "Forma de #{label}"
        assert html =~ "Forma original"
        assert html =~ "7/29 PG"

        assert html =~ "Vuelve a tu forma original para lanzar conjuros."

        assert transformed.characters[sheet.name] == card
      end

      {:ok, reverted} = World.revert_wild_shape(sheet.name).(transformed)

      html =
        render_component(&Components.detail_sheet/1,
          card: reverted.characters[sheet.name],
          world: reverted
        )

      refute html =~ "Vuelve a tu forma original para lanzar conjuros."
    end
  end

  test "a partial legacy original-form snapshot remains explicit instead of implying known hit points" do
    card =
      Character.new(
        name: "Sylvi",
        class: "druid",
        level: 2,
        hp: 11,
        max_hp: 11,
        wild_shape: %{beast: "wolf", orig_hp: nil, orig_max_hp: nil}
      )

    world = World.new(characters: %{card.name => card})
    html = render_component(&Components.detail_sheet/1, card: card, world: world)
    row = html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-resource=native-hit-points]")
    assert LazyHTML.text(row) =~ "Forma original"
    assert LazyHTML.text(row) =~ "Sin registrar"
    refute LazyHTML.text(row) =~ "0/0"
    assert html =~ "Forma de lobo"
  end

  test "an ordinary sheet and a companion overview do not invent a second health pool" do
    card = Archetypes.fighter()
    world = World.new(characters: %{card.name => card})
    html = render_component(&Components.detail_sheet/1, card: card, world: world)
    refute html =~ "native-hit-points"
    refute html =~ "Forma de bestia"

    {:ok, shaped} =
      World.transform_wild_shape(card.name, "wolf", Dragonex.Monsters.wolf()).(world)

    companion =
      render_component(&Components.sheet/1, card: shaped.characters[card.name], world: shaped)

    assert companion =~ "Forma de lobo"
    refute companion =~ "native-hit-points"
  end

  test "the combat turn bar identifies the monster and never offers a busy human the floor" do
    hero = Archetypes.fighter()
    goblin = Dragonex.Monsters.goblin()
    world = World.new(characters: %{hero.name => hero, goblin.name => goblin})
    {:ok, world} = World.begin_combat([goblin.name, hero.name]).(world)
    {:ok, world} = World.set_current_combatant(goblin.name).(world)

    html =
      render_component(&Components.turn_bar/1,
        world: world,
        current: "dm",
        round: 1,
        status: :running,
        viewer: hero.name
      )

    assert html =~ "Turno de goblin"

    {:ok, world} = World.set_current_combatant(hero.name).(world)

    html =
      render_component(&Components.turn_bar/1,
        world: world,
        current: hero.name,
        round: 1,
        status: :running,
        viewer: hero.name
      )

    refute html =~ "¡Tu turno!"
    assert html =~ "Resolviendo tu acción"
  end

  test "casting updates the displayed reserve through Game and survives LiveView reload" do
    Dragonex.Test.Sandbox.start_shared!()

    {:ok, user} =
      Accounts.register(%{
        email: "sheet-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Mago"
      })

    card = Archetypes.wizard()

    {:ok, game} =
      Games.create_game(
        title: "Spell reserve",
        user_id: user.id,
        roster: [{card, :human}, {Dragonex.Monsters.goblin(), :ai}],
        initiative: [card.name, "goblin"]
      )

    {:ok, game} = Games.save_state(game.id, Games.load_world(game), card.name, 1, :paused)

    model = %Test{
      script: [
        tool_calls([
          call("cast_spell", %{
            "caster" => card.name,
            "spell" => "magic missile",
            "target" => "goblin"
          })
        ]),
        narration("Los dardos alcanzan al goblin."),
        # The DM's following turn: an exhausted script would pause it (D228).
        narration("El goblin se tambalea entre los barriles.")
      ]
    }

    pid =
      Dragonex.Test.GameFixture.start!({Game, {game.id, [model: model, roller: fn _ -> 1 end]}})

    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> DragonexWeb.UserAuth.log_in(user)
    {:ok, view, _} = live(conn, "/games/#{game.id}")
    assert has_element?(view, ".detail [data-resource=spell-slot-1]", "2 disponibles")

    assert :ok = Game.resume(pid)
    assert :ok = Game.await_turn(pid, card.name)
    assert {:ok, :resolving} = Game.declare(pid, card.name, "Lanzo Proyectil mágico")
    assert :ok = Game.await(pid, &(&1.world.spell_slots[card.name][1] == 1))
    assert has_element?(view, ".detail [data-resource=spell-slot-1]", "1 disponible")
    assert :ok = Game.pause(pid)
    {:ok, reloaded, _} = live(conn, "/games/#{game.id}")
    assert has_element?(reloaded, ".detail [data-resource=spell-slot-1]", "1 disponible")
  end
end
