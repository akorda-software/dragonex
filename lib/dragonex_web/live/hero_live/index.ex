defmodule DragonexWeb.HeroLive.Index do
  @moduledoc """
  The hero gallery — lists the current user's saved characters with quick
  stats and links to view or delete them. Entry point for the creator.
  """

  use Phoenix.LiveView, layout: {DragonexWeb.Layouts, :app}
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{Accounts, Heroes.Catalog}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    heroes = Accounts.list_heroes(user)

    {:ok,
     assign(socket,
       heroes: heroes,
       used_hero_ids: MapSet.new(Accounts.used_hero_ids(user)),
       error: nil
     )}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    # Verify ownership server-side: get_user_hero is user-scoped and returns
    # nil for a hero that isn't ours, so a forged phx-value-id can't delete
    # another user's hero.
    error =
      case Accounts.delete_hero(user, id) do
        {:ok, _} ->
          nil

        {:error, :in_game} ->
          dgettext("ui", "No puedes borrar un héroe que ya está en una partida.")

        {:error, _} ->
          dgettext("ui", "No se pudo borrar el héroe.")
      end

    heroes = Accounts.list_heroes(user)

    {:noreply,
     assign(socket,
       heroes: heroes,
       used_hero_ids: MapSet.new(Accounts.used_hero_ids(user)),
       error: error
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page gallery">
      <.link navigate="/" class="nav-link">{dgettext("ui", "← partidas")}</.link>

      <header class="page-head">
        <div>
          <h1 class="page-title">{dgettext("ui", "Mis héroes")}</h1>
          <p class="sub">{dgettext("ui", "Tus personajes de D&D 5e, listos para la próxima mesa.")}</p>
        </div>
        <div class="page-actions">
          <.link navigate="/mi-contenido" class="btn btn-ghost"><i class="px px-book" aria-hidden="true"></i>{dgettext("ui", "Mi contenido")}</.link>
          <.link navigate="/heroes/new" class="btn btn-primary"><i class="px px-quill" aria-hidden="true"></i>{dgettext("ui", "Forjar nuevo héroe")}</.link>
        </div>
      </header>

      <div :if={@error} class="error">{@error}</div>

      <div class="cards">
        <div :for={h <- @heroes} :key={h.id} class="hero-card">
          <.link navigate={"/heroes/#{h.id}"}>
            <span class="hero-portrait" aria-hidden="true">{initial(h.name)}</span>
            <span>
              <h3>{h.name}</h3>
              <span class="role">{Catalog.race_label(h.race)} · {Catalog.class_label(h.class)}</span>
            </span>
          </.link>
          <div class="hero-card-footer">
            <span class="badge">{dgettext("ui", "Nivel %{level}", level: h.level)}</span>
            <div class="hero-card-actions">
              <.link :if={!hero_used?(@used_hero_ids, h)} navigate={"/heroes/#{h.id}/edit"} class="btn btn-ghost btn-sm">{dgettext("ui", "Editar")}</.link>
              <button :if={!hero_used?(@used_hero_ids, h)} class="btn btn-danger btn-sm" phx-click="delete" phx-value-id={h.id} data-confirm={dgettext("ui", "¿Borrar a %{name}? No se puede deshacer.", name: h.name)}>{dgettext("ui", "Borrar")}</button>
              <span :if={hero_used?(@used_hero_ids, h)} class="locked-note" title={dgettext("ui", "Un héroe en partida no se puede editar ni borrar")}>
                <i class="px px-swords" aria-hidden="true"></i> {dgettext("ui", "En partida")}
              </span>
            </div>
          </div>
        </div>
      </div>

      <div :if={@heroes == []} class="empty">
        <p>{dgettext("ui", "No tienes héroes todavía.")}</p>
        <.link navigate="/heroes/new" class="btn btn-primary"><i class="px px-quill" aria-hidden="true"></i>{dgettext("ui", "Forjar el primero")}</.link>
      </div>
    </div>
    """
  end

  defp initial(name) when is_binary(name) and name != "", do: String.first(name)
  defp initial(_), do: "?"

  defp hero_used?(used_hero_ids, hero), do: MapSet.member?(used_hero_ids, hero.id)
end
