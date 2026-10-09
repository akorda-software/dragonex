---
name: exagent-run-agent
description: >
  Use this skill when integrating the `exagent` Hex package's one-shot agent loop
  (Layer 0) in an Elixir app: building an agent with `ExAgent.new/1`, running it
  with `ExAgent.run/3` / `run!/3` / `run_stream/3`, choosing a model
  (`"openai:"`, `"anthropic:"`, `"openrouter:"`, `"zai:"` or `"test"`), getting
  structured output via an Ecto `embedded_schema`, or streaming text deltas.
  Triggers: exagent agent, run agent, ExAgent.new, ExAgent.run, structured
  output, run_stream, modelo de agente, agente one-shot, integrar exagent.
---

# exagent-run-agent — the one-shot agent loop (Layer 0)

`ExAgent` is an agent = **model + instructions + tools + output spec**, run as a
recursion that alternates *call the model* ⇄ *execute tools* until a final result.
This skill covers the core loop (`ExAgent.run/3`). For tools see `exagent-tools`;
for a long-lived stateful agent see `exagent-server`.

## Prerequisites

The host app depends on exagent (it starts its own supervised `Finch`, `Registry`,
`Task.Supervisor`, `Store.ETS` and `AgentSupervisor`):

```elixir
# mix.exs
def deps do
  [{:exagent, path: "../exAgent"}]
end
```

This skill describes the unreleased major checkout, not published1.x. ReqLLM stock
is the sole general backend; pass credentials explicitly per instance. Disable
upstream dotenv with `config :req_llm, load_dotenv: false` if the app owns env loading.
For offline/dev use `model: "test"` — no key.

## Workflow

### 1. Build the agent, run it once

```elixir
{:ok, model} = ExAgent.Model.resolve("openai:gpt-4o", api_key: System.fetch_env!("OPENAI_API_KEY"))
agent = ExAgent.new(model: model, instructions: "Be concise.")
{:ok, %{output: text}} = ExAgent.run(agent, "Hello!")
```

Operational failures return `{:error, %ExAgent.RunError{reason: cause, partial: result}}`.
Construction errors can raise.
`result` is a map: `:output`, `:messages`, `:new_messages`, `:usage`
(`%{input_tokens:, output_tokens:}`), `:run_step`, `:model`.
`run!/3` returns `output` directly and raises on error.

### 2. Choose a model

Resolve stock strings/maps/tuples through `Model.resolve/2` with instance options,
or pass a custom Model struct. Strings alone resolve identity, not auth or tools.
For tools/Ecto-tool/stream select the actual Chat-compatible non-reasoning profile:

```elixir
chat_model = ExAgent.Models.ReqLLM.new(
  model: %{provider: :openai, id: "gpt-4o-mini",
    capabilities: %{tools: %{enabled: true}, reasoning: %{enabled: false}},
    extra: %{wire: %{protocol: "openai_chat"}}},
  api_key: System.fetch_env!("OPENAI_API_KEY"), tool_profile: :chat_tools_v1)
ExAgent.new(model: chat_model)
ExAgent.new(model: "test")
```

Custom gateways require explicit `base_url`, exact model ID and actual capabilities.
OpenCode Go/Zen have distinct URLs; `zai:` now resolves stock ZAI, not the old
Anthropic alias. Anthropic `auth_token` maps to stock Bearer auth, but affected
reasoning/continuation/tools remain closed. See `docs/guides/migration.md` for
recipes and limits. No profile is certified live merely by catalogue membership.

### 3. Structured output (any Ecto `embedded_schema`)

Define a schema with a `changeset/2`. JSON Schema is derived from the schema
**and** the changeset validations (`validate_inclusion`/`Ecto.Enum` → `enum`,
`validate_number` → `minimum`/`maximum`, `validate_length` → `minLength`/`maxLength`),
so the model can comply instead of guessing and being retried.

```elixir
defmodule MyApp.Extract do
  use Ecto.Schema
  @primary_key false
  embedded_schema do
    field(:name, :string)
    field(:age, :integer)
    field(:mood, Ecto.Enum, values: [:happy, :sad, :neutral])
  end

  def changeset(s, a) do
    s
    |> Ecto.Changeset.cast(a, [:name, :age, :mood])
    |> Ecto.Changeset.validate_required([:name, :age])
    |> Ecto.Changeset.validate_number(:age, greater_than: 0, less_than: 150)
  end
end

agent = ExAgent.new(model: chat_model, output: MyApp.Extract,
  instructions: "Extract structured data.", model_settings: [max_tokens: 512, temperature: 0.0])

{:ok, %{output: %MyApp.Extract{name: "Mara", age: 30, mood: :happy}}} =
  ExAgent.run(agent, "Hi! I'm Mara, I'm 30 and happy.")
```

