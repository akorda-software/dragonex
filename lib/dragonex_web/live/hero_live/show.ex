defmodule DragonexWeb.HeroLive.Show do
  @moduledoc """
  Full character sheet for a saved hero — every field, ready to inspect or
  bring into a game.
  """

  use Phoenix.LiveView, layout: {DragonexWeb.Layouts, :app}

  alias Dragonex.{Accounts, Character, Heroes.Catalog, Heroes.Translations}

  @impl true
  def mount(%{"id" => id}, session, socket) do
    case Accounts.get_user(session["user_id"]) do
      nil ->
        {:ok, Phoenix.LiveView.redirect(socket, to: "/login")}

      user ->
        hero = Accounts.get_user_hero(user, id)

        socket =
          socket
          |> assign(:current_user, user)
          |> assign(:hero, hero)
          |> assign(:sheet, hero && Accounts.hero_sheet(hero))
          |> assign(:can_edit, hero && !Accounts.hero_used?(hero))
          |> assign(:error, nil)

        {:ok, load_progress(socket)}
    end
  end

  defp load_progress(socket) do
    case socket.assigns.hero do
      nil ->
        socket

      %{level: level} ->
        xp = (socket.assigns.sheet && socket.assigns.sheet.xp) || 0

        assign(socket,
          level: level,
          xp: xp,
          can_level_up: level < 20,
          target_level: min(level + 1, 20)
        )
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="hero-sheet-page">
      <style>
        .hero-sheet-page{width:min(1180px,calc(100% - clamp(1rem,4vw,3rem)));margin:0 auto;padding:clamp(1rem,2.5vw,2rem) 0 2.5rem;font-family:Georgia,'Times New Roman',serif;color:#ddd;}
        .hero-sheet-page *{box-sizing:border-box;}
        .hero-sheet-nav{display:inline-flex;color:#7ab;text-decoration:none;font-size:.85rem;margin-bottom:.9rem;}
        .hero-sheet-nav:hover{color:#9cd;}
        .hero-sheet-top{display:flex;align-items:center;justify-content:space-between;gap:1rem;}
        .hero-sheet-edit{display:inline-flex;align-items:center;justify-content:center;padding:.4rem .75rem;border-radius:8px;border:1px solid #3a3a3a;background:#202020;color:#9cd;text-decoration:none;font-size:.8rem;}
        .hero-sheet-edit:hover{background:#282828;color:#bde;}
        .hero-sheet-header{text-align:center;margin:0 0 1.15rem;}
        .hero-sheet-header h1{font-size:clamp(1.7rem,3vw,2.4rem);line-height:1.05;color:#fc8;margin:0 0 .55rem;}
        .hero-sheet-role{display:flex;justify-content:center;gap:.45rem;flex-wrap:wrap;color:#889;font-size:.95rem;}
        .hero-sheet-role span{display:inline-flex;align-items:center;min-height:1.7rem;padding:.25rem .65rem;border:1px solid rgba(120,140,150,.22);border-radius:999px;background:rgba(20,20,22,.55);}
        .hero-sheet-layout{display:grid;grid-template-columns:minmax(260px,340px) minmax(0,1fr);gap:1rem;align-items:start;}
        .hero-sheet-stack,.hero-sheet-main{display:grid;gap:1rem;min-width:0;}
        .hero-sheet-main{grid-template-columns:repeat(2,minmax(0,1fr));}
        .hero-sheet-panel{display:block;min-width:0;overflow:hidden;background:rgba(26,26,26,.92);border:1px solid #333;border-radius:14px;padding:1rem;box-shadow:0 18px 45px rgba(0,0,0,.18);}
        .hero-sheet-panel.full{grid-column:1/-1;}
        .hero-sheet-panel h2{margin:0 0 .8rem;color:#7ab;font-size:.78rem;text-transform:uppercase;letter-spacing:.08em;font-weight:normal;}
        .hero-sheet-abilities{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:.6rem;text-align:center;}
        .hero-sheet-ability{background:#222;border:1px solid #363636;border-radius:10px;padding:.75rem .45rem;}
        .hero-sheet-ability strong{display:block;color:#eee;font-size:1.55rem;line-height:1;}
        .hero-sheet-ability span{display:block;margin-top:.35rem;color:#999;font-size:.72rem;letter-spacing:.04em;}
        .hero-sheet-stats{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:.6rem;}
        .hero-sheet-stat{background:#222;border:1px solid #333;border-radius:10px;padding:.7rem;min-width:0;}
        .hero-sheet-stat span{display:block;color:#777;font-size:.68rem;text-transform:uppercase;letter-spacing:.08em;margin-bottom:.25rem;}
        .hero-sheet-stat strong{display:block;color:#eee;font-size:1.05rem;line-height:1.2;overflow-wrap:anywhere;}
        .hero-sheet-save{margin-top:.6rem;background:#201f1f;border:1px solid #333;border-radius:10px;padding:.7rem;color:#bbb;font-size:.88rem;line-height:1.4;}
        .hero-sheet-save span{display:block;color:#777;font-size:.68rem;text-transform:uppercase;letter-spacing:.08em;margin-bottom:.25rem;}
        .hero-sheet-list{list-style:none;padding:0;margin:0;display:grid;gap:.45rem;color:#ccc;font-size:.9rem;}
        .hero-sheet-list li{min-width:0;padding:.5rem 0;border-bottom:1px solid #262626;}
        .hero-sheet-list li:last-child{border-bottom:0;}
        .hero-sheet-line-main{display:block;color:#ddd;overflow-wrap:anywhere;}
        .hero-sheet-line-meta{display:block;color:#777;font-size:.78rem;line-height:1.35;margin-top:.15rem;overflow-wrap:anywhere;}
        .hero-sheet-prose{color:#aaa;font-size:.92rem;line-height:1.6;margin:0;white-space:pre-wrap;overflow-wrap:anywhere;}
        .hero-sheet-empty{text-align:center;color:#666;padding:3rem;background:rgba(20,20,20,.65);border:1px dashed #333;border-radius:14px;}
        @media(max-width:900px){.hero-sheet-layout{grid-template-columns:1fr;}.hero-sheet-main{grid-template-columns:repeat(2,minmax(0,1fr));}.hero-sheet-abilities{grid-template-columns:repeat(3,minmax(0,1fr));}}
        @media(max-width:640px){.hero-sheet-page{width:min(100% - 1rem,1180px);padding-top:1rem;}.hero-sheet-main{grid-template-columns:1fr;}.hero-sheet-abilities,.hero-sheet-stats{grid-template-columns:repeat(2,minmax(0,1fr));}.hero-sheet-header{text-align:left;}.hero-sheet-role{justify-content:flex-start;}.hero-sheet-role span{border-radius:8px;}}
        .level-up-callout{margin-top:.7rem;background:#241c14;border:1px solid #a72;border-radius:10px;padding:.7rem;display:flex;align-items:center;justify-content:space-between;gap:.6rem;color:#fc8;font-size:.85rem;}
        .level-up-callout .btn{background:#3a2a1a;border:1px solid #a72;color:#fc8;padding:.35rem .7rem;border-radius:8px;text-decoration:none;font-size:.8rem;font-family:inherit;}
        .xp-actions{margin-top:.6rem;display:flex;gap:.4rem;flex-wrap:wrap;}
        .xp-actions .btn,.btn-sm{background:#202020;border:1px solid #3a3a3a;color:#9cd;padding:.35rem .6rem;border-radius:8px;font-size:.75rem;font-family:inherit;cursor:pointer;}
        .error{margin:.8rem 0;color:#f99;background:#2a1a1a;border:1px solid #633;border-radius:8px;padding:.7rem;font-size:.85rem;}
      </style>

      <div class="hero-sheet-top">
        <.link navigate="/heroes" class="hero-sheet-nav">← mis héroes</.link>
        <.link :if={@can_edit} navigate={"/heroes/#{@hero.id}/edit"} class="hero-sheet-edit">editar</.link>
      </div>

      <%= if @sheet do %>
        <header class="hero-sheet-header">
          <h1>{@sheet.name}</h1>
          <div class="hero-sheet-role">
            <span>{Catalog.race_label(@sheet.race)}</span>
            <span>{Catalog.class_label(@sheet.class)}</span>
            <span>Nivel {@sheet.level}</span>
            <span :if={@sheet.sex}>{String.capitalize(@sheet.sex)}</span>
          </div>
        </header>

        <div class="hero-sheet-layout">
          <div class="hero-sheet-stack">
            <section class="hero-sheet-panel">
              <h2>Atributos</h2>
              <div class="hero-sheet-abilities">
                <%= for ab <- [:str, :dex, :con, :int, :wis, :cha] do %>
                  <% score = Map.get(@sheet, ab)
                     mod = Character.modifier(@sheet, ab)
                     sign = if mod >= 0, do: "+", else: "" %>
                  <div class="hero-sheet-ability">
                    <strong>{score}</strong>
                    <span>{Translations.ability_short(ab)} {sign}{mod}</span>
                  </div>
                <% end %>
              </div>
            </section>

            <section class="hero-sheet-panel">
              <h2>Combate</h2>
              <div class="hero-sheet-stats">
                <div class="hero-sheet-stat">
                  <span>Puntos de golpe</span>
                  <strong>{@sheet.hp}/{@sheet.max_hp}</strong>
                </div>
                <div class="hero-sheet-stat" :if={positive?(@sheet.temp_hp)}>
                  <span>Temporales</span>
                  <strong>{@sheet.temp_hp}</strong>
                </div>
                <div class="hero-sheet-stat">
                  <span>CA</span>
                  <strong>{@sheet.ac}</strong>
                </div>
                <div class="hero-sheet-stat">
                  <span>Velocidad</span>
                  <strong>{@sheet.speed} ft</strong>
                </div>
              </div>
              <div class="hero-sheet-save">
                <span>Salvaciones</span>
                {fallback(Catalog.saving_throws(@sheet.saving_proficiencies || []), "Ninguna")}
              </div>
            </section>

            <section class="hero-sheet-panel">
              <h2>Progresión</h2>
              <div class="hero-sheet-stats">
                <div class="hero-sheet-stat">
                  <span>Progresión</span>
                  <strong>Por hitos</strong>
                </div>
                <div class="hero-sheet-stat">
                  <span>Experiencia</span>
                  <strong>{@xp} XP</strong>
                </div>
              </div>
              <div :if={@can_level_up} class="level-up-callout">
                <strong>¡Puede subir a nivel {@target_level}!</strong>
                <.link navigate={"/heroes/#{@hero.id}/level-up"} class="btn">Subir de nivel →</.link>
              </div>
            </section>
          </div>

          <div class="hero-sheet-main">
            <section :if={non_empty?(@sheet.weapons)} class="hero-sheet-panel">
              <h2>Armas</h2>
              <ul class="hero-sheet-list">
                <li :for={w <- @sheet.weapons}>
                  <span class="hero-sheet-line-main">{Catalog.weapon_label(w)}</span>
                  <span class="hero-sheet-line-meta">{weapon_meta(w)}</span>
                </li>
              </ul>
            </section>

            <section :if={non_empty?(@sheet.inventory)} class="hero-sheet-panel">
              <h2>Equipamiento</h2>
              <ul class="hero-sheet-list">
                <li :for={item <- @sheet.inventory}>
                  <span class="hero-sheet-line-main">
                    {Catalog.item_label(item)}{if item.qty > 1, do: " ×#{item.qty}"}
                  </span>
                  <span class="hero-sheet-line-meta">{Translations.item_kind(item.kind)}</span>
                </li>
              </ul>
            </section>

            <section :if={non_empty?(@sheet.spells)} class="hero-sheet-panel full">
              <h2>Hechizos</h2>
              <ul class="hero-sheet-list">
                <li :for={s <- @sheet.spells}>
                  <span class="hero-sheet-line-main">{Catalog.spell_label(s)}</span>
                  <span class="hero-sheet-line-meta">{spell_meta(s)}</span>
                </li>
              </ul>
            </section>

            <section :if={non_empty?(@sheet.skill_proficiencies)} class="hero-sheet-panel">
              <h2>Habilidades</h2>
              <p class="hero-sheet-prose">{Catalog.skills(@sheet.skill_proficiencies)}</p>
            </section>

            <section :if={non_empty?(@sheet.languages)} class="hero-sheet-panel">
              <h2>Idiomas</h2>
              <p class="hero-sheet-prose">{Catalog.languages(@sheet.languages)}</p>
            </section>

            <section :if={non_empty?(@sheet.racial_traits)} class="hero-sheet-panel">
              <h2>Rasgos raciales</h2>
              <ul class="hero-sheet-list">
                <li :for={t <- Catalog.racial_traits(@sheet.racial_traits)}>{t}</li>
              </ul>
            </section>

            <section :if={non_empty?(@sheet.class_features)} class="hero-sheet-panel">
              <h2>Características de clase</h2>
              <ul class="hero-sheet-list">
                <li :for={f <- Catalog.class_features(@sheet.class_features)}>{f}</li>
              </ul>
            </section>

            <section :if={@sheet.background_feature} class="hero-sheet-panel">
              <h2>Característica de trasfondo</h2>
              <p class="hero-sheet-prose">{Translations.background_feature(@sheet.background_feature)}</p>
            </section>

            <section :if={non_empty?(@sheet.conditions)} class="hero-sheet-panel">
              <h2>Condiciones</h2>
              <ul class="hero-sheet-list">
                <li :for={condition <- @sheet.conditions}>{condition_label(condition)}</li>
              </ul>
            </section>

            <section :if={present?(@sheet.backstory)} class="hero-sheet-panel full">
              <h2>Historia</h2>
              <p class="hero-sheet-prose">{@sheet.backstory}</p>
            </section>
          </div>
        </div>
      <% else %>
        <div class="hero-sheet-empty">Héroe no encontrado.</div>
      <% end %>
    </div>
    """
  end

  defp non_empty?(value), do: is_list(value) and value != []

  defp positive?(value), do: is_integer(value) and value > 0

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp fallback(value, fallback) when is_binary(value) do
    if String.trim(value) == "", do: fallback, else: value
  end

  defp fallback(_value, fallback), do: fallback

  defp weapon_meta(w) do
    [
      w.dice,
      Translations.damage_type(w.damage_type),
      Translations.ability_short(w.attack_ability),
      if(w.finesse, do: "sutil"),
      if(w.ranged, do: "a distancia")
    ]
    |> compact_join()
  end

  defp spell_meta(s) do
    [
      if(s.level == 0, do: "truco", else: "nivel #{s.level}"),
      Translations.kind(s.kind),
      Translations.ability_short(s.casting_ability),
      if(s.dice, do: compact_join([s.dice, Translations.damage_type(s.damage_type)], " "))
    ]
    |> compact_join()
  end

  defp condition_label(%{name: name}) when is_binary(name), do: name
  defp condition_label(%{"name" => name}) when is_binary(name), do: name
  defp condition_label(condition), do: inspect(condition)

  defp compact_join(values, separator \\ " · ") do
    values
    |> Enum.reject(fn value -> is_nil(value) or value == "" end)
    |> Enum.join(separator)
  end
end
