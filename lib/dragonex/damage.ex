defmodule Dragonex.Damage do
  @moduledoc "Canonical damage preparation: resolve once, commit without rerolling."
  use Gettext, backend: Dragonex.Gettext
  alias Dragonex.{Character, World, RollLog}
  alias Dragonex.Rules.{Combat, Conditions}

  # These fields determine the damage transition, including concentration saves.
  # A preceding spell save can provide its original target for commit validation.
  @dependencies ~w(hp max_hp temp_hp wild_shape raging uncanny_dodge concentrating
    relentless_endurance_used relentless_rage_successes death_saves
    damage_resistances damage_immunities damage_vulnerabilities conditions
    ac con race class level saving_proficiencies inspired indomitable_used)a

  def prepare(c, amount, type, roller, opts) do
    expected = Keyword.get(opts, :expected_target, c)
    world = World.new(characters: %{c.name => c})
    {:ok, resolved} = World.apply_damage(c.name, amount, type, roller, opts).(world)
    after_char = resolved.characters[c.name]
    notes = resolved.log |> Enum.reverse() |> Enum.map(&elem(&1, 1))

    changes =
      Map.from_struct(after_char) |> Map.reject(fn {key, value} -> Map.get(c, key) == value end)

    commit = fn current ->
      case World.present_character(current, c.name) do
        %Character{} = live ->
          if Map.take(live, @dependencies) == Map.take(expected, @dependencies) do
            updated = struct(live, changes)

            next = %{
              current
              | characters: Map.put(current.characters, c.name, updated),
                log: Enum.take(resolved.log ++ current.log, 50)
            }

            next =
              if incoming(c, amount, type, opts) > 0,
                do: Dragonex.TurnBudget.mark(next, c.name, "damaged"),
                else: next

            {:ok, Dragonex.WorldClock.observe(next, live, updated)}
          else
            {:error,
             dgettext(
               "engine",
               "%{name} ha cambiado desde la resolución del daño; vuelve a resolver la acción",
               name: c.name
             )}
          end

        nil ->
          {:error, dgettext("engine", "no existe el personaje: %{name}", name: c.name)}
      end
    end

    {notes, commit, after_char}
  end

  def incoming(c, amount, type, opts) do
    parts = [{amount, type} | Keyword.get(opts, :additional_damage, [])]

    Enum.reduce(parts, 0, fn {n, damage_type}, sum ->
      n = if c.uncanny_dodge == true, do: div(max(0, n), 2), else: n
      sum + Character.incoming_damage(c, n, damage_type)
    end)
  end

  def concentrate(before, after_world, amount, type, roller, opts) do
    after_char = World.character(after_world, before.name)
    incoming = incoming(before, amount, type, opts)

    cond do
      before.concentrating == nil or incoming <= 0 ->
        after_world

      after_char.hp <= 0 ->
        note(
          after_world,
          dgettext(
            "engine",
            "%{name} cae a 0 pg y pierde la concentración en %{spell}.",
            name: before.name,
            spell: Dragonex.Terms.spell(before.concentrating)
          )
        )

      true ->
        dc = max(10, div(incoming, 2))
        aura = Keyword.get(opts, :aura, World.aura_save_bonus(after_world, before.name))
        {:roll, mode} = Conditions.save_mode(after_char, :con)

        {r, close} =
          RollLog.open(
            Keyword.get(opts, :roll_log),
            roller || (&Dragonex.Dice.roll/1),
            before.name,
            :save,
            dgettext("engine", "salvación de Constitución (concentración)")
          )

        {d20, total, _, lucky} = Combat.saving_throw_tagged(after_char, :con, dc, r, mode)
        bardic = if after_char.inspired, do: r.(6), else: 0
        total = total + aura + bardic
        original_total = total

        reroll? =
          total < dc and after_char.class == "fighter" and after_char.level >= 9 and
            not after_char.indomitable_used

        {d20, total, lucky} =
          if reroll? do
            {d, t, _, l} = Combat.saving_throw_tagged(after_char, :con, dc, r, mode)
            {d, t + aura, l}
          else
            {d20, total, lucky}
          end

        success? = total >= dc

        c = %{
          after_char
          | concentrating: if(success?, do: after_char.concentrating, else: nil),
            inspired: false,
            indomitable_used: after_char.indomitable_used or reroll?
        }

        RollLog.close(close,
          total: total,
          against: {:dc, dc},
          outcome: if(success?, do: :success, else: :failure)
        )

        reroll_tag = if reroll?, do: " (Indomitable: #{original_total}→#{total})", else: ""
        lucky_tag = if lucky != nil, do: " #{lucky}", else: ""

        suffix =
          if(bardic > 0,
            do: dgettext("engine", " +%{bonus} inspiración", bonus: bardic),
            else: ""
          )

        suffix = suffix <> if(aura != 0, do: " +#{aura} aura", else: "")

        %{after_world | characters: Map.put(after_world.characters, before.name, c)}
        |> Dragonex.WorldClock.observe(after_char, c)
        |> note(
          concentration_note(success?,
            name: before.name,
            spell: Dragonex.Terms.spell(before.concentrating),
            roll: "#{d20}#{lucky_tag}#{reroll_tag}",
            total: total,
            dc: dc,
            suffix: suffix
          )
        )
    end
  end

  defp concentration_note(true, bindings),
    do:
      dgettext(
        "engine",
        "%{name} mantiene la concentración en %{spell} (d20 %{roll}: %{total} vs CD %{dc}%{suffix}).",
        bindings
      )

  defp concentration_note(false, bindings),
    do:
      dgettext(
        "engine",
        "%{name} pierde la concentración en %{spell} (d20 %{roll}: %{total} vs CD %{dc}%{suffix}).",
        bindings
      )

  defp note(w, text), do: %{w | log: Enum.take([{"dm", text} | w.log], 50)}
end
