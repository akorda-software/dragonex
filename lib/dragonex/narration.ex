defmodule Dragonex.Narration do
  @moduledoc """
  Public prose returned through exAgent's structured output tool. This schema
  checks the envelope, not whether every sentence agrees with the World.
  Roster-aware sanitization happens at the publication boundary.
  """
  use Ecto.Schema
  use Gettext, backend: Dragonex.Gettext
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:text, :string)
  end

  def changeset(output, attrs) do
    output
    |> cast(attrs, [:text])
    |> update_change(:text, &String.trim/1)
    |> validate_required([:text])
    |> validate_length(:text, min: 1, max: 8000, count: :codepoints)
    |> validate_change(:text, fn :text, text ->
      if String.valid?(text),
        do: [],
        else: [text: dgettext("engine", "debe ser UTF-8 válido")]
    end)
  end

  @doc "Explicit intermediate public speech; the actor and turn come from the engine."
  def tool do
    ExAgent.Tool.new(
      name: "narrate",
      description:
        "Publish a brief declaration before resolving actions, or an intermediate reaction. " <>
          "It does not close the turn. Use only the text field, written in the language of the game; " <>
          "include no internal deliberation and no results not yet applied. A human player's voice " <>
          "belongs to them. To close, use final_result in a separate reply, after resolving tools.",
      parameters_json_schema: ExAgent.OutputSchema.json_schema(__MODULE__),
      takes_ctx: true,
      call: fn ctx, args ->
        Dragonex.I18n.adopt(ctx.deps)

        case Dragonex.Narration.Contract.publish_intermediate(args, ctx.deps) do
          {:ok, _speech} ->
            {:ok,
             dgettext(
               "engine",
               "Narración pública registrada y ya visible; el turno sigue abierto. " <>
                 "El cierre no debe repetirla: continúa con lo que cambie después."
             )}

          {:error, reason} ->
            raise ExAgent.ModelRetry, Dragonex.Narration.Contract.feedback(reason)
        end
      end
    )
    |> Dragonex.Game.ToolReplay.wrap()
  end
end
