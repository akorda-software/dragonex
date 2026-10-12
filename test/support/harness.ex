defmodule Dragonex.Test.Harness do
  @moduledoc """
  Shared helpers for the D&D flow tests: build agents whose tools mutate the
  world via SharedState, start sessions, and drive one participant's turn.
  """

  alias ExAgent.{Models.Test, Server, Session}
  alias ExAgent.Message.Part
  alias ExAgent.Session.{Participant, SharedState}
  alias Dragonex.{Tools, World}

  @doc "A roller that always returns a fixed value (deterministic combat)."
  def fixed_roller(value), do: Dragonex.Dice.always(value)

  @doc """
  `setup :skip_failed_turns` — exercise the skip path of a failed actor turn
  directly, without the first-failure pause and resume of D228.
  """
  def skip_failed_turns(_context) do
    Application.put_env(:dragonex, :retain_failed_turns, false)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dragonex, :retain_failed_turns) end)
    :ok
  end

  @doc "Bundle deps the tools expect: the SharedState handle + a dice roller."
  def deps_for(session, participant, roller) do
    %{state: SharedState.new(session, participant), roller: roller}
  end

  @doc "Start a DM agent with the game tools, scripted to do `script` in order."
  def start_dm(opts) do
    id = Keyword.fetch!(opts, :id)
    script = Keyword.fetch!(opts, :script)

    agent =
      ExAgent.new(
        model: %Test{script: script},
        instructions: "You are the Dungeon Master.",
        tools: Tools.agent_tools()
      )

    ExUnit.Callbacks.start_supervised!({Server, agent: agent, agent_id: id})
  end

  @doc "Drive one participant's turn: chat with bundled deps, then end the turn."
  def take_turn(session, participant, server, roller) do
    with {:ok, %{output: _}} <-
           Server.chat(server, "your turn", deps: deps_for(session, participant, roller)),
         {:ok, _next} <- Session.end_turn(session, participant) do
      :ok
    end
  end

  @doc "A scripted tool call part, for readable TestModel scripts."
  def call(tool_name, args) do
    %Part.ToolCall{tool_name: tool_name, args: args}
  end

  def text(t) when is_binary(t), do: t
  def tool_calls(calls) when is_list(calls), do: {:tool_calls, calls}

  @doc "An explicit typed public closure for a DM/PC narration script."
  def narration(text) when is_binary(text),
    do: tool_calls([call("final_result", %{"text" => text})])

  @doc "A native response carrying an explicit typed public closure."
  def narration_response(text) when is_binary(text),
    do:
      ExAgent.Message.new_response([call("final_result", %{"text" => text})],
        finish_reason: :tool_calls
      )

  @doc "Terminal de streaming del contrato de exAgent 2.x."
  def stream_response(response, model), do: {:response, response, model}

  @doc "Start a session with the given policy and participants."
  def start_session(opts) do
    sid = "game-#{:erlang.unique_integer([:positive])}"

    {:ok, session} =
      Session.start_link(
        shared_state: Keyword.get(opts, :world, World.new()),
        policy: Keyword.fetch!(opts, :policy),
        participants: Keyword.fetch!(opts, :participants),
        session_id: sid,
        pubsub: Keyword.get(opts, :pubsub)
      )

    session
  end

  @doc "participant/1 convenience."
  def p(id, kind \\ :agent, ref \\ nil),
    do: Participant.new(id: id, kind: if(kind in [:ai, :other], do: :agent, else: kind), ref: ref)
end
