defmodule Dragonex.Gettext do
  @moduledoc """
  Message catalog of the engine, prompts and interface (D236).

  Source strings (msgids) are the Spanish texts: with the Spanish locale the
  output is the msgid itself, byte for byte. `priv/gettext/en` carries the
  English catalog. Use `Dragonex.I18n` to set the locale; it keeps this
  backend in sync per process.

  Domains: `engine` (rules feedback, errors, roll reasons, system notes),
  `prompts` (agent instructions) and `ui` (LiveView text).
  """
  use Gettext.Backend, otp_app: :dragonex, default_locale: "es"
end
