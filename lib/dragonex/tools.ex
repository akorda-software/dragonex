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

  @doc "Heal `target` by a dice expression (e.g. \"1d8+3\"); caps at max hp. Death saves clear only if hp rises above 0."
  deftool heal(ctx, target :: String.t(), dice :: String.t()) do
    with {:ok, msg, change} <-
           Dragonex.Actions.heal(world(ctx), target, dice, ctx.deps.roller, ctx.deps[:roll_log]),
         {:ok, _} <- propose(ctx, change) do
      {:ok, msg}
    end
  end

  @doc """
  Resolve a non-combat ability check: the DM sets the `dc` (5/10/15/20 by 5e
  difficulty), the engine rolls d20 + the ability modifier for `who`.
  Skill proficiency is not applied in v1 (the sheet stores it; resolution does
  not). Pass mode "advantage"/"disadvantage" when it applies.
  """
  deftool ability_check(
            ctx,
            who :: String.t(),
            ability :: String.t(),
            dc :: integer(),
            mode :: String.t()
          ) do
    with :ok <- assert_controls(ctx, who),
         {:ok, ability_atom} <- parse_ability(ability),
         {:ok, msg, change} <-
           Dragonex.Actions.check(
             world(ctx),
             who,
             ability_atom,
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
    with {:ok, _} <- propose(ctx, Dragonex.World.apply_condition(target, condition)) do
      {:ok, "#{target} ahora está #{condition}"}
    end
  end

  @doc "Remove a condition from a character."
  deftool remove_condition(ctx, target :: String.t(), condition :: String.t()) do
    with {:ok, _} <- propose(ctx, Dragonex.World.remove_condition(target, condition)) do
      {:ok, "#{target} ya no está #{condition}"}
    end
  end

  defp parse_ability(s) do
    case Dragonex.Rules.Ability.parse(s) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        {:error, "característica desconocida: #{inspect(s)} (usa str/dex/con/int/wis/cha)"}
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
