defmodule Dragonex.Tools do
  @moduledoc """
  The game's model-callable tools. Built with `use ExAgent.Tools`, so each
  tool's JSON Schema is derived from its `::` type annotations.

  Every tool reads what it needs from `ctx.deps`, which is a map bundling:
    * `:state` — the ExAgent.Session.SharedState handle (propose world changes)
    * `:roller` — a (sides -> value) dice fn (injected so tests are deterministic)
  """

  use ExAgent.Tools
  use Gettext, backend: Dragonex.Gettext
  require Logger

  @doc "Tools advertised to live agents, with genuinely optional spell arguments."
  def agent_tools do
    Enum.map(tools(), fn
      %{name: "record_item_round_trip"} = tool ->
        schema = tool.parameters_json_schema

        properties =
          schema.properties
          |> Map.update!("item", &Map.merge(&1, %{minLength: 1, maxLength: 160}))
          |> Map.update!("quantity", &Map.merge(&1, %{minimum: 1, maximum: 9999}))
          |> Map.update!("counterparty", &Map.merge(&1, %{minLength: 1, maxLength: 80}))
          |> Map.update!("direction", &Map.put(&1, :enum, ["borrow_return", "lend_return"]))

        %{tool | parameters_json_schema: %{schema | properties: properties}}

      %{name: "confirm_no_inventory_transfer"} = tool ->
        schema = tool.parameters_json_schema

        properties =
          schema.properties
          |> Map.update!(
            "outcome",
            &Map.put(&1, :enum, ["declined", "not_available", "look_only"])
          )
          |> Map.update!("reason", &Map.merge(&1, %{minLength: 1, maxLength: 400}))

        %{tool | parameters_json_schema: %{schema | properties: properties}}

      %{name: name} = tool when name in ["grant_item", "remove_item"] ->
        schema = tool.parameters_json_schema

        properties =
          schema.properties
          |> optional_additional(name)
          |> nullable_counterparty(name)
          |> Map.update!(
            "item",
            &Map.merge(&1, %{minLength: 1, maxLength: Dragonex.Rules.Inventory.max_name()})
          )
          |> Map.update!(
            "quantity",
            &Map.merge(&1, %{minimum: 1, maximum: Dragonex.Rules.Inventory.max_quantity()})
          )

        required = schema.required -- ["additional", "source"]
        %{tool | parameters_json_schema: %{schema | properties: properties, required: required}}

      %{name: "record_npc_statement"} = tool ->
        schema = tool.parameters_json_schema

        properties =
          schema.properties
          |> Map.update!(
            "speaker",
            &Map.merge(&1, %{minLength: 1, maxLength: Dragonex.NPCStatement.max_speaker()})
          )
          |> Map.update!(
            "statement",
            &Map.merge(&1, %{minLength: 1, maxLength: Dragonex.NPCStatement.max_statement()})
          )

        %{tool | parameters_json_schema: %{schema | properties: properties}}

      %{name: "cast_spell"} = tool ->
        # exAgent derives every argument as required and non-nullable. The
        # bridge accepts omitted arguments, so advertise that same contract
        # rather than making a model invent a selection for every spell.
        schema = tool.parameters_json_schema

        properties =
          schema.properties
          |> Map.update!("cast_level", &Map.put(&1, :type, ["integer", "null"]))
          |> Map.update!("additional_targets", &Map.put(&1, :type, ["array", "null"]))
          |> Map.put("condition_to_remove", %{
            anyOf: [
              %{
                type: ["string", "null"],
                enum: [nil, "blinded", "deafened", "paralyzed", "poisoned", "diseased"]
              },
              %{type: "string", pattern: "^\\s*$"}
            ]
          })

        required = schema.required -- ~w(cast_level additional_targets condition_to_remove)
        %{tool | parameters_json_schema: %{schema | properties: properties, required: required}}

      %{name: name} = tool
      when name in [
             "short_rest",
             "lay_on_hands",
             "make_attack",
             "ability_check",
             "action_surge",
             "flurry_of_blows"
           ] ->
        field =
          case name do
            "short_rest" -> "hit_dice"
            "lay_on_hands" -> "conditions_to_remove"
            _ -> "mode"
          end

        schema = tool.parameters_json_schema

        properties =
          Map.update!(
            schema.properties,
            field,
            &Map.update!(&1, :type, fn type -> [type, "null"] end)
          )

        %{
          tool
          | parameters_json_schema: %{
              schema
              | properties: properties,
                required: schema.required -- [field]
            }
        }

      %{name: "request_response"} = tool ->
        schema = tool.parameters_json_schema

        properties =
          schema.properties
          |> Map.update!(
            "recipients",
            &Map.merge(&1, %{
              minItems: 1,
              maxItems: Dragonex.Conversation.max_recipients(),
              uniqueItems: true
            })
          )
          |> Map.update!(
            "question",
            &Map.merge(&1, %{minLength: 1, maxLength: Dragonex.Conversation.max_question()})
          )

        %{tool | parameters_json_schema: %{schema | properties: properties}}

      tool ->
        tool
    end)
    |> Enum.map(&Dragonex.Game.ToolReplay.wrap/1)
    |> Enum.map(fn tool ->
      original = tool.call

      %{
        tool
        | call: fn ctx, args ->
            Dragonex.I18n.adopt(ctx.deps)

            case original.(ctx, args) do
              {:error, message} when is_binary(message) ->
                raise ExAgent.ModelRetry, retry_guidance(message)

              result ->
                result
            end
          end
      }
    end)
  end

  defp optional_additional(properties, "grant_item"),
    do: Map.update!(properties, "additional", &Map.put(&1, :type, ["boolean", "null"]))

  defp optional_additional(properties, _), do: properties

  defp nullable_counterparty(properties, name) do
    field = if name == "grant_item", do: "source", else: "recipient"

    Map.update!(
      properties,
      field,
      &Map.merge(&1, %{
        type: ["string", "null"],
        minLength: 1,
        maxLength: Dragonex.Game.InventoryMovement.max_counterparty()
      })
    )
  end

  # 19451/26–30: a declared attack on a narrated creature without a sheet led
  # the manual resolver to retry spawn_monster until the turn failed.
  defp unregistered_target do
    dgettext(
      "engine",
      "Usa un nombre canónico del estado. Una criatura sin ficha solo la registra " <>
        "el DM con spawn_monster; si resuelves la acción de un PC, no la crees ni " <>
        "la ataques: cierra con una confirmación breve y el DM la registrará."
    )
  end

  # The missing-target prefix may come from a converted message (active
  # locale) or from one still emitted in Spanish.
  defp retry_guidance(message) do
    missing = ["no existe el objetivo", dgettext("engine", "no existe el objetivo")]

    if String.starts_with?(message, missing),
      do: message <> ". " <> unregistered_target(),
      else: message
  end

  @doc """
  Acting PC only, exploration only: ask named present companions for their own
  responses. Call when the player's declaration explicitly asks other PCs a
  question, then narrate only the questioner's words. Recipients get one turn
  each in the supplied order; never invent their answers. No rolls or resources.
  If the engine already registered the human question, do not call again or
  replace that pending conversation; narrate only the questioner's words.
  Do not call for a PNJ, the DM, a mere mention, or while answering a request.
  """
  deftool request_response(ctx, recipients :: [String.t()], question :: String.t()) do
    from = ctx.deps.state.participant_id
    registered = ExAgent.Session.participants(ctx.deps.state.session) |> Enum.map(& &1.id)

    if is_list(recipients) and Enum.all?(recipients, &(&1 in registered)) do
      with {:ok, _} <- propose(ctx, Dragonex.Conversation.request(from, recipients, question)) do
        {:ok,
         dgettext(
           "engine",
           "Pregunta registrada. %{recipients} responderán por sí mismos; no narres sus respuestas.",
           recipients: Enum.join(recipients, ", ")
         )}
      end
    else
      {:error,
       dgettext("engine", "Usa solo nombres canónicos de PCs participantes: %{names}.",
         names: Enum.join(registered -- ["dm", from], ", ")
       )}
    end
  end

  @doc "DM only: update the confirmed current surroundings. Do not invent actions or relocation for PCs; each decides on their own turn."
  deftool set_scene(ctx, narration :: String.t()) do
    with :ok <- assert_world_narrator(ctx) do
      # Model text reaching persistent world state must be scrubbed (D7): a scene
      # is echoed to every agent every turn, so scrubbing closes a prompt-injection
      # amplifier.
      scene = Dragonex.Text.scrub(narration)
      world = world(ctx)
      actor = ctx.deps.state.participant_id
      pcs = for {name, %{side: "pc"}} <- world.characters, do: name

      cond do
        scene == "" ->
          {:error,
           dgettext(
             "engine",
             "RECHAZADO — describe una escena con contenido; no borres el entorno actual."
           )}

        Dragonex.Text.puppets_pc?(scene, actor, pcs, Map.keys(world.characters)) ->
          {:error,
           dgettext(
             "engine",
             "RECHAZADO — no decidas acciones ni traslados de otros PCs o del grupo. " <>
               "Describe el entorno sin moverlos; cada PC decide y actúa en su turno."
           )}

        true ->
          with {:ok, _} <- propose(ctx, Dragonex.World.set_scene(scene)) do
            {:ok, dgettext("engine", "escena establecida")}
          end
      end
    end
  end

  @doc """
  DM only: record a confirmed durable narrative fact, written in the language of
  the game ("A Council messenger delivered a scroll", "Thane found a hidden
  door"). Facts persist in the world and are shown
  to every agent each turn, so the partida's concrete state survives history
  truncation and hooks don't get dropped or re-introduced. Call this whenever you
  introduce or reveal something concrete the party should remember.
  Use this for established world events. For an NPC's report, rumor, promise or
  uncertain claim, use record_npc_statement so its source remains explicit.
  """
  deftool establish_fact(ctx, fact :: String.t()) do
    with :ok <- assert_world_narrator(ctx) do
      # Facts are canonical world state surfaced to every agent each turn — scrub
      # before persisting so a tainted fact can't poison all future contexts (D7).
      fact = Dragonex.Text.scrub(fact)
      world = world(ctx)
      actor = ctx.deps.state.participant_id
      pcs = for {name, %{side: "pc"}} <- world.characters, do: name

      if Dragonex.Text.puppets_pc?(fact, actor, pcs, Map.keys(world.characters)) do
        {:error,
         dgettext(
           "engine",
           "RECHAZADO — no registres decisiones ni acciones de otros PCs o del grupo. " <>
             "Registra el entorno o hechos establecidos; cada PC decide y actúa en su turno."
         )}
      else
        with {:ok, _} <- propose(ctx, Dragonex.World.add_fact(fact)) do
          {:ok, dgettext("engine", "hecho registrado")}
        end
      end
    end
  end

  defp assert_world_narrator(ctx) do
    if ctx.deps.state.participant_id == "dm" do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo el DM confirma escenas y registra hechos canónicos del mundo. " <>
           "Resuelve tus reglas y describe tu intención u observación; espera la confirmación del DM."
       )}
    end
  end

  @doc """
  DM only: remember a durable NPC statement before narrating it. Supply the
  NPC's name or role and the short claim, preserving uncertainty and who told
  them. The engine stores attributed testimony, not a confirmed world fact.
  Use for clues, reported sightings, rumors and promises the party may recall.
  The engine stamps the first recording with the world clock. Repeating the
  same claim preserves that reference; do not invent dates for old testimony.
  Do not use for transient gestures or repeat unchanged testimony each turn.
  It never moves characters, grants rewards, confirms a rumor or advances time.
  """
  deftool record_npc_statement(ctx, speaker :: String.t(), statement :: String.t()) do
    if ctx.deps.state.participant_id == "dm" do
      with :ok <- Dragonex.Game.NPCMemoryResolution.validate_speaker(ctx.deps, speaker),
           {:ok, _} <- propose(ctx, Dragonex.World.record_npc_statement(speaker, statement)) do
        {:ok,
         dgettext(
           "engine",
           "Testimonio registrado con su fuente; el contenido no se considera confirmado."
         )}
      else
        {:error, reason} = error ->
          # A rejected source exhausts the model's retries without a trace
          # otherwise; keep the offending value in the server log.
          Logger.info(
            "record_npc_statement rejected speaker=#{inspect(String.slice(speaker, 0, 120))}: " <>
              inspect(reason)
          )

          error
      end
    else
      {:error,
       dgettext(
         "engine",
         "Solo el DM registra testimonios de PNJ; no hables por ellos como un PC."
       )}
    end
  end

  @doc """
  DM only: record that an existing non-PC has left the scene. Does not roll or
  decide an escape: resolve applicable actions/checks first. Preserves the
  creature's HP/resources, ends its concentration and removes active targeting
  and initiative. A narration or generic check alone does not remove it.
  """
  deftool leave_scene(ctx, who :: String.t(), reason :: String.t()) do
    with :ok <- assert_scene_presence(ctx),
         :proceed <- already_absent(ctx, who),
         {:ok, _} <- propose(ctx, Dragonex.World.leave_scene(who, reason)) do
      {:ok,
       dgettext(
         "engine",
         "%{who} está fuera de escena; conserva su ficha y no es un objetivo presente.",
         who: who
       )}
    end
  end

  @doc "DM only: bring an absent creature back with its stored HP/resources. Combat reinforcements join at the end; never spawn a fresh copy of the same name."
  deftool return_to_scene(ctx, who :: String.t()) do
    with :ok <- assert_scene_presence(ctx),
         :proceed <- already_present(ctx, who),
         {:ok, _} <- propose(ctx, Dragonex.World.return_to_scene(who)) do
      {:ok, dgettext("engine", "%{who} vuelve a la escena con su ficha conservada.", who: who)}
    end
  end

  # The scene already is what the DM asks for: say so instead of rejecting.
  # A rejection here only made the DM retry until the beat failed (game 19466).
  defp already_absent(ctx, who) do
    world = world(ctx)

    case is_binary(who) && Dragonex.World.character(world, who) do
      %Dragonex.Character{side: side} when side != "pc" ->
        if Dragonex.World.present?(world, who),
          do: :proceed,
          else:
            {:ok,
             dgettext(
               "engine",
               "%{who} ya estaba fuera de escena; no hace falta registrarlo otra vez.",
               who: who
             )}

      _ ->
        :proceed
    end
  end

  defp already_present(ctx, who) do
    world = world(ctx)

    if is_binary(who) and Dragonex.World.character(world, who) != nil and
         Dragonex.World.present?(world, who),
       do:
         {:ok, dgettext("engine", "%{who} ya está en escena; no hace falta traerlo.", who: who)},
       else: :proceed
  end

  defp assert_scene_presence(ctx) do
    if ctx.deps.state.participant_id == "dm",
      do: :ok,
      else:
        {:error,
         dgettext("engine", "RECHAZADO — solo el DM registra salidas y retornos de escena.")}
  end

  defp assert_present_target(ctx, who) do
    if Dragonex.World.present?(world(ctx), who),
      do: :ok,
      else: {:error, dgettext("engine", "%{who} no está presente en la escena.", who: who)}
  end

  @doc "DM only, exploration: MUST call before narrating descriptive gear actually collected or handed to a present PC, including an NPC returning an object into their hand. Adds quantity to the canonical inventory stack. A pending request/plan alone does not transfer stock; when the NPC agrees and actually hands it over, this tool is required. Set optional source to the known giver's name/role or the object's origin; omit when unknown. This attribution does not validate/create an NPC or change another inventory. Never equip weapons/armor or grant mechanical effects. Copy the canonical item name when adding to a stack; name a new scene object exactly as narrated, in the language of the game (e.g. \"ledger\" / \"libro de cuentas\"), never translated. An object already in their inventory is rejected: omit additional (or false) for a single object; set additional true only for genuinely new, separate units of a stack (more arrows, coins)."
  deftool grant_item(
            ctx,
            who :: String.t(),
            item :: String.t(),
            quantity :: integer(),
            additional :: boolean(),
            source :: String.t()
          ) do
    with :ok <- assert_inventory_dm(ctx),
         :ok <- Dragonex.Game.InventoryResolution.assert_tool_allowed(ctx, "grant_item", who),
         {:ok, ctx} <- inventory_counterparty(ctx, source),
         {:ok, _} <- propose(ctx, Dragonex.World.grant_item(who, item, quantity, additional)) do
      {:ok,
       dgettext("engine", "%{who} recibe %{quantity} × %{item} en su inventario.",
         who: who,
         quantity: quantity,
         item: Dragonex.Rules.Inventory.key(item)
       )}
    end
  end

  def grant_item(ctx, who, item, quantity, additional),
    do: grant_item(ctx, who, item, quantity, additional, nil)

  @doc "DM only, exploration: confirm a present PC actually handed over, dropped or lost owned descriptive gear. Removes only the requested positive quantity, rejects insufficient stock. ALWAYS include recipient: the known receiver's name or role, or null only when unknown or no receiver. This attribution does not validate/create an NPC or change another inventory. Copy the canonical name from inventory. Does not equip/consume or alter combat equipment."
  deftool remove_item(
            ctx,
            who :: String.t(),
            item :: String.t(),
            quantity :: integer(),
            recipient :: String.t()
          ) do
    with :ok <- assert_inventory_dm(ctx),
         :ok <- Dragonex.Game.InventoryResolution.assert_tool_allowed(ctx, "remove_item", who),
         {:ok, ctx} <- inventory_counterparty(ctx, recipient),
         {:ok, _} <- propose(ctx, Dragonex.World.remove_item(who, item, quantity)) do
      {:ok,
       dgettext("engine", "%{who} entrega o deja %{quantity} × %{item}; inventario actualizado.",
         who: who,
         quantity: quantity,
         item: Dragonex.Rules.Inventory.key(item)
       )}
    end
  end

  def remove_item(ctx, who, item, quantity), do: remove_item(ctx, who, item, quantity, nil)

  defp inventory_counterparty(ctx, value) do
    with {:ok, label} <- Dragonex.Game.InventoryMovement.counterparty(value),
         do: {:ok, %{ctx | deps: Map.put(ctx.deps, :inventory_counterparty, label)}}
  end

  @doc "DM only, exploration: confirm that a player's declared pickup or handover does NOT change any inventory this turn (the object is not there, the attempt fails, they only look at it, or it is already in their inventory). Use it instead of grant_item/remove_item, never alongside a real change."
  deftool confirm_inventory_unchanged(ctx, who :: String.t(), reason :: String.t()) do
    with :ok <- assert_inventory_dm(ctx),
         :ok <-
           Dragonex.Game.InventoryResolution.assert_tool_allowed(
             ctx,
             "confirm_inventory_unchanged",
             who
           ) do
      _ = reason

      {:ok, dgettext("engine", "Sin cambios en el inventario de %{who}.", who: who)}
    end
  end

  @doc "DM only, exploration: register BOTH completed legs of a temporary handover in this turn, even when final stock is unchanged. borrow_return: the PC receives descriptive gear from counterparty and returns it; lend_return: the PC hands over owned gear and receives it back. Use ONE call instead of separate grant/remove or confirm_inventory_unchanged. State the exact object, positive quantity, present PC and other person/role; never invent a completed return that is only planned for later. Both movements commit atomically and remain in history. For a refused/unavailable loan or looking without taking, use confirm_no_inventory_transfer instead."
  deftool record_item_round_trip(
            ctx,
            who :: String.t(),
            item :: String.t(),
            quantity :: integer(),
            counterparty :: String.t(),
            direction :: String.t()
          ) do
    with :ok <- assert_inventory_dm(ctx),
         :ok <-
           Dragonex.Game.InventoryResolution.assert_tool_allowed(
             ctx,
             "record_item_round_trip",
             who
           ),
         {:ok, _} <- propose_round_trip(ctx, who, item, quantity, counterparty, direction) do
      {:ok,
       dgettext(
         "engine",
         "Registrados ambos traspasos de %{quantity} × %{item} para %{who}; el saldo final se conserva.",
         quantity: quantity,
         item: Dragonex.Rules.Inventory.key(item),
         who: who
       )}
    else
      {:error, :invalid_round_trip_direction} ->
        {:error,
         dgettext(
           "engine",
           "Indica borrow_return para recibir y devolver, o lend_return para entregar y recuperar."
         )}

      {:error, :round_trip_counterparty_required} ->
        {:error,
         dgettext(
           "engine",
           "El préstamo necesita una contraparte distinta del personaje, de 1 a 80 caracteres."
         )}

      error ->
        error
    end
  end

  defp propose_round_trip(ctx, who, item, quantity, counterparty, direction) do
    durable? = is_pid(ctx.deps[:game_owner])

    propose(ctx, fn world ->
      result =
        Dragonex.Rules.InventoryRoundTrip.apply(
          world,
          who,
          item,
          quantity,
          counterparty,
          direction
        )

      case result do
        {:ok, final, _legs} when not durable? -> {:ok, final}
        other -> other
      end
    end)
  end

  @doc "DM only, exploration: explicitly confirm that NO physical handover occurred: declined (the other person refused), not_available (the object was absent), or look_only (observed without taking). Provide the actual short reason. NEVER use this for a loan/examination followed by a return, even if final stock is unchanged: record_item_round_trip must record both legs. This decision is durable and excludes a conflicting successful round trip in this turn."
  deftool confirm_no_inventory_transfer(
            ctx,
            who :: String.t(),
            outcome :: String.t(),
            reason :: String.t()
          ) do
    with :ok <- assert_inventory_dm(ctx),
         :ok <-
           Dragonex.Game.InventoryResolution.assert_tool_allowed(
             ctx,
             "confirm_no_inventory_transfer",
             who
           ),
         {:ok, clean} <- no_transfer_reason(outcome, reason) do
      ctx = %{
        ctx
        | deps:
            Map.put(ctx.deps, :inventory_no_transfer, %{who: who, outcome: outcome, reason: clean})
      }

      with {:ok, _} <-
             propose(ctx, fn world ->
               if world.phase == :exploration and
                    match?(%{side: "pc"}, Dragonex.World.present_character(world, who)),
                  do: {:ok, world},
                  else:
                    {:error,
                     dgettext("engine", "El destinatario debe ser un personaje jugador presente.")}
             end) do
        {:ok,
         dgettext("engine", "No hubo entrega para %{who}: %{reason}", who: who, reason: clean)}
      end
    end
  end

  defp no_transfer_reason(outcome, reason)
       when outcome in ["declined", "not_available", "look_only"] and is_binary(reason) and
              byte_size(reason) <= 2048 do
    if String.valid?(reason) do
      clean = reason |> Dragonex.Text.scrub() |> String.replace(~r/\s+/u, " ") |> String.trim()
      if String.length(clean) in 1..400, do: {:ok, clean}, else: no_transfer_reason(nil, nil)
    else
      no_transfer_reason(nil, nil)
    end
  end

  defp no_transfer_reason(_, _),
    do:
      {:error,
       dgettext(
         "engine",
         "Indica declined, not_available o look_only y un motivo de 1 a 400 caracteres; un préstamo devuelto sí tuvo entregas."
       )}

  defp assert_inventory_dm(ctx) do
    if ctx.deps.state.participant_id == "dm",
      do: :ok,
      else:
        {:error,
         dgettext(
           "engine",
           "RECHAZADO — solo el DM confirma entregas y retiradas del inventario; narra tu intención y espera su resolución."
         )}
  end

  # --- legacy spike stubs ----------------------------------------------------
  # These apply a raw effect without rolling — they predate the rules engine and
  # are kept only so the original exAgent capability tests (combat/round-robin,
  # multi-participant, dice) keep exercising the framework. The real,
  # rules-driven versions are `make_attack` and `roll_dice` below. Retire once
  # those flows migrate.

  @doc "Attack a target for `damage` hp (after a successful hit roll elsewhere)."
  deftool attack(ctx, target :: String.t(), damage :: integer()) do
    case propose(ctx, Dragonex.World.apply_damage(target, damage)) do
      {:ok, _} ->
        {:ok,
         dgettext("engine", "%{target} recibe %{amount} de daño", target: target, amount: damage)}

      {:error, _} = e ->
        e
    end
  end

  @doc "Roll a single d`n` and report the result to the model."
  deftool roll(ctx, sides :: pos_integer()) do
    # Entradas inválidas (auditoría 7): caras 0/negativas/no enteras
    # crasheaban en Dice.roll; aquí se responde con error accionable.
    if is_integer(sides) and sides >= 2 and sides <= 1000 do
      roller = ctx.deps.roller
      {:ok, dgettext("engine", "salió %{value} (d%{sides})", value: roller.(sides), sides: sides)}
    else
      {:error,
       dgettext("engine", "tirada inválida: d%{sides} — usa entre 2 y 1000 caras",
         sides: inspect(sides)
       )}
    end
  end

  @doc "Add a character to the world with the given hp."
  deftool spawn_character(ctx, name :: String.t(), hp :: integer()) do
    # Entradas inválidas (auditoría 7): un nombre vacío creaba un personaje
    # basura con clave "" y pg <= 0 producían fichas sin sentido.
    cond do
      not is_binary(name) or String.trim(name) == "" ->
        {:error,
         dgettext("engine", "nombre inválido: %{name} — el personaje necesita un nombre",
           name: inspect(name)
         )}

      not is_integer(hp) or hp < 1 ->
        {:error,
         dgettext("engine", "pg iniciales inválidos: %{hp} — deben ser un entero ≥ 1",
           hp: inspect(hp)
         )}

      true ->
        c =
          Dragonex.Character.new(
            name: name,
            class: "monster",
            hp: hp,
            max_hp: hp,
            ac: 10,
            side: "enemy"
          )

        {:ok, _} = propose(ctx, Dragonex.World.add_character(c))
        {:ok, dgettext("engine", "%{name} aparece (%{hp} pg)", name: name, hp: hp)}
    end
  end

  @doc "Advance to the next round."
  deftool next_round(ctx) do
    {:ok, _} = propose(ctx, Dragonex.World.next_round())
    {:ok, dgettext("engine", "ronda avanzada")}
  end

  # --- real bridge tools (Rules -> World) -------------------------------
  # These resolve intents through Dragonex.Actions (deterministic math) and
  # propose the resulting change. The LLM only ever sees the returned message;
  # it never computes damage, hit chance or saves itself.

  @doc "Roll `count` d`sides`, optionally with advantage/disadvantage."
  deftool roll_dice(ctx, count :: pos_integer(), sides :: pos_integer()) do
    # Entradas inválidas (auditoría 7): propagar el error de Actions.roll
    # (antes el match duro crasheaba en cuanto la tirada no validaba).
    case Dragonex.Actions.roll(count, sides, :normal, ctx.deps.roller, ctx.deps[:roll_log]) do
      {:ok, msg} -> {:ok, msg}
      {:error, _} = e -> e
    end
  end

  @doc "DM only: roll initiative for every conscious combatant and begin combat."
  deftool roll_initiative(ctx) do
    with :ok <- assert_combat_dm(ctx),
         {:ok, msg, change} <-
           Dragonex.Actions.initiative(world(ctx), ctx.deps.roller, ctx.deps[:roll_log]),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc "Resolve a weapon attack from `attacker` onto `target` by the rules. Pass mode \"advantage\"/\"disadvantage\" when it applies."
  deftool make_attack(
            ctx,
            attacker :: String.t(),
            target :: String.t(),
            weapon :: String.t(),
            mode :: String.t()
          ) do
    with :ok <- assert_controls(ctx, attacker),
         {:ok, msg, change} <-
           Dragonex.Actions.attack(
             world(ctx),
             attacker,
             target,
             weapon,
             ctx.deps.roller,
             parse_mode(mode),
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Resolve a spell cast by `caster` onto `target` by the rules. Optional
  `cast_level` (integer): the spell-slot level to spend when UPCASTING a
  scaling spell — e.g. `cast_spell(who, "fireball", target, 4)` casts it with
  a 4th-level slot (9d6 instead of 8d6) and spends a 4th-level slot. Omit it
  (or pass the spell's base level) for a normal cast. Only spells with a
  curated scaling table scale (fireball, cure wounds, magic missile, …);
  others just spend the requested slot. Bless grants +1d4 to attacks and saves
  for 1 minute of concentration. For Bless only, `additional_targets` is an
  optional list of names besides `target`: up to 3 total at level 1, plus
  one per slot level above 1. No duplicates; the caster may be a target.
  Shield of Faith protects `target` with +2 effective AC for 10 minutes of
  concentration, uses a bonus action and one slot, and does not stack with
  itself. A higher slot does not increase its bonus. It is not Shield.
  Heal (level 6) restores 70 HP, plus 10 per higher slot, capped at max HP,
  and ends blinded, deafened and diseased. No dice or casting modifier.
  It can target yourself or a living downed ally, but not undead, constructs
  or dead creatures. One action and one slot, no concentration.
  Spare the Dying is a cantrip: stabilizes a living target at exactly 0 HP,
  clearing death-save failures without healing. One action, no slot or
  concentration. No effect on undead, constructs or dead creatures.
  False Life targets the caster only: 1d4+4 temporary HP at level 1, plus
  5 per higher slot, for 1 hour without concentration. Temporary HP do not
  stack; the engine keeps the greater value. One action and one slot.
  Lesser Restoration removes one condition: blinded, deafened, paralyzed,
  poisoned or diseased. Set condition_to_remove when several are present;
  omit it only when each target has exactly one eligible condition.
  It does not heal HP. One action and one slot, no concentration or scaling.
  Omit condition_to_remove or send null for every other spell. Never send "none".
  condition_to_remove is only accepted for Lesser Restoration; with Twinned,
  an explicit selection applies to both targets.
  """
  deftool cast_spell(
            ctx,
            caster :: String.t(),
            spell :: String.t(),
            target :: String.t(),
            cast_level :: integer(),
            additional_targets :: [String.t()],
            condition_to_remove :: String.t()
          ) do
    with :ok <- assert_controls(ctx, caster),
         {:ok, msg, change} <-
           Dragonex.Actions.spell(
             world(ctx),
             caster,
             spell,
             target,
             ctx.deps.roller,
             ctx.deps[:roll_log],
             parse_cast_level(cast_level),
             additional_targets,
             empty_selection_to_nil(condition_to_remove)
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  # Keep the existing direct Elixir call compatible as well as old tool JSON.
  def cast_spell(ctx, caster, spell, target, cast_level, additional_targets),
    do: cast_spell(ctx, caster, spell, target, cast_level, additional_targets, nil)

  def cast_spell(ctx, caster, spell, target, cast_level),
    do: cast_spell(ctx, caster, spell, target, cast_level, nil)

  # D74: coerce a clean integer string; let anything odd hit Actions' validation.
  defp parse_cast_level(nil), do: nil

  defp parse_cast_level(n) when is_integer(n), do: n

  defp parse_cast_level(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> s
    end
  end

  defp parse_cast_level(other), do: other

  defp empty_selection_to_nil(selection) when is_binary(selection) do
    if String.trim(selection) == "", do: nil, else: selection
  end

  defp empty_selection_to_nil(selection), do: selection

  @doc "Make a death saving throw for a down `character`."
  deftool make_death_save(ctx, character :: String.t()) do
    with :ok <- assert_controls(ctx, character),
         {:ok, msg, change} <-
           Dragonex.Actions.death_save(
             world(ctx),
             character,
             ctx.deps.roller,
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc "End combat and return to free-form exploration (DM call, once combat is over)."
  deftool end_combat(ctx) do
    with :ok <- assert_combat_dm(ctx),
         {:ok, _} <- propose(ctx, Dragonex.World.end_combat()) do
      {:ok, dgettext("engine", "el combate termina")}
    end
  end

  @doc "PC self-rest only; the DM must use rest_party, including for one target. One-hour short rest. Optional hit_dice: 0 to recover features only, or available dice to spend; omitted spends at most one."
  deftool short_rest(ctx, target :: String.t(), hit_dice :: integer()) do
    with :ok <- assert_rest_target(ctx, target),
         {:ok, msg, change} <-
           Dragonex.Actions.short_rest(
             world(ctx),
             target,
             ctx.deps.roller,
             ctx.deps[:roll_log],
             hit_dice
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  def short_rest(ctx, target), do: short_rest(ctx, target, nil)

  @doc """
  D99 Spiritual Weapon: strike again with the caster's active spectral
  weapon. One BONUS action per turn; melee spell attack of 1d8 (+the caster's
  spellcasting modifier, +1d8 per two slot levels above 2nd) force damage.
  Only usable while the spiritual weapon posture is active (cast spiritual
  weapon first — it lasts 1 minute of combat rounds and a re-cast replaces
  it, never stacks). The engine resolves the attack, crits and advantage;
  never computes damage yourself.
  """
  deftool spiritual_weapon_attack(ctx, who :: String.t(), target :: String.t()) do
    with :ok <- assert_controls(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.spiritual_weapon_attack(
             world(ctx),
             who,
             target,
             ctx.deps.roller,
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc "DM only: advance explicit exploration time in seconds. Never use to skip combat turns or add a rest's duration: rest_party already advances time. A separate interval after a rest requires another player declaration."
  deftool advance_time(ctx, seconds :: integer()) do
    if ctx.deps.state.participant_id == "dm" do
      with {:ok, committed} <-
             propose(ctx, fn world ->
               Dragonex.Game.WaitResolution.advance_time(world, seconds, ctx.deps)
             end) do
        if ctx.deps[:beat] && ctx.deps.beat[:wait_resolution] do
          {:ok,
           dgettext(
             "engine",
             "Espera registrada; reloj confirmado: %{seconds} s. No repitas este intervalo.",
             seconds: committed.elapsed_seconds
           )}
        else
          {:ok, dgettext("engine", "transcurren %{seconds} segundos", seconds: seconds)}
        end
      end
    else
      {:error, dgettext("engine", "solo el DM puede avanzar el tiempo del mundo")}
    end
  end

  @doc "DM only: resolve one simultaneous rest with ALL resting targets (even a solo rest uses this tool). kind is short (1h) or long (8h); time advances once. Do not call short_rest/long_rest per target or advance_time for this interval. A subsequent rest/travel interval requires another player declaration."
  deftool rest_party(ctx, targets :: [String.t()], kind :: String.t()) do
    if ctx.deps.state.participant_id == "dm" do
      with {:ok, message, change} <-
             Dragonex.Actions.rest_party(
               world(ctx),
               targets,
               kind,
               ctx.deps.roller,
               ctx.deps[:roll_log]
             ),
           {:ok, committed} <- propose(ctx, change),
           do:
             {:ok,
              message <>
                " " <>
                dgettext(
                  "engine",
                  "Tiempo del mundo tras el descanso: %{seconds} s. " <>
                    "Si el entorno o la situación cambió, actualiza el registro con set_scene, " <>
                    "sin mover ni hacer actuar a los PCs. No repitas el descanso ya aplicado.",
                  seconds: committed.elapsed_seconds
                )}
    else
      {:error, dgettext("engine", "solo el DM puede resolver un descanso de grupo")}
    end
  end

  @doc "PC self-rest only; the DM must use rest_party, including for one target. Long rest: restore all HP. Available outside combat."
  deftool long_rest(ctx, target :: String.t()) do
    with :ok <- assert_rest_target(ctx, target),
         {:ok, msg, change} <- Dragonex.Actions.long_rest(world(ctx), target),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  DM only: grant a character one level (milestone advancement). Raises HP and
  refreshes spell slots. **Does not apply to human PCs** (a real person controls
  them, even in auto-play): they always level up from their sheet
  (`/heroes/:id/level-up`). For NPCs, enemies and AI PCs the DM decides here.

  `opts` carries the new level's choices (ignored for human PCs):
    * `"spells"` — keys of the new spells learned (builtin/SRD).
    * `"asi"` — `%{"str" => 2}` spending 2 points at levels 4/8/12/16/19.
  Pass `{}` when there is nothing to choose. The engine validates the limits.
  """
  deftool level_up(ctx, target :: String.t(), opts :: map()) do
    with :ok <- assert_direct_effect_dm(ctx) do
      cond do
        human_pc?(ctx, target) ->
          {:ok,
           dgettext(
             "engine",
             "%{target} es un jugador humano: debe subir de nivel desde su ficha (/heroes/:id/level-up), no por la mesa.",
             target: target
           )}

        true ->
          change = Dragonex.World.level_up(target, normalize_level_up_opts(opts))

          with {:ok, _} <- propose(ctx, change) do
            {:ok, dgettext("engine", "¡%{target} sube de nivel!", target: target)}
          end
      end
    end
  end

  defp normalize_level_up_opts(nil), do: %{}

  defp normalize_level_up_opts(opts) when is_map(opts) do
    %{
      spells_added: List.wrap(opts["spells"] || opts["spells_added"]),
      asi: normalize_asi(opts["asi"]),
      custom: %{}
    }
  end

  defp normalize_level_up_opts(_), do: %{}

  defp normalize_asi(asi) when is_map(asi) do
    Enum.reduce(asi, %{}, fn
      {ab, n}, acc when ab in ~w(str dex con int wis cha) and is_integer(n) ->
        Map.put(acc, String.to_existing_atom(ab), n)

      _, acc ->
        acc
    end)
  end

  defp normalize_asi(_), do: %{}

  # ¿El target es un PC controlado por un humano? El Game inyecta `human_pcs`
  # (MapSet de nombres) en el `deps` de cada beat.
  defp human_pc?(ctx, target) do
    case ctx.deps[:human_pcs] do
      %MapSet{} = set -> MapSet.member?(set, target)
      _ -> false
    end
  end

  @doc "DM only: spawn a monster from the bestiary into the world (e.g. 'orc', 'skeleton', 'wolf'). Use a unique name if summoning multiples."
  deftool spawn_monster(ctx, kind :: String.t(), name :: String.t()) do
    with :ok <- assert_combat_dm(ctx) do
      spawn_bestiary_monster(ctx, kind, name)
    end
  end

  defp spawn_bestiary_monster(ctx, kind, name) do
    cond do
      # Entradas inválidas (auditoría 7): sin esto un nombre en blanco
      # spawnneaba un monstruo con clave "".
      not is_binary(name) or String.trim(name) == "" ->
        {:error,
         dgettext("engine", "nombre inválido: %{name} — el monstruo necesita un nombre",
           name: inspect(name)
         )}

      true ->
        monster =
          case Dragonex.Monsters.get(kind) do
            builder when is_function(builder, 1) -> builder.(name: name)
            nil -> nil
          end

        if monster do
          # Add the monster AND join it to the initiative order when mid-combat
          # (join_initiative is a no-op in exploration, so composing is always safe).
          change =
            compose(
              Dragonex.World.add_character(monster),
              Dragonex.World.join_initiative(monster.name)
            )

          with {:ok, _} <- propose(ctx, change) do
            {:ok,
             dgettext("engine", "¡Aparece %{name} (%{kind})! PG %{hp}, CA %{ac}.",
               name: name,
               kind: kind,
               hp: monster.hp,
               ac: monster.ac
             )}
          end
        else
          {:ok,
           dgettext(
             "engine",
             "Tipo de monstruo desconocido '%{kind}'. Disponibles, de menor a mayor desafío: %{kinds}. Si ninguno encaja, usa el de CR más parecido a la criatura que pide la historia, nunca uno más fuerte.",
             kind: kind,
             kinds: Dragonex.Monsters.catalogue_by_cr()
           )}
        end
    end
  end

  defp assert_combat_dm(ctx) do
    if ctx.deps.state.participant_id == "dm" do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo el DM introduce criaturas o pide iniciar/terminar combate. " <>
           "Resuelve con las fichas existentes; si el objetivo aún no tiene ficha, no lo crees " <>
           "ni lo ataques: cierra con una confirmación breve y el DM lo registrará con su iniciativa."
       )}
    end
  end

  @doc "DM only: apply established healing by a dice expression (e.g. \"1d8+3\"); caps at max hp. PCs use their paid spell or class feature. Death saves clear only if hp rises above 0. Does not touch temp_hp."
  deftool heal(ctx, target :: String.t(), dice :: String.t()) do
    with :ok <- assert_direct_effect_dm(ctx),
         {:ok, msg, change} <-
           Dragonex.Actions.heal(world(ctx), target, dice, ctx.deps.roller, ctx.deps[:roll_log]),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  DM only: grant `amount` temporary hit points to `who` (5e, D36). Does not stack: the
  character keeps the higher of current temp_hp and `amount`. Does not heal.
  PCs use cast_spell or their class feature, whose engine validates the source and cost.
  """
  deftool grant_temp_hp(ctx, who :: String.t(), amount :: integer()) do
    with :ok <- assert_direct_effect_dm(ctx) do
      grant_direct_temp_hp(ctx, who, amount)
    end
  end

  defp grant_direct_temp_hp(ctx, who, amount) do
    current =
      case Dragonex.World.character(world(ctx), who) do
        %Dragonex.Character{} = c -> c.temp_hp || 0
        _ -> 0
      end

    with :ok <- assert_present_target(ctx, who),
         :ok <- positive_amount(amount, dgettext("engine", "los pg temporales")),
         {:ok, _} <- propose(ctx, Dragonex.World.apply_temp_hp(who, amount)) do
      {:ok,
       dgettext("engine", "%{who} queda con %{amount} pg temporales.",
         who: who,
         amount: max(current, amount)
       )}
    end
  end

  # Entradas inválidas (auditoría 7): guard temprano en la tool — el amount
  # llega del LLM y debe ser un entero positivo.
  defp positive_amount(amount, _what) when is_integer(amount) and amount > 0, do: :ok

  defp positive_amount(amount, what),
    do:
      {:error,
       dgettext("engine", "%{what} deben ser un entero positivo (recibió %{value})",
         what: what,
         value: inspect(amount)
       )}

  @doc """
  Grant `amount` XP to `who` (5e, D43). Does not level up and does not
  touch hp or spell slots. Amount must be positive. DM only.
  """
  deftool grant_xp(ctx, who :: String.t(), amount :: integer()) do
    c = Dragonex.World.character(world(ctx), who)
    current_xp = if c, do: c.xp || 0, else: 0
    level = if c, do: c.level || 1, else: 1

    with :ok <- assert_grant_xp(ctx),
         {:ok, _} <- propose(ctx, Dragonex.World.grant_xp(who, amount)) do
      xp = current_xp + amount
      threshold = Dragonex.Heroes.Progression.xp_threshold(level + 1)
      can? = Dragonex.Heroes.Progression.can_level_up?(level, xp)
      {:ok, grant_xp_message(who, amount, xp, threshold, can?)}
    end
  end

  @doc """
  Drop concentration (5e, D37). The DM may drop anyone; a PC may only drop
  themselves.
  """
  deftool drop_concentration(ctx, who :: String.t()) do
    spell =
      case Dragonex.World.character(world(ctx), who) do
        nil -> nil
        c -> c.concentrating
      end

    with :ok <- assert_drop_concentration(ctx, who),
         {:ok, _} <- propose(ctx, Dragonex.World.clear_concentration(who)) do
      if is_binary(spell) do
        {:ok,
         dgettext("engine", "%{who} deja de concentrarse en %{spell}.",
           who: who,
           spell: Dragonex.Terms.spell(spell)
         )}
      else
        {:ok, dgettext("engine", "%{who} no estaba concentrado.", who: who)}
      end
    end
  end

  @doc """
  Enter Rage (5e, D42). Barbarian only, limited uses per long rest (D72;
  recharges on long rest). Clears concentration. The DM may start
  anyone; a PC may only start themselves.
  """
  deftool start_rage(ctx, who :: String.t()) do
    with :ok <- assert_rage_self(ctx, who),
         {:ok, _} <- propose(ctx, Dragonex.World.start_rage(who)) do
      {:ok, dgettext("engine", "%{who} entra en furia.", who: who)}
    end
  end

  @doc """
  End Rage (5e, D42). The DM may end anyone; a PC may only end themselves.
  """
  deftool end_rage(ctx, who :: String.t()) do
    with :ok <- assert_rage_self(ctx, who),
         {:ok, _} <- propose(ctx, Dragonex.World.end_rage(who)) do
      {:ok, dgettext("engine", "%{who} deja la furia.", who: who)}
    end
  end

  @doc """
  Enter Reckless Attack (5e, D44). Barbarian only. The DM may start anyone; a
  PC may only start themselves. The engine applies advantage — do not pass
  mode to make_attack for Reckless.
  """
  deftool start_reckless(ctx, who :: String.t()) do
    with :ok <- assert_reckless_self(ctx, who),
         {:ok, _} <- propose(ctx, Dragonex.World.start_reckless(who)) do
      {:ok, dgettext("engine", "%{who} ataca de forma temeraria.", who: who)}
    end
  end

  @doc """
  End Reckless Attack (D44). The DM may end anyone; a PC may only end
  themselves.
  """
  deftool end_reckless(ctx, who :: String.t()) do
    with :ok <- assert_reckless_self(ctx, who),
         {:ok, _} <- propose(ctx, Dragonex.World.end_reckless(who)) do
      {:ok, dgettext("engine", "%{who} deja de atacar de forma temeraria.", who: who)}
    end
  end

  @doc """
  Second Wind (5e, D45). Fighter only. Heals 1d10+level, once per rest.
  The DM may use it for anyone; a PC may only use it on themselves.
  """
  deftool second_wind(ctx, who :: String.t()) do
    with :ok <- assert_second_wind_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.second_wind(
             world(ctx),
             who,
             ctx.deps.roller,
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Action Surge (5e, D47). Fighter level 2+. Extra Attack action (N swings,
  Extra Attack D35 included), once per rest. The DM may use it for anyone;
  a PC may only use it on themselves.
  """
  deftool action_surge(
            ctx,
            who :: String.t(),
            target :: String.t(),
            weapon :: String.t(),
            mode :: String.t()
          ) do
    with :ok <- assert_action_surge_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.action_surge(
             world(ctx),
             who,
             target,
             weapon,
             ctx.deps.roller,
             parse_mode(mode),
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Flurry of Blows (5e, D54). Monk level 2+. Spends 1 ki point; the engine
  resolves two unarmed strikes (martial arts die). The DM may use it for
  any monk; a PC may only use it as themselves.
  """
  deftool flurry_of_blows(ctx, who :: String.t(), target :: String.t(), mode :: String.t()) do
    with :ok <- assert_flurry_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.flurry_of_blows(
             world(ctx),
             who,
             target,
             ctx.deps.roller,
             parse_mode(mode),
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Hunter's Mark (5e, D55). Ranger level 2+. Spends a level-1 spell slot
  and concentrates on `target`; the engine then adds +1d6 to the marker's
  weapon hits against that prey. The DM may use it for any ranger; a PC
  may only use it as themselves.
  """
  deftool hunters_mark(ctx, who :: String.t(), target :: String.t()) do
    with :ok <- assert_hunters_mark_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.hunters_mark(
             world(ctx),
             who,
             target,
             ctx.deps.roller,
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Cunning Action: Hide (5e, D57). Rogue level 2+. The engine rolls a DEX
  (Stealth) check against the highest passive perception among conscious
  enemies; success applies "hidden" — the rogue's next attack rolls with
  advantage (and enables Sneak Attack), and that attack reveals them.
  The DM may use it for any rogue; a PC may only use it as themselves.
  """
  deftool cunning_action_hide(ctx, who :: String.t()) do
    with :ok <- assert_cunning_hide_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.cunning_action_hide(
             world(ctx),
             who,
             ctx.deps.roller,
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Uncanny Dodge (5e, D64). Rogue level 5+. Arms a defensive posture: the
  engine halves (floor) the NEXT damage `who` takes — any source — and
  consumes the flag. Arming is free and can be done at any moment (no
  reaction economy); 0 damage or healing never consumes it. The DM may
  arm anyone; a PC may only arm themselves.
  """
  deftool start_uncanny_dodge(ctx, who :: String.t()) do
    with :ok <- assert_uncanny_dodge_self(ctx, who),
         {:ok, msg, change} <- Dragonex.Actions.start_uncanny_dodge(world(ctx), who),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Create a Spell Slot (5e, D56 Font of Magic). Sorcerer level 2+. Spends
  sorcery points (2/3/5/6/7 by slot level 1–5) and gains one slot of that
  level. The DM may use it for any sorcerer; a PC may only use it as
  themselves.
  """
  deftool create_spell_slot(ctx, who :: String.t(), level :: integer()) do
    with :ok <- assert_font_of_magic_self(ctx, who),
         {:ok, msg, change} <- Dragonex.Actions.create_spell_slot(world(ctx), who, level),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Convert to Sorcery Points (5e, D56 Font of Magic). Sorcerer level 2+.
  Spends one slot of `level` (1–5) and gains that many sorcery points,
  capped at the pool maximum. The DM may use it for any sorcerer; a PC may
  only use it as themselves.
  """
  deftool convert_to_sorcery_points(ctx, who :: String.t(), level :: integer()) do
    with :ok <- assert_font_of_magic_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.convert_to_sorcery_points(world(ctx), who, level),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Metamagic (5e, D65). Sorcerer level 3+. Spends sorcery points to arm ONE
  option that the engine applies to and consumes with the sorcerer's next
  qualifying spell: "empowered" (1 punto — the first max(1, CHA) damage
  dice roll twice keeping the higher), "heightened" (3 puntos — the armed
  target saves with disadvantage), "twinned" (2 puntos — the same spell
  also resolves against the armed second target). Pass `target` (a
  character name) for heightened/twinned, "" for empowered. Only ONE
  option at a time; no un-arm nor refund; spells that don't qualify leave
  it armed. The DM may arm anyone; a PC may only arm themselves.
  """
  deftool arm_metamagic(ctx, who :: String.t(), option :: String.t(), target :: String.t()) do
    with :ok <- assert_metamagic_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.arm_metamagic(world(ctx), who, option, target || ""),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Arm Divine Smite (5e, D46). Paladin only. Leaves a pending smite_slot;
  the spell slot is consumed on the next melee hit, not now. The DM may
  arm anyone; a PC may only arm themselves.
  """
  deftool divine_smite(ctx, who :: String.t(), slot_level :: integer()) do
    with :ok <- assert_smite_self(ctx, who),
         {:ok, _} <- propose(ctx, Dragonex.World.start_smite(who, slot_level)) do
      {:ok,
       dgettext("engine", "%{who} arma Castigo divino (casilla de nivel %{level}).",
         who: who,
         level: slot_level
       )}
    end
  end

  @doc """
  Clear pending Divine Smite (D46) without consuming a slot. The DM may
  end anyone; a PC may only end themselves.
  """
  deftool end_smite(ctx, who :: String.t()) do
    with :ok <- assert_smite_self(ctx, who),
         {:ok, _} <- propose(ctx, Dragonex.World.end_smite(who)) do
      {:ok, dgettext("engine", "%{who} retira el Castigo divino.", who: who)}
    end
  end

  @doc """
  Lay on Hands (5e, D49). Paladin only. Spends pool points to heal
  `target` (self or another). The DM may use it for any paladin; a PC
  may only use it as themselves (`who` is self; `target` may be an ally).
  Optional conditions_to_remove: a unique list of poisoned and/or diseased
  currently present on the target. Costs 5 pool points per condition plus
  healing in the same action. amount may be 0 for purification alone.
  No effect on undead, constructs or dead targets. Purification alone does
  not restore HP or stabilize. Omit the list for ordinary healing.
  """
  deftool lay_on_hands(
            ctx,
            who :: String.t(),
            target :: String.t(),
            amount :: integer(),
            conditions_to_remove :: [String.t()]
          ) do
    with :ok <- assert_lay_on_hands_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.lay_on_hands(world(ctx), who, target, amount, conditions_to_remove),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  def lay_on_hands(ctx, who, target, amount),
    do: lay_on_hands(ctx, who, target, amount, nil)

  @doc """
  Divine Sense (5e, D52). Paladin only. Spends 1 use and the engine
  reports celestials, fiends and undead in the world. The DM may use it
  for any paladin; a PC may only use it as themselves.
  """
  deftool divine_sense(ctx, who :: String.t()) do
    with :ok <- assert_divine_sense_self(ctx, who),
         {:ok, msg, change} <- Dragonex.Actions.divine_sense(world(ctx), who),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Turn Undead (5e, D53). Cleric level 2+. Spends Channel Divinity; living
  undead roll a Wisdom save and fail into frightened. The DM may use it
  for any cleric; a PC may only use it as themselves.
  """
  deftool turn_undead(ctx, who :: String.t()) do
    with :ok <- assert_turn_undead_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.turn_undead(
             world(ctx),
             who,
             ctx.deps.roller,
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Bardic Inspiration (5e, D50). Bard only. Spends 1 use to grant `target`
  a pending d6. The DM may use it for any bard; a PC may only use it as
  themselves (`who` is self; `target` may be an ally).
  """
  deftool bardic_inspiration(ctx, who :: String.t(), target :: String.t()) do
    with :ok <- assert_bardic_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.bardic_inspiration(world(ctx), who, target),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Arcane Recovery (5e, D51). Wizard only. Restores expended spell slots
  outside combat, once per long rest. The engine picks slots (greedy).
  The DM may use it for anyone; a PC may only use it on themselves.
  """
  deftool arcane_recovery(ctx, who :: String.t()) do
    with :ok <- assert_arcane_recovery_self(ctx, who),
         {:ok, msg, change} <- Dragonex.Actions.arcane_recovery(world(ctx), who),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Wild Shape (5e, D63). Druid level 2+. Transforms `who` into a beast from
  the fixed catalogue — "cat" (ND 0), "wolf" (ND 1/4), "black_bear"
  (ND 1/2, level 4+ only). The engine spends 1 use (2 per rest), saves the
  original form and applies the beast's stats and attacks; while
  transformed `who` CANNOT cast spells (everything else works). If the beast
  drops to 0 hp the engine reverts automatically with only the excess
  damage carried over. The DM may transform anyone; a PC may only
  transform themselves.
  """
  deftool wild_shape(ctx, who :: String.t(), beast :: String.t()) do
    with :ok <- assert_wild_shape_self(ctx, who),
         {:ok, msg, change} <- Dragonex.Actions.wild_shape(world(ctx), who, beast),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  End Wild Shape (D63). Returns `who` to their original form with the hit
  points they had when transforming. The DM may end anyone; a PC may only
  end themselves.
  """
  deftool end_wild_shape(ctx, who :: String.t()) do
    with :ok <- assert_wild_shape_self(ctx, who),
         {:ok, msg, change} <- Dragonex.Actions.end_wild_shape(world(ctx), who),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Breath Weapon (5e, D70). Dragonborn only (any class/level): spends the
  racial use (1/rest — short AND long recharge) and the engine resolves a
  DEX save for `target` vs the dragonborn's DC (8 + CON + proficiency);
  failure takes the full fire damage of `Progression.breath_dice/1`,
  success takes half. Not a spell (no slot, works in Wild Shape). The
  DM may use it for any dragonborn; a PC may only use it as themselves.
  """
  deftool breath_weapon(ctx, who :: String.t(), target :: String.t()) do
    with :ok <- assert_breath_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.breath_weapon(
             world(ctx),
             who,
             target,
             ctx.deps.roller,
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Expertise (5e, D73). Rogue (L1+) / bard (L3+): doubles the proficiency
  bonus of ONE trained skill (2 choices; 4 from rogue L6 / bard L10).
  `skill` must be in the character's trained skills — the engine
  validates class, level, training, duplicates and cupo. Choose once per
  skill, any moment once eligible. The DM may choose for anyone; a PC
  may only choose for themselves.
  """
  deftool gain_expertise(ctx, who :: String.t(), skill :: String.t()) do
    with :ok <- assert_gain_expertise_self(ctx, who),
         {:ok, msg, change} <- Dragonex.Actions.gain_expertise(world(ctx), who, skill),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Resolve a non-combat ability check: the DM sets the `dc` (5/10/15/20 by 5e
  difficulty), the engine rolls d20 + the ability modifier for `who`.
  Pass a SKILL name when the check maps to one (`"stealth"`,
  `"athletics"`, `"animal_handling"` — case/spaces/hyphens are normalized):
  the engine picks the governing ability and applies the character's skill
  proficiency from the sheet, plus Jack of All Trades (bard L2+: half
  proficiency on untrained skills). Pass a raw ability (`"str"`…`"cha"`)
  only for generic checks (no proficiency from the sheet). Pass mode
  "advantage"/"disadvantage" when it applies.
  Examples: ability_check("Thane", "athletics", 15),
  ability_check("Vex", "stealth", 15, "advantage"), ability_check("Thane", "str", 10).
  """
  deftool ability_check(
            ctx,
            who :: String.t(),
            ability :: String.t(),
            dc :: integer(),
            mode :: String.t()
          ) do
    with :ok <- assert_controls(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.check(
             world(ctx),
             who,
             ability,
             dc,
             false,
             ctx.deps.roller,
             parse_mode(mode),
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc "DM only: apply an established condition (e.g. prone, poisoned, blinded). PCs use their rule-driven spell or class feature."
  deftool apply_condition(ctx, target :: String.t(), condition :: String.t()) do
    # D62 Aura of Courage: same-side ally of a conscious paladin L10+ can't
    # be frightened. The World hook would no-op anyway; the message tells
    # the model WHY nothing landed.
    with :ok <- assert_direct_effect_dm(ctx),
         :ok <- assert_present_target(ctx, target) do
      if condition == "frightened" and Dragonex.World.courage_immune?(world(ctx), target) do
        {:ok, dgettext("engine", "%{target} es inmune al miedo (Aura de Coraje)", target: target)}
      else
        with {:ok, _} <- propose(ctx, Dragonex.World.apply_condition(target, condition)) do
          {:ok,
           dgettext("engine", "%{target} ahora está %{condition}",
             target: target,
             condition: Dragonex.Terms.condition(condition)
           )}
        end
      end
    end
  end

  @doc "DM only: remove a condition whose removal is established. PCs use their paid spell or class feature."
  deftool remove_condition(ctx, target :: String.t(), condition :: String.t()) do
    with :ok <- assert_direct_effect_dm(ctx),
         :ok <- assert_present_target(ctx, target),
         {:ok, _} <- propose(ctx, Dragonex.World.remove_condition(target, condition)) do
      {:ok,
       dgettext("engine", "%{target} ya no está %{condition}",
         target: target,
         condition: Dragonex.Terms.condition(condition)
       )}
    end
  end

  @doc false
  def normalize_mode("advantage"), do: :advantage
  def normalize_mode("disadvantage"), do: :disadvantage
  def normalize_mode(_), do: :normal

  defp parse_mode(value), do: normalize_mode(value)

  # Read the current shared world through the Session handle.
  defp world(ctx), do: ExAgent.Session.SharedState.read(ctx.deps.state)

  # Guard: only let a participant act with the characters it controls. Stops a
  # monster from acting on a player's turn (and vice versa). The error is
  # *directive* — it tells the DM exactly who must act and how to re-issue, so a
  # confused model self-corrects on the retry instead of repeating the mistake.
  # PCs only rest themselves; the DM (referee) may rest anyone between fights.
  defp assert_rest_target(ctx, target) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == target do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes descansar tú mismo (%{proposer}), no a %{target}.",
         proposer: proposer,
         target: target
       )}
    end
  end

  defp assert_grant_xp(ctx) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" do
      :ok
    else
      {:error, dgettext("engine", "RECHAZADO — solo el DM puede otorgar XP.")}
    end
  end

  defp grant_xp_message(who, amount, xp, nil, _can?) do
    dgettext(
      "engine",
      "%{who} gana %{amount} XP (total %{xp}; nivel máximo; no puede subir de nivel).",
      who: who,
      amount: amount,
      xp: xp
    )
  end

  defp grant_xp_message(who, amount, xp, threshold, true) do
    dgettext(
      "engine",
      "%{who} gana %{amount} XP (total %{xp}; umbral siguiente nivel %{threshold}; puede subir de nivel).",
      who: who,
      amount: amount,
      xp: xp,
      threshold: threshold
    )
  end

  defp grant_xp_message(who, amount, xp, threshold, false) do
    dgettext(
      "engine",
      "%{who} gana %{amount} XP (total %{xp}; umbral siguiente nivel %{threshold}; aún no puede subir de nivel).",
      who: who,
      amount: amount,
      xp: xp,
      threshold: threshold
    )
  end

  defp assert_direct_effect_dm(ctx) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo el DM aplica curaciones/efectos directos o decide subidas de nivel. " <>
           "Usa cast_spell, second_wind o la capacidad correspondiente; el motor valida su recurso y resultado."
       )}
    end
  end

  defp assert_drop_concentration(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes soltar tu propia concentración (%{proposer}), no la de %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  defp assert_rage_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes controlar tu propia furia (%{proposer}), no la de %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  defp assert_reckless_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes controlar tu propio ataque temerario (%{proposer}), no el de %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  defp assert_second_wind_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes usar Segundo aliento en ti mismo (%{proposer}), no en %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  defp assert_action_surge_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes usar Oleada de acción en ti mismo (%{proposer}), no en %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  defp assert_flurry_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes usar Ráfaga de golpes en ti mismo (%{proposer}), no en %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  defp assert_hunters_mark_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes usar Marca del cazador como %{proposer}, no como %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  # Cunning Action: Hide (D57): self guard (divine_smite pattern).
  defp assert_cunning_hide_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes esconderte tú mismo (%{proposer}), no a %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  # Uncanny Dodge (D64): self guard (divine_smite pattern).
  defp assert_uncanny_dodge_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes armarte tú mismo de Esquiva asombrosa (%{proposer}), no a %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  # Font of Magic (D56): both tools share the self guard (divine_smite pattern).
  defp assert_font_of_magic_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes usar Fuente de magia en ti mismo (%{proposer}), no en %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  # Metamagic (D65): self guard (divine_smite pattern).
  defp assert_metamagic_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes armar Metamagia en ti mismo (%{proposer}), no en %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  defp assert_smite_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes controlar tu propio Castigo divino (%{proposer}), no el de %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  defp assert_lay_on_hands_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes usar Manos impositoras como %{proposer}, no como %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  defp assert_divine_sense_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes usar Sentido divino como %{proposer}, no como %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  defp assert_turn_undead_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes usar Expulsar no-muertos como %{proposer}, no como %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  defp assert_bardic_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes usar Inspiración bárdica como %{proposer}, no como %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  defp assert_arcane_recovery_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes usar Recuperación arcana en ti mismo (%{proposer}), no en %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  # Wild Shape (D63): both tools share the self guard (divine_smite pattern).
  defp assert_wild_shape_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes usar Forma salvaje en ti mismo (%{proposer}), no en %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  # Breath Weapon (D70): self guard (divine_smite pattern).
  defp assert_breath_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes usar tu propio aliento de dragón (%{proposer}), no el de %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  # Expertise (D73): self guard (divine_smite pattern).
  defp assert_gain_expertise_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       dgettext(
         "engine",
         "RECHAZADO — solo puedes elegir tu propio Expertise (%{proposer}), no el de %{who}.",
         proposer: proposer,
         who: who
       )}
    end
  end

  defp assert_controls(ctx, actor) do
    proposer = ctx.deps.state.participant_id
    current_world = world(ctx)

    if Dragonex.World.controlled_by?(current_world, actor, proposer) do
      :ok
    else
      control_rejection(current_world, proposer, actor)
    end
  end

  defp control_rejection(world, proposer, actor) do
    cond do
      proposer == "dm" and actor == "dm" ->
        dm_control_rejection(world)

      Dragonex.World.character(world, actor) == nil ->
        registration =
          if proposer == "dm",
            do:
              " " <>
                dgettext(
                  "engine",
                  "Si introduces un monstruo nuevo, registra su ficha con spawn_monster antes de iniciativa o ataques."
                ),
            else:
              " " <>
                dgettext(
                  "engine",
                  "Usa el nombre canónico del personaje que controlas; el DM registra criaturas nuevas."
                )

        {:error,
         dgettext(
           "engine",
           "RECHAZADO — no existe una ficha de %{actor} en el World. Usa un nombre canónico del estado.",
           actor: actor
         ) <>
           registration}

      not Dragonex.World.present?(world, actor) ->
        {:error,
         dgettext(
           "engine",
           "RECHAZADO — %{actor} está fuera de escena; no puede actuar aquí ni se recrea su ficha.",
           actor: actor
         )}

      proposer == "dm" ->
        dm_control_rejection(world)

      true ->
        {:error,
         dgettext(
           "engine",
           "RECHAZADO — es el turno de %{proposer}, así que el atacante/conjurador/quien DEBE ser \"%{proposer}\". " <>
             "Llamaste a esta herramienta con actor=\"%{actor}\" (%{proposer} no controla a %{actor}). " <>
             "Reemite la MISMA intención pero como %{proposer}, usando su nombre canónico en los argumentos de la herramienta.",
           proposer: proposer,
           actor: actor
         )}
    end
  end

  defp dm_control_rejection(world) do
    actors =
      world.characters
      |> Map.keys()
      |> Enum.filter(
        &(Dragonex.World.controlled_by?(world, &1, "dm") and
            Dragonex.World.validate_actor(world, &1) == :ok)
      )
      |> Enum.sort()

    available =
      if actors == [],
        do:
          dgettext(
            "engine",
            "No hay criaturas registradas disponibles; introduce un monstruo nuevo con spawn_monster antes de resolver sus acciones."
          ),
        else:
          dgettext(
            "engine",
            "Actores disponibles que controlas: %{actors}. Usa su nombre canónico y respeta el slot actual de iniciativa.",
            actors: Enum.join(actors, ", ")
          )

    {:error,
     dgettext(
       "engine",
       "RECHAZADO — dm es el controlador, no el atacante ni conjurador. El DM controla monstruos y PNJs; cada PC actúa por sí mismo. %{available}",
       available: available
     )}
  end

  # Live tools go through the Game's durable single writer. Standalone offline
  # engine sessions retain their SharedState-only API without needing a DB.
  defp propose(ctx, change_fn) do
    case Map.get(ctx.deps, :game_owner) do
      owner when is_pid(owner) -> Dragonex.Game.commit_rule_change(owner, ctx.deps, change_fn)
      _ -> ExAgent.Session.SharedState.propose_change(ctx.deps.state, change_fn)
    end
  end

  # Sequence two change functions into one (the Session applies a single fn).
  defp compose(f1, f2) do
    fn w ->
      with {:ok, w} <- f1.(w), {:ok, w} <- f2.(w), do: {:ok, w}
    end
  end
end
