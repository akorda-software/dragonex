defmodule Dragonex.TurnMaster do
  @moduledoc """
  Turn-orchestration agent (D25). Decides **who acts next**; never narrates
  fiction and never resolves rolls.

  Tools only **record** a decision (`Dragonex.TurnMaster.Decision`). The
  `Dragonex.Game` GenServer applies it via `Session.handoff/2` /
  `Session.update_state/3` — single-writer (D6) stays intact.

  `WorldDriven` remains the Session policy and the deterministic fallback when
  this agent fails or picks an invalid target.
  """

  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.TurnMaster.Tools
  alias Dragonex.World

  @doc "Orchestration tool set (not the 5e resolution tools)."
  @spec tools() :: [term()]
  def tools do
    Enum.map(Tools.tools(), fn tool ->
      call = tool.call

      %{
        tool
        | call: fn ctx, args ->
            Dragonex.I18n.adopt(ctx.deps)

            case call.(ctx, args) do
              {:error, message} when is_binary(message) -> raise ExAgent.ModelRetry, message
              result -> result
            end
          end
      }
    end)
  end

  @doc """
  Build the TurnMaster agent.

  Options:
    * `:max_tokens` — output cap (default 1024, env-overridable; one decision
      tool-call, including the provider's reasoning budget).
    * `:max_steps`  — agentic loop cap (default 3: one decision + one retry +
      margin). A healthy TM decides in a single tool-call; the exAgent default
      of 50 let a looping LLM stall the beat ~50s and burn ~50 calls before
      the WorldDriven fallback kicked in (playtest 2026-09-16).
  """
  @spec new(term(), keyword()) :: ExAgent.t()
  def new(model, opts \\ []) do
    max_tokens = Keyword.get(opts, :max_tokens, Dragonex.Models.turnmaster_max_tokens())
    max_steps = Keyword.get(opts, :max_steps, 3)

    ExAgent.new(
      model: model,
      instructions: system_prompt(),
      tools: tools(),
      max_steps: max_steps,
      model_settings:
        Dragonex.Models.request_settings(
          model,
          [max_tokens: max_tokens, temperature: 0.3],
          Dragonex.Models.request_extra()
        ),
      # No Events capability: TurnMaster does not narrate. The Game appends a
      # short :system line when it applies the decision.
      capabilities:
        Dragonex.Agent.capabilities([Dragonex.Game.RunLifecycle, Dragonex.AgentInstructions])
    )
  end

  # Provider knobs (reasoning effort + OpenRouter provider order) ride in
  # ModelSettings.extra, the same channel the DM uses.
  @doc "Stable system contract (cacheable prefix)."
  @spec system_prompt() :: String.t()
  def system_prompt do
    dgettext("prompts", """
    Eres el TurnMaster de una partida de D&D 5e. Tu ÚNICA salida es decidir quién actúa a continuación llamando a UNA herramienta. Nunca narras ficción, nunca resuelves tiradas, nunca escribes prosa para el jugador.

    REGLAS:
    1. Llama exactamente a UNA tool por beat; a continuación responde únicamente el texto exacto «listo» (sin más tool-calls, sin prosa). Si la tool devuelve un error, corrige con otra tool válida y responde «listo» después de ella.
    2. COMBATE: sigue el `initiative_order` del brief. Cede a cada combatiente consciente una vez por ronda (`give_turn_to`). Excepciones solo con `cut_in` / `react` cuando el contexto las justifica (ataque de oportunidad, acción preparada, interrupción dramática). Los mini-turnos de cut_in/react NO gastan el turno principal del reactor.
     3. EXPLORACIÓN: el default DESPUÉS de un PC es `pass_to_dm` (el mundo/PNJ responde). No des el siguiente PC hasta que el DM haya narrado la consecuencia. Usa `give_turn_to` a otro PC solo si reacciona a algo que no necesita al DM. Evita el ping-pong PC↔PC.
     4. Equidad: no repitas al mismo actor sin motivo; no dejes a nadie sin turno en una ronda de combate.
     5. Nunca elijas a un participante inexistente, muerto, o enemigo ya caído. El DM (`dm`) siempre es válido.
      6. `end_scene` cierra el combate/encuentro y vuelve a exploración (el motor aplica el cambio).
      7. Si el brief lista `acted_this_round`, prioriza a quien aún no haya actuado en la ronda.
      8. INTENCIONES HUMANAS: son declaraciones reales de jugadores (nunca de bots). En EXPLORACIÓN, prioriza a quien tiene algo escrito; si el último actor habló con un PNJ o preguntó algo al mundo, `pass_to_dm` ANTES de ceder a otro PC. En COMBATE, si un humano escribió interrumpo/reacción/me pongo delante/escudo/protejo, DEBES `cut_in` o `react` a ese humano AHORA — no esperes al `initiative_order`. No robes la ronda entera a un humano que encola cada turno.
    """)
    |> String.trim()
  end

  @doc """
  Per-beat instruction: who just acted and what the TurnMaster must decide.
  """
  @spec instruction(String.t() | nil, World.t(), keyword()) :: String.t()
  def instruction(_last_actor, %World{} = _world, opts \\ []) do
    nudge = Keyword.get(opts, :nudge, nil)
    interrupted = Keyword.get(opts, :interrupted, nil)
    pending = Keyword.get(opts, :pending_intents, %{})

    interrupt =
      if is_binary(interrupted) and interrupted != "" do
        dgettext(
          "prompts",
          "Hay un actor interrumpido esperando retomar: %{actor}. Tras el mini-turno, devuélvele la palabra salvo nueva excepción.",
          actor: interrupted
        )
      else
        ""
      end

    pending_line =
      case pending_intent_names(pending) do
        [] ->
          ""

        names ->
          dgettext(
            "prompts",
            "Hay intenciones humanas pendientes de: %{names}. En combate, si suenan a reacción (interrumpo, escudo, me pongo delante), usa cut_in/react AHORA. En exploración, priorízalos o pasa al DM si el mundo debe responder.",
            names: Enum.join(names, ", ")
          )
      end

    nudge_line =
      if is_binary(nudge) and nudge != "",
        do: dgettext("prompts", "AVISO: %{nudge}", nudge: nudge),
        else: ""

    [
      interrupt,
      pending_line,
      Dragonex.ExplorationTurns.brief(Keyword.get(opts, :exploration)),
      nudge_line,
      dgettext(
        "prompts",
        "Decide quién actúa ahora. Una sola tool-call y luego responde «listo»."
      )
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @doc """
  Human-readable system note for a applied decision (UI / history).
  """
  @spec decision_note(map()) :: String.t()
  # System notes (UI + history) belong to the `engine` domain.
  def decision_note(%{action: :give_turn_to, to: to}),
    do: dgettext("engine", "El turno pasa a %{next}.", next: to)

  def decision_note(%{action: :cut_in, to: to}),
    do: dgettext("engine", "%{actor} interrumpe.", actor: to)

  def decision_note(%{action: :react, to: to}),
    do: dgettext("engine", "%{actor} reacciona.", actor: to)

  def decision_note(%{action: :pass_to_dm}), do: dgettext("engine", "El turno pasa al DM.")

  def decision_note(%{action: :end_scene}),
    do: dgettext("engine", "La escena termina. Vuelta a exploración.")

  def decision_note(%{action: action, to: to}) when is_atom(action), do: "#{action} → #{to}"
  def decision_note(_), do: dgettext("engine", "El motor toma el relevo del turno.")

  defp pending_intent_names(intents) when is_map(intents) do
    intents
    |> Enum.filter(fn {_name, raw} ->
      Dragonex.Intents.present?(raw)
    end)
    |> Enum.map(fn {name, _} -> to_string(name) end)
    |> Enum.sort()
  end

  defp pending_intent_names(_), do: []
end
