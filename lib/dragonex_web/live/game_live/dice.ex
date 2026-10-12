defmodule DragonexWeb.GameLive.Dice do
  @moduledoc """
  The dice overlay FSM — modal tumble + labeled roll-group cards.

  Extracted from `DragonexWeb.GameLive.Show`. Owns the dice assigns' state
  machine: groups arriving within a debounce window coalesce into one tumble,
  the dic_ex hooks (2D theatre or 3D physics) report settle/land, and the
  overlay auto-hides after a hold window.
  """

  use Phoenix.Component
  use Gettext, backend: Dragonex.Gettext

  import Phoenix.LiveView, only: [push_event: 3]

  alias DragonexWeb.GameLive.RollFormat
  alias Phoenix.LiveView.JS

  # Coalesce dice that arrive within this window into one tumble (an action
  # rolls several dice back-to-back). Then hold the result this long after the
  # dice settle before auto-hiding the overlay.
  @dice_debounce_ms 140
  @dice_hold_ms 2600
  @dice_animation_timeout_ms 10_000

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
       dice_token: socket.assigns.dice_token + 1,
       dice_flush_ref: nil,
       dice_hide_ref: nil,
       dice_hide_token: nil
     )}
  end

  # The 2D hook reports every die finished its settle animation; reveal the
  # total and schedule auto-hide. The hook echoes the roll's nonce (our
  # dice_token), so a report from a superseded tumble is dropped. Reports
  # without a nonce (Hex dic_ex 0.2.0 hooks) fall back to the state guard.
  def settled(
        params,
        %{assigns: %{dice_show: true, dice_rolling: true, dice_flush_ref: nil}} = socket
      ) do
    if current_nonce?(params, socket) do
      {:noreply, socket |> assign(dice_rolling: false) |> schedule_hide()}
    else
      {:noreply, socket}
    end
  end

  def settled(_params, socket), do: {:noreply, socket}

  # Client physics acknowledges the animation; the committed engine roll
  # remains authoritative for the hand, total and outcome cards.
  def landed(params, socket), do: settled(params, socket)

  # ------------------------------------------------------------------- info

  # A roll GROUP landed (RollLog on_close). It already carries the full labeled
  # entry — who rolled, why, dice, total, what it contested against, outcome —
  # so we open the modal ONCE per group with everything in one shot. Multiple
  # groups arriving within the debounce window (e.g. an attack's d20 then its
  # damage dice) collapse into a single tumble + a stack of labeled cards.
  def group_landed(socket, entry) do
    # Pull the dice of THIS group into the tumble hand, and stack the labeled
    # entry into the cards list. A roll by someone else than the burst on
    # screen starts a new one: an AI round no longer piles up every
    # creature's cards in one window.
    new_hand =
      Enum.map(entry["dice"] || entry[:dice] || [], fn
        [s, v] -> %{sides: s, value: v}
        {s, v} -> %{sides: s, value: v}
      end)

    fresh? =
      not socket.assigns.dice_show or
        roller(List.last(socket.assigns.dice_groups)) != roller(entry)

    {hand, groups} =
      if fresh?,
        do: {new_hand, [entry]},
        else: {socket.assigns.dice_hand ++ new_hand, socket.assigns.dice_groups ++ [entry]}

    # Only the viewer's own roll takes the screen; everyone else's goes to a
    # tray that leaves the chronicle and the input usable.
    mine? = roller(entry) == socket.assigns[:viewer]

    mode =
      if mine? or (not fresh? and socket.assigns[:dice_mode] == "modal"),
        do: "modal",
        else: "tray"

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
       dice_mode: mode,
       dice_rolling: true,
       dice_token: token,
       dice_flush_ref: flush_ref,
       dice_hide_ref: nil,
       dice_hide_token: nil
     )}
  end

  # Flush the accumulated hand to the dic_ex hook as one tumble event. The token
  # guards against a cancelled-yet-already-fired timer double-pushing. The
  # labeled cards (dice_groups) are already in assigns and render beside the
  # tumble — no second pass needed.
  def flush(
        %{assigns: %{dice_token: token, dice_show: true, dice_flush_ref: ref}} = socket,
        token
      )
      when is_reference(ref) do
    Process.cancel_timer(ref)
    payload = Map.put(dice_payload(socket.assigns.dice_hand), :nonce, token)

    {:noreply,
     socket
     |> assign(dice_rolling: true, dice_flush_ref: nil)
     |> schedule_animation_timeout()
     |> push_event(
       "dic_ex:roll:#{stage_id(effective_engine(socket.assigns.dice_engine))}",
       payload
     )}
  end

  # Stale token: the timer was cancelled but had already fired — drop the flush
  # so a cancelled-yet-fired timer can't double-push the tumble.
  def flush(socket, _stale_token), do: {:noreply, socket}

  # If the renderer fails to acknowledge, reveal the committed cards anyway.
  # The reading window starts here, rather than closing an unseen result.
  def animation_timeout(
        %{assigns: %{dice_hide_token: token, dice_show: true, dice_rolling: true}} = socket,
        token
      )
      when is_reference(token),
      do: settled(%{"nonce" => socket.assigns.dice_token}, socket)

  def animation_timeout(socket, _stale_token), do: {:noreply, socket}

  def hide(
        %{assigns: %{dice_hide_token: token, dice_show: true, dice_rolling: false}} = socket,
        token
      )
      when is_reference(token),
      do: dismiss(%{}, socket)

  def hide(socket, _stale_token), do: {:noreply, socket}

  # Unversioned messages from the old renderer cannot identify a current roll.
  def hide(socket), do: {:noreply, socket}

  defp roller(nil), do: nil
  defp roller(entry), do: entry["who"] || entry[:who]

  defp current_nonce?(params, socket) do
    case params do
      %{"nonce" => nonce} when not is_nil(nonce) -> nonce == socket.assigns.dice_token
      _ -> true
    end
  end

  defp schedule_hide(socket) do
    schedule_timer(socket, :hide_dice, @dice_hold_ms)
  end

  defp schedule_animation_timeout(socket) do
    schedule_timer(socket, :dice_animation_timeout, @dice_animation_timeout_ms)
  end

  defp schedule_timer(socket, message, timeout) do
    if ref = socket.assigns[:dice_hide_ref], do: Process.cancel_timer(ref)
    token = make_ref()
    ref = Process.send_after(self(), {message, token}, timeout)
    assign(socket, dice_hide_ref: ref, dice_hide_token: token)
  end

  # ----------------------------------------------------------- dice helpers

  @doc "Whether the installed package can reveal the engine's committed faces in 3D."
  def three_d_available? do
    Code.ensure_loaded?(DicEx) and function_exported?(DicEx, :renderer_capabilities, 0) and
      match?(%{authoritative_3d: true}, apply(DicEx, :renderer_capabilities, []))
  end

  @doc "Resolve a saved/view preference to the mode supported by the installed package."
  def effective_engine("3d"), do: if(three_d_available?(), do: "3d", else: "2d")
  def effective_engine(_), do: "2d"

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

    %{expression: dice_label(hand), total: dice_total(hand), groups: groups, authoritative: true}
  end

  defp dice_entries(hand) do
    hand
    |> Enum.with_index(1)
    |> Enum.map(fn {%{sides: sides, value: value}, index} ->
      %{index: index, label: "d#{sides}", value: value}
    end)
  end

  defp dice_total(hand), do: Enum.sum(Enum.map(hand, & &1.value))

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

  attr(:engine, :string, default: "2d")
  attr(:rolling, :boolean, default: false)

  def engine_control(assigns) do
    assigns =
      assign(assigns, engine: effective_engine(assigns.engine), available: three_d_available?())

    ~H"""
    <button :if={@available} class="ctl-btn" phx-click="toggle_dice_engine" disabled={@rolling}
      aria-label={dgettext("ui", "Dados %{engine}. Cambiar a %{other}.", engine: String.upcase(@engine), other: if(@engine == "3d", do: "2D", else: "3D"))}
      title={dgettext("ui", "Cambiar a dados %{other}", other: if(@engine == "3d", do: "2D", else: "3D"))}>
      <i class="px px-d20" aria-hidden="true"></i>{String.upcase(@engine)}
    </button>
    <span :if={not @available} id="dice-engine-mode" class="ctl-mode">
      <i class="px px-d20" aria-hidden="true"></i>{dgettext("ui", "Dados 2D")}
    </span>
    """
  end

  attr(:engine, :string, default: "2d")

  def engine_picker(assigns) do
    assigns =
      assign(assigns, engine: effective_engine(assigns.engine), available: three_d_available?())

    ~H"""
    <div class="engine-toggle">
      <button type="button" class={"engine-opt #{if @engine == "2d", do: "sel", else: ""}"}
        aria-pressed={to_string(@engine == "2d")} phx-click="pick_engine" phx-value-engine="2d">
        <span class="eo-tk"><i class="px px-d20" aria-hidden="true"></i></span>
        <span class="eo-n">2D</span><span class="eo-d">{dgettext("ui", "Rápidos y ligeros")}</span>
      </button>
      <button type="button" class={"engine-opt #{if @engine == "3d", do: "sel", else: ""}"}
        aria-pressed={to_string(@engine == "3d")} phx-click="pick_engine" phx-value-engine="3d"
        disabled={not @available}>
        <span class="eo-tk"><i class="px px-orb" aria-hidden="true"></i></span>
        <span class="eo-n">3D</span><span class="eo-d">{if @available, do: dgettext("ui", "Ruedan sobre la mesa"), else: dgettext("ui", "No disponible")}</span>
      </button>
    </div>
    """
  end

  # ----------------------------------------------------------------- modal

  attr(:show, :boolean, default: false)
  attr(:mode, :string, default: "modal")
  attr(:rolling, :boolean, default: false)
  attr(:hand, :list, default: [])
  attr(:groups, :list, default: [])
  attr(:engine, :string, default: "2d")

  def stage(assigns) do
    assigns = assign(assigns, :engine, effective_engine(assigns.engine))
    assigns = assign(assigns, :stage_id, stage_id(assigns.engine))

    ~H"""
    <%!-- The same stage serves both modes so the dic_ex hook never remounts:
         "modal" for the viewer's own roll, "tray" (corner, no backdrop, no
         focus capture) for everyone else's. --%>
    <div
      class={"modal dice-overlay dice-#{@mode} #{unless @show, do: "dice-hidden"}"}
      inert={not @show}
      phx-click={if @mode == "modal", do: "dismiss_dice"}
      phx-window-keydown={if @show and @mode == "modal", do: "dismiss_dice"}
      phx-key="escape"
    >
      <.focus_wrap id="dice-dialog" class="modal-box dice-modal-box"
        role={if @mode == "modal", do: "dialog", else: "status"}
        aria-modal={to_string(@mode == "modal")} aria-labelledby="dice-dialog-title"
        aria-describedby={if @mode == "modal", do: "dice-dialog-help"}
        aria-live={if @mode == "tray", do: "polite"}
        aria-hidden={to_string(not @show)} tabindex="-1">
        <h2 id="dice-dialog-title"><i class="px px-d20" aria-hidden="true"></i>{dgettext("ui", "Tirada")}</h2>
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
          <div class="dice-results-title">{dgettext("ui", "Resultados")}</div>
          <div class="dice-result-list">
            <div :for={die <- dice_entries(@hand)} :key={die.index} class="die-result">
              <span class="die-kind">{die.label}</span>
              <span class="die-value">{die.value}</span>
            </div>
          </div>
        </div>
        <div :if={@rolling}>
          <div class="dice-rolling-text">{dgettext("ui", "tirando…")}</div>
        </div>

        <button :if={@show and @mode == "modal"} id="dice-close" type="button" class="btn btn-sm dice-close"
          phx-click="dismiss_dice"
          phx-mounted={JS.push_focus(to: ":focus") |> JS.focus(to: "#dice-close")}
          phx-remove={JS.pop_focus()}>
          {dgettext("ui", "Cerrar tirada")}
        </button>
        <button :if={@show and @mode == "tray"} id="dice-tray-close" type="button" class="btn btn-sm dice-close"
          phx-click="dismiss_dice" aria-label={dgettext("ui", "Cerrar tirada")}>×</button>
        <p :if={@mode == "modal"} id="dice-dialog-help" class="dice-dismiss">{dgettext("ui", "Escape o toca para cerrar")}</p>
      </.focus_wrap>
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
        <span class="dg-against">{RollFormat.format_against_spaced(@g[:against] || @g["against"])}</span>
      </div>
      <div class="dg-outcome">{RollFormat.outcome_label(@g[:outcome] || @g["outcome"])}</div>
    </div>
    """
  end
end
