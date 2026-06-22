defmodule Dragones.World do
  @moduledoc """
  The shared game world — the combat state machine + cast, mutated ONLY through
  the Session (single-writer rule). Tools propose changes via SharedState.

  Every mutator is a *change function*: `name(args) -> (world -> {:ok, world} |
  {:error, reason})`, so it composes directly with
  `ExAgent.Session.SharedState.propose_change/2` and is trivially testable on its
  own (`World.apply_damage("goblin", 3).(world)`).

  Invariants enforced by the transitions (not by the LLM):

    * damage floors at 0,
    * you can't damage/heal a missing character,
    * `begin_combat` requires the exploration phase and known combatants,
    * the death-save tracker resolves dead (3 fails) / stable (3 successes) /
      revive (nat 20).

  Characters are stored as full `Dragones.Character` structs, so the engine can
  read any stat (AC, abilities, weapons ...) straight from the world.
  """

  alias Dragones.Character

  defstruct scene: "an unremarkable crossroads",
            phase: :exploration,
            round: 1,
            characters: %{},
            initiative_order: [],
            log: []

  @type phase :: :exploration | :combat

  @type t :: %__MODULE__{
          scene: String.t(),
          phase: phase(),
          round: pos_integer(),
          characters: %{String.t() => Character.t()},
          initiative_order: [String.t()],
          log: [{String.t(), String.t()}]
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct(__MODULE__, opts)

  # ---------------------------------------------------------------- queries

  @doc "Look up a character by name."
  @spec character(t(), String.t()) :: Character.t() | nil
  def character(%__MODULE__{} = w, name), do: Map.get(w.characters, name)

  @doc "Down/incapacitated: hp at or below 0 (dying, not yet dead)."
  @spec down?(t(), String.t()) :: boolean()
  def down?(%__MODULE__{} = w, name) do
    case character(w, name) do
      %Character{hp: hp} when hp <= 0 -> true
      _ -> false
    end
  end

  @doc "Truly dead: three failed death saves."
  @spec dead?(t(), String.t()) :: boolean()
  def dead?(%__MODULE__{} = w, name) do
    case character(w, name) do
      %Character{death_saves: %{fails: f}} when f >= 3 -> true
      _ -> false
    end
  end

  @doc "Combat is over once at most one side still has conscious (hp > 0) fighters."
  @spec combat_over?(t()) :: boolean()
  def combat_over?(%__MODULE__{phase: :combat, characters: chars}) do
    chars
    |> Map.values()
    |> Enum.filter(&(&1.hp > 0))
    |> Enum.map(& &1.side)
    |> Enum.uniq()
    |> length() <= 1
  end

  def combat_over?(_), do: false

  @doc """
  Does `proposer` control the character `name`? The invariant that stops a
  monster from acting on a player's turn (and vice versa):

    * a PC is controlled only by the participant whose id is the PC's own name;
    * a non-PC (monster/NPC) is controlled by any participant who is NOT a PC
      (i.e. the DM), so the DM runs all its monsters.

  This is a guard the tools enforce before resolving an action.
  """
  @spec controlled_by?(t(), String.t(), String.t()) :: boolean()
  def controlled_by?(%__MODULE__{} = w, name, proposer) do
    pcs = Enum.filter(Map.values(w.characters), &(&1.side == "pc" and &1.name == proposer))

    case character(w, name) do
      nil -> false
      %Character{side: "pc"} = c -> proposer == c.name
      %Character{} -> pcs == []
    end
  end

  # ---------------------------------------------------------- change functions

  @spec set_scene(String.t()) :: (t() -> {:ok, t()})
  def set_scene(text) do
    fn w -> {:ok, %{w | scene: text, log: log(w, "dm", "scene: #{text}")}} end
  end

  @spec narrate(String.t(), String.t()) :: (t() -> {:ok, t()})
  def narrate(actor, text) do
    fn w -> {:ok, %{w | log: log(w, actor, text)}} end
  end

  @spec add_character(Character.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def add_character(%Character{} = c) do
    fn w ->
      if Map.has_key?(w.characters, c.name) do
        {:error, "character already exists: #{c.name}"}
      else
        {:ok,
         %{
           w
           | characters: Map.put(w.characters, c.name, c),
             log: log(w, "dm", "#{c.name} appears")
         }}
      end
    end
  end

  @spec apply_damage(String.t(), non_neg_integer()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def apply_damage(target, amount) do
    fn w ->
      case character(w, target) do
        nil ->
          {:error, "no such character: #{target}"}

        %Character{} = c ->
          new_hp = max(0, c.hp - amount)
          {:ok, %{w | characters: Map.put(w.characters, target, %{c | hp: new_hp})}}
      end
    end
  end

  @spec heal(String.t(), non_neg_integer()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def heal(target, amount) do
    fn w ->
      case character(w, target) do
        nil ->
          {:error, "no such character: #{target}"}

        %Character{hp: hp, max_hp: max_hp} = c ->
          new_hp = min(max_hp, hp + amount)
          {:ok, put_char(w, target, %{c | hp: new_hp, death_saves: fresh_saves()})}
      end
    end
  end

  @doc """
  Enter combat with an already-ordered initiative list (highest first).
  Requires the exploration phase and that every name exists.
  """
  @spec begin_combat([String.t()]) :: (t() -> {:ok, t()} | {:error, String.t()})
  def begin_combat(initiative_order) do
    fn w ->
      cond do
        w.phase != :exploration ->
          {:error, "already in combat"}

        Enum.empty?(initiative_order) ->
          {:error, "initiative order is empty"}

        not Enum.all?(initiative_order, &Map.has_key?(w.characters, &1)) ->
          {:error, "initiative order references unknown characters"}

        true ->
          {:ok,
           %{
             w
             | phase: :combat,
               initiative_order: initiative_order,
               log: log(w, "dm", "combat begins: #{Enum.join(initiative_order, " → ")}")
           }}
      end
    end
  end

  @spec end_combat() :: (t() -> {:ok, t()})
  def end_combat do
    fn w -> {:ok, %{w | phase: :exploration, log: log(w, "dm", "combat ends")}} end
  end

  @doc "Bump the round counter directly (kept for the spike's exploration flows)."
  @spec next_round() :: (t() -> {:ok, t()})
  def next_round do
    fn w -> {:ok, %{w | round: w.round + 1}} end
  end

  @doc """
  Apply a `Dragones.Rules.Combat.death_save/1` result to a character's tracker.
  Three fails mark them dead; three successes stable; a nat 20 revives at 1 hp.
  """
  @spec apply_death_save(String.t(), tuple()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def apply_death_save(target, result) do
    fn w ->
      case character(w, target) do
        nil ->
          {:error, "no such character: #{target}"}

        %Character{} = c ->
          {:ok, put_char(w, target, resolve_death_save(c, result))}
      end
    end
  end

  # ----------------------------------------------------------------- helpers

  defp log(%__MODULE__{log: l}, actor, entry), do: [{actor, entry} | l]

  defp put_char(%__MODULE__{characters: chars} = w, name, %Character{} = c),
    do: %{w | characters: Map.put(chars, name, c)}

  defp fresh_saves, do: %{successes: 0, fails: 0}

  defp resolve_death_save(%Character{} = c, {:revive, _d20, _f, _s}) do
    %{c | hp: 1, death_saves: fresh_saves()}
  end

  defp resolve_death_save(
         %Character{death_saves: %{fails: f, successes: s}} = c,
         {_tag, _d20, fd, sd}
       ) do
    %{c | death_saves: %{fails: f + fd, successes: s + sd}}
  end
end
