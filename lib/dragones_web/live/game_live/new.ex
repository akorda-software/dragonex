defmodule DragonesWeb.GameLive.New do
  @moduledoc """
  The creator wizard: title/scene/dm_style plus a roster of predefined characters
  (each PC flagged `:human`/`:ai`; monsters are always DM-controlled). On submit
  it builds the partida via `Games.create_from_wizard/1` and navigates to the
  table for that `game_id`.
  """

  use Phoenix.LiveView, layout: {DragonesWeb.Layouts, :app}

  alias Dragones.{Games, Scenario}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       catalog: Scenario.catalog(),
       changeset: %{title: "", scene: "", dm_style: "vivid but brief"},
       # No pre-selection — the creator explicitly picks the cast.
       roster: %{},
       error: nil
     )}
  end

  @impl true
  def handle_event("save", params, socket) do
    case Games.create_from_wizard(params) do
      {:ok, game} ->
        {:noreply, push_navigate(socket, to: "/games/#{game.id}")}

      {:error, :no_characters} ->
        {:noreply, assign(socket, error: "Selecciona al menos un personaje.")}

      {:error, _} ->
        {:noreply, assign(socket, error: "No se pudo crear la partida.")}
    end
  end

  # The form is stateless (plain HTML inputs); we don't track every keystroke,
  # we just render the catalogue and read the params on submit.
  @impl true
  def render(assigns) do
    ~H"""
    <div class="wizard">
      <style>
        .wizard{max-width:680px; margin:0 auto; padding:1.5rem;}
        .wizard h1{font-size:1.3rem;}
        .wizard label{display:block; font-size:.8rem; color:#7ab; text-transform:uppercase; margin:.8rem 0 .2rem;}
        .wizard input[type=text], .wizard textarea{width:100%; padding:.5rem; background:#222; color:#eee; border:1px solid #444; border-radius:4px; font-size:.95rem; box-sizing:border-box;}
        .wizard .row{display:flex; align-items:center; gap:.6rem; padding:.5rem 0; border-bottom:1px solid #222;}
        .wizard .row .name{font-weight:600; min-width:7rem;}
        .wizard .row .role{color:#888; font-size:.85rem;}
        .wizard select{padding:.3rem; background:#222; color:#eee; border:1px solid #444; border-radius:4px;}
        .wizard .error{color:#f99; margin:.6rem 0;}
        .btn{padding:.5rem 1.2rem; border-radius:6px; border:1px solid #a72; background:#3a2a1a; color:#fc8; font-size:1rem; cursor:pointer; margin-top:1rem;}
        .btn:hover{background:#4a3520;}
        .back{color:#7ab; text-decoration:none; font-size:.85rem;}
      </style>

      <h1>Nueva partida</h1>
      <.link navigate={"/"} class="back">← volver</.link>

      <form phx-submit="save">
        <label>Título</label>
        <input type="text" name="title" value={Map.get(@changeset, :title)} placeholder="La Ruina de la Antorcha" />

        <label>Escena inicial</label>
        <input type="text" name="scene" value={Map.get(@changeset, :scene)} placeholder="una ruina iluminada por antorchas" />

        <label>Estilo del DM</label>
        <input type="text" name="dm_style" value={Map.get(@changeset, :dm_style)} />

        <label>Personajes</label>
        <div :for={c <- @catalog} :key={c.key}>
          <div class="row">
            <input
              type="checkbox"
              name={"roster[#{c.key}][include]"}
              value="on"
              checked={Map.get(Map.get(@roster, c.key, %{}), "include") == "on"}
            />
            <span class="name">{c.name}</span>
            <span class="role">{c.role} · {c.side}</span>
            <select
              :if={c.side == "pc"}
              name={"roster[#{c.key}][kind]"}
            >
              <option value="human" selected={Map.get(Map.get(@roster, c.key, %{}), "kind") != "ai"}>humano</option>
              <option value="ai" selected={Map.get(Map.get(@roster, c.key, %{}), "kind") == "ai"}>IA</option>
            </select>
          </div>
        </div>

        <div :if={@error} class="error">{@error}</div>
        <button class="btn" type="submit">Crear partida</button>
      </form>
    </div>
    """
  end
end
