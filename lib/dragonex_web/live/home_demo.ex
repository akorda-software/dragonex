defmodule DragonexWeb.HomeDemo do
  @moduledoc """
  The home page's living chronicle: a real excerpt from game 19451 («El libro
  del molino», 2026-10-04) replayed turn by turn. Narration is verbatim (or a
  literal cut of it) and every roll is the engine's logged payload (weapon and
  damage keys shown in Spanish), formatted by the same `RollFormat` the table
  uses. Dice tumble to those exact values.

  The excerpt follows the visitor's locale: narration in the `ui` catalog,
  roll reasons through the engine's own msgids and `Dragonex.Terms`.

  Pure data and stepping; the LiveView owns timers and pushes. No model or
  database access, so the landing never spends provider tokens.
  """

  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.Terms
  alias DragonexWeb.GameLive.{Chat, RollFormat}

  # The visitor sits in Thane's seat, so his turn header reads «THANE · TÚ».
  @viewer "Thane"

  # {pause before this entry in ms, entry}. Built at runtime: narration and
  # roll reasons follow the visitor's locale. Reasons reuse the engine's own
  # msgids, so an English visitor reads exactly what an English table logs.
  defp script do
    [
      {0, {:turn, "dm", "exploration"}},
      {300,
       {:dm,
        dgettext(
          "ui",
          "Del fondo del interior llega un correteo nervioso entre los sacos: las ratas ya saben que alguien ha venido."
        )}},
      {1800,
       {:rolls,
        [
          initiative("Vex", 19, 22),
          initiative("Lyra", 10, 12),
          initiative("Thane", 2, 3)
        ]}},
      {3400, {:turn, "Vex", "combat"}},
      {500, {:rolls, [attack("Vex", "rata1", "shortbow", 16, 21, 12, "hit")]}},
      {2600, {:rolls, [damage("Vex", "rata1", "piercing", [[6, 6], [6, 3]], 12)]}},
      {3200, {:turn, "Lyra", "combat"}},
      {500,
       {:rolls,
        [
          %{
            "who" => "Lyra",
            "kind" => "attack",
            "dice" => [[20, 4]],
            "total" => 9,
            "reason" =>
              dgettext("engine", "ataque con %{spell}", spell: Terms.spell("fire bolt")),
            "against" => ["ac", 12],
            "outcome" => "miss"
          }
        ]}},
      {2600,
       {:pc, "Lyra",
        dgettext(
          "ui",
          "—La humedad del suelo desvía mi puntería —murmura Lyra, ajustando el agarre del cayado—. Vex ya ha tumbado a la primera; a esta la recibimos entre Thane y yo."
        )}},
      {3800, {:turn, "Thane", "combat"}},
      {500, {:pc, "Thane", dgettext("ui", "Ataco a rata2 con mi espada larga.")}},
      {1400, {:rolls, [attack("Thane", "rata2", "longsword", 3, 8, 12, "miss")]}},
      {3200, {:turn, "dm", "combat"}},
      {300,
       {:dm,
        dgettext(
          "ui",
          "La rata2 se lanza sobre las botas de Thane con un chillido, buscando el tobillo desprotegido."
        )}},
      {2400, {:rolls, [attack("rata2", "Thane", "bite", 5, 9, 16, "miss")]}},
      {2600,
       {:dm,
        dgettext(
          "ui",
          "El morro húmedo muerde el aire: la cadena de malla desvía el bocado y las fauces de la rata resbalan contra el cuero húmedo de las botas sin encontrar carne."
        )}},
      {3800, {:turn, "Vex", "combat"}},
      {500, {:rolls, [attack("Vex", "rata2", "shortbow", 16, 21, 12, "hit")]}},
      {2600, {:rolls, [damage("Vex", "rata2", "piercing", [[6, 4], [6, 6]], 13)]}},
      {2600,
       {:pc, "Vex",
        dgettext(
          "ui",
          "La flecha se clava limpia en el lomo de la rata, que cae de costado entre la harina."
        )}},
      {2400, {:system, dgettext("engine", "⚔ El combate termina.")}}
    ]
  end

  defp initiative(who, d20, total),
    do: %{
      "who" => who,
      "kind" => "initiative",
      "dice" => [[20, d20]],
      "total" => total,
      "reason" => dgettext("engine", "tirada de iniciativa")
    }

  defp attack(who, target, weapon, d20, total, ac, outcome),
    do: %{
      "who" => who,
      "kind" => "attack",
      "dice" => [[20, d20]],
      "total" => total,
      "reason" =>
        dgettext("engine", "ataque a %{target} con %{weapon}",
          target: target,
          weapon: Terms.weapon(weapon)
        ),
      "against" => ["ac", ac],
      "outcome" => outcome
    }

  defp damage(who, target, type, dice, total),
    do: %{
      "who" => who,
      "kind" => "damage",
      "dice" => dice,
      "total" => total,
      "reason" =>
        dgettext("engine", "%{damage} a %{target}", damage: Terms.damage(type), target: target)
    }

  # Hold the finished excerpt this long before replaying from the start.
  @hold_ms 7000
  # Entries already on the parchment before the socket connects: the DM's
  # opening and the initiative, so the first paint is a game already running.
  @opening 3

  # Bone dice with rubric numerals on oxblood felt. dic_ex paints its table
  # platform and fog with faceEdge and its grid with border; matching them
  # hides the grid.
  @dice_palette Jason.encode!(%{
                  "face" => "#efe2c4",
                  "faceEdge" => "#3a1712",
                  "pip" => "#8a1c16",
                  "pipShadow" => "#c9b48a",
                  "border" => "#3a1712",
                  "sheen" => "#fff6df"
                })

  def opening, do: @opening
  def dice_palette, do: @dice_palette
  def length, do: Kernel.length(script())
  def hold_ms, do: @hold_ms

  @doc "Pause in ms before entry `step` (0-based) appears."
  def delay(step) do
    case Enum.at(script(), step) do
      {pause, _entry} -> pause
      nil -> raise FunctionClauseError, module: __MODULE__, function: :delay, arity: 1
    end
  end

  @doc "Raw entry at `step`."
  def entry(step), do: script() |> Enum.at(step) |> elem(1)

  @doc "Dice payload for the dic_ex hook when entry `step` rolls, else nil."
  def dice(step) do
    case entry(step) do
      {:rolls, rolls} ->
        groups =
          rolls
          |> Enum.flat_map(& &1["dice"])
          |> Enum.group_by(fn [sides, _] -> sides end, fn [_, value] -> value end)
          |> Enum.map(fn {sides, values} ->
            %{sides: sides, rolls: Enum.map(values, &%{value: &1, kept: true})}
          end)

        %{groups: groups, authoritative: true, nonce: "home-#{step}"}

      _ ->
        nil
    end
  end

  @doc "The latest roll among the first `count` entries, for the tray readout."
  def last_roll(count) do
    script()
    |> Enum.take(count)
    |> Enum.with_index()
    |> Enum.filter(&match?({{_, {:rolls, _}}, _}, &1))
    |> List.last()
    |> case do
      nil ->
        nil

      {{_, {:rolls, rolls}}, index} ->
        roll = List.last(rolls)

        %{
          id: index,
          who: roll["who"],
          total: roll["total"],
          outcome: RollFormat.outcome_label(roll["outcome"]),
          tone: RollFormat.outcome_css(roll["outcome"]),
          what: kind_label(roll["kind"])
        }
    end
  end

  @doc """
  The first `count` entries grouped into chronicle blocks, with the same view
  model the table renders (turn header, role, label, formatted roll line).
  """
  def blocks(count) do
    script()
    |> Enum.take(count)
    |> Enum.with_index()
    |> Enum.reduce([], fn {{_pause, entry}, index}, acc -> add(acc, entry, index) end)
    |> Enum.reverse()
    |> Enum.map(&%{&1 | lines: Enum.reverse(&1.lines)})
  end

  defp kind_label("attack"), do: dgettext("ui", "ataque")
  defp kind_label("damage"), do: dgettext("ui", "daño")
  defp kind_label("initiative"), do: dgettext("ui", "iniciativa")
  defp kind_label(_), do: dgettext("ui", "tirada")

  defp add(acc, {:turn, actor, phase}, index) do
    header = %{
      id: index,
      label: Chat.turn_header_label(actor, @viewer, false),
      class: Chat.th_actor_class(actor, @viewer, false),
      combat: phase == "combat"
    }

    [%{header: header, lines: []} | acc]
  end

  defp add([block | rest], {:rolls, rolls}, index) do
    lines =
      rolls
      |> Enum.with_index()
      |> Enum.map(fn {roll, i} ->
        %{
          id: "#{index}-#{i}",
          kind: :roll,
          who: roll["who"],
          text: RollFormat.format_line(roll),
          outcome: roll["outcome"]
        }
      end)

    [%{block | lines: Enum.reverse(lines) ++ block.lines} | rest]
  end

  defp add([block | rest], {:dm, text}, index),
    do: [%{block | lines: [%{id: index, kind: :dm, text: text} | block.lines]} | rest]

  defp add([block | rest], {:pc, who, text}, index),
    do: [%{block | lines: [%{id: index, kind: :pc, who: who, text: text} | block.lines]} | rest]

  defp add([block | rest], {:system, text}, index),
    do: [%{block | lines: [%{id: index, kind: :system, text: text} | block.lines]} | rest]
end
