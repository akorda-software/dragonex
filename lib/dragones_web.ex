defmodule DragonesWeb do
  @moduledoc """
  The entrypoint for defining web interfaces (controllers, HTML views).
  """

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html],
        layouts: [html: {DragonesWeb.Layouts, :app}]

      import Plug.Conn
      alias DragonesWeb.Router.Helpers, as: Routes
    end
  end

  def html do
    quote do
      use Phoenix.Component
    end
  end

  @doc false
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
