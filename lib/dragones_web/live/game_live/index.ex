defmodule DragonesWeb.GameLive.Index do
  @moduledoc """
  The partida list — the lobby. Shows the current user's persisted games (or a
  login prompt if not authenticated).
  """

  use Phoenix.LiveView, layout: {DragonesWeb.Layouts, :app}

  alias Dragones.Games

  @impl true
  def mount(_params, session, socket) do
    user_id = session["user_id"]
    user = user_id && Dragones.Accounts.get_user(user_id)

    games =
      if user do
        Games.list_games(user.id)
      else
        []
      end

    open_games = if user, do: Games.open_games(user), else: []

    {:ok, assign(socket, current_user: user, games: games, open_games: open_games)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    # Only the creator may delete their partida. The id comes from a forged
    # phx-value, so verify server-side rather than trusting the rendered button.
    creator? =
      user != nil and
        case Games.get_game(id) do
          %{user_id: uid} -> uid == user.id
          nil -> false
        end

    if creator? do
      _ = Games.delete_game(id)
      _ = Dragones.Game.Supervisor.stop_game(id)
    end

    games = if user, do: Games.list_games(user.id), else: []
    {:noreply, assign(socket, :games, games)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="lobby">
      <style>
        .lobby{max-width:760px;margin:0 auto;padding:1.5rem;font-family:Georgia,'Times New Roman',serif;}
        .lobby h1{font-size:1.5rem;color:#fc8;}
        .lobby .sub{color:#889;margin-bottom:1rem;font-size:.9rem;}
        .lobby table{width:100%;border-collapse:collapse;}
        .lobby th,.lobby td{text-align:left;padding:.5rem .6rem;border-bottom:1px solid #2a2a2a;font-size:.95rem;}
        .lobby th{color:#7ab;font-weight:600;font-size:.8rem;text-transform:uppercase;}
        .lobby tr:hover td{background:#222;}
        .badge{display:inline-block;padding:.1rem .5rem;border-radius:10px;font-size:.75rem;background:#2a2a2a;border:1px solid #3a3a3a;}
        .badge-running{color:#9e9;}.badge-waiting{color:#fb0;}.badge-paused{color:#f96;}.badge-ended{color:#f66;}
        .actions{display:flex;gap:.6rem;align-items:center;flex-wrap:wrap;margin-bottom:1rem;}
        .btn{padding:.4rem .8rem;border-radius:6px;border:1px solid #444;background:#2c2c2c;color:#eee;font-size:.85rem;text-decoration:none;cursor:pointer;font-family:inherit;}
        .btn:hover{background:#3a3a3a;}
        .btn-primary{background:#3a2a1a;border-color:#a72;color:#fc8;}
        .btn-danger{background:#2a1a1a;border-color:#744;color:#f99;}
        .new-row td{text-align:center;color:#888;font-style:italic;padding:1.4rem;}
        .welcome{text-align:center;padding:2rem 0;}
        .welcome h1{font-size:2rem;color:#fc8;}
        .welcome p{color:#889;font-size:1rem;margin:.5rem 0 1.5rem;}
        .welcome .btn{font-size:1rem;padding:.6rem 1.5rem;}
      </style>

      <%= if @current_user do %>
        <h1>Dragones — partidas</h1>
        <div class="sub">El DM por IA dirige D&D 5e. Abre una partida o crea una nueva.</div>

        <div class="actions">
          <.link navigate="/games/new" class="btn btn-primary">+ Nueva partida</.link>
          <.link navigate="/heroes" class="btn">⚔ Mis héroes</.link>
        </div>

        <div :if={@open_games != []}>
          <h2 style="color:#9f9;font-size:.95rem;margin:1.5rem 0 .5rem;">🔓 Partidas abiertas</h2>
          <table>
            <tbody>
              <tr :for={g <- @open_games} :key={g.id}>
                <td>{g.title}</td>
                <td><span class="badge badge-running">{g.open_slots} slot(s)</span></td>
                <td>
                  <.link navigate={"/games/#{g.id}"} class="btn btn-primary">Unirse</.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <h2 style="color:#7ab;font-size:.95rem;margin:1.5rem 0 .5rem;">Tus partidas</h2>

        <table>
          <thead>
            <tr><th>Título</th><th>Estado</th><th>Turno de</th><th></th></tr>
          </thead>
          <tbody>
            <tr :for={g <- @games} :key={g.id}>
              <td>{g.title}</td>
              <td><span class={"badge badge-#{g.status}"}>{status_label(g.status)}</span></td>
              <td>{g.current_participant || "—"}</td>
              <td>
                <div class="actions">
                  <.link navigate={"/games/#{g.id}"} class="btn">Abrir</.link>
                  <button class="btn btn-danger" phx-click="delete" phx-value-id={g.id} data-confirm="¿Borrar?">Borrar</button>
                </div>
              </td>
            </tr>
            <tr :if={@games == []}><td colspan="4" class="new-row">No hay partidas todavía. ¡Crea la primera!</td></tr>
          </tbody>
        </table>
      <% else %>
        <div class="welcome">
          <h1>⚔ Dragones</h1>
          <p>El DM por IA dirige D&D 5e. Crea personajes, forma partidas y juega.</p>
          <div class="actions" style="justify-content:center;">
            <.link navigate="/login" class="btn btn-primary">Entrar</.link>
            <.link navigate="/register" class="btn">Crear cuenta</.link>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp status_label(:running), do: "en curso"
  defp status_label(:waiting), do: "espera humano"
  defp status_label(:paused), do: "en pausa"
  defp status_label(:ended), do: "terminada"
  defp status_label(:configuring), do: "configurando"
  defp status_label(other), do: to_string(other)
end
