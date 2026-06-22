defmodule DragonesWeb.ConnCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.LiveViewTest
      import Phoenix.ConnTest
      import Plug.Conn
      @endpoint DragonesWeb.Endpoint
    end
  end

  setup _ do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
