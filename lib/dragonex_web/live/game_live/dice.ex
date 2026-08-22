defmodule DragonexWeb.GameLive.Dice do
  @moduledoc """
  The dice overlay FSM — modal tumble + labeled roll-group cards.

  Extracted from `DragonexWeb.GameLive.Show`. Owns the dice assigns' state
  machine: groups arriving within a debounce window coalesce into one tumble,
  the dic_ex hooks (2D theatre or 3D physics) report settle/land, and the
  overlay auto-hides after a hold window.
  """

  use Phoenix.Component

  import Phoenix.LiveView, only: [push_event: 3]

  alias DragonexWeb.GameLive.RollFormat

  # Coalesce dice that arrive within this window into one 2D tumble (an action
  # rolls several dice back-to-back). Then hold the result this long after the
  # dice settle before auto-hiding the overlay.
  @dice_debounce_ms 140
  @dice_hold_ms 2600

  # ---------------------------------------------------------------- events

  def dismiss(_params, socket) do
    if ref = socket.assigns[:dice_flush_ref], do: Process.cancel_timer(ref)
    if ref = socket.assigns[:dice_hide_ref], do: Process.cancel_timer(ref)

    {:noreply,
     socket
     |> assign(
       dice_show: false,
       dice_rolling: false,
       dice_hand: [],
       dice_groups: [],
       dice_flush_ref: nil,
       dice_hide_ref: nil
     )}
  end

  # The 2D hook reports every die finished its settle animation; reveal the
  # total and schedule auto-hide.
  def settled(_params, socket) do
    hide_ref = Process.send_after(self(), :hide_dice, @dice_hold_ms)
    {:noreply, assign(socket, dice_rolling: false, dice_hide_ref: hide_ref)}
  end

  # The 3D hook is physics-driven and reports landed faces instead of the 2D
  # settled event. Use those landed values for the modal total so the number
  # shown matches the face the player sees on top of the rendered dice.
  def landed(%{"values" => values}, socket) do
    hide_ref = Process.send_after(self(), :hide_dice, @dice_hold_ms)

    {:noreply,
     assign(socket,
       dice_hand: apply_landed_values(socket.assigns.dice_hand, values),
       dice_rolling: false,
       dice_hide_ref: hide_ref
     )}
  end

  def landed(_params, socket) do
    hide_ref = Process.send_after(self(), :hide_dice, @dice_hold_ms)
    {:noreply, assign(socket, dice_rolling: false, dice_hide_ref: hide_ref)}
  end

  # ------------------------------------------------------------------- info

  # A roll GROUP landed (RollLog on_close). It already carries the full labeled
  # entry — who rolled, why, dice, total, what it contested against, outcome —
  # so we open the modal ONCE per group with everything in one shot. Multiple
  # groups arriving within the debounce window (e.g. an attack's d20 then its
  # damage dice) collapse into a single tumble + a stack of labeled cards.
  def group_landed(socket, entry) do
    # Pull the dice of THIS group into the tumble hand, and stack the labeled
    # entry into the cards list. Both reset on each new group burst after the
    # hold timer fires (see hide/1).
    new_hand =
      Enum.map(entry["dice"] || entry[:dice] || [], fn
        [s, v] -> %{sides: s, value: v}
        {s, v} -> %{sides: s, value: v}
      end)

    hand = socket.assigns.dice_hand ++ new_hand
    groups = socket.assigns.dice_groups ++ [entry]

    if ref = socket.assigns[:dice_flush_ref], do: Process.cancel_timer(ref)
    if ref = socket.assigns[:dice_hide_ref], do: Process.cancel_timer(ref)

    token = socket.assigns.dice_token + 1
    flush_ref = Process.send_after(self(), {:flush_dice, token}, @dice_debounce_ms)

    {:noreply,
     socket
     |> assign(
       dice_hand: hand,
       dice_groups: groups,
       dice_show: true,
       dice_token: token,
       dice_flush_ref: flush_ref,
       dice_hide_ref: nil
     )}
  end

  # Flush the accumulated hand to the dic_ex hook as one tumble event. The token
  # guards against a cancelled-yet-already-fired timer double-pushing. The
  # labeled cards (dice_groups) are already in assigns and render beside the
  # tumble — no second pass needed.
  def flush(%{assigns: %{dice_token: token}} = socket, token) do
    payload = dice_payload(socket.assigns.dice_hand)

    hide_ref = Process.send_after(self(), :hide_dice, @dice_hold_ms)

    {:noreply,
     socket
     |> assign(dice_rolling: true, dice_flush_ref: nil, dice_hide_ref: hide_ref)
     |> push_event("dic_ex:roll:#{stage_id(socket.assigns.dice_engine)}", payload)}
  end

  # Stale token: the timer was cancelled but had already fired — drop the flush
  # so a cancelled-yet-fired timer can't double-push the tumble.
  def flush(socket, _stale_token), do: {:noreply, socket}

  def hide(socket) do
    {:noreply,
     assign(socket, dice_show: false, dice_hand: [], dice_groups: [], dice_hide_ref: nil)}
  end

  # ----------------------------------------------------------- dice helpers

  # Picks the LiveView hook name for the configured engine. The 2D hook is
  # server-authoritative theatre; the 3D hook is physics-driven and reports
  # landed faces back via dic_ex:landed:*.
  defp dice_hook("3d"), do: "DiceRoller"
  defp dice_hook(_), do: "DiceRoller2D"

  defp stage_id("3d"), do: "dice-stage-3d"
  defp stage_id(_), do: "dice-stage-2d"

  # Builds the roll payload the dic_ex hooks expect: dice grouped by sides, each
  # carrying the server-authoritative value used by 2D and by the final result.
  defp dice_payload(hand) do
    groups =
      hand
      |> Enum.group_by(& &1.sides)
      |> Enum.map(fn {sides, dice} ->
        %{sides: sides, rolls: Enum.map(dice, &%{value: &1.value, kept: true})}
      end)

    %{expression: dice_label(hand), total: dice_total(hand), groups: groups}
  end

  defp dice_entries(hand) do
    hand
    |> Enum.with_index(1)
    |> Enum.map(fn {%{sides: sides, value: value}, index} ->
      %{index: index, label: "d#{sides}", value: value}
    end)
  end

  defp dice_total(hand), do: Enum.sum(Enum.map(hand, & &1.value))

  defp apply_landed_values(hand, values) when is_list(hand) and is_list(values) do
    landed = Enum.map(values, &landed_value/1)

    valid? =
      length(hand) == length(landed) and
        Enum.all?(Enum.zip(hand, landed), fn
          {%{sides: sides}, value} when is_integer(value) -> value >= 1 and value <= sides
          _ -> false
        end)

    if valid? do
      hand
      |> Enum.zip(landed)
      |> Enum.map(fn {die, value} -> %{die | value: value} end)
    else
      hand
    end
  end

  defp apply_landed_values(hand, _values), do: hand

  defp landed_value(value) when is_integer(value), do: value
  defp landed_value(value) when is_float(value), do: round(value)

  defp landed_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp landed_value(_value), do: nil

  # "d20 + 2d6 + ..." style label from the accumulated hand.
  defp dice_label(hand) do
    hand
    |> Enum.group_by(& &1.sides)
    |> Enum.sort_by(fn {sides, _} -> sides end)
    |> Enum.map_join(" + ", fn {sides, dice} ->
      n = length(dice)
      if n == 1, do: "d#{sides}", else: "#{n}d#{sides}"
    end)
  end

  # ----------------------------------------------------------------- modal

  attr(:show, :boolean, default: false)
  attr(:rolling, :boolean, default: false)
  attr(:hand, :list, default: [])
  attr(:groups, :list, default: [])
  attr(:engine, :string, default: "2d")

  def stage(assigns) do
    assigns = assign(assigns, :stage_id, stage_id(assigns.engine))

    ~H"""
    <div class={"modal dice-overlay #{unless @show, do: "dice-hidden"}"} phx-click="dismiss_dice">
      <div class="modal-box dice-modal-box">
        <h2>🎲 Tirada</h2>
        <%!-- The dic_ex hook owns this element. It is always in the DOM (toggled
             via .dice-hidden) so push_event reliably reaches a mounted hook.
             The stage child is phx-update="ignore": the hook draws the dice
             canvases and LiveView must never diff them. --%>
        <div
          id={@stage_id}
          class={"dicex-roller dicex-engine-#{@engine}"}
          phx-hook={dice_hook(@engine)}
        >
          <div id={"#{@stage_id}-canvas"} class="dicex-stage" data-dicex-stage phx-update="ignore"></div>
        </div>

        <div :if={not @rolling and @groups != []} class="dice-groups">
          <.group_card :for={{g, i} <- Enum.with_index(@groups)} :key={i} g={g} />
        </div>
        <div :if={not @rolling and @groups == [] and @hand != []} class="dicex-result dice-results">
          <div class="dice-results-title">Resultados</div>
          <div class="dice-result-list">
            <div :for={die <- dice_entries(@hand)} :key={die.index} class="die-result">
              <span class="die-kind">{die.label}</span>
              <span class="die-value">{die.value}</span>
            </div>
          </div>
        </div>
        <div :if={@rolling}>
          <div class="dice-rolling-text">tirando…</div>
        </div>

        <p class="muted">(click para cerrar)</p>
      </div>
    </div>
    """
  end

  # One roll group as a labeled, comparison-aware card: who rolled, why, the
  # dice + modifier + total, and — for contests — the opposing side (AC/DC) with
  # the outcome colored. This is what makes "what was rolled and why it mattered"
  # legible at a glance.
  attr(:g, :map, required: true)

  def group_card(assigns) do
    assigns =
      assign(
        assigns,
        :outcome_css,
        RollFormat.outcome_css(assigns.g[:outcome] || assigns.g["outcome"])
      )

    ~H"""
    <div class={"dice-group #{@outcome_css}"}>
      <div class="dg-head">
        <span class="dg-who">{(@g[:who] || @g["who"] || "—")}</span>
        <span class="dg-reason">{(@g[:reason] || @g["reason"] || "")}</span>
      </div>
      <div class="dg-line">
        <span class="dg-dice">{RollFormat.format_dice(@g)}</span>
        <span class="dg-against">{RollFormat.format_against_spaced(@g)}</span>
      </div>
      <div class="dg-outcome">{RollFormat.outcome_label(@g[:outcome] || @g["outcome"])}</div>
    </div>
    """
  end
end
