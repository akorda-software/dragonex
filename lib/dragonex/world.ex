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
    * damage taken while already at 0 hp registers death-save failures
      (RAW: 1 per hit, 2 on a crit; `apply_damage/5` opts) — the hit that
      merely DROPS you to 0 registers none,
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
          preserves the active beast and spent uses while progressing the
          saved original form (D129),
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

  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.{Character, Terms}

  # Facts are surfaced to every agent every turn, so an unbounded list grows the
  # prompt payload forever. Cap to the most recent facts (dropping the oldest).
  @max_facts 30

  defstruct scene: "an unremarkable crossroads",
            scene_refresh_pending: false,
            # Successful tools in an unfinished actor beat, durable on restart.
            actor_checkpoint: nil,
            wait_resolution: nil,
            phase: :exploration,
            round: 1,
            characters: %{},
            # Stored sheets remain durable when a non-PC leaves this scene.
            # Active queries exclude these names; values are scrubbed reasons.
            absent_characters: %{},
            # Exploration only: companions answer their own bounded request.
            # Cleared by a scene change or combat; encoded by Codec.
            conversation: nil,
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
            current_combatant: nil,
            # Reserved before evaluating automatic turn-start effects; cleared
            # only with their durable World/dice commit (including named DM slots).
            pending_turn: nil,
            turn_state: %{},
            turn_kind: "main",
            turn_owner: nil,
            rest_state: %{},
            elapsed_seconds: 0,
            effect_expiries: %{}

  @type phase :: :exploration | :combat

  @type t :: %__MODULE__{
          scene: String.t(),
          scene_refresh_pending: boolean(),
          phase: phase(),
          round: pos_integer(),
          characters: %{String.t() => Character.t()},
          absent_characters: %{String.t() => String.t()},
          conversation: map() | nil,
          initiative_order: [String.t()],
          log: [{String.t(), String.t()}],
          spell_slots: %{String.t() => %{pos_integer() => non_neg_integer()}},
          facts: [String.t()],
          acted_this_round: MapSet.t(String.t()),
          current_combatant: String.t() | nil,
          pending_turn: map() | nil,
          turn_state: map(),
          turn_kind: String.t(),
          turn_owner: String.t() | nil,
          rest_state: map(),
          elapsed_seconds: non_neg_integer(),
          effect_expiries: map()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct(__MODULE__, opts)

  # ---------------------------------------------------------------- queries

  @doc "Look up a character by name."
  @spec character(t(), String.t()) :: Character.t() | nil
  def character(%__MODULE__{} = w, name), do: Map.get(w.characters, name)

  @doc "Whether the stored character is present in the current scene."
  def present?(%__MODULE__{} = w, name),
    do:
      Map.has_key?(w.characters, name) and
        not Map.has_key?(Map.get(w, :absent_characters, %{}), name)

  @doc "Look up an active scene character without losing their stored sheet."
  def present_character(%__MODULE__{} = w, name),
    do: if(present?(w, name), do: character(w, name))

  @doc "Characters available to scene actions, senses, effects and initiative."
  def present_characters(%__MODULE__{} = w),
    do: Map.drop(w.characters, Map.keys(Map.get(w, :absent_characters, %{})))

  @doc "Validate that an actor can take an action, bonus action or reaction."
  @spec validate_actor(t(), String.t()) :: :ok | {:error, String.t()}
  def validate_actor(w, name) do
    case present_character(w, name) do
      nil ->
        if character(w, name),
          do:
            {:error,
             dgettext("engine", "%{name} está fuera de escena y no puede actuar", name: name)},
          else: {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

      %Character{death_saves: %{fails: fails}} when fails >= 3 ->
        {:error, dgettext("engine", "%{name} está muerto y no puede actuar", name: name)}

      %Character{hp: hp} when hp <= 0 ->
        {:error, dgettext("engine", "%{name} está caído (0 pg) y no puede actuar", name: name)}

      %Character{} = c ->
        if Enum.any?(
             Character.condition_names(c),
             &(&1 in ~w(incapacitated stunned paralyzed petrified unconscious))
           ),
           do:
             {:error,
              dgettext("engine", "%{name} está incapacitado y no puede actuar", name: name)},
           else: :ok
    end
  end

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
  def combat_over?(%__MODULE__{phase: :combat} = w) do
    present_characters(w)
    |> Map.values()
    |> Enum.filter(&((&1.hp || 0) > 0))
    |> Enum.map(& &1.side)
    |> Enum.uniq()
    |> length() <= 1
  end

  def combat_over?(_), do: false

  @doc "The set of living enemy (side `\"enemy\"`) character names."
  @spec living_enemies(t()) :: MapSet.t(String.t())
  def living_enemies(%__MODULE__{} = w) do
    present_characters(w)
    |> Enum.filter(fn {_, c} -> c.side == "enemy" and (c.hp || 0) > 0 end)
    |> Enum.map(fn {name, _} -> name end)
    |> MapSet.new()
  end

  @doc "True if any conscious (hp > 0) PC is present."
  @spec has_living_pcs?(t()) :: boolean()
  def has_living_pcs?(%__MODULE__{} = w) do
    Enum.any?(present_characters(w), fn {_, c} -> c.side == "pc" and (c.hp || 0) > 0 end)
  end

  @doc "True if any conscious (hp > 0) enemy is present."
  @spec has_living_enemies?(t()) :: boolean()
  def has_living_enemies?(%__MODULE__{} = w) do
    Enum.any?(present_characters(w), fn {_, c} -> c.side == "enemy" and (c.hp || 0) > 0 end)
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

    case present_character(w, name) do
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
        if present?(w, to), do: to

      true ->
        acted = w.acted_this_round || MapSet.new()

        Enum.find(combat_cycle(w), fn name ->
          not MapSet.member?(acted, name) and controller_of(w, name) == "dm"
        end)
    end
  end

  def resolve_combatant(_, _), do: nil

  # ---------------------------------------------------------- change functions

  @doc """
  DM-confirmed descriptive inventory addition; exploration and present PCs
  only. An object the PC already holds is not granted again unless
  `additional` says these are new, separate units (D240).
  """
  def grant_item(who, item, quantity, additional \\ false) do
    change = inventory_change(who, item, quantity, :grant)

    fn world ->
      held =
        case present_character(world, who) do
          %{side: "pc", inventory: items} -> Dragonex.Rules.Inventory.held(items, item)
          _ -> nil
        end

      if is_struct(held) and additional != true and world.phase == :exploration,
        do:
          {:error,
           dgettext(
             "engine",
             "%{who} ya tiene %{item} ×%{held} en su inventario: no lo concedas otra vez. " <>
               "Si no cambia nada, usa confirm_inventory_unchanged; si de verdad recibe " <>
               "unidades nuevas y distintas (más flechas, monedas), repite grant_item con additional: true.",
             who: who,
             item: held.name,
             held: held.qty
           )},
        else: change.(world)
    end
  end

  @doc "Remove an owned quantity of descriptive gear without negative stock."
  def remove_item(who, item, quantity), do: inventory_change(who, item, quantity, :remove)

  defp inventory_change(who, item, quantity, operation) do
    fn world ->
      character = present_character(world, who)

      cond do
        world.phase != :exploration ->
          {:error, dgettext("engine", "El inventario narrativo solo se confirma en exploración.")}

        is_nil(character) or character.side != "pc" ->
          {:error, dgettext("engine", "El destinatario debe ser un personaje jugador presente.")}

        true ->
          with {:ok, inventory} <-
                 Dragonex.Rules.Inventory.change(
                   character.inventory || [],
                   item,
                   quantity,
                   operation
                 ) do
            {:ok,
             %{
               world
               | scene_refresh_pending: true,
                 characters: Map.put(world.characters, who, %{character | inventory: inventory})
             }}
          end
      end
    end
  end

  @spec set_scene(String.t()) :: (t() -> {:ok, t()})
  def set_scene(text) do
    fn w ->
      conversation = if text == w.scene, do: Map.get(w, :conversation)
      w = w |> Map.put(:conversation, conversation) |> Map.put(:scene_refresh_pending, false)
      {:ok, %{w | scene: text, log: log(w, "dm", "scene: #{text}")}}
    end
  end

  @doc "Record the established surroundings without cancelling the current reply/return queue."
  @spec refresh_scene(String.t()) :: (t() -> {:ok, t()})
  def refresh_scene(text) do
    fn w ->
      w = Map.put(w, :scene_refresh_pending, false)
      {:ok, %{w | scene: text, log: log(w, "dm", "scene: #{text}")}}
    end
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
        {:ok, %{Map.put(w, :scene_refresh_pending, true) | facts: facts}}
      end
    end
  end

  @doc "Record what an NPC claims, preserving attribution without confirming the content."
  @spec record_npc_statement(term(), term()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def record_npc_statement(speaker, statement) do
    fn world ->
      with {:ok, fact} <- Dragonex.NPCStatement.fact(world, speaker, statement),
           {:ok, recorded} <- add_fact(fact).(world) do
        # Testimony updates shared memory, not the physical surroundings.
        # Keep a prior review pending without creating or clearing one here.
        {:ok, %{recorded | scene_refresh_pending: world.scene_refresh_pending}}
      end
    end
  end

  @spec add_character(Character.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def add_character(%Character{} = c) do
    fn w ->
      if Map.has_key?(w.characters, c.name) do
        suffix =
          if present?(w, c.name),
            do: "",
            else: dgettext("engine", "; usa return_to_scene para conservar su ficha")

        {:error, dgettext("engine", "el personaje ya existe: %{name}", name: c.name) <> suffix}
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

  @doc "Record a non-PC's scene departure, preserving their sheet and resources."
  def leave_scene(name, reason) do
    fn w ->
      cleaned =
        if is_binary(reason),
          do: reason |> Dragonex.Text.scrub() |> String.trim() |> String.slice(0, 500),
          else: ""

      cond do
        not is_binary(name) or is_nil(character(w, name)) ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: inspect(name))}

        match?(%Character{side: "pc"}, character(w, name)) ->
          {:error, dgettext("engine", "los PCs conservan su presencia en el grupo")}

        not present?(w, name) ->
          {:error, dgettext("engine", "%{name} ya está fuera de escena", name: name)}

        cleaned == "" ->
          {:error, dgettext("engine", "indica un motivo de salida de la escena")}

        true ->
          {:ok, w} = clear_concentration(name).(w)
          budget = Map.get(w.turn_state, name, %{})
          owner? = w.phase == :combat and w.turn_owner == name and budget["round"] == w.round
          w = if owner?, do: Dragonex.TurnBudget.finish(w, name), else: w

          acted =
            if owner?,
              do: MapSet.put(w.acted_this_round || MapSet.new(), name),
              else: w.acted_this_round

          absent = Map.put(Map.get(w, :absent_characters, %{}), name, cleaned)

          {:ok,
           w
           |> Map.put(:absent_characters, absent)
           |> Map.put(:initiative_order, Enum.reject(w.initiative_order, &(&1 == name)))
           |> Map.put(:acted_this_round, acted)
           |> Map.put(
             :log,
             log(
               w,
               "dm",
               dgettext("engine", "%{name} sale de escena: %{cleaned}",
                 name: name,
                 cleaned: cleaned
               )
             )
           )}
      end
    end
  end

  @doc "Bring back the stored non-PC; combat reinforcements join at the end."
  def return_to_scene(name) do
    fn w ->
      cond do
        not is_binary(name) or is_nil(character(w, name)) ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: inspect(name))}

        present?(w, name) ->
          {:error, dgettext("engine", "%{name} ya está presente en la escena", name: name)}

        true ->
          w =
            Map.put(w, :absent_characters, Map.delete(Map.get(w, :absent_characters, %{}), name))

          w = %{
            w
            | log: log(w, "dm", dgettext("engine", "%{name} vuelve a la escena", name: name))
          }

          join_initiative(name).(w)
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
  @spec apply_damage(
          String.t(),
          integer(),
          String.t() | nil,
          (pos_integer() -> pos_integer()) | nil,
          keyword()
        ) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def apply_damage(target, amount, type \\ nil, roller \\ nil, opts \\ []) do
    fn w ->
      with {:ok, next} <- do_apply_damage(target, amount, type, roller, opts).(w) do
        next =
          if Dragonex.Damage.incoming(character(w, target), amount, type, opts) > 0,
            do: Dragonex.TurnBudget.mark(next, target, "damaged"),
            else: next

        {:ok, Dragonex.Damage.concentrate(character(w, target), next, amount, type, roller, opts)}
      end
    end
  end

  # Entradas inválidas (auditoría 7): un daño negativo atravesaba la
  # aritmética de temp_hp y AUMENTABA los pg temporales del objetivo
  # (absorbed = min(temp, negativo) → new_temp = temp + |daño|); uno no
  # entero contaminaba hp con floats. Se rechaza antes de tocar nada.
  defp do_apply_damage(_target, amount, _type, _roller, _opts)
       when not is_integer(amount) or amount < 0 do
    fn _w ->
      {:error,
       dgettext("engine", "el daño debe ser un entero no negativo (recibió %{amount})",
         amount: inspect(amount)
       )}
    end
  end

  defp do_apply_damage(target, amount, type, roller, opts) do
    fn w ->
      case present_character(w, target) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: target)}

        %Character{} = c ->
          # D64 Uncanny Dodge: an armed rogue halves ANY incoming damage
          # (floor) at the entry point — before the D38 resistance layer
          # below (which includes D76 dwarf poison resistance: a dwarf
          # halves poison there, so a dwarf rogue stacks half × half =
          # quarter, RAW), temp_hp (D36) and hp — and the flag is
          # consumed. amount <= 0 never consumes it. The D63 auto-revert
          # flow below runs after, with the already-mitigated damage.
          incoming = Dragonex.Damage.incoming(c, amount, type, opts)
          dodge? = c.uncanny_dodge == true and amount > 0
          c = if dodge?, do: %{c | uncanny_dodge: false}, else: c

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
            {updated, rr_note, re_note} =
              survive_drop(reverted, orig_hp > 0 and excess > 0, target, w, roller, opts)

            updated = clear_drop_flags(updated, updated.hp)
            # D96: recibir daño despierta al dormido (solo el sueño; el
            # daño se aplica con normalidad).
            updated = wake_on_damage(updated, incoming)
            updated = break_charm(updated, incoming, opts)

            msg =
              dgettext("engine", "la bestia cae y %{target} vuelve a su forma (PG %{final_hp})",
                target: target,
                final_hp: final_hp
              ) <>
                case join_notes([rr_note, re_note]) do
                  "" -> ""
                  notes -> "; " <> notes
                end

            # Note in the world change so the narration surfaces it.
            w = put_char(w, target, updated) |> forget_charm_timer(target, updated)

            {:ok, %{w | log: log(w, "dm", msg)}}
          else
            downed? = (c.hp || 0) <= 0

            {updated, rr_note, re_note} =
              survive_drop(
                %{c | hp: new_hp, temp_hp: new_temp},
                not downed? and rest > 0,
                target,
                w,
                roller,
                opts
              )

            updated = clear_drop_flags(updated, updated.hp)
            # D96: recibir daño despierta al dormido (solo el sueño; el
            # daño se aplica con normalidad — incluido el absorbido por
            # pg temporales).
            updated = wake_on_damage(updated, incoming)
            updated = break_charm(updated, incoming, opts)

            # RAW: damage taken WHILE already at 0 hp registers death-save
            # failures (the hit that DROPS you to 0 does not — the layer
            # order keeps Relentless Rage/Endurance ahead: they leave the
            # character at 1 hp and no fail is registered).
            {updated, df_note} =
              maybe_death_save_fail(updated, target, downed? and rest > 0, opts)

            w = put_char(w, target, updated) |> forget_charm_timer(target, updated)

            case join_notes([rr_note, re_note, df_note]) do
              "" -> {:ok, w}
              notes -> {:ok, %{w | log: log(w, "dm", notes)}}
            end
          end
      end
    end
  end

  defp join_notes(notes), do: notes |> Enum.reject(&is_nil/1) |> Enum.join("; ")

  defp clear_drop_flags(%Character{} = c, 0),
    do: %{c | raging: false, reckless: false, smite_slot: nil, concentrating: nil}

  defp clear_drop_flags(%Character{} = c, _hp), do: c

  # These traits replace a transition from positive HP to zero; they are not
  # healing and cannot fire merely because a character is already at zero.
  defp survive_drop(c, true, target, w, roller, opts) do
    {c, rr_note} = maybe_relentless_rage(c, target, w, roller, opts)
    {c, re_note} = maybe_relentless(c, target)
    {c, rr_note, re_note}
  end

  defp survive_drop(c, false, _target, _w, _roller, _opts), do: {c, nil, nil}

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
         roller,
         opts
       )
       when is_integer(level) and level >= 11 and hp <= 0 do
    successes = c.relentless_rage_successes || 0
    dc = 10 + 5 * successes
    roller = roller || (&Dragonex.Dice.roll/1)
    aura = Keyword.get(opts, :aura, aura_save_bonus(w, name))
    {d20, total, _success?} = Dragonex.Rules.Combat.saving_throw(c, :con, dc, roller)
    total = total + aura

    if total >= dc do
      {%{c | hp: 1, relentless_rage_successes: successes + 1},
       dgettext(
         "engine",
         "la furia mantiene a %{name} en pie con 1 pg (Furia implacable: salvación CON d20 %{d20}: %{total} vs CD %{dc}%{aura})",
         name: name,
         d20: d20,
         total: total,
         dc: dc,
         aura: aura_bit(aura)
       )}
    else
      {c,
       dgettext(
         "engine",
         "%{name} falla la salvación de Furia implacable (CON d20 %{d20}: %{total} vs CD %{dc}%{aura})",
         name: name,
         d20: d20,
         total: total,
         dc: dc,
         aura: aura_bit(aura)
       )}
    end
  end

  defp maybe_relentless_rage(%Character{} = c, _name, _w, _roller, _opts), do: {c, nil}

  defp aura_bit(aura) when aura != 0,
    do: dgettext("engine", " %{bonus} aura", bonus: signed(aura))

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
     dgettext(
       "engine",
       "la furia semi-orca mantiene a %{name} en pie con 1 pg (Resistencia implacable)",
       name: name
     )}
  end

  defp maybe_relentless(%Character{} = c, _name), do: {c, nil}

  # RAW death saves: damage taken WHILE already at 0 hp registers failures
  # in the death-save tracker — one per hit, TWO when the hit was a critical
  # (`opts[:crit]`). Runs as the LAST layer of `apply_damage` (after D72/D67:
  # a Relentless save leaves the character at 1 hp and nothing registers).
  # The 3rd failure just accumulates — death is `dead?/2` (fails >= 3), the
  # existing vía. `opts[:death_fail] == false` skips registration (the smite
  # pipe uses it: the weapon damage of the SAME hit already registered).
  # Massive-damage insta-death is deliberately OUT of scope.
  defp maybe_death_save_fail(%Character{} = c, _name, false, _opts), do: {c, nil}

  defp maybe_death_save_fail(%Character{hp: hp, death_saves: saves} = c, name, true, opts)
       when hp <= 0 do
    if (saves.fails || 0) >= 3 or Keyword.get(opts, :death_fail, true) == false do
      {c, nil}
    else
      crit? = Keyword.get(opts, :crit, false)
      delta = if crit?, do: 2, else: 1
      # Three successes encode stability (rather than a separate persisted
      # flag). Damage ends it; old pre-stabilization failures cannot carry over,
      # including in worlds saved before stabilization cleared them.
      saves = if saves.successes >= 3, do: fresh_saves(), else: saves

      {%{c | death_saves: %{saves | fails: saves.fails + delta}},
       if(crit?,
         do:
           dgettext(
             "engine",
             "%{name} recibe daño estando caído: dos fallos de salvación de muerte",
             name: name
           ),
         else:
           dgettext(
             "engine",
             "%{name} recibe daño estando caído: un fallo de salvación de muerte",
             name: name
           )
       )}
    end
  end

  defp maybe_death_save_fail(%Character{} = c, _name, _downed_hit?, _opts), do: {c, nil}

  @doc """
  Grant temporary hit points (5e, D36). Does not stack: the character keeps
  `max(current temp_hp, amount)`. Amount must be positive; `heal/2` never
  writes this field.
  """
  @spec apply_temp_hp(String.t(), integer()) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def apply_temp_hp(_name, amount) when is_integer(amount) and amount <= 0 do
    fn _w ->
      {:error,
       dgettext("engine", "la cantidad de temp_hp debe ser positiva (recibido %{amount})",
         amount: amount
       )}
    end
  end

  # Entradas inválidas (auditoría 7): un amount no entero no casaba con
  # ninguna cláusula y crasheaba (FunctionClauseError) en vez de error útil.
  def apply_temp_hp(_name, amount) when not is_integer(amount) do
    fn _w ->
      {:error,
       dgettext("engine", "los pg temporales deben ser un entero positivo (recibió %{amount})",
         amount: inspect(amount)
       )}
    end
  end

  def apply_temp_hp(name, amount) when is_integer(amount) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

        %Character{} = c ->
          current = c.temp_hp || 0
          next = put_char(w, name, %{c | temp_hp: max(current, amount)})

          {:ok,
           if(amount > current, do: Dragonex.WorldClock.forget(next, name, "temp_hp"), else: next)}
      end
    end
  end

  @doc "Grant temporary HP with a duration; a smaller grant never replaces the existing source."
  def apply_temp_hp_for(name, amount, seconds) do
    fn w ->
      if is_integer(seconds) and seconds > 0 do
        with {:ok, next} <- apply_temp_hp(name, amount).(w) do
          if amount > (character(w, name).temp_hp || 0),
            do: {:ok, Dragonex.WorldClock.track(next, name, "temp_hp", seconds)},
            else: {:ok, next}
        end
      else
        {:error, dgettext("engine", "duración inválida")}
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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

        %Character{} ->
          w = clear_sourced_effects(w, name)
          c = character(w, name)
          next = put_char(w, name, %{c | concentrating: spell_name})
          {:ok, Dragonex.WorldClock.concentration(next, name, spell_name)}
      end
    end
  end

  @doc """
  Remove only effects linked to this caster's concentration. D99: the
  spirit_guardians aura rides the same routes — its `spirit_guardians:<n>`
  entries are stripped here too (World-level, without touching the frozen
  `Rules.Effects` dispatch).
  """
  def clear_sourced_effects(w, source) do
    %{
      w
      | characters:
          Map.new(w.characters, fn {name, c} ->
            c =
              c
              |> Dragonex.Rules.Effects.without_source(source)
              |> strip_guardians_from(source)

            {name, c}
          end)
    }
  end

  defp strip_guardians_from(%Character{conditions: conds} = c, source) do
    %{c | conditions: Enum.reject(conds || [], &guardians_from?(&1, source))}
  end

  defp strip_guardians_from(other, _source), do: other

  defp guardians_from?(
         %{"condition" => "spirit_guardians", "source" => "spirit_guardians:" <> n},
         source
       ),
       do: n == source

  defp guardians_from?(_, _), do: false

  @doc """
  D99 Spiritual Weapon: grants (or RENEWS — re-casting replaces, never
  stacks) the caster's persistent posture as a structured condition entry.
  No concentration: it only ages at the start of the caster's new turns
  (combat rounds clock).
  """
  def grant_spiritual_weapon(caster, dice, mod, rounds) when is_binary(dice) do
    fn w ->
      case character(w, caster) do
        %Character{conditions: conds} = c ->
          kept = Enum.reject(conds || [], &spirit_weapon_entry?/1)

          entry = %{
            "condition" => "spiritual_weapon",
            "dice" => dice,
            "mod" => mod,
            "rounds_left" => rounds
          }

          {:ok, put_char(w, caster, %{c | conditions: kept ++ [entry]})}

        _ ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: caster)}
      end
    end
  end

  defp spirit_weapon_entry?(%{"condition" => "spiritual_weapon"}), do: true
  defp spirit_weapon_entry?(_), do: false

  def validate_bless_targets(w, targets, level) do
    cond do
      not is_list(targets) or targets == [] or Enum.any?(targets, &(not is_binary(&1))) ->
        {:error,
         dgettext("engine", "%{spell} requiere una lista de objetivos",
           spell: Terms.spell("bless")
         )}

      not is_integer(level) or level not in 1..9 ->
        {:error, dgettext("engine", "nivel de %{spell} inválido", spell: Terms.spell("bless"))}

      length(targets) > 2 + level ->
        {:error,
         dgettext("engine", "%{spell} permite hasta %{max} objetivos a nivel %{level}",
           spell: Terms.spell("bless"),
           max: 2 + level,
           level: level
         )}

      length(Enum.uniq(targets)) != length(targets) ->
        {:error,
         dgettext("engine", "los objetivos de %{spell} no pueden repetirse",
           spell: Terms.spell("bless")
         )}

      Enum.any?(targets, fn name ->
        case present_character(w, name) do
          nil -> true
          c -> c.death_saves.fails >= 3
        end
      end) ->
        {:error,
         dgettext("engine", "%{spell} requiere objetivos existentes y no muertos",
           spell: Terms.spell("bless")
         )}

      true ->
        :ok
    end
  end

  @doc "Apply Bless atomically to its targets, replacing the caster's previous concentration."
  def bless(caster, targets, level) do
    fn w ->
      with :ok <- validate_actor(w, caster),
           :ok <- validate_bless_targets(w, targets, level) do
        grant_concentration_effect(w, caster, targets, "bless", "blessed")
      end
    end
  end

  def validate_shield_of_faith_targets(w, targets) do
    cond do
      not is_list(targets) or length(targets) not in 1..2 or
          Enum.any?(targets, &(not is_binary(&1))) ->
        {:error,
         dgettext("engine", "%{spell} requiere uno o dos objetivos (con Twinned)",
           spell: Terms.spell("shield of faith")
         )}

      length(Enum.uniq(targets)) != length(targets) ->
        {:error,
         dgettext("engine", "los objetivos de %{spell} deben ser distintos",
           spell: Terms.spell("shield of faith")
         )}

      Enum.any?(targets, fn name ->
        case present_character(w, name) do
          nil -> true
          c -> c.death_saves.fails >= 3
        end
      end) ->
        {:error,
         dgettext("engine", "%{spell} requiere objetivos existentes y no muertos",
           spell: Terms.spell("shield of faith")
         )}

      true ->
        :ok
    end
  end

  @doc "Protect targets with Shield of Faith, under one concentration and deadline."
  def shield_of_faith(caster, targets) do
    fn w ->
      with :ok <- validate_actor(w, caster),
           :ok <- validate_shield_of_faith_targets(w, targets) do
        grant_concentration_effect(w, caster, targets, "shield of faith", "shield_of_faith")
      end
    end
  end

  @mage_armor_seconds 28_800
  @charm_seconds 3600

  def set_conditions(name, conds) when is_list(conds) do
    fn w ->
      case character(w, name) do
        %Character{} = c -> {:ok, put_char(w, name, %{c | conditions: conds})}
        _ -> {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}
      end
    end
  end

  def note(%__MODULE__{} = w, actor, text), do: %{w | log: log(w, actor, text)}

  @doc "Mage Armor (D98): renews the 8-hour mark. Does not concentrate."
  def grant_mage_armor(targets) when is_list(targets) do
    fn w ->
      {:ok,
       Enum.reduce(targets, w, fn name, acc ->
         c = character(acc, name)
         conds = Enum.reject(c.conditions || [], &mage_armor_entry?/1)
         c = %{c | conditions: conds ++ [%{"condition" => "mage_armor"}]}
         acc = put_char(acc, name, c)
         Dragonex.WorldClock.track(acc, name, "condition:mage_armor", @mage_armor_seconds)
       end)}
    end
  end

  @doc "Charm Person (D98): one sourced mark and a 1-hour timer. No concentration."
  def grant_charm(caster, caster_side, targets) when is_list(targets) do
    fn w ->
      entry = %{
        "condition" => "charmed",
        "source" => "charm_person:#{caster}",
        "caster_side" => caster_side
      }

      {:ok,
       Enum.reduce(targets, w, fn name, acc ->
         c = character(acc, name)
         conds = Enum.reject(c.conditions || [], &charm_from?(caster, &1))
         c = %{c | conditions: conds ++ [entry]}
         acc = put_char(acc, name, c)
         Dragonex.WorldClock.track(acc, name, "condition:charmed", @charm_seconds)
       end)}
    end
  end

  defp mage_armor_entry?(%{"condition" => "mage_armor"}), do: true
  defp mage_armor_entry?(%{condition: "mage_armor"}), do: true
  defp mage_armor_entry?(_), do: false

  defp charm_from?(caster, %{"source" => "charm_person:" <> name}), do: name == caster
  defp charm_from?(_, _), do: false

  @doc """
  Fix concentration, then attach sourced condition entries. Used by Hold Person
  and Faerie Fire (D97) so a later `set_concentration` cannot wipe them.
  """
  def impose_sourced_conditions(caster, spell, effects) when is_list(effects) do
    fn w ->
      with {:ok, w} <- set_concentration(caster, spell).(w) do
        {:ok,
         Enum.reduce(effects, w, fn {name, entry}, acc ->
           c = character(acc, name)
           put_char(acc, name, %{c | conditions: c.conditions ++ [entry]})
         end)}
      end
    end
  end

  defp grant_concentration_effect(w, caster, targets, spell, condition) do
    with {:ok, w} <- set_concentration(caster, spell).(w) do
      effect = %{"condition" => condition, "source" => caster, "concentration" => spell}

      {:ok,
       Enum.reduce(targets, w, fn name, acc ->
         c = character(acc, name)
         put_char(acc, name, %{c | conditions: c.conditions ++ [effect]})
       end)}
    end
  end

  @doc "Drop concentration (5e, D37). Idempotent if already nil."
  @spec clear_concentration(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def clear_concentration(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
      with :ok <- validate_actor(w, name),
           {:ok, w} <- Dragonex.TurnBudget.spend(w, name, :bonus),
           do: do_start_rage(name).(w)
    end
  end

  defp do_start_rage(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

        %Character{class: "barbarian"} = c ->
          max_rages = Dragonex.Heroes.Progression.rage_count(c.level || 1)

          cond do
            c.raging == true ->
              set_raging(name, true).(w)

            (c.rage_uses_used || 0) >= max_rages ->
              {:error,
               dgettext("engine", "%{name} no le quedan furias hoy (%{max}/%{max} usadas)",
                 name: name,
                 max: max_rages
               )}

            true ->
              with {:ok, w} <- set_raging(name, true).(w) do
                set_rage_uses_used(name, (c.rage_uses_used || 0) + 1).(w)
              end
          end

        %Character{} ->
          {:error,
           dgettext("engine", "%{name} no es bárbaro y no puede entrar en furia", name: name)}
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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
      with :ok <- validate_actor(w, name),
           :ok <- Dragonex.TurnBudget.check(w, name, :free) do
        if w.phase == :combat and get_in(w.turn_state, [name, "attacked"]) == true,
          do:
            {:error,
             dgettext("engine", "Ataque temerario se decide antes del primer ataque del turno")},
          else: do_start_reckless(name).(w)
      end
    end
  end

  defp do_start_reckless(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

        %Character{class: class} when class != "barbarian" ->
          {:error,
           dgettext("engine", "%{name} no es bárbaro y no puede atacar de forma temeraria",
             name: name
           )}

        %Character{level: level} when not is_integer(level) or level < 2 ->
          {:error, dgettext("engine", "%{name} no tiene Ataque temerario (nivel 2)", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

        %Character{class: class} when class != "paladin" ->
          {:error,
           dgettext("engine", "%{name} no es paladín y no puede usar Sentido divino", name: name)}

        %Character{divine_sense_uses: uses} = c ->
          uses = uses || 0

          if uses < 1 do
            {:error, dgettext("engine", "%{name} no tiene usos de Sentido divino", name: name)}
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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

        %Character{class: class} when class != "monk" ->
          {:error, dgettext("engine", "%{name} no es monje y no puede gastar ki", name: name)}

        %Character{ki: ki} = c ->
          ki = ki || 0

          if ki < amount do
            {:error,
             dgettext("engine", "%{name} no tiene suficiente ki (le quedan %{ki})",
               name: name,
               ki: ki
             )}
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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

        %Character{class: class} when class != "sorcerer" ->
          {:error,
           dgettext("engine", "%{name} no es hechicero y no puede gastar puntos de hechicería",
             name: name
           )}

        %Character{sorcery_points: points} = c ->
          points = points || 0

          if points < amount do
            {:error,
             dgettext(
               "engine",
               "%{name} no tiene suficientes puntos de hechicería (le quedan %{points})",
               name: name,
               points: points
             )}
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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

        %Character{class: class} when class != "sorcerer" ->
          {:error,
           dgettext("engine", "%{name} no es hechicero y no puede ganar puntos de hechicería",
             name: name
           )}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "%{name} ya está en forma de bestia", name: name)}
      end
    end
  end

  @doc """
  End Wild Shape (D63): restore the saved form — str/dex/con/max_hp/ac/
  weapons — with `hp` set to the saved `orig_hp`, including native vitality
  gained by progression while transformed (D129).
  Errors if `name` is missing or not transformed. (The auto-revert excess
  path lives in `apply_damage/3`, which computes the carry-over hp.)
  """
  @spec revert_wild_shape(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def revert_wild_shape(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

        %Character{wild_shape: nil} ->
          {:error, dgettext("engine", "%{name} no está en forma de bestia", name: name)}

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

  defp restore_wild_shape_form(%Character{wild_shape: %{}} = c, hp) do
    %{Dragonex.WildShape.base_form(c) | hp: hp}
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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

        %Character{} = c ->
          next = put_char(w, name, %{c | inspired: inspired})

          {:ok,
           if(inspired, do: Dragonex.WorldClock.track(next, name, "inspired", 600), else: next)}
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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
        {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

      %Character{class: class, level: level} ->
        level = level || 1
        max_slots = Dragonex.SpellSlots.for_class(class, level)
        current = Map.get(w.spell_slots, name, max_slots)
        budget = div(level + 1, 2)
        {new_slots, restored} = greedy_arcane_restore(current, max_slots, budget)

        if restored == %{} do
          {:error,
           dgettext(
             "engine",
             "%{name} no tiene huecos gastados que Recuperación arcana pueda restaurar",
             name: name
           )}
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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: who)}

        %Character{class: class} when class != "bard" ->
          {:error,
           dgettext("engine", "%{who} no es bardo y no puede usar Inspiración bárdica", who: who)}

        %Character{bardic_inspiration_uses: uses} = bard ->
          uses = uses || 0

          case character(w, target) do
            nil ->
              {:error, dgettext("engine", "no existe el personaje: %{name}", name: target)}

            %Character{inspired: true} ->
              {:error, dgettext("engine", "%{target} ya está inspirado", target: target)}

            %Character{} when uses < 1 ->
              {:error,
               dgettext("engine", "%{who} no tiene usos de Inspiración bárdica", who: who)}

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
      with :ok <- validate_actor(w, who),
           {:ok, w} <- Dragonex.TurnBudget.spend(w, who, :action),
           do: do_lay_on_hands(who, target, applied).(w)
    end
  end

  defp do_lay_on_hands(who, target, applied) do
    fn w ->
      case character(w, who) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: who)}

        %Character{class: class} when class != "paladin" ->
          {:error,
           dgettext("engine", "%{who} no es paladín y no puede usar Manos impositoras", who: who)}

        %Character{lay_on_hands_pool: pool} when not is_integer(pool) or pool < applied ->
          {:error,
           dgettext("engine", "%{who} no tiene suficientes puntos de Manos impositoras", who: who)}

        %Character{lay_on_hands_pool: pool} ->
          pool = pool || 0

          case character(w, target) do
            nil ->
              {:error, dgettext("engine", "no existe el personaje: %{name}", name: target)}

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
      with :ok <- validate_actor(w, name),
           {:ok, w} <- Dragonex.TurnBudget.spend(w, name, :bonus),
           do: do_second_wind(name, amount).(w)
    end
  end

  defp do_second_wind(name, amount) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

        %Character{class: class} when class != "fighter" ->
          {:error,
           dgettext("engine", "%{name} no es guerrero y no puede usar Segundo aliento",
             name: name
           )}

        %Character{second_wind_used: true} ->
          {:error,
           dgettext("engine", "%{name} ya ha usado Segundo aliento (se recarga con un descanso)",
             name: name
           )}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
    fn _w ->
      {:error,
       dgettext("engine", "el nivel de casilla del Castigo divino debe estar entre 1 y 5")}
    end
  end

  def start_smite(name, slot_level) when is_integer(slot_level) do
    fn w ->
      with :ok <- validate_actor(w, name),
           :ok <- Dragonex.TurnBudget.check(w, name, :free),
           do: do_start_smite(name, slot_level).(w)
    end
  end

  defp do_start_smite(name, slot_level) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

        %Character{class: class} when class != "paladin" ->
          {:error,
           dgettext("engine", "%{name} no es paladín y no puede usar Castigo divino", name: name)}

        %Character{class: class, level: level} ->
          table = Dragonex.SpellSlots.for_class(class, level || 1)

          cond do
            Map.get(table, slot_level, 0) < 1 ->
              {:error,
               dgettext(
                 "engine",
                 "a %{name} no le quedan casillas de hechizo de nivel %{slot_level}",
                 name: name,
                 slot_level: slot_level
               )}

            not has_slot?(w, name, slot_level) ->
              {:error,
               dgettext(
                 "engine",
                 "a %{name} no le quedan casillas de hechizo de nivel %{slot_level}",
                 name: name,
                 slot_level: slot_level
               )}

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
    fn _w ->
      {:error,
       dgettext("engine", "la cantidad de xp debe ser positiva (recibido %{amount})",
         amount: amount
       )}
    end
  end

  # Entradas inválidas (auditoría 7): un amount no entero no casaba con
  # ninguna cláusula y crasheaba (FunctionClauseError) en vez de error útil.
  def grant_xp(_name, amount) when not is_integer(amount) do
    fn _w ->
      {:error,
       dgettext("engine", "la cantidad de XP debe ser un entero positivo (recibió %{amount})",
         amount: inspect(amount)
       )}
    end
  end

  def grant_xp(name, amount) when is_integer(amount) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
      case present_character(w, target) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: target)}

        %Character{} when not is_integer(amount) or amount < 0 ->
          {:error, dgettext("engine", "la curación debe ser un entero no negativo")}

        %Character{death_saves: %{fails: fails}} when fails >= 3 ->
          {:error,
           dgettext("engine", "%{target} está muerto; la curación no resucita", target: target)}

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
          {:error, dgettext("engine", "ya hay un combate en curso")}

        Enum.empty?(initiative_order) ->
          {:error, dgettext("engine", "el orden de iniciativa está vacío")}

        not Enum.all?(initiative_order, &Map.has_key?(w.characters, &1)) ->
          {:error, dgettext("engine", "el orden de iniciativa incluye personajes desconocidos")}

        not Enum.all?(initiative_order, &present?(w, &1)) ->
          {:error, dgettext("engine", "la iniciativa incluye personajes fuera de escena")}

        true ->
          w = Map.put(w, :conversation, nil)

          {:ok,
           %{
             w
             | phase: :combat,
               initiative_order: initiative_order,
               acted_this_round: MapSet.new(),
               turn_state: %{},
               turn_kind: "main",
               turn_owner: nil,
               current_combatant: nil,
               pending_turn: nil,
               log: log(w, "dm", "combat begins: #{Enum.join(initiative_order, " → ")}")
           }}
      end
    end
  end

  @spec end_combat() :: (t() -> {:ok, t()})
  def end_combat do
    fn w ->
      w = if w.phase == :combat, do: Map.put(w, :scene_refresh_pending, true), else: w

      characters =
        Map.new(w.characters, fn
          {name, %Character{} = c} ->
            c =
              %{c | raging: false, reckless: false, smite_slot: nil}
              |> sweep_shielded(name)

            # D95/D96: la marca guided muere con el combate. Sin este
            # barrido, un combate nuevo en la MISMA ronda la revivía: el
            # primer turno del lanzador reescribe turn_state a esa ronda y
            # `ts == round` volvía a darla por activa (guided zombie).
            {name, %{c | conditions: Enum.reject(c.conditions, &guided_entry?/1)}}

          other ->
            other
        end)

      {:ok,
       %{
         w
         | phase: :exploration,
           characters: characters,
           acted_this_round: MapSet.new(),
           turn_state: %{},
           turn_kind: "main",
           turn_owner: nil,
           current_combatant: nil,
           pending_turn: nil,
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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

        not present?(w, name) ->
          {:error, dgettext("engine", "%{name} está fuera de escena", name: name)}

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

  @doc """
  Recover living, present hostiles omitted from a saved combat order. They join
  as reinforcements at the end, preserving the active slot and spent turns.
  This never reconstructs or rolls their original initiative.
  """
  @spec recover_hostile_initiative() :: (t() -> {:ok, t()})
  def recover_hostile_initiative do
    fn w ->
      if w.phase == :combat do
        missing =
          w
          |> living_enemies()
          |> Enum.reject(&(&1 in w.initiative_order))
          |> Enum.sort()

        recovered =
          Enum.reduce(missing, w, fn name, acc ->
            {:ok, joined} = join_initiative(name).(acc)
            joined
          end)

        {:ok, recovered}
      else
        {:ok, w}
      end
    end
  end

  @doc "Bump the round counter and clear `acted_this_round` (D25)."
  @spec next_round() :: (t() -> {:ok, t()})
  def next_round do
    fn w ->
      w = Dragonex.TurnBudget.finish(w, w.turn_owner)
      w = Dragonex.WorldClock.advance(w, 6)
      {:ok, %{w | round: w.round + 1, acted_this_round: MapSet.new(), current_combatant: nil}}
    end
  end

  @doc """
  Record whose initiative slot the current beat is (D34). Nil outside combat.
  Starting a combatant's turn ends their Reckless Attack (D44) and any
  pending Divine Smite (D46).
  """
  @spec set_current_combatant(
          String.t() | nil,
          String.t(),
          (pos_integer() -> pos_integer()),
          Dragonex.RollLog.t() | nil
        ) ::
          (t() -> {:ok, t()} | {:error, String.t()})
  def set_current_combatant(
        name,
        kind \\ "main",
        roller \\ &Dragonex.Dice.roll/1,
        roll_log \\ nil
      )
      when (is_binary(name) or is_nil(name)) and is_function(roller, 1) do
    fn w ->
      cond do
        kind not in ["main", "reaction"] ->
          {:error, dgettext("engine", "tipo de turno inválido")}

        w.phase != :combat ->
          {:ok, %{w | current_combatant: nil}}

        is_nil(name) or name == "" ->
          {:ok, %{w | current_combatant: nil}}

        present?(w, name) ->
          w =
            if kind == "main" and w.turn_owner != name,
              do: Dragonex.TurnBudget.finish(w, w.turn_owner),
              else: w

          characters =
            Map.update!(w.characters, name, fn
              %Character{} = c -> %{c | reckless: false, smite_slot: nil}
              other -> other
            end)

          # Re-selecting a participant is not a new turn and cannot refund resources.
          first? = kind == "main" and get_in(w.turn_state, [name, "round"]) != w.round
          # D96 Shield: la postura muere al INICIO del turno nuevo del
          # lanzador (eager, patrón D44). Re-seleccionar en el mismo turno
          # no la toca.
          characters =
            if first?,
              do: Map.update!(characters, name, &sweep_shielded(&1, name)),
              else: w.characters

          next = %{
            w
            | current_combatant: name,
              characters: characters,
              turn_kind: kind,
              turn_owner: if(kind == "main", do: name, else: w.turn_owner)
          }

          next = if first?, do: reroll_hold_person(next, name, roller, roll_log), else: next
          # D99: la postura del arma espiritual envejece y el aura de spirit
          # guardians tickea, solo en turno nuevo (mismo cuello D44).
          next = if first?, do: age_spiritual_weapon(next, name), else: next
          next = if first?, do: spirit_guardians_tick(next, name, roller, roll_log), else: next

          {:ok, if(first?, do: Dragonex.TurnBudget.start(next, name), else: next)}

        true ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}
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
      with {:ok, w} <- Dragonex.TurnBudget.spend(w, target, :death_save),
           do: do_apply_death_save(target, result).(w)
    end
  end

  defp do_apply_death_save(target, result) do
    fn w ->
      case character(w, target) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: target)}

        %Character{hp: hp} when hp > 0 ->
          {:error, dgettext("engine", "%{target} no está caído", target: target)}

        %Character{death_saves: %{fails: fails}} when fails >= 3 ->
          {:error, dgettext("engine", "%{target} está muerto", target: target)}

        %Character{death_saves: %{successes: successes}} when successes >= 3 ->
          {:error, dgettext("engine", "%{target} ya está estable", target: target)}

        %Character{} = c ->
          {:ok, put_char(w, target, resolve_death_save(c, result))}
      end
    end
  end

  @doc "Stabilize a living creature at 0 HP without healing or spending its death save."
  @spec stabilize(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def stabilize(target) do
    fn w ->
      case present_character(w, target) do
        nil ->
          {:error, dgettext("engine", "no existe el objetivo: %{target}", target: target)}

        %Character{death_saves: %{fails: fails}} when fails >= 3 ->
          {:error,
           dgettext("engine", "%{target} está muerto; estabilizar no resucita", target: target)}

        %Character{hp: hp} when hp != 0 ->
          {:error,
           dgettext("engine", "%{target} debe estar a 0 pg para estabilizarse", target: target)}

        %Character{} = c ->
          {:ok, put_char(w, target, %{c | death_saves: %{successes: 3, fails: 0}})}
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
              {:error,
               dgettext(
                 "engine",
                 "a %{name} no le quedan casillas de hechizo de nivel %{slot_level}",
                 name: name,
                 slot_level: slot_level
               )}
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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

        %Character{class: class, level: level} ->
          max_slots = Dragonex.SpellSlots.for_class(class, level)
          {:ok, %{w | spell_slots: Map.put(w.spell_slots, name, max_slots)}}
      end
    end
  end

  @doc """
  Sube el nivel de un personaje: nivel +1, PG máximos (dado medio + CON), y
  capacidad nueva de casillas/pools conservando gasto. Si se pasan `choices`
  (`spells_added`, `asi`, `custom`),
  también aplica hechizos nuevos, mejora de característica (a niveles ASI) y las
  features de clase del nuevo nivel. La lógica vive en
   `Dragonex.Heroes.LevelUp.apply/2`; aquí solo la aplicamos al `Character` del
   mundo y aumentamos la capacidad de casillas conservando los usos gastados.
  """
  @spec level_up(String.t(), map()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def level_up(name, choices \\ %{}) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

        %Character{level: 20} ->
          {:error, dgettext("engine", "%{name} ya está en el nivel máximo (20)", name: name)}

        %Character{} = c ->
          case Dragonex.Heroes.LevelUp.apply(c, choices) do
            {:ok, leveled} ->
              w2 = put_char(w, name, leveled)

              slots =
                Dragonex.SpellSlots.level_up(
                  c.class,
                  c.level,
                  leveled.level,
                  Map.get(w.spell_slots, name)
                )

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
    present_characters(w)
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
    case present_character(w, name) do
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
    case present_character(w, name) do
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
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: target)}

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

  @doc "Apply a condition with an explicit positive duration in game seconds."
  def apply_condition(target, condition, seconds) do
    fn w ->
      if is_integer(seconds) and seconds > 0 do
        with {:ok, next} <- apply_condition(target, condition).(w) do
          if has_condition?(next, target, condition),
            do:
              {:ok, Dragonex.WorldClock.track(next, target, "condition:" <> condition, seconds)},
            else: {:ok, next}
        end
      else
        {:error, dgettext("engine", "la duración debe ser un entero positivo")}
      end
    end
  end

  @doc "Remove a condition from a character."
  @spec remove_condition(String.t(), String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def remove_condition(target, condition) do
    fn w ->
      case character(w, target) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: target)}

        %Character{conditions: conds} = c ->
          filtered = Enum.reject(conds, &(Character.condition_name(&1) == condition))

          next = put_char(w, target, %{c | conditions: filtered})

          timers =
            Map.get(next.effect_expiries, target, %{}) |> Map.delete("condition:" <> condition)

          {:ok, %{next | effect_expiries: Map.put(next.effect_expiries, target, timers)}}
      end
    end
  end

  # --- Guiding Bolt (D95): helpers aislados del marcador guided. ---
  # La caducidad es perezosa (Rules.Guided la deriva de turn_state/phase);
  # aquí solo viven la marca y el consumo atómico que compone Actions.

  @doc """
  Guiding Bolt (D95): marca al objetivo — la próxima tirada de ataque contra
  él gana ventaja y consume la marca. Sustituye cualquier marca guided previa
  (una aplicación fresca gana). Idempotente respecto a otras condiciones.
  """
  @spec mark_guided(String.t(), String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def mark_guided(target, caster) when is_binary(target) and is_binary(caster) do
    fn w ->
      case character(w, target) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: target)}

        %Character{conditions: conds} = c ->
          kept = Enum.reject(conds, &guided_entry?/1)
          entry = %{"condition" => "guided", "source" => caster, "round" => w.round}

          {:ok, put_char(w, target, %{c | conditions: kept ++ [entry]})}
      end
    end
  end

  @doc """
  Guiding Bolt (D95): consume la marca guided del objetivo (la primera
  tirada de ataque posterior, acierte o falle). Idempotente: sin marca,
  no cambia nada.
  """
  @spec consume_guided(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def consume_guided(target) when is_binary(target) do
    fn w ->
      case character(w, target) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: target)}

        %Character{conditions: conds} = c ->
          if Enum.any?(conds, &guided_entry?/1) do
            {:ok, put_char(w, target, %{c | conditions: Enum.reject(conds, &guided_entry?/1)})}
          else
            {:ok, w}
          end
      end
    end
  end

  defp guided_entry?(%{"condition" => "guided"}), do: true
  defp guided_entry?(_), do: false

  # --- Sleep y Shield (D96): sección aislada. ---

  @doc """
  Sleep (D96): marca a los objetivos como inconscientes por sueño del
  `caster`. Entrada estructurada con fuente para el despertar por daño;
  duración 1 minuto vía WorldClock (misma clave que apply_condition).
  """
  @spec apply_sleep(String.t(), [String.t()]) :: (t() -> {:ok, t()})
  def apply_sleep(_caster, []), do: fn w -> {:ok, w} end

  def apply_sleep(caster, targets) when is_binary(caster) and is_list(targets) do
    fn w ->
      w =
        Enum.reduce(targets, w, fn name, acc ->
          case character(acc, name) do
            %Character{conditions: conds} = c ->
              entry = %{"condition" => "unconscious", "source" => "sleep:#{caster}"}
              put_char(acc, name, %{c | conditions: conds ++ [entry]})

            _ ->
              acc
          end
        end)

      {:ok,
       Enum.reduce(targets, w, &Dragonex.WorldClock.track(&2, &1, "condition:unconscious", 60))}
    end
  end

  @doc """
  Sleep (D96): despertar por daño — quita SOLO las entradas unconscious cuya
  fuente es sueño (un inconsciente por otra causa no se toca).
  """
  @spec wake_sleepers(String.t()) :: (t() -> {:ok, t()})
  def wake_sleepers(target) when is_binary(target) do
    fn w ->
      case character(w, target) do
        %Character{conditions: conds} = c ->
          if Enum.any?(conds, &sleep_unconscious?/1) do
            {:ok,
             put_char(w, target, %{c | conditions: Enum.reject(conds, &sleep_unconscious?/1)})}
          else
            {:ok, w}
          end

        _ ->
          {:ok, w}
      end
    end
  end

  defp sleep_unconscious?(%{"condition" => "unconscious", "source" => "sleep:" <> _}), do: true
  defp sleep_unconscious?(_), do: false

  @doc """
  Shield (D96): arma la postura del lanzador (+5 CA efectiva hasta el inicio
  de su siguiente turno). Rearmar RENUEVA (nunca apila): sustituye cualquier
  entrada shielded previa.
  """
  @spec arm_shield(String.t()) :: (t() -> {:ok, t()} | {:error, String.t()})
  def arm_shield(name) when is_binary(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

        %Character{conditions: conds} = c ->
          kept = Enum.reject(conds, &shielded_entry?/1)
          entry = %{"condition" => "shielded", "source" => name}
          {:ok, put_char(w, name, %{c | conditions: kept ++ [entry]})}
      end
    end
  end

  defp shielded_entry?(%{"condition" => "shielded"}), do: true
  defp shielded_entry?(_), do: false

  # D96: barrido eager de la postura shield del propio personaje.
  defp sweep_shielded(%Character{conditions: conds} = c, _name),
    do: %{c | conditions: Enum.reject(conds, &shielded_entry?/1)}

  defp sweep_shielded(other, _name), do: other

  # D97: nueva salvación de Sabiduría al inicio del turno del paralizado.
  # Re-selección y reacción no llegan aquí (`first?` es false).
  defp reroll_hold_person(w, name, roller, roll_log) do
    Dragonex.Actions.reroll_hold_person(w, name, roller, roll_log)
  end

  # D99: el aura recurrente se resuelve en Actions (stack completo de
  # salvación de condition_save); World solo la engancha al cuello de turno.
  defp spirit_guardians_tick(w, name, roller, roll_log) do
    Dragonex.Actions.spirit_guardians_tick(w, name, roller, roll_log)
  end

  # D99: el arma espiritual pierde 1 ronda al inicio del turno NUEVO del
  # lanzador; a 0 muere con nota. Re-selección/reacción no envejecen.
  defp age_spiritual_weapon(w, name) do
    case character(w, name) do
      %Character{conditions: conds} = c ->
        {kept, notes} =
          Enum.reduce(conds || [], {[], []}, fn entry, {kept, notes} ->
            if spirit_weapon_entry?(entry) do
              left = (entry["rounds_left"] || 0) - 1

              if left > 0,
                do: {kept ++ [Map.put(entry, "rounds_left", left)], notes},
                else:
                  {kept,
                   notes ++
                     [
                       dgettext("engine", "el arma espiritual de %{name} se desvanece (1 minuto)",
                         name: name
                       )
                     ]}
            else
              {kept ++ [entry], notes}
            end
          end)

        w = put_char(w, name, %{c | conditions: kept})
        Enum.reduce(notes, w, &note(&2, "dm", &1))

      _ ->
        w
    end
  end

  # D96: helper del gancho de despertar — sin daño real entrante no despierta.
  defp wake_on_damage(%Character{} = c, incoming) when incoming > 0,
    do: %{c | conditions: Enum.reject(c.conditions, &sleep_unconscious?/1)}

  defp wake_on_damage(%Character{} = c, _incoming), do: c

  # D98: el lanzador o su side rompen charm_person. Un tercero no. Sin
  # atacante en las opts, el daño no sabe de quién es y no rompe nada.
  defp break_charm(%Character{} = c, incoming, opts) when incoming > 0 do
    attacker = opts[:attacker]
    side = opts[:attacker_side]

    %{
      c
      | conditions: Enum.reject(c.conditions, &charm_broken?(&1, attacker, side))
    }
  end

  defp break_charm(%Character{} = c, _incoming, _opts), do: c

  defp charm_broken?(
         %{"condition" => "charmed", "source" => "charm_person:" <> caster} = entry,
         attacker,
         side
       ) do
    attacker == caster or (is_binary(side) and side != "" and side == entry["caster_side"])
  end

  defp charm_broken?(_, _, _), do: false

  defp forget_charm_timer(w, name, %Character{} = c) do
    if Enum.any?(c.conditions || [], &(Character.condition_name(&1) == "charmed")) do
      w
    else
      Dragonex.WorldClock.forget(w, name, "condition:charmed")
    end
  end

  # Newest-first. Capped so the persisted jsonb does not grow without bound;
  # the canonical timeline is `game_events`, not this field.
  @max_log 50

  defp in_combat_cycle?(w, name) do
    cond do
      not present?(w, name) -> false
      dead?(w, name) -> false
      match?(%Character{side: "pc"}, character(w, name)) -> true
      match?(%Character{hp: hp} when hp > 0, character(w, name)) -> true
      true -> false
    end
  end

  defp log(%__MODULE__{log: l}, actor, entry), do: Enum.take([{actor, entry} | l], @max_log)

  defp put_char(%__MODULE__{characters: chars} = w, name, %Character{} = c) do
    %{w | characters: Map.put(chars, name, c)}
    |> Dragonex.WorldClock.observe(Map.get(chars, name), c)
  end

  @doc "Advance explicit game time; combat time advances through rounds."
  def advance_time(seconds) do
    fn w ->
      cond do
        not is_integer(seconds) or seconds < 0 ->
          {:error, dgettext("engine", "el tiempo debe ser un entero no negativo")}

        w.phase == :combat ->
          {:error, dgettext("engine", "el tiempo de combate avanza por rondas")}

        true ->
          {:ok, Dragonex.WorldClock.advance(w, seconds)}
      end
    end
  end

  @doc "Resolve one declared wait once, retaining its receipt after actor settlement."
  def resolve_wait(source_turn_id, declared_seconds, elapsed_seconds) do
    fn world ->
      cond do
        not is_binary(source_turn_id) or source_turn_id == "" or
          not is_integer(declared_seconds) or declared_seconds <= 0 or declared_seconds > 86400 or
          not is_integer(elapsed_seconds) or elapsed_seconds < 0 or
            elapsed_seconds > declared_seconds ->
          {:error,
           dgettext("engine", "la espera requiere un origen y una duración transcurrida válida")}

        world.phase == :combat ->
          {:error, dgettext("engine", "el tiempo de combate avanza por rondas")}

        is_map(Map.get(world, :wait_resolution)) and
            world.wait_resolution["source_turn_id"] == source_turn_id ->
          {:ok, world}

        true ->
          with {:ok, next} <- advance_time(elapsed_seconds).(world) do
            receipt = %{
              "source_turn_id" => source_turn_id,
              "declared_seconds" => declared_seconds,
              "elapsed_seconds" => elapsed_seconds,
              "clock_before" => world.elapsed_seconds,
              "clock_after" => next.elapsed_seconds
            }

            receipt =
              if world.scene_refresh_pending,
                do: receipt,
                else:
                  Map.put(receipt, "scene_review_fingerprint", scene_review_fingerprint(world))

            {:ok, %{next | wait_resolution: receipt}}
          end
      end
    end
  end

  @doc "Fingerprint of established state for a wait's read-only scene confirmation."
  def scene_review_fingerprint(%__MODULE__{} = world) do
    world
    |> Map.drop([:elapsed_seconds, :scene_refresh_pending, :wait_resolution, :actor_checkpoint])
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Temporary hit points end after a long rest."
  def clear_temp_hp(name) do
    fn w ->
      case character(w, name) do
        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

        c ->
          {:ok,
           put_char(w, name, %{c | temp_hp: 0}) |> Dragonex.WorldClock.forget(name, "temp_hp")}
      end
    end
  end

  defp fresh_saves, do: %{successes: 0, fails: 0}

  defp resolve_death_save(%Character{} = c, {:revive, _d20, _f, _s}) do
    %{c | hp: 1, death_saves: fresh_saves()}
  end

  defp resolve_death_save(
         %Character{death_saves: %{fails: f, successes: s}} = c,
         {_tag, _d20, fd, sd}
       ) do
    saves = %{fails: f + fd, successes: s + sd}
    # Keep the existing stable sentinel for callers/Codec, but clear failures
    # as RAW requires when becoming stable. The sentinel is removed on damage.
    saves =
      if saves.successes >= 3 and saves.fails < 3, do: %{successes: 3, fails: 0}, else: saves

    %{c | death_saves: saves}
  end
end
