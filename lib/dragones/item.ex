defmodule Dragones.Item do
  @moduledoc "An inventory item."

  defstruct [:name, :qty, :kind]

  @type t :: %__MODULE__{
          name: String.t(),
          qty: pos_integer(),
          kind: atom()
        }
end
