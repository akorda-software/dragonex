defmodule DragonesWeb.HeroLive.Index do
  @moduledoc """
  The hero gallery — lists the current user's saved characters with quick
  stats and links to view or delete them. Entry point for the creator.
  """

  use Phoenix.LiveView, layout: {DragonesWeb.Layouts, :app}

  alias Dragones.Accounts

  @impl true
  def mount(_params, session, socket) do
    case Accounts.get_user(session["user_id"]) do
      nil ->
        {:ok, Phoenix.LiveView.redirect(socket, to: "/login")}

      user ->
        heroes = Accounts.list_heroes(user)
        {:ok, assign(socket, current_user: user, heroes: heroes)}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    _ = Accounts.delete_hero(id)
    heroes = Accounts.list_heroes(socket.assigns.current_user)
    {:noreply, assign(socket, :heroes, heroes)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="gallery">
      <style>
        .gallery{max-width:760px;margin:0 auto;padding:1.5rem;font-family:Georgia,'Times New Roman',serif;}
        .gallery h1{font-size:1.4rem;color:#fc8;}
        .gallery .sub{color:#889;font-size:.85rem;margin-bottom:1rem;}
        .gallery .actions{margin-bottom:1rem;}
        .cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:.8rem;}
        .card{background:#1a1a1a;border:1px solid #333;border-radius:8px;padding:.8rem;text-decoration:none;color:#ccc;transition:all .12s;}
        .card:hover{border-color:#555;}
        .card h3{color:#fc8;font-size:1rem;margin-bottom:.2rem;}
        .card .role{font-size:.78rem;color:#889;margin-bottom:.4rem;}
        .card .stats{display:flex;gap:.5rem;font-size:.78rem;color:#aaa;flex-wrap:wrap;}
        .card .stats span{background:#222;padding:.15rem .4rem;border-radius:3px;}
        .card .abilities{font-size:.72rem;color:#777;margin-top:.3rem;}
        .btn{padding:.4rem .9rem;border-radius:6px;border:1px solid #a72;background:#3a2a1a;color:#fc8;font-size:.88rem;cursor:pointer;text-decoration:none;font-family:inherit;}
        .btn:hover{background:#4a3520;}
        .btn-danger{background:#2a1a1a;border-color:#744;color:#f99;font-size:.75rem;padding:.3rem .6rem;}
        .btn-danger:hover{background:#3a2222;}
        .empty{text-align:center;color:#666;font-style:italic;padding:3rem;}
        .nav-link{color:#7ab;text-decoration:none;font-size:.85rem;}
      </style>

      <div class="actions">
        <.link navigate="/" class="nav-link">← partidas</.link>
      </div>

      <h1>Mis héroes</h1>
      <div class="sub">Tus personajes de D&D 5e, listos para jugar.</div>

      <div style="margin-bottom:1rem;">
        <.link navigate="/heroes/new" class="btn">+ Forjar nuevo héroe</.link>
      </div>

      <div class="cards">
        <div :for={h <- @heroes} :key={h.id} class="card">
          <.link navigate={"/heroes/#{h.id}"}>
            <h3>{h.name}</h3>
            <div class="role">{String.capitalize(h.race)} · {String.capitalize(h.class)} · Nivel {h.level}</div>
          </.link>
          <button class="btn btn-danger" phx-click="delete" phx-value-id={h.id} data-confirm="¿Borrar este héroe?">borrar</button>
        </div>
      </div>

      <div :if={@heroes == []} class="empty">
        No tienes héroes todavía. ¡Crea el primero!
      </div>
    </div>
    """
  end
end
