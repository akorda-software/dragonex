defmodule Dragonex.World do
  @moduledoc """
  The shared game world — the combat state machine + cast, mutated ONLY through
  the Session (single-writer rule). Tools propose changes via SharedState.

  Every mutator is a *change function*: `name(args) -> (world -> {:ok, world} |
  {:error, reason})`, so it composes directly with
  `ExAgent.Session.SharedState.propose_change/2` and is trivially testable on its
  own (`World.apply_damage("goblin", 3).(world)`).

  Invariants enforced by the transitions (not by the LLM):

    * damage floors at 0,
    * damage hits `temp_hp` first, remainder to `hp` (D36); `temp_hp` never negative,
    * you can't damage/heal a missing character,
    * `begin_combat` requires the exploration phase and known combatants,
    * the death-save tracker resolves dead (3 fails) / stable (3 successes) /
      revive (nat 20) and looks at `hp`, not `temp_hp`.

  Characters are stored as full `Dragonex.Character` structs, so the engine can
  read any stat (AC, abilities, weapons ...) straight from the world.
  """

  alias Dragonex.Character

  # Facts are surfaced to every agent every turn, so an unbounded list grows the
  # prompt payload forever. Cap to the most recent facts (dropping the oldest).
  @max_facts 30

  defstruct scene: "an unremarkable crossroads",
            phase: :exploration,
            round: 1,
            characters: %{},
            initiative_order: [],
            log: [],
            spell_slots: %{},
            # Durable narrative facts the DM has established (a PNJ arrived, a
            # door was discovered, a contract was given). They survive truncation
            # in the shared history and are surfaced in the world_brief every
            # turn, so every agent reads the same "what has concretely happened
            # in the world" — the antidote to the DM introducing a hook and then
            # abandoning it, or re-introducing an event that already occurred.
            facts: [],
            # Combatants who already spent their main turn this round (D25).
            # Updated by the Game on give_turn_to handoffs — never by TurnMaster
            # tools (single-writer). cut_in/react mini-turns do NOT mark here.
            # Cleared when the round advances.
            acted_this_round: MapSet.new(),
            current_combatant: nil

  @type phase :: :exploration | :combat

  @type t :: %__MODULE__{
          scene: String.t(),
          phase: phase(),
          round: pos_integer(),
          characters: %{String.t() => Character.t()},
          initiative_order: [String.t()],
          log: [{String.t(), String.t()}],
          spell_slots: %{String.t() => %{pos_integer() => non_neg_integer()}},
          facts: [String.t()],
          acted_this_round: MapSet.t(String.t()),
          current_combatant: String.t() | nil
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
    |> Enum.filter(&((&1.hp || 0) > 0))
    |> Enum.map(& &1.side)
    |> Enum.uniq()
    |> length() <= 1
  end

  def combat_over?(_), do: false

  @doc "The set of living enemy (side `\"enemy\"`) character names."
  @spec living_enemies(t()) :: MapSet.t(String.t())
  def living_enemies(%__MODULE__{characters: chars}) do
    chars
    |> Enum.filter(fn {_, c} -> c.side == "enemy" and (c.hp || 0) > 0 end)
    |> Enum.map(fn {name, _} -> name end)
    |> MapSet.new()
  end

  @doc "True if any conscious (hp > 0) PC is present."
  @spec has_living_pcs?(t()) :: boolean()
  def has_living_pcs?(%__MODULE__{characters: chars}) do
    Enum.any?(chars, fn {_, c} -> c.side == "pc" and (c.hp || 0) > 0 end)
  end

  @doc "True if any conscious (hp > 0) enemy is present."
  @spec has_living_enemies?(t()) :: boolean()
  def has_living_enemies?(%__MODULE__{characters: chars}) do
    Enum.any?(chars, fn {_, c} -> c.side == "enemy" and (c.hp || 0) > 0 end)
  end

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

  @doc """
  Who controls `name`/`c`: the PC's own name if it's a player character, or
  `\"dm\"` otherwise (monsters/NPCs fold onto the DM). The view-layer inverse of
  `controlled_by?/3` — used to mark whose turn it is in the initiative tracker.
  Accepts either a name (looked up) or a `Character` struct directly.
  """
  @spec controller_of(t(), String.t() | Character.t() | nil) :: String.t()
  def controller_of(%__MODULE__{} = w, name) when is_binary(name),
    do: controller_of(w, character(w, name))

  def controller_of(_w, %Character{side: "pc"} = c), do: c.name
  def controller_of(_w, _enemy_or_nil), do: "dm"

  @doc """
  Combatants who still occupy an initiative slot this round (D34): living
  enemies and PCs (including downed PCs, who take death saves). Dead creatures
  and downed enemies are skipped.
  """
  @spec combat_cycle(t()) :: [String.t()]
  def combat_cycle(%__MODULE__{phase: :combat, initiative_order: order} = w)
      when is_list(order) do
    Enum.filter(order, &in_combat_cycle?(w, &1))
  end

  def combat_cycle(_), do: []

  @doc "Whose combat slot is live: `current_combatant` in combat, else controller."
  @spec acting?(t(), String.t(), String.t() | nil) :: boolean()
  def acting?(%__MODULE__{phase: :combat, current_combatant: slot}, name, _current)
      when is_binary(slot) and slot != "",
      do: name == slot

  def acting?(%__MODULE__{} = w, name, current), do: controller_of(w, name) == current

  @doc "Next unacted combatant in the cycle, or `to` when it names a character."
  @spec resolve_combatant(t(), String.t() | nil) :: String.t() | nil
  def resolve_combatant(%__MODULE__{phase: :combat} = w, to) do
    cond do
      is_binary(to) and to != "dm" and Map.has_key?(w.characters, to) ->
        to

      true ->
        acted = w.acted_this_round || MapSet.new()

        Enum.find(combat_cycle(w), fn name ->
          not MapSet.member?(acted, name) and controller_of(w, name) == "dm"
        end)
    end
  end

  def resolve_combatant(_, _), do: nil

  # ---------------------------------------------------------- change functions

  @spec set_scene(String.t()) :: (t() -> {:ok, t()})
  def set_scene(text) do
    fn w -> {:ok, %{w | scene: text, log: log(w, "dm", "scene: #{text}")}} end
  end

  @spec narrate(String.t(), String.t()) :: (t() -> {:ok, t()})
  def narrate(actor, text) do
    fn w -> {:ok, %{w | log: log(w, actor, text)}} end
  end

  @doc """
  Append a durable narrative fact to the world. Facts are short, concrete
  statements of what has been established in-fiction ("Un mensajero del Concejo
  entregó un pergamino con una misión", "Thane descubrió una puerta oculta tras
  las dianas"). They are surfaced in every agent's world_brief so the partida's
  concrete state survives history truncation and every agent reads the same
  ground truth — keeping the DM from re-introducing or abandoning hooks it
  already fired. Idempotent: an identical existing fact is not re-added.
  """
  @spec add_fact(String.t()) :: (t() -> {:ok, t()})
  def add_fact(fact) when is_binary(fact) do
    fn w ->
      trimmed = String.trim(fact)

      if trimmed == "" or trimmed in w.facts do
        {:ok, w}
      else
        facts = (w.facts ++ [trimmed]) |> Enum.take(-@max_facts)
        {:ok, %{w | facts: facts}}
      end
    end
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
          temp = c.temp_hp || 0
          absorbed = min(temp, amount)
          rest = amount - absorbed
          new_temp = temp - absorbed
          new_hp = max(0, (c.hp || 0) - rest)
          {:ok, put_char(w, target, %{c | hp: new_hp, temp_hp: new_temp})}
      end
    end
  end

  @doc """
  Grant temporary hit points (5e, D36). Does not stack: the character keeps
  `max(current temp_hp, amount)`. Amount must be positive; `heal/2` never
  writes this field.
  """
  @spec apply_temp_hp(String.t(), integer()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def apply_temp_hp(_name, amount) when is_integer(amount) and amount <= 0 do
    fn _w -> {:error, "temp_hp amount must be positive (got #{amount})"} end
  end

  def apply_temp_hp(name, amount) when is_integer(amount) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          current = c.temp_hp || 0
          {:ok, put_char(w, name, %{c | temp_hp: max(current, amount)})}
      end
    end
  end

  @doc """
  Set `who`'s concentration to a spell key (5e, D37). Replaces any previous
  concentration. Does not inspect the catalogue — the caller decides.
  """
  @spec set_concentration(String.t(), String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def set_concentration(name, spell_name) when is_binary(spell_name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | concentrating: spell_name})}
      end
    end
  end

  @doc "Drop concentration (5e, D37). Idempotent if already nil."
  @spec clear_concentration(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def clear_concentration(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | concentrating: nil})}
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
          hp = hp || 0
          max_hp = max_hp || 0
          new_hp = min(max_hp, hp + amount)
          c = %{c | hp: new_hp}
          c = if new_hp > 0, do: %{c | death_saves: fresh_saves()}, else: c
          {:ok, put_char(w, target, c)}
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
               acted_this_round: MapSet.new(),
               current_combatant: nil,
               log: log(w, "dm", "combat begins: #{Enum.join(initiative_order, " → ")}")
           }}
      end
    end
  end

  @spec end_combat() :: (t() -> {:ok, t()})
  def end_combat do
    fn w ->
      {:ok,
       %{
         w
         | phase: :exploration,
           acted_this_round: MapSet.new(),
           current_combatant: nil,
           log: log(w, "dm", "combat ends")
       }}
    end
  end

  @doc """
  Mark a participant as having spent their main turn this combat round (D25).
  No-op outside combat. Mini-turns (`cut_in`/`react`) must NOT call this.
  """
  @spec mark_acted(String.t()) :: (t() -> {:ok, t()})
  def mark_acted(name) when is_binary(name) do
    fn w ->
      if w.phase == :combat do
        {:ok, %{w | acted_this_round: MapSet.put(w.acted_this_round || MapSet.new(), name)}}
      else
        {:ok, w}
      end
    end
  end

  @doc "Clear `acted_this_round` (called when the round counter advances)."
  @spec clear_acted_this_round() :: (t() -> {:ok, t()})
  def clear_acted_this_round do
    fn w -> {:ok, %{w | acted_this_round: MapSet.new()}} end
  end

  @doc """
  True when every conscious combat participant has spent a main turn this round.
  Used by the Game to advance `world.round` under TurnMaster (D25) instead of
  the old "last of the WorldDriven cycle" heuristic.
  """
  @spec round_complete?(t(), [String.t()]) :: boolean()
  def round_complete?(%__MODULE__{phase: :combat, acted_this_round: acted}, cycle)
      when is_list(cycle) and cycle != [] do
    acted = acted || MapSet.new()
    Enum.all?(cycle, &MapSet.member?(acted, &1))
  end

  def round_complete?(_, _), do: false

  @doc """
  Add an existing character to the initiative order mid-combat (for
  reinforcements/summons). No-op outside combat — a character added in
  exploration will be included the next time initiative is rolled.
  """
  @spec join_initiative(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def join_initiative(name) do
    fn w ->
      cond do
        w.phase != :combat ->
          {:ok, w}

        not Map.has_key?(w.characters, name) ->
          {:error, "no such character: #{name}"}

        name in w.initiative_order ->
          {:ok, w}

        true ->
          {:ok,
           %{
             w
             | initiative_order: w.initiative_order ++ [name],
               log: log(w, "dm", "#{name} joins the fight")
           }}
      end
    end
  end

  @doc "Bump the round counter and clear `acted_this_round` (D25)."
  @spec next_round() :: (t() -> {:ok, t()})
  def next_round do
    fn w ->
      {:ok, %{w | round: w.round + 1, acted_this_round: MapSet.new(), current_combatant: nil}}
    end
  end

  @doc "Record whose initiative slot the current beat is (D34). Nil outside combat."
  @spec set_current_combatant(String.t() | nil) :: (t() -> {:ok, t()} | {:error, String.t()})
  def set_current_combatant(name) when is_binary(name) or is_nil(name) do
    fn w ->
      cond do
        w.phase != :combat ->
          {:ok, %{w | current_combatant: nil}}

        is_nil(name) or name == "" ->
          {:ok, %{w | current_combatant: nil}}

        Map.has_key?(w.characters, name) ->
          {:ok, %{w | current_combatant: name}}

        true ->
          {:error, "no such character: #{name}"}
      end
    end
  end

  @doc """
  Apply a `Dragonex.Rules.Combat.death_save/1` result to a character's tracker.
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

  # ------------------------------------------------------------- spell slots

  @doc "Initialize spell slots for every caster in the world (from class + level)."
  @spec init_spell_slots(t()) :: t()
  def init_spell_slots(%__MODULE__{characters: chars} = w) do
    slots =
      chars
      |> Enum.filter(fn {_, c} -> Dragonex.SpellSlots.caster?(c.class) end)
      |> Enum.map(fn {name, c} -> {name, Dragonex.SpellSlots.for_class(c.class, c.level)} end)
      |> Map.new()

    %{w | spell_slots: slots}
  end

  @doc "Does `name` have at least one level-`level` slot remaining?"
  @spec has_slot?(t(), String.t(), pos_integer()) :: boolean()
  def has_slot?(%__MODULE__{spell_slots: slots}, name, level) do
    cond do
      # No slot tracking → backward compat (spells always work)
      slots == %{} ->
        true

      # Character not tracked → no enforcement
      not is_map_key(slots, name) ->
        true

      # Tracked: check the count
      true ->
        slots
        |> Map.get(name, %{})
        |> Map.get(level, 0)
        |> Kernel.>(0)
    end
  end

  @doc "Consume one level-`level` slot from `name`. No-op if level 0 (cantrip) or untracked."
  @spec consume_slot(String.t(), pos_integer()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def consume_slot(_name, 0), do: fn w -> {:ok, w} end

  def consume_slot(name, level) do
    fn w ->
      cond do
        # Untracked character → no-op (backward compat)
        w.spell_slots == %{} or not is_map_key(w.spell_slots, name) ->
          {:ok, w}

        true ->
          case get_in(w.spell_slots, [name, level]) do
            n when is_integer(n) and n > 0 ->
              {:ok, put_in(w.spell_slots[name][level], n - 1)}

            _ ->
              {:error, "#{name} has no level-#{level} spell slots remaining"}
          end
      end
    end
  end

  @doc "Restore all spell slots for `name` to their maximum (called by long_rest)."
  @spec restore_slots(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def restore_slots(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{class: class, level: level} ->
          max_slots = Dragonex.SpellSlots.for_class(class, level)
          {:ok, %{w | spell_slots: Map.put(w.spell_slots, name, max_slots)}}
      end
    end
  end

  @doc """
  Sube el nivel de un personaje: nivel +1, PG (dado medio + CON), y refresca los
  huecos de conjuro. Si se pasan `choices` (`spells_added`, `asi`, `custom`),
  también aplica hechizos nuevos, mejora de característica (a niveles ASI) y las
  features de clase del nuevo nivel. La lógica vive en
   `Dragonex.Heroes.LevelUp.apply/2`; aquí solo la aplicamos al `Character` del
   mundo y refrescamos los spell slots.
  """
  @spec level_up(String.t(), map()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def level_up(name, choices \\ %{}) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{level: 20} ->
          {:error, "#{name} is already at max level (20)"}

        %Character{} = c ->
          case Dragonex.Heroes.LevelUp.apply(c, choices) do
            {:ok, leveled} ->
              w2 = put_char(w, name, leveled)
              slots = Dragonex.SpellSlots.for_class(leveled.class, leveled.level)

              if slots != %{},
                do: {:ok, %{w2 | spell_slots: Map.put(w2.spell_slots, name, slots)}},
                else: {:ok, w2}

            {:error, _} = err ->
              err
          end
      end
    end
  end

  @doc "The hit-die size for a 5e class (from the class catalog; default d8)."
  @spec hit_die_size(String.t()) :: pos_integer()
  def hit_die_size(class) when is_binary(class) do
    case Dragonex.Heroes.Classes.get(class) do
      {:ok, %{hit_die: n}} when is_integer(n) and n > 0 -> n
      _ -> 8
    end
  end

  def hit_die_size(_), do: 8

  # ----------------------------------------------------------------- helpers

  @doc "Check if a character has a condition."
  @spec has_condition?(t(), String.t(), String.t()) :: boolean()
  def has_condition?(%__MODULE__{} = w, name, condition) do
    case character(w, name) do
      %Character{} = c -> condition in Character.condition_names(c)
      _ -> false
    end
  end

  @breaks_concentration ~w(unconscious incapacitated stunned paralyzed petrified)

  @doc "Apply a condition to a character (idempotent — duplicates are skipped)."
  @spec apply_condition(String.t(), String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def apply_condition(target, condition) do
    fn w ->
      case character(w, target) do
        nil ->
          {:error, "no such character: #{target}"}

        %Character{conditions: conds} = c ->
          updated =
            if has_condition?(w, target, condition) do
              c
            else
              %{c | conditions: conds ++ [%{condition: condition}]}
            end

          updated =
            if condition in @breaks_concentration,
              do: %{updated | concentrating: nil},
              else: updated

          {:ok, put_char(w, target, updated)}
      end
    end
  end

  @doc "Remove a condition from a character."
  @spec remove_condition(String.t(), String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def remove_condition(target, condition) do
    fn w ->
      case character(w, target) do
        nil ->
          {:error, "no such character: #{target}"}

        %Character{conditions: conds} = c ->
          filtered = Enum.reject(conds, &(Character.condition_name(&1) == condition))

          {:ok, put_char(w, target, %{c | conditions: filtered})}
      end
    end
  end

  # Newest-first. Capped so the persisted jsonb does not grow without bound;
  # the canonical timeline is `game_events`, not this field.
  @max_log 50

  defp in_combat_cycle?(w, name) do
    cond do
      dead?(w, name) -> false
      match?(%Character{side: "pc"}, character(w, name)) -> true
      match?(%Character{hp: hp} when hp > 0, character(w, name)) -> true
      true -> false
    end
  end

  defp log(%__MODULE__{log: l}, actor, entry), do: Enum.take([{actor, entry} | l], @max_log)

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
