defmodule Dragonex.Tools do
  @moduledoc """
  The game's model-callable tools. Built with `use ExAgent.Tools`, so each
  tool's JSON Schema is derived from its `::` type annotations.

  Every tool reads what it needs from `ctx.deps`, which is a map bundling:
    * `:state` — the ExAgent.Session.SharedState handle (propose world changes)
    * `:roller` — a (sides -> value) dice fn (injected so tests are deterministic)
  """

  use ExAgent.Tools

  @doc "Narrate and set the current scene."
  deftool set_scene(ctx, narration :: String.t()) do
    # Model text reaching persistent world state must be scrubbed (D7): a scene
    # is echoed to every agent every turn, so scrubbing closes a prompt-injection
    # amplifier.
    {:ok, _} = propose(ctx, Dragonex.World.set_scene(Dragonex.Text.scrub(narration)))
    {:ok, "escena establecida"}
  end

  @doc """
  Record a durable narrative fact ("Un mensajero del Concejo entregó un pergamino",
  "Thane descubrió una puerta oculta"). Facts persist in the world and are shown
  to every agent each turn, so the partida's concrete state survives history
  truncation and hooks don't get dropped or re-introduced. Call this whenever you
  introduce or reveal something concrete the party should remember.
  """
  deftool establish_fact(ctx, fact :: String.t()) do
    # Facts are canonical world state surfaced to every agent each turn — scrub
    # before persisting so a tainted fact can't poison all future contexts (D7).
    {:ok, _} = propose(ctx, Dragonex.World.add_fact(Dragonex.Text.scrub(fact)))
    {:ok, "hecho registrado"}
  end

  # --- legacy spike stubs ----------------------------------------------------
  # These apply a raw effect without rolling — they predate the rules engine and
  # are kept only so the original exAgent capability tests (combat/round-robin,
  # multi-participant, dice) keep exercising the framework. The real,
  # rules-driven versions are `make_attack` and `roll_dice` below. Retire once
  # those flows migrate.

  @doc "Attack a target for `damage` hp (after a successful hit roll elsewhere)."
  deftool attack(ctx, target :: String.t(), damage :: integer()) do
    case propose(ctx, Dragonex.World.apply_damage(target, damage)) do
      {:ok, _} -> {:ok, "#{target} recibe #{damage} de daño"}
      {:error, _} = e -> e
    end
  end

  @doc "Roll a single d`n` and report the result to the model."
  deftool roll(ctx, sides :: pos_integer()) do
    roller = ctx.deps.roller
    {:ok, "salió #{roller.(sides)} (d#{sides})"}
  end

  @doc "Add a character to the world with the given hp."
  deftool spawn_character(ctx, name :: String.t(), hp :: integer()) do
    c =
      Dragonex.Character.new(
        name: name,
        class: "monster",
        hp: hp,
        max_hp: hp,
        ac: 10,
        side: "enemy"
      )

    {:ok, _} = propose(ctx, Dragonex.World.add_character(c))
    {:ok, "#{name} aparece (#{hp} pg)"}
  end

  @doc "Advance to the next round."
  deftool next_round(ctx) do
    {:ok, _} = propose(ctx, Dragonex.World.next_round())
    {:ok, "ronda avanzada"}
  end

  # --- real bridge tools (Rules -> World) -------------------------------
  # These resolve intents through Dragonex.Actions (deterministic math) and
  # propose the resulting change. The LLM only ever sees the returned message;
  # it never computes damage, hit chance or saves itself.

  @doc "Roll `count` d`sides`, optionally with advantage/disadvantage."
  deftool roll_dice(ctx, count :: pos_integer(), sides :: pos_integer()) do
    {:ok, msg} =
      Dragonex.Actions.roll(count, sides, :normal, ctx.deps.roller, ctx.deps[:roll_log])

    {:ok, msg}
  end

  @doc "Roll initiative for every conscious combatant and begin combat."
  deftool roll_initiative(ctx) do
    with {:ok, msg, change} <-
           Dragonex.Actions.initiative(world(ctx), ctx.deps.roller, ctx.deps[:roll_log]),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc "Resolve a weapon attack from `attacker` onto `target` by the rules. Pass mode \"advantage\"/\"disadvantage\" when it applies."
  deftool make_attack(
            ctx,
            attacker :: String.t(),
            target :: String.t(),
            weapon :: String.t(),
            mode :: String.t()
          ) do
    with :ok <- assert_controls(ctx, attacker),
         {:ok, msg, change} <-
           Dragonex.Actions.attack(
             world(ctx),
             attacker,
             target,
             weapon,
             ctx.deps.roller,
             parse_mode(mode),
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc "Resolve a spell cast by `caster` onto `target` by the rules."
  deftool cast_spell(ctx, caster :: String.t(), spell :: String.t(), target :: String.t()) do
    with :ok <- assert_controls(ctx, caster),
         {:ok, msg, change} <-
           Dragonex.Actions.spell(
             world(ctx),
             caster,
             spell,
             target,
             ctx.deps.roller,
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc "Make a death saving throw for a down `character`."
  deftool make_death_save(ctx, character :: String.t()) do
    with :ok <- assert_controls(ctx, character),
         {:ok, msg, change} <-
           Dragonex.Actions.death_save(
             world(ctx),
             character,
             ctx.deps.roller,
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc "End combat and return to free-form exploration (DM call, once combat is over)."
  deftool end_combat(ctx) do
    {:ok, _} = propose(ctx, Dragonex.World.end_combat())
    {:ok, "el combate termina"}
  end

  @doc "Short rest: spend a hit die to recover HP. Available outside combat."
  deftool short_rest(ctx, target :: String.t()) do
    with :ok <- assert_rest_target(ctx, target),
         {:ok, msg, change} <-
           Dragonex.Actions.short_rest(world(ctx), target, ctx.deps.roller, ctx.deps[:roll_log]),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc "Long rest: restore all HP. Available outside combat."
  deftool long_rest(ctx, target :: String.t()) do
    with :ok <- assert_rest_target(ctx, target),
         {:ok, msg, change} <- Dragonex.Actions.long_rest(world(ctx), target),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Otorga un nivel a un personaje (subida por hito). Sube PG y refresca huecos de
  conjuro. **No aplica a PCs humanos** (los controla una persona real, incluso en
  auto-play): esos suben siempre desde su ficha (`/heroes/:id/level-up`). Para
  NPCs, enemigos y PCs IA, la subida la decide el DM aquí.

  `opts` lleva las elecciones del nuevo nivel (ignoradas para PCs humanos):
    * `"spells"` — keys de hechizos nuevos que aprende (builtin/SRD).
    * `"asi"` — `%{"str" => 2}` repartiendo 2 puntos a niveles 4/8/12/16/19.
  Pasa `{}` cuando no toque elegir nada. La validación de cupo la hace el motor.
  """
  deftool level_up(ctx, target :: String.t(), opts :: map()) do
    cond do
      human_pc?(ctx, target) ->
        {:ok,
         "#{target} es un jugador humano: debe subir de nivel desde su ficha (/heroes/:id/level-up), no por la mesa."}

      true ->
        change = Dragonex.World.level_up(target, normalize_level_up_opts(opts))

        with {:ok, _} <- propose(ctx, change) do
          {:ok, "¡#{target} sube de nivel!"}
        end
    end
  end

  defp normalize_level_up_opts(nil), do: %{}

  defp normalize_level_up_opts(opts) when is_map(opts) do
    %{
      spells_added: List.wrap(opts["spells"] || opts["spells_added"]),
      asi: normalize_asi(opts["asi"]),
      custom: %{}
    }
  end

  defp normalize_level_up_opts(_), do: %{}

  defp normalize_asi(asi) when is_map(asi) do
    Enum.reduce(asi, %{}, fn
      {ab, n}, acc when ab in ~w(str dex con int wis cha) and is_integer(n) ->
        Map.put(acc, String.to_existing_atom(ab), n)

      _, acc ->
        acc
    end)
  end

  defp normalize_asi(_), do: %{}

  # ¿El target es un PC controlado por un humano? El Game inyecta `human_pcs`
  # (MapSet de nombres) en el `deps` de cada beat.
  defp human_pc?(ctx, target) do
    case ctx.deps[:human_pcs] do
      %MapSet{} = set -> MapSet.member?(set, target)
      _ -> false
    end
  end

  @doc "Spawn a monster from the bestiary into the world (e.g. 'orc', 'skeleton', 'wolf'). Use a unique name if summoning multiples."
  deftool spawn_monster(ctx, kind :: String.t(), name :: String.t()) do
    monster =
      case Dragonex.Monsters.get(kind) do
        builder when is_function(builder, 1) -> builder.(name: name)
        nil -> nil
      end

    if monster do
      # Add the monster AND join it to the initiative order when mid-combat
      # (join_initiative is a no-op in exploration, so composing is always safe).
      change =
        compose(
          Dragonex.World.add_character(monster),
          Dragonex.World.join_initiative(monster.name)
        )

      with {:ok, _} <- propose(ctx, change) do
        {:ok, "¡Aparece #{name} (#{kind})! PG #{monster.hp}, CA #{monster.ac}."}
      end
    else
      {:ok,
       "Tipo de monstruo desconocido '#{kind}'. Disponibles: #{Enum.join(Dragonex.Monsters.keys(), ", ")}"}
    end
  end

  @doc "Heal `target` by a dice expression (e.g. \"1d8+3\"); caps at max hp. Death saves clear only if hp rises above 0. Does not touch temp_hp."
  deftool heal(ctx, target :: String.t(), dice :: String.t()) do
    with {:ok, msg, change} <-
           Dragonex.Actions.heal(world(ctx), target, dice, ctx.deps.roller, ctx.deps[:roll_log]),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Grant `amount` temporary hit points to `who` (5e, D36). Does not stack: the
  character keeps the higher of current temp_hp and `amount`. Does not heal.
  The DM may grant to anyone; a PC may only grant to themselves.
  """
  deftool grant_temp_hp(ctx, who :: String.t(), amount :: integer()) do
    current =
      case Dragonex.World.character(world(ctx), who) do
        nil -> 0
        c -> c.temp_hp || 0
      end

    with :ok <- assert_grant_temp_hp(ctx, who),
         {:ok, _} <- propose(ctx, Dragonex.World.apply_temp_hp(who, amount)) do
      {:ok, "#{who} queda con #{max(current, amount)} pg temporales."}
    end
  end

  @doc """
  Grant `amount` XP to `who` (5e, D43). Does not level up and does not
  touch hp or spell slots. Amount must be positive. DM only.
  """
  deftool grant_xp(ctx, who :: String.t(), amount :: integer()) do
    c = Dragonex.World.character(world(ctx), who)
    current_xp = if c, do: c.xp || 0, else: 0
    level = if c, do: c.level || 1, else: 1

    with :ok <- assert_grant_xp(ctx),
         {:ok, _} <- propose(ctx, Dragonex.World.grant_xp(who, amount)) do
      xp = current_xp + amount
      threshold = Dragonex.Heroes.Progression.xp_threshold(level + 1)
      can? = Dragonex.Heroes.Progression.can_level_up?(level, xp)
      {:ok, grant_xp_message(who, amount, xp, threshold, can?)}
    end
  end

  @doc """
  Drop concentration (5e, D37). The DM may drop anyone; a PC may only drop
  themselves.
  """
  deftool drop_concentration(ctx, who :: String.t()) do
    spell =
      case Dragonex.World.character(world(ctx), who) do
        nil -> nil
        c -> c.concentrating
      end

    with :ok <- assert_drop_concentration(ctx, who),
         {:ok, _} <- propose(ctx, Dragonex.World.clear_concentration(who)) do
      if is_binary(spell) do
        {:ok, "#{who} deja de concentrarse en #{spell}."}
      else
        {:ok, "#{who} no estaba concentrado."}
      end
    end
  end

  @doc """
  Enter Rage (5e, D42). Barbarian only, limited uses per long rest (D72;
  recharges on long rest). Clears concentration. The DM may start
  anyone; a PC may only start themselves.
  """
  deftool start_rage(ctx, who :: String.t()) do
    with :ok <- assert_rage_self(ctx, who),
         {:ok, _} <- propose(ctx, Dragonex.World.start_rage(who)) do
      {:ok, "#{who} entra en furia."}
    end
  end

  @doc """
  End Rage (5e, D42). The DM may end anyone; a PC may only end themselves.
  """
  deftool end_rage(ctx, who :: String.t()) do
    with :ok <- assert_rage_self(ctx, who),
         {:ok, _} <- propose(ctx, Dragonex.World.end_rage(who)) do
      {:ok, "#{who} deja la furia."}
    end
  end

  @doc """
  Enter Reckless Attack (5e, D44). Barbarian only. The DM may start anyone; a
  PC may only start themselves. The engine applies advantage — do not pass
  mode to make_attack for Reckless.
  """
  deftool start_reckless(ctx, who :: String.t()) do
    with :ok <- assert_reckless_self(ctx, who),
         {:ok, _} <- propose(ctx, Dragonex.World.start_reckless(who)) do
      {:ok, "#{who} ataca de forma temeraria."}
    end
  end

  @doc """
  End Reckless Attack (D44). The DM may end anyone; a PC may only end
  themselves.
  """
  deftool end_reckless(ctx, who :: String.t()) do
    with :ok <- assert_reckless_self(ctx, who),
         {:ok, _} <- propose(ctx, Dragonex.World.end_reckless(who)) do
      {:ok, "#{who} deja de atacar de forma temeraria."}
    end
  end

  @doc """
  Second Wind (5e, D45). Fighter only. Heals 1d10+level, once per rest.
  The DM may use it for anyone; a PC may only use it on themselves.
  """
  deftool second_wind(ctx, who :: String.t()) do
    with :ok <- assert_second_wind_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.second_wind(
             world(ctx),
             who,
             ctx.deps.roller,
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Action Surge (5e, D47). Fighter level 2+. Extra Attack action (N swings,
  Extra Attack D35 included), once per rest. The DM may use it for anyone;
  a PC may only use it on themselves.
  """
  deftool action_surge(
            ctx,
            who :: String.t(),
            target :: String.t(),
            weapon :: String.t(),
            mode :: String.t()
          ) do
    with :ok <- assert_action_surge_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.action_surge(
             world(ctx),
             who,
             target,
             weapon,
             ctx.deps.roller,
             parse_mode(mode),
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Flurry of Blows (5e, D54). Monk level 2+. Spends 1 ki point; the engine
  resolves two unarmed strikes (martial arts die). The DM may use it for
  any monk; a PC may only use it as themselves.
  """
  deftool flurry_of_blows(ctx, who :: String.t(), target :: String.t(), mode :: String.t()) do
    with :ok <- assert_flurry_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.flurry_of_blows(
             world(ctx),
             who,
             target,
             ctx.deps.roller,
             parse_mode(mode),
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Hunter's Mark (5e, D55). Ranger level 2+. Spends a level-1 spell slot
  and concentrates on `target`; the engine then adds +1d6 to the marker's
  weapon hits against that prey. The DM may use it for any ranger; a PC
  may only use it as themselves.
  """
  deftool hunters_mark(ctx, who :: String.t(), target :: String.t()) do
    with :ok <- assert_hunters_mark_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.hunters_mark(
             world(ctx),
             who,
             target,
             ctx.deps.roller,
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Cunning Action: Hide (5e, D57). Rogue level 2+. The engine rolls a DEX
  (Stealth) check against the highest passive perception among conscious
  enemies; success applies "hidden" — the rogue's next attack rolls with
  advantage (and enables Sneak Attack), and that attack reveals them.
  The DM may use it for any rogue; a PC may only use it as themselves.
  """
  deftool cunning_action_hide(ctx, who :: String.t()) do
    with :ok <- assert_cunning_hide_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.cunning_action_hide(
             world(ctx),
             who,
             ctx.deps.roller,
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Uncanny Dodge (5e, D64). Rogue level 5+. Arms a defensive posture: the
  engine halves (floor) the NEXT damage `who` takes — any source — and
  consumes the flag. Arming is free and can be done at any moment (no
  reaction economy); 0 damage or healing never consumes it. The DM may
  arm anyone; a PC may only arm themselves.
  """
  deftool start_uncanny_dodge(ctx, who :: String.t()) do
    with :ok <- assert_uncanny_dodge_self(ctx, who),
         {:ok, msg, change} <- Dragonex.Actions.start_uncanny_dodge(world(ctx), who),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Create a Spell Slot (5e, D56 Font of Magic). Sorcerer level 2+. Spends
  sorcery points (2/3/5/6/7 by slot level 1–5) and gains one slot of that
  level. The DM may use it for any sorcerer; a PC may only use it as
  themselves.
  """
  deftool create_spell_slot(ctx, who :: String.t(), level :: integer()) do
    with :ok <- assert_font_of_magic_self(ctx, who),
         {:ok, msg, change} <- Dragonex.Actions.create_spell_slot(world(ctx), who, level),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Convert to Sorcery Points (5e, D56 Font of Magic). Sorcerer level 2+.
  Spends one slot of `level` (1–5) and gains that many sorcery points,
  capped at the pool maximum. The DM may use it for any sorcerer; a PC may
  only use it as themselves.
  """
  deftool convert_to_sorcery_points(ctx, who :: String.t(), level :: integer()) do
    with :ok <- assert_font_of_magic_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.convert_to_sorcery_points(world(ctx), who, level),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Metamagic (5e, D65). Sorcerer level 3+. Spends sorcery points to arm ONE
  option that the engine applies to and consumes with the sorcerer's next
  qualifying spell: "empowered" (1 punto — the first max(1, CHA) damage
  dice roll twice keeping the higher), "heightened" (3 puntos — the armed
  target saves with disadvantage), "twinned" (2 puntos — the same spell
  also resolves against the armed second target). Pass `target` (a
  character name) for heightened/twinned, "" for empowered. Only ONE
  option at a time; no un-arm nor refund; spells that don't qualify leave
  it armed. The DM may arm anyone; a PC may only arm themselves.
  """
  deftool arm_metamagic(ctx, who :: String.t(), option :: String.t(), target :: String.t()) do
    with :ok <- assert_metamagic_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.arm_metamagic(world(ctx), who, option, target || ""),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Arm Divine Smite (5e, D46). Paladin only. Leaves a pending smite_slot;
  the spell slot is consumed on the next melee hit, not now. The DM may
  arm anyone; a PC may only arm themselves.
  """
  deftool divine_smite(ctx, who :: String.t(), slot_level :: integer()) do
    with :ok <- assert_smite_self(ctx, who),
         {:ok, _} <- propose(ctx, Dragonex.World.start_smite(who, slot_level)) do
      {:ok, "#{who} arma Castigo divino (casilla de nivel #{slot_level})."}
    end
  end

  @doc """
  Clear pending Divine Smite (D46) without consuming a slot. The DM may
  end anyone; a PC may only end themselves.
  """
  deftool end_smite(ctx, who :: String.t()) do
    with :ok <- assert_smite_self(ctx, who),
         {:ok, _} <- propose(ctx, Dragonex.World.end_smite(who)) do
      {:ok, "#{who} retira el Castigo divino."}
    end
  end

  @doc """
  Lay on Hands (5e, D49). Paladin only. Spends pool points to heal
  `target` (self or another). The DM may use it for any paladin; a PC
  may only use it as themselves (`who` is self; `target` may be an ally).
  """
  deftool lay_on_hands(
            ctx,
            who :: String.t(),
            target :: String.t(),
            amount :: integer()
          ) do
    with :ok <- assert_lay_on_hands_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.lay_on_hands(world(ctx), who, target, amount),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Divine Sense (5e, D52). Paladin only. Spends 1 use and the engine
  reports celestials, fiends and undead in the world. The DM may use it
  for any paladin; a PC may only use it as themselves.
  """
  deftool divine_sense(ctx, who :: String.t()) do
    with :ok <- assert_divine_sense_self(ctx, who),
         {:ok, msg, change} <- Dragonex.Actions.divine_sense(world(ctx), who),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Turn Undead (5e, D53). Cleric level 2+. Spends Channel Divinity; living
  undead roll a Wisdom save and fail into frightened. The DM may use it
  for any cleric; a PC may only use it as themselves.
  """
  deftool turn_undead(ctx, who :: String.t()) do
    with :ok <- assert_turn_undead_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.turn_undead(
             world(ctx),
             who,
             ctx.deps.roller,
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Bardic Inspiration (5e, D50). Bard only. Spends 1 use to grant `target`
  a pending d6. The DM may use it for any bard; a PC may only use it as
  themselves (`who` is self; `target` may be an ally).
  """
  deftool bardic_inspiration(ctx, who :: String.t(), target :: String.t()) do
    with :ok <- assert_bardic_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.bardic_inspiration(world(ctx), who, target),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Arcane Recovery (5e, D51). Wizard only. Restores expended spell slots
  outside combat, once per long rest. The engine picks slots (greedy).
  The DM may use it for anyone; a PC may only use it on themselves.
  """
  deftool arcane_recovery(ctx, who :: String.t()) do
    with :ok <- assert_arcane_recovery_self(ctx, who),
         {:ok, msg, change} <- Dragonex.Actions.arcane_recovery(world(ctx), who),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Wild Shape (5e, D63). Druid level 2+. Transforms `who` into a beast from
  the fixed catalogue — "cat" (ND 0), "wolf" (ND 1/4), "black_bear"
  (ND 1/2, level 4+ only). The engine spends 1 use (2 per rest), saves the
  original form and applies the beast's stats and attacks; while
  transformed `who` CANNOT cast spells (everything else works). If the beast
  drops to 0 hp the engine reverts automatically with only the excess
  damage carried over. The DM may transform anyone; a PC may only
  transform themselves.
  """
  deftool wild_shape(ctx, who :: String.t(), beast :: String.t()) do
    with :ok <- assert_wild_shape_self(ctx, who),
         {:ok, msg, change} <- Dragonex.Actions.wild_shape(world(ctx), who, beast),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  End Wild Shape (D63). Returns `who` to their original form with the hit
  points they had when transforming. The DM may end anyone; a PC may only
  end themselves.
  """
  deftool end_wild_shape(ctx, who :: String.t()) do
    with :ok <- assert_wild_shape_self(ctx, who),
         {:ok, msg, change} <- Dragonex.Actions.end_wild_shape(world(ctx), who),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Breath Weapon (5e, D70). Dragonborn only (any class/level): spends the
  racial use (1/rest — short AND long recharge) and the engine resolves a
  DEX save for `target` vs the dragonborn's DC (8 + CON + proficiency);
  failure takes the full fire damage of `Progression.breath_dice/1`,
  success takes half. Not a spell (no slot, works in Wild Shape). The
  DM may use it for any dragonborn; a PC may only use it as themselves.
  """
  deftool breath_weapon(ctx, who :: String.t(), target :: String.t()) do
    with :ok <- assert_breath_self(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.breath_weapon(
             world(ctx),
             who,
             target,
             ctx.deps.roller,
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Expertise (5e, D73). Rogue (L1+) / bard (L3+): doubles the proficiency
  bonus of ONE trained skill (2 choices; 4 from rogue L6 / bard L10).
  `skill` must be in the character's trained skills — the engine
  validates class, level, training, duplicates and cupo. Choose once per
  skill, any moment once eligible. The DM may choose for anyone; a PC
  may only choose for themselves.
  """
  deftool gain_expertise(ctx, who :: String.t(), skill :: String.t()) do
    with :ok <- assert_gain_expertise_self(ctx, who),
         {:ok, msg, change} <- Dragonex.Actions.gain_expertise(world(ctx), who, skill),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Resolve a non-combat ability check: the DM sets the `dc` (5/10/15/20 by 5e
  difficulty), the engine rolls d20 + the ability modifier for `who`.
  Pass a SKILL name when the check maps to one (`"stealth"`,
  `"athletics"`, `"animal_handling"` — case/spaces/hyphens are normalized):
  the engine picks the governing ability and applies the character's skill
  proficiency from the sheet, plus Jack of All Trades (bard L2+: half
  proficiency on untrained skills). Pass a raw ability (`"str"`…`"cha"`)
  only for generic checks (no proficiency from the sheet). Pass mode
  "advantage"/"disadvantage" when it applies.
  Examples: ability_check("Thane", "athletics", 15),
  ability_check("Vex", "stealth", 15, "advantage"), ability_check("Thane", "str", 10).
  """
  deftool ability_check(
            ctx,
            who :: String.t(),
            ability :: String.t(),
            dc :: integer(),
            mode :: String.t()
          ) do
    with :ok <- assert_controls(ctx, who),
         {:ok, msg, change} <-
           Dragonex.Actions.check(
             world(ctx),
             who,
             ability,
             dc,
             false,
             ctx.deps.roller,
             parse_mode(mode),
             ctx.deps[:roll_log]
           ),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc "Apply a condition to a character (e.g. prone, poisoned, blinded)."
  deftool apply_condition(ctx, target :: String.t(), condition :: String.t()) do
    # D62 Aura of Courage: same-side ally of a conscious paladin L10+ can't
    # be frightened. The World hook would no-op anyway; the message tells
    # the model WHY nothing landed.
    if condition == "frightened" and Dragonex.World.courage_immune?(world(ctx), target) do
      {:ok, "#{target} es inmune al miedo (Aura de Coraje)"}
    else
      with {:ok, _} <- propose(ctx, Dragonex.World.apply_condition(target, condition)) do
        {:ok, "#{target} ahora está #{condition}"}
      end
    end
  end

  @doc "Remove a condition from a character."
  deftool remove_condition(ctx, target :: String.t(), condition :: String.t()) do
    with {:ok, _} <- propose(ctx, Dragonex.World.remove_condition(target, condition)) do
      {:ok, "#{target} ya no está #{condition}"}
    end
  end

  defp parse_mode("advantage"), do: :advantage
  defp parse_mode("disadvantage"), do: :disadvantage
  defp parse_mode(_), do: :normal

  # Read the current shared world through the Session handle.
  defp world(ctx), do: ExAgent.Session.SharedState.read(ctx.deps.state)

  # Guard: only let a participant act with the characters it controls. Stops a
  # monster from acting on a player's turn (and vice versa). The error is
  # *directive* — it tells the DM exactly who must act and how to re-issue, so a
  # confused model self-corrects on the retry instead of repeating the mistake.
  # PCs only rest themselves; the DM (referee) may rest anyone between fights.
  defp assert_rest_target(ctx, target) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == target do
      :ok
    else
      {:error, "RECHAZADO — solo puedes descansar tú mismo (#{proposer}), no a #{target}."}
    end
  end

  defp assert_grant_xp(ctx) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" do
      :ok
    else
      {:error, "RECHAZADO — solo el DM puede otorgar XP."}
    end
  end

  defp grant_xp_message(who, amount, xp, nil, _can?) do
    "#{who} gana #{amount} XP (total #{xp}; nivel máximo; no puede subir de nivel)."
  end

  defp grant_xp_message(who, amount, xp, threshold, true) do
    "#{who} gana #{amount} XP (total #{xp}; umbral siguiente nivel #{threshold}; puede subir de nivel)."
  end

  defp grant_xp_message(who, amount, xp, threshold, false) do
    "#{who} gana #{amount} XP (total #{xp}; umbral siguiente nivel #{threshold}; aún no puede subir de nivel)."
  end

  defp assert_grant_temp_hp(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       "RECHAZADO — solo puedes otorgar pg temporales a ti mismo (#{proposer}), no a #{who}."}
    end
  end

  defp assert_drop_concentration(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       "RECHAZADO — solo puedes soltar tu propia concentración (#{proposer}), no la de #{who}."}
    end
  end

  defp assert_rage_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       "RECHAZADO — solo puedes controlar tu propia furia (#{proposer}), no la de #{who}."}
    end
  end

  defp assert_reckless_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       "RECHAZADO — solo puedes controlar tu propio ataque temerario (#{proposer}), no el de #{who}."}
    end
  end

  defp assert_second_wind_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       "RECHAZADO — solo puedes usar Segundo aliento en ti mismo (#{proposer}), no en #{who}."}
    end
  end

  defp assert_action_surge_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       "RECHAZADO — solo puedes usar Oleada de acción en ti mismo (#{proposer}), no en #{who}."}
    end
  end

  defp assert_flurry_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       "RECHAZADO — solo puedes usar Ráfaga de golpes en ti mismo (#{proposer}), no en #{who}."}
    end
  end

  defp assert_hunters_mark_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error, "RECHAZADO — solo puedes usar Marca del cazador como #{proposer}, no como #{who}."}
    end
  end

  # Cunning Action: Hide (D57): self guard (divine_smite pattern).
  defp assert_cunning_hide_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error, "RECHAZADO — solo puedes esconderte tú mismo (#{proposer}), no a #{who}."}
    end
  end

  # Uncanny Dodge (D64): self guard (divine_smite pattern).
  defp assert_uncanny_dodge_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       "RECHAZADO — solo puedes armarte tú mismo de Esquiva asombrosa (#{proposer}), no a #{who}."}
    end
  end

  # Font of Magic (D56): both tools share the self guard (divine_smite pattern).
  defp assert_font_of_magic_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       "RECHAZADO — solo puedes usar Fuente de magia en ti mismo (#{proposer}), no en #{who}."}
    end
  end

  # Metamagic (D65): self guard (divine_smite pattern).
  defp assert_metamagic_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error, "RECHAZADO — solo puedes armar Metamagia en ti mismo (#{proposer}), no en #{who}."}
    end
  end

  defp assert_smite_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       "RECHAZADO — solo puedes controlar tu propio Castigo divino (#{proposer}), no el de #{who}."}
    end
  end

  defp assert_lay_on_hands_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error, "RECHAZADO — solo puedes usar Manos impositoras como #{proposer}, no como #{who}."}
    end
  end

  defp assert_divine_sense_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error, "RECHAZADO — solo puedes usar Sentido divino como #{proposer}, no como #{who}."}
    end
  end

  defp assert_turn_undead_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       "RECHAZADO — solo puedes usar Expulsar no-muertos como #{proposer}, no como #{who}."}
    end
  end

  defp assert_bardic_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       "RECHAZADO — solo puedes usar Inspiración bárdica como #{proposer}, no como #{who}."}
    end
  end

  defp assert_arcane_recovery_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       "RECHAZADO — solo puedes usar Recuperación arcana en ti mismo (#{proposer}), no en #{who}."}
    end
  end

  # Wild Shape (D63): both tools share the self guard (divine_smite pattern).
  defp assert_wild_shape_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       "RECHAZADO — solo puedes usar Forma salvaje en ti mismo (#{proposer}), no en #{who}."}
    end
  end

  # Breath Weapon (D70): self guard (divine_smite pattern).
  defp assert_breath_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       "RECHAZADO — solo puedes usar tu propio aliento de dragón (#{proposer}), no el de #{who}."}
    end
  end

  # Expertise (D73): self guard (divine_smite pattern).
  defp assert_gain_expertise_self(ctx, who) do
    proposer = ctx.deps.state.participant_id

    if proposer == "dm" or proposer == who do
      :ok
    else
      {:error,
       "RECHAZADO — solo puedes elegir tu propio Expertise (#{proposer}), no el de #{who}."}
    end
  end

  defp assert_controls(ctx, actor) do
    proposer = ctx.deps.state.participant_id

    if Dragonex.World.controlled_by?(world(ctx), actor, proposer) do
      :ok
    else
      {:error,
       "RECHAZADO — es el turno de #{proposer}, así que el atacante/conjurador/quien DEBE ser \"#{proposer}\". " <>
         "Llamaste a esta herramienta con actor=\"#{actor}\" (#{proposer} no controla a #{actor}). " <>
         "Reemite la MISMA intención pero como #{proposer}, p.ej. " <>
         "make_attack(\"#{proposer}\", \"<objetivo>\", \"<arma>\") o cast_spell(\"#{proposer}\", \"<hechizo>\", \"<objetivo>\")."}
    end
  end

  # Propose a world change through the Session handle. Tools must not mutate the
  # world directly; they propose through SharedState (single-writer rule).
  defp propose(ctx, change_fn) do
    ExAgent.Session.SharedState.propose_change(ctx.deps.state, change_fn)
  end

  # Sequence two change functions into one (the Session applies a single fn).
  defp compose(f1, f2) do
    fn w ->
      with {:ok, w} <- f1.(w), {:ok, w} <- f2.(w), do: {:ok, w}
    end
  end
end
