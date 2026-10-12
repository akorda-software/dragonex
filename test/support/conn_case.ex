defmodule DragonexWeb.ConnCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.LiveViewTest,
        except: [
          live: 1,
          live: 2,
          live: 3,
          live_isolated: 2,
          live_isolated: 3,
          follow_redirect: 2,
          follow_redirect: 3
        ]

      import Dragonex.Test.LiveViewFixture,
        only: [
          live: 1,
          live: 2,
          live: 3,
          live_isolated: 2,
          live_isolated: 3,
          follow_redirect: 2,
          follow_redirect: 3
        ]

      import Phoenix.ConnTest
      import Plug.Conn
      @endpoint DragonexWeb.Endpoint
    end
  end

  setup _ do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
