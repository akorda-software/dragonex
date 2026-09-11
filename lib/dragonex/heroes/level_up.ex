defmodule Dragonex.Heroes.LevelUp do
  @moduledoc """
  Reglas de subida de nivel aplicadas a un `Dragonex.Character`.

  Módulo **enfocado en progresión**, separado del builder (`Dragonex.Heroes`),
  para que el motor de partida (`Dragonex.World.level_up/2`) dependa de esto y no
  del constructor de nivel 1. Comparte las tablas de `Dragonex.Heroes.Progression`
  (XP, ASI, nivel máx. de hechizo, features).

  ## Reglas 5e que aplica

    * Nivel +1 (tope 20).
    * PG: dado medio + mod CON (con el mod nuevo) + bono racial por nivel. El
      `hp_gain` va **solo al máximo** (RAW: subir de nivel no cura).
    * Retroactivo de CON: al subir CON (vía ASI), `(new_mod − old_mod) × niveles
      previos` se suma al max_hp **y al hp actual** (vitalidad, regla 5e).
    * ASI en niveles 4/8/12/16/19, validando el cupo (`Progression.asi_points/0`).
    * AC recalculada si cambian DEX / CON / WIS (según equipo y Defensa sin Armadura).
    * Hechizos nuevos (`choices.spells_added`) y features de clase del nuevo nivel.

  No toca estado transitorio (condiciones, death_saves, temp_hp, concentrating, raging, reckless, second_wind_used, action_surge_used, smite_slot, lay_on_hands_pool, slots usados). El
  hp actual solo sube por la vitalidad retroactiva de CON; un caído (0 hp) sin
  ASI de CON sigue caído tras subir.
  """

  alias Dragonex.Character
  alias Dragonex.Heroes.{Classes, Equipment, Progression, Races, Spells}
  alias Dragonex.Rules.Ability

  @doc """
  Aplica una subida de nivel a un `Character`.

  `choices` (opcional):
    * `:spells_added` — keys de hechizos nuevos (builtin/SRD o custom `custom_*`).
    * `:asi` — `%{str: 1, dex: 1, …}` repartiendo `Progression.asi_points/0` (máx 20 cada).
    * `:custom` — bundle de contenido custom para resolver hechizos custom nuevos.
  """
  @spec apply(Character.t(), map()) :: {:ok, Character.t()} | {:error, String.t()}
  def apply(%Character{level: 20}, _choices),
    do: {:error, "el personaje ya está en el nivel máximo (20)"}

  def apply(%Character{} = c, choices) when is_map(choices) do
    new_level = c.level + 1
    hit_die = hit_die_for(c.class)
    custom = choices[:custom] || %{}
    asi = if Progression.asi_at?(new_level), do: choices[:asi] || %{}, else: %{}

    # Validación server-side del cupo ASI (los deltas negativos no cuentan:
    # 5e nunca rebaja características por este camino, se tratan como 0).
    asi_used = asi |> Map.values() |> Enum.filter(&(is_integer(&1) and &1 > 0)) |> Enum.sum()

    if asi_used > Progression.asi_points() do
      {:error, "el ASI reparte #{asi_used} puntos (máximo #{Progression.asi_points()})"}
    else
      new_scores = %{
        str: apply_asi(c.str, asi[:str]),
        dex: apply_asi(c.dex, asi[:dex]),
        con: apply_asi(c.con, asi[:con]),
        int: apply_asi(c.int, asi[:int]),
        wis: apply_asi(c.wis, asi[:wis]),
        cha: apply_asi(c.cha, asi[:cha])
      }

      # HP del nivel nuevo (dado medio + CON nueva + bono racial por nivel, p. ej.
      # hill dwarf +1) y retroactivo por el cambio de modificador de CON sobre
      # los niveles PREVIOS (regla 5e): el nivel nuevo ya usa new_con_mod en
      # hp_gain, así que el retro solo aplica a `c.level` niveles anteriores.
      #
      # RAW 5e: el `hp_gain` del nuevo nivel va SOLO al máximo (no cura al hp
      # actual). El `con_retro` sí se suma al hp actual: es vitalidad ganada por
      # subir el mod de CON, no sanación (PHB: "your current hit points increase
      # by the same amount"). Así un personaje dañado conserva su daño y un caído
      # (0 hp) sin cambio de CON sigue caído.
      old_con_mod = Ability.modifier(c.con)
      new_con_mod = Ability.modifier(new_scores[:con])
      avg = div(hit_die, 2) + 1
      race_bonus = race_hp_bonus(c)
      hp_gain = avg + new_con_mod + race_bonus
      con_retro = (new_con_mod - old_con_mod) * c.level
      new_max_hp = c.max_hp + hp_gain + con_retro

      max_sl = Progression.max_spell_level(c.class, new_level)

      new_spells =
        if max_sl >= 1 do
          build_added_spells(c.class, choices[:spells_added] || choices[:spells] || [], custom)
          |> Enum.reject(&(&1.level > max_sl))
        else
          []
        end

      features = Progression.features_at(c.class, new_level)
      new_ac = recompute_ac(c, new_scores)

      updated = %{
        c
        | level: new_level,
          max_hp: new_max_hp,
          hp: c.hp + con_retro,
          xp: max(c.xp || 0, Progression.xp_threshold(new_level)),
          spells: Enum.uniq_by(c.spells ++ new_spells, & &1.name),
          class_features: Enum.uniq(c.class_features ++ features),
          ac: new_ac,
          str: new_scores[:str],
          dex: new_scores[:dex],
          con: new_scores[:con],
          int: new_scores[:int],
          wis: new_scores[:wis],
          cha: new_scores[:cha]
      }

      {:ok, updated}
    end
  end

  # --------------------------------------------------------------- helpers

  # Bono racial de HP por nivel (p. ej. hill dwarf +1). `Character.race` guarda
  # el nombre legible (downcased) de la raza o subraza, que puede NO coincidir con
  # la `key` interna (p. ej. "hill dwarf" vs key "hill"), así que resolvemos por
  # nombre contra razas y subrazas.
  defp race_hp_bonus(%Character{race: race_key}) do
    target = String.downcase(race_key || "")

    bonuses =
      for race <- Races.all(),
          sub <- [%{name: race.name, hp_bonus: race.hp_bonus} | race.subraces],
          String.downcase(sub.name) == target,
          do: sub.hp_bonus || 0

    List.first(bonuses, 0)
  end

  # Recalcula la AC tras un cambio de puntuaciones (p. ej. ASI de DEX, o
  # CON/WIS con Defensa sin Armadura). Deriva el equipo del `Character` y reutiliza
  # el cómputo de AC del builder (`Heroes.compute_ac/3`).
  defp recompute_ac(c, scores) do
    case Classes.get(c.class) do
      {:ok, class} ->
        Dragonex.Heroes.compute_ac(eq_from_character(c), class, scores)

      _ ->
        c.ac
    end
  end

  defp eq_from_character(c) do
    inv = c.inventory || []

    armor =
      Enum.find_value(inv, fn
        %{kind: :armor, name: name} when name != "shield" -> Equipment.armor(name)
        _ -> nil
      end)

    shield =
      Enum.any?(inv, fn
        %{kind: :armor, name: "shield"} -> true
        _ -> false
      end)

    %{armor: armor, shield: shield, weapons: c.weapons, inventory: c.inventory}
  end

  defp hit_die_for(class_key) do
    case Classes.get(class_key) do
      {:ok, %{hit_die: d}} -> d
      _ -> 8
    end
  end

  defp build_added_spells(class_key, keys, custom) do
    ability = casting_ability_for(class_key)

    keys
    |> Enum.map(&Spells.resolve(&1, custom))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Spells.to_character_spell(&1, ability))
  end

  # Capacidad de conjuración para fijar `casting_ability` en los hechizos nuevos.
  # Los half-casters (paladín/ranger) NO traen `spellcasting` en `Classes` a L1
  # (lo ganan a L2 vía `features_at`), pero su capacidad es fija por clase.
  defp casting_ability_for(class_key) do
    case Classes.get(class_key) do
      {:ok, %{spellcasting: %{ability: a}}} -> a
      _ -> half_caster_ability(class_key)
    end
  end

  defp half_caster_ability(class) when class in ["paladin", :paladin], do: :cha
  defp half_caster_ability(class) when class in ["ranger", :ranger], do: :wis
  defp half_caster_ability(_), do: nil

  defp apply_asi(nil, _), do: nil
  defp apply_asi(score, nil), do: score

  defp apply_asi(score, delta) when is_integer(score) and is_integer(delta) and delta > 0 do
    (score + delta) |> max(1) |> min(20)
  end

  defp apply_asi(score, _), do: score
end
