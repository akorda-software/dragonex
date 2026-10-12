defmodule DragonexWeb.ErrorTranslation do
  @moduledoc """
  Changeset errors in the active locale. Ecto's defaults have English msgids
  (Spanish in `priv/gettext/es/LC_MESSAGES/errors.po`); Dragonex's own
  messages are already localized when the changeset is built and pass through.
  """

  @doc "Translate one `{message, opts}` error, filling its bindings."
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(Dragonex.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(Dragonex.Gettext, "errors", msg, opts)
    end
  end

  @doc "All messages of a changeset, translated, unique, joined for a flash."
  def flash_message(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map(fn {_field, error} -> translate_error(error) end)
    |> Enum.uniq()
    |> Enum.join("; ")
  end
end
