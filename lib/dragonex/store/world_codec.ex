defmodule Dragonex.Store.WorldCodec do
  @moduledoc "Codec de World para la frontera validada de Session en exAgent v2."

  def encode(%Dragonex.World{} = world), do: {:ok, Dragonex.Codec.encode(world)}
  def encode(_), do: {:error, :invalid_world}

  def decode(%{"characters" => characters, "phase" => phase} = data)
      when is_map(characters) and phase in ["exploration", "combat"],
      do: {:ok, Dragonex.Codec.decode(data)}

  def decode(_), do: {:error, :invalid_world}
end
