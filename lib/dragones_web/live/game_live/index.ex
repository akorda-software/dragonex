defmodule DragonesWeb.GameLive.Index do
  @moduledoc """
  The partida list — the lobby. Shows every persisted game (title, status,
  whose turn) with links to open one or start a new one via the creator wizard.
  """

  use Phoenix.LiveView, layout: {DragonesWeb.Layouts, :app}

  alias Dragones.Games

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, games: Games.list_games())}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    _ = Games.delete_game(id)
    # Stop a running Game process for it too (its state is already persisted).
    _ = Dragones.Game.Supervisor.stop_game(id)
    {:noreply, assign(socket, games: Games.list_games())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="lobby">
      <style>
        .lobby{max-width:760px; margin:0 auto; padding:1.5rem;}
        .lobby h1{font-size:1.4rem;}
        .lobby .sub{color:#888; margin-bottom:1rem;}
        .lobby table{width:100%; border-collapse:collapse;}
        .lobby th,.lobby td{text-align:left; padding:.5rem .6rem; border-bottom:1px solid #2a2a2a; font-size:.95rem;}
        .lobby th{color:#7ab; font-weight:600; font-size:.8rem; text-transform:uppercase;}
        .lobby tr:hover td{background:#222;}
        .badge{display:inline-block; padding:.1rem .5rem; border-radius:10px; font-size:.75rem; background:#2a2a2a; border:1px solid #3a3a3a;}
        .badge-running{color:#9e9;} .badge-waiting{color:#fb0;} .badge-paused{color:#f96;} .badge-ended{color:#f66;}
        .actions{display:flex; gap:.6rem; align-items:center;}
        .btn{padding:.4rem .8rem; border-radius:6px; border:1px solid #444; background:#2c2c2c; color:#eee; font-size:.85rem; text-decoration:none; cursor:pointer;}
        .btn:hover{background:#3a3a3a;}
        .btn-primary{background:#3a2a1a; border-color:#a72; color:#fc8;}
        .btn-danger{background:#2a1a1a; border-color:#744; color:#f99;}
        .new-row td{text-align:center; color:#888; font-style:italic; padding:1.4rem;}
      </style>

      <h1>Dragones — partidas</h1>
      <div class="sub">El DM por IA dirige D&D 5e. Abre una partida o crea una nueva.</div>

      <div class="actions" style="margin-bottom:1rem;">
        <.link navigate={"/games/new"} class="btn btn-primary">+ Nueva partida</.link>
      </div>

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
                <button class="btn btn-danger" phx-click="delete" phx-value-id={g.id} data-confirm="¿Borrar la partida?">Borrar</button>
              </div>
            </td>
          </tr>
          <tr :if={@games == []}><td colspan="4" class="new-row">No hay partidas todavía. Crea la primera.</td></tr>
        </tbody>
      </table>
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
