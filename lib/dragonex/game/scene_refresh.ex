defmodule Dragonex.Game.SceneRefresh do
  @moduledoc """
  A bounded, read-only scene recorder after an exploration DM beat. Its only
  output is a surroundings snapshot; Game applies it through Session before
  settling the turn. Also reviews literal human movement when the DM omits
  set_scene. Failed recording never retries already committed rules.
  """
  use Gettext, backend: Dragonex.Gettext
  require Logger
  alias Dragonex.{AgentInstructions, Brief, Games, History, Text, World}
  alias Dragonex.Game.{Participants, ToolReplay}
  alias ExAgent.Session

  defmodule Output do
    @moduledoc false
    use Ecto.Schema
    use Gettext, backend: Dragonex.Gettext
    import Ecto.Changeset
    @primary_key false
    embedded_schema do
      field(:scene, :string)
    end

    def changeset(output, attrs) do
      output
      |> cast(attrs, [:scene])
      |> validate_required([:scene])
      |> validate_length(:scene, min: 1, max: 1200)
      |> validate_format(:scene, ~r/[.!…]\z/u,
        message: dgettext("prompts", "termina la descripción con una frase completa")
      )
    end
  end

  # Runtime text: the table locale decides the language (D236).
  defp instructions do
    dgettext("prompts", """
    Registra una instantánea breve del entorno ACTUAL ya establecido, en español.
    Devuelve obligatoriamente final_result con el campo scene; no uses texto libre.
    Solo resumes el lugar y la situación después de lo que ya ocurrió: prevalecen
    los hechos canónicos, el estado del motor y las decisiones/narración recientes
    sobre el registro antiguo. No reintroduzcas encargos cerrados. No añadas
    sucesos, peligros, recompensas ni encargos. No adelantes tiempo ni trama.
    Describe exclusivamente el entorno; omite acciones, pensamientos, diálogo y
    traslados de los PCs o del grupo. No decidas por ellos. No resuelvas reglas,
    dados, curaciones ni recursos: no tienes herramientas para ello. No repitas
    el descanso ya aplicado. No incluyas preguntas ni instrucciones al jugador.
    Máximo 1200 caracteres, preferiblemente dos o tres frases.
    Omite nombres de PCs y sujetos como «los tres», «los compañeros» o «el grupo».
    Termina la descripción con punto; no dejes ninguna frase cortada.
    El registro es una referencia del lugar, sus objetos y condiciones físicas,
    no un resumen del último turno. No registres diálogos de PNJ, preguntas
    pendientes, ofertas o rumores como parte del decorado. Omite también sus
    gestos pasajeros y comparaciones sobre lo que parecen pensar o esperar.
    El historial conserva la conversación y los hechos canónicos conservan
    los datos duraderos: no los sustituyas por una pose en la escena.
    Si el registro anterior mezcla entorno y conversación, conserva los detalles
    físicos establecidos y omite esa conversación al actualizarlo. No inventes
    objetos, cantidades ni estados de consumo a partir del mero paso del tiempo.
    El inventario del motor tiene prioridad sobre el decorado antiguo: no dejes
    en el suelo un objeto cuya recogida ya se confirmó. Conserva la situación
    física establecida tras entregas y retiradas, sin inventar otras unidades.
    Si solo cambió lo transportado y el entorno sigue igual, confirma devolviendo
    exactamente la escena actual; no añadas decoración para forzar una diferencia.
    """)
  end

  def after_beat(state, participant, game_owner \\ nil, opts \\ [])

  def after_beat(state, "dm", game_owner, opts) do
    world = Session.read_state(state.session)

    if world.phase == :exploration do
      pending? = Map.get(world, :scene_refresh_pending, false)
      events = Games.recent_events(state.game_id, 40)
      local? = not pending? and local_review?(state, world, events)

      if pending? or local? do
        model = Map.get(state, :scene_model) || state.model

        request =
          Keyword.get(opts, :wait_resolution) ||
            Dragonex.Game.WaitResolution.review_request(world, events)

        recorder_opts = [
          game_owner: game_owner,
          allow_unchanged: local?,
          wait_before: Keyword.get(opts, :wait_before),
          wait_resolution: request
        ]

        # Runtime progress only: the owning Game verifies the live Task and
        # turn before updating its snapshot. No World/event mutation here.
        if is_pid(game_owner) and is_binary(opts[:turn_id]) do
          send(game_owner, {:scene_review_started, self(), opts[:turn_id]})
        end

        case propose(model, world, events, recorder_opts) do
          {:error, reason} when local? -> {:review_failed, world, reason}
          result -> result
        end
      else
        :skip
      end
    else
      :skip
    end
  end

  def after_beat(_state, _participant, _game_owner, _opts), do: :skip

  # This signal requests a read-only check, never a relocation or a rules
  # result. Deliberately bounded to affirmative first-person declarations;
  # proposals, questions, quotes and other characters keep their own route.
  @movement_declared ~r/^(?:(?:agradezco|me\s+despido|saludo|doy\s+las\s+gracias)\b[^.!?¿:«»"“”]{0,120},\s*)?(?:yo\s+)?(?:entro|salgo|cruzo|subo|bajo|camino|avanzo|sigo|me\s+(?:acerco|dirijo|adentro|alejo))\s+(?:a|al|en|hacia|hasta|por|de|del|junto\s+a)\b/iu

  def movement_declared?(text) when is_binary(text),
    do: Regex.match?(@movement_declared, String.trim(text))

  def movement_declared?(_), do: false

  defp local_review?(state, world, events) do
    actor = state.last_actor

    if Participants.human?(state, actor) and not Participants.ai_pc?(state, actor) and
         world.conversation == nil and not state.tm_reeval and not state.pending_mini and
         not state.last_was_mini and state.interrupted in [nil, ""] and
         not scene_recorded?(world) do
      recent = Enum.reverse(events)
      action = Enum.find(recent, &(&1.type == :action))
      turn = Enum.find(recent, &(&1.type == :turn and &1.actor == actor))

      action != nil and turn != nil and action.actor == actor and
        action.payload["turn_id"] == turn.payload["turn_id"] and
        action.payload["scene_before"] == world.scene and
        movement_declared?(action.payload["text"])
    else
      false
    end
  end

  defp scene_recorded?(world) do
    case ToolReplay.restore(world, "dm") do
      %{tool_results: results} -> Enum.any?(results, fn {{name, _}, _} -> name == "set_scene" end)
      _ -> false
    end
  end

  def propose(model, world, events, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 20_000)
    deps = %{game_owner: Keyword.get(opts, :game_owner), beat_owner: self()}

    agent =
      ExAgent.new(
        model: model,
        name: "scene_recorder",
        instructions: instructions() <> wait_confirmation_instruction(world, opts),
        output: Output,
        tools: [],
        max_steps: 2,
        output_retries: 1,
        model_settings:
          Dragonex.Models.request_settings(
            model,
            [
              max_tokens: 1024,
              temperature: 0,
              timeout: timeout
            ],
            Dragonex.Models.request_extra()
          ),
        capabilities: Dragonex.Agent.capabilities([Dragonex.Game.RunLifecycle, AgentInstructions])
      )

    table_locale = Dragonex.I18n.locale()

    task =
      Task.Supervisor.async_nolink(ExAgent.TaskSupervisor, fn ->
        # Tasks do not inherit the table language (D236).
        Dragonex.I18n.put_locale(table_locale)

        ExAgent.run(
          agent,
          dgettext("prompts", "Registra el entorno después del último beat.") <>
            "\n" <> Brief.world_brief(world, "dm"),
          deps: deps,
          message_history: History.import_events(events)
        )
      end)

    result = Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)

    case result do
      {:ok, {:ok, %{output: %Output{scene: text}, usage: usage}}} ->
        same? = Text.scrub(text) == world.scene

        cond do
          same? and clock_only_wait?(world, opts) ->
            {:unchanged_wait, world, Keyword.get(opts, :wait_before),
             Keyword.fetch!(opts, :wait_resolution), usage}

          same? and inventory_only_review?(world) ->
            {:unchanged_inventory, world, usage}

          same? and Keyword.get(opts, :allow_unchanged, false) and
              not world.scene_refresh_pending ->
            :skip

          true ->
            with {:ok, scene} <- validate(world, text), do: {:ok, world, scene, usage}
        end

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:exit, _} ->
        {:error, :recorder_crashed}

      nil ->
        {:error, :timeout}
    end
  rescue
    _ -> {:error, :recorder_failed}
  catch
    :exit, _ -> {:error, :recorder_failed}
  end

  defp wait_confirmation_instruction(world, opts) do
    if clock_only_wait?(world, opts) do
      "\n" <>
        dgettext(
          "prompts",
          "CONFIRMACIÓN DE ENTORNO TRAS ESPERA: el comprobante del motor conserva el estado " <>
            "establecido anterior a esta espera. Si los eventos recientes no cambian el entorno, " <>
            "confirma devolviendo EXACTAMENTE la escena actual. El paso del tiempo por sí solo " <>
            "no exige reescribir la descripción. Si hay un cambio de entorno establecido, regístralo."
        )
    else
      ""
    end
  end

  defp inventory_only_review?(world) do
    case ToolReplay.restore(world, "dm") do
      %{
        inventory_scene_before: %{"pending" => false, "fingerprint" => before},
        tool_results: tools
      } ->
        world.phase == :exploration and world.scene_refresh_pending and
          is_binary(before) and before == Dragonex.Rules.Inventory.scene_fingerprint(world) and
          Enum.all?(tools, fn {{name, _}, _} ->
            name in [
              "grant_item",
              "remove_item",
              "confirm_inventory_unchanged",
              "record_item_round_trip",
              "confirm_no_inventory_transfer"
            ]
          end)

      _ ->
        false
    end
  end

  # Time requests a review even when furniture and surroundings stay put.
  # An exact baseline plus this interval's receipt allows confirmation. A
  # previously pending scene, facts/resources/movement or further time still
  # need a fresh snapshot. Do not infer this permission from a clock alone.
  defp clock_only_wait?(world, opts) do
    case Keyword.get(opts, :wait_resolution) do
      %{source_turn_id: source, seconds: seconds, clock_before: start} ->
        receipt = Map.get(world, :wait_resolution) || %{}

        world.phase == :exploration and world.scene_refresh_pending and
          is_binary(source) and source != "" and is_integer(seconds) and seconds > 0 and
          is_integer(start) and start >= 0 and receipt["source_turn_id"] == source and
          receipt["declared_seconds"] == seconds and receipt["clock_before"] == start and
          receipt["clock_after"] == world.elapsed_seconds and
          is_integer(receipt["elapsed_seconds"]) and receipt["elapsed_seconds"] > 0 and
          receipt["elapsed_seconds"] <= seconds and
          receipt["elapsed_seconds"] == world.elapsed_seconds - start and
          unchanged_wait_state?(world, Keyword.get(opts, :wait_before), receipt, start)

      _ ->
        false
    end
  end

  defp unchanged_wait_state?(world, before, receipt, start) do
    fingerprint = receipt["scene_review_fingerprint"]
    durable = is_binary(fingerprint) and fingerprint == World.scene_review_fingerprint(world)

    # Legacy receipts can be confirmed only while the actual clean baseline
    # remains available. They gain no invented fingerprint on rehydrate.
    in_memory =
      case before do
        %World{phase: :exploration, scene_refresh_pending: false, elapsed_seconds: ^start} ->
          World.scene_review_fingerprint(world) == World.scene_review_fingerprint(before)

        _ ->
          false
      end

    durable or in_memory
  end

  defp validate(world, text) do
    scene = Text.scrub(text)
    pcs = for {name, %{side: "pc"}} <- world.characters, do: name

    cond do
      scene == "" ->
        {:error, :empty_scene}

      scene == world.scene ->
        {:error, :unchanged_scene}

      Regex.match?(
        ~r/\b(?:los|las)\s+(?:dos|tres|cuatro|cinco|seis)\s+(?:ya\s+)?(?:pasan|cruzan|avanzan|parten|salen|entran|deciden|aceptan|caminan)\b/iu,
        scene
      ) ->
        {:error, :pc_agency}

      Text.puppets_pc?(scene, "dm", pcs, Map.keys(world.characters)) ->
        {:error, :pc_agency}

      true ->
        {:ok, scene}
    end
  end

  # Called only inside Game. Revalidate the snapshot against the current World:
  # a concurrent hero sync or control action cannot be overwritten by old data.
  def commit(state, {:ok, expected, scene, _usage}) do
    current = Session.current(state.session)

    result =
      Session.update_state(state.session, current, fn world ->
        if world == expected do
          with {:ok, scene} <- validate(world, scene), do: World.refresh_scene(scene).(world)
        else
          {:error, "scene snapshot changed"}
        end
      end)

    if match?({:error, _}, result), do: log_pending(state, :stale_snapshot)
    state
  end

  def commit(state, :skip), do: state

  def commit(state, {:unchanged_inventory, expected, _usage}) do
    current = Session.current(state.session)

    result =
      Session.update_state(state.session, current, fn world ->
        if world == expected and inventory_only_review?(world),
          do: {:ok, %{world | scene_refresh_pending: false}},
          else: {:error, "scene snapshot changed"}
      end)

    if match?({:error, _}, result), do: log_pending(state, :stale_snapshot)
    state
  end

  def commit(state, {:unchanged_wait, expected, before, request, _usage}) do
    current = Session.current(state.session)

    result =
      Session.update_state(state.session, current, fn world ->
        if world == expected and
             clock_only_wait?(world, wait_before: before, wait_resolution: request),
           do: {:ok, %{world | scene_refresh_pending: false}},
           else: {:error, "scene snapshot changed"}
      end)

    if match?({:error, _}, result), do: log_pending(state, :stale_snapshot)
    state
  end

  def commit(state, {:review_failed, expected, reason}) do
    current = Session.current(state.session)

    result =
      Session.update_state(state.session, current, fn world ->
        if world == expected,
          do: {:ok, %{world | scene_refresh_pending: true}},
          else: {:error, "scene snapshot changed"}
      end)

    log_pending(state, if(match?({:error, _}, result), do: :stale_snapshot, else: reason))
    state
  end

  def commit(state, {:error, reason}) do
    log_pending(state, reason)
    state
  end

  defp log_pending(state, reason) do
    label =
      case reason do
        tag when tag in [:timeout, :pc_agency, :empty_scene, :unchanged_scene, :stale_snapshot] ->
          tag

        {:max_tokens_exceeded, _} ->
          :max_tokens

        {:max_steps_exceeded, _} ->
          :max_steps

        {:model_request_failed, _} ->
          :provider_error

        _ ->
          :invalid_result
      end

    Logger.info(
      "dragonex game #{state.game_id}: scene recording pending (#{label}); committed actions retained"
    )
  end
end
