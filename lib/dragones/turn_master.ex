defmodule Dragones.TurnMaster do
  @moduledoc """
  Turn-orchestration agent (D25). Decides **who acts next**; never narrates
  fiction and never resolves rolls.

  Tools only **record** a decision (`Dragones.TurnMaster.Decision`). The
  `Dragones.Game` GenServer applies it via `Session.handoff/2` /
  `Session.update_state/3` — single-writer (D6) stays intact.

  `WorldDriven` remains the Session policy and the deterministic fallback when
  this agent fails or picks an invalid target.
  """

  alias Dragones.TurnMaster.Tools
  alias Dragones.World

  @doc "Orchestration tool set (not the 5e resolution tools)."
  @spec tools() :: [term()]
  def tools, do: Tools.tools()

  @doc """
  Build the TurnMaster agent.

  Options:
    * `:max_tokens` — output cap (default 256; one tool-call, no prose).
  """
  @spec new(term(), keyword()) :: ExAgent.t()
  def new(model, opts \\ []) do
    max_tokens = Keyword.get(opts, :max_tokens, 256)

    ExAgent.new(
      model: model,
      instructions: system_prompt(),
      tools: tools(),
      model_settings: [
        max_tokens: max_tokens,
        temperature: 0.3
      ],
      # No Events capability: TurnMaster does not narrate. The Game appends a
      # short :system line when it applies the decision.
      capabilities: []
    )
  end

  @doc "Stable system contract (cacheable prefix)."
  @spec system_prompt() :: String.t()
  def system_prompt do
    """
    Eres el TurnMaster de una partida de D&D 5e. Tu ÚNICA salida es decidir quién actúa a continuación llamando a UNA herramienta. Nunca narras ficción, nunca resuelves tiradas, nunca escribes prosa para el jugador.

    REGLAS:
    1. Llama exactamente a UNA tool por beat. Sin texto libre.
    2. COMBATE: sigue el `initiative_order` del brief. Cede a cada combatiente consciente una vez por ronda (`give_turn_to`). Excepciones solo con `cut_in` / `react` cuando el contexto las justifica (ataque de oportunidad, acción preparada, interrupción dramática). Los mini-turnos de cut_in/react NO gastan el turno principal del reactor.
    3. EXPLORACIÓN: reparte la palabra con criterio dramático (quien reacciona a lo último, quien tiene algo que decir). Evita el round-robin plano. Usa `pass_to_dm` para abrir/cerrar escena, narrar entorno o dar voz a PNJs.
    4. Equidad: no repitas al mismo actor sin motivo; no dejes a nadie sin turno en una ronda de combate.
    5. Nunca elijas a un participante inexistente, muerto, o enemigo ya caído. El DM (`dm`) siempre es válido.
    6. `end_scene` cierra el combate/encuentro y vuelve a exploración (el motor aplica el cambio).
    7. Si el brief lista `acted_this_round`, prioriza a quien aún no haya actuado en la ronda.
    """
    |> String.trim()
  end

  @doc """
  Per-beat instruction: who just acted and what the TurnMaster must decide.
  """
  @spec instruction(String.t() | nil, World.t(), keyword()) :: String.t()
  def instruction(last_actor, %World{} = world, opts \\ []) do
    participants = Keyword.get(opts, :participants, [])
    nudge = Keyword.get(opts, :nudge, nil)
    interrupted = Keyword.get(opts, :interrupted, nil)

    last =
      case last_actor do
        nil -> "Nadie ha actuado aún (arranque de escena)."
        name -> "Acaba de actuar: #{name}."
      end

    phase =
      case world.phase do
        :combat ->
          order = Enum.join(world.initiative_order || [], " → ")
          acted = acted_line(world)
          "Fase: COMBATE ronda #{world.round}. Iniciativa: #{order}.#{acted}"

        _ ->
          "Fase: EXPLORACIÓN."
      end

    roster =
      if participants == [] do
        ""
      else
        "Participantes: #{Enum.join(participants, ", ")}."
      end

    interrupt =
      if is_binary(interrupted) and interrupted != "" do
        "Hay un actor interrumpido esperando retomar: #{interrupted}. Tras el mini-turno, devuélvele la palabra salvo nueva excepción."
      else
        ""
      end

    nudge_line = if is_binary(nudge) and nudge != "", do: "AVISO: #{nudge}", else: ""

    [
      last,
      phase,
      roster,
      interrupt,
      nudge_line,
      "Decide quién actúa ahora. Una sola tool-call."
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @doc """
  Human-readable system note for a applied decision (UI / history).
  """
  @spec decision_note(map()) :: String.t()
  def decision_note(%{action: :give_turn_to, to: to}), do: "El turno pasa a #{to}."
  def decision_note(%{action: :cut_in, to: to}), do: "#{to} interrumpe."
  def decision_note(%{action: :react, to: to}), do: "#{to} reacciona."
  def decision_note(%{action: :pass_to_dm}), do: "El turno pasa al DM."
  def decision_note(%{action: :end_scene}), do: "La escena termina. Vuelta a exploración."
  def decision_note(%{action: action, to: to}) when is_atom(action), do: "#{action} → #{to}"
  def decision_note(_), do: "El motor toma el relevo del turno."

  defp acted_line(%World{acted_this_round: acted}) when is_struct(acted, MapSet) do
    case MapSet.to_list(acted) do
      [] -> " Aún no ha actuado nadie esta ronda."
      names -> " Ya actuaron esta ronda: #{Enum.join(Enum.sort(names), ", ")}."
    end
  end

  defp acted_line(_), do: ""
end
