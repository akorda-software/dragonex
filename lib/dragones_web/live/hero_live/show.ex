defmodule DragonesWeb.HeroLive.Show do
  @moduledoc """
  Full character sheet for a saved hero — every field, ready to inspect or
  bring into a game.
  """

  use Phoenix.LiveView, layout: {DragonesWeb.Layouts, :app}

  alias Dragones.{Accounts, Character}

  @impl true
  def mount(%{"id" => id}, session, socket) do
    case Accounts.get_user(session["user_id"]) do
      nil ->
        {:ok, Phoenix.LiveView.redirect(socket, to: "/login")}

      user ->
        hero = Accounts.get_user_hero(user, id)
        sheet = hero && Accounts.hero_sheet(hero)
        {:ok, assign(socket, current_user: user, hero: hero, sheet: sheet)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="sheet-page">
      <style>
        .sheet-page{max-width:560px;margin:0 auto;padding:1.5rem;font-family:Georgia,'Times New Roman',serif;}
        .sheet-page h1{font-size:1.5rem;color:#fc8;text-align:center;}
        .sheet-page .role{text-align:center;color:#889;font-size:.9rem;margin-bottom:1rem;}
        .nav-link{color:#7ab;text-decoration:none;font-size:.85rem;}
        .sheet{background:#1a1a1a;border:1px solid #333;border-radius:8px;padding:1.2rem;margin-top:.5rem;}
        .sheet .section-label{font-size:.78rem;color:#7ab;text-transform:uppercase;letter-spacing:.05em;margin:1rem 0 .3rem;}
        .sheet .abilities{display:grid;grid-template-columns:repeat(6,1fr);gap:.4rem;text-align:center;}
        .sheet .ab{background:#222;border:1px solid #333;border-radius:6px;padding:.5rem .2rem;}
        .sheet .ab strong{display:block;font-size:1.2rem;color:#eee;}
        .sheet .ab .lbl{font-size:.68rem;color:#999;}
        .sheet .stats{display:flex;gap:.6rem;flex-wrap:wrap;margin:.6rem 0;}
        .sheet .stats span{background:#222;padding:.3rem .6rem;border-radius:4px;font-size:.85rem;color:#aaa;}
        .sheet ul{list-style:none;padding:0;margin:0;font-size:.85rem;color:#ccc;}
        .sheet li{padding:.2rem 0;border-bottom:1px solid #222;}
        .sheet .spell{font-size:.78rem;color:#aaa;padding:.15rem 0;border-bottom:1px solid #1a1a1a;}
        .sheet .spell strong{color:#fc8;}
        .empty{text-align:center;color:#666;padding:3rem;}
      </style>

      <.link navigate="/heroes" class="nav-link">← mis héroes</.link>

      <%= if @sheet do %>
        <h1>{@sheet.name}</h1>
        <div class="role">
          {String.capitalize(@sheet.race)} · {String.capitalize(@sheet.class)} · Nivel {@sheet.level}
          <span :if={@sheet.sex}>· {String.capitalize(@sheet.sex)}</span>
        </div>

        <div class="sheet">
          <div class="section-label">Atributos</div>
          <div class="abilities">
            <%= for ab <- [:str, :dex, :con, :int, :wis, :cha] do %>
              <% score = Map.get(@sheet, ab)
                 mod = Character.modifier(@sheet, ab)
                 sign = if mod >= 0, do: "+", else: "" %>
              <div class="ab">
                <strong>{score}</strong>
                <div class="lbl">{String.upcase(to_string(ab))} {sign}{mod}</div>
              </div>
            <% end %>
          </div>

          <div class="section-label">Combate</div>
          <div class="stats">
            <span>❤ HP {@sheet.hp}/{@sheet.max_hp}</span>
            <span>🛡 AC {@sheet.ac}</span>
            <span>👁 Speed {@sheet.speed} ft</span>
          </div>
          <div class="stats">
            <span>Salvar: {Enum.join(@sheet.saving_proficiencies, ", ")}</span>
          </div>

          <div :if={@sheet.weapons != []}>
            <div class="section-label">Armas</div>
            <ul>
              <li :for={w <- @sheet.weapons}>
                {w.name} — {w.dice} {w.damage_type}
                <span style="color:#666;font-size:.78rem;">[{w.attack_ability}{if w.finesse, do: ", finesse"}{if w.ranged, do: ", ranged"}]</span>
              </li>
            </ul>
          </div>

          <div :if={@sheet.spells != []}>
            <div class="section-label">Hechizos</div>
            <div :for={s <- @sheet.spells} class="spell">
              <strong>{s.name}</strong>
              <span style="color:#666;">
                {if s.level == 0, do: "cantrip", else: "nivel #{s.level}"}
                · {s.kind} · {s.casting_ability}
                {if s.dice, do: " · #{s.dice} #{s.damage_type || ""}"}
              </span>
            </div>
          </div>

          <div :if={@sheet.inventory != []}>
            <div class="section-label">Equipamiento</div>
            <ul>
              <li :for={item <- @sheet.inventory}>
                {item.name}{if item.qty > 1, do: " ×#{item.qty}"}
                <span style="color:#555;font-size:.72rem;"> [{item.kind}]</span>
              </li>
            </ul>
          </div>

          <div :if={@sheet.backstory}>
            <div class="section-label">Historia</div>
            <p style="color:#aaa;font-size:.85rem;line-height:1.5;">{@sheet.backstory}</p>
          </div>
        </div>
      <% else %>
        <div class="empty">Héroe no encontrado.</div>
      <% end %>
    </div>
    """
  end
end
