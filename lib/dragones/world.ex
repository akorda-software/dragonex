defmodule Dragones.World do
  @moduledoc """
  The shared game world. A single plain struct mutated only through the
  Session (single-writer rule); tools propose changes via SharedState.

  Kept deliberately small for the spike — a real game would model more (terrain,
  lighting, conditions, inventory ...) but the shape is what matters: the world
  is what every participant reads and the Session is the only writer.
  """

  defstruct scene: "an unremarkable crossroads",
            round: 1,
            # name => %{hp, max_hp}
            characters: %{},
            log: []

  @type t :: %__MODULE__{
          scene: String.t(),
          round: pos_integer(),
          characters: %{String.t() => map()},
          log: [{String.t(), String.t()}]
        }

  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end

  # Composable change helpers. Each returns a function suitable for
  # SharedState.propose_change/2 (world -> {:ok, new_world}).
  def set_scene(text),
    do: fn w -> {:ok, %{w | scene: text, log: [{"dm", "scene: #{text}"} | w.log]}} end

  def narrate(actor, text),
    do: fn w -> {:ok, %{w | log: [{actor, text} | w.log]}} end

  def damage(target, amount),
    do: fn w ->
      case Map.get(w.characters, target) do
        nil ->
          {:error, "no such character: #{target}"}

        %{hp: hp} = ch ->
          new_hp = max(0, hp - amount)
          {:ok, %{w | characters: Map.put(w.characters, target, %{ch | hp: new_hp})}}
      end
    end

  def add_character(name, hp),
    do: fn w -> {:ok, %{w | characters: Map.put(w.characters, name, %{hp: hp, max_hp: hp})}} end

  def next_round,
    do: fn w -> {:ok, %{w | round: w.round + 1}} end

  def dead?(%__MODULE__{characters: chars}, name) do
    case chars[name] do
      %{hp: hp} -> hp <= 0
      _ -> false
    end
  end
end
