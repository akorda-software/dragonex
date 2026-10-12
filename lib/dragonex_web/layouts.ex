defmodule DragonexWeb.Layouts do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: Dragonex.Gettext

  embed_templates("layouts/*")
end
