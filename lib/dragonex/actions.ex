defmodule Dragonex.Actions do
  @moduledoc """
  Pure orchestration that turns an actor's *intent* into a narrated outcome plus
  a world change — the bridge between `Dragonex.Rules` (the math) and
  `Dragonex.World` (the state).

  Every function returns `{:ok, message, change_fn} | {:error, reason}`, where:

    * `message`    — a factual string the tool hands back to the LLM (the LLM
                     never computes the math; it only reads results);
    * `change_fn`  — a `(world -> {:ok, world} | {:error, reason})` ready for
                     `SharedState.propose_change/2`.

  No exAgent here: deterministic and unit-testable with a fixed roller.
  """

  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{
    Character,
    Dice,
    RollLog,
    Rules.Ability,
    Rules.Cantrips,
    Rules.Combat,
    Rules.Effects,
    Rules.Conditions,
    Rules.Guided,
    Rules.Skills,
    Rules.Upcast,
    Spell,
    SpellSlots,
    Terms,
    Weapon,
    WildShape,
    World
  }

  alias Dragonex.Heroes.{Progression, Spells, Translations}

  @resource_fields ~w(ki sorcery_points action_surge_used second_wind_used
    channel_divinity_used lay_on_hands_pool divine_sense_uses bardic_inspiration_uses
    wild_shape_uses breath_weapon_used rage_uses_used arcane_recovery_used
    metamagic inspired smite_slot conditions concentrating)a

  # Validate before rolling, and again against the world receiving the change.
  # Preparation and application are separate calls; neither may trust the
  # caller to keep an actor conscious/capable between those calls.
  defp with_actor(world, who, resolve, cost \\ :free) do
    with :ok <- World.validate_actor(world, who),
         :ok <- Dragonex.TurnBudget.check(world, who, cost),
         {:ok, message, change} <- resolve.() do
      {:ok, message,
       fn current ->
         with :ok <- World.validate_actor(current, who),
              :ok <- unchanged_turn(world, current),
              :ok <- unchanged_resources(world, current, who),
              {:ok, current} <- Dragonex.TurnBudget.spend(current, who, cost),
              do: change.(current)
       end}
    end
  end

  defp unchanged_resources(before, current, who) do
    if Map.take(World.present_character(before, who), @resource_fields) ==
         Map.take(World.present_character(current, who), @resource_fields) and
         before.spell_slots[who] == current.spell_slots[who] and
         before.turn_state[who] == current.turn_state[who],
       do: :ok,
       else:
         {:error,
          dgettext("engine", "los recursos de %{actor} han cambiado; vuelve a resolver la acción",
            actor: who
          )}
  end

  defp unchanged_turn(before, current) do
    keys = [
      :phase,
      :round,
      :current_combatant,
      :turn_kind,
      :turn_owner,
      :elapsed_seconds,
      :absent_characters
    ]

    if Map.take(before, keys) == Map.take(current, keys),
      do: :ok,
      else:
        {:error,
         dgettext("engine", "ha cambiado el turno o el tiempo; vuelve a resolver la acción")}
  end

  @type roller :: (pos_integer() -> pos_integer())
  @type result ::
          {:ok, String.t(), (World.t() -> {:ok, World.t()} | {:error, term()})}
          | {:error, String.t()}

  @doc "Roll one or more dice and report the total (no world side-effect)."
  @spec roll(
          pos_integer(),
          pos_integer(),
          :normal | :advantage | :disadvantage,
          roller(),
          RollLog.t() | nil
        ) ::
          {:ok, String.t()}
  def roll(count, sides, mode \\ :normal, roller, roll_log \\ nil) do
    # Entradas inválidas (auditoría 7): caras <= 0 crasheaban en Dice.roll
    # (FunctionClauseError), counts gigantes colgaban la tirada, y un 0
    # devolvía "0d6 = 0" basura. Rango sano y mensaje accionable.
    if not is_integer(count) or not is_integer(sides) or count < 1 or count > 100 or
         sides < 2 or sides > 1000 do
      {:error,
       dgettext(
         "engine",
         "tirada inválida: %{count} dados de %{sides} caras — usa enteros (1..100 dados, 2..1000 caras)",
         count: inspect(count),
         sides: inspect(sides)
       )}
    else
      do_roll(count, sides, mode, roller, roll_log)
    end
  end

  defp do_roll(count, sides, mode, roller, roll_log) do
    {r, close} =
      RollLog.open(
        roll_log,
        roller,
        nil,
        :roll,
        dgettext("engine", "tirada de %{count}d%{sides}", count: count, sides: sides)
      )

    result =
      case mode do
        :normal ->
          {:ok,
           dgettext("engine", "tirada %{count}d%{sides} = %{total}",
             count: count,
             sides: sides,
             total: sum(count, sides, r)
           )}

        mode when mode in [:advantage, :disadvantage] ->
          kept =
            for _ <- 1..max(count, 1) do
              {k, _, _} = Dice.roll_advantage(sides, mode, r)
              k
            end

          {:ok,
           dgettext("engine", "tirada %{count}d%{sides} (%{mode}) = %{total}",
             count: count,
             sides: sides,
             mode: mode,
             total: Enum.sum(kept)
           )}
      end

    RollLog.close(close, total: nil, against: nil, outcome: nil)
    result
  end

  @doc """
  Resolve a weapon Attack action: N attack rolls (with crit/fumble) against
  the same target, then damage on each hit. N comes from
  `Progression.attack_count/2` (Extra Attack 5e, D35). If the target drops
  (hp ≤ 0) mid-action, remaining swings are skipped (no retarget); a target
  that is ALREADY downed CAN be attacked (RAW: each hit with damage
  registers death-save failures — `World.apply_damage/5`). The
  attacker and target must already be in the world, and the attacker must
  wield the named weapon. Melee hits vs a `paralyzed`/`unconscious`
  target are automatic criticals (RAW). Sneak Attack (D41) adds N d6 to
  the first hit of this call when the rogue qualifies.   Rage (D42) adds
  `Progression.rage_damage/1` to every melee hit (`weapon.ranged != true`)
  while the attacker is raging. Divine Smite (D46) spends a pending
  `smite_slot` on the first melee hit (or crit) of this call: extra
  radiant dice through `apply_damage/3`, then `consume_slot`. Miss,
  ranged, and spells leave the pending slot. Fighting Style (D48):
  archery/dueling in `Combat`;   defense raises this target's effective AC
  by 1 without mutating `Character.ac`. Bardic Inspiration (D50) adds 1d6
  to the first swing's attack total (hit or miss consumes; not damage).
  Hunter's Mark (D55) adds 1d6 to every hit against the marked prey while
  the attacker concentrates `"hunter's mark:prey"` (crit doubles the mark
  dice; damage type is the weapon's, like Sneak Attack). Spells and
  Flurry never benefit from the mark. Savage Attacks (D69) adds one extra
  weapon die to a half-orc's melee crit (inside `Combat.damage_roll`).
  """
  @spec attack(
          World.t(),
          String.t(),
          String.t(),
          String.t(),
          roller(),
          :normal | :advantage | :disadvantage,
          RollLog.t() | nil
        ) :: result()
  def attack(world, attacker, target, weapon_name, roller, mode \\ :normal, roll_log \\ nil) do
    with_actor(
      world,
      attacker,
      fn ->
        do_attack(world, attacker, target, weapon_name, roller, mode, roll_log)
      end,
      :attack
    )
  end

  defp do_attack(world, attacker, target, weapon_name, roller, mode, roll_log) do
    cond do
      is_nil(World.present_character(world, attacker)) ->
        {:error, dgettext("engine", "no existe el atacante: %{attacker}", attacker: attacker)}

      is_nil(World.present_character(world, target)) ->
        {:error, dgettext("engine", "no existe el objetivo: %{target}", target: target)}

      # A downed actor (hp <= 0) cannot take actions — the engine enforces RAW
      # rather than trusting the model not to attack from 0 pg.
      World.present_character(world, attacker).hp <= 0 ->
        {:error,
         dgettext("engine", "%{attacker} está caído (0 pg) y no puede atacar", attacker: attacker)}

      true ->
        a = World.present_character(world, attacker)
        t = World.present_character(world, target)

        case find_weapon(a, weapon_name) do
          nil ->
            {:error,
             dgettext("engine", "%{attacker} no tiene el arma %{weapon}",
               attacker: attacker,
               weapon: weapon_name
             )}

          weapon ->
            attack_opts = [
              requested: mode,
              ranged: weapon.ranged == true,
              attack_ability: weapon.attack_ability,
              finesse: weapon.finesse == true
            ]

            effective_mode = Conditions.attack_mode(a, t, attack_opts)

            # D95 Guiding Bolt: la marca del objetivo ventajea SOLO el primer
            # swing del ataque (RAW: la primera tirada posterior) y se
            # consume con él acierte o falle.
            guided? = Guided.active?(world, t)

            first_mode =
              if(guided?,
                do: Conditions.attack_mode(a, t, Keyword.put(attack_opts, :guided, true)),
                else: nil
              )

            n = Progression.attack_count(a.class, a.level)
            sneak = sneak_opts(world, a, attacker, target, weapon, first_mode || effective_mode)
            smite = smite_opts(a, weapon)
            inspired? = a.inspired == true
            mark? = mark_target?(a, target)
            hidden? = "hidden" in Character.condition_names(a)
            # D61: the attack target's concentration saves ride this aura.
            aura = aura_save_bonus(world, target)

            swings =
              resolve_swings(
                a,
                t,
                attacker,
                target,
                weapon,
                roller,
                roll_log,
                effective_mode,
                first_mode,
                n,
                sneak,
                smite,
                inspired?,
                mark?,
                aura
              )

            ac = target_ac(t)

            {notes, change} =
              pipe_attack_damage(target, swings, roller, roll_log, t, weapon.damage_type, aura)

            change = compose_smite_spend(attacker, a.smite_slot, swings, change)
            change = compose_sneak_spend(attacker, swings, change)
            change = compose_inspired_clear(attacker, inspired?, change)
            # D57: attacking (hit or miss, every swing) reveals a hidden attacker.
            change = compose_hidden_clear(attacker, hidden?, change)
            # D95: la tirada (el primer swing) consumió la marca guiada.
            change = consume_guided_change(target, guided?, change)
            prior = change

            change = fn w ->
              with {:ok, next} <- prior.(w) do
                {:ok,
                 if(a.side != t.side,
                   do: Dragonex.TurnBudget.mark(next, attacker, "rage_attack"),
                   else: next
                 )}
              end
            end

            {:ok,
             append_notes(
               # D95: el modo mostrado refleja el primer swing (el guiado
               # ventajea la tirada que consume la marca).
               format_attack_message(
                 attacker,
                 target,
                 weapon,
                 ac,
                 first_mode || effective_mode,
                 swings
               ),
               notes
             ), change}
            |> guard_target_defense(world, target, :attack)
        end
    end
  end

  @doc """
  Resolve a spell against a single target by its `kind`:

    * `:automatic` — always hits (e.g. magic missile); full dice damage.
    * `:attack`    — spell attack vs AC (nat 20 auto-hits, nat 1 auto-misses).
    * `:save`      — target saves vs DC; success halves the damage (5e default).

  Upcasting (D74, M58): `cast_level` (optional, `nil` = the spell's base
  level — backwards compatible) spends ONE slot of that exact level and scales
  the spell with the curated RAW table in `Rules.Upcast` (`fireball` with a
  4th-level slot rolls 9d6). Spells absent from the table never scale (the
  slot is still the requested one). Save DC and concentration are unchanged
  (RAW). Errors mutate nothing: `cast_level` below the base level, above 9,
  non-integer, upcast cantrip, or no slot left of the REQUESTED level.

  Lesser Restoration (D90) accepts `condition_to_remove` as the final optional
  argument. Omit it only when each target has exactly one eligible condition.
  Other spells reject this selector. No dice, healing or upcast scaling.
  """
  @spec spell(
          World.t(),
          String.t(),
          String.t(),
          String.t(),
          roller(),
          RollLog.t() | nil,
          non_neg_integer() | nil,
          [String.t()] | nil,
          String.t() | nil
        ) :: result()
  def spell(
        world,
        caster_name,
        spell_name,
        target_name,
        roller,
        roll_log \\ nil,
        cast_level \\ nil,
        additional_targets \\ nil,
        condition_to_remove \\ nil
      ) do
    with_actor(
      world,
      caster_name,
      fn ->
        do_spell(
          world,
          caster_name,
          spell_name,
          target_name,
          roller,
          roll_log,
          cast_level,
          additional_targets,
          condition_to_remove
        )
      end,
      Dragonex.TurnBudget.spell_cost(
        case World.present_character(world, caster_name) do
          nil -> nil
          c -> find_spell(c, spell_name)
        end
      )
    )
  end

  defp do_spell(
         world,
         caster_name,
         spell_name,
         target_name,
         roller,
         roll_log,
         cast_level,
         additional_targets,
         condition_to_remove
       ) do
    cond do
      is_nil(World.present_character(world, caster_name)) ->
        {:error, dgettext("engine", "no existe el conjurador: %{caster}", caster: caster_name)}

      is_nil(World.present_character(world, target_name)) ->
        {:error, dgettext("engine", "no existe el objetivo: %{target}", target: target_name)}

      # A downed caster cannot cast — the engine enforces RAW.
      World.present_character(world, caster_name).hp <= 0 ->
        {:error,
         dgettext("engine", "%{caster} está caído (0 pg) y no puede conjurar",
           caster: caster_name
         )}

      World.present_character(world, caster_name).raging == true ->
        {:error,
         dgettext("engine", "%{caster} está en furia y no puede conjurar", caster: caster_name)}

      World.present_character(world, caster_name).wild_shape != nil ->
        {:error,
         dgettext("engine", "%{caster} no puede conjurar en forma de bestia", caster: caster_name)}

      true ->
        c = World.present_character(world, caster_name)
        t = World.present_character(world, target_name)

        case find_spell(c, spell_name) do
          nil ->
            {:error,
             dgettext("engine", "%{caster} no conoce %{spell}",
               caster: caster_name,
               spell: spell_name
             )}

          spell ->
            with {:ok, cast_level} <- validate_cast_level(spell, cast_level),
                 :ok <-
                   validate_spell_targets(
                     world,
                     spell,
                     target_name,
                     additional_targets,
                     cast_level
                   ),
                 :ok <- validate_healing_target(spell, t),
                 :ok <- validate_self_spell_target(spell, caster_name, target_name),
                 :ok <- validate_condition_selection(spell, condition_to_remove) do
              # Check a slot of the REQUESTED level for leveled spells
              # (cantrips are free; D74 upcasting spends the asked slot).
              if spell.level > 0 and not World.has_slot?(world, caster_name, cast_level) do
                {:error,
                 dgettext(
                   "engine",
                   "a %{caster} no le quedan casillas de hechizo de nivel %{level} (debe descansar para recuperarlas). Los trucos siempre están disponibles.",
                   caster: caster_name,
                   level: cast_level
                 )}
              else
                # D74: one combined dice expression (base + extra) rides the
                # normal resolution paths — same roll log, same halving on a
                # save, crit doubles the extra dice too.
                # D95: the sheet's nil fields are filled from the catalogue
                # (builtin wins — stale pre-builtin sheets), and cantrips
                # scale with the CASTER's level, never with cast_level.
                scaled =
                  spell
                  |> overlay_catalog()
                  |> Upcast.scaled_spell(cast_level)
                  |> Cantrips.scaled_spell(c.level)

                result =
                  case {if(false_life?(spell), do: "false life", else: spell.name),
                        twinned_target(world, c, caster_name, target_name)} do
                    {"false life", _} ->
                      resolve_false_life(caster_name, spell, cast_level, roller, roll_log)

                    {"sleep", _} ->
                      # D96: pool de sueño RAW. Twinned no duplica el pool:
                      # se resuelve una vez y la opción no se aplica ni se
                      # consume (mismo criterio que los self-buffs).
                      resolve_sleep(world, c, caster_name, scaled, roller, roll_log)

                    {"shield", _} ->
                      # D96: postura armable en el turno propio (patrón D64).
                      resolve_shield(world, caster_name, target_name)

                    {"spiritual weapon", twin_name} ->
                      # D99: el ataque inicial queda como está (rama genérica
                      # de ataque de conjuro) y la lanzadura DEJA la postura
                      # persistente. Twin conserva el flujo previo.
                      attack =
                        if is_nil(twin_name),
                          do:
                            resolve_spell(
                              world,
                              c,
                              caster_name,
                              t,
                              target_name,
                              scaled,
                              roller,
                              roll_log
                            ),
                          else:
                            resolve_twinned(
                              world,
                              c,
                              caster_name,
                              target_name,
                              twin_name,
                              scaled,
                              roller,
                              roll_log
                            )

                      chain_spiritual_weapon_posture(attack, caster_name, scaled, c)

                    {"spirit guardians", _} ->
                      # D99: sin daño inmediato; marca el aura vinculada a
                      # concentración (patrón D97). Twinned no aplica ni
                      # consume (alcance self, mismo criterio que D96 sleep).
                      resolve_spirit_guardians(caster_name, scaled, c)

                    {"bless", _} ->
                      targets = [target_name | additional_targets || []]

                      {:ok,
                       dgettext(
                         "engine",
                         "%{caster} conjura %{spell} sobre %{targets}: +1d4 a ataques y salvaciones durante 1 minuto. %{caster} concentra en %{spell}.",
                         caster: caster_name,
                         spell: Terms.spell("bless"),
                         targets: Enum.join(targets, ", ")
                       ), World.bless(caster_name, targets, cast_level)}

                    {"shield of faith", twin_name} ->
                      targets =
                        if is_nil(twin_name), do: [target_name], else: [target_name, twin_name]

                      with :ok <- World.validate_shield_of_faith_targets(world, targets) do
                        {:ok,
                         dgettext(
                           "engine",
                           "%{caster} conjura %{spell} sobre %{targets}: +2 CA durante 10 minutos. %{caster} concentra en %{spell}.",
                           caster: caster_name,
                           spell: Terms.spell("shield of faith"),
                           targets: Enum.join(targets, ", ")
                         ), World.shield_of_faith(caster_name, targets)}
                        |> consume_metamagic(caster_name, not is_nil(twin_name))
                      end

                    {"hold person", twin_name} ->
                      targets =
                        if is_nil(twin_name), do: [target_name], else: [target_name, twin_name]

                      resolve_hold_person(world, c, caster_name, spell, targets, roller, roll_log)
                      |> consume_metamagic(
                        caster_name,
                        metamagic_applied?(c, spell, target_name, twin_name)
                      )

                    {"faerie fire", twin_name} ->
                      targets =
                        if is_nil(twin_name), do: [target_name], else: [target_name, twin_name]

                      resolve_faerie_fire(world, c, caster_name, spell, targets, roller, roll_log)
                      |> consume_metamagic(
                        caster_name,
                        metamagic_applied?(c, spell, target_name, twin_name)
                      )

                    {"mage armor", twin_name} ->
                      targets =
                        if is_nil(twin_name), do: [target_name], else: [target_name, twin_name]

                      resolve_mage_armor(world, caster_name, targets)
                      |> consume_metamagic(caster_name, not is_nil(twin_name))

                    {"charm person", twin_name} ->
                      targets =
                        if is_nil(twin_name), do: [target_name], else: [target_name, twin_name]

                      resolve_charm_person(
                        world,
                        c,
                        caster_name,
                        spell,
                        targets,
                        roller,
                        roll_log
                      )
                      |> consume_metamagic(
                        caster_name,
                        metamagic_applied?(c, spell, target_name, twin_name)
                      )

                    {"spare the dying", twin_name} ->
                      targets =
                        if is_nil(twin_name), do: [target_name], else: [target_name, twin_name]

                      Dragonex.Actions.SpareTheDying.prepare(world, caster_name, targets)
                      |> consume_metamagic(caster_name, not is_nil(twin_name))

                    {"lesser restoration", twin_name} ->
                      targets =
                        if is_nil(twin_name), do: [target_name], else: [target_name, twin_name]

                      Dragonex.Actions.LesserRestoration.prepare(
                        world,
                        caster_name,
                        targets,
                        condition_to_remove
                      )
                      |> consume_metamagic(caster_name, not is_nil(twin_name))

                    {"heal", twin_name} ->
                      targets =
                        if is_nil(twin_name), do: [target_name], else: [target_name, twin_name]

                      Dragonex.Actions.HealSpell.prepare(world, caster_name, targets, cast_level)
                      |> consume_metamagic(caster_name, not is_nil(twin_name))

                    {_, nil} ->
                      resolve_spell(
                        world,
                        c,
                        caster_name,
                        t,
                        target_name,
                        scaled,
                        roller,
                        roll_log
                      )

                    {_, twin_name} ->
                      resolve_twinned(
                        world,
                        c,
                        caster_name,
                        target_name,
                        twin_name,
                        scaled,
                        roller,
                        roll_log
                      )
                  end

                result
                |> compose_slot_consumption(caster_name, cast_level)
                |> compose_concentration(caster_name, spell)
                |> tag_upcast_level(caster_name, spell, cast_level)
              end
            end
        end
    end
  end

  # D74: validate the requested cast level against the spell's base. nil →
  # base (backwards compat). Cantrips never upcast (they cost no slot). All
  # errors leave the world untouched.
  defp validate_spell_targets(world, %{name: "bless"}, target, additional, level) do
    if is_nil(additional) or is_list(additional),
      do: World.validate_bless_targets(world, [target | additional || []], level),
      else: {:error, dgettext("engine", "additional_targets debe ser una lista de nombres")}
  end

  defp validate_spell_targets(_world, _spell, _target, additional, _level) do
    if additional in [nil, []],
      do: :ok,
      else: {:error, dgettext("engine", "additional_targets solo está disponible para Bless")}
  end

  defp validate_healing_target(spell, target) do
    healing? =
      spell.kind == :automatic and spell.damage_type == nil and
        spell.dice != nil and not false_life?(spell)

    if healing? and target.death_saves.fails >= 3,
      do:
        {:error,
         dgettext("engine", "%{target} está muerto; la curación no resucita", target: target.name)},
      else: :ok
  end

  defp validate_self_spell_target(spell, caster, target) do
    cond do
      false_life?(spell) and caster != target ->
        {:error,
         dgettext("engine", "False Life solo puede tener como objetivo al propio lanzador")}

      shield_spell?(spell) and caster != target ->
        {:error, dgettext("engine", "Shield solo puede tener como objetivo al propio lanzador")}

      true ->
        :ok
    end
  end

  defp validate_condition_selection(%{name: "lesser restoration"}, _), do: :ok
  defp validate_condition_selection(_, nil), do: :ok

  defp validate_condition_selection(_, _),
    do:
      {:error,
       dgettext(
         "engine",
         "condition_to_remove solo está disponible para Lesser Restoration; para este hechizo omite el parámetro o envía null"
       )}

  defp validate_cast_level(%{level: 0}, nil), do: {:ok, 0}

  defp validate_cast_level(%{level: 0}, cast_level)
       when is_integer(cast_level) and cast_level >= 1,
       do:
         {:error, dgettext("engine", "los trucos (nivel 0) no se pueden lanzar a nivel superior")}

  defp validate_cast_level(%{level: base}, nil) when base > 0, do: {:ok, base}

  defp validate_cast_level(%{level: base}, cast_level) do
    cond do
      not is_integer(cast_level) ->
        {:error,
         dgettext(
           "engine",
           "nivel de lanzamiento inválido (cast_level): %{level} — debe ser un entero entre %{base} y 9",
           level: inspect(cast_level),
           base: base
         )}

      cast_level < base ->
        {:error,
         dgettext(
           "engine",
           "no se puede lanzar a nivel %{level}: el nivel mínimo de este hechizo es %{base}",
           level: cast_level,
           base: base
         )}

      cast_level > 9 ->
        {:error,
         dgettext("engine", "nivel de lanzamiento inválido: %{level} (máximo 9)",
           level: cast_level
         )}

      true ->
        {:ok, cast_level}
    end
  end

  # D74: "X conjura Y (nivel N); …" — one tag right after the spell name,
  # covering every resolution branch (save/attack/automatic/heal/utility and
  # the Twinned outer message).
  defp tag_upcast_level({:ok, msg, change}, caster_name, spell, cast_level)
       when is_integer(cast_level) and cast_level > 0 and cast_level > spell.level do
    prefix =
      dgettext("engine", "%{caster} conjura %{spell}",
        caster: caster_name,
        spell: Terms.spell(spell.name)
      )

    tag = dgettext("engine", " (nivel %{level})", level: cast_level)
    {:ok, String.replace_prefix(msg, prefix, prefix <> tag), change}
  end

  defp tag_upcast_level(result, _caster_name, _spell, _cast_level), do: result

  # Wrap a spell result's change_fn to also consume a spell slot.
  # Cantrips (level 0) pass through unchanged.
  defp compose_slot_consumption({:ok, msg, change}, caster, spell_level) when spell_level > 0 do
    combined = fn w ->
      case change.(w) do
        {:ok, w2} -> World.consume_slot(caster, spell_level).(w2)
        error -> error
      end
    end

    {:ok, msg, combined}
  end

  defp compose_slot_consumption(result, _, _), do: result

  @doc """
  Roll initiative for every conscious combatant (hp > 0), highest total first,
  and produce a `begin_combat` change. Ties break by DEX score desc, then name
  asc (D39). 5e would then roll off — skipped so fixed rollers stay deterministic.
  The committed roster and DEX scores must still match those that were rolled;
  concurrent spawns or departures cannot leave creatures out of initiative.
  """
  @spec initiative(World.t(), roller(), RollLog.t() | nil) :: result()
  def initiative(world, roller, roll_log \\ nil) do
    roster = initiative_roster(world)

    # 19451/33–40: initiative rolled before the narrated rats had sheets opened a
    # fight with no foe, and the creatures later joined last without a roll.
    if Enum.any?(roster, fn {_name, c} -> c.side == "enemy" end),
      do: roll_initiative(world, roster, roller, roll_log),
      else:
        {:error,
         dgettext(
           "engine",
           "No hay criaturas hostiles registradas en la escena: regístralas primero con spawn_monster y después pide iniciativa."
         )}
  end

  defp roll_initiative(_world, roster, roller, roll_log) do
    rolled_roster = Enum.map(roster, fn {name, c} -> {name, c.dex} end)

    ordered =
      roster
      |> Enum.map(fn {name, c} ->
        {r, close} =
          RollLog.open(
            roll_log,
            roller,
            name,
            :initiative,
            dgettext("engine", "tirada de iniciativa")
          )

        rolled = Combat.roll_initiative(c, r)
        {_d20, total} = rolled
        RollLog.close(close, total: total, against: nil, outcome: nil)
        {name, rolled, c.dex}
      end)
      |> Enum.sort_by(fn {name, {_d20, total}, dex} -> {-total, -dex, name} end)

    summary =
      Enum.map_join(ordered, ", ", fn {name, {d20, total}, _dex} -> "#{name} #{d20}→#{total}" end)

    names = Enum.map(ordered, &elem(&1, 0))

    change = fn committed ->
      current_roster =
        committed |> initiative_roster() |> Enum.map(fn {name, c} -> {name, c.dex} end)

      if current_roster == rolled_roster,
        do: World.begin_combat(names).(committed),
        else:
          {:error,
           dgettext(
             "engine",
             "La lista de combatientes o su Destreza cambió después de preparar la iniciativa. Vuelve a pedir iniciativa con el estado actual; esta tirada no se aplicó."
           )}
    end

    {:ok, dgettext("engine", "Iniciativa — %{summary}.", summary: summary), change}
  end

  defp initiative_roster(world) do
    world
    |> World.present_characters()
    |> Enum.filter(fn {_, %Character{hp: hp}} -> hp > 0 end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  @doc "Make a death saving throw for a down character and apply the result."
  @spec death_save(World.t(), String.t(), roller(), RollLog.t() | nil) :: result()
  def death_save(world, name, roller, roll_log \\ nil) do
    with :ok <- Dragonex.TurnBudget.check(world, name, :death_save),
         do: do_death_save(world, name, roller, roll_log)
  end

  defp do_death_save(world, name, roller, roll_log) do
    case World.present_character(world, name) do
      nil ->
        {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

      %Character{hp: hp} when hp > 0 ->
        {:error, dgettext("engine", "%{name} no está caído (pg %{hp})", name: name, hp: hp)}

      %Character{death_saves: %{fails: fails}} when fails >= 3 ->
        {:error,
         dgettext(
           "engine",
           "%{name} ya está muerto (3 fallos de salvación de muerte) — no puede tirar más salvaciones",
           name: name
         )}

      %Character{death_saves: %{successes: successes}} when successes >= 3 ->
        {:error,
         dgettext(
           "engine",
           "%{name} ya está estable (3 salvaciones de muerte) — no necesita tirar más salvaciones",
           name: name
         )}

      %Character{} = c ->
        inspired? = c.inspired == true
        # D61 Aura of Protection applies to death saves (RAW).
        aura = aura_save_bonus(world, name)

        {r, close} =
          RollLog.open(
            roll_log,
            roller,
            name,
            :death_save,
            dgettext("engine", "salvación de muerte")
          )

        d20 = r.(20)
        bless = Effects.bless_bonus(c, r)
        result = Combat.death_save(fn _ -> d20 end, aura + bless)
        {result, bardic} = apply_inspired_death(c, result, r, aura + bless)

        RollLog.close(close,
          total: elem(result, 1) + aura + bless + bardic,
          against: {:dc, 10},
          outcome: elem(result, 0)
        )

        change = compose_inspired_clear(name, inspired?, World.apply_death_save(name, result))

        {:ok,
         describe_death_save(name, result, bardic, aura) <> lucky_suffix(Effects.tag(nil, bless)),
         fn current ->
           with :ok <- unchanged_turn(world, current),
                :ok <- unchanged_resources(world, current, name),
                do: change.(current)
         end}
    end
  end

  @doc """
  Heal a character by a dice expression (e.g. "1d8+3"), capped at max_hp.
  Healing also clears the death-save tracker (reviving a downed character).
  """
  @spec heal(World.t(), String.t(), String.t(), roller(), RollLog.t() | nil) :: result()
  def heal(world, target, dice_expr, roller, roll_log \\ nil) do
    # Entradas inválidas (auditoría 7): el DM/LLM envía strings libres
    # ("2d", "d6", "1d8+abc", "5", "") — sin esta guarda Dice.parse_expr
    # crasheaba con ArgumentError en vez de devolver un error accionable.
    cond do
      not is_binary(dice_expr) or not Dice.valid?(dice_expr) ->
        {:error,
         dgettext(
           "engine",
           "expresión de dados inválida: %{dice} — usa NdM o NdM±K (p. ej. \"1d8+3\")",
           dice: inspect(dice_expr)
         )}

      true ->
        do_heal(world, target, dice_expr, roller, roll_log)
    end
  end

  defp do_heal(world, target, dice_expr, roller, roll_log) do
    case World.present_character(world, target) do
      nil ->
        {:error, dgettext("engine", "no existe el personaje: %{target}", target: target)}

      %Character{death_saves: %{fails: fails}} when fails >= 3 ->
        {:error,
         dgettext("engine", "%{target} está muerto; la curación no resucita", target: target)}

      %Character{hp: hp, max_hp: max_hp} ->
        {r, close} =
          RollLog.open(
            roll_log,
            roller,
            target,
            :heal,
            dgettext("engine", "curación (%{dice})", dice: dice_expr)
          )

        rolled = max(0, Dice.roll_expr(dice_expr, r))
        RollLog.close(close, total: rolled, against: nil, outcome: nil)
        applied = min(rolled, max_hp - hp)

        {:ok,
         dgettext("engine", "%{target} se cura %{amount} pg (%{hp} → %{new_hp}).",
           target: target,
           amount: applied,
           hp: hp,
           new_hp: hp + applied
         ), World.heal(target, rolled)}
    end
  end

  @doc """
  Second Wind (5e, D45): a fighter heals 1d10 + level, once until a rest.

  Capped at max_hp; same heal path (clears death saves if hp > 0). Does not
  touch temp_hp.
  """
  @spec second_wind(World.t(), String.t(), roller(), RollLog.t() | nil) :: result()
  def second_wind(world, who, roller, roll_log \\ nil) do
    with_actor(
      world,
      who,
      fn -> do_second_wind(world, who, roller, roll_log) end,
      {:delegated, :bonus}
    )
  end

  defp do_second_wind(world, who, roller, roll_log) do
    case World.present_character(world, who) do
      nil ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      %Character{class: class} when class != "fighter" ->
        {:error,
         dgettext("engine", "%{actor} no es guerrero y no puede usar Segundo aliento", actor: who)}

      %Character{second_wind_used: true} ->
        {:error,
         dgettext("engine", "%{actor} ya ha usado Segundo aliento (se recarga con un descanso)",
           actor: who
         )}

      %Character{hp: hp, max_hp: max_hp, level: level} ->
        hp = hp || 0
        max_hp = max_hp || 0
        level = level || 1

        {r, close} =
          RollLog.open(
            roll_log,
            roller,
            who,
            :heal,
            dgettext("engine", "Segundo aliento (1d10+%{level})", level: level)
          )

        rolled = r.(10) + level
        RollLog.close(close, total: rolled, against: nil, outcome: nil)
        applied = min(rolled, max(0, max_hp - hp))

        {:ok,
         dgettext(
           "engine",
           "%{actor} usa Segundo aliento y se cura %{amount} pg (1d10+%{level} = %{total}, ahora %{new_hp}/%{max_hp}).",
           actor: who,
           amount: applied,
           level: level,
           total: rolled,
           new_hp: hp + applied,
           max_hp: max_hp
         ), World.second_wind(who, rolled)}
    end
  end

  @doc """
  Lay on Hands (5e, D49): a paladin spends pool points to heal `target`.

  `applied = min(amount, remaining_pool, max(0, target.max_hp - target.hp))`.
  Spends `applied`, not the requested amount. Capped at max_hp; same heal
  path (clears death saves if hp > 0). Does not touch temp_hp.
  """
  @spec lay_on_hands(World.t(), String.t(), String.t(), term(), [String.t()] | nil) :: result()
  def lay_on_hands(world, who, target, amount, conditions_to_remove \\ nil) do
    purify? = conditions_to_remove not in [nil, []]

    with_actor(
      world,
      who,
      fn ->
        if purify?,
          do:
            Dragonex.Actions.LayOnHandsPurify.prepare(
              world,
              who,
              target,
              amount,
              conditions_to_remove
            ),
          else: do_lay_on_hands(world, who, target, amount)
      end,
      if(purify?, do: :action, else: {:delegated, :action})
    )
  end

  defp do_lay_on_hands(world, who, target, amount) do
    case World.present_character(world, who) do
      nil ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      %Character{} ->
        case World.present_character(world, target) do
          nil ->
            {:error, dgettext("engine", "no existe el personaje: %{target}", target: target)}

          %Character{death_saves: %{fails: fails}} when fails >= 3 ->
            {:error,
             dgettext("engine", "%{target} está muerto; la curación no resucita", target: target)}

          %Character{} = tgt ->
            lay_on_hands_apply(world, who, target, amount, tgt)
        end
    end
  end

  defp lay_on_hands_apply(world, who, target, amount, tgt) do
    case World.present_character(world, who) do
      %Character{class: class} when class != "paladin" ->
        {:error,
         dgettext("engine", "%{actor} no es paladín y no puede usar Manos impositoras",
           actor: who
         )}

      %Character{lay_on_hands_pool: pool} ->
        pool = pool || 0

        cond do
          not is_integer(amount) or amount < 1 ->
            {:error,
             dgettext("engine", "la cantidad de Manos impositoras debe ser un entero ≥ 1")}

          pool == 0 ->
            {:error,
             dgettext("engine", "%{actor} no tiene puntos de Manos impositoras", actor: who)}

          amount > pool ->
            {:error,
             dgettext(
               "engine",
               "%{actor} no tiene suficientes puntos de Manos impositoras (pide %{amount}, quedan %{pool})",
               actor: who,
               amount: amount,
               pool: pool
             )}

          lay_on_hands_blocked_race?(tgt.race) ->
            {:error,
             dgettext(
               "engine",
               "%{target} no puede recibir Manos impositoras (no-muerto o constructo)",
               target: target
             )}

          true ->
            hp = tgt.hp || 0
            max_hp = tgt.max_hp || 0
            applied = min(amount, min(pool, max(0, max_hp - hp)))

            if applied == 0 do
              {:error,
               dgettext("engine", "%{target} ya está a tope de puntos de golpe", target: target)}
            else
              remaining = pool - applied

              {:ok,
               dgettext(
                 "engine",
                 "%{actor} usa Manos impositoras en %{target} y cura %{amount} pg (ahora %{new_hp}/%{max_hp}, pool %{remaining}).",
                 actor: who,
                 target: target,
                 amount: applied,
                 new_hp: hp + applied,
                 max_hp: max_hp,
                 remaining: remaining
               ), World.lay_on_hands(who, target, applied)}
            end
        end
    end
  end

  defp lay_on_hands_blocked_race?(race) when is_binary(race) do
    String.downcase(race) in ["undead", "construct"]
  end

  defp lay_on_hands_blocked_race?(_), do: false

  @divine_sense_races ~w(celestial fiend undead)

  @doc """
  Divine Sense (5e, D52): a paladin spends 1 use and the engine reports
  every other character whose `race` is celestial, fiend or undead.
  Allowed in combat. Spends even if the scan is empty. The LLM does not
  list types.
  """
  @spec divine_sense(World.t(), String.t()) :: result()
  def divine_sense(world, who) do
    with_actor(world, who, fn -> do_divine_sense(world, who) end, :action)
  end

  defp do_divine_sense(world, who) do
    case World.present_character(world, who) do
      nil ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      %Character{class: class} when class != "paladin" ->
        {:error,
         dgettext("engine", "%{actor} no es paladín y no puede usar Sentido divino", actor: who)}

      %Character{divine_sense_uses: uses} ->
        uses = uses || 0

        if uses < 1 do
          {:error, dgettext("engine", "%{actor} no tiene usos de Sentido divino", actor: who)}
        else
          remaining = uses - 1
          detected = divine_sense_targets(world, who)

          {:ok, divine_sense_message(who, detected, remaining), World.spend_divine_sense(who)}
        end
    end
  end

  defp divine_sense_targets(%World{} = world, who) do
    World.present_characters(world)
    |> Enum.reject(fn {name, _} -> name == who end)
    |> Enum.map(fn {_name, c} -> c end)
    |> Enum.filter(&divine_sense_race?(&1.race))
    |> Enum.sort_by(& &1.name)
  end

  defp divine_sense_race?(race) when is_binary(race) do
    String.downcase(race) in @divine_sense_races
  end

  defp divine_sense_race?(_), do: false

  defp divine_sense_label(race) when is_binary(race) do
    case String.downcase(race) do
      "celestial" -> dgettext("engine", "celestial")
      "fiend" -> dgettext("engine", "infernal")
      "undead" -> dgettext("engine", "no-muerto")
      other -> other
    end
  end

  defp divine_sense_message(who, [], remaining) do
    dgettext(
      "engine",
      "%{actor} usa Sentido divino y no percibe celestiales, infernales ni no-muertos (usos restantes %{remaining}).",
      actor: who,
      remaining: remaining
    )
  end

  defp divine_sense_message(who, detected, remaining) do
    listed =
      detected
      |> Enum.map(fn c -> "#{c.name} (#{divine_sense_label(c.race)})" end)
      |> Enum.join(", ")

    dgettext(
      "engine",
      "%{actor} usa Sentido divino y percibe: %{detected} (usos restantes %{remaining}).",
      actor: who,
      detected: listed,
      remaining: remaining
    )
  end

  @doc """
  Turn Undead (5e, D53): a cleric level 2+ spends Channel Divinity.

  Other living undead (`race` downcase `"undead"`, hp > 0) roll a Wisdom
  save vs DC `8 + proficiency + cleric Wisdom modifier`. Failure applies
  frightened (M06). Spends even if there are no targets. Combat allowed.
  Aura of Protection (D61) adds to the save; Aura of Courage (D62) makes
  a target sharing a side with a conscious paladin L10+ immune (the message
  reports it; no condition lands).
  """
  @spec turn_undead(World.t(), String.t(), roller(), RollLog.t() | nil) :: result()
  def turn_undead(world, who, roller, roll_log \\ nil) do
    with_actor(world, who, fn -> do_turn_undead(world, who, roller, roll_log) end, :action)
  end

  defp do_turn_undead(world, who, roller, roll_log) do
    case World.present_character(world, who) do
      nil ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      %Character{class: class} when class != "cleric" ->
        {:error,
         dgettext("engine", "%{actor} no es clérigo y no puede usar Expulsar no-muertos",
           actor: who
         )}

      %Character{level: level} when not is_integer(level) or level < 2 ->
        {:error,
         dgettext("engine", "%{actor} no tiene Expulsar no-muertos (nivel 2)", actor: who)}

      %Character{channel_divinity_used: true} ->
        {:error,
         dgettext(
           "engine",
           "%{actor} ya ha usado Canalizar divinidad (se recarga con un descanso)",
           actor: who
         )}

      %Character{} = cleric ->
        dc = 8 + Ability.proficiency(cleric.level) + Character.modifier(cleric, :wis)
        {failed, saved, immune} = turn_undead_resolutions(world, who, dc, roller, roll_log)

        {:ok, turn_undead_message(who, dc, failed, saved, immune),
         compose_turn_undead(who, failed, saved)}
    end
  end

  defp turn_undead_resolutions(world, who, dc, roller, roll_log) do
    world
    |> turn_undead_targets(who)
    |> Enum.reduce({[], [], []}, fn target, {failed, saved, immune} ->
      cond do
        # D62 Aura of Courage: a same-side ally of a conscious paladin L10+
        # can't be frightened — no save needed (nothing would land).
        World.courage_immune?(world, target.name) ->
          {failed, saved, immune ++ [target.name]}

        true ->
          # D68: {saved?, indomitable_tag} — the tag rides the entry so the
          # clause renders the reroll and compose marks the spent flag.
          {success?, indom} = turn_undead_save_success?(world, target, dc, roller, roll_log)
          entry = {target.name, indom}

          if success? do
            {failed, saved ++ [entry], immune}
          else
            {failed ++ [entry], saved, immune}
          end
      end
    end)
  end

  defp turn_undead_targets(%World{} = world, who) do
    World.present_characters(world)
    |> Enum.reject(fn {name, _} -> name == who end)
    |> Enum.map(fn {_name, c} -> c end)
    |> Enum.filter(&turn_undead_target?/1)
    |> Enum.sort_by(& &1.name)
  end

  defp turn_undead_target?(%Character{hp: hp, race: race})
       when is_integer(hp) and hp > 0 and is_binary(race) do
    String.downcase(race) == "undead"
  end

  defp turn_undead_target?(_), do: false

  defp turn_undead_save_success?(world, target, dc, roller, roll_log) do
    # D71 Gnome Cunning: divine magic counts (ADR D71). Today no turn_undead
    # target can be a gnome (race must be "undead"), but the contract holds.
    case Conditions.save_mode(target, :wis, :normal,
           gnome_advantage: gnome_cunning?(target, :wis)
         ) do
      # No die was rolled — Indomitable (D68) never rerolls an auto-fail.
      :auto_fail ->
        {false, nil}

      {:roll, save_mode} ->
        {r, close} =
          RollLog.open(
            roll_log,
            roller,
            target.name,
            :save,
            dgettext("engine", "salvación de Sabiduría contra Expulsar no-muertos")
          )

        {_d20, total, _success?} = Combat.saving_throw(target, :wis, dc, r, save_mode)
        # D61 Aura of Protection: covers this Wisdom save too.
        aura = aura_save_bonus(world, target.name)
        total = total + aura

        # D68 Indomitable: a fighter L9+ undead rerolls a failed WIS save
        # once per long rest — the reroll decides (aura re-applies).
        {_d20_2, total, success?, indom} =
          maybe_indomitable(target, :wis, dc, r, save_mode, {nil, total, total >= dc}, aura)

        RollLog.close(close,
          total: total,
          against: {:dc, dc},
          outcome: if(success?, do: :success, else: :failure)
        )

        {success?, indom}
    end
  end

  defp turn_undead_message(who, dc, [], [], []) do
    dgettext(
      "engine",
      "%{actor} usa Expulsar no-muertos (CD %{dc}) y no hay no-muertos que Expulsar no-muertos pueda afectar (usos restantes 0).",
      actor: who,
      dc: dc
    )
  end

  defp turn_undead_message(who, dc, failed, saved, immune) do
    bits =
      [frightened_clause(failed), saved_clause(saved), immune_clause(immune)]
      |> Enum.reject(&is_nil/1)

    dgettext(
      "engine",
      "%{actor} usa Expulsar no-muertos (CD %{dc}): %{effects} (usos restantes 0).",
      actor: who,
      dc: dc,
      effects: Enum.join(bits, "; ")
    )
  end

  # Entries are {name, indomitable_tag} (D68): the tag renders next to the
  # name when the reroll fired ("X (Indomitable: 9→15)"), nothing otherwise.
  defp frightened_clause([]), do: nil

  defp frightened_clause([{name, tag}]),
    do:
      dgettext("engine", "%{name}%{indomitable} queda asustado",
        name: name,
        indomitable: indom_suffix(tag)
      )

  defp frightened_clause(entries) do
    dgettext("engine", "%{names} quedan asustados", names: turn_names(entries))
  end

  defp saved_clause([]), do: nil

  defp saved_clause([{name, tag}]),
    do:
      dgettext("engine", "%{name}%{indomitable} supera la salvación",
        name: name,
        indomitable: indom_suffix(tag)
      )

  defp saved_clause(entries),
    do: dgettext("engine", "%{names} superan la salvación", names: turn_names(entries))

  defp turn_names(entries),
    do: Enum.map_join(entries, ", ", fn {name, tag} -> "#{name}#{indom_suffix(tag)}" end)

  # D62: immunity is an outcome, not an error — the message says so.
  defp immune_clause([]), do: nil

  defp immune_clause([name]),
    do: dgettext("engine", "%{name} es inmune al miedo (Aura de Coraje)", name: name)

  defp immune_clause(names),
    do:
      dgettext("engine", "%{names} son inmunes al miedo (Aura de Coraje)",
        names: Enum.join(names, ", ")
      )

  defp compose_turn_undead(who, failed, saved) do
    # D68: every target whose Indomitable reroll fired (saved OR frightened)
    # spends the flag.
    rerolled = for {name, tag} <- failed ++ saved, tag != nil, do: name

    fn w ->
      with {:ok, w} <- World.set_channel_divinity_used(who, true).(w),
           {:ok, w} <- mark_indomitable_all(w, rerolled) do
        Enum.reduce_while(failed, {:ok, w}, fn {name, _tag}, {:ok, acc} ->
          case World.apply_condition(name, "frightened", 60).(acc) do
            {:ok, w2} -> {:cont, {:ok, w2}}
            err -> {:halt, err}
          end
        end)
      end
    end
  end

  defp mark_indomitable_all(w, []), do: {:ok, w}

  defp mark_indomitable_all(w, [name | rest]) do
    case World.set_indomitable(name, true).(w) do
      {:ok, w2} -> mark_indomitable_all(w2, rest)
      error -> error
    end
  end

  @doc """
  Bardic Inspiration (5e, D50): a bard spends 1 use to grant `target` a
  pending d6 (`inspired = true`). The die is applied by the engine on the
  target's next attack/check/save/death save. Target may be another
  character or the bard. Does not stack or refresh.
  """
  @spec bardic_inspiration(World.t(), String.t(), String.t()) :: result()
  def bardic_inspiration(world, who, target) do
    with_actor(world, who, fn -> do_bardic_inspiration(world, who, target) end, :bonus)
  end

  defp do_bardic_inspiration(world, who, target) do
    case World.present_character(world, who) do
      nil ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      %Character{class: class} when class != "bard" ->
        {:error,
         dgettext("engine", "%{actor} no es bardo y no puede usar Inspiración bárdica",
           actor: who
         )}

      %Character{bardic_inspiration_uses: uses} ->
        uses = uses || 0

        case World.present_character(world, target) do
          nil ->
            {:error, dgettext("engine", "no existe el personaje: %{target}", target: target)}

          %Character{inspired: true} ->
            {:error, dgettext("engine", "%{target} ya está inspirado", target: target)}

          %Character{} when uses < 1 ->
            {:error,
             dgettext("engine", "%{actor} no tiene usos de Inspiración bárdica", actor: who)}

          %Character{} ->
            remaining = uses - 1

            {:ok,
             dgettext(
               "engine",
               "%{actor} inspira a %{target} (Inspiración bárdica d6, usos restantes %{remaining}).",
               actor: who,
               target: target,
               remaining: remaining
             ), World.spend_bardic(who, target)}
        end
    end
  end

  @doc """
  Arcane Recovery (5e, D51): a wizard restores expended spell slots
  outside combat, once until a long rest. Budget `div(level + 1, 2)`.
  No slot above 5th. Greedy highest-to-lowest. The LLM does not pick slots.
  """
  @spec arcane_recovery(World.t(), String.t()) :: result()
  def arcane_recovery(world, who) do
    with_actor(world, who, fn -> do_arcane_recovery(world, who) end)
  end

  defp do_arcane_recovery(world, who) do
    case World.present_character(world, who) do
      nil ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      %Character{} when world.phase == :combat ->
        {:error, dgettext("engine", "no se puede usar Recuperación arcana en combate")}

      %Character{class: class} when class != "wizard" ->
        {:error,
         dgettext("engine", "%{actor} no es mago y no puede usar Recuperación arcana", actor: who)}

      %Character{arcane_recovery_used: true} ->
        {:error,
         dgettext(
           "engine",
           "%{actor} ya ha usado Recuperación arcana (se recarga con un descanso largo)",
           actor: who
         )}

      %Character{} ->
        case World.arcane_recovery_plan(world, who) do
          {:error, reason} ->
            {:error, reason}

          {:ok, new_slots, restored} ->
            {:ok, arcane_recovery_message(who, restored),
             World.apply_arcane_recovery(who, new_slots)}
        end
    end
  end

  defp arcane_recovery_message(who, restored) do
    dgettext("engine", "%{actor} usa Recuperación arcana y recupera %{slots}.",
      actor: who,
      slots: format_restored_slots(restored)
    )
  end

  defp format_restored_slots(restored) do
    items =
      restored
      |> Enum.sort_by(fn {level, _} -> -level end)
      |> Enum.with_index()
      |> Enum.map(fn {{level, n}, i} -> slot_fragment(n, level, i == 0) end)

    case items do
      [only] ->
        only

      [first, last] ->
        dgettext("engine", "%{first} y %{last}", first: first, last: last)

      [first | rest] ->
        {last, mids} = List.pop_at(rest, -1)

        dgettext("engine", "%{first}, %{middle} y %{last}",
          first: first,
          middle: Enum.join(mids, ", "),
          last: last
        )
    end
  end

  defp slot_fragment(n, level, true) do
    dngettext(
      "engine",
      "%{count} hueco de nivel %{level}",
      "%{count} huecos de nivel %{level}",
      n,
      level: level
    )
  end

  defp slot_fragment(n, level, false),
    do: dgettext("engine", "%{n} de nivel %{level}", n: n, level: level)

  @doc """
  Wild Shape (5e, D63): a druid of level 2+ transforms into a beast from
  `Monsters.wild_shape_beasts/0`, spending 1 use (2 per rest).

  CR gate: L2–3 → max ND 1/4 (cat, wolf); L4+ → max ND 1/2 (all). The
  engine saves the druid's original form and applies the beast's
  str/dex/con/hp/max_hp/ac/weapons — mental scores, identity, proficiencies,
  conditions and concentration are kept (RAW). Errors (no mutation): missing
  who, downed, not a druid, L1, already transformed, unknown beast, CR above
  the level gate, 0 uses.
  """
  @spec wild_shape(World.t(), String.t(), String.t()) :: result()
  def wild_shape(world, who, beast_key) do
    with_actor(world, who, fn -> do_wild_shape(world, who, beast_key) end, :action)
  end

  defp do_wild_shape(world, who, beast_key) do
    beasts = Dragonex.Monsters.wild_shape_beasts()

    case World.present_character(world, who) do
      nil ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      %Character{hp: hp} when hp <= 0 ->
        {:error,
         dgettext("engine", "%{actor} está caído (0 pg) y no puede transformarse", actor: who)}

      %Character{class: class} when class != "druid" ->
        {:error,
         dgettext("engine", "%{actor} no es druida y no puede usar Forma salvaje", actor: who)}

      %Character{level: level} when not is_integer(level) or level < 2 ->
        {:error, dgettext("engine", "%{actor} no tiene Forma salvaje (nivel 2)", actor: who)}

      %Character{wild_shape: ws} when ws != nil ->
        {:error, dgettext("engine", "%{actor} ya está en forma de bestia", actor: who)}

      %Character{wild_shape_uses: uses} = c ->
        uses = uses || 0
        cr = Map.get(beasts, beast_key)
        max = wild_shape_max_cr(c.level)

        cond do
          is_nil(cr) ->
            {:error,
             dgettext("engine", "bestia desconocida: %{beast} (disponibles: %{options})",
               beast: beast_key,
               options: Enum.join(Enum.sort(Map.keys(beasts)), ", ")
             )}

          cr > max ->
            {:error,
             dgettext(
               "engine",
               "%{actor} no puede adoptar la forma de %{beast} (ND %{cr}) a nivel %{level} (máximo ND %{max_cr})",
               actor: who,
               beast: beast_key,
               cr: cr,
               level: c.level,
               max_cr: max
             )}

          uses < 1 ->
            {:error,
             dgettext(
               "engine",
               "%{actor} no tiene usos de Forma salvaje (se recargan con un descanso)",
               actor: who
             )}

          true ->
            beast = Dragonex.Monsters.get(beast_key).(name: who)
            name_es = WildShape.beast_name(beast_key)

            {:ok,
             dgettext(
               "engine",
               "%{actor} adopta la forma de un %{beast} (usos de forma salvaje restantes: %{remaining}).",
               actor: who,
               beast: name_es,
               remaining: uses - 1
             ), World.transform_wild_shape(who, beast_key, beast)}
        end
    end
  end

  @doc """
  End Wild Shape (5e, D63): the transformed druid returns to their original
  form with its saved hit points, including native Constitution vitality
  gained while transformed (D129). Errors (no
  mutation): missing who, not transformed. Everything else (attack with the
  beast weapons, ability checks, rests) works normally while transformed;
  only `cast_spell` is blocked.
  """
  @spec end_wild_shape(World.t(), String.t()) :: result()
  def end_wild_shape(world, who) do
    with_actor(world, who, fn -> do_end_wild_shape(world, who) end, :bonus)
  end

  defp do_end_wild_shape(world, who) do
    case World.present_character(world, who) do
      nil ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      %Character{wild_shape: nil} ->
        {:error, dgettext("engine", "%{actor} no está en forma de bestia", actor: who)}

      %Character{wild_shape: %{} = ws} ->
        {:ok,
         dgettext("engine", "%{actor} vuelve a su forma original (PG %{hp}).",
           actor: who,
           hp: ws[:orig_hp]
         ), World.revert_wild_shape(who)}
    end
  end

  # CR gate (D63, RAW): L2–4 → máx 1/4; L5+ → máx 1/2.
  defp wild_shape_max_cr(level) when is_integer(level) and level >= 5, do: 0.5
  defp wild_shape_max_cr(_), do: 0.25

  @doc """
  Action Surge (5e, D47): a fighter of level 2+ takes one extra Attack
  action (N swings via Extra Attack D35), once until a rest.

  The tool IS the extra action (simplified action economy). Hit or miss
  marks the use; errors (missing, 0 hp, no weapon, not fighter, L1,
  already used) do not.
  """
  @spec action_surge(
          World.t(),
          String.t(),
          String.t(),
          String.t(),
          roller(),
          :normal | :advantage | :disadvantage,
          RollLog.t() | nil
        ) :: result()
  def action_surge(world, who, target, weapon_name, roller, mode \\ :normal, roll_log \\ nil) do
    with_actor(
      world,
      who,
      fn ->
        do_action_surge(world, who, target, weapon_name, roller, mode, roll_log)
      end,
      :surge
    )
  end

  defp do_action_surge(world, who, target, weapon_name, roller, mode, roll_log) do
    case World.present_character(world, who) do
      nil ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      %Character{class: class} when class != "fighter" ->
        {:error,
         dgettext("engine", "%{actor} no es guerrero y no puede usar Oleada de acción",
           actor: who
         )}

      %Character{level: level} when not is_integer(level) or level < 2 ->
        {:error, dgettext("engine", "%{actor} no tiene Oleada de acción (nivel 2)", actor: who)}

      %Character{action_surge_used: true} ->
        {:error,
         dgettext("engine", "%{actor} ya ha usado Oleada de acción (se recarga con un descanso)",
           actor: who
         )}

      %Character{} ->
        case do_attack(world, who, target, weapon_name, roller, mode, roll_log) do
          {:ok, msg, change} ->
            {:ok,
             dgettext("engine", "%{actor} usa Oleada de acción. %{result}",
               actor: who,
               result: msg
             ), compose_mark_action_surge(who, change)}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Flurry of Blows (5e, D54): a monk of level 2+ spends 1 ki point and makes
  two unarmed strikes (martial arts die, DEX) against `target`.

  The tool IS the bonus action (simplified action economy); no prior attack
  required. N is fixed at 2 — never `Progression.attack_count/2` — and no
  Sneak Attack, Divine Smite or Extra Attack stacking. The unarmed strike is
  a synthetic weapon: not required in inventory. Hit or miss spends the ki;
  errors (missing who/target, 0 hp, not a monk, L1, 0 ki) do not. If the
  target drops (hp ≤ 0) mid-flurry, the second swing is skipped.
  """
  @spec flurry_of_blows(
          World.t(),
          String.t(),
          String.t(),
          roller(),
          :normal | :advantage | :disadvantage,
          RollLog.t() | nil
        ) :: result()
  def flurry_of_blows(world, who, target, roller, mode \\ :normal, roll_log \\ nil) do
    with_actor(
      world,
      who,
      fn ->
        do_flurry_of_blows(world, who, target, roller, mode, roll_log)
      end,
      :flurry
    )
  end

  defp do_flurry_of_blows(world, who, target, roller, mode, roll_log) do
    monk = World.present_character(world, who)

    cond do
      is_nil(monk) ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      is_nil(World.present_character(world, target)) ->
        {:error, dgettext("engine", "no existe el objetivo: %{target}", target: target)}

      (monk.hp || 0) <= 0 ->
        {:error, dgettext("engine", "%{actor} está caído (0 pg) y no puede atacar", actor: who)}

      monk.class != "monk" ->
        {:error,
         dgettext("engine", "%{actor} no es monje y no puede usar Ráfaga de golpes", actor: who)}

      not is_integer(monk.level) or monk.level < 2 ->
        {:error, dgettext("engine", "%{actor} no tiene Ráfaga de golpes (nivel 2)", actor: who)}

      (monk.ki || 0) < 1 ->
        {:error,
         dgettext("engine", "%{actor} no tiene ki (se recarga con un descanso)", actor: who)}

      true ->
        t = World.present_character(world, target)
        weapon = unarmed_strike(monk.level)
        inspired? = monk.inspired == true
        # D61: the target's concentration saves ride this aura.
        aura = aura_save_bonus(world, target)

        attack_opts = [requested: mode, ranged: false, attack_ability: :dex, finesse: true]
        effective_mode = Conditions.attack_mode(monk, t, attack_opts)

        # D95 Guiding Bolt: mismo criterio que do_attack — ventaja solo al
        # primer golpe, consumo acierte o falle.
        guided? = Guided.active?(world, t)

        first_mode =
          if(guided?,
            do: Conditions.attack_mode(monk, t, Keyword.put(attack_opts, :guided, true)),
            else: nil
          )

        # N=2 fijo (D54): sin sneak, sin smite, sin Extra Attack, sin marca (D55).
        swings =
          resolve_swings(
            monk,
            t,
            who,
            target,
            weapon,
            roller,
            roll_log,
            effective_mode,
            first_mode,
            2,
            nil,
            nil,
            inspired?,
            false,
            aura
          )

        ac = target_ac(t)

        {notes, change} =
          pipe_attack_damage(target, swings, roller, roll_log, t, weapon.damage_type, aura)

        change = compose_inspired_clear(who, inspired?, change)
        change = consume_guided_change(target, guided?, change)

        {:ok,
         append_notes(
           dgettext(
             "engine",
             "%{actor} usa Ráfaga de golpes (ki restantes %{remaining}). %{attack}",
             actor: who,
             remaining: (monk.ki || 0) - 1,
             attack:
               format_attack_message(
                 who,
                 target,
                 weapon,
                 ac,
                 first_mode || effective_mode,
                 swings
               )
           ),
           notes
         ), compose_spend_ki(who, change)}
        |> guard_target_defense(world, target, :attack)
    end
  end

  defp unarmed_strike(level) do
    %Weapon{
      name: "unarmed strike",
      dice: Progression.martial_arts_die(level || 1),
      damage_type: "bludgeoning",
      attack_ability: :dex,
      finesse: true,
      ranged: false
    }
  end

  @doc """
  Hunter's Mark (5e, D55): a ranger of level 2+ spends a level-1 spell
  slot and marks `target` as prey, concentrating on the mark.

  While the concentration holds, `attack/6` adds +1d6 per weapon hit
  against that prey (crit doubles the mark dice; damage type is the
  weapon's). Spells and Flurry never benefit. The mark ends only through
  the existing concentration paths (`drop_concentration`, breaking
  conditions, rage, 0 hp) — nothing new. Errors spend no slot and never
  touch concentration.
  """
  @spec hunters_mark(World.t(), String.t(), String.t(), roller(), RollLog.t() | nil) ::
          result()
  def hunters_mark(world, who, target, _roller, _roll_log \\ nil) do
    with_actor(world, who, fn -> do_hunters_mark(world, who, target) end, :bonus)
  end

  defp do_hunters_mark(world, who, target) do
    hunter = World.present_character(world, who)

    cond do
      is_nil(hunter) ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      is_nil(World.present_character(world, target)) ->
        {:error, dgettext("engine", "no existe el objetivo: %{target}", target: target)}

      (hunter.hp || 0) <= 0 ->
        {:error,
         dgettext("engine", "%{actor} está caído (0 pg) y no puede marcar presa", actor: who)}

      hunter.class != "ranger" ->
        {:error,
         dgettext("engine", "%{actor} no es explorador y no puede usar Marca del cazador",
           actor: who
         )}

      not is_integer(hunter.level) or hunter.level < 2 ->
        {:error, dgettext("engine", "%{actor} no tiene Marca del cazador (nivel 2)", actor: who)}

      (World.present_character(world, target).hp || 0) <= 0 ->
        {:error,
         dgettext("engine", "%{target} está caído (0 pg) y no puede ser presa", target: target)}

      not World.has_slot?(world, who, 1) ->
        {:error,
         dgettext(
           "engine",
           "a %{actor} no le quedan casillas de hechizo de nivel 1 (debe descansar para recuperarlas).",
           actor: who
         )}

      not is_nil(hunter.concentrating) ->
        {:error,
         dgettext(
           "engine",
           "%{actor} ya concentra en %{effect} — debe soltar la concentración antes (drop_concentration)",
           actor: who,
           effect: hunter.concentrating
         )}

      true ->
        {:ok,
         dgettext(
           "engine",
           "%{actor} marca a %{target} como presa (Hunter's Mark, concentración, casilla nivel 1 gastada).",
           actor: who,
           target: target
         ),
         fn w ->
           with {:ok, w} <- World.consume_slot(who, 1).(w) do
             World.set_concentration(who, "hunter's mark:#{target}").(w)
           end
         end}
    end
  end

  @doc """
  Cunning Action: Hide (5e, D57): a rogue of level 2+ attempts to hide.

  The engine rolls the check — `1d20 + DEX mod (+ proficiency when "stealth"
  is in `skill_proficiencies`, DOUBLED with stealth Expertise D73)`, mode from
  `Conditions.check_mode/3` —
  against the highest passive perception among conscious enemies
  (`side != who.side`, hp > 0): `10 + WIS mod (+ proficiency when
  "perception" is trained)`. With no conscious enemy the DC is 10 (RAW
  minimum). Success applies the "hidden" condition (advantage on the
  rogue's attacks — and Sneak Attack, D41); attacking (hit or miss)
  reveals and removes it. Combat allowed (bonus action RAW; action
  economy out of scope). Errors do not mutate.
  """
  @spec cunning_action_hide(World.t(), String.t(), roller(), RollLog.t() | nil) :: result()
  def cunning_action_hide(world, who, roller, roll_log \\ nil) do
    with_actor(world, who, fn -> do_cunning_action_hide(world, who, roller, roll_log) end, :bonus)
  end

  defp do_cunning_action_hide(world, who, roller, roll_log) do
    rogue = World.present_character(world, who)

    cond do
      is_nil(rogue) ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      (rogue.hp || 0) <= 0 ->
        {:error,
         dgettext("engine", "%{actor} está caído (0 pg) y no puede esconderse", actor: who)}

      rogue.class != "rogue" ->
        {:error,
         dgettext("engine", "%{actor} no es pícaro y no puede usar Astucia de pícaro", actor: who)}

      not is_integer(rogue.level) or rogue.level < 2 ->
        {:error, dgettext("engine", "%{actor} no tiene Astucia de pícaro (nivel 2)", actor: who)}

      World.has_condition?(world, who, "hidden") ->
        {:error, dgettext("engine", "%{actor} ya está oculto", actor: who)}

      true ->
        hide_check(rogue, world, who, roller, roll_log)
    end
  end

  defp hide_check(%Character{} = rogue, world, who, roller, roll_log) do
    dc = hide_dc(world, rogue)
    stealth? = skill_trained?(rogue, "stealth")
    mode = Conditions.check_mode(rogue, :dex, :normal)

    {r, close} =
      RollLog.open(roll_log, roller, who, :check, dgettext("engine", "Sigilo para esconderse"))

    # D73: stealth expertise doubles the proficiency in this roll too.
    {d20, total, success?, lucky} =
      Combat.ability_check_tagged(rogue, :dex, dc, r, stealth?, mode, "stealth")

    RollLog.close(close,
      total: total,
      against: {:dc, dc},
      outcome: if(success?, do: :success, else: :failure)
    )

    dex_mod = Character.modifier(rogue, :dex)
    {prof, prof_kind} = Combat.check_proficiency(rogue, stealth?, "stealth")

    breakdown =
      ["1d20(#{d20})"]
      |> then(fn p -> if dex_mod != 0, do: p ++ ["#{signed(dex_mod)}"], else: p end)
      |> then(fn p ->
        cond do
          prof == 0 -> p
          prof_kind == :expert -> p ++ [dgettext("engine", "+%{bonus} (experto)", bonus: prof)]
          true -> p ++ ["+#{prof}"]
        end
      end)
      |> Enum.join("")

    verdict =
      if success?,
        do: dgettext("engine", "oculto"),
        else: dgettext("engine", "falla y sigue a la vista")

    {:ok,
     dgettext(
       "engine",
       "%{actor} se esconde: %{breakdown}=%{total} vs %{dc} — %{verdict}%{lucky}",
       actor: who,
       breakdown: breakdown,
       total: total,
       dc: dc,
       verdict: verdict,
       lucky: lucky_suffix(lucky)
     ), if(success?, do: World.apply_condition(who, "hidden"), else: noop())}
  end

  @doc """
  Uncanny Dodge (5e, D64): a rogue of level 5+ arms a defensive posture.

  Without reactions or rounds in the engine, this is modeled as a flag
  (pattern `inspired`/`reckless`): arming is free at any moment; the LLM
  decides WHEN. While armed, `World.apply_damage/3` halves ANY incoming
  damage (floor) at entry — before resistances (D38) and temp_hp (D36) —
  and consumes the flag. Stacks with Evasión (D59): half of half. Errors
  do not mutate.
  """
  @spec start_uncanny_dodge(World.t(), String.t()) :: result()
  def start_uncanny_dodge(world, who) do
    with_actor(world, who, fn -> do_start_uncanny_dodge(world, who) end, :reaction)
  end

  defp do_start_uncanny_dodge(world, who) do
    case World.present_character(world, who) do
      nil ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      %Character{hp: hp} when hp <= 0 ->
        {:error,
         dgettext("engine", "%{actor} está caído (0 pg) y no puede prepararse para esquivar",
           actor: who
         )}

      %Character{class: class} when class != "rogue" ->
        {:error,
         dgettext("engine", "%{actor} no es pícaro y no puede usar Esquiva asombrosa", actor: who)}

      %Character{level: level} when not is_integer(level) or level < 5 ->
        {:error, dgettext("engine", "%{actor} no tiene Esquiva asombrosa (nivel 5)", actor: who)}

      %Character{uncanny_dodge: true} ->
        {:error, dgettext("engine", "%{actor} ya tiene Esquiva asombrosa armada", actor: who)}

      %Character{} ->
        {:ok,
         dgettext(
           "engine",
           "%{actor} se prepara para esquivar (Uncanny Dodge armado: el próximo daño se reduce a la mitad).",
           actor: who
         ), World.set_uncanny_dodge(who, true)}
    end
  end

  @doc """
  Expertise (5e, D73): a rogue (L1+) or bard (L3+) deepens ONE trained
  skill — recorded in `Character.expertise`, doubled by the check routes
  (`check/7` and `cunning_action_hide` via `Combat.check_proficiency/3`).

  Cupo por clase y nivel (`Progression.expertise_count/2`: rogue 2 desde
  L1 y 4 desde L6; bard 2 desde L3 y 4 desde L10; resto 0). Se elige una
  vez por skill, en cualquier momento una vez elegible (la tool cubre el
  momento — nada de integración con level-up). JoaT (D60) nunca aplica a
  una skill con Expertise (ya es competente). Errors (NO mutan): who
  inexistente, caído, clase sin Expertise, nivel insuficiente para el
  PRIMER cupo (bardo L1–2), skill desconocida, skill sin competencia,
  skill ya elegida, cupo agotado.
  """
  @spec gain_expertise(World.t(), String.t(), atom() | String.t()) :: result()
  def gain_expertise(world, who, skill) do
    c = World.present_character(world, who)

    cond do
      is_nil(c) ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      (c.hp || 0) <= 0 ->
        {:error,
         dgettext("engine", "%{actor} está caído (0 pg) y no puede elegir Expertise", actor: who)}

      c.class not in ["rogue", "bard"] ->
        {:error,
         dgettext("engine", "%{actor} no puede elegir Expertise (sólo pícaros y bardos)",
           actor: who
         )}

      not expertise_eligible_level?(c) ->
        {:error,
         dgettext("engine", "%{actor} aún no tiene Expertise (llega a nivel 3)", actor: who)}

      not Skills.known?(skill) ->
        {:error, unknown_expertise_error(skill)}

      not skill_trained?(c, Skills.normalize(skill)) ->
        {:error,
         dgettext(
           "engine",
           "%{actor} no tiene competencia en %{skill} (Expertise sólo aplica a skills entrenadas)",
           actor: who,
           skill: Translations.skill(Skills.normalize(skill))
         )}

      skill_expertised?(c, Skills.normalize(skill)) ->
        {:error,
         dgettext("engine", "%{actor} ya tiene Expertise en %{skill}",
           actor: who,
           skill: Translations.skill(Skills.normalize(skill))
         )}

      length(c.expertise || []) >= Progression.expertise_count(c.class, c.level) ->
        {:error,
         dgettext("engine", "%{actor} ya ha elegido sus %{count} expertises (%{skills})",
           actor: who,
           count: Progression.expertise_count(c.class, c.level),
           skills: Enum.map_join(c.expertise || [], ", ", &Translations.skill/1)
         )}

      true ->
        normalized = Skills.normalize(skill)
        cap = Progression.expertise_count(c.class, c.level)
        position = length(c.expertise || []) + 1

        {:ok,
         dgettext(
           "engine",
           "%{actor} profundiza su dominio de %{skill} (Expertise %{position}/%{cap}).",
           actor: who,
           skill: Translations.skill(normalized),
           position: position,
           cap: cap
         ), World.add_expertise(who, normalized)}
    end
  end

  # Bardo L1–2: sin cupo aún (el pícaro lo tiene desde L1, las demás
  # clases ya se cortaron arriba).
  defp expertise_eligible_level?(%Character{class: "bard", level: level}),
    do: is_integer(level) and level >= 3

  defp expertise_eligible_level?(_), do: true

  defp skill_expertised?(%Character{expertise: list}, skill) when is_list(list) do
    Enum.any?(list, fn e -> is_binary(e) and Skills.normalize(e) == skill end)
  end

  defp skill_expertised?(_, _), do: false

  defp unknown_expertise_error(skill) do
    dgettext("engine", "skill desconocida: %{skill} — usa un skill entrenado (%{examples}, …)",
      skill: inspect(skill),
      examples: Skills.examples()
    )
  end

  # DC: the highest passive perception among conscious enemies; 10 when
  # there is none (RAW minimum).
  defp hide_dc(%World{} = world, %Character{} = who) do
    World.present_characters(world)
    |> Map.values()
    |> Enum.filter(fn c -> c.side != who.side and (c.hp || 0) > 0 end)
    |> Enum.map(&passive_perception/1)
    |> Enum.max(fn -> 10 end)
  end

  @doc "Passive perception: 10 + WIS mod (+ proficiency if trained)."
  @spec passive_perception(Character.t()) :: integer()
  def passive_perception(%Character{} = c) do
    prof = if skill_trained?(c, "perception"), do: Ability.proficiency(c.level), else: 0
    10 + Character.modifier(c, :wis) + prof
  end

  # Normalized membership (D60): sheets store canonical snake_case keys, but
  # custom/legacy data may differ in case or separators.
  defp skill_trained?(%Character{skill_proficiencies: profs}, skill) when is_list(profs) do
    Enum.any?(profs, fn p -> is_binary(p) and Skills.normalize(p) == skill end)
  end

  defp skill_trained?(_, _), do: false

  @doc """
  Create a Spell Slot (5e, D56 Font of Magic): a sorcerer of level 2+ spends
  sorcery points (RAW cost 2/3/5/6/7 for slots 1–5) and gains one slot of
  `level`. RAW allows exceeding the daily slot maximum. Combat allowed
  (bonus action RAW; action economy out of scope). Errors (nothing spent):
  missing who, 0 hp, not a sorcerer, level < 2, invalid slot level,
  insufficient points.
  """
  @spec create_spell_slot(World.t(), String.t(), integer()) :: result()
  def create_spell_slot(world, who, level) do
    with_actor(world, who, fn -> do_create_spell_slot(world, who, level) end, :bonus)
  end

  defp do_create_spell_slot(world, who, level) do
    sorcerer = World.present_character(world, who)
    cost = Progression.sorcery_slot_cost(level)

    cond do
      is_nil(sorcerer) ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      (sorcerer.hp || 0) <= 0 ->
        {:error,
         dgettext("engine", "%{actor} está caído (0 pg) y no puede usar Fuente de magia",
           actor: who
         )}

      sorcerer.class != "sorcerer" ->
        {:error,
         dgettext("engine", "%{actor} no es hechicero y no puede usar Fuente de magia",
           actor: who
         )}

      not is_integer(sorcerer.level) or sorcerer.level < 2 ->
        {:error, dgettext("engine", "%{actor} no tiene Fuente de magia (nivel 2)", actor: who)}

      is_nil(cost) ->
        {:error,
         dgettext("engine", "nivel de casilla inválido: %{level} (1 a 5)", level: inspect(level))}

      (sorcerer.sorcery_points || 0) < cost ->
        {:error,
         dgettext(
           "engine",
           "%{actor} no tiene suficientes puntos de hechicería (le quedan %{points}; la casilla de nivel %{level} cuesta %{cost})",
           actor: who,
           points: sorcerer.sorcery_points || 0,
           level: level,
           cost: cost
         )}

      true ->
        remaining = (sorcerer.sorcery_points || 0) - cost

        {:ok,
         dgettext(
           "engine",
           "%{actor} teje magia: convierte %{cost} puntos de hechicería en 1 casilla de nivel %{level} (quedan %{remaining} puntos).",
           actor: who,
           cost: cost,
           level: level,
           remaining: remaining
         ), compose_create_slot(who, level, cost)}
    end
  end

  @doc """
  Convert to Sorcery Points (5e, D56 Font of Magic): a sorcerer of level 2+
  spends one slot of `level` (1–5, same range as create) and gains `level`
  sorcery points, capped at the pool maximum (`Progression.sorcery_points/2`).
  The excess is silently discarded (RAW) — never an error — and the message
  reports the real result. Errors (nothing spent): missing who, 0 hp, not a
  sorcerer, level < 2, invalid slot level, no slot of that level left.
  """
  @spec convert_to_sorcery_points(World.t(), String.t(), integer()) :: result()
  def convert_to_sorcery_points(world, who, level) do
    with_actor(world, who, fn -> do_convert_to_sorcery_points(world, who, level) end, :bonus)
  end

  defp do_convert_to_sorcery_points(world, who, level) do
    sorcerer = World.present_character(world, who)

    cond do
      is_nil(sorcerer) ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      (sorcerer.hp || 0) <= 0 ->
        {:error,
         dgettext("engine", "%{actor} está caído (0 pg) y no puede usar Fuente de magia",
           actor: who
         )}

      sorcerer.class != "sorcerer" ->
        {:error,
         dgettext("engine", "%{actor} no es hechicero y no puede usar Fuente de magia",
           actor: who
         )}

      not is_integer(sorcerer.level) or sorcerer.level < 2 ->
        {:error, dgettext("engine", "%{actor} no tiene Fuente de magia (nivel 2)", actor: who)}

      not (is_integer(level) and level >= 1 and level <= 5) ->
        {:error,
         dgettext("engine", "nivel de casilla inválido: %{level} (1 a 5)", level: inspect(level))}

      not World.has_slot?(world, who, level) ->
        {:error,
         dgettext("engine", "%{actor} no le quedan casillas de nivel %{level}",
           actor: who,
           level: level
         )}

      true ->
        max = Progression.sorcery_points("sorcerer", sorcerer.level)
        before = sorcerer.sorcery_points || 0
        after_points = min(before + level, max)
        gained = after_points - before

        cap_note =
          if before + level > max,
            do: dgettext("engine", " El exceso se disipa en la Fuente."),
            else: ""

        {:ok,
         dngettext(
           "engine",
           "%{actor} drena una casilla de nivel %{level} y recupera %{count} punto de hechicería (%{points}/%{max} máx).%{note}",
           "%{actor} drena una casilla de nivel %{level} y recupera %{count} puntos de hechicería (%{points}/%{max} máx).%{note}",
           gained,
           actor: who,
           level: level,
           points: after_points,
           max: max,
           note: cap_note
         ), compose_convert_slot(who, level)}
    end
  end

  @doc """
  Metamagic (5e, D65): a sorcerer of level 3+ spends sorcery points to arm
  ONE option that the NEXT qualifying spell they cast will apply and
  consume:

    * `"empowered"` (1 punto) — the first `max(1, CHA mod)` damage dice
      of the spell roll twice, keeping the higher;
    * `"heightened"` (3 puntos, `target` required) — that target's save
      against the spell is resolved with disadvantage;
    * `"twinned"` (2 puntos, `target` required) — the same spell also
      resolves against the armed second target.

  Only ONE option may be armed at a time and there is no un-arm nor
  refund: a spell that doesn't qualify leaves it armed. Rests never touch
  it. Errors (nothing spent): missing who, downed, not a sorcerer,
  level < 3, unknown option, already armed, insufficient points,
  heightened without target, twinned without/inexistent/self target.
  """
  @spec arm_metamagic(World.t(), String.t(), String.t(), String.t()) :: result()
  def arm_metamagic(world, who, option, target \\ "")

  def arm_metamagic(world, who, option, target) do
    with_actor(world, who, fn -> do_arm_metamagic(world, who, option, target) end)
  end

  defp do_arm_metamagic(world, who, option, target) do
    sorcerer = World.present_character(world, who)
    opt = normalize_metamagic_option(option)
    target = if is_binary(target), do: String.trim(target), else: ""

    cond do
      is_nil(sorcerer) ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      (sorcerer.hp || 0) <= 0 ->
        {:error,
         dgettext("engine", "%{actor} está caído (0 pg) y no puede usar Metamagia", actor: who)}

      sorcerer.class != "sorcerer" ->
        {:error,
         dgettext("engine", "%{actor} no es hechicero y no puede usar Metamagia", actor: who)}

      not is_integer(sorcerer.level) or sorcerer.level < 3 ->
        {:error, dgettext("engine", "%{actor} no tiene Metamagia (nivel 3)", actor: who)}

      is_nil(opt) ->
        {:error,
         dgettext(
           "engine",
           "opción de Metamagia desconocida: %{option} (válidas: empowered, heightened, twinned)",
           option: option
         )}

      sorcerer.metamagic != nil ->
        {:error,
         dgettext(
           "engine",
           "%{actor} ya tiene Metamagia armada: %{option} — se consume con su próximo hechizo que califique (espera a que se consuma antes de armar otra)",
           actor: who,
           option: metamagic_es(sorcerer.metamagic)
         )}

      (sorcerer.sorcery_points || 0) < metamagic_cost(opt) ->
        {:error,
         dgettext(
           "engine",
           "%{actor} no tiene suficientes puntos de hechicería (le quedan %{points}; %{option} cuesta %{cost})",
           actor: who,
           points: sorcerer.sorcery_points || 0,
           option: metamagic_es(opt),
           cost: metamagic_cost(opt)
         )}

      opt == "heightened" and target == "" ->
        {:error, dgettext("engine", "heightened requiere un objetivo (target)")}

      opt == "twinned" and target == "" ->
        {:error, dgettext("engine", "twinned requiere un segundo objetivo (target)")}

      opt == "twinned" and is_nil(World.present_character(world, target)) ->
        {:error, dgettext("engine", "no existe el objetivo: %{target}", target: target)}

      opt == "twinned" and target == who ->
        {:error,
         dgettext(
           "engine",
           "twinned no puede gemarse a sí mismo (target debe ser otro personaje)"
         )}

      true ->
        cost = metamagic_cost(opt)
        remaining = (sorcerer.sorcery_points || 0) - cost

        points_label =
          if cost == 1,
            do: dgettext("engine", "1 punto de hechicería"),
            else: dgettext("engine", "%{cost} puntos de hechicería", cost: cost)

        target_bit =
          if target == "", do: "", else: dgettext("engine", " sobre %{target}", target: target)

        {:ok,
         dgettext(
           "engine",
           "%{actor} arma Metamagia: %{option} (%{points}, quedan %{remaining})%{target_note}. El próximo hechizo que califique la aplicará.",
           actor: who,
           option: metamagic_es(opt),
           points: points_label,
           remaining: remaining,
           target_note: target_bit
         ), compose_arm_metamagic(who, cost, opt, target)}
    end
  end

  defp compose_arm_metamagic(who, cost, opt, target) do
    armed = %{option: opt, target: if(target == "", do: nil, else: target)}

    fn w ->
      with {:ok, w} <- World.spend_sorcery_points(who, cost).(w) do
        World.set_metamagic(who, armed).(w)
      end
    end
  end

  @metamagic_costs %{"empowered" => 1, "heightened" => 3, "twinned" => 2}

  defp metamagic_cost(opt) when is_binary(opt), do: Map.get(@metamagic_costs, opt, 0)

  defp normalize_metamagic_option(option) when is_binary(option) do
    case String.downcase(String.trim(option)) do
      opt when opt in ~w(empowered heightened twinned) -> opt
      _ -> nil
    end
  end

  defp normalize_metamagic_option(_), do: nil

  defp metamagic_es(%{option: opt}), do: metamagic_es(opt)

  defp metamagic_es("empowered"), do: "Empowered"
  defp metamagic_es("heightened"), do: "Heightened"
  defp metamagic_es("twinned"), do: "Twinned"
  defp metamagic_es(opt), do: opt

  @doc """
  Breath Weapon (5e, D70): a dragonborn exhales dragon breath at `target`.

  Damage dice by level (`Progression.breath_dice/1`), type "fire" (no
  draconic ancestry in the engine — ADR D70). `target` rolls a DEX save
  vs DC `8 + CON mod + proficiency` of the dragonborn: success halves
  the damage (floor), failure takes it all. The use is spent on EVERY
  resolution (save or not — it is an area breath, D70); errors (missing
  who/target, downed who, not a dragonborn, already used) mutate
  nothing. Combat allowed; a downed target may be hit. Not a spell: no
  slot, no concentration set, works in Wild Shape (racial, RAW).
  """
  @spec breath_weapon(World.t(), String.t(), String.t(), roller(), RollLog.t() | nil) ::
          result()
  def breath_weapon(world, who, target, roller, roll_log \\ nil) do
    with_actor(
      world,
      who,
      fn -> do_breath_weapon(world, who, target, roller, roll_log) end,
      :action
    )
  end

  defp do_breath_weapon(world, who, target, roller, roll_log) do
    cond do
      is_nil(World.present_character(world, who)) ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      is_nil(World.present_character(world, target)) ->
        {:error, dgettext("engine", "no existe el objetivo: %{target}", target: target)}

      (World.present_character(world, who).hp || 0) <= 0 ->
        {:error,
         dgettext("engine", "%{actor} está caído (0 pg) y no puede usar su aliento", actor: who)}

      not dragonborn?(World.present_character(world, who)) ->
        {:error,
         dgettext("engine", "%{actor} no es dragontino y no tiene aliento de dragón", actor: who)}

      World.present_character(world, who).breath_weapon_used == true ->
        {:error,
         dgettext(
           "engine",
           "%{actor} ya ha usado su aliento de dragón (se recarga con un descanso)",
           actor: who
         )}

      true ->
        resolve_breath_weapon(world, who, target, roller, roll_log)
    end
  end

  defp resolve_breath_weapon(world, who, target_name, roller, roll_log) do
    source = World.present_character(world, who)
    t = World.present_character(world, target_name)
    level = source.level || 1
    dice = Progression.breath_dice(level)
    # CD pattern of spells, keyed on the dragonborn's CON (D70).
    dc = 8 + Ability.proficiency(level) + Character.modifier(source, :con)
    # D61: the aura covers this save (RAW — all saves) and the target's
    # concentration saves triggered by the breath damage.
    aura = aura_save_bonus(world, target_name)

    case Conditions.save_mode(t, :dex) do
      :auto_fail ->
        {r, close_dmg} =
          RollLog.open(
            roll_log,
            roller,
            who,
            :damage,
            dgettext("engine", "daño de aliento de dragón (%{damage_type})",
              damage_type: Terms.damage_type("fire")
            )
          )

        full = Dice.roll_expr(dice, r)
        RollLog.close(close_dmg, total: full, against: nil, outcome: nil)

        {:ok, msg, change} =
          with_conc_damage(
            dgettext(
              "engine",
              "%{actor} exhala aliento de dragón (fuego, usos restantes: 0): %{target} falla automáticamente la salvación de Destreza vs CD %{dc} — %{amount} de %{damage}.",
              actor: who,
              target: target_name,
              dc: dc,
              amount: full,
              damage: Terms.damage("fire")
            ),
            target_name,
            full,
            roller,
            roll_log,
            t,
            "fire",
            aura
          )

        {:ok, msg, compose_breath_spend(who, change)}

      {:roll, save_mode} ->
        {r, close_save} =
          RollLog.open(
            roll_log,
            roller,
            target_name,
            :save,
            dgettext("engine", "salvación de Destreza contra aliento de dragón")
          )

        inspired? = t.inspired == true

        {d20, stotal, _success?, lucky} =
          Combat.saving_throw_tagged(t, :dex, dc, r, save_mode)

        stotal = stotal + aura
        {stotal, success?, bardic} = apply_inspired_vs_dc(t, stotal, dc, r)

        # D68 Indomitable: same save-site stack as spells — the reroll
        # rides the same mode (Danger Sense/conditions) and re-applies
        # the aura.
        {d20, stotal, success?, indom} =
          maybe_indomitable(t, :dex, dc, r, save_mode, {d20, stotal, success?}, aura)

        before_save = t
        t = if indom, do: %{t | indomitable_used: true}, else: t
        t = if inspired?, do: %{t | inspired: false}, else: t

        RollLog.close(close_save,
          total: stotal,
          against: {:dc, dc},
          outcome: if(success?, do: :success, else: :failure)
        )

        {r2, close_dmg} =
          RollLog.open(
            roll_log,
            roller,
            who,
            :damage,
            dgettext("engine", "daño de aliento de dragón (%{damage_type})",
              damage_type: Terms.damage_type("fire")
            )
          )

        full = Dice.roll_expr(dice, r2)
        RollLog.close(close_dmg, total: full, against: nil, outcome: nil)

        # D59 Evasión: RAW covers any DEX-save half-damage effect, spell or
        # not — the breath qualifies (ADR D70).
        evasion? = evasion?(t, %{save_ability: :dex})

        dmg =
          cond do
            success? and evasion? -> 0
            success? -> div(full, 2)
            evasion? -> div(full, 2)
            true -> full
          end

        bardic_bit =
          if bardic != 0,
            do: dgettext("engine", " +%{bardic} inspiración", bardic: bardic),
            else: ""

        aura_b = aura_bit(aura)
        lucky_b = lucky_suffix(lucky)
        indom_b = indom_suffix(indom)

        verdict =
          cond do
            success? and evasion? ->
              dgettext(
                "engine",
                "supera la salvación de Destreza (d20 %{d20}%{lucky}%{indomitable}: %{total} vs CD %{dc}%{aura}%{bardic})%{mode} (Evasión: sin daño)",
                d20: d20,
                lucky: lucky_b,
                indomitable: indom_b,
                total: stotal,
                dc: dc,
                aura: aura_b,
                bardic: bardic_bit,
                mode: mode_tag(save_mode)
              )

            success? ->
              dgettext(
                "engine",
                "supera la salvación de Destreza (d20 %{d20}%{lucky}%{indomitable}: %{total} vs CD %{dc}%{aura}%{bardic})%{mode}, mitad de daño",
                d20: d20,
                lucky: lucky_b,
                indomitable: indom_b,
                total: stotal,
                dc: dc,
                aura: aura_b,
                bardic: bardic_bit,
                mode: mode_tag(save_mode)
              )

            evasion? ->
              dgettext(
                "engine",
                "falla la salvación de Destreza (d20 %{d20}%{lucky}%{indomitable}: %{total} vs CD %{dc}%{aura}%{bardic})%{mode} (Evasión: mitad)",
                d20: d20,
                lucky: lucky_b,
                indomitable: indom_b,
                total: stotal,
                dc: dc,
                aura: aura_b,
                bardic: bardic_bit,
                mode: mode_tag(save_mode)
              )

            true ->
              dgettext(
                "engine",
                "falla la salvación de Destreza (d20 %{d20}%{lucky}%{indomitable}: %{total} vs CD %{dc}%{aura}%{bardic})%{mode}",
                d20: d20,
                lucky: lucky_b,
                indomitable: indom_b,
                total: stotal,
                dc: dc,
                aura: aura_b,
                bardic: bardic_bit,
                mode: mode_tag(save_mode)
              )
          end

        {:ok, msg, change} =
          with_conc_damage(
            dgettext(
              "engine",
              "%{actor} exhala aliento de dragón (fuego, usos restantes: 0): %{target} %{verdict} — %{amount} de %{damage}.",
              actor: who,
              target: target_name,
              verdict: verdict,
              amount: dmg,
              damage: Terms.damage("fire")
            ),
            target_name,
            dmg,
            roller,
            roll_log,
            t,
            "fire",
            aura,
            before_save
          )

        {:ok, msg,
         compose_breath_spend(
           who,
           compose_indomitable_mark(
             target_name,
             indom,
             compose_inspired_clear(
               target_name,
               inspired?,
               change
             )
           )
         )}
    end
  end

  # D70: the use is spent on every resolution (save or not) — composed
  # last so errors above never reach it.
  defp compose_breath_spend(who, change) do
    fn w ->
      with {:ok, w} <- change.(w) do
        World.set_breath_weapon_used(who, true).(w)
      end
    end
  end

  defp dragonborn?(%Character{race: race}) when is_binary(race),
    do: String.downcase(race) == "dragonborn"

  defp dragonborn?(_), do: false

  @doc """
  A short rest: the character spends hit dice to recover HP.

  At level 1, a character has 1 hit die. The heal is `roll(hit_die) + con_mod`.
  Warlocks (D40) also restore Pact Magic slots; other casters do not.
  """
  @spec short_rest(World.t(), String.t(), roller(), RollLog.t() | nil) :: result()
  def short_rest(world, name, roller, roll_log \\ nil, hit_dice \\ nil) do
    with :ok <- Dragonex.Rest.validate(world, name, :short) do
      available = Dragonex.Rest.remaining(world, name)
      count = if is_nil(hit_dice), do: min(1, available), else: hit_dice

      if is_integer(count) and count >= 0 and count <= available,
        do: guard_rest(do_short_rest(world, name, roller, roll_log, count), world, name, 3600),
        else:
          {:error,
           dgettext("engine", "dados de golpe inválidos; disponibles %{available}",
             available: available
           )}
    end
  end

  defp do_short_rest(world, name, roller, roll_log, count) do
    # Dice are spent at the end of the rest, after timed forms/effects expire.
    projected = Dragonex.WorldClock.advance(world, 3600)

    case World.present_character(projected, name) do
      nil ->
        {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

      %Character{} when world.phase == :combat ->
        {:error, dgettext("engine", "no se puede descansar en combate")}

      %Character{hp: hp, max_hp: max_hp} = c ->
        if hp <= 0 do
          {:error, dgettext("engine", "%{name} está caído y no puede descansar", name: name)}
        else
          hit_die = World.hit_die_size(c.class)
          con_mod = Character.modifier(c, :con)

          {r, close} =
            RollLog.open(
              roll_log,
              roller,
              name,
              :heal,
              dgettext("engine", "descanso corto (1d%{hit_die})", hit_die: hit_die)
            )

          rolled =
            if count == 0,
              do: 0,
              else: Enum.sum(for _ <- 1..count, do: max(0, r.(hit_die) + con_mod))

          RollLog.close(close, total: rolled, against: nil, outcome: nil)
          applied = min(rolled, max_hp - hp)

          msg =
            dgettext(
              "engine",
              "%{name} hace un descanso corto y recupera %{amount} pg (%{count} dados de golpe d%{hit_die}, CON %{con} por dado = %{total}, ahora %{new_hp}/%{max_hp}).",
              name: name,
              amount: applied,
              count: count,
              hit_die: hit_die,
              con: signed(con_mod),
              total: rolled,
              new_hp: hp + applied,
              max_hp: max_hp
            )

          {msg, restore?} =
            if SpellSlots.pact_caster?(c.class) do
              {msg <> dgettext("engine", " Casillas de pacto recuperadas."), true}
            else
              {msg, false}
            end

          {:ok, msg, compose_rest(name, rolled, restore?, :short, count)}
        end
    end
  end

  @doc """
  A long rest: full HP restore (and clears short-term conditions).

  In 5e RAW, a long rest restores all hit points and hit dice (up to half the
  total). At level 1 this means full heal + 1 hit die back. It also recharges
  the long-rest pools: rage uses and the Relentless Rage DC counter (D72)
  reset to 0 alongside Lay on Hands, sorcery points, Relentless Endurance
  and Indomitable.
  """
  @spec long_rest(World.t(), String.t()) :: result()
  def long_rest(world, name) do
    with :ok <- Dragonex.Rest.validate(world, name, :long),
         do: guard_rest(do_long_rest(world, name), world, name, 28800)
  end

  defp guard_rest({:ok, message, change}, before, name, seconds) do
    expected_body = rest_body(before, name, seconds)

    {:ok, message,
     fn current ->
       with :ok <- unchanged_turn(before, current) do
         if rest_body(current, name, seconds) == expected_body do
           change.(current)
         else
           {:error,
            dgettext(
              "engine",
              "los recursos de %{actor} han cambiado; vuelve a resolver la acción",
              actor: name
            )}
         end
       end
     end}
  end

  defp guard_rest(error, _before, _name, _seconds), do: error

  # Compare the body that receives healing, after timed forms have expired.
  # A party rest's first member expires everyone's forms; the next member's
  # projection must still match, even though their pre-rest body has changed.
  defp rest_body(world, name, seconds) do
    projected = Dragonex.WorldClock.advance(world, seconds)

    case World.present_character(projected, name) do
      %Character{} = character -> Map.take(character, [:hp, :max_hp, :con, :class, :level])
      nil -> nil
    end
  end

  defp do_long_rest(world, name) do
    # Report the body that will receive healing after the rest's timed
    # effects expire, as short_rest does. Projection does not commit time.
    projected = Dragonex.WorldClock.advance(world, 28800)

    case World.present_character(projected, name) do
      nil ->
        {:error, dgettext("engine", "no existe el personaje: %{name}", name: name)}

      %Character{} when world.phase == :combat ->
        {:error, dgettext("engine", "no se puede descansar en combate")}

      %Character{hp: hp, max_hp: max_hp} ->
        if hp <= 0 do
          {:error, dgettext("engine", "%{name} está caído y no puede descansar", name: name)}
        else
          healed = max_hp - hp

          {:ok,
           dgettext(
             "engine",
             "%{name} hace un descanso largo y recupera %{healed} pg (%{hp} → %{max_hp}, recuperación completa). Casillas de hechizo recuperadas.",
             name: name,
             healed: healed,
             hp: hp,
             max_hp: max_hp
           ), compose_long_rest(name, healed)}
        end
    end
  end

  @doc "Simultaneous party rest: each member recovers, but world time advances only once."
  def rest_party(world, names, kind, roller, roll_log \\ nil) do
    cond do
      not is_list(names) or names == [] or Enum.any?(names, &(not is_binary(&1))) ->
        {:error, dgettext("engine", "indica una lista de personajes")}

      length(Enum.uniq(names)) != length(names) ->
        {:error, dgettext("engine", "un personaje no puede descansar dos veces a la vez")}

      kind not in ["short", "long"] ->
        {:error, dgettext("engine", "descanso inválido: short o long")}

      true ->
        with :ok <- validate_party_rest(world, names, kind) do
          Enum.reduce_while(names, {:ok, [], []}, fn name, {:ok, messages, changes} ->
            result =
              if kind == "short",
                do: short_rest(world, name, roller, roll_log),
                else: long_rest(world, name)

            case result do
              {:ok, message, change} -> {:cont, {:ok, messages ++ [message], changes ++ [change]}}
              error -> {:halt, error}
            end
          end)
          |> case do
            {:ok, messages, changes} ->
              {:ok, Enum.join(messages, " "),
               fn current ->
                 if current.elapsed_seconds != world.elapsed_seconds do
                   {:error,
                    dgettext("engine", "ha transcurrido tiempo desde la preparación del descanso")}
                 else
                   Enum.reduce_while(changes, {:ok, current}, fn change, {:ok, acc} ->
                     case change.(%{acc | elapsed_seconds: current.elapsed_seconds}) do
                       {:ok, next} -> {:cont, {:ok, next}}
                       error -> {:halt, error}
                     end
                   end)
                 end
               end}

            error ->
              error
          end
        end
    end
  end

  defp validate_party_rest(world, names, kind) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      case Dragonex.Rest.validate(world, name, if(kind == "short", do: :short, else: :long)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Resolve an ability check (non-combat): the DM sets the `dc`, the engine rolls
  `d20 + ability modifier` and reports success/failure. No world side-effect —
  the DM narrates the consequences and may then call other tools.

  `ability_or_skill` (D60): either a raw ability (`"str"`, `:dex`, …) or a
  skill name (`"stealth"`, `"Animal Handling"`, `"animal-handling"`). A known
  skill resolves to its governing ability (`Rules.Skills`) and the ENGINE
  applies proficiency from the sheet (`skill_proficiencies`), plus Jack of All
  Trades (bard L2+, half proficiency) on untrained checks — the `proficient`
  argument is ignored in that branch. A raw ability keeps the caller's
  `proficient` flag (backwards compatible). Unknown input → directive error.
  Expertise (D73): a trained skill in the sheet's `expertise` DOUBLES the
  proficiency bonus ("prof N (experto)"); never on a raw ability, and JoaT
  never stacks with it (already proficient).
  """
  @spec check(
          World.t(),
          String.t(),
          atom() | String.t(),
          integer(),
          boolean(),
          roller(),
          :normal | :advantage | :disadvantage,
          RollLog.t() | nil
        ) :: result()
  def check(
        world,
        who,
        ability_or_skill,
        dc,
        proficient,
        roller,
        mode \\ :normal,
        roll_log \\ nil
      ) do
    with_actor(
      world,
      who,
      fn -> do_check(world, who, ability_or_skill, dc, proficient, roller, mode, roll_log) end,
      :action
    )
  end

  defp do_check(world, who, ability_or_skill, dc, proficient, roller, mode, roll_log) do
    case World.present_character(world, who) do
      nil ->
        {:error, dgettext("engine", "no existe el personaje: %{actor}", actor: who)}

      # A downed character cannot make ability checks (death saves use their
      # own path); enforce RAW rather than trusting the model.
      %Character{hp: hp} when hp <= 0 ->
        {:error,
         dgettext("engine", "%{actor} está caído (0 pg) y no puede hacer chequeos", actor: who)}

      %Character{} = c ->
        with {:ok, %{ability: ability, proficient?: prof?, skill: skill}} <-
               resolve_check_input(c, ability_or_skill, proficient) do
          effective_mode = Conditions.check_mode(c, ability, mode)

          label = check_label(ability, skill)

          {r, close} =
            RollLog.open(
              roll_log,
              roller,
              who,
              :check,
              dgettext("engine", "chequeo de %{label}", label: label)
            )

          {d20, total, _success?, lucky} =
            Combat.ability_check_tagged(c, ability, dc, r, prof?, effective_mode, skill)

          inspired? = c.inspired == true
          {total, success?, bardic} = apply_inspired_vs_dc(c, total, dc, r)

          RollLog.close(close,
            total: total,
            against: {:dc, dc},
            outcome: if(success?, do: :success, else: :failure)
          )

          mod = Character.modifier(c, ability)
          {prof_bonus, prof_kind} = Combat.check_proficiency(c, prof?, skill)

          verdict =
            if success?, do: dgettext("engine", "éxito"), else: dgettext("engine", "fallo")

          parts = check_parts(d20, mod, ability, prof_bonus, prof_kind, bardic, skill, lucky)

          {:ok,
           dgettext(
             "engine",
             "%{actor} hace un chequeo de %{label}%{mode}: %{parts} = %{total} vs CD %{dc} — %{verdict}.",
             actor: who,
             label: label,
             mode: mode_tag(effective_mode),
             parts: Enum.join(parts, " + "),
             total: total,
             dc: dc,
             verdict: verdict
           ), compose_inspired_clear(who, inspired?, noop())}
        end
    end
  end

  # Skill-vs-ability detection (D60): a known skill wins over ability parsing
  # ("intimidation" is a CHA skill, not the int ability — the parser matches
  # prefixes). A skill takes proficiency from the sheet; a raw ability keeps
  # the caller's flag. Unknown input gets a directive error with examples.
  defp resolve_check_input(%Character{} = c, input, proficient) do
    if Skills.known?(input) do
      skill = Skills.normalize(input)

      {:ok,
       %{skill: skill, ability: ability_from_skills(skill), proficient?: skill_trained?(c, skill)}}
    else
      case Ability.parse(input) do
        {:ok, ability} -> {:ok, %{skill: nil, ability: ability, proficient?: proficient}}
        :error -> {:error, unknown_check_input_error(input)}
      end
    end
  end

  # The fetch cannot fail: known?/1 already validated the key.
  defp ability_from_skills(skill) do
    {:ok, ability} = Skills.ability(skill)
    ability
  end

  defp unknown_check_input_error(input) do
    dgettext(
      "engine",
      "característica o skill desconocidos: %{input} — usa un skill (%{examples}, …) o una característica str/dex/con/int/wis/cha",
      input: inspect(input),
      examples: Skills.examples()
    )
  end

  # Roll-log label: "Sigilo (DES)" for a named skill, "Destreza" for a raw
  # ability (same string is reused in the chat message).
  defp check_label(ability, nil), do: ability_es(ability)

  defp check_label(ability, skill),
    do: "#{Translations.skill(skill)} (#{Translations.ability_short(ability)})"

  # Breakdown parts. A named skill gets the D60 format
  # ("1d20(11) + DES 3 + prof 2" / "+ JoaT 1"; D73 expertise →
  # "prof 4 (experto)"); a raw ability keeps the v1
  # format ("d20 11 + +3 (dex) + 2 (competencia)") for backwards compat.
  # The Lucky reroll tag (D66) rides right after the die value.
  defp check_parts(d20, mod, ability, prof_bonus, prof_kind, bardic, nil, lucky) do
    ["d20 #{d20}#{lucky_suffix(lucky)}"]
    |> then(fn p -> if mod != 0, do: p ++ ["#{signed(mod)} (#{ability})"], else: p end)
    |> then(fn p ->
      case prof_kind do
        :prof -> p ++ [dgettext("engine", "%{bonus} (competencia)", bonus: prof_bonus)]
        :joat -> p ++ ["#{prof_bonus} (JoaT)"]
        :none -> p
      end
    end)
    |> then(fn p ->
      if bardic != 0,
        do: p ++ [dgettext("engine", "%{bardic} (inspiración)", bardic: bardic)],
        else: p
    end)
  end

  defp check_parts(d20, mod, ability, prof_bonus, prof_kind, bardic, skill, lucky)
       when is_binary(skill) do
    abbr = Translations.ability_short(ability)

    ["1d20(#{d20})#{lucky_suffix(lucky)}"]
    |> then(fn p -> if mod != 0, do: p ++ ["#{abbr} #{mod}"], else: p end)
    |> then(fn p ->
      case prof_kind do
        :expert -> p ++ [dgettext("engine", "prof %{bonus} (experto)", bonus: prof_bonus)]
        :prof -> p ++ [dgettext("engine", "prof %{bonus}", bonus: prof_bonus)]
        :joat -> p ++ ["JoaT #{prof_bonus}"]
        :none -> p
      end
    end)
    |> then(fn p ->
      if bardic != 0,
        do: p ++ [dgettext("engine", "inspiración %{bardic}", bardic: bardic)],
        else: p
    end)
  end

  # ------------------------------------------------------------- spell helpers

  @humanoid_races ~w(human elf dwarf halfling gnome half-elf half-orc dragonborn tiefling humanoid goblinoid orc reptilian)

  defp resolve_mage_armor(world, caster_name, targets) do
    with :ok <- validate_condition_targets(world, targets, :any) do
      twin = if length(targets) > 1, do: dgettext("engine", " (Metamagia: Twinned)"), else: ""

      {:ok,
       dgettext(
         "engine",
         "%{caster} conjura %{spell}%{twin} sobre %{targets}: CA 13 + DES durante 8 horas, sin concentración.",
         caster: caster_name,
         spell: Terms.spell("mage armor"),
         twin: twin,
         targets: Enum.join(targets, ", ")
       ), World.grant_mage_armor(targets)}
    end
  end

  defp resolve_charm_person(world, caster, caster_name, spell, targets, roller, roll_log) do
    with :ok <- validate_condition_targets(world, targets, :humanoid) do
      requested = if world.phase == :combat, do: :advantage, else: :normal

      {bits, failed, marks} =
        Enum.reduce(targets, {[], [], []}, fn name, {bits, failed, marks} ->
          target = World.present_character(world, name)

          save =
            condition_save(world, caster, spell, target, :wis, roller, roll_log,
              requested: requested
            )

          bit =
            condition_verdict(name, ability_es(:wis), save, dgettext("engine", "queda encantado"))

          bit =
            if length(targets) > 1,
              do: dgettext("engine", "en %{name}: %{result}", name: name, result: bit),
              else: bit

          failed = if save.success?, do: failed, else: failed ++ [name]
          {bits ++ [bit], failed, marks ++ [save_mark(name, save)]}
        end)

      {:ok,
       dgettext("engine", "%{caster} conjura %{spell}: %{effects}.",
         caster: caster_name,
         spell: Terms.spell("charm person"),
         effects: Enum.join(bits, "; ")
       ), compose_save_marks(marks, World.grant_charm(caster_name, caster.side, failed))}
    end
  end

  defp resolve_hold_person(world, caster, caster_name, spell, targets, roller, roll_log) do
    with :ok <- validate_condition_targets(world, targets, :humanoid) do
      {bits, failed, marks} =
        Enum.reduce(targets, {[], [], []}, fn name, {bits, failed, marks} ->
          target = World.present_character(world, name)
          save = condition_save(world, caster, spell, target, :wis, roller, roll_log)

          bit =
            condition_verdict(
              name,
              ability_es(:wis),
              save,
              dgettext("engine", "queda paralizado")
            )

          bit =
            if length(targets) > 1,
              do: dgettext("engine", "en %{name}: %{result}", name: name, result: bit),
              else: bit

          failed = if save.success?, do: failed, else: failed ++ [{name, save.dc}]
          {bits ++ [bit], failed, marks ++ [save_mark(name, save)]}
        end)

      {:ok, hold_person_message(caster_name, bits, failed),
       compose_save_marks(marks, hold_person_change(caster_name, failed))}
    end
  end

  defp resolve_faerie_fire(world, caster, caster_name, spell, targets, roller, roll_log) do
    with :ok <- validate_condition_targets(world, targets, :any) do
      {bits, failed, marks} =
        Enum.reduce(targets, {[], [], []}, fn name, {bits, failed, marks} ->
          target = World.present_character(world, name)
          save = condition_save(world, caster, spell, target, :dex, roller, roll_log)

          bit =
            condition_verdict(name, ability_es(:dex), save, dgettext("engine", "queda marcado"))

          bit =
            if length(targets) > 1,
              do: dgettext("engine", "en %{name}: %{result}", name: name, result: bit),
              else: bit

          failed = if save.success?, do: failed, else: failed ++ [name]
          {bits ++ [bit], failed, marks ++ [save_mark(name, save)]}
        end)

      {:ok, faerie_fire_message(caster_name, bits, failed),
       compose_save_marks(marks, faerie_fire_change(caster_name, failed))}
    end
  end

  defp hold_person_message(caster, bits, failed) do
    twin = if length(bits) > 1, do: dgettext("engine", " (Metamagia: Twinned)"), else: ""

    conc =
      if failed == [],
        do: "",
        else:
          dgettext("engine", " %{caster} concentra en %{spell}.",
            caster: caster,
            spell: Terms.spell("hold person")
          )

    dgettext("engine", "%{caster} conjura %{spell}%{twin}: %{effects}.%{concentration}",
      caster: caster,
      spell: Terms.spell("hold person"),
      twin: twin,
      effects: Enum.join(bits, "; "),
      concentration: conc
    )
  end

  defp faerie_fire_message(caster, bits, failed) do
    twin = if length(bits) > 1, do: dgettext("engine", " (Metamagia: Twinned)"), else: ""

    conc =
      if failed == [],
        do: "",
        else:
          dgettext("engine", " %{caster} concentra en %{spell}.",
            caster: caster,
            spell: Terms.spell("faerie fire")
          )

    dgettext("engine", "%{caster} conjura %{spell}%{twin}: %{effects}.%{concentration}",
      caster: caster,
      spell: Terms.spell("faerie fire"),
      twin: twin,
      effects: Enum.join(bits, "; "),
      concentration: conc
    )
  end

  defp hold_person_change(_caster, []), do: fn w -> {:ok, w} end

  defp hold_person_change(caster, failed) do
    effects =
      Enum.map(failed, fn {name, dc} ->
        {name,
         %{
           "condition" => "paralyzed",
           "source" => "hold_person:#{caster}",
           "concentration" => "hold person",
           "dc" => dc
         }}
      end)

    World.impose_sourced_conditions(caster, "hold person", effects)
  end

  defp faerie_fire_change(_caster, []), do: fn w -> {:ok, w} end

  defp faerie_fire_change(caster, failed) do
    effects =
      Enum.map(failed, fn name ->
        {name,
         %{
           "condition" => "faerie_fire",
           "source" => "faerie_fire:#{caster}",
           "concentration" => "faerie fire"
         }}
      end)

    World.impose_sourced_conditions(caster, "faerie fire", effects)
  end

  defp validate_condition_targets(world, targets, kind) do
    cond do
      Enum.any?(targets, &(World.present_character(world, &1) == nil)) ->
        {:error, dgettext("engine", "no existe el objetivo")}

      Enum.any?(targets, fn name ->
        c = World.present_character(world, name)
        c.death_saves.fails >= 3
      end) ->
        {:error, dgettext("engine", "el objetivo está muerto")}

      kind == :humanoid and
          Enum.any?(targets, &(not humanoid?(World.present_character(world, &1)))) ->
        {:error, dgettext("engine", "el conjuro solo afecta a humanoides")}

      true ->
        :ok
    end
  end

  defp humanoid?(%Character{race: race}) when race in [nil, ""], do: true

  defp humanoid?(%Character{race: race}) when is_binary(race) do
    down = String.downcase(race)
    down in @humanoid_races or String.contains?(down, "humanoid")
  end

  defp humanoid?(_), do: true

  # Same mode/bonus pipeline as resolve_save_spell: Heightened, Gnome Cunning,
  # Dwarven Resilience, aura, bardic inspiration, Indomitable and a :save RollLog.
  defp condition_save(world, caster, spell, target, ability, roller, roll_log, opts \\ []) do
    dc = Keyword.get(opts, :dc) || Combat.spell_save_dc(caster, spell)
    aura = World.aura_save_bonus(world, target.name)
    height? = heightened?(caster, target.name, %{kind: :save})
    requested = condition_requested(Keyword.get(opts, :requested, :normal), height?)
    gnome? = gnome_cunning?(target, ability)
    dwarf? = dwarven_resilience?(target, spell)

    base = %{
      dc: dc,
      aura: aura,
      gnome?: gnome?,
      height_tag: if(height?, do: dgettext("engine", " (Metamagia: Heightened)"), else: ""),
      indom: nil,
      inspired?: false,
      bardic: 0,
      mode: :normal
    }

    case Conditions.save_mode(target, ability, requested,
           gnome_advantage: gnome?,
           dwarf_advantage: dwarf?
         ) do
      :auto_fail ->
        Map.merge(base, %{d20: 0, total: 0, success?: false, auto?: true})

      {:roll, mode} ->
        {r, close} =
          RollLog.open(
            roll_log,
            roller,
            target.name,
            :save,
            dgettext("engine", "salvación de %{ability} contra %{spell}",
              ability: ability_es(ability),
              spell: Terms.spell(spell.name)
            )
          )

        inspired? = target.inspired == true
        {d20, total, _, _lucky} = Combat.saving_throw_tagged(target, ability, dc, r, mode)
        total = total + aura
        {total, success?, bardic} = apply_inspired_vs_dc(target, total, dc, r)

        {d20, total, success?, indom} =
          maybe_indomitable(target, ability, dc, r, mode, {d20, total, success?}, aura)

        RollLog.close(close,
          total: total,
          against: {:dc, dc},
          outcome: if(success?, do: :success, else: :failure)
        )

        Map.merge(base, %{
          d20: d20,
          total: total,
          success?: success?,
          auto?: false,
          mode: mode,
          indom: indom,
          inspired?: inspired?,
          bardic: bardic
        })
    end
  end

  defp metamagic_applied?(caster, spell, target, twin) do
    not is_nil(twin) or heightened?(caster, target, spell) or heightened?(caster, twin, spell)
  end

  defp condition_requested(:advantage, true), do: :normal
  defp condition_requested(_requested, true), do: :disadvantage
  defp condition_requested(requested, false), do: requested

  defp condition_verdict(name, ability, save, stuck) do
    tail = save_tail(save)

    cond do
      save.auto? ->
        dgettext(
          "engine",
          "%{name} falla automáticamente la salvación de %{ability} vs CD %{dc} y %{effect}",
          name: name,
          ability: ability,
          dc: save.dc,
          effect: stuck
        )

      save.success? ->
        dgettext(
          "engine",
          "%{name} supera la salvación de %{ability} (d20 %{d20}: %{total} vs CD %{dc}%{tail})",
          name: name,
          ability: ability,
          d20: save.d20,
          total: save.total,
          dc: save.dc,
          tail: tail
        )

      true ->
        dgettext(
          "engine",
          "%{name} falla la salvación de %{ability} (d20 %{d20}: %{total} vs CD %{dc}%{tail}) y %{effect}",
          name: name,
          ability: ability,
          d20: save.d20,
          total: save.total,
          dc: save.dc,
          tail: tail,
          effect: stuck
        )
    end
  end

  defp save_tail(save) do
    bardic =
      if save.bardic != 0,
        do: dgettext("engine", " +%{bardic} inspiración", bardic: save.bardic),
        else: ""

    mode =
      if save.gnome? and save.mode == :advantage,
        do: dgettext("engine", " (Astucia gnoma: ventaja)"),
        else: mode_tag(save.mode)

    "#{aura_bit(save.aura)}#{bardic}#{indom_suffix(save.indom)}#{mode}#{save.height_tag}"
  end

  defp save_mark(name, save), do: %{name: name, indom: save.indom, inspired?: save.inspired?}

  defp compose_save_marks(marks, change) do
    Enum.reduce(marks, change, fn mark, acc ->
      acc
      |> then(&compose_inspired_clear(mark.name, mark.inspired?, &1))
      |> then(&compose_indomitable_mark(mark.name, mark.indom, &1))
    end)
  end

  @doc false
  def reroll_hold_person(world, name, roller, roll_log \\ nil) do
    case World.present_character(world, name) do
      %Character{conditions: conds} = target ->
        if Enum.any?(conds, &hold_repeat_entry?/1) do
          {kept, notes, marks, freed} =
            Enum.reduce(conds, {[], [], [], []}, fn entry, {kept, notes, marks, freed} ->
              if hold_repeat_entry?(entry) do
                caster_name = hold_caster(entry)

                caster =
                  World.present_character(world, caster_name) ||
                    %Character{name: caster_name, level: 1}

                spell = %{name: "hold person", kind: :save, save_ability: :wis, damage_type: nil}

                save =
                  condition_save(world, caster, spell, target, :wis, roller, roll_log,
                    dc: entry["dc"]
                  )

                note =
                  if save.success?,
                    do:
                      dgettext(
                        "engine",
                        "%{name} supera Hold Person (d20 %{d20}: %{total} vs CD %{dc}%{tail}) y deja de estar paralizado",
                        name: name,
                        d20: save.d20,
                        total: save.total,
                        dc: save.dc,
                        tail: save_tail(save)
                      ),
                    else:
                      dgettext(
                        "engine",
                        "%{name} falla Hold Person (d20 %{d20}: %{total} vs CD %{dc}%{tail}) y sigue paralizado",
                        name: name,
                        d20: save.d20,
                        total: save.total,
                        dc: save.dc,
                        tail: save_tail(save)
                      )

                if save.success? do
                  {kept, notes ++ [note], marks ++ [save_mark(name, save)],
                   freed ++ [caster_name]}
                else
                  {kept ++ [entry], notes ++ [note], marks ++ [save_mark(name, save)], freed}
                end
              else
                {kept ++ [entry], notes, marks, freed}
              end
            end)

          {:ok, world} = World.set_conditions(name, kept).(world)
          world = Enum.reduce(notes, world, &World.note(&2, "dm", &1))
          world = apply_repeat_marks(world, marks)
          drop_orphan_hold(world, freed)
        else
          world
        end

      _ ->
        world
    end
  end

  defp hold_repeat_entry?(%{
         "condition" => "paralyzed",
         "source" => "hold_person:" <> _,
         "dc" => dc
       })
       when is_integer(dc),
       do: true

  defp hold_repeat_entry?(_), do: false

  defp hold_caster(%{"source" => "hold_person:" <> caster}), do: caster

  defp apply_repeat_marks(world, marks) do
    Enum.reduce(marks, world, fn mark, acc ->
      acc =
        if mark.inspired? do
          {:ok, acc} = World.set_inspired(mark.name, false).(acc)
          acc
        else
          acc
        end

      if mark.indom do
        {:ok, acc} = World.set_indomitable(mark.name, true).(acc)
        acc
      else
        acc
      end
    end)
  end

  defp drop_orphan_hold(world, casters) do
    Enum.reduce(Enum.uniq(casters), world, fn caster, acc ->
      still? =
        Enum.any?(acc.characters, fn {_n, c} ->
          Enum.any?(c.conditions || [], fn
            %{"source" => "hold_person:" <> name} -> name == caster
            _ -> false
          end)
        end)

      if still? do
        acc
      else
        case World.clear_concentration(caster).(acc) do
          {:ok, next} -> next
          _ -> acc
        end
      end
    end)
  end

  # ------------------------------------------------------ D99: spiritual weapon

  # La lanzadura resuelve el ataque inicial por la rama genérica y ADEMÁS
  # deja la postura persistente (D99): sin concentración, 1 minuto.
  defp chain_spiritual_weapon_posture({:ok, msg, change}, caster_name, spell, c) do
    mod = if spell.casting_ability, do: Character.modifier(c, spell.casting_ability), else: 0
    dice = spell.dice || "1d8"

    combined = fn w ->
      with {:ok, w} <- change.(w) do
        World.grant_spiritual_weapon(caster_name, dice, mod, 10).(w)
      end
    end

    {:ok, msg <> dgettext("engine", " El arma espiritual lo acompañará durante 1 minuto."),
     combined}
  end

  defp chain_spiritual_weapon_posture(error, _caster_name, _spell, _c), do: error

  @doc """
  D99 Spiritual Weapon: repeat attack with the persistent spectral weapon.
  One BONUS action (TurnBudget, patrón D82): melee spell attack of
  `dice + mod` force damage through the standard spell-attack pipeline
  (RollLog `:attack`, a crit doubles the DICE — never the mod, guided D95,
  faerie fire advantage via `attack_mode`, bless on the d20, effective AC).
  Errors (no active weapon, missing/dead target, no bonus action left) never
  mutate nor spend anything.
  """
  @spec spiritual_weapon_attack(World.t(), String.t(), String.t(), roller(), RollLog.t() | nil) ::
          result()
  def spiritual_weapon_attack(world, who, target_name, roller, roll_log \\ nil) do
    with_actor(
      world,
      who,
      fn ->
        do_spiritual_weapon_attack(world, who, target_name, roller, roll_log)
      end,
      :bonus
    )
  end

  defp do_spiritual_weapon_attack(world, who, target_name, roller, roll_log) do
    c = World.present_character(world, who)

    cond do
      is_nil(spiritual_weapon_entry(c)) ->
        {:error,
         dgettext(
           "engine",
           "%{actor} no tiene un arma espiritual activa (lanza spiritual weapon primero)",
           actor: who
         )}

      is_nil(World.present_character(world, target_name)) ->
        {:error, dgettext("engine", "no existe el objetivo: %{target}", target: target_name)}

      World.present_character(world, target_name).death_saves.fails >= 3 ->
        {:error, dgettext("engine", "%{target} está muerto", target: target_name)}

      true ->
        t = World.present_character(world, target_name)
        spiritual_weapon_swing(world, c, who, t, target_name, roller, roll_log)
    end
  end

  defp spiritual_weapon_entry(%Character{conditions: conds}) do
    Enum.find(conds || [], fn
      %{"condition" => "spiritual_weapon", "rounds_left" => n}
      when is_integer(n) and n > 0 ->
        true

      _ ->
        false
    end)
  end

  defp spiritual_weapon_entry(_), do: nil

  # Espejo de la rama :attack de resolve_spell (pipeline de ataque de
  # conjuro existente, D99), con el mod guardado en la postura.
  defp spiritual_weapon_swing(world, c, who, t, target_name, roller, roll_log) do
    entry = spiritual_weapon_entry(c)
    mod = entry["mod"] || 0
    dice = entry["dice"] || "1d8"
    bonus = Ability.proficiency(c.level) + mod
    guided? = Guided.active?(world, t)
    effective_mode = Conditions.attack_mode(c, t, ranged: false, guided: guided?)

    {r, close} =
      RollLog.open(
        roll_log,
        roller,
        who,
        :attack,
        dgettext("engine", "ataque con arma espiritual")
      )

    d20 = kept_d20(r, effective_mode)
    bless = Effects.bless_bonus(c, r)
    bless_tag = lucky_suffix(Effects.tag(nil, bless))
    total = d20 + bonus + bless
    ac = target_ac(t)
    hit? = d20 == 20 or (d20 != 1 and total >= ac)
    crit? = d20 == 20

    outcome =
      cond do
        crit? -> :crit
        hit? -> :hit
        true -> :miss
      end

    RollLog.close(close,
      total: total,
      against: {:ac, ac},
      outcome: outcome
    )

    result =
      if hit? do
        {r2, close_dmg} =
          RollLog.open(
            roll_log,
            roller,
            who,
            :damage,
            dgettext("engine", "daño de arma espiritual (%{damage_type})",
              damage_type: Terms.damage_type("force")
            )
          )

        base = Dice.roll_expr(dice, r2)
        raw_dmg = if crit?, do: base + Dice.roll_expr(dice, r2) + mod, else: base + mod
        dmg = Combat.damage_total(raw_dmg)
        damage_summary = [total: dmg, against: nil, outcome: nil]

        damage_summary =
          if raw_dmg < 0,
            do: Keyword.put(damage_summary, :raw_total, raw_dmg),
            else: damage_summary

        RollLog.close(close_dmg, damage_summary)

        aura = aura_save_bonus(world, target_name)
        verb = if crit?, do: dgettext("engine", "CRÍTICO"), else: dgettext("engine", "acierta")

        with_conc_damage(
          dgettext(
            "engine",
            "%{actor} %{verb} a %{target} con su arma espiritual (d20 %{d20}%{bless}: %{total} vs CA %{ac}) por %{amount} de %{damage}%{mode}.",
            actor: who,
            verb: verb,
            target: target_name,
            d20: d20,
            bless: bless_tag,
            total: total,
            ac: ac,
            amount: dmg,
            damage: Terms.damage("force"),
            mode: mode_tag(effective_mode)
          ),
          target_name,
          dmg,
          roller,
          roll_log,
          t,
          "force",
          aura
        )
      else
        {:ok,
         dgettext(
           "engine",
           "%{actor} lanza su arma espiritual contra %{target} — fallo (d20 %{d20}%{bless}: %{total} vs CA %{ac})%{mode}.",
           actor: who,
           target: target_name,
           d20: d20,
           bless: bless_tag,
           total: total,
           ac: ac,
           mode: mode_tag(effective_mode)
         ), noop()}
      end

    consume_guided_after_roll(result, target_name, guided?)
  end

  # ---------------------------------------------------- D99: spirit guardians

  # Sin daño inmediato: marca el aura en el lanzador vinculada a la
  # concentración (patrón D97). `target` se ignora (alcance self).
  defp resolve_spirit_guardians(caster_name, spell, c) do
    dc = Combat.spell_save_dc(c, %{spell | casting_ability: spell.casting_ability || :wis})
    dice = spell.dice || "3d8"

    {:ok,
     dgettext(
       "engine",
       "%{caster} conjura %{spell}: espíritus revolotean a su alrededor y golpearán a sus enemigos al inicio de cada uno de sus turnos (SAB vs CD %{dc}, la mitad al superararla). %{caster} concentra en %{spell}.",
       caster: caster_name,
       spell: Terms.spell("spirit guardians"),
       dc: dc
     ),
     World.impose_sourced_conditions(caster_name, "spirit guardians", [
       {caster_name,
        %{
          "condition" => "spirit_guardians",
          "source" => "spirit_guardians:#{caster_name}",
          "dice" => dice,
          "dc" => dc
        }}
     ])}
  end

  @doc false
  # D99 tick, llamado por World.set_current_combatant al inicio del turno
  # NUEVO del lanzador (cuello D44). El Game aporta roller y RollLog también
  # fuera de un beat de IA. Guardas: concentra, vivo y consciente; si no, no
  # tickea. Cada enemigo vivo y consciente tira SAB con el stack completo
  # de condition_save; fallo = dados completos, éxito = mitad (floor).
  def spirit_guardians_tick(world, caster_name, roller, roll_log \\ nil) do
    case World.present_character(world, caster_name) do
      %Character{hp: hp, death_saves: %{fails: fails}} = c when hp > 0 and fails < 3 ->
        if c.concentrating == "spirit guardians" and
             not incapacitated?(c) and guardians_entry(c) != nil do
          tick_guardians(world, c, caster_name, roller, roll_log)
        else
          world
        end

      _ ->
        world
    end
  end

  defp guardians_entry(%Character{} = c) do
    Enum.find(c.conditions || [], fn
      %{"condition" => "spirit_guardians", "source" => "spirit_guardians:" <> _, "dc" => dc}
      when is_integer(dc) ->
        true

      _ ->
        false
    end)
  end

  defp incapacitated?(%Character{} = c) do
    Enum.any?(
      Character.condition_names(c),
      &(&1 in ~w(incapacitated stunned paralyzed petrified unconscious))
    )
  end

  defp tick_guardians(world, caster, _caster_name, roller, roll_log) do
    entry = guardians_entry(caster)
    pseudo = %Spell{name: "spirit guardians", level: 3, kind: :save, save_ability: :wis}

    enemies =
      World.present_characters(world)
      |> Enum.filter(fn {_name, ch} ->
        match?(%Character{}, ch) and ch.side != caster.side and ch.hp > 0 and
          ch.death_saves.fails < 3 and "unconscious" not in Character.condition_names(ch)
      end)
      |> Enum.sort_by(fn {name, _} -> name end)

    {world, notes} =
      Enum.reduce(enemies, {world, []}, fn {name, t}, {w, notes} ->
        save = condition_save(w, caster, pseudo, t, :wis, roller, roll_log, dc: entry["dc"])

        # The spell save spends resources before the damage's concentration
        # save. Commit still validates against the original, pre-save target.
        after_save = if save.indom, do: %{t | indomitable_used: true}, else: t
        after_save = if save.inspired?, do: %{after_save | inspired: false}, else: after_save

        {r2, close_dmg} =
          RollLog.open(
            roll_log,
            roller,
            name,
            :damage,
            dgettext("engine", "daño de %{spell} (%{damage_type})",
              spell: Terms.spell("spirit guardians"),
              damage_type: Terms.damage_type("radiant")
            )
          )

        full = Dice.roll_expr(entry["dice"] || "3d8", r2)
        RollLog.close(close_dmg, total: full, against: nil, outcome: nil)

        dmg = if save.success?, do: div(full, 2), else: full

        verb =
          if save.success?, do: dgettext("engine", "supera"), else: dgettext("engine", "falla")

        {:ok, _msg, change} =
          with_conc_damage(
            dgettext("engine", "%{verb}%{tail} — recibe %{amount} de %{damage}",
              verb: verb,
              tail: save_tail(save),
              amount: dmg,
              damage: Terms.damage("radiant")
            ) <>
              if(save.success?, do: dgettext("engine", " (la mitad)"), else: ""),
            name,
            dmg,
            roller,
            roll_log,
            after_save,
            "radiant",
            World.aura_save_bonus(w, name),
            t
          )

        change = compose_save_marks([save_mark(name, save)], change)

        case change.(w) do
          {:ok, w} ->
            note =
              dgettext(
                "engine",
                "%{name} %{verb} la salvación de Sabiduría de spirit guardians (d20 %{d20}: %{total} vs CD %{dc}%{tail})",
                name: name,
                verb: verb,
                d20: save.d20,
                total: save.total,
                dc: save.dc,
                tail: save_tail(save)
              )

            {w, notes ++ [note]}

          _ ->
            {w, notes}
        end
      end)

    Enum.reduce(notes, world, &World.note(&2, "dm", &1))
  end

  defp resolve_false_life(caster, spell, level, roller, roll_log) do
    {r, close} =
      RollLog.open(
        roll_log,
        roller,
        caster,
        :spell,
        dgettext("engine", "conjura %{spell}", spell: Terms.spell(spell.name))
      )

    rolled = Dice.roll_expr(Upcast.false_life_dice(level), r)

    RollLog.close(close,
      kind: :heal,
      reason: dgettext("engine", "pg temporales de %{spell}", spell: Terms.spell(spell.name)),
      total: rolled,
      outcome: nil
    )

    {:ok,
     dgettext(
       "engine",
       "%{caster} conjura %{spell}; genera %{total} pg temporales durante 1 hora (no se acumulan; conserva el mayor valor).",
       caster: caster,
       spell: Terms.spell(spell.name),
       total: rolled
     ), World.apply_temp_hp_for(caster, rolled, 3600)}
  end

  # D96 Sleep: pool RAW (5d8 + 2d8/nivel sobre 1, ya combinado en
  # `scaled.dice`), SIN salvación. Área abstracta: todos los enemigos vivos
  # y conscientes del lanzador, ordenados por PG ascendente; quien cabe
  # entero en el pool restante duerme y descuenta TODO su pg; el primero
  # que no cabe detiene el reparto.
  defp resolve_sleep(world, %Character{} = caster, caster_name, spell, roller, roll_log) do
    enemies = sleep_targets(world, caster)

    {r, close} =
      RollLog.open(
        roll_log,
        roller,
        caster_name,
        :spell,
        dgettext("engine", "conjura %{spell} (%{dice})",
          spell: Terms.spell(spell.name),
          dice: spell.dice
        )
      )

    pool = dice_with(spell, r, 0)

    RollLog.close(close,
      kind: :spell,
      reason: dgettext("engine", "pool de sueño de %{spell}", spell: Terms.spell(spell.name)),
      total: pool,
      outcome: nil
    )

    {sleepers, spent, leftover} = assign_sleep(enemies, pool, [])
    names = Enum.map_join(sleepers, ", ", & &1.name)

    msg =
      case sleepers do
        [] ->
          dgettext(
            "engine",
            "%{caster} conjura %{spell} (pool %{pool}): no hay enemigos que duerman.",
            caster: caster_name,
            spell: Terms.spell(spell.name),
            pool: pool
          )

        _ ->
          detail =
            case enemies -- sleepers do
              [first | _] ->
                dgettext(
                  "engine",
                  "; %{name} (%{hp} pg) resiste — el resto del pool (%{leftover}) no alcanza",
                  name: first.name,
                  hp: first.hp,
                  leftover: leftover
                )

              [] ->
                dgettext("engine", "; queda %{leftover} de pool sin gastar", leftover: leftover)
            end

          dngettext(
            "engine",
            "%{caster} conjura %{spell} (pool %{pool}): %{names} cae inconsciente (%{spent} pg del pool)%{detail}.",
            "%{caster} conjura %{spell} (pool %{pool}): %{names} caen inconscientes (%{spent} pg del pool)%{detail}.",
            length(sleepers),
            caster: caster_name,
            spell: Terms.spell(spell.name),
            pool: pool,
            names: names,
            spent: spent,
            detail: detail
          )
      end

    {:ok, msg,
     if(sleepers == [],
       do: noop(),
       else: World.apply_sleep(caster_name, Enum.map(sleepers, & &1.name))
     )}
  end

  # Enemigos vivos y conscientes del lanzador, por PG ascendente (empates
  # por nombre: orden determinista para los oráculos).
  defp sleep_targets(world, %Character{} = caster) do
    World.present_characters(world)
    |> Enum.filter(fn
      {_name, %Character{} = ch} ->
        ch.side != nil and ch.side != caster.side and (ch.hp || 0) > 0 and
          "unconscious" not in Character.condition_names(ch)

      _ ->
        false
    end)
    |> Enum.map(fn {_name, ch} -> ch end)
    |> Enum.sort_by(&{&1.hp, &1.name})
  end

  defp assign_sleep([], _pool, acc), do: {Enum.reverse(acc), 0, 0}

  defp assign_sleep([%Character{hp: hp} | _rest] = enemies, pool, acc) do
    if hp <= pool do
      [first | rest] = enemies
      {sleepers, spent, leftover} = assign_sleep(rest, pool - hp, [first | acc])
      {sleepers, spent + hp, leftover}
    else
      # RAW: la primera criatura que no cabe detiene el reparto.
      {Enum.reverse(acc), Enum.sum(Enum.map(acc, & &1.hp)), pool}
    end
  end

  # D96 Shield: postura armable en el turno propio (simplificación D64: no
  # hay economía de reacción para uno mismo). +5 CA efectiva hasta el inicio
  # del siguiente turno; rearmar renueva. La casilla de nivel 1 la validan y
  # gastan los caminos genéricos de cast_spell.
  defp resolve_shield(world, caster_name, target_name) do
    if world.phase != :combat do
      {:error,
       dgettext("engine", "Shield solo puede tejerse en combate (reacción abstracta, D96)")}
    else
      {:ok,
       dgettext(
         "engine",
         "%{caster} teje un escudo arcano: +5 CA hasta el inicio de su siguiente turno; los dardos de magic missile no le dañarán.",
         caster: caster_name
       ), World.arm_shield(target_name)}
    end
  end

  defp shield_spell?(%{name: name}) when is_binary(name),
    do: name |> String.downcase() |> String.replace(~r/[\s_-]+/, "") == "shield"

  defp shield_spell?(_), do: false

  defp magic_missile?(%{name: name}) when is_binary(name),
    do: name |> String.downcase() |> String.replace(~r/[\s_-]+/, "") == "magicmissile"

  defp magic_missile?(_), do: false

  defp resolve_spell(world, c, caster_name, t, target_name, spell, roller, roll_log) do
    # D61: the aura covers the save target and the target's concentration
    # saves triggered by this spell's damage.
    aura = aura_save_bonus(world, target_name)
    # D65 Metamagic: Empowered boosts the spell's damage dice; Heightened
    # forces disadvantage on the armed target's save. Both apply (and are
    # consumed) only when the spell qualifies — see empowered_count/2 and
    # heightened?/3.
    emp = empowered_count(c, spell)
    heightened? = heightened?(c, target_name, spell)
    emp_tag = metamagic_tag(emp)

    case spell.kind do
      :automatic ->
        {r, close} =
          RollLog.open(
            roll_log,
            roller,
            caster_name,
            :spell,
            dgettext("engine", "conjura %{spell}", spell: Terms.spell(spell.name))
          )

        amount =
          case spell do
            %{dice: nil} -> 0
            # D65 Empowered: damage dice roll through the empowered path
            # (no-op for healing spells — emp is 0 without a damage_type).
            %{dice: _expr} -> dice_with(spell, r, emp)
          end

        cond do
          # D96 Shield: mientras la postura vive, magic missile hace 0 daño
          # al portador (los dardos se disipan; el pool no se recalcula).
          magic_missile?(spell) and Effects.shielded?(t) ->
            RollLog.close(close,
              kind: :damage,
              reason:
                dgettext("engine", "dardos de %{spell} contra escudo",
                  spell: Terms.spell(spell.name)
                ),
              total: 0,
              outcome: nil
            )

            {:ok,
             dgettext(
               "engine",
               "%{caster} conjura %{spell}; los dardos se disipan contra el escudo arcano de %{target} — 0 de %{damage}.",
               caster: caster_name,
               spell: Terms.spell(spell.name),
               target: target_name,
               damage: Terms.damage("force")
             ), noop()}

          # Healing spell: no damage_type but has dice → heal the target
          spell.damage_type == nil and amount > 0 ->
            cast_mod = Character.modifier(c, spell.casting_ability)
            total_heal = max(0, amount + cast_mod)

            RollLog.close(close,
              kind: :heal,
              reason: dgettext("engine", "curación de %{spell}", spell: Terms.spell(spell.name)),
              total: total_heal,
              outcome: nil
            )

            {:ok,
             dgettext(
               "engine",
               "%{caster} conjura %{spell}; %{target} se cura %{total} pg (%{amount} + %{modifier}).",
               caster: caster_name,
               spell: Terms.spell(spell.name),
               target: target_name,
               total: total_heal,
               amount: amount,
               modifier: cast_mod
             ), World.heal(target_name, total_heal)}

          # Damage spell (magic missile, etc.)
          amount > 0 ->
            verb = spell_damage_verb(spell, amount)

            RollLog.close(close,
              kind: :damage,
              reason:
                dgettext("engine", "daño de %{spell} (%{damage_type})",
                  spell: Terms.spell(spell.name),
                  damage_type: Terms.damage_type(spell.damage_type)
                ),
              total: amount,
              outcome: nil
            )

            with_conc_damage(
              dgettext(
                "engine",
                "%{caster} conjura %{spell}; %{target} recibe %{amount} de %{damage}%{verb}%{empowered}.",
                caster: caster_name,
                spell: Terms.spell(spell.name),
                target: target_name,
                amount: amount,
                damage: Terms.damage(spell.damage_type),
                verb: verb,
                empowered: emp_tag
              ),
              target_name,
              amount,
              roller,
              roll_log,
              t,
              spell.damage_type,
              aura
            )

          # Other utility spells without executable effects: no dice → report.
          true ->
            RollLog.close(close, total: 0, outcome: nil)

            {:ok,
             dgettext("engine", "%{caster} conjura %{spell} sobre %{target}. %{effect}",
               caster: caster_name,
               spell: Terms.spell(spell.name),
               target: target_name,
               effect: spell.effect || ""
             ), noop()}
        end

      :attack ->
        bonus = Combat.spell_attack_bonus(c, spell)
        # D95: un objetivo guiado por guiding bolt concede ventaja a esta
        # tirada junto a todas las fuentes de ventaja/desventaja.
        guided? = Guided.active?(world, t)
        effective_mode = Conditions.attack_mode(c, t, ranged: true, guided: guided?)
        # D57: a hidden caster keeps the advantage for free (attack_mode),
        # but the spell attack reveals them just like a weapon swing.
        hidden? = "hidden" in Character.condition_names(c)

        {r, close_atk} =
          RollLog.open(
            roll_log,
            roller,
            caster_name,
            :attack,
            dgettext("engine", "ataque con %{spell}", spell: Terms.spell(spell.name))
          )

        d20 = kept_d20(r, effective_mode)
        bless = Effects.bless_bonus(c, r)
        bless_tag = lucky_suffix(Effects.tag(nil, bless))
        total = d20 + bonus + bless
        ac = target_ac(t)
        hit? = d20 == 20 or (d20 != 1 and total >= ac)

        RollLog.close(close_atk,
          total: total,
          against: {:ac, ac},
          outcome: if(d20 == 20, do: :crit, else: if(hit?, do: :hit, else: :miss))
        )

        if hit? do
          {r2, close_dmg} =
            RollLog.open(
              roll_log,
              roller,
              caster_name,
              :damage,
              dgettext("engine", "daño de %{spell} (%{damage_type})",
                spell: Terms.spell(spell.name),
                damage_type: Terms.damage_type(spell.damage_type)
              )
            )

          dmg =
            cond do
              # D65: a crit doubles the (already empowered) base dice —
              # the rerolls themselves are never duplicated.
              d20 == 20 and emp > 0 ->
                base = dice_with(spell, r2, emp)
                base + base

              d20 == 20 ->
                dice_with(spell, r2, 0) + dice_with(spell, r2, 0)

              true ->
                dice_with(spell, r2, emp)
            end

          RollLog.close(close_dmg, total: dmg, against: nil, outcome: nil)

          with_conc_damage(
            dgettext(
              "engine",
              "%{caster} conjura %{spell}; impacta a %{target} (d20 %{d20}%{bless}: %{total} vs CA %{ac}) por %{amount} de %{damage}%{empowered}%{mode}.",
              caster: caster_name,
              spell: Terms.spell(spell.name),
              target: target_name,
              d20: d20,
              bless: bless_tag,
              total: total,
              ac: ac,
              amount: dmg,
              damage: Terms.damage(spell.damage_type),
              empowered: emp_tag,
              mode: mode_tag(effective_mode)
            ),
            target_name,
            dmg,
            roller,
            roll_log,
            t,
            spell.damage_type,
            aura
          )
          # D95: esta tirada consume la marca guiada (una marca fresca de
          # guiding bolt se aplica DESPUÉS, dentro del mark).
          |> consume_guided_after_roll(target_name, guided?)
          |> mark_guided_on_hit(spell, caster_name, target_name)
          |> clear_hidden_after_attack_spell(caster_name, hidden?)
        else
          {:ok,
           dgettext(
             "engine",
             "%{caster} conjura %{spell}; falla contra %{target} (d20 %{d20}%{bless}: %{total} vs CA %{ac})%{mode}.",
             caster: caster_name,
             spell: Terms.spell(spell.name),
             target: target_name,
             d20: d20,
             bless: bless_tag,
             total: total,
             ac: ac,
             mode: mode_tag(effective_mode)
           ), noop()}
          # D95: la marca guiada se consume también al fallar (RAW: la
          # primera tirada de ataque posterior, acierte o falle).
          |> consume_guided_after_roll(target_name, guided?)
          |> clear_hidden_after_attack_spell(caster_name, hidden?)
        end

      :save ->
        resolve_save_spell(
          c,
          caster_name,
          t,
          target_name,
          spell,
          roller,
          roll_log,
          aura,
          heightened?,
          emp
        )
    end
    |> consume_metamagic(caster_name, emp > 0 or heightened?)
    |> guard_target_defense(world, target_name, spell.kind)
  end

  # D65 Heightened: applies when a save spell targets EXACTLY the armed
  # target — that save resolves with disadvantage (entered as `requested`,
  # so it combines with conditions through Conditions.save_mode). Any other
  # target: no apply, no consume.
  defp heightened?(%Character{metamagic: metamagic}, target_name, %{kind: :save}) do
    case metamagic do
      %{option: "heightened", target: armed}
      when is_binary(armed) and armed != "" and armed == target_name ->
        true

      _ ->
        false
    end
  end

  defp heightened?(_c, _target_name, _spell), do: false

  # D65 Empowered: applies to spells that roll damage dice (a dice
  # expression AND a damage type — heals and utility never qualify).
  # Returns how many of the dice roll twice keeping the higher:
  # `max(1, CHA mod)` of the caster.
  defp empowered_count(%Character{} = c, %{dice: dice, damage_type: dt})
       when is_binary(dt) and dt != "" do
    case c.metamagic do
      %{option: "empowered"} when dice != nil and dice != "" ->
        max(1, Character.modifier(c, :cha))

      _ ->
        0
    end
  end

  defp empowered_count(_c, _spell), do: 0

  # D65: consume the armed option once it applied (resolve_spell sites only
  # — never make_attack or anywhere else).
  defp consume_metamagic({:ok, msg, change}, caster_name, true) do
    combined = fn w ->
      with {:ok, w} <- change.(w) do
        World.set_metamagic(caster_name, nil).(w)
      end
    end

    {:ok, msg, combined}
  end

  defp consume_metamagic(result, _caster_name, _applied), do: result

  defp metamagic_tag(0), do: ""

  defp metamagic_tag(_emp), do: dgettext("engine", " (Metamagia: Empowered)")

  # D65 Twinned: applies when the armed twin target exists and differs from
  # the caster, and the spell targets someone other than the caster
  # (self-buffs never apply nor consume). Returns the twin's name or nil.
  defp twinned_target(world, %Character{} = c, caster_name, target_name) do
    case c.metamagic do
      %{option: "twinned", target: twin} when is_binary(twin) and twin != "" ->
        if twin != caster_name and target_name != caster_name and
             not is_nil(World.present_character(world, twin)) do
          twin
        else
          nil
        end

      _ ->
        nil
    end
  end

  # D65 Twinned: the SAME spell resolves against both targets — each
  # resolution rolls its own dice (the first one's rolls are never
  # re-used). The spell is one: the slot is consumed once and concentration
  # set once (both composed by the caller in spell/5). The option is
  # consumed here, once.
  defp resolve_twinned(world, c, caster_name, target_name, twin_name, spell, roller, roll_log) do
    t1 = World.present_character(world, target_name)
    t2 = World.present_character(world, twin_name)

    {:ok, msg1, change1} =
      resolve_spell(world, c, caster_name, t1, target_name, spell, roller, roll_log)

    {:ok, msg2, change2} =
      resolve_spell(world, c, caster_name, t2, twin_name, spell, roller, roll_log)

    change = fn w ->
      with {:ok, w} <- change1.(w),
           {:ok, w} <- change2.(w) do
        World.set_metamagic(caster_name, nil).(w)
      end
    end

    {:ok,
     dgettext("engine", "%{caster} conjura %{spell} (Metamagia: Twinned): %{first}; %{second}.",
       caster: caster_name,
       spell: Terms.spell(spell.name),
       first: twin_block(caster_name, spell, target_name, msg1),
       second: twin_block(caster_name, spell, twin_name, msg2)
     ), change}
  end

  # Per-target block of a Twinned message: strip the shared
  # "X conjura Y; " prefix (or "X conjura Y sobre <target>. ") so the outer
  # message reads "en <target>: <resolution>".
  defp twin_block(caster_name, spell, target_name, msg) do
    prefix =
      dgettext("engine", "%{caster} conjura %{spell}",
        caster: caster_name,
        spell: Terms.spell(spell.name)
      )

    over = dgettext("engine", " sobre ")

    body =
      cond do
        String.starts_with?(msg, prefix <> "; ") ->
          msg
          |> String.replace_prefix(prefix <> "; ", "")
          |> String.replace_prefix("#{target_name} ", "")

        String.starts_with?(msg, prefix <> over) ->
          msg
          |> String.replace_prefix(prefix <> over, "")
          |> String.replace_prefix("#{target_name}. ", "")

        true ->
          msg
      end
      |> String.trim_trailing(".")

    dgettext("engine", "en %{name}: %{result}", name: target_name, result: body)
  end

  defp resolve_save_spell(
         c,
         caster_name,
         t,
         target_name,
         spell,
         roller,
         roll_log,
         aura,
         heightened?,
         emp
       ) do
    dc = Combat.spell_save_dc(c, spell)
    # D65 Heightened: the armed target's save enters as requested
    # disadvantage (combines with conditions/Danger Sense via save_mode).
    # D71 Gnome Cunning: a gnome's mental save enters as an extra
    # advantage source — combine/2 cancels it against Heightened or a
    # condition's disadvantage (normal).
    # D76 Dwarven Resilience: a dwarf's save against a POISON spell
    # enters as an extra advantage source (same combination semantics).
    gnome? = gnome_cunning?(t, spell.save_ability)
    dwarf? = dwarven_resilience?(t, spell)
    requested = if heightened?, do: :disadvantage, else: :normal
    height_tag = if heightened?, do: dgettext("engine", " (Metamagia: Heightened)"), else: ""
    emp_tag = metamagic_tag(emp)

    case Conditions.save_mode(t, spell.save_ability, requested,
           gnome_advantage: gnome?,
           dwarf_advantage: dwarf?
         ) do
      :auto_fail ->
        {r2, close_dmg} =
          RollLog.open(
            roll_log,
            roller,
            caster_name,
            :damage,
            dgettext("engine", "daño de %{spell} (%{damage_type})",
              spell: Terms.spell(spell.name),
              damage_type: Terms.damage_type(spell.damage_type)
            )
          )

        full = dice_with(spell, r2, emp)
        RollLog.close(close_dmg, total: full, against: nil, outcome: nil)

        with_conc_damage(
          dgettext(
            "engine",
            "%{caster} conjura %{spell}; %{target} falla automáticamente la salvación de %{ability} vs CD %{dc}%{heightened} — %{amount} de %{damage}%{empowered}.",
            caster: caster_name,
            spell: Terms.spell(spell.name),
            target: target_name,
            ability: ability_es(spell.save_ability),
            dc: dc,
            heightened: height_tag,
            amount: full,
            damage: Terms.damage(spell.damage_type),
            empowered: emp_tag
          ),
          target_name,
          full,
          roller,
          roll_log,
          t,
          spell.damage_type,
          aura
        )

      {:roll, save_mode} ->
        {r, close_save} =
          RollLog.open(
            roll_log,
            roller,
            target_name,
            :save,
            dgettext("engine", "salvación de %{ability} contra %{spell}",
              ability: ability_es(spell.save_ability),
              spell: Terms.spell(spell.name)
            )
          )

        inspired? = t.inspired == true

        {d20, stotal, _success?, lucky} =
          Combat.saving_throw_tagged(t, spell.save_ability, dc, r, save_mode)

        # D61 Aura of Protection: added before bardic inspiration (which
        # re-derives success from the running total).
        stotal = stotal + aura
        {stotal, success?, bardic} = apply_inspired_vs_dc(t, stotal, dc, r)

        # D68 Indomitable: a fighter L9+ rerolls a FAILED save once per long
        # rest — the reroll decides the final outcome (aura re-applies; the
        # bardic die was consumed by the first attempt). The reroll goes
        # through the same roller/mode (Heightened/Danger Sense intact).
        {d20, stotal, success?, indom} =
          maybe_indomitable(
            t,
            spell.save_ability,
            dc,
            r,
            save_mode,
            {d20, stotal, success?},
            aura
          )

        # The reroll spends Indomitable: the updated struct rides into the
        # concentration simulation so a later CON save this same resolution
        # can't double-spend it.
        before_save = t
        t = if indom, do: %{t | indomitable_used: true}, else: t
        t = if inspired?, do: %{t | inspired: false}, else: t

        RollLog.close(close_save,
          total: stotal,
          against: {:dc, dc},
          outcome: if(success?, do: :success, else: :failure)
        )

        {r2, close_dmg} =
          RollLog.open(
            roll_log,
            roller,
            caster_name,
            :damage,
            dgettext("engine", "daño de %{spell} (%{damage_type})",
              spell: Terms.spell(spell.name),
              damage_type: Terms.damage_type(spell.damage_type)
            )
          )

        full = dice_with(spell, r2, emp)
        RollLog.close(close_dmg, total: full, against: nil, outcome: nil)

        # D59 Evasión: a rogue L7+ takes no damage on a successful DEX save
        # and half on a failed one. Incapacitated rogues are cut off by the
        # auto-fail set in Conditions.save_mode (they never roll here).
        evasion? = evasion?(t, spell)

        dmg =
          cond do
            success? and evasion? -> 0
            success? -> div(full, 2)
            evasion? -> div(full, 2)
            true -> full
          end

        bardic_bit =
          if bardic != 0,
            do: dgettext("engine", " +%{bardic} inspiración", bardic: bardic),
            else: ""

        aura_b = aura_bit(aura)
        lucky_b = lucky_suffix(lucky)
        indom_b = indom_suffix(indom)

        # D71/D76: when a racial advantage shaped the mode, its tag
        # replaces the generic "(ventaja)" — a cancelled advantage
        # (Heightened/condition) leaves the plain mode_tag (normal = "").
        mode_b =
          cond do
            gnome? and save_mode == :advantage ->
              dgettext("engine", " (Astucia gnoma: ventaja)")

            dwarf? and save_mode == :advantage ->
              dgettext("engine", " (Resistencia enana: ventaja)")

            true ->
              mode_tag(save_mode)
          end

        verdict =
          cond do
            success? and evasion? ->
              dgettext(
                "engine",
                "supera la salvación (d20 %{d20}%{lucky}%{indomitable}: %{total} vs CD %{dc}%{aura}%{bardic})%{mode}%{heightened} (Evasión: sin daño)",
                d20: d20,
                lucky: lucky_b,
                indomitable: indom_b,
                total: stotal,
                dc: dc,
                aura: aura_b,
                bardic: bardic_bit,
                mode: mode_b,
                heightened: height_tag
              )

            success? ->
              dgettext(
                "engine",
                "supera la salvación (d20 %{d20}%{lucky}%{indomitable}: %{total} vs CD %{dc}%{aura}%{bardic})%{mode}%{heightened}, mitad de daño",
                d20: d20,
                lucky: lucky_b,
                indomitable: indom_b,
                total: stotal,
                dc: dc,
                aura: aura_b,
                bardic: bardic_bit,
                mode: mode_b,
                heightened: height_tag
              )

            evasion? ->
              dgettext(
                "engine",
                "falla la salvación (d20 %{d20}%{lucky}%{indomitable}: %{total} vs CD %{dc}%{aura}%{bardic})%{mode}%{heightened} (Evasión: mitad)",
                d20: d20,
                lucky: lucky_b,
                indomitable: indom_b,
                total: stotal,
                dc: dc,
                aura: aura_b,
                bardic: bardic_bit,
                mode: mode_b,
                heightened: height_tag
              )

            true ->
              dgettext(
                "engine",
                "falla la salvación (d20 %{d20}%{lucky}%{indomitable}: %{total} vs CD %{dc}%{aura}%{bardic})%{mode}%{heightened}",
                d20: d20,
                lucky: lucky_b,
                indomitable: indom_b,
                total: stotal,
                dc: dc,
                aura: aura_b,
                bardic: bardic_bit,
                mode: mode_b,
                heightened: height_tag
              )
          end

        {:ok, msg, change} =
          with_conc_damage(
            dgettext(
              "engine",
              "%{caster} conjura %{spell}; %{target} %{verdict} — %{amount} de %{damage}%{empowered}.",
              caster: caster_name,
              spell: Terms.spell(spell.name),
              target: target_name,
              verdict: verdict,
              amount: dmg,
              damage: Terms.damage(spell.damage_type),
              empowered: emp_tag
            ),
            target_name,
            dmg,
            roller,
            roll_log,
            t,
            spell.damage_type,
            aura,
            before_save
          )

        {:ok, msg,
         compose_indomitable_mark(
           target_name,
           indom,
           compose_inspired_clear(target_name, inspired?, change)
         )}
    end
  end

  defp kept_d20(roller, mode) when mode in [:advantage, :disadvantage] do
    {kept, _, _} = Dice.roll_advantage(20, mode, roller)
    kept
  end

  defp kept_d20(roller, _), do: roller.(20)

  # D57: reveal a hidden caster once their attack spell resolves.
  defp clear_hidden_after_attack_spell({:ok, msg, change}, name, true) do
    {:ok, msg, compose_hidden_clear(name, true, change)}
  end

  defp clear_hidden_after_attack_spell(result, _name, false), do: result

  defp dice_with(%{dice: nil}, _roller, _emp), do: 0

  defp dice_with(%{dice: expr}, roller, emp) when emp > 0,
    do: empowered_roll(expr, roller, emp)

  defp dice_with(%{dice: expr}, roller, _emp), do: Dice.roll_expr(expr, roller)

  # D65 Empowered: the first `emp` dice of `NdM±K` roll twice keeping the
  # higher (deterministic: two roller draws per boosted die); the rest and
  # the flat modifier pass through unchanged.
  defp empowered_roll(expr, roller, emp) do
    {count, sides, mod} = Dice.parse_expr(expr)

    rolls =
      for i <- 1..count do
        if i <= emp, do: max(roller.(sides), roller.(sides)), else: roller.(sides)
      end

    Enum.sum(rolls) + mod
  end

  # D59 Evasión: rogue L7+ — no damage on a successful DEX save, half on a
  # failed one. The auto-fail conditions short-circuit DEX saves inside
  # Conditions.save_mode, so an incapacitated rogue never reaches the roll
  # branch that applies this (RAW "unless incapacitated").
  defp evasion?(%Character{} = target, %{save_ability: :dex}) do
    target.class == "rogue" and (target.level || 1) >= 7
  end

  defp evasion?(_target, _spell), do: false

  # D71 Gnome Cunning: advantage on INT/WIS/CHA saves against MAGIC. Engine
  # equivalence (ADR D71): every save that comes out of cast_spell's :save
  # branch and turn_undead (divine = magic) is "magic"; concentration (CON)
  # and DEX saves are out of the mental scope either way.
  defp gnome_cunning?(%Character{race: race}, ability) when ability in [:int, :wis, :cha] do
    is_binary(race) and String.downcase(race) == "gnome"
  end

  defp gnome_cunning?(_, _), do: false

  # D76 Dwarven Resilience: advantage on saving throws against poison.
  # Engine equivalence (ADR D76): every :save spell with
  # damage_type "poison" counts as "against poison" regardless of the
  # save ability (RAW 2014 wording). Injected only from cast_spell's
  # :save branch. NOTE: today the catalog has exactly one such spell
  # (SRD cloudkill, CON save 5d8 poison) — usable E2E, but rare; the
  # hook is future-proof for any poison spell that arrives.
  defp dwarven_resilience?(%Character{race: race}, %{damage_type: "poison"})
       when is_binary(race) do
    String.downcase(race) == "dwarf"
  end

  defp dwarven_resilience?(_, _), do: false

  # D74: the dart count rides the dice expression (3d4+3 → 3; 4d4+4 → 4 when
  # upcast), so the verb always reports the real number of darts.
  defp spell_damage_verb(%{name: "magic missile", dice: dice}, _dmg) when is_binary(dice) do
    {count, _sides, _mod} = Dice.parse_expr(dice)
    dgettext("engine", " (%{count} dardos de fuerza)", count: count)
  end

  defp spell_damage_verb(%{name: "magic missile"}, _dmg),
    do: dgettext("engine", " (3 dardos de fuerza)")

  defp spell_damage_verb(_spell, _dmg), do: ""

  defp describe_death_save(name, {:revive, _d20, _, _}, bardic, aura),
    do:
      dgettext("engine", "%{name} saca un 20 natural%{aura}%{bardic} — ¡revive con 1 pg!",
        name: name,
        aura: aura_death_bit(aura),
        bardic: bardic_death_bit(bardic)
      )

  defp describe_death_save(name, {:crit_fail, 1, _, _}, bardic, aura),
    do:
      dgettext(
        "engine",
        "%{name} saca un 1 natural%{aura}%{bardic} — ¡dos fallos de salvación de muerte!",
        name: name,
        aura: aura_death_bit(aura),
        bardic: bardic_death_bit(bardic)
      )

  defp describe_death_save(name, {:fail, d20, _, _}, bardic, aura),
    do:
      dgettext("engine", "%{name} saca %{d20}%{aura}%{bardic} — un fallo de salvación de muerte.",
        name: name,
        d20: d20,
        aura: aura_death_bit(aura),
        bardic: bardic_death_bit(bardic)
      )

  defp describe_death_save(name, {:success, d20, _, _}, bardic, aura),
    do:
      dgettext("engine", "%{name} saca %{d20}%{aura}%{bardic} — un éxito de salvación de muerte.",
        name: name,
        d20: d20,
        aura: aura_death_bit(aura),
        bardic: bardic_death_bit(bardic)
      )

  # D61: the aura shifts the 10 threshold, so the breakdown shows it.
  defp aura_death_bit(aura) when aura != 0,
    do: dgettext("engine", " (%{aura} aura)", aura: signed(aura))

  defp aura_death_bit(_), do: ""

  defp bardic_death_bit(n) when is_integer(n) and n > 0,
    do: dgettext("engine", " (+%{bardic} inspiración)", bardic: n)

  defp bardic_death_bit(_), do: ""

  # ----------------------------------------------------------------- helpers

  defp resolve_swings(
         a,
         t,
         attacker,
         target,
         weapon,
         roller,
         roll_log,
         mode,
         first_mode,
         n,
         sneak,
         smite,
         inspired?,
         mark?,
         aura
       ) do
    {swings, _target, _sneak, _smite, _inspired} =
      Enum.reduce_while(1..n, {[], t, sneak, smite, inspired?}, fn i,
                                                                   {acc, current_target,
                                                                    sneak_left, smite_left,
                                                                    inspired_left} ->
        # A target that DROPS mid-action stops the remaining swings (no
        # retarget) — but a target that was ALREADY downed when the action
        # started keeps receiving every swing (RAW: you can attack a dying
        # creature; each hit registers death-save fails via apply_damage).
        if current_target.hp <= 0 and t.hp > 0 do
          {:halt, {acc, current_target, sneak_left, smite_left, inspired_left}}
        else
          # D95: solo el PRIMER swing hereda la ventaja de la marca guiada.
          swing_mode = if(i == 1 and first_mode != nil, do: first_mode, else: mode)

          swing =
            resolve_one_swing(
              if(t.concentrating == "bless" and current_target.concentrating != "bless",
                do: Effects.without_source(a, target),
                else: a
              ),
              current_target,
              attacker,
              target,
              weapon,
              roller,
              roll_log,
              swing_mode,
              sneak_left,
              smite_left,
              inspired_left,
              mark?
            )

          {notes, change, next_target} =
            if swing.dmg + swing.smite > 0 do
              Dragonex.Damage.prepare(current_target, swing.dmg, weapon.damage_type, roller,
                crit: swing.kind == :crit,
                additional_damage: [{swing.smite, "radiant"}],
                aura: aura,
                roll_log: roll_log,
                attacker: attacker,
                attacker_side: a.side
              )
            else
              {[], noop(), current_target}
            end

          swing = Map.merge(swing, %{damage_notes: notes, damage_change: change})
          sneak_left = if swing.sneak > 0, do: nil, else: sneak_left
          smite_left = if swing.smite > 0, do: nil, else: smite_left
          {:cont, {acc ++ [swing], next_target, sneak_left, smite_left, false}}
        end
      end)

    swings
  end

  defp target_ac(%Character{} = c), do: Effects.effective_ac(c)

  defp guard_target_defense({:ok, message, change}, before, target, :attack) do
    keys = [:ac, :fighting_style, :conditions]
    expected = Map.take(World.present_character(before, target), keys)

    {:ok, message,
     fn current ->
       case World.present_character(current, target) do
         %Character{} = c ->
           if Map.take(c, keys) == expected,
             do: change.(current),
             else:
               {:error,
                dgettext(
                  "engine",
                  "la defensa de %{target} ha cambiado; vuelve a resolver el ataque",
                  target: target
                )}

         nil ->
           {:error, dgettext("engine", "no existe el objetivo: %{target}", target: target)}
       end
     end}
  end

  defp guard_target_defense(result, _world, _target, _kind), do: result

  # RAW auto-crit vs incapacitating conditions: a melee HIT against a
  # paralyzed or unconscious target is a critical (doubled damage dice —
  # the :crit flows into Combat.damage_roll_tagged). Ranged attacks and
  # misses never upgrade; nat 20 was already :crit.
  defp auto_crit_vs_incapacitated(:hit, %Character{} = t, %Weapon{ranged: ranged})
       when ranged != true do
    conds = Character.condition_names(t)

    if "paralyzed" in conds or "unconscious" in conds, do: :crit, else: :hit
  end

  defp auto_crit_vs_incapacitated(kind, _t, _weapon), do: kind

  defp resolve_one_swing(
         a,
         t,
         attacker,
         target,
         weapon,
         roller,
         roll_log,
         mode,
         sneak,
         smite,
         inspired?,
         mark?
       ) do
    {r, close_atk} =
      RollLog.open(
        roll_log,
        roller,
        attacker,
        :attack,
        dgettext("engine", "ataque a %{target} con %{weapon}",
          target: target,
          weapon: Terms.weapon(weapon.name)
        )
      )

    ac = target_ac(t)
    {kind, d20, total, lucky} = Combat.attack_roll_tagged(a, weapon, ac, r, mode)
    {kind, total, bardic} = apply_inspired_attack(inspired?, kind, d20, total, ac, r)
    # RAW: any attack that HITS a paralyzed/unconscious target from within
    # 5 ft is a critical hit. The engine has no positioning, so the proxy
    # is melee weapons; the advantage those conditions grant (attack_mode)
    # is unchanged. Misses stay misses.
    kind = auto_crit_vs_incapacitated(kind, t, weapon)
    RollLog.close(close_atk, total: total, against: {:ac, ac}, outcome: kind)

    case kind do
      :miss ->
        %{
          kind: :miss,
          ac: ac,
          d20: d20,
          total: total,
          dmg: 0,
          sneak: 0,
          rage: 0,
          smite: 0,
          smite_dice: 0,
          savage: 0,
          mark: 0,
          bardic: bardic,
          lucky: lucky
        }

      k ->
        {r2, close_dmg} =
          RollLog.open(
            roll_log,
            roller,
            attacker,
            :damage,
            dgettext("engine", "%{damage} a %{target}",
              damage: Terms.damage(weapon.damage_type),
              target: target
            )
          )

        {dmg, savage_dmg} = Combat.damage_roll_tagged(a, weapon, k, r2)
        sneak_dmg = sneak_damage(sneak, k, r2)
        rage_dmg = rage_bonus(a, weapon)
        mark_dmg = mark_damage(mark?, k, r2)
        raw_dmg = dmg + sneak_dmg + rage_dmg + mark_dmg
        total_dmg = Combat.damage_total(raw_dmg)

        damage_summary = [
          total: total_dmg,
          against: nil,
          outcome: if(k == :crit, do: :crit, else: nil)
        ]

        damage_summary =
          if raw_dmg < 0,
            do: Keyword.put(damage_summary, :raw_total, raw_dmg),
            else: damage_summary

        RollLog.close(close_dmg, damage_summary)

        {smite_dmg, smite_dice} = smite_roll(smite, t, attacker, target, roller, roll_log)

        %{
          kind: k,
          ac: ac,
          d20: d20,
          total: total,
          dmg: total_dmg,
          sneak: sneak_dmg,
          rage: rage_dmg,
          smite: smite_dmg,
          smite_dice: smite_dice,
          savage: savage_dmg,
          mark: mark_dmg,
          bardic: bardic,
          lucky: lucky
        }
    end
  end

  defp format_attack_message(attacker, target, _weapon, ac, mode, [%{kind: :miss} = s]) do
    dgettext(
      "engine",
      "%{attacker} lanza un golpe a %{target} — fallo (d20 %{d20}%{lucky}: %{total} vs CA %{ac})%{bardic}%{mode}.",
      attacker: attacker,
      target: target,
      d20: s.d20,
      lucky: lucky_tag(s),
      total: s.total,
      ac: ac,
      bardic: bardic_tag(s),
      mode: mode_tag(mode)
    )
  end

  defp format_attack_message(attacker, target, weapon, ac, mode, [s]) do
    verb =
      if s.kind == :crit, do: dgettext("engine", "CRÍTICO"), else: dgettext("engine", "acierta")

    dgettext(
      "engine",
      "%{attacker} %{verb} a %{target} (d20 %{d20}%{lucky}: %{total} vs CA %{ac}) por %{amount} de %{damage} en total%{inclusions}%{smite}%{bardic}%{mode}.",
      attacker: attacker,
      verb: verb,
      target: target,
      d20: s.d20,
      lucky: lucky_tag(s),
      total: s.total,
      ac: ac,
      amount: s.dmg,
      damage: Terms.damage(weapon.damage_type),
      inclusions: damage_inclusions(s),
      smite: smite_tag(s),
      bardic: bardic_tag(s),
      mode: mode_tag(mode)
    )
  end

  defp format_attack_message(attacker, target, weapon, ac, mode, swings) do
    parts = Enum.map_join(swings, "; ", &describe_swing(&1, weapon, ac))

    dgettext("engine", "%{attacker} ataca a %{target} (%{count} golpes)%{mode}: %{parts}.",
      attacker: attacker,
      target: target,
      count: length(swings),
      mode: mode_tag(mode),
      parts: parts
    )
  end

  defp describe_swing(%{kind: :miss, d20: d20, total: total} = s, _weapon, ac) do
    ac = Map.get(s, :ac, ac)

    dgettext("engine", "fallo (d20 %{d20}%{lucky}: %{total} vs CA %{ac})%{bardic}",
      d20: d20,
      lucky: lucky_tag(s),
      total: total,
      ac: ac,
      bardic: bardic_tag(s)
    )
  end

  defp describe_swing(%{kind: k, d20: d20, total: total, dmg: dmg} = s, weapon, ac) do
    ac = Map.get(s, :ac, ac)
    verb = if k == :crit, do: dgettext("engine", "CRÍTICO"), else: dgettext("engine", "acierta")

    dgettext(
      "engine",
      "%{verb} (d20 %{d20}%{lucky}: %{total} vs CA %{ac}) por %{amount} de %{damage} en total%{inclusions}%{smite}%{bardic}",
      verb: verb,
      d20: d20,
      lucky: lucky_tag(s),
      total: total,
      ac: ac,
      amount: dmg,
      damage: Terms.damage(weapon.damage_type),
      inclusions: damage_inclusions(s),
      smite: smite_tag(s),
      bardic: bardic_tag(s)
    )
  end

  # Amounts carry the per-hit damage opts for `World.apply_damage/5`: weapon
  # swings pass their crit flag (RAW: a critical registers TWO death-save
  # fails on a downed target); the smite pipe passes `death_fail: false`
  # (the weapon damage of the SAME hit already registered it).
  defp pipe_attack_damage(_target, swings, _roller, _roll_log, _char, _weapon_type, _aura) do
    change = fn w ->
      Enum.reduce_while(swings, {:ok, w}, fn swing, {:ok, acc} ->
        case swing.damage_change.(acc) do
          {:ok, next} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end
      end)
    end

    {Enum.flat_map(swings, & &1.damage_notes), change}
  end

  defp compose_smite_spend(attacker, slot, swings, change) do
    if is_integer(slot) and slot in 1..5 and Enum.any?(swings, &(&1.smite > 0)) do
      fn w ->
        with {:ok, w} <- change.(w),
             {:ok, w} <- World.consume_slot(attacker, slot).(w) do
          World.set_smite_slot(attacker, nil).(w)
        end
      end
    else
      change
    end
  end

  defp compose_concentration(result, _caster, %{name: "bless"}), do: result
  defp compose_concentration(result, _caster, %{name: "shield of faith"}), do: result
  defp compose_concentration(result, _caster, %{name: "hold person"}), do: result
  defp compose_concentration(result, _caster, %{name: "faerie fire"}), do: result
  defp compose_concentration(result, _caster, %{name: "spirit guardians"}), do: result

  defp compose_concentration({:ok, msg, change}, caster, spell) do
    if Spells.concentration?(spell.name) do
      combined = fn w ->
        case change.(w) do
          {:ok, w2} -> World.set_concentration(caster, spell.name).(w2)
          error -> error
        end
      end

      {:ok,
       dgettext("engine", "%{result} %{caster} concentra en %{spell}.",
         result: msg,
         caster: caster,
         spell: Terms.spell(spell.name)
       ), combined}
    else
      {:ok, msg, change}
    end
  end

  defp compose_concentration(result, _caster, _spell), do: result

  defp with_conc_damage(
         msg,
         target_name,
         amount,
         roller,
         roll_log,
         target_char,
         type,
         aura,
         expected_target \\ nil
       ) do
    {notes, change, _char} =
      pipe_damage(
        target_name,
        [amount],
        roller,
        roll_log,
        target_char,
        type,
        aura,
        expected_target
      )

    {:ok, append_notes(msg, notes), change}
  end

  # D68: pipe_damage threads the simulated character through each amount's
  # concentration save, so a reroll that spent Indomitable blocks a second
  # reroll on the next hit of the same action.
  #
  # Amounts are `{amount, damage_opts}` pairs for `World.apply_damage/5`
  # (crit flag / death_fail skip — see swing_amounts); a bare integer rides
  # with default opts (spells and friends). A target that was already DOWN
  # when the pipe started keeps taking every amount (RAW: damage at 0 hp
  # registers death-save fails); one that drops mid-pipe stops the rest (no
  # retarget) — `char` is the target at the pipe's start.
  defp pipe_damage(_target, amounts, roller, roll_log, char, type, aura, expected_target) do
    Enum.reduce(Enum.with_index(amounts), {[], noop(), char}, fn {entry, index},
                                                                 {notes, prior, c} ->
      {amount, opts} = if is_tuple(entry), do: entry, else: {entry, []}

      if amount <= 0 or (char.hp > 0 and c.hp <= 0) do
        {notes, prior, c}
      else
        {more, change, next} =
          Dragonex.Damage.prepare(
            c,
            amount,
            type,
            roller,
            Keyword.merge(opts,
              aura: aura,
              roll_log: roll_log,
              expected_target: if(index == 0, do: expected_target || c, else: c)
            )
          )

        combined = fn w ->
          with {:ok, w} <- prior.(w), do: change.(w)
        end

        {notes ++ more, combined, next}
      end
    end)
  end

  defp append_notes(msg, []), do: msg
  defp append_notes(msg, notes), do: msg <> " " <> Enum.join(notes, " ")

  @incapacitating_ally ~w(unconscious incapacitated stunned paralyzed petrified)

  defp sneak_opts(world, attacker, attacker_name, target_name, weapon, mode) do
    dice = Progression.sneak_attack_dice(attacker.class, attacker.level)
    weapon_ok? = weapon.finesse == true or weapon.ranged == true

    circumstance? =
      case mode do
        :disadvantage -> false
        :advantage -> true
        _ -> conscious_ally?(world, attacker, attacker_name, target_name)
      end

    spent? =
      world.phase == :combat and
        get_in(world.turn_state, [attacker_name, "sneak_turn"]) ==
          Dragonex.TurnBudget.turn_id(world)

    if dice > 0 and weapon_ok? and circumstance? and not spent?, do: %{dice: dice}, else: nil
  end

  defp compose_sneak_spend(name, swings, change) do
    fn w ->
      with {:ok, next} <- change.(w) do
        if next.phase == :combat and Enum.any?(swings, &(&1.sneak > 0)) do
          state =
            Map.get(next.turn_state, name, %{})
            |> Map.put("sneak_turn", Dragonex.TurnBudget.turn_id(next))

          {:ok, %{next | turn_state: Map.put(next.turn_state, name, state)}}
        else
          {:ok, next}
        end
      end
    end
  end

  defp conscious_ally?(
         %World{} = world,
         %Character{} = attacker,
         attacker_name,
         target_name
       ) do
    Enum.any?(World.present_characters(world), fn {name, c} ->
      name != attacker_name and name != target_name and c.side == attacker.side and
        (c.hp || 0) > 0 and
        not Enum.any?(Character.condition_names(c), &(&1 in @incapacitating_ally))
    end)
  end

  defp sneak_damage(nil, _kind, _roller), do: 0

  defp sneak_damage(%{dice: n}, kind, roller) when n > 0 do
    count = if kind == :crit, do: n * 2, else: n
    Enum.sum(for _ <- 1..count, do: roller.(6))
  end

  # These physical contributions are already in dmg; presenting them as +N
  # after that total invites the narrator to add them twice. Smite is separate.
  defp damage_inclusions(swing) do
    included =
      for key <- [:savage, :sneak, :rage, :mark],
          amount = Map.get(swing, key, 0),
          is_integer(amount) and amount > 0 do
        "#{amount} #{inclusion_label(key)}"
      end

    if included == [],
      do: "",
      else: dgettext("engine", " (incluye %{items})", items: Enum.join(included, ", "))
  end

  defp inclusion_label(:savage), do: dgettext("engine", "Savage")
  defp inclusion_label(:sneak), do: dgettext("engine", "sneak")
  defp inclusion_label(:rage), do: dgettext("engine", "furia")
  defp inclusion_label(:mark), do: dgettext("engine", "presa marcada")

  @mark_prefix "hunter's mark:"

  # D55: the attacker concentrates on "hunter's mark:<prey>" — exact
  # case-insensitive name match, never fuzzy (a similar name doesn't count).
  defp mark_target?(%Character{concentrating: conc}, target)
       when is_binary(conc) and is_binary(target) do
    conc = String.downcase(conc)

    if String.starts_with?(conc, @mark_prefix) do
      String.replace_prefix(conc, @mark_prefix, "") == String.downcase(target)
    else
      false
    end
  end

  defp mark_target?(_, _), do: false

  defp mark_damage(false, _kind, _roller), do: 0

  defp mark_damage(true, kind, roller) do
    count = if kind == :crit, do: 2, else: 1
    Enum.sum(for _ <- 1..count, do: roller.(6))
  end

  defp rage_bonus(%Character{raging: true, level: level}, weapon) when weapon.ranged != true do
    Progression.rage_damage(level)
  end

  defp rage_bonus(_, _), do: 0

  defp smite_opts(%Character{class: "paladin", smite_slot: slot}, weapon)
       when is_integer(slot) and slot in 1..5 and weapon.ranged != true,
       do: slot

  defp smite_opts(_, _), do: nil

  defp smite_roll(nil, _target, _attacker, _tname, _roller, _roll_log), do: {0, 0}

  defp smite_roll(slot, target, attacker, tname, roller, roll_log) when is_integer(slot) do
    n = smite_dice(slot, target)

    {r, close} =
      RollLog.open(
        roll_log,
        roller,
        attacker,
        :damage,
        dgettext("engine", "Castigo divino (radiante) a %{target}", target: tname)
      )

    amount = Enum.sum(for _ <- 1..n, do: r.(8))
    RollLog.close(close, total: amount, against: nil, outcome: nil)
    {amount, n}
  end

  defp smite_dice(slot, %Character{race: race}) do
    base = min(slot + 1, 5)
    extra = if smite_foe?(race), do: 1, else: 0
    min(base + extra, 6)
  end

  defp smite_foe?(race) when is_binary(race) do
    String.downcase(race) in ["undead", "fiend"]
  end

  defp smite_foe?(_), do: false

  defp smite_tag(%{smite: n, smite_dice: d}) when is_integer(n) and n > 0 do
    dgettext("engine", " (+%{amount} smite %{dice}d8 radiante, adicional)", amount: n, dice: d)
  end

  defp smite_tag(_), do: ""

  defp bardic_tag(%{bardic: n}) when is_integer(n) and n > 0,
    do: dgettext("engine", " (ataque: incluye %{bardic} inspiración)", bardic: n)

  defp bardic_tag(_), do: ""

  # D66 Lucky: the tagged roll returns the reroll note ("(Lucky: 1→N)") —
  # render it right after the die value (mode_tag pattern).
  defp lucky_tag(%{lucky: tag}) when is_binary(tag), do: " #{tag}"

  defp lucky_tag(_), do: ""

  defp lucky_suffix(nil), do: ""

  defp lucky_suffix(tag) when is_binary(tag), do: " #{tag}"

  # D68 Indomitable: a fighter of level 9+ rerolls a FAILED saving throw
  # once per long rest — the NEW total is used (RAW), whatever it is. The
  # reroll is the SAME `saving_throw_tagged` call with the same arguments,
  # so the mode (Heightened D65, Danger Sense D58, conditions) still shapes
  # it and Lucky (D66) can fire on the reroll for free. `extra` is the flat
  # bonus the site already added to the first roll (the D61 aura) — it
  # re-applies to the reroll; the bardic die was consumed by the first
  # attempt and never re-rolls. Auto-fails never reach here (no die rolled).
  # Returns the final {d20, total, success?} plus a breakdown tag (nil when
  # it didn't fire) — the site marks `indomitable_used` on a non-nil tag.
  defp maybe_indomitable(
         %Character{} = t,
         ability,
         dc,
         roller,
         mode,
         {d20, total, success?},
         extra
       ) do
    if success? or not indomitable?(t) do
      {d20, total, success?, nil}
    else
      {d20_2, total_2, _success?, lucky_2} =
        Combat.saving_throw_tagged(t, ability, dc, roller, mode)

      total_2 = total_2 + extra

      tag =
        dgettext("engine", "(Indomitable: %{before}→%{after})", before: total, after: total_2) <>
          lucky_suffix(lucky_2)

      {d20_2, total_2, total_2 >= dc, tag}
    end
  end

  # Fighter L9+, use still unspent this long-rest cycle.
  defp indomitable?(%Character{class: "fighter", level: level, indomitable_used: false})
       when is_integer(level) and level >= 9,
       do: true

  defp indomitable?(_), do: false

  defp indom_suffix(nil), do: ""

  defp indom_suffix(tag) when is_binary(tag), do: " #{tag}"

  # D68: a fired reroll spends Indomitable (composed into the site's change).
  defp compose_indomitable_mark(_name, nil, change), do: change

  defp compose_indomitable_mark(name, _tag, change) do
    fn w ->
      with {:ok, w} <- change.(w) do
        World.set_indomitable(name, true).(w)
      end
    end
  end

  defp apply_inspired_attack(true, _kind, d20, total, ac, roller) do
    bonus = roller.(6)
    new_total = total + bonus

    new_kind =
      cond do
        d20 == 20 -> :crit
        d20 == 1 -> :miss
        new_total >= ac -> :hit
        true -> :miss
      end

    {new_kind, new_total, bonus}
  end

  defp apply_inspired_attack(_, kind, _d20, total, _ac, _roller), do: {kind, total, 0}

  defp apply_inspired_vs_dc(%Character{inspired: true}, total, dc, roller) do
    bonus = roller.(6)
    new_total = total + bonus
    {new_total, new_total >= dc, bonus}
  end

  defp apply_inspired_vs_dc(_, total, dc, _), do: {total, total >= dc, 0}

  # D61: the aura already shaped `result` (Combat.death_save/2); re-deriving
  # the outcome with bardic must keep it in the total.
  defp apply_inspired_death(%Character{inspired: true}, result, roller, aura) do
    d20 = elem(result, 1)
    bonus = roller.(6)

    new_result =
      case result do
        {:revive, _, _, _} -> result
        {:crit_fail, _, _, _} -> result
        _ when d20 + aura + bonus >= 10 -> {:success, d20, 0, 1}
        _ -> {:fail, d20, 1, 0}
      end

    {new_result, bonus}
  end

  defp apply_inspired_death(_, result, _, _), do: {result, 0}

  # D61 Aura of Protection: every conscious paladin (L6+) on the saver's side
  # shares their CHA modifier with ALL saves of that side (the paladin
  # included). Multiple paladins stack (RAW); a CHA below 10 gives a negative
  # bonus with no floor (RAW). 0 when the side has none. The computation
  # moved to `World.aura_save_bonus/2` so the D72 Relentless Rage save inside
  # `World.apply_damage/4` rides the same bonus.
  defp aura_save_bonus(%World{} = world, name), do: World.aura_save_bonus(world, name)

  # Breakdown bit for save messages: " +3 aura" / " -1 aura".
  defp aura_bit(aura) when aura != 0, do: dgettext("engine", " %{aura} aura", aura: signed(aura))
  defp aura_bit(_), do: ""

  defp compose_inspired_clear(_name, false, change), do: change

  defp compose_inspired_clear(name, true, change) do
    fn w ->
      with {:ok, w} <- change.(w) do
        World.set_inspired(name, false).(w)
      end
    end
  end

  # D57: an attack (or attack spell) reveals a hidden attacker — strip
  # "hidden" once the change resolves, hit or miss.
  defp compose_hidden_clear(_name, false, change), do: change

  defp compose_hidden_clear(name, true, change) do
    fn w ->
      with {:ok, w} <- change.(w) do
        World.remove_condition(name, "hidden").(w)
      end
    end
  end

  # D95: hojas rancias — rellena SOLO los campos nil de la ficha con el
  # catálogo (`Heroes.Spells.get/1`, builtin gana al SRD). Las hojas
  # persistidas antes de los builtin (sacred flame con `dice: null`) se
  # corrigen al lanzar sin migración. `custom_*` queda fuera: su definición
  # vive en el bundle inyectado, no en el catálogo.
  defp overlay_catalog(%Spell{name: name} = spell) do
    if String.starts_with?(name, "custom_") do
      spell
    else
      case Spells.get(name) do
        %{dice: dice, save_ability: save_ability, damage_type: damage_type} ->
          %{
            spell
            | dice: non_empty(spell.dice) || dice,
              save_ability: spell.save_ability || save_ability,
              damage_type: non_empty(spell.damage_type) || damage_type
          }

        nil ->
          spell
      end
    end
  end

  defp non_empty(""), do: nil
  defp non_empty(value), do: value

  # D95 Guiding Bolt: al IMPACTAR, el objetivo queda guiado — la próxima
  # tirada de ataque contra él gana ventaja. Compone tras el daño.
  defp mark_guided_on_hit({:ok, msg, change}, %Spell{} = spell, caster, target) do
    if guiding_bolt?(spell) do
      {:ok, msg,
       fn w ->
         with {:ok, w} <- change.(w) do
           World.mark_guided(target, caster).(w)
         end
       end}
    else
      {:ok, msg, change}
    end
  end

  defp mark_guided_on_hit(result, _spell, _caster, _target), do: result

  defp guiding_bolt?(%Spell{name: name}),
    do: name |> String.downcase() |> String.replace(~r/[\s_-]+/, "") == "guidingbolt"

  # D95 Guiding Bolt: la tirada de ataque que consumió la marca la retira
  # acierte o falle — compónela SIEMPRE detrás de un eventual mark nuevo
  # (consume la marca vieja, aplica la fresca).
  defp consume_guided_after_roll({:ok, msg, change}, target, true) do
    {:ok, msg,
     fn w ->
       with {:ok, w} <- change.(w) do
         World.consume_guided(target).(w)
       end
     end}
  end

  defp consume_guided_after_roll(result, _target, false), do: result

  # D95: variante de compose para la cadena de cambios de do_attack (la
  # marca la consumió el primer swing de esta acción, acierte o falle).
  defp consume_guided_change(_target, false, change), do: change

  defp consume_guided_change(target, true, change) do
    fn w ->
      with {:ok, w} <- change.(w) do
        World.consume_guided(target).(w)
      end
    end
  end

  defp find_weapon(%Character{weapons: weapons}, name), do: match_named(weapons, name)

  defp find_spell(%Character{spells: spells}, name), do: match_named(spells, name)

  @doc "Read the same weapon definition used by attack resolution, without rolling or mutating."
  def weapon_definition(%World{} = world, attacker, name) when is_binary(name) do
    case World.present_character(world, attacker) do
      %Character{} = character -> find_weapon(character, name)
      _ -> nil
    end
  end

  def weapon_definition(_world, _attacker, _name), do: nil

  @doc false
  def unique_weapon_definition(weapons, name) when is_list(weapons) and is_binary(name) do
    case matching_named(weapons, name) do
      [weapon] -> weapon
      _ -> nil
    end
  end

  def unique_weapon_definition(_weapons, _name), do: nil

  @doc false
  def same_weapon_name?(left, right) when is_binary(left) and is_binary(right),
    do: normalized_name(left) == normalized_name(right)

  def same_weapon_name?(_left, _right), do: false

  @doc "Read the same spell definition/name used by resolution, without rolling or mutating."
  def spell_definition(%World{} = world, caster, name) when is_binary(name) do
    case World.present_character(world, caster) do
      %Character{} = character -> find_spell(character, name)
      _ -> nil
    end
  end

  def spell_definition(_world, _caster, _name), do: nil

  defp false_life?(%{name: name, dice: dice}) when dice in [nil, ""] and is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[\s_-]+/, "")
    |> Kernel.==("falselife")
  end

  defp false_life?(_), do: false

  # Fuzzy name lookup for weapons/spells: the LLM often says "sword" for
  # "longsword", "firebolt" for "fire bolt", or varies casing. We match
  # case/space-insensitively first, then fall back to a substring containment
  # (both directions) so a short or approximate name still resolves.
  defp match_named(items, name), do: items |> matching_named(name) |> List.first()

  defp matching_named(items, name) do
    n = normalized_name(name)

    case Enum.filter(items, &(normalized_name(&1.name) == n)) do
      [] ->
        Enum.filter(items, fn item ->
          iname = normalized_name(item.name)
          String.contains?(iname, n) or String.contains?(n, iname)
        end)

      exact ->
        exact
    end
  end

  defp normalized_name(name),
    do: name |> String.downcase() |> String.replace(~r/[\s_-]+/, "")

  defp compose_rest(name, heal_amount, restore_slots?, kind, dice_spent) do
    fn w ->
      with {:ok, w} <- Dragonex.Rest.complete(w, name, kind, dice_spent),
           {:ok, w} <-
             World.heal(
               name,
               if(kind == :long, do: World.present_character(w, name).max_hp, else: heal_amount)
             ).(w),
           {:ok, w} <- maybe_restore_slots(w, name, restore_slots?),
           {:ok, w} <- World.set_second_wind_used(name, false).(w),
           {:ok, w} <- World.set_action_surge_used(name, false).(w),
           {:ok, w} <- World.set_channel_divinity_used(name, false).(w),
           {:ok, w} <- World.restore_ki(name).(w),
           {:ok, w} <- World.restore_wild_shape_uses(name).(w),
           {:ok, w} <- World.set_breath_weapon_used(name, false).(w),
           {:ok, w} <- World.set_relentless_rage_successes(name, 0).(w) do
        c = World.present_character(w, name)

        if c.class == "bard" and c.level >= 5,
          do: World.restore_bardic_inspiration(name).(w),
          else: {:ok, w}
      end
    end
  end

  defp compose_long_rest(name, heal_amount) do
    fn w ->
      with {:ok, w} <- compose_rest(name, heal_amount, true, :long, 0).(w),
           {:ok, w} <- World.restore_lay_on_hands(name).(w),
           {:ok, w} <- World.restore_divine_sense(name).(w),
           {:ok, w} <- World.restore_bardic_inspiration(name).(w),
           {:ok, w} <- World.set_inspired(name, false).(w),
           {:ok, w} <- World.set_arcane_recovery_used(name, false).(w),
           {:ok, w} <- World.restore_sorcery_points(name).(w),
           {:ok, w} <- World.set_relentless_endurance(name, false).(w),
           {:ok, w} <- World.set_indomitable(name, false).(w),
           {:ok, w} <- World.set_rage_uses_used(name, 0).(w),
           {:ok, w} <- World.set_relentless_rage_successes(name, 0).(w),
           {:ok, w} <- World.clear_temp_hp(name).(w) do
        {:ok, w}
      end
    end
  end

  defp compose_mark_action_surge(who, change) do
    fn w ->
      with {:ok, w} <- change.(w) do
        World.set_action_surge_used(who, true).(w)
      end
    end
  end

  defp compose_spend_ki(who, change) do
    fn w ->
      with {:ok, w} <- change.(w) do
        World.spend_ki(who, 1).(w)
      end
    end
  end

  # Font of Magic (D56): spend points first, then grant the slot. The chain
  # re-validates, so a mid-chain failure leaves the world untouched.
  defp compose_create_slot(who, level, cost) do
    fn w ->
      with {:ok, w} <- World.spend_sorcery_points(who, cost).(w) do
        World.gain_slot(who, level).(w)
      end
    end
  end

  defp compose_convert_slot(who, level) do
    fn w ->
      with {:ok, w} <- World.consume_slot(who, level).(w) do
        World.gain_sorcery_points(who, level).(w)
      end
    end
  end

  defp maybe_restore_slots(w, name, true), do: World.restore_slots(name).(w)
  defp maybe_restore_slots(w, _name, false), do: {:ok, w}

  defp noop, do: fn w -> {:ok, w} end

  defp sum(count, sides, roller), do: Enum.sum(for _ <- 1..count, do: roller.(sides))

  defp signed(n) when n >= 0, do: "+#{n}"
  defp signed(n), do: "#{n}"

  defp mode_tag(:advantage), do: dgettext("engine", " (ventaja)")
  defp mode_tag(:disadvantage), do: dgettext("engine", " (desventaja)")
  defp mode_tag(_), do: ""

  @ability_keys ~w(str dex con int wis cha)a

  # Spanish label for roll reasons (shown to players in the chat & dice modal).
  defp ability_es(a) when is_atom(a),
    do: if(a in @ability_keys, do: Translations.ability(a), else: inspect(a))

  defp ability_es(s) when is_binary(s) do
    case Dragonex.Rules.Ability.parse(s) do
      {:ok, atom} -> ability_es(atom)
      :error -> s
    end
  end
end
