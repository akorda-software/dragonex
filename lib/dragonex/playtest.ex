defmodule Dragonex.Playtest do
  @moduledoc """
  Arnés de playtest sin interfaz: crea una mesa como el asistente (héroe humano +
  compañeros IA), arranca su `Game` y deja que un **jugador bot** escriba las
  declaraciones del humano cuando le toca. Así se juegan partidas reales contra
  el proveedor configurado y se miden con `Dragonex.Playtest.Metrics`.

  El jugador bot no es un PCAgent: escribe texto libre como lo haría una persona
  en el cuadro de declaración, de modo que se ejercita el mismo camino que la
  mesa web (`Game.declare/3` → resolutor del TurnMaster). Usa el modelo barato
  (`Models.summarizer/0`) con los eventos públicos recientes como contexto.

  Si la mesa se pausa por un fallo (D228), el arnés la reanuda como haría el
  creador, hasta `max_resumes` veces; cada pausa queda en las métricas.

  Cuesta dinero: cada declaración dispara beats del DM, del TurnMaster y de los
  PCs IA contra el proveedor real. Sin API key, los beats usan `TestModel` y el
  arnés no aporta información.
  """

  require Logger

  alias Dragonex.{Game, Games}
  alias Dragonex.Playtest.{Metrics, Player}

  @poll_ms 500

  @scenarios %{
    "mill" => %{
      es: %{
        title: "Playtest — El libro del molino",
        scene:
          "Mira, la molinera, espera en la puerta del viejo molino del arroyo. Pide recuperar el libro de cuentas de su difunto marido, guardado en un arcón azul del altillo. Dentro, dos ratas gigantes hostiles merodean entre los sacos de harina",
        dm_style:
          "Aventura breve en español. Solo hay dos ratas gigantes (giant rat) hostiles dentro del molino, sin otras amenazas ni giros: registra sus fichas e iniciativa antes de la pelea y respeta el orden del motor. Mira sabe que el libro está en el arcón azul del altillo y que la escalera cruje; no sabe nada más. Los PCs deciden individualmente. No adelantes recogida, entrega ni viajes. El libro entra en el inventario solo al recogerlo y sale al entregárselo a Mira; entonces cierra el encargo. Narra en pocas frases.",
        goal: "Recuperar el libro de cuentas del altillo y entregárselo a Mira."
      },
      en: %{
        title: "Playtest — The mill ledger",
        scene:
          "Mira, the miller, waits at the door of the old mill by the brook. She asks the party to recover her late husband's ledger, kept in a blue chest in the loft. Inside, two hostile giant rats prowl among the flour sacks",
        dm_style:
          "Short adventure in English. There are only two hostile giant rats (giant rat) inside the mill, no other threats or twists: register their sheets and initiative before the fight and follow the engine order. Mira knows the ledger is in the blue chest in the loft and that the ladder creaks; she knows nothing more. The PCs decide individually. Do not jump ahead to pickup, delivery or travel. The ledger enters the inventory only when picked up and leaves it when handed to Mira; then close the errand. Narrate in a few sentences.",
        goal: "Recover the ledger from the loft and hand it to Mira."
      }
    }
  }

  @doc "Escenarios propios del arnés (además de los del catálogo de `Scenarios`)."
  def scenario_keys, do: Map.keys(@scenarios) ++ Enum.map(Dragonex.Scenarios.all(), & &1.key)

  @doc """
  Juega una partida y devuelve `%{game_id, declarations, resumes, stop, metrics}`.

  Opciones: `:scenario` (`"mill"` o una clave de `Scenarios`), `:locale`
  (`:es | :en`), `:hero` (clave del catálogo, por defecto `"fighter"`),
  `:companions` (por defecto `["wizard", "rogue"]`), `:turns` (declaraciones
  humanas, 8), `:minutes` (tope de reloj, 15), `:max_resumes` (3), `:goal`
  (objetivo que persigue el jugador bot), `:on_event` (callback de progreso) y,
  para tests, `:player` (`(context -> {:ok, text} | {:error, term})`) y
  `:game_opts` (opciones de `Game.ensure_started/2`, p. ej. `model:`).
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    locale = Keyword.get(opts, :locale, :es)
    {:ok, game} = create_game(opts, locale)
    {:ok, pid} = Game.ensure_started(game.id, Keyword.get(opts, :game_opts, []))
    human = human_name(game.id)

    Logger.info("playtest: partida #{game.id}, humano #{human}, modelo #{model_name(pid)}")

    loop_state = %{
      pid: pid,
      game_id: game.id,
      human: human,
      locale: locale,
      goal: Keyword.get(opts, :goal) || scenario_goal(opts, locale),
      player: Keyword.get(opts, :player, &Player.declare/1),
      turns: Keyword.get(opts, :turns, 8),
      max_resumes: Keyword.get(opts, :max_resumes, 3),
      deadline:
        System.monotonic_time(:millisecond) + round(Keyword.get(opts, :minutes, 15) * 60_000),
      declarations: 0,
      resumes: 0,
      pending_check: nil,
      inventory_checks: [],
      on_event: Keyword.get(opts, :on_event, fn _ -> :ok end)
    }

    {stop, final} = loop(loop_state)
    _ = Game.pause(pid)
    final = close_check(final, Game.world(pid))

    %{
      game_id: game.id,
      declarations: final.declarations,
      resumes: final.resumes,
      stop: stop,
      metrics: Metrics.analyze(Games.list_events(game.id), [human]),
      inventory_checks: Enum.reverse(final.inventory_checks)
    }
  end

  # ------------------------------------------------------------ bucle

  defp loop(s) do
    if System.monotonic_time(:millisecond) > s.deadline do
      {:deadline, s}
    else
      snap = Game.snapshot(s.pid)
      step(snap, s)
    end
  end

  defp step(%{status: :ended}, s), do: {:ended, s}

  defp step(%{status: :paused}, %{resumes: r, max_resumes: r} = s), do: {:paused, s}

  defp step(%{status: :paused}, s) do
    s.on_event.({:resume, s.resumes + 1})
    _ = Game.resume(s.pid)
    loop(%{s | resumes: s.resumes + 1})
  end

  # The final declaration has the same recovery and deadline budget as every
  # earlier one. Reaching the requested count only completes the run once the
  # table actually gives the human the floor again; a pause is not success.
  defp step(
         %{status: :waiting, current: human},
         %{human: human, declarations: n, turns: n} = s
       ),
       do: {:turns_reached, s}

  defp step(%{status: :waiting, current: human, events: events} = snap, %{human: human} = s) do
    s = close_check(s, snap.world)

    context = %{
      name: human,
      locale: s.locale,
      goal: s.goal,
      phase: snap.world.phase,
      sheet: Map.get(snap.world.characters, human),
      events: events
    }

    case s.player.(context) do
      {:ok, text} ->
        s.on_event.({:declare, human, text})
        s = open_check(s, text, snap.world)
        {:ok, _} = Game.declare(s.pid, human, text)
        wait_until_not_current(s)
        loop(%{s | declarations: s.declarations + 1})

      {:error, reason} ->
        {{:player_failed, reason}, s}
    end
  end

  defp step(_snap, s) do
    Process.sleep(@poll_ms)
    loop(s)
  end

  # Recogidas y entregas declaradas: ¿cambió el inventario del humano antes de
  # volver a tener la palabra? El motor no deja rastro del cambio en eventos,
  # así que se compara el stock al declarar con el del siguiente turno propio.
  defp open_check(s, text, world) do
    case Dragonex.InventoryDeclaration.kind(text, s.locale) do
      nil -> s
      kind -> %{s | pending_check: %{text: text, kind: kind, before: inventory(world, s.human)}}
    end
  end

  defp close_check(%{pending_check: nil} = s, _world), do: s

  defp close_check(%{pending_check: check} = s, world) do
    after_ = inventory(world, s.human)
    result = %{text: check.text, kind: check.kind, changed: after_ != check.before, after: after_}
    %{s | pending_check: nil, inventory_checks: [result | s.inventory_checks]}
  end

  defp inventory(world, who) do
    case Map.get(world.characters, who) do
      %{inventory: items} when is_list(items) ->
        items |> Enum.map(&{Map.get(&1, :name), Map.get(&1, :qty)}) |> Enum.sort()

      _ ->
        []
    end
  end

  # Tras declarar, el Game puede tardar un instante en marcar el beat.
  defp wait_until_not_current(s) do
    Game.await(s.pid, fn snap -> snap.status != :waiting or snap.current != s.human end, 10_000)
  end

  # ------------------------------------------------------------ partida

  defp create_game(opts, locale) do
    key = Keyword.get(opts, :scenario, "mill")
    hero = Keyword.get(opts, :hero, "fighter")
    companions = Keyword.get(opts, :companions, ["wizard", "rogue"])

    base = %{my_hero: hero, companions: companions, locale: locale, user_id: nil}

    choices =
      case @scenarios[key] do
        %{^locale => sc} ->
          Map.merge(base, %{
            scenario: %{key: "custom"},
            custom_title: sc.title,
            custom_scene: sc.scene,
            custom_dm_style: sc.dm_style
          })

        nil ->
          scenario =
            Dragonex.Scenarios.get(key) || raise ArgumentError, "escenario desconocido: #{key}"

          Map.put(base, :scenario, scenario)
      end

    Games.create_from_wizard_choices(choices)
  end

  defp scenario_goal(opts, locale) do
    case @scenarios[Keyword.get(opts, :scenario, "mill")] do
      %{^locale => %{goal: goal}} -> goal
      _ -> nil
    end
  end

  defp human_name(game_id) do
    game_id
    |> Games.get_game()
    |> Map.fetch!(:participants)
    |> Enum.find(&(&1.kind == :human))
    |> Map.fetch!(:name)
  end

  # The model the table really plays with (house, own key or injected).
  defp model_name(pid) do
    ExAgent.Model.model_name(:sys.get_state(pid).model)
  rescue
    _ -> "?"
  end
end