With `output:`, the model is forced to call an internal `final_result` tool whose
args match the schema; exAgent validates with the changeset and retries on failure
(`:output` defaults to `:text` = free-text responses allowed).

### 4. Streaming text deltas

`run_stream/3` returns a lazy stream. Best for chat/typewriter UIs. It yields
`{:delta, binary}` per chunk then `{:result, map}` or an error. It uses the full
agentic loop; provisional deltas never authorize effects before a valid terminal.

```elixir
ExAgent.run_stream(agent, "count to five")
|> Stream.each(fn
  {:delta, t} -> IO.write(t)
  {:result, %{usage: u}} -> IO.puts("\n#{u.output_tokens} out tokens")
  {:error, reason} -> IO.puts("\nERROR: #{inspect(reason)}")
end)
|> Stream.run()
```

### 5. Continue/resume a conversation (DB-free)

The core owns no DB. Serialize history, store it anywhere, reload it:

```elixir
json = ExAgent.Message.to_json(result.messages)       # persist this
{:ok, history} = ExAgent.Message.from_json(json)      # load it back
ExAgent.run(agent, "follow up", message_history: history)
```

History/checkpoints are not mid-run recovery; replaying an Oban job can repeat
effects. Persisted approval/continuation C7 remains pending.

## `ExAgent.new/1` options

| key | default | notes |
|---|---|---|
| `:model` | — | **required**. `"provider:model"` string or struct. |
| `:instructions` | `[]` | string or list of strings → system parts. |
| `:tools` | `[]` | `[ExAgent.Tool.t()]`, usually `MyApp.Tools.tools()`. |
| `:output` / `:output_type` | `:text` | an Ecto schema module for structured output. |
| `:model_settings` | `%{}` | `[max_tokens:, temperature:, cache:, ...]`. |
| `:output_retries` | `1` | retries on output-validation failure. |
| `:max_steps` | `50` | cap on model⇄tool iterations. |
| `:tool_timeout` | `30_000` | ms per tool call. |
| `:usage_limits` | `nil` | `%ExAgent.UsageLimits{}` (request/tool/budget caps). |
| `:capabilities` | `[]` | middleware (compaction, etc.). |

`run/3` options: `:deps` (DI value threaded into `RunContext.deps` for tools),
`:message_history` (prior `Message.t()` list), `:model_settings` (per-run override).

## Gotchas

- Match operational `RunError.reason` and preserve its partial result; do not
  serialize live results containing credentials into logs/events.
- `model: "test"` is the offline TestModel — perfect for dev/demos with no API
  key and no network (see `exagent-test`).
- With `output: Module`, the model is **forced** to call the `final_result` tool;
  free-text answers are rejected and retried.
- `instructions` can be a string **or** a list of strings (each becomes a system part).
- Invalid envelopes/history/terminals reject before effects. Stock usage is
  normalized with unknown presence; strict metric limits reject, estimated mode
  requires a finite request bound and never promises an invoice cap.
- ExAgent's own `Agent` does **not** shadow OTP's `Agent` unless you `alias Agent`.

## Troubleshooting

- `** (ArgumentError) ...` on `new/1` → you omitted `:model` or used an unknown
  provider prefix. Check `Model.resolve/1` returns `{:ok, _}`.
- Output retries exhausted / model returns text not matching the schema → tighten
  the changeset (more `validate_*`) so the JSON Schema guides the model, and/or
  raise `:output_retries`.
- `{:error, {:model_request_failed, %ExAgent.RequestError{status: 401}}}` →
  missing/wrong API key env var for that provider.
- Hangs on `run/3` → a tool may be slow; raise `:tool_timeout` or check the tool
  is not blocking forever. Long runs are expected (`chat/3` uses `:infinity`).

## Validation

- Smoke test offline: `ExAgent.new(model: "test") |> ExAgent.run("hi")` → `{:ok, _}`.
- Run an example: `mix run examples/demo.exs` (no key needed).
