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
        .gallery{width:min(1180px,calc(100% - 3rem));margin:0 auto;padding:clamp(1rem,2vw,2rem) 0 2.5rem;font-family:Georgia,'Times New Roman',serif;}
        .gallery-header{display:flex;align-items:flex-end;justify-content:space-between;gap:1rem;margin:1rem 0 1.25rem;}
        .gallery h1{font-size:clamp(1.5rem,2vw,2rem);color:#fc8;}
        .gallery .sub{color:#889;font-size:.92rem;margin-top:.25rem;}
        .cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:1rem;}
        .hero-card{display:flex;flex-direction:column;gap:.9rem;min-height:120px;background:rgba(26,26,26,.92);border:1px solid #333;border-radius:12px;padding:1rem;text-decoration:none;color:#ccc;transition:all .12s;}
        .hero-card:hover{border-color:#a72;background:#201b16;transform:translateY(-1px);}
        .hero-card a{text-decoration:none;color:inherit;}
        .hero-card h3{color:#fc8;font-size:1.12rem;margin-bottom:.3rem;}
        .hero-card .role{font-size:.82rem;color:#889;line-height:1.4;}
        .hero-card-footer{display:flex;align-items:center;justify-content:space-between;gap:.8rem;margin-top:auto;}
        .hero-badge{font-size:.72rem;color:#aaa;background:#222;border:1px solid #333;border-radius:999px;padding:.2rem .55rem;}
        .btn{display:inline-flex;align-items:center;justify-content:center;padding:.55rem 1rem;border-radius:8px;border:1px solid #a72;background:#3a2a1a;color:#fc8;font-size:.9rem;cursor:pointer;text-decoration:none;font-family:inherit;}
        .btn:hover{background:#4a3520;}
        .btn-danger{background:#2a1a1a;border-color:#744;color:#f99;font-size:.75rem;padding:.3rem .6rem;}
        .btn-danger:hover{background:#3a2222;}
        .empty{text-align:center;color:#666;font-style:italic;padding:4rem;background:rgba(20,20,20,.65);border:1px dashed #333;border-radius:12px;}
        .nav-link{color:#7ab;text-decoration:none;font-size:.85rem;}
        @media(max-width:640px){.gallery{width:min(100% - 1rem,1180px);}.gallery-header{align-items:flex-start;flex-direction:column;}.cards{grid-template-columns:1fr;}}
      </style>

      <div>
        <.link navigate="/" class="nav-link">← partidas</.link>
      </div>

      <div class="gallery-header">
        <div>
          <h1>Mis héroes</h1>
          <div class="sub">Tus personajes de D&D 5e, listos para jugar.</div>
        </div>
        <.link navigate="/heroes/new" class="btn">+ Forjar nuevo héroe</.link>
      </div>

      <div class="cards">
        <div :for={h <- @heroes} :key={h.id} class="hero-card">
          <.link navigate={"/heroes/#{h.id}"}>
            <h3>{h.name}</h3>
            <div class="role">{String.capitalize(h.race)} · {String.capitalize(h.class)} · Nivel {h.level}</div>
          </.link>
          <div class="hero-card-footer">
            <span class="hero-badge">D&D 5e</span>
            <button class="btn btn-danger" phx-click="delete" phx-value-id={h.id} data-confirm="¿Borrar este héroe?">borrar</button>
          </div>
        </div>
      </div>

      <div :if={@heroes == []} class="empty">
        No tienes héroes todavía. ¡Crea el primero!
      </div>
    </div>
    """
  end
end
