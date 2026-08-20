defmodule Dragones.ModelsTurnmasterTest do
  use ExUnit.Case, async: true

  alias Dragones.Models

  test "turnmaster/0 builds a model struct (Test offline, live provider when keyed)" do
    model = Models.turnmaster()
    # With an API key in .env.dev this is a live provider struct; without it, Test.
    assert is_struct(model)
  end
end
