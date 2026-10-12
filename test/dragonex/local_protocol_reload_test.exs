defmodule Dragonex.LocalProtocolReloadTest do
  use ExUnit.Case, async: false

  test "new local package types can derive a JSON encoder after the project is compiled" do
    module = Dragonex.Test.ReloadedPackageType
    encoder = Jason.Encoder.Dragonex.Test.ReloadedPackageType

    on_exit(fn ->
      for name <- [encoder, module] do
        :code.purge(name)
        :code.delete(name)
      end
    end)

    Code.compile_quoted(
      quote do
        defmodule Dragonex.Test.ReloadedPackageType do
          @derive Jason.Encoder
          defstruct [:phase, :revision]
        end
      end
    )

    value = struct!(module, phase: "ready", revision: 2)
    assert Jason.decode!(Jason.encode!(value)) == %{"phase" => "ready", "revision" => 2}
    refute Protocol.consolidated?(Jason.Encoder)
  end
end
