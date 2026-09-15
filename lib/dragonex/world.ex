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
    * typed damage is scaled by immunity/resistance/vulnerability first (D38),
      then hits `temp_hp`, remainder to `hp` (D36); `temp_hp` never negative,
    * untyped damage (`apply_damage/2` or empty type) is flat — no resist math,
    * you can't damage/heal a missing character,
    * `begin_combat` requires the exploration phase and known combatants,
    * the death-save tracker resolves dead (3 fails) / stable (3 successes) /
      revive (nat 20) and looks at `hp`, not `temp_hp`,
    * Rage (D42) ends on 0 hp, unconscious, `end_combat`, or `end_rage`,
    * Reckless Attack (D44) ends on the barbarian's next turn start
      (`set_current_combatant/1`), `end_reckless`, 0 hp, unconscious, or
      `end_combat`,
    * Divine Smite (D46) pending `smite_slot` expires on `end_smite`,
      `set_current_combatant/1` (start of that combatant's turn), 0 hp,
      unconscious, or `end_combat`. The slot is consumed on the first
      melee hit, not when arming,
    * Second Wind (D45) is 1/rest for fighters; `short_rest`/`long_rest` clear
      `second_wind_used`,
    * Action Surge (D47) is 1/rest for fighters L2+; `short_rest`/`long_rest`
      clear `action_surge_used`,
    * Lay on Hands (D49) is a paladin pool (`5 * level`); `long_rest` refills
      it, `short_rest` does not,
     * Bardic Inspiration (D50): bard spends uses to set `inspired` on a
       target; `long_rest` refills bard uses and clears `inspired` on the
       rester; `short_rest` does not,
     * Arcane Recovery (D51) is 1/long rest for wizards; `long_rest` clears
       `arcane_recovery_used`, `short_rest` does not,
     * Divine Sense (D52) is a paladin scan (`1 + cha_mod` uses, floor 1);
       `long_rest` refills it, `short_rest` does not,
      * Channel Divinity: Turn Undead (D53) is 1/rest for clerics L2+;
        `short_rest`/`long_rest` clear `channel_divinity_used`,
      * Ki (D54) is a monk L2+ pool (`level` points); `Actions.flurry_of_blows`
        spends 1 per use; `short_rest`/`long_rest` refill it to `level`
        (no-op for other classes),
       * Font of Magic (D56) is a sorcerer L2+ pool (`level` points);
         `Actions.create_spell_slot` spends points into slots and
         `Actions.convert_to_sorcery_points` drains a slot back into points
         (capped at `level`); only `long_rest` refills it (no-op for other
         classes),
        * Wild Shape (D63) is a druid L2+ transform (2 uses/rest): the beast's
          str/dex/con/hp/max_hp/ac/weapons replace the druid's while the
          originals live in `wild_shape`; damage that drops the beast to 0
          auto-reverts with only the excess carried over; `cast_spell` is
          blocked while transformed; both rests refill the uses; level-up
          never touches uses or form,
         * Metamagic (D65) is a sorcerer L3+ armed option
           (`%{option, target}`, ONE at a time): arming spends sorcery
           points (`Actions.arm_metamagic/4`); `Actions.spell/5` applies
           and consumes it when the spell qualifies; rests never touch it,
          * Relentless Endurance (D67) is a half-orc passive in
            `apply_damage/3`: damage-layering order is Uncanny Dodge halves
            the incoming amount (D64) → the D38 resistance layer in
            `Character.incoming_damage/3` (incl. D76 Dwarven Resilience: a
            dwarf halves poison — stacks multiplicatively with D64) →
            temp_hp (D36) → hp → Wild Shape auto-revert (D63) → Relentless
            Endurance (hp 0 → 1, once per long rest;
            `relentless_endurance_used`); `long_rest` recharges
            it, `short_rest` does not,
         * Rage uses (D72): a barbarian gets `Progression.rage_count/1`
           rages per long rest; `start_rage/1` spends one on entry
           (`rage_uses_used`) and refuses when the pool is empty;
           `end_rage/1` does NOT refund the use; only `long_rest` resets
           the counter,
         * Relentless Rage (D72) is a barbarian L11+ passive in
           `apply_damage/3`, right BEFORE Relentless Endurance (D67): a
           raging barbarian whose hp lands at 0 saves CON vs
           `10 + 5 * relentless_rage_successes` (Aura of Protection D61
           applies — RAW covers all saves) to stay at 1 hp; each success
           bumps the next DC and only `long_rest` resets the counter,
         * `grant_xp` adds to `Character.xp` and never levels up (D43).

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

  @spec apply_damage(String.t(), integer()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  @spec apply_damage(String.t(), integer(), String.t() | nil) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  @spec apply_damage(
          String.t(),
          integer(),
          String.t() | nil,
          (pos_integer() -> pos_integer()) | nil
        ) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def apply_damage(target, amount, type \\ nil, roller \\ nil) do
    fn w ->
      case character(w, target) do
        nil ->
          {:error, "no such character: #{target}"}

        %Character{} = c ->
          # D64 Uncanny Dodge: an armed rogue halves ANY incoming damage
          # (floor) at the entry point — before the D38 resistance layer
          # below (which includes D76 dwarf poison resistance: a dwarf
          # halves poison there, so a dwarf rogue stacks half × half =
          # quarter, RAW), temp_hp (D36) and hp — and the flag is
          # consumed. amount <= 0 never consumes it. The D63 auto-revert
          # flow below runs after, with the already-mitigated damage.
          dodge? = c.uncanny_dodge == true and amount > 0
          amount = if dodge?, do: div(amount, 2), else: amount
          c = if dodge?, do: %{c | uncanny_dodge: false}, else: c

          incoming = Character.incoming_damage(c, amount, type)
          temp = c.temp_hp || 0
          absorbed = min(temp, incoming)
          rest = incoming - absorbed
          new_temp = temp - absorbed
          new_hp = max(0, (c.hp || 0) - rest)

          if new_hp <= 0 and c.wild_shape != nil do
            # D63 auto-revert: the beast drops and the druid returns to their
            # own form. Only the excess damage (beyond the beast's remaining
            # hp) carries over to the original hit points.
            excess = max(0, rest - (c.hp || 0))
            orig_hp = c.wild_shape[:orig_hp] || 0
            final_hp = max(0, orig_hp - excess)
            reverted = %{restore_wild_shape_form(c, final_hp) | temp_hp: new_temp}

            # Layer order at 0 hp (D67/D72): Relentless RAGE (class, save)
            # first, then Relentless ENDURANCE (racial, hp 0 → 1).
            {updated, rr_note} = maybe_relentless_rage(reverted, target, w, roller)
            {updated, re_note} = maybe_relentless(updated, target)
            updated = clear_drop_flags(updated, updated.hp)

            msg =
              "la bestia cae y #{target} vuelve a su forma (PG #{final_hp})" <>
                case join_notes([rr_note, re_note]) do
                  "" -> ""
                  notes -> "; " <> notes
                end

            # Note in the world change so the narration surfaces it.
            w = put_char(w, target, updated)

            {:ok, %{w | log: log(w, "dm", msg)}}
          else
            {updated, rr_note} =
              maybe_relentless_rage(%{c | hp: new_hp, temp_hp: new_temp}, target, w, roller)

            {updated, re_note} = maybe_relentless(updated, target)
            updated = clear_drop_flags(updated, updated.hp)

            case join_notes([rr_note, re_note]) do
              "" -> {:ok, put_char(w, target, updated)}
              notes -> {:ok, %{put_char(w, target, updated) | log: log(w, "dm", notes)}}
            end
          end
      end
    end
  end

  defp join_notes(notes), do: notes |> Enum.reject(&is_nil/1) |> Enum.join("; ")

  defp clear_drop_flags(%Character{} = c, 0),
    do: %{c | raging: false, reckless: false, smite_slot: nil}

  defp clear_drop_flags(%Character{} = c, _hp), do: c

  # D72 Relentless Rage: a barbarian L11+ whose hp lands at 0 WHILE raging
  # saves CON vs `10 + 5 * relentless_rage_successes` to stay at 1 hp
  # instead. Runs BEFORE the racial layer (D67) so a half-orc barbarian
  # stacks both; a rage-save success leaves Relentless Endurance
  # unconsumed (hp is 1, not 0). The save rides `Rules.Combat.saving_throw`
  # (CON proficiency from the sheet + Lucky D66) plus the Aura of
  # Protection bonus (D61 — RAW it covers ALL saves). There is no RollLog
  # at this depth (the change-fn only sees the world), so the world-log
  # note is the record of the roll (D72). Returns the character plus the
  # note when it fired (`nil` otherwise).
  defp maybe_relentless_rage(
         %Character{class: "barbarian", raging: true, hp: hp, level: level} = c,
         name,
         %__MODULE__{} = w,
         roller
       )
       when is_integer(level) and level >= 11 and hp <= 0 do
    successes = c.relentless_rage_successes || 0
    dc = 10 + 5 * successes
    roller = roller || (&Dragonex.Dice.roll/1)
    aura = aura_save_bonus(w, name)
    {d20, total, _success?} = Dragonex.Rules.Combat.saving_throw(c, :con, dc, roller)
    total = total + aura

    if total >= dc do
      {%{c | hp: 1, relentless_rage_successes: successes + 1},
       "la furia mantiene a #{name} en pie con 1 pg (Furia implacable: salvación CON d20 #{d20}: #{total} vs CD #{dc}#{aura_bit(aura)})"}
    else
      {c,
       "#{name} falla la salvación de Furia implacable (CON d20 #{d20}: #{total} vs CD #{dc}#{aura_bit(aura)})"}
    end
  end

  defp maybe_relentless_rage(%Character{} = c, _name, _w, _roller), do: {c, nil}

  defp aura_bit(aura) when aura != 0, do: " #{signed(aura)} aura"
  defp aura_bit(_), do: ""

  defp signed(n) when n >= 0, do: "+#{n}"
  defp signed(n), do: "#{n}"

  # D67 Relentless Endurance: a half-orc whose hp lands at 0 drops to 1
  # instead — ONCE per long rest (`relentless_endurance_used` is recharged by
  # Actions' long rest). Runs after the D63 auto-revert, so the carried-over
  # excess is what RE saves. Returns the character plus a world-log note when
  # it fired (`nil` otherwise).
  defp maybe_relentless(
         %Character{race: "half-orc", relentless_endurance_used: false, hp: hp} = c,
         name
       )
       when hp <= 0 do
    {%{c | hp: 1, relentless_endurance_used: true},
     "la furia semi-orca mantiene a #{name} en pie con 1 pg (Resistencia implacable)"}
  end

  defp maybe_relentless(%Character{} = c, _name), do: {c, nil}

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

  @doc """
  Set `who`'s raging flag (5e, D42). Entering rage (`true`) also drops
  concentration. Does not check class — `start_rage/1` does.
  """
  @spec set_raging(String.t(), boolean()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def set_raging(name, raging) when is_boolean(raging) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          updated = %{c | raging: raging}
          updated = if raging, do: %{updated | concentrating: nil}, else: updated
          {:ok, put_char(w, name, updated)}
      end
    end
  end

  @doc """
  Enter Rage (D42/D72). Only `class == "barbarian"` with uses left:
  spends one of the `Progression.rage_count/1` rages per long rest
  (`rage_uses_used`) on entry. Clears concentration. Already raging is an
  idempotent no-op that does NOT spend another use. `end_rage/1` never
  refunds the use (RAW: spent on entering).
  """
  @spec start_rage(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def start_rage(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{class: "barbarian"} = c ->
          max_rages = Dragonex.Heroes.Progression.rage_count(c.level || 1)

          cond do
            c.raging == true ->
              set_raging(name, true).(w)

            (c.rage_uses_used || 0) >= max_rages ->
              {:error, "#{name} no le quedan furias hoy (#{max_rages}/#{max_rages} usadas)"}

            true ->
              with {:ok, w} <- set_raging(name, true).(w) do
                set_rage_uses_used(name, (c.rage_uses_used || 0) + 1).(w)
              end
          end

        %Character{} ->
          {:error, "#{name} no es bárbaro y no puede entrar en furia"}
      end
    end
  end

  @doc "End Rage (D42). Idempotent if already false."
  @spec end_rage(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def end_rage(name), do: set_raging(name, false)

  @doc """
  Set `who`'s Reckless Attack flag (5e, D44). Does not check class —
  `start_reckless/1` does.
  """
  @spec set_reckless(String.t(), boolean()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def set_reckless(name, reckless) when is_boolean(reckless) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | reckless: reckless})}
      end
    end
  end

  @doc """
  Enter Reckless Attack (D44). Only `class == "barbarian"` of level 2+
  (RAW: the feature arrives at L2; the level gate mirrors
  `Actions.start_uncanny_dodge`).
  """
  @spec start_reckless(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def start_reckless(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{class: class} when class != "barbarian" ->
          {:error, "#{name} no es bárbaro y no puede atacar de forma temeraria"}

        %Character{level: level} when not is_integer(level) or level < 2 ->
          {:error, "#{name} no tiene Ataque temerario (nivel 2)"}

        %Character{} ->
          set_reckless(name, true).(w)
      end
    end
  end

  @doc "End Reckless Attack (D44). Idempotent if already false."
  @spec end_reckless(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def end_reckless(name), do: set_reckless(name, false)

  @doc """
  Set `who`'s Uncanny Dodge flag (5e, D64). `true` = armed: the next
  damage is halved and the flag consumed in `apply_damage/3`. Does not
  check class/level — `Actions.start_uncanny_dodge/2` does.
  """
  @spec set_uncanny_dodge(String.t(), boolean()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def set_uncanny_dodge(name, armed) when is_boolean(armed) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | uncanny_dodge: armed})}
      end
    end
  end

  @doc """
  Set `who`'s Relentless Endurance spent flag (5e, D67). `apply_damage/3`
  sets it when the feature saves a half-orc at 1 hp; `Actions`' long rest
  recharges it (`false`). Short rest does not.
  """
  @spec set_relentless_endurance(String.t(), boolean()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def set_relentless_endurance(name, used) when is_boolean(used) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | relentless_endurance_used: used})}
      end
    end
  end

  @doc """
  Set `who`'s spent rage uses (D72). `World.start_rage/1` spends one on
  entry; `Actions`' long rest resets them to 0. Short rest does not.
  """
  @spec set_rage_uses_used(String.t(), non_neg_integer()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def set_rage_uses_used(name, used) when is_integer(used) and used >= 0 do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | rage_uses_used: used})}
      end
    end
  end

  @doc """
  Set `who`'s Relentless Rage success count (D72). `apply_damage/4` bumps
  it on each successful save (next DC harder); `Actions`' long rest
  resets it to 0.
  """
  @spec set_relentless_rage_successes(String.t(), non_neg_integer()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def set_relentless_rage_successes(name, successes)
      when is_integer(successes) and successes >= 0 do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | relentless_rage_successes: successes})}
      end
    end
  end

  @doc """
  Set `who`'s Indomitable spent flag (5e, D68). The save-reroll sites in
  `Actions` (spell save, turn undead, concentration) set it when a fighter
  L9+ rerolls a failed save; `Actions`' long rest recharges it (`false`).
  Short rest does not.
  """
  @spec set_indomitable(String.t(), boolean()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def set_indomitable(name, used) when is_boolean(used) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | indomitable_used: used})}
      end
    end
  end

  @doc """
  Set `who`'s Breath Weapon used flag (5e, D70). The breath site in
  `Actions` sets it when a dragonborn exhales (hit or save — the use is
  spent on resolution); BOTH rests recharge it (`false`), like ki D54.
  """
  @spec set_breath_weapon_used(String.t(), boolean()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def set_breath_weapon_used(name, used) when is_boolean(used) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | breath_weapon_used: used})}
      end
    end
  end

  @doc """
  Set `who`'s armed Metamagic option (5e, D65). `nil` clears (consumed);
  armed = `%{option: String.t(), target: String.t() | nil}` with atom keys.
  Does not check class/level/points — `Actions.arm_metamagic/4` does.
  """
  @spec set_metamagic(String.t(), map() | nil) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def set_metamagic(name, metamagic) when is_nil(metamagic) or is_map(metamagic) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | metamagic: metamagic})}
      end
    end
  end

  @doc """
  Add `skill` to `who`'s Expertise list (5e, D73). Does not check
  class/level/training/cupo — `Actions.gain_expertise/3` does.
  Idempotent-ish: re-adding a skill is a no-op (the Actions layer
  rejects duplicates first).
  """
  @spec add_expertise(String.t(), String.t()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def add_expertise(name, skill) when is_binary(skill) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          list = c.expertise || []

          if skill in list do
            {:ok, w}
          else
            {:ok, put_char(w, name, %{c | expertise: list ++ [skill]})}
          end
      end
    end
  end

  @doc """
  Set `who`'s Second Wind used flag (5e, D45). Does not heal — `second_wind/2`
  does. Idempotent.
  """
  @spec set_second_wind_used(String.t(), boolean()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def set_second_wind_used(name, used) when is_boolean(used) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | second_wind_used: used})}
      end
    end
  end

  @doc """
  Set `who`'s Action Surge used flag (5e, D47). Does not attack —
  `Actions.action_surge` does. Idempotent.
  """
  @spec set_action_surge_used(String.t(), boolean()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def set_action_surge_used(name, used) when is_boolean(used) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | action_surge_used: used})}
      end
    end
  end

  @doc """
  Set `who`'s Channel Divinity used flag (5e, D53). Does not turn undead —
  `Actions.turn_undead` does. Idempotent. `short_rest`/`long_rest` clear it.
  """
  @spec set_channel_divinity_used(String.t(), boolean()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def set_channel_divinity_used(name, used) when is_boolean(used) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | channel_divinity_used: used})}
      end
    end
  end

  @doc """
  Set `who`'s remaining Lay on Hands pool (5e, D49). Does not heal —
  `lay_on_hands/3` does. Idempotent.
  """
  @spec set_lay_on_hands_pool(String.t(), non_neg_integer()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def set_lay_on_hands_pool(name, pool) when is_integer(pool) and pool >= 0 do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | lay_on_hands_pool: pool})}
      end
    end
  end

  @doc """
  Long rest refill (D49). Paladin pool → `5 * level`. No-op for other classes.
  """
  @spec restore_lay_on_hands(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def restore_lay_on_hands(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{class: "paladin", level: level} = c ->
          max_pool = 5 * max(level || 1, 1)
          {:ok, put_char(w, name, %{c | lay_on_hands_pool: max_pool})}

        %Character{} ->
          {:ok, w}
      end
    end
  end

  @doc """
  Set `who`'s remaining Divine Sense uses (5e, D52). Does not scan —
  `spend_divine_sense/1` does. Idempotent.
  """
  @spec set_divine_sense_uses(String.t(), non_neg_integer()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def set_divine_sense_uses(name, uses) when is_integer(uses) and uses >= 0 do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | divine_sense_uses: uses})}
      end
    end
  end

  @doc """
  Long rest refill (D52). Paladin uses → `max(1, 1 + cha_mod)`. No-op for
  other classes.
  """
  @spec restore_divine_sense(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def restore_divine_sense(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{class: "paladin"} = c ->
          uses = max(1, 1 + Character.modifier(c, :cha))
          {:ok, put_char(w, name, %{c | divine_sense_uses: uses})}

        %Character{} ->
          {:ok, w}
      end
    end
  end

  @doc """
  Spend one Divine Sense use (5e, D52). Paladin only. Errors (no spend):
  missing who, not a paladin, 0 uses.
  """
  @spec spend_divine_sense(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def spend_divine_sense(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{class: class} when class != "paladin" ->
          {:error, "#{name} no es paladín y no puede usar Sentido divino"}

        %Character{divine_sense_uses: uses} = c ->
          uses = uses || 0

          if uses < 1 do
            {:error, "#{name} no tiene usos de Sentido divino"}
          else
            {:ok, put_char(w, name, %{c | divine_sense_uses: uses - 1})}
          end
      end
    end
  end

  @doc """
  Spend `amount` ki points (5e, D54). Monk only. Errors (no spend):
  missing who, not a monk, fewer than `amount` ki left.
  """
  @spec spend_ki(String.t(), pos_integer()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def spend_ki(name, amount) when is_integer(amount) and amount >= 1 do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{class: class} when class != "monk" ->
          {:error, "#{name} no es monje y no puede gastar ki"}

        %Character{ki: ki} = c ->
          ki = ki || 0

          if ki < amount do
            {:error, "#{name} no tiene suficiente ki (le quedan #{ki})"}
          else
            {:ok, put_char(w, name, %{c | ki: ki - amount})}
          end
      end
    end
  end

  @doc """
  Rest refill (D54). Monk ki → `level` (L2+; a L1 monk → 0). No-op for
  other classes. Both `short_rest` and `long_rest` call this.
  """
  @spec restore_ki(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def restore_ki(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{class: "monk"} = c ->
          max_ki = Dragonex.Heroes.Progression.ki_points("monk", c.level)
          {:ok, put_char(w, name, %{c | ki: max_ki})}

        %Character{} ->
          {:ok, w}
      end
    end
  end

  @doc """
  Spend `amount` sorcery points (5e, D56 Font of Magic). Sorcerer only.
  Errors (no spend): missing who, not a sorcerer, fewer than `amount`
  points left.
  """
  @spec spend_sorcery_points(String.t(), pos_integer()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def spend_sorcery_points(name, amount) when is_integer(amount) and amount >= 1 do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{class: class} when class != "sorcerer" ->
          {:error, "#{name} no es hechicero y no puede gastar puntos de hechicería"}

        %Character{sorcery_points: points} = c ->
          points = points || 0

          if points < amount do
            {:error, "#{name} no tiene suficientes puntos de hechicería (le quedan #{points})"}
          else
            {:ok, put_char(w, name, %{c | sorcery_points: points - amount})}
          end
      end
    end
  end

  @doc """
  Gain `amount` sorcery points (D56), capped at the class/level maximum
  (`Progression.sorcery_points/2`; the excess is silently discarded).
  No-op gain of 0; errors on missing who or not a sorcerer.
  """
  @spec gain_sorcery_points(String.t(), non_neg_integer()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def gain_sorcery_points(name, amount) when is_integer(amount) and amount >= 0 do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{class: class} when class != "sorcerer" ->
          {:error, "#{name} no es hechicero y no puede ganar puntos de hechicería"}

        %Character{sorcery_points: points, class: class, level: level} = c ->
          max = Dragonex.Heroes.Progression.sorcery_points(class, level)
          {:ok, put_char(w, name, %{c | sorcery_points: min((points || 0) + amount, max)})}
      end
    end
  end

  @doc """
  Long-rest refill (D56). Sorcerer points → `level` (L2+; a L1 sorcerer → 0).
  No-op for other classes. Only `long_rest` calls this (RAW: sorcery points
  return on a long rest, unlike ki D54 which returns on both).
  """
  @spec restore_sorcery_points(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def restore_sorcery_points(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{class: "sorcerer"} = c ->
          max = Dragonex.Heroes.Progression.sorcery_points("sorcerer", c.level)
          {:ok, put_char(w, name, %{c | sorcery_points: max})}

        %Character{} ->
          {:ok, w}
      end
    end
  end

  # ------------------------------------------------------- Wild Shape (D63)

  @doc """
  Transform `name` into `beast_key` (5e, D63). `beast` is the prebuilt
  `Character` from `Monsters`; class/level/CR/uses validation lives in
  `Actions.wild_shape/3` — here we only re-check who exists and isn't
  already transformed. On success it ALWAYS spends one use and:

    * saves the original form (str/dex/con/hp/max_hp/ac/weapons) in
      `Character.wild_shape`,
    * applies the beast's str/dex/con/hp/max_hp/ac/weapons,
    * keeps int/wis/cha, name, side, class, level, proficiencies,
      skill_proficiencies, conditions and concentration (RAW: transforming
      does not break concentration).

  The inventory (`Character.inventory`) is NEVER touched — beast weapons are
  synthetic and the originals come back on revert.
  """
  @spec transform_wild_shape(String.t(), String.t(), Character.t()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def transform_wild_shape(name, beast_key, %Character{} = beast) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{wild_shape: nil} = c ->
          saved = %{
            beast: beast_key,
            orig_str: c.str,
            orig_dex: c.dex,
            orig_con: c.con,
            orig_hp: c.hp,
            orig_max_hp: c.max_hp,
            orig_ac: c.ac,
            orig_weapons: c.weapons
          }

          updated =
            %{c | wild_shape: saved, wild_shape_uses: max(0, (c.wild_shape_uses || 0) - 1)}
            |> apply_beast_form(beast)

          {:ok, put_char(w, name, updated)}

        %Character{} ->
          {:error, "#{name} ya está en forma de bestia"}
      end
    end
  end

  @doc """
  End Wild Shape (D63): restore the saved form — str/dex/con/max_hp/ac/
  weapons — with `hp` set to the exact `orig_hp` saved at transformation.
  Errors if `name` is missing or not transformed. (The auto-revert excess
  path lives in `apply_damage/3`, which computes the carry-over hp.)
  """
  @spec revert_wild_shape(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def revert_wild_shape(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{wild_shape: nil} ->
          {:error, "#{name} no está en forma de bestia"}

        %Character{wild_shape: %{} = ws} = c ->
          {:ok, put_char(w, name, restore_wild_shape_form(c, ws[:orig_hp] || 0))}
      end
    end
  end

  defp apply_beast_form(%Character{} = c, %Character{} = beast) do
    %{
      c
      | str: beast.str,
        dex: beast.dex,
        con: beast.con,
        hp: beast.hp,
        max_hp: beast.max_hp,
        ac: beast.ac,
        weapons: beast.weapons
    }
  end

  defp restore_wild_shape_form(%Character{wild_shape: %{} = ws} = c, hp) do
    %{
      c
      | str: ws[:orig_str],
        dex: ws[:orig_dex],
        con: ws[:orig_con],
        hp: hp,
        max_hp: ws[:orig_max_hp],
        ac: ws[:orig_ac],
        weapons: ws[:orig_weapons] || [],
        wild_shape: nil
    }
  end

  @doc """
  Rest refill (D63). Druid Wild Shape uses → 2 (L2+; a L1 druid stays at 0).
  No-op for other classes. Both `short_rest` and `long_rest` call this.
  Does NOT revert the form (RAW: you can rest while transformed).
  """
  @spec restore_wild_shape_uses(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def restore_wild_shape_uses(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{class: "druid", level: level} = c
        when is_integer(level) and level >= 2 ->
          {:ok, put_char(w, name, %{c | wild_shape_uses: 2})}

        %Character{} ->
          {:ok, w}
      end
    end
  end

  @doc """
  Set `who`'s Bardic Inspiration pending die (5e, D50). Any class may be
  inspired. Idempotent.
  """
  @spec set_inspired(String.t(), boolean()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def set_inspired(name, inspired) when is_boolean(inspired) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | inspired: inspired})}
      end
    end
  end

  @doc """
  Set remaining Bardic Inspiration uses (5e, D50). Does not grant the die —
  `spend_bardic/2` does. Idempotent.
  """
  @spec set_bardic_inspiration_uses(String.t(), non_neg_integer()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def set_bardic_inspiration_uses(name, uses) when is_integer(uses) and uses >= 0 do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | bardic_inspiration_uses: uses})}
      end
    end
  end

  @doc """
  Set `who`'s Arcane Recovery used flag (5e, D51). Does not restore slots —
  `apply_arcane_recovery/2` does. Idempotent. `long_rest` clears it.
  """
  @spec set_arcane_recovery_used(String.t(), boolean()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def set_arcane_recovery_used(name, used) when is_boolean(used) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | arcane_recovery_used: used})}
      end
    end
  end

  @doc """
  Greedy Arcane Recovery plan (D51). Budget `div(level + 1, 2)`. Restores
  expended slots (`current < max` from `SpellSlots.for_class`), highest
  level first, never above 5th. Restoring a slot of level N costs N.
  Untracked casters are treated as full (nothing expended).
  """
  @spec arcane_recovery_plan(t(), String.t()) ::
          {:ok, %{pos_integer() => non_neg_integer()}, %{pos_integer() => pos_integer()}}
          | {:error, String.t()}
  def arcane_recovery_plan(%__MODULE__{} = w, name) do
    case character(w, name) do
      nil ->
        {:error, "no such character: #{name}"}

      %Character{class: class, level: level} ->
        level = level || 1
        max_slots = Dragonex.SpellSlots.for_class(class, level)
        current = Map.get(w.spell_slots, name, max_slots)
        budget = div(level + 1, 2)
        {new_slots, restored} = greedy_arcane_restore(current, max_slots, budget)

        if restored == %{} do
          {:error, "#{name} no tiene huecos gastados que Recuperación arcana pueda restaurar"}
        else
          {:ok, new_slots, restored}
        end
    end
  end

  @doc """
  Apply an Arcane Recovery plan (D51): write restored slots and mark used.
  """
  @spec apply_arcane_recovery(String.t(), %{pos_integer() => non_neg_integer()}) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def apply_arcane_recovery(name, new_slots) when is_map(new_slots) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          w = %{w | spell_slots: Map.put(w.spell_slots, name, new_slots)}
          {:ok, put_char(w, name, %{c | arcane_recovery_used: true})}
      end
    end
  end

  defp greedy_arcane_restore(current, max_slots, budget) do
    Enum.reduce(5..1//-1, {current, %{}, budget}, fn level, {slots, restored, remaining} ->
      max_n = Map.get(max_slots, level, 0)
      cur_n = Map.get(slots, level, 0)
      expended = max(0, max_n - cur_n)
      n = min(expended, div(remaining, level))

      if n > 0 do
        {
          Map.put(slots, level, cur_n + n),
          Map.put(restored, level, n),
          remaining - n * level
        }
      else
        {slots, restored, remaining}
      end
    end)
    |> then(fn {slots, restored, _} -> {slots, restored} end)
  end

  @doc """
  Long rest refill (D50). Bard uses → `max(1, cha_mod)`. No-op for other classes.
  """
  @spec restore_bardic_inspiration(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def restore_bardic_inspiration(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{class: "bard"} = c ->
          uses = max(1, Character.modifier(c, :cha))
          {:ok, put_char(w, name, %{c | bardic_inspiration_uses: uses})}

        %Character{} ->
          {:ok, w}
      end
    end
  end

  @doc """
  Spend one Bardic Inspiration use (5e, D50). Bard only. Marks `target`
  inspired. Errors (no spend): missing who/target, not a bard, 0 uses,
  target already inspired.
  """
  @spec spend_bardic(String.t(), String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def spend_bardic(who, target) do
    fn w ->
      case character(w, who) do
        nil ->
          {:error, "no such character: #{who}"}

        %Character{class: class} when class != "bard" ->
          {:error, "#{who} no es bardo y no puede usar Inspiración bárdica"}

        %Character{bardic_inspiration_uses: uses} = bard ->
          uses = uses || 0

          case character(w, target) do
            nil ->
              {:error, "no such character: #{target}"}

            %Character{inspired: true} ->
              {:error, "#{target} ya está inspirado"}

            %Character{} when uses < 1 ->
              {:error, "#{who} no tiene usos de Inspiración bárdica"}

            %Character{} = tgt ->
              remaining = uses - 1

              if who == target do
                {:ok,
                 put_char(w, who, %{bard | bardic_inspiration_uses: remaining, inspired: true})}
              else
                w = put_char(w, who, %{bard | bardic_inspiration_uses: remaining})
                {:ok, put_char(w, target, %{tgt | inspired: true})}
              end
          end
      end
    end
  end

  @doc """
  Lay on Hands (5e, D49). Paladin only. Spends already-computed `applied`
  from the pool and heals `target` (capped at max_hp, same path as `heal/2`).
  Does not touch temp_hp. `who` and `target` may differ.
  """
  @spec lay_on_hands(String.t(), String.t(), non_neg_integer()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def lay_on_hands(who, target, applied) when is_integer(applied) and applied >= 0 do
    fn w ->
      case character(w, who) do
        nil ->
          {:error, "no such character: #{who}"}

        %Character{class: class} when class != "paladin" ->
          {:error, "#{who} no es paladín y no puede usar Manos impositoras"}

        %Character{lay_on_hands_pool: pool} ->
          pool = pool || 0

          case character(w, target) do
            nil ->
              {:error, "no such character: #{target}"}

            %Character{} ->
              with {:ok, w2} <- heal(target, applied).(w) do
                c = character(w2, who)
                {:ok, put_char(w2, who, %{c | lay_on_hands_pool: max(0, pool - applied)})}
              end
          end
      end
    end
  end

  @doc """
  Second Wind (5e, D45). Fighter only. Applies already-rolled heal `amount`
  (capped at max_hp, same path as `heal/2`) and marks `second_wind_used`.
  Does not touch temp_hp. Errors if already used or not a fighter.
  """
  @spec second_wind(String.t(), non_neg_integer()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def second_wind(name, amount) when is_integer(amount) and amount >= 0 do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{class: class} when class != "fighter" ->
          {:error, "#{name} no es guerrero y no puede usar Segundo aliento"}

        %Character{second_wind_used: true} ->
          {:error, "#{name} ya ha usado Segundo aliento (se recarga con un descanso)"}

        %Character{} ->
          with {:ok, w2} <- heal(name, amount).(w) do
            set_second_wind_used(name, true).(w2)
          end
      end
    end
  end

  @doc """
  Set `who`'s pending Divine Smite slot (5e, D46). `nil` clears. Does not
  check class or slots — `start_smite/2` does. Does not consume the slot.
  """
  @spec set_smite_slot(String.t(), pos_integer() | nil) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def set_smite_slot(name, slot) when is_nil(slot) or (is_integer(slot) and slot in 1..5) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          {:ok, put_char(w, name, %{c | smite_slot: slot})}
      end
    end
  end

  @doc """
  Arm Divine Smite (D46). Paladin only. Leaves `smite_slot` pending; does
  **not** consume the spell slot. Errors if not a paladin, `slot_level`
  outside 1..5, or `has_slot?/3` is false.
  """
  @spec start_smite(String.t(), integer()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def start_smite(_name, slot_level) when not is_integer(slot_level) or slot_level not in 1..5 do
    fn _w -> {:error, "el nivel de casilla del Castigo divino debe estar entre 1 y 5"} end
  end

  def start_smite(name, slot_level) when is_integer(slot_level) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{class: class} when class != "paladin" ->
          {:error, "#{name} no es paladín y no puede usar Castigo divino"}

        %Character{class: class, level: level} ->
          table = Dragonex.SpellSlots.for_class(class, level || 1)

          cond do
            Map.get(table, slot_level, 0) < 1 ->
              {:error, "a #{name} no le quedan casillas de hechizo de nivel #{slot_level}"}

            not has_slot?(w, name, slot_level) ->
              {:error, "a #{name} no le quedan casillas de hechizo de nivel #{slot_level}"}

            true ->
              set_smite_slot(name, slot_level).(w)
          end
      end
    end
  end

  @doc "Clear pending Divine Smite (D46). Idempotent. Does not consume a slot."
  @spec end_smite(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def end_smite(name), do: set_smite_slot(name, nil)

  @doc """
  Grant XP (5e, D43). Adds `amount` to `Character.xp`. Does not level up
  and does not touch hp or spell slots. Amount must be positive.
  """
  @spec grant_xp(String.t(), integer()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def grant_xp(_name, amount) when is_integer(amount) and amount <= 0 do
    fn _w -> {:error, "xp amount must be positive (got #{amount})"} end
  end

  def grant_xp(name, amount) when is_integer(amount) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} = c ->
          current = c.xp || 0
          {:ok, put_char(w, name, %{c | xp: current + amount})}
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
      characters =
        Map.new(w.characters, fn
          {name, %Character{} = c} ->
            {name, %{c | raging: false, reckless: false, smite_slot: nil}}

          other ->
            other
        end)

      {:ok,
       %{
         w
         | phase: :exploration,
           characters: characters,
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

  @doc """
  Record whose initiative slot the current beat is (D34). Nil outside combat.
  Starting a combatant's turn ends their Reckless Attack (D44) and any
  pending Divine Smite (D46).
  """
  @spec set_current_combatant(String.t() | nil) :: (t() -> {:ok, t()} | {:error, String.t()})
  def set_current_combatant(name) when is_binary(name) or is_nil(name) do
    fn w ->
      cond do
        w.phase != :combat ->
          {:ok, %{w | current_combatant: nil}}

        is_nil(name) or name == "" ->
          {:ok, %{w | current_combatant: nil}}

        Map.has_key?(w.characters, name) ->
          characters =
            Map.update!(w.characters, name, fn
              %Character{} = c -> %{c | reckless: false, smite_slot: nil}
              other -> other
            end)

          {:ok, %{w | current_combatant: name, characters: characters}}

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

  @doc """
  Does `name` have at least one slot remaining for a spell of `level`?

  Warlocks (D40) check the pact-slot level, not `spell.level` raw.
  Untracked worlds / casters not in the map → true (backward compat).
  """
  @spec has_slot?(t(), String.t(), pos_integer()) :: boolean()
  def has_slot?(%__MODULE__{spell_slots: slots} = w, name, level) do
    cond do
      # No slot tracking → backward compat (spells always work)
      slots == %{} ->
        true

      # Character not tracked → no enforcement
      not is_map_key(slots, name) ->
        true

      # Tracked: check the count (pact casters remap to pact slot level)
      true ->
        slot_level = slot_level_for(w, name, level)

        slots
        |> Map.get(name, %{})
        |> Map.get(slot_level, 0)
        |> Kernel.>(0)
    end
  end

  @doc """
  Consume one slot from `name` for a spell of `level`.

  Warlocks (D40) spend a pact slot. No-op if level 0 (cantrip) or untracked.
  """
  @spec consume_slot(String.t(), pos_integer()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def consume_slot(_name, 0), do: fn w -> {:ok, w} end

  def consume_slot(name, level) do
    fn w ->
      cond do
        # Untracked character → no-op (backward compat)
        w.spell_slots == %{} or not is_map_key(w.spell_slots, name) ->
          {:ok, w}

        true ->
          slot_level = slot_level_for(w, name, level)

          case get_in(w.spell_slots, [name, slot_level]) do
            n when is_integer(n) and n > 0 ->
              {:ok, put_in(w.spell_slots[name][slot_level], n - 1)}

            _ ->
              {:error, "#{name} has no level-#{slot_level} spell slots remaining"}
          end
      end
    end
  end

  defp slot_level_for(w, name, spell_level) do
    case character(w, name) do
      %Character{class: class, level: char_level} ->
        Dragonex.SpellSlots.slot_level_for(class, char_level, spell_level)

      _ ->
        spell_level
    end
  end

  @doc """
  Gain one spell slot of `level` (Font of Magic, D56). Raw slot level — no
  warlock pact remap (sorcerers are the only callers) — and it may exceed
  the daily maximum (RAW). Errors: missing who, invalid level.
  """
  @spec gain_slot(String.t(), pos_integer()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def gain_slot(name, level) when is_integer(level) and level >= 1 do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, "no such character: #{name}"}

        %Character{} ->
          slots = Map.get(w.spell_slots, name, %{})
          current = Map.get(slots, level, 0)

          {:ok,
           %{w | spell_slots: Map.put(w.spell_slots, name, Map.put(slots, level, current + 1))}}
      end
    end
  end

  @doc "Restore all spell slots for `name` to their maximum (long rest; warlock short rest)."
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

  @doc """
  Conscious paladins (hp > 0) of `side` with `level >= min_level` (D61/D62).

  Shared query behind both paladin auras: Aura of Protection (L6+) and Aura
  of Courage (L10+). No grid, no range — every same-side character is "within"
  the aura (D61/D62 simplification).
  """
  @spec paladins_conscious(t(), String.t() | nil, non_neg_integer()) :: [Character.t()]
  def paladins_conscious(%__MODULE__{} = w, side, min_level) do
    w.characters
    |> Map.values()
    |> Enum.filter(fn c ->
      c.class == "paladin" and c.side == side and (c.hp || 0) > 0 and
        is_integer(c.level) and c.level >= min_level
    end)
  end

  @doc """
  Aura of Protection bonus (D61) on `name`'s saves.

  Every conscious paladin (L6+) on the saver's side shares their CHA
  modifier with ALL saves of that side (the paladin themself included).
  Multiple paladins stack (RAW); a CHA below 10 gives a negative bonus
  with no floor. 0 when the side has none. Lives in `World` (not just
  `Actions`) because the D72 Relentless Rage save inside `apply_damage/4`
  is CON but the aura covers it too (RAW: all saves).
  """
  @spec aura_save_bonus(t(), String.t()) :: integer()
  def aura_save_bonus(%__MODULE__{} = w, name) do
    case character(w, name) do
      %Character{side: side} ->
        w
        |> paladins_conscious(side, 6)
        |> Enum.map(&Character.modifier(&1, :cha))
        |> Enum.sum()

      _ ->
        0
    end
  end

  @doc """
  Aura of Courage (D62): `name` can't be frightened while sharing a side with
  a conscious paladin L10+ (the paladin themself included).
  """
  @spec courage_immune?(t(), String.t()) :: boolean()
  def courage_immune?(%__MODULE__{} = w, name) do
    case character(w, name) do
      %Character{side: side} -> paladins_conscious(w, side, 10) != []
      _ -> false
    end
  end

  @doc """
  Apply a condition to a character (idempotent — duplicates are skipped).

  Aura of Courage (D62): a "frightened" condition never lands on a same-side
  ally of a conscious paladin L10+ — the change resolves `{:ok, world}`
  WITHOUT mutating (immunity is not an error); the caller reports it.
  """
  @spec apply_condition(String.t(), String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def apply_condition(target, condition) do
    fn w ->
      case character(w, target) do
        nil ->
          {:error, "no such character: #{target}"}

        %Character{conditions: conds} = c ->
          if condition == "frightened" and courage_immune?(w, target) do
            {:ok, w}
          else
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

            updated =
              if condition == "unconscious",
                do: %{updated | raging: false, reckless: false, smite_slot: nil},
                else: updated

            {:ok, put_char(w, target, updated)}
          end
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
