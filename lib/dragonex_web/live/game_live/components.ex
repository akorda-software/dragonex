defmodule DragonexWeb.GameLive.Components do
  @moduledoc """
  Presentational function components for the game table: the turn bar, the
  character cards (combat tracker + detail sheet).

  Extracted from `DragonexWeb.GameLive.Show` so the markup + its tiny view
  helpers (`turn_label/3`, `cond_name/1`) live apart from the LiveView's event
  handling and state. The dice modal (`dice_stage`, `dice_group_card`) stays in
  the LiveView because it is wired to the dice FSM handlers.
  """

  use Phoenix.Component

  alias Dragonex.World

  # ----------------------------------------------------------------- turn bar

  attr(:world, :any, default: nil)
  attr(:current, :any, default: nil)
  attr(:round, :integer, default: 1)
  attr(:status, :any, default: nil)
  attr(:viewer, :any, default: nil)

  def turn_bar(%{
        world: %World{phase: :combat} = w,
        current: current,
        round: round,
        status: status,
        viewer: viewer
      }) do
    assigns = %{w: w, current: current, round: round, status: status, viewer: viewer}

    ~H"""
    <span class="round">Round {@round}</span>
    <ul class="initiative">
      <li :for={name <- @w.initiative_order} :key={name} class={if World.controller_of(@w, name) == @current, do: "active", else: ""}>
        {name}
      </li>
    </ul>
    <span class="whose-turn">{turn_label(@current, @status, @viewer)}</span>
    """
  end

  def turn_bar(%{current: current, status: status, viewer: viewer}) do
    assigns = %{current: current, status: status, viewer: viewer}

    ~H"""
    <span class="phase">Exploración</span>
    <span class="whose-turn">{turn_label(@current, @status, @viewer)}</span>
    """
  end

  defp turn_label(viewer, _, viewer) when is_binary(viewer), do: "¡Tu turno!"
  defp turn_label(current, :paused, _) when current != nil, do: "En pausa"
  defp turn_label("dm", _, _), do: "Turno del DM"
  defp turn_label(other, _, _) when is_binary(other), do: "Esperando a #{other}"
  defp turn_label(_, _, _), do: ""

  # --------------------------------------------------------------- sheet card

  attr(:card, :map, default: nil)
  attr(:active, :boolean, default: false)
  attr(:mine, :boolean, default: false)

  def sheet(assigns) do
    ~H"""
    <%= if @card do %>
      <% card = @card
         pct = if card.max_hp > 0, do: max(0, card.hp) / card.max_hp * 100, else: 0
         status = if card.hp <= 0, do: " [DOWN]", else: ""
         conds = Enum.map(card.conditions || [], &cond_name/1) %>
      <div class={"card side-#{card.side}#{if @active, do: " your-turn", else: ""}#{if @mine, do: " mine", else: ""}"}>
        <h3>
          {card.name}{status}<span :if={@mine} class="you-tag">TÚ</span>
        </h3>
        <p class="muted">{card.class} · {card.side}</p>
        <div class="hp"><div class="hp-fill" style={"width:#{pct}%"}></div></div>
        <p>HP {card.hp}/{card.max_hp} · AC {card.ac}</p>
        <p :if={conds != []} class="conds">
          <span :for={c <- conds} class="cond-badge">{c}</span>
        </p>
      </div>
    <% else %>
      <div class="empty-sheet muted">— vacío —</div>
    <% end %>
    """
  end

  # ----------------------------------------------------------- combat tracker

  # A scrollable initiative tracker shown in the left rail during combat: every
  # combatant in turn order with an HP bar, AC, conditions and a clear marker on
  # whoever is acting right now.
  attr(:world, :any, required: true)
  attr(:current, :any, default: nil)
  attr(:round, :integer, default: 1)
  attr(:viewer, :any, default: nil)

  def combat_tracker(assigns) do
    ~H"""
    <div class="combat-tracker">
      <div class="ct-header">
        <span>⚔</span> Iniciativa <span class="ct-round">Ronda {@round}</span>
      </div>
      <div class="ct-list">
        <div :for={name <- @world.initiative_order} :key={name}>
          <.combatant world={@world} name={name} current={@current} viewer={@viewer} />
        </div>
      </div>
    </div>
    """
  end

  attr(:world, :any, required: true)
  attr(:name, :string, required: true)
  attr(:current, :any, default: nil)
  attr(:viewer, :any, default: nil)

  def combatant(assigns) do
    c = Map.get(assigns.world.characters, assigns.name)
    acting = World.controller_of(assigns.world, assigns.name) == assigns.current
    pct = if c && c.max_hp > 0, do: max(0, c.hp) / c.max_hp * 100, else: 0
    conds = if c, do: Enum.map(c.conditions || [], &cond_name/1), else: []

    assigns =
      assign(assigns, c: c, acting: acting, pct: pct, down: c && c.hp <= 0, conds: conds)

    ~H"""
    <div class={"combatant side-#{(@c && @c.side) || "pc"}#{if @acting, do: " acting", else: ""}#{if @name == @viewer, do: " mine", else: ""}"}>
      <span class="ct-mark">{if @acting, do: "▶", else: ""}</span>
      <div class="ct-body">
        <div class="ct-name">
          {@name}<span :if={@name == @viewer} class="you-tag">TÚ</span><span :if={@down} class="ct-down"> ✖</span>
        </div>
        <div class="hp"><div class="hp-fill" style={"width:#{@pct}%"}></div></div>
        <div class="ct-stats">HP {(@c && @c.hp) || 0}/{(@c && @c.max_hp) || 0} · CA {(@c && @c.ac) || "?"}</div>
        <div :if={@conds != []} class="conds">
          <span :for={cd <- @conds} class="cond-badge">{cd}</span>
        </div>
      </div>
    </div>
    """
  end

  # The viewer's own detailed sheet (combat): full stats + weapons/spells so the
  # player has their full character at hand while the tracker shows everyone.
  attr(:card, :map, default: nil)

  def detail_sheet(assigns) do
    ~H"""
    <%= if @card do %>
      <% card = @card
         pct = if card.max_hp > 0, do: max(0, card.hp) / card.max_hp * 100, else: 0
         conds = Enum.map(card.conditions || [], &cond_name/1)
         weapons = Enum.map(card.weapons || [], & &1.name)
         spells = Enum.map(card.spells || [], & &1.name) %>
      <div class="sheet">
        <div class="card mine">
          <h3>{card.name}<span class="you-tag">TÚ</span></h3>
          <p class="muted">{card.race} {card.class} · niv {card.level}</p>
          <div class="hp"><div class="hp-fill" style={"width:#{pct}%"}></div></div>
          <p>HP {card.hp}/{card.max_hp} · CA {card.ac}</p>
          <p class="muted">STR {card.str} · DEX {card.dex} · CON {card.con}<br />INT {card.int} · WIS {card.wis} · CHA {card.cha}</p>
          <p :if={weapons != []}><span class="muted">Armas:</span> {Enum.join(weapons, ", ")}</p>
          <p :if={spells != []}><span class="muted">Hechizos:</span> {Enum.join(spells, ", ")}</p>
          <p :if={conds != []} class="conds">
            <span :for={c <- conds} class="cond-badge">{c}</span>
          </p>
        </div>
      </div>
    <% end %>
    """
  end

  # ----------------------------------------------- shared condition formatter

  # Normalizes a condition entry (struct/map/binary shape from jsonb or live
  # state) into a display label.
  defp cond_name(%{condition: c}), do: c
  defp cond_name(%{"condition" => c}), do: c
  defp cond_name(c) when is_binary(c), do: c
  defp cond_name(_), do: "?"
end
