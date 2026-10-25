defmodule DragonexWeb.GameLive.Index do
  @moduledoc """
  The partida list — the lobby. Shows the current user's persisted games (or a
  login prompt if not authenticated).
  """

  use Phoenix.LiveView, layout: {DragonexWeb.Layouts, :app}
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.Games
  alias DragonexWeb.HomeDemo

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    games = if user, do: Games.list_games(user.id), else: []
    open_games = if user, do: Games.open_games(user), else: []

    socket =
      assign(socket,
        games: games,
        open_games: open_games,
        demo_step: HomeDemo.opening(),
        demo_gen: 0,
        demo_paused: false
      )

    # Visitors see the living chronicle; it only plays on a live socket.
    if is_nil(user) and connected?(socket), do: schedule_demo(socket)

    {:ok, socket}
  end

  # Every timer carries the generation it was armed in; pausing, resuming or
  # replaying bumps it, so a stale timer can never advance the chronicle twice.
  @impl true
  def handle_info({:demo, gen, _step}, %{assigns: %{demo_gen: current}} = socket)
      when gen != current,
      do: {:noreply, socket}

  def handle_info({:demo, _gen, :restart}, socket) do
    socket = assign(socket, demo_step: HomeDemo.opening(), demo_gen: socket.assigns.demo_gen + 1)
    schedule_demo(socket)
    {:noreply, socket}
  end

  def handle_info({:demo, _gen, step}, socket) when is_integer(step) do
    if step >= HomeDemo.length() do
      # Hold the finished excerpt, then replay it from the opening.
      Process.send_after(self(), {:demo, socket.assigns.demo_gen, :restart}, HomeDemo.hold_ms())
      {:noreply, socket}
    else
      socket = assign(socket, :demo_step, step + 1)

      socket =
        case HomeDemo.dice(step) do
          nil -> socket
          payload -> push_event(socket, "dic_ex:roll:home-dice", payload)
        end

      schedule_demo(socket)
      {:noreply, socket}
    end
  end

  defp schedule_demo(%{assigns: %{demo_step: step, demo_gen: gen}}) do
    pause = if step < HomeDemo.length(), do: HomeDemo.delay(step), else: 0
    Process.send_after(self(), {:demo, gen, step}, pause)
  end

  # The home dice stage reports when its tumble lands; the chronicle is
  # already scripted, so there is nothing to commit.
  @impl true
  def handle_event("dic_ex:" <> _event, _params, socket), do: {:noreply, socket}

  def handle_event("toggle_demo", _params, socket) do
    socket =
      assign(socket,
        demo_paused: not socket.assigns.demo_paused,
        demo_gen: socket.assigns.demo_gen + 1
      )

    unless socket.assigns.demo_paused, do: schedule_demo(socket)
    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    if user do
      case Games.delete_game(user, id) do
        {:ok, game} -> _ = Dragonex.Game.Supervisor.stop_game(game.id)
        _ -> :ok
      end
    end

    games = if user, do: Games.list_games(user.id), else: []
    {:noreply, assign(socket, :games, games)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @current_user do %>
      <div class="page lobby">
        <header class="page-head">
          <div>
            <h1 class="page-title">{dgettext("ui", "Tus partidas")}</h1>
            <p class="sub">{dgettext("ui", "El DM por IA narra; el motor tira los dados y aplica las reglas de D&D 5e.")}</p>
          </div>
          <div class="page-actions">
            <.link navigate="/heroes" class="btn btn-ghost"><i class="px px-swords" aria-hidden="true"></i>{dgettext("ui", "Mis héroes")}</.link>
            <.link navigate="/games/new" class="btn btn-primary"><i class="px px-d20" aria-hidden="true"></i>{dgettext("ui", "Nueva partida")}</.link>
          </div>
        </header>

        <section :if={@open_games != []}>
          <h2 class="section-title"><i class="px px-key" aria-hidden="true"></i>{dgettext("ui", "Mesas con sitio libre")}</h2>
          <div class="quest-list">
            <article :for={g <- @open_games} :key={g.id} class="quest is-open">
              <div class="quest-sigil"><i class="px px-key" aria-hidden="true"></i></div>
              <div>
                <.link navigate={"/games/#{g.id}"} class="quest-title">{g.title}</.link>
                <div class="quest-meta">
                  <span class="badge badge-running">{dngettext("ui", "%{count} hueco libre", "%{count} huecos libres", g.open_slots)}</span>
                </div>
              </div>
              <div class="quest-actions">
                <.link navigate={"/games/#{g.id}"} class="btn btn-primary">{dgettext("ui", "Unirse")}</.link>
              </div>
            </article>
          </div>
        </section>

        <h2 class="section-title"><i class="px px-scroll" aria-hidden="true"></i>{dgettext("ui", "Tus crónicas")}</h2>

        <div class="quest-list">
          <article :for={g <- @games} :key={g.id} class="quest">
            <div class="quest-sigil"><i class={"px #{status_sigil(g.status)}"} aria-hidden="true"></i></div>
            <div>
              <.link navigate={"/games/#{g.id}"} class="quest-title">{g.title}</.link>
              <div class="quest-meta">
                <span class={"badge badge-#{g.status}"}>{status_label(g.status)}</span>
                <span :if={g.current_participant}>{dgettext("ui", "Turno de %{name}", name: g.current_participant)}</span>
              </div>
            </div>
            <div class="quest-actions">
              <button class="btn btn-danger btn-sm" phx-click="delete" phx-value-id={g.id} data-confirm={dgettext("ui", "¿Borrar «%{title}»? No se puede deshacer.", title: g.title)}>{dgettext("ui", "Borrar")}</button>
              <.link navigate={"/games/#{g.id}"} class="btn">{dgettext("ui", "Abrir")}</.link>
            </div>
          </article>
        </div>

        <div :if={@games == []} class="empty">
          <p>{dgettext("ui", "Todavía no has empezado ninguna aventura.")}</p>
          <.link navigate="/games/new" class="btn btn-primary"><i class="px px-d20" aria-hidden="true"></i>{dgettext("ui", "Crear la primera partida")}</.link>
        </div>
      </div>
    <% else %>
      <div class="home">
        <!--
          THESIS: the home is a game already in play; the real chronicle sells the
          product instead of a hero illustration with three feature bullets.
          OWN-WORLD: the 16-bit dungeon (bricks, torchlight, stepped RPG frames,
          parchment with rubric red, Alegreya prose, Departure Mono rolls) plus
          the pixel wordmark.
          STORY: the DM narrates, the engine's dice land in the tray, the party
          acts; the visitor sits in Thane's seat and declares by creating an account.
          FIRST VIEWPORT: wordmark and three facts on top; between two torches,
          parchment chronicle left, dice tray and roll readout right, declare bar
          with «Crear cuenta» at its foot.
          FORM: «La crónica viva», pick card over dealt 5/2/4, seed 62973b2b.
          FINISH: unreviewed and undocumented is unfinished; this build ends with
          the finish review, the verdict, DESIGN.md, and every shipping raster
          carrying its provenance.
        -->
        <header class="home-head">
          <h1 class="home-mark">
            <img src="/assets/wordmark.svg" alt="Dragonex" width="610" height="150" />
          </h1>
          <ul class="home-facts">
            <li><i class="px px-scroll" aria-hidden="true"></i>{dgettext("ui", "La IA narra la historia")}</li>
            <li><i class="px px-d20" aria-hidden="true"></i>{dgettext("ui", "El motor aplica las reglas de 5e")}</li>
            <li><i class="px px-swords" aria-hidden="true"></i>{dgettext("ui", "Juega solo o con amigos")}</li>
          </ul>
        </header>

        <section class="home-table" aria-label={dgettext("ui", "Fragmento real de una partida")}>
          <i class="px px-torch home-torch" aria-hidden="true"></i>
          <div class="home-chronicle">
            <div class="home-body">
              <div class="home-log" id="home-log" phx-hook="AutoScroll" aria-live="off">
                <div :for={block <- HomeDemo.blocks(@demo_step)} :key={block.header.id} class="turn-block">
                  <div class="turn-head">
                    <span class="th-line">
                      <span class={"th-actor #{block.header.class}"}>{block.header.label}</span>
                      <span :if={block.header.combat} class="th-phase">{dgettext("ui", "combate")}</span>
                    </span>
                  </div>
                  <%= for line <- block.lines do %>
                    <p :if={line.kind == :dm} id={"home-line-#{line.id}"} class="msg msg-dm home-ink">{line.text}</p>
                    <p :if={line.kind == :pc} id={"home-line-#{line.id}"} class="msg msg-pc home-ink">
                      <span class="who">{line.who} ·</span> {line.text}
                    </p>
                    <p :if={line.kind == :roll} id={"home-line-#{line.id}"} class={"msg msg-roll home-ink home-roll#{if line.outcome, do: " roll-#{line.outcome}"}"}>
                      <span class="who">{line.who}</span> {line.text}
                    </p>
                    <p :if={line.kind == :system} id={"home-line-#{line.id}"} class="msg msg-system home-ink">{line.text}</p>
                  <% end %>
                </div>
              </div>

              <div class="home-tray" aria-hidden="true">
                <div id="home-dice" class="dicex-roller dicex-engine-2d home-dice" phx-hook="DiceRoller2D" data-palette={HomeDemo.dice_palette()}>
                  <div id="home-dice-canvas" class="dicex-stage" data-dicex-stage phx-update="ignore"></div>
                </div>
                <% roll = HomeDemo.last_roll(@demo_step) %>
                <div :if={roll} id={"home-readout-#{roll.id}"} class={"home-readout #{roll.tone}"}>
                  <span class="hr-who">{roll.who} · {roll.what}</span>
                  <span class="hr-total">{roll.total}</span>
                  <span :if={roll.outcome != ""} class="hr-outcome">{roll.outcome}</span>
                </div>
                <div :if={is_nil(roll)} class="home-readout home-readout-idle">
                  <span class="hr-who">{dgettext("ui", "Bandeja de dados")}</span>
                  <span class="hr-total">d20</span>
                </div>
              </div>
            </div>
            <div class="home-declare">
              <.link navigate="/register" class="home-declare-field">
                <i class="px px-quill" aria-hidden="true"></i>{dgettext("ui", "Declara tu intención…")}
              </.link>
              <.link navigate="/register" class="btn btn-primary">{dgettext("ui", "Crear cuenta")}</.link>
            </div>
          </div>
          <i class="px px-torch home-torch" aria-hidden="true"></i>
        </section>

        <p class="home-foot">
          <span>{dgettext("ui", "Fragmento real de una partida")}</span>
          <button type="button" phx-click="toggle_demo" aria-pressed={to_string(@demo_paused)}>
            {if @demo_paused,
              do: dgettext("ui", "Reanudar demostración"),
              else: dgettext("ui", "Pausar demostración")}
          </button>
          <span>{dgettext("ui", "¿Ya tienes cuenta?")} <.link navigate="/login">{dgettext("ui", "Entrar")}</.link></span>
        </p>
      </div>
    <% end %>
    """
  end

  defp status_sigil(:running), do: "px-d20"
  defp status_sigil(:waiting), do: "px-quill"
  defp status_sigil(:paused), do: "px-potion"
  defp status_sigil(:ended), do: "px-skull"
  defp status_sigil(_), do: "px-scroll"

  defp status_label(:running), do: dgettext("ui", "en curso")
  defp status_label(:waiting), do: dgettext("ui", "espera humano")
  defp status_label(:paused), do: dgettext("ui", "en pausa")
  defp status_label(:ended), do: dgettext("ui", "terminada")
  defp status_label(:configuring), do: dgettext("ui", "configurando")
  defp status_label(other), do: to_string(other)
end
