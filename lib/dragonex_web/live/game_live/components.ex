defmodule DragonexWeb.GameLive.Components do
  @moduledoc """
  Presentational function components for the game table: the full table layout
  (topbar, chat timeline, rails, input), the waiting room, the turn bar and the
  character cards (combat tracker + detail sheet).

  Extracted from `DragonexWeb.GameLive.Show` so the markup + its tiny view
  helpers live apart from the LiveView's event handling and state. The chat
  view-model builders live in `DragonexWeb.GameLive.Chat`, the dice overlay in
  `DragonexWeb.GameLive.Dice` and the Ajustes modal in
  `DragonexWeb.GameLive.Settings`.
  """

  use Phoenix.Component
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{Character, ClassResources, Rest, SpellSlots, WildShape, World}
  alias Dragonex.Rules.Effects
  alias Dragonex.Heroes.{Catalog, Translations}
  alias DragonexWeb.GameLive.{Chat, Dice, Settings}

  @max_scene_sheets 2

  # ----------------------------------------------------------------- turn bar

  attr(:world, :any, default: nil)
  attr(:current, :any, default: nil)
  attr(:round, :integer, default: 1)
  attr(:status, :any, default: nil)
  attr(:viewer, :any, default: nil)
  attr(:is_creator, :boolean, default: true)

  def turn_bar(
        %{
          world: %World{phase: :combat} = w,
          current: current,
          round: round,
          status: status,
          viewer: viewer
        } = assigns
      ) do
    label =
      cond do
        status == :paused ->
          paused_label(assigns)

        current == "dm" and is_binary(w.current_combatant) ->
          dgettext("ui", "Turno de %{actor}", actor: w.current_combatant)

        true ->
          turn_label(current, status, viewer)
      end

    assigns = %{
      w: w,
      current: current,
      round: round,
      status: status,
      viewer: viewer,
      label: label
    }

    ~H"""
    <span class="round"><i class="px px-swords" aria-hidden="true"></i>{dgettext("ui", "Ronda %{round}", round: @round)}</span>
    <ol class="initiative" aria-label={dgettext("ui", "Orden de iniciativa")}>
      <li
        :for={name <- @w.initiative_order}
        :key={name}
        class={initiative_chip_class(@w, name, @current)}
        title={chip_title(@w.characters[name])}
      >
        <span class="ini-name">{name}</span>
        <span :if={@w.characters[name]} class={"ini-hp #{hp_level(hp_pct(@w.characters[name]))}"} aria-hidden="true">
          <span style={"width:#{hp_pct(@w.characters[name])}%"}></span>
        </span>
      </li>
    </ol>
    <span class={"whose-turn#{if @current == @viewer and @status == :waiting and is_binary(@viewer), do: " is-mine", else: ""}"}>{@label}</span>
    """
  end

  def turn_bar(%{current: current, status: status, viewer: viewer} = assigns) do
    label =
      if status == :paused, do: paused_label(assigns), else: turn_label(current, status, viewer)

    assigns = %{current: current, status: status, viewer: viewer, label: label}

    ~H"""
    <span class="phase"><i class="px px-boot" aria-hidden="true"></i>{dgettext("ui", "Exploración")}</span>
    <span class={"whose-turn#{if @current == @viewer and @status == :waiting and is_binary(@viewer), do: " is-mine", else: ""}"}>{@label}</span>
    """
  end

  # On mobile the initiative strip is the only combat overview outside the
  # drawer: each chip carries its side, a mini HP bar and whether it is down.
  defp initiative_chip_class(world, name, current) do
    c = world.characters[name]

    [
      if(World.acting?(world, name, current), do: "active"),
      c && "side-#{c.side}",
      c && c.hp <= 0 && "is-down"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp chip_title(nil), do: nil

  defp chip_title(c) do
    conds = Enum.map(c.conditions || [], &cond_name/1) ++ status_flags(c)
    Enum.join([hp_line(c) | conds], " · ")
  end

  # Only the creator holds «Reanudar»; a pause note asking to resume must not
  # leave a guest looking for a control they do not have (D228).
  defp paused_label(%{is_creator: false} = assigns),
    do: dgettext("ui", "%{pause} · la reanuda quien creó la partida", pause: paused_turn(assigns))

  defp paused_label(assigns), do: paused_turn(assigns)

  # «En pausa · tu turno» tells the player what resuming leads to.
  defp paused_turn(%{current: viewer, viewer: viewer}) when is_binary(viewer) and viewer != "dm",
    do: dgettext("ui", "En pausa · tu turno")

  defp paused_turn(%{current: current} = assigns) when is_binary(current) do
    case actor_name(current, Map.get(assigns, :world)) do
      nil -> dgettext("ui", "En pausa · turno del DM")
      actor -> dgettext("ui", "En pausa · turno de %{actor}", actor: actor)
    end
  end

  defp paused_turn(_), do: dgettext("ui", "En pausa")

  # The DM's participant id never reaches the table: in combat its turn
  # belongs to the acting monster or NPC; otherwise it is nil («del DM»).
  defp actor_name("dm", %World{phase: :combat, current_combatant: name}) when is_binary(name),
    do: name

  defp actor_name("dm", _world), do: nil
  defp actor_name(actor, _world), do: actor

  defp turn_label(viewer, :waiting, viewer) when is_binary(viewer),
    do: dgettext("ui", "¡Tu turno!")

  defp turn_label(viewer, :running, viewer) when is_binary(viewer),
    do: dgettext("ui", "Resolviendo tu acción")

  defp turn_label("dm", _, _), do: dgettext("ui", "Turno del DM")

  defp turn_label(other, _, _) when is_binary(other),
    do: dgettext("ui", "Esperando a %{actor}", actor: other)

  defp turn_label(_, _, _), do: ""

  # --------------------------------------------------------------- sheet card

  attr(:card, :map, default: nil)
  attr(:active, :boolean, default: false)
  attr(:mine, :boolean, default: false)
  attr(:world, :any, default: nil)

  def sheet(assigns) do
    ~H"""
    <%= if @card do %>
      <% card = @card
         pct = hp_pct(card)
         conds = Enum.map(card.conditions || [], &cond_name/1) ++ status_flags(card) %>
      <div class={"card side-#{card.side}#{if @active, do: " your-turn", else: ""}#{if @mine, do: " mine", else: ""}#{if card.hp <= 0, do: " is-down", else: ""}"}>
        <div class="card-head">
          <h3 class="card-name">{card.name}</h3>
          <span :if={@mine} class="you-tag">{dgettext("ui", "TÚ")}</span>
          <span :if={vital_label(card)} class="down-tag"><i class="px px-skull" aria-hidden="true"></i>{vital_label(card)}</span>
        </div>
        <p class="card-sub">{card_sub(card)}</p>
        <p :if={conds != []} class="conds">
          <span :for={c <- conds} class="cond-badge">{c}</span>
        </p>
        <.hp_bar pct={pct} />
        <p class="card-stats">{hp_line(card)}</p>
        <.sheet_resources :if={@mine} card={card} world={@world} />
        <.sheet_inventory :if={@mine} card={card} />
        <p :if={@mine and is_map(card.wild_shape) and (card.spells || []) != []} class="card-list">{dgettext("ui", "Vuelve a tu forma original para lanzar conjuros.")}</p>
      </div>
    <% else %>
      <div class="empty-sheet"><span>{dgettext("ui", "Silla vacía")}</span></div>
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
        <i class="px px-swords" aria-hidden="true"></i> {dgettext("ui", "Iniciativa")} <span class="ct-round">{dgettext("ui", "Ronda %{round}", round: @round)}</span>
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
    acting = World.acting?(assigns.world, assigns.name, assigns.current)
    pct = if c, do: hp_pct(c), else: 0
    conds = if c, do: Enum.map(c.conditions || [], &cond_name/1) ++ status_flags(c), else: []

    assigns =
      assign(assigns, c: c, acting: acting, pct: pct, down: c && c.hp <= 0, conds: conds)

    ~H"""
    <div class={"combatant side-#{(@c && @c.side) || "pc"}#{if @acting, do: " acting", else: ""}#{if @name == @viewer, do: " mine", else: ""}"}>
      <span class="ct-mark"><i :if={@acting} class="px px-arrow" aria-label={dgettext("ui", "actuando")}></i></span>
      <div class="ct-body">
        <div class="ct-name">
          <span>{@name}</span><span :if={@name == @viewer} class="you-tag">{dgettext("ui", "TÚ")}</span><i :if={@down} class="px px-skull ct-down" aria-label={dgettext("ui", "caído")}></i>
        </div>
        <.hp_bar pct={@pct} />
        <div class="ct-stats">{if @c, do: hp_line(@c), else: dgettext("ui", "HP 0/0 · CA ?")}</div>
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
  attr(:world, :any, default: nil)

  def detail_sheet(assigns) do
    ~H"""
    <%= if @card do %>
      <% card = @card
         pct = hp_pct(card)
         conds = Enum.map(card.conditions || [], &cond_name/1) ++ status_flags(card)
         weapons = Enum.map(card.weapons || [], &Catalog.weapon_label/1)
         spells = Enum.map(card.spells || [], &Catalog.spell_label/1) %>
      <div class="sheet">
        <div class={"card mine detail side-#{card.side}"}>
          <div class="card-head">
            <h3 class="card-name">{card.name}</h3>
            <span class="you-tag">{dgettext("ui", "TÚ")}</span>
          </div>
          <p :if={vital_label(card)} class="card-vital">{vital_label(card)}</p>
          <.hp_bar pct={pct} />
          <p class="card-stats">{hp_line(card)}</p>
          <p class="card-sub">{Catalog.race_label(card.race)} {Catalog.class_label(card.class)} · {dgettext("ui", "nivel %{level}", level: card.level)}</p>
          <p :if={conds != []} class="conds">
            <span :for={c <- conds} class="cond-badge">{c}</span>
          </p>
          <p :if={vital_label(card) == dgettext("ui", "Caído")} class="death-save-state">
            {death_saves_line(card)}
          </p>
          <.sheet_resources card={card} world={@world} />
          <div class="abil-grid">
            <div :for={ab <- [:str, :dex, :con, :int, :wis, :cha]} class="abil">
              <span>{Translations.ability_short(ab)}</span>
              <strong>{Map.get(card, ab)}</strong>
            </div>
          </div>
          <p :if={weapons != []} class="card-list"><span>{dgettext("ui", "Armas")}</span>{Enum.join(weapons, ", ")}</p>
          <p :if={spells != []} class="card-list"><span>{dgettext("ui", "Hechizos")}</span>{Enum.join(spells, ", ")}</p>
          <p :if={is_map(card.wild_shape) and spells != []} class="card-list">{dgettext("ui", "Vuelve a tu forma original para lanzar conjuros.")}</p>
          <.sheet_inventory card={card} />
        </div>
      </div>
    <% end %>
    """
  end

  attr(:card, :map, required: true)

  def sheet_inventory(assigns) do
    ~H"""
    <section class="sheet-inventory" aria-label={dgettext("ui", "Inventario de %{name}", name: @card.name)}>
      <p class="card-list"><span>{dgettext("ui", "Inventario")}</span></p>
      <ul :if={(@card.inventory || []) != []} class="inventory-list" tabindex="0" aria-label={dgettext("ui", "Objetos de %{name}", name: @card.name)}>
        <li :for={item <- @card.inventory}>
          <span>{Catalog.item_label(item)}</span><span class="inventory-quantity">×{item.qty}</span>
        </li>
      </ul>
      <p :if={(@card.inventory || []) == []} class="inventory-empty">{dgettext("ui", "Sin objetos registrados.")}</p>
    </section>
    """
  end

  attr(:card, :map, required: true)
  attr(:world, :any, default: nil)

  def sheet_resources(assigns) do
    known? =
      match?(%World{}, assigns.world) and
        Map.has_key?(assigns.world.characters, assigns.card.name)

    slots = if known?, do: Map.get(assigns.world.spell_slots, assigns.card.name)

    capacity =
      if is_integer(assigns.card.level),
        do: SpellSlots.for_class(assigns.card.class, assigns.card.level),
        else: %{}

    dice = if known?, do: Rest.remaining(assigns.world, assigns.card.name)

    pools =
      if known?, do: ClassResources.pools(assigns.world.characters[assigns.card.name]), else: []

    original_form = if known?, do: assigns.world.characters[assigns.card.name].wild_shape

    assigns =
      assign(assigns,
        known: known?,
        slots: slots,
        slot_capacity: capacity,
        hit_dice: dice,
        class_pools: pools,
        original_form: original_form,
        original_hit_points: original_hit_points(original_form)
      )

    ~H"""
    <dl :if={@known} class="sheet-resources">
      <div :if={is_map(@original_form)} data-resource="native-hit-points">
        <dt>{dgettext("ui", "Forma original")}</dt>
        <dd class={if @original_hit_points == dgettext("ui", "Sin registrar"), do: "resource-note", else: ""}>{@original_hit_points}</dd>
      </div>
      <div data-resource="hit-dice">
        <dt>{dgettext("ui", "Dados de golpe")}</dt>
        <dd class={if @hit_dice == 0, do: "resource-spent", else: ""}>{@hit_dice}/{@card.level} · d{World.hit_die_size(@card.class)}</dd>
      </div>
      <div :if={SpellSlots.caster?(@card.class)} class="spell-reserve-label">
        <dt>{if SpellSlots.pact_caster?(@card.class), do: dgettext("ui", "Casillas de pacto"), else: dgettext("ui", "Casillas de conjuro")}</dt>
        <dd :if={@slots == nil} class="resource-note">{dgettext("ui", "Casillas sin registro")}</dd>
      </div>
      <div :for={{level, count} <- Enum.sort(@slots || %{})} data-resource={"spell-slot-#{level}"}>
        <dt>{dgettext("ui", "Nivel %{level}", level: level)}</dt>
        <dd class={if count == 0, do: "resource-spent", else: ""}>{slot_line(count, Map.get(@slot_capacity, level))}</dd>
      </div>
      <div :if={@card.class == "fighter"} data-resource="second-wind">
        <dt>{dgettext("ui", "Segundo aliento")}</dt>
        <dd class={if @card.second_wind_used, do: "resource-spent", else: ""}>{if @card.second_wind_used, do: dgettext("ui", "Gastado"), else: dgettext("ui", "Disponible")}</dd>
      </div>
      <div :for={pool <- @class_pools} data-resource={pool.field}>
        <dt>{pool.label}</dt>
        <dd class={if pool.remaining == 0, do: "resource-spent", else: ""}>{dgettext("ui", "%{remaining}/%{capacity} disponibles", remaining: pool.remaining, capacity: pool.capacity)}</dd>
      </div>
    </dl>
    """
  end

  # Sorcery points can fund a slot beyond the table capacity; then the count
  # alone is the truth.
  defp slot_line(count, capacity) when is_integer(capacity) and count <= capacity,
    do:
      dgettext("ui", "%{remaining}/%{capacity} disponibles", remaining: count, capacity: capacity)

  defp slot_line(count, _capacity),
    do: dngettext("ui", "%{count} disponible", "%{count} disponibles", count)

  defp original_hit_points(%{orig_hp: hp, orig_max_hp: max_hp})
       when is_integer(hp) and hp >= 0 and is_integer(max_hp) and max_hp > 0,
       do: dgettext("ui", "%{hp}/%{max_hp} PG", hp: hp, max_hp: max_hp)

  defp original_hit_points(_), do: dgettext("ui", "Sin registrar")

  # ----------------------------------------------- shared condition formatter

  # Normalizes a condition entry (struct/map/binary shape from jsonb or live
  # state) into a display label.
  defp cond_name(%{condition: c}), do: c
  defp cond_name(%{"condition" => c}), do: c
  defp cond_name(c) when is_binary(c), do: c
  defp cond_name(_), do: "?"

  defp hp_line(card) do
    temp = card.temp_hp || 0
    temp_bit = if temp > 0, do: dgettext("ui", " +%{amount} temp", amount: temp), else: ""
    ac = if is_integer(card.ac), do: Effects.effective_ac(card), else: "?"

    dgettext("ui", "HP %{hp}/%{max_hp}%{temp} · CA %{ac}",
      hp: card.hp,
      max_hp: card.max_hp,
      temp: temp_bit,
      ac: ac
    )
  end

  defp death_saves_line(card) do
    successes = save_count(card, :successes)
    fails = save_count(card, :fails)

    dgettext("ui", "Salvaciones de muerte: %{successes} · %{failures}",
      successes: dngettext("ui", "%{count} éxito", "%{count} éxitos", successes),
      failures: dngettext("ui", "%{count} fallo", "%{count} fallos", fails)
    )
  end

  defp vital_label(%{death_saves: %{fails: fails}}) when fails >= 3, do: dgettext("ui", "Muerto")

  defp vital_label(%{hp: hp, death_saves: %{successes: successes}})
       when is_integer(hp) and hp <= 0 and successes >= 3,
       do: dgettext("ui", "Estable")

  defp vital_label(%{hp: hp}) when is_integer(hp) and hp <= 0, do: dgettext("ui", "Caído")
  defp vital_label(_), do: nil
  defp save_count(card, kind), do: Map.get(card.death_saves || %{}, kind, 0)

  defp hp_pct(%{max_hp: max, hp: hp}) when is_integer(max) and max > 0,
    do: max(0, hp) / max * 100

  defp hp_pct(_), do: 0

  # Segmented pixel HP bar; the fill turns amber then red as it drains.
  attr(:pct, :any, required: true)

  defp hp_bar(assigns) do
    ~H"""
    <div class={"hp #{hp_level(@pct)}"} role="meter" aria-label={dgettext("ui", "Puntos de golpe")} aria-valuemin="0" aria-valuemax="100" aria-valuenow={round(@pct)}>
      <div class="hp-fill" style={"width:#{@pct}%"}></div>
    </div>
    """
  end

  defp hp_level(pct) when pct > 50, do: "hp-high"
  defp hp_level(pct) when pct > 25, do: "hp-mid"
  defp hp_level(_), do: "hp-low"

  defp card_sub(%{side: "pc"} = card),
    do: "#{Catalog.class_label(card.class)} · #{side_label(card.side)}"

  defp card_sub(card), do: side_label(card.side)

  defp side_label("pc"), do: dgettext("ui", "Aventurero")
  defp side_label("enemy"), do: dgettext("ui", "Enemigo")
  defp side_label("ally"), do: dgettext("ui", "Aliado")
  defp side_label(nil), do: ""
  defp side_label(other), do: String.capitalize(to_string(other))

  defp status_flags(card) do
    shape_flags(card)
    |> maybe_flag(card.raging == true, dgettext("ui", "Furia"))
    |> maybe_flag(card.inspired == true, dgettext("ui", "Inspirado"))
    |> maybe_flag(
      is_binary(card.concentrating) and card.concentrating != "",
      "◎ #{card.concentrating}"
    )
    |> maybe_flag(card.uncanny_dodge == true, dgettext("ui", "Esquiva"))
    |> maybe_flag(card.reckless == true, dgettext("ui", "Temerario"))
  end

  defp shape_flags(%{wild_shape: %{} = saved}),
    do: [dgettext("ui", "Forma de %{beast}", beast: WildShape.beast_name(saved[:beast]))]

  defp shape_flags(_), do: []

  defp maybe_flag(flags, true, label), do: flags ++ [label]
  defp maybe_flag(flags, false, _label), do: flags

  # ------------------------------------------------------------- full table

  attr(:entry, :map, required: true)

  defp chat_entry(assigns) do
    assigns =
      assign(assigns,
        declaration: assigns.entry.declaration,
        msg_class:
          "msg msg-#{assigns.entry.role}#{if assigns.entry.outcome, do: " roll-#{assigns.entry.outcome}", else: ""}"
      )

    ~H"""
    <div :if={@declaration} id={"event-#{@entry.seq}"} data-log-entry class={@msg_class}>
      <details class="player-declaration">
        <summary class="player-declared-chip">
          <i class="px px-quill" aria-hidden="true"></i><span class="pd-text">{dgettext("ui", "%{actor} declara", actor: @entry.actor)}</span>
        </summary>
        <p class="player-declaration-text">{@entry.text}</p>
      </details>
    </div>
    <p :if={not @declaration} id={"event-#{@entry.seq}"} data-log-entry class={@msg_class}>
      <span :if={@entry.who != ""}><span class="who">{@entry.who}</span>{" "}</span>{@entry.text}
    </p>
    """
  end

  # The full table, rendered once the viewer has claimed a seat.
  def table(assigns) do
    ~H"""
    <% cards = sheets(@world, @viewer) %>
    <% companions = Enum.filter(cards, &(&1.side == "pc" and &1.name != @viewer)) %>
    <% can_act = @viewer != "dm" and @my_turn and @status == :waiting and not @busy %>
    <% pc_names = if @world, do: for({name, %{side: "pc"}} <- @world.characters, do: name), else: [] %>
    <% character_names = if @world, do: Map.keys(@world.characters), else: [] %>
    <% shown_live = Chat.live_shown(@live_text, @live_actor, pc_names, character_names) %>

    <header class="game-topbar">
      <div class="turn-bar">
        <.turn_bar world={@world} current={@current} round={@round} status={@status} viewer={@viewer} is_creator={@is_creator == true} />
        <span id="turn-controls" class="controls" phx-hook="TurnControls">
          <span class="viewer-tag" title={dgettext("ui", "Estás jugando como")}>
            <i class={"px #{if @viewer == "dm", do: "px-eye", else: "px-shield"}"} aria-hidden="true"></i>{if @viewer == "dm", do: dgettext("ui", "Vista del DM"), else: @viewer}
          </span>
          <button :if={@is_creator and @status in [:running, :waiting]} class="ctl-btn" phx-click="pause">{dgettext("ui", "Pausa")}</button>
          <button
            :if={@viewer != "dm"}
            class={"ctl-btn #{if @auto_play, do: "ctl-active", else: ""}"}
            phx-click="toggle_auto"
            aria-pressed={to_string(@auto_play)}
            title={dgettext("ui", "La IA juega tu personaje")}
          >
            <i class="px px-orb" aria-hidden="true"></i>{if @auto_play, do: dgettext("ui", "Auto: sí"), else: dgettext("ui", "Auto")}
          </button>
          <Dice.engine_control engine={@dice_engine} rolling={@dice_rolling} />
          <.link :if={@is_creator and @viewer != "dm"} patch={"/games/#{@game_id}?as=dm"} class="ctl-btn" title={dgettext("ui", "Ver la partida como el DM")}>
            <i class="px px-eye" aria-hidden="true"></i>DM
          </.link>
          <.link :if={@is_creator and @viewer == "dm"} patch={"/games/#{@game_id}"} class="ctl-btn">
            <i class="px px-shield" aria-hidden="true"></i>{dgettext("ui", "Mi personaje")}
          </.link>
          <button class="ctl-btn" phx-click="share" title={dgettext("ui", "Copiar el enlace de la partida")}>
            <i class="px px-key" aria-hidden="true"></i>{dgettext("ui", "Invitar")}
          </button>
          <button :if={@is_creator} class="ctl-btn ai-btn" phx-click="open_settings" aria-label={dgettext("ui", "Ajustes de IA")} title={dgettext("ui", "Ajustes de IA: %{model}", model: Settings.ai_button_label())}>
            <i class="px px-gear ai-gear" aria-hidden="true"></i>
            <span class="ai-label">{Settings.ai_button_label()}</span>
          </button>
          <.link navigate="/" class="ctl-btn ctl-exit" title={dgettext("ui", "Volver a tus partidas")}>{dgettext("ui", "Salir")}</.link>
        </span>
      </div>
    </header>

    <div class={"game-body#{if @sheet_open, do: " sheet-open", else: ""}"}>
    <aside class="game-rail game-rail-left">
      <%= if @world != nil and @world.phase == :combat do %>
        <.combat_tracker world={@world} current={@current} round={@round} viewer={@viewer} />
      <% else %>
        <%= for {card, index} <- Enum.with_index(cards), rem(index, 2) == 0 do %>
          <.detail_sheet :if={card.name == @viewer} card={card} world={@world} />
          <div :if={card.name != @viewer} class="sheet">
            <.sheet world={@world} card={card} active={active_card?(@world, card, @current)} />
          </div>
        <% end %>
      <% end %>
    </aside>

    <section class="game-center">
      <div class="game-log" id="log" phx-hook="AutoScroll">
        <p :if={@history_limited} class="msg msg-system history-limit">
          {dgettext("ui", "Has alcanzado el límite del historial visible. La crónica completa sigue guardada.")}
        </p>
        <button
          :if={@has_more_events}
          class="load-more-btn"
          phx-click="load_more_log"
          title={dgettext("ui", "Cargar turnos anteriores")}
        >
          {dgettext("ui", "↑ cargar turnos anteriores")}
        </button>

        <div :for={{block, bi} <- Enum.with_index(@chat)} :key={block.header && block.header.turn_id || bi} class="turn-block">
          <div :if={block.header} class="turn-head">
            <span class="th-line">
              <span class={"th-actor #{Chat.th_actor_class(block.header.actor, @viewer, @auto_play)}"}>
                {Chat.header_label(block.header, @viewer, @auto_play)}
              </span>
              <span :if={block.header.phase == "combat"} class="th-phase">{dgettext("ui", "combate")}</span>
            </span>
          </div>

          <.chat_entry
            :for={entry <- block.events}
            :key={entry.seq}
            entry={entry}
          />
        </div>
        <p :if={@busy and shown_live == ""} class="msg msg-system thinking" role="status" aria-live="polite">
          {Chat.busy_label(Map.get(assigns, :busy_stage), @busy_actor)}
        </p>
        <p :if={shown_live != ""} class={"msg msg-#{if @live_actor == "dm", do: "dm", else: "pc"} live-streaming"}>
          <span :if={Chat.show_live_who?(shown_live, @live_actor)} class="who">{@live_actor} ·</span>{if Chat.show_live_who?(shown_live, @live_actor), do: " "}{shown_live}<span class="cursor">▍</span>
        </p>
      </div>
      <button type="button" id="jump-latest" class="ctl-btn jump-latest" hidden>
        {dgettext("ui", "Volver al último turno ↓")}
      </button>
      <div class="game-input-area">
        <p :if={@input_error} id="player-input-error" class="input-error" role="alert">{@input_error}</p>
        <div :if={@status == :paused} class="game-toast pause-banner" role="status">
          <i class="px px-scroll" aria-hidden="true"></i>
          <span class="pause-text">{pause_reason(@chat) || dgettext("ui", "La partida está en pausa.")}</span>
          <button :if={@is_creator} class="ctl-btn ctl-active btn-sm" phx-click="resume">{dgettext("ui", "Reanudar")}</button>
        </div>
        <p :if={@viewer == "dm"} class="dm-view-note">
          {dgettext("ui", "Estás viendo la crónica como DM.")}
          <.link patch={"/games/#{@game_id}"}>{dgettext("ui", "Volver a mi personaje")}</.link>
        </p>
        <div :if={can_act or @my_intent} class="input-notes">
          <div :if={can_act} class="game-toast my-turn-banner" role="status">
            <i class="px px-d20" aria-hidden="true"></i>
            <span>{your_turn_prompt(@viewer)}</span>
          </div>
          <div :if={@my_intent} class="game-toast intent-banner" role="status">
            <i class="px px-quill" aria-hidden="true"></i>
            <span class="intent-text">{dgettext("ui", "Has declarado: «%{intent}»", intent: @my_intent)} <span :if={not @my_turn} class="intent-when">{dgettext("ui", "— se resolverá en tu turno")}</span></span>
            <button class="ctl-btn btn-sm" phx-click="clear_intent">{dgettext("ui", "Borrar")}</button>
          </div>
        </div>
        <form
          :if={@viewer != "dm"}
          class={"game-input#{if can_act, do: " is-my-turn", else: ""}"}
          id="player-input"
          phx-hook="PlayerDraft"
          data-draft-key={"dragonex:draft:#{@game_id}:#{@viewer}"}
          phx-change="draft"
          phx-submit="declare"
        >
          <label for="player-input-text" class="game-input-caret" aria-label={dgettext("ui", "Tu acción")}><i class="px px-arrow" aria-hidden="true"></i></label>
          <input
            id="player-input-text"
            aria-label={dgettext("ui", "Tu acción")}
            aria-describedby={if @input_error, do: "player-input-error"}
            name="text"
            value={@pending}
            autocomplete="off"
            disabled={@status == :ended}
            placeholder={placeholder(@my_turn, @busy, @current && (actor_name(@current, @world) || :dm), @status)}
          />
          <button type="submit" class={"btn#{if can_act, do: " btn-primary", else: ""}"} disabled={@status == :ended or String.trim(@pending) == ""}>
            {if can_act, do: dgettext("ui", "Actuar"), else: dgettext("ui", "Declarar")}
          </button>
        </form>
      </div>
    </section>

    <button type="button" id="sheet-drawer" class="sheet-drawer-label" phx-click="toggle_sheet" aria-expanded={to_string(@sheet_open)} aria-controls="player-sheets" aria-label={if @viewer == "dm", do: dgettext("ui", "Fichas del grupo"), else: dgettext("ui", "Ficha de %{name}", name: @viewer)}>
      <i class="px px-shield" aria-hidden="true"></i>{dgettext("ui", "Ficha")}
    </button>
    <aside id="player-sheets" phx-hook="PlayerSheets" class={"game-rail game-rail-right#{if @sheet_open, do: " is-open", else: ""}"}>
      <div :if={@world != nil and @world.phase == :combat} class="mobile-combat-tracker">
        <.combat_tracker world={@world} current={@current} round={@round} viewer={@viewer} />
      </div>
      <%= if @world != nil and @world.phase == :combat and @viewer != "dm" and @world.characters[@viewer] != nil do %>
        <div class="combat-player-sheet">
          <.detail_sheet card={@world.characters[@viewer]} world={@world} />
        </div>
      <% else %>
        <div :if={@world != nil and @viewer != "dm" and @world.characters[@viewer] != nil} class="mobile-player-sheet">
          <.detail_sheet card={@world.characters[@viewer]} world={@world} />
        </div>
        <div :for={{card, index} <- Enum.with_index(cards)} :key={card.name} :if={rem(index, 2) == 1 or @world.phase == :combat} class="sheet">
          <.sheet world={@world} card={card} active={active_card?(@world, card, @current)} mine={card.name == @viewer} />
        </div>
      <% end %>
      <details :if={companions != []} id="mobile-companions" class="mobile-party-sheets" phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}>
        <summary>
          <i class="px px-orb" aria-hidden="true"></i>
          <span>{if @viewer in [nil, "dm"], do: dgettext("ui", "Grupo"), else: dgettext("ui", "Compañeros")} ({length(companions)})</span>
        </summary>
        <div class="mobile-party-list">
          <div :for={card <- companions} :key={card.name} class="sheet">
            <.sheet world={@world} card={card} active={active_card?(@world, card, @current)} />
          </div>
        </div>
      </details>
    </aside>
    </div>

    <Dice.stage
      show={@dice_show}
      mode={@dice_mode}
      rolling={@dice_rolling}
      hand={@dice_hand}
      groups={@dice_groups}
      engine={@dice_engine}
    />
    """
  end

  # ----------------------------------------------------------- waiting room

  # The waiting room: a lobby where players join, pick heroes, and the creator
  # starts when everyone is ready.
  attr(:game_id, :integer, required: true)
  attr(:game, :map, required: true)
  attr(:is_creator, :boolean, default: false)
  attr(:current_user, :any, default: nil)
  attr(:waiting_heroes, :list, default: [])
  attr(:join_error, :string, default: nil)

  def waiting_room(assigns) do
    ~H"""
    <div class="wr">

      <div class="wr-header">
        <div class="eyebrow">{dgettext("ui", "Sala de espera")}</div>
        <h1>{@game.title}</h1>
        <div class="scene">{(@game.world || %{})["scene"] || ""}</div>
      </div>

      <div class="wr-layout">
        <div class="slots-area">
          <h2 class="section-title">{dgettext("ui", "El grupo")}</h2>
          <div class="slots-circle">
            <% participants = preload_participants(@game) %>

            <%= for p <- participants do %>
              <% you = @current_user && p.user_id == @current_user.id %>
              <div class={"slot-card ready #{if you, do: "you", else: ""}"}>
                <div class="avatar">
                  <i class={"px #{if p.kind == :ai, do: "px-orb", else: "px-shield"}"} aria-hidden="true"></i>
                </div>
                <div class="sname">{p.name}</div>
                <div class="shero">{hero_role(p)}</div>
                <div class="sbadge sbadge-ready">{if you, do: dgettext("ui", "TÚ ✓"), else: dgettext("ui", "Listo")}</div>
              </div>
            <% end %>

            <%= for _ <- List.duplicate(nil, @game.open_slots) do %>
              <div class="slot-card empty">
                <div class="avatar"><i class="px px-key" aria-hidden="true"></i></div>
                <div class="sname">{dgettext("ui", "Hueco libre")}</div>
                <div class="sbadge sbadge-empty">{dgettext("ui", "Esperando jugador…")}</div>
              </div>
            <% end %>
          </div>

          <p :if={@join_error} id="lobby-join-error" class="wr-join-error" role="alert">{@join_error}</p>

          <%!-- Hero picker for non-participants --%>
          <%= if @current_user && not participant?(@current_user, participants) and @game.status == :configuring and @game.open_slots > 0 do %>
            <div class="hero-picker">
              <div class="hero-picker-label">{dgettext("ui", "Elige tu héroe para unirte")}</div>
              <div class="hero-grid">
                <%= for hero <- @waiting_heroes do %>
                  <button type="button" class="hero-btn" phx-click="join_with_hero" phx-value-hero_id={hero.id} aria-describedby={@join_error && "lobby-join-error"}>
                    <div class="hn">{hero.name}</div>
                    <div class="hd">{Catalog.race_label(hero.race)} · {Catalog.class_label(hero.class)}</div>
                  </button>
                <% end %>
              </div>
              <div :if={@waiting_heroes == []} class="no-hero">
                {dgettext("ui", "No tienes héroes.")} <a href="/heroes/new">{dgettext("ui", "Forja uno →")}</a>
              </div>
            </div>
          <% end %>
        </div>

        <div class="sidebar">
          <div class="panel">
            <h3><i class="px px-key" aria-hidden="true"></i>{dgettext("ui", "Invitar jugadores")}</h3>
            <div class="info-row">{dgettext("ui", "Comparte el enlace de la partida con tu grupo.")}</div>
            <button class="copy-btn" phx-click="share">{dgettext("ui", "Copiar enlace")}</button>
            <div class="info-row">
              {dngettext("ui", "%{count} hueco libre", "%{count} huecos libres", @game.open_slots)}
            </div>
          </div>

          <div class="panel">
            <%= if @is_creator do %>
              <button class="start-btn" phx-click="start_game"><i class="px px-swords" aria-hidden="true"></i>{dgettext("ui", "¡Empezar partida!")}</button>
              <div class="info-row center">{dgettext("ui", "Puedes empezar aunque queden huecos libres.")}</div>
            <% else %>
              <% joined = participant?(@current_user, participants) %>
              <h3>{if not joined and @game.status == :configuring and @game.open_slots > 0, do: dgettext("ui", "Únete"), else: dgettext("ui", "Estado")}</h3>
              <div class="info-row">
                <%= cond do %>
                  <% joined -> %>{dgettext("ui", "Estás dentro. Esperando a que el creador empiece…")}
                  <% @game.status != :configuring -> %>{dgettext("ui", "La partida ya ha empezado.")}
                  <% @game.open_slots <= 0 -> %>{dgettext("ui", "La sala está completa.")}
                  <% true -> %>{dgettext("ui", "Elige un héroe para unirte.")}
                <% end %>
              </div>
            <% end %>
          </div>

          <div class="panel">
            <h3><i class="px px-scroll" aria-hidden="true"></i>{dgettext("ui", "La aventura")}</h3>
            <div class="info-row"><span class="info-label">{dgettext("ui", "Tono")}</span>{(@game.story_bible || %{})["tone"] || "—"}</div>
            <div class="info-row"><span class="info-label">{dgettext("ui", "Gancho")}</span>{String.slice((@game.story_bible || %{})["hook"] || "", 0, 140)}…</div>
          </div>

          <.link navigate="/" class="nav-link">{dgettext("ui", "← partidas")}</.link>
        </div>
      </div>
    </div>
    """
  end

  defp hero_role(%{kind: :ai}), do: dgettext("ui", "IA")
  defp hero_role(%{kind: :human}), do: dgettext("ui", "Jugador")

  defp preload_participants(game), do: game.participants || []

  defp participant?(nil, _), do: false

  defp participant?(%{id: uid}, participants) do
    Enum.any?(participants, fn p -> p.user_id == uid end)
  end

  # ---------------------------------------------------------------- helpers

  defp sheets(nil, _viewer), do: []

  defp sheets(%World{} = world, viewer) do
    {pcs, scene} =
      world
      |> World.present_characters()
      |> Map.values()
      |> Enum.split_with(&(&1.side == "pc"))

    pcs = Enum.sort_by(pcs, &{&1.name != viewer, &1.name})

    scene =
      scene
      |> Enum.filter(&(&1.hp > 0))
      |> Enum.sort_by(& &1.name)
      |> Enum.take(@max_scene_sheets)

    pcs ++ scene
  end

  defp active_card?(%World{} = w, %Character{} = c, current),
    do: World.acting?(w, c.name, current) and c.hp > 0

  defp active_card?(_, _, _), do: false

  # A failed turn pauses the table right after its public note (the raw
  # failure only reaches the DM view); that note is the reason.
  defp pause_reason(chat) do
    case chat |> List.last() |> then(&((&1 && &1.events) || [])) |> List.last() do
      %{kind: "turn_retained", text: text} when text != "" -> text
      _ -> nil
    end
  end

  defp placeholder(_, _, _, :paused), do: dgettext("ui", "Declara tu intención (en pausa)…")
  defp placeholder(_, _, _, :ended), do: dgettext("ui", "La partida ha terminado")
  defp placeholder(true, false, _, _), do: dgettext("ui", "¿Qué haces?")

  defp placeholder(_, _, current, _) when is_binary(current),
    do: dgettext("ui", "Declara tu intención (turno de %{actor})…", actor: current)

  defp placeholder(_, _, :dm, _), do: dgettext("ui", "Declara tu intención (turno del DM)…")

  defp placeholder(_, _, _, _), do: dgettext("ui", "Declara tu intención…")

  # "Es tu turno — ¿qué hace <strong>name</strong>?": the sentence stays whole
  # for translators; the escaped name is wrapped in <strong> before interpolating.
  defp your_turn_prompt(viewer) do
    name =
      viewer
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()

    Phoenix.HTML.raw(
      dgettext("ui", "Es tu turno — ¿qué hace %{name}?", name: "<strong>#{name}</strong>")
    )
  end
end
