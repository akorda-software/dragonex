defmodule DragonexWeb.HeroLive.Show do
  @moduledoc """
  Full character sheet for a saved hero — every field, ready to inspect or
  bring into a game.
  """

  use Phoenix.LiveView, layout: {DragonexWeb.Layouts, :app}
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{Accounts, Character, Heroes.Catalog, Heroes.Progression, Heroes.Translations}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user
    hero = Accounts.get_user_hero(user, id)

    socket =
      socket
      |> assign(:hero, hero)
      |> assign(:sheet, hero && Accounts.hero_sheet(hero))
      |> assign(:can_edit, hero && !Accounts.hero_used?(hero))
      |> assign(:error, nil)

    {:ok, load_progress(socket)}
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
          can_level_up: Progression.can_level_up?(level, xp),
          target_level: min(level + 1, 20),
          next_threshold: Progression.xp_threshold(level + 1)
        )
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page hero-sheet-page">

      <div class="hero-sheet-top">
        <.link navigate="/heroes" class="hero-sheet-nav">{dgettext("ui", "← mis héroes")}</.link>
        <.link :if={@can_edit} navigate={"/heroes/#{@hero.id}/edit"} class="btn btn-ghost btn-sm">{dgettext("ui", "Editar")}</.link>
      </div>

      <%= if @sheet do %>
        <header class="hero-sheet-header">
          <h1>{@sheet.name}</h1>
          <div class="hero-sheet-role">
            <span class="tag">{Catalog.race_label(@sheet.race)}</span>
            <span class="tag">{Catalog.class_label(@sheet.class)}</span>
            <span class="tag">{dgettext("ui", "Nivel %{level}", level: @sheet.level)}</span>
            <span :if={@sheet.sex} class="tag">
              {DragonexWeb.HeroLive.New.Components.sex_label(@sheet.sex)}
            </span>
          </div>
        </header>

        <div class="hero-sheet-layout">
          <div class="hero-sheet-stack">
            <section class="hero-sheet-panel">
              <h2><i class="px px-d20" aria-hidden="true"></i>{dgettext("ui", "Atributos")}</h2>
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
              <h2><i class="px px-shield" aria-hidden="true"></i>{dgettext("ui", "Combate")}</h2>
              <div class="hero-sheet-stats">
                <div class="hero-sheet-stat">
                  <span>{dgettext("ui", "Puntos de golpe")}</span>
                  <strong><i class="px px-heart" aria-hidden="true"></i>{@sheet.hp}/{@sheet.max_hp}</strong>
                </div>
                <div class="hero-sheet-stat" :if={positive?(@sheet.temp_hp)}>
                  <span>{dgettext("ui", "Temporales")}</span>
                  <strong>{@sheet.temp_hp}</strong>
                </div>
                <div class="hero-sheet-stat">
                  <span>{dgettext("ui", "CA")}</span>
                  <strong><i class="px px-shield" aria-hidden="true"></i>{@sheet.ac}</strong>
                </div>
                <div class="hero-sheet-stat">
                  <span>{dgettext("ui", "Velocidad")}</span>
                  <strong><i class="px px-boot" aria-hidden="true"></i>{@sheet.speed} ft</strong>
                </div>
              </div>
              <div class="hero-sheet-save">
                <span>{dgettext("ui", "Salvaciones")}</span>
                {fallback(Catalog.saving_throws(@sheet.saving_proficiencies || []), dgettext("ui", "Ninguna"))}
              </div>
            </section>

            <section class="hero-sheet-panel">
              <h2><i class="px px-potion" aria-hidden="true"></i>{dgettext("ui", "Progresión")}</h2>
              <div class="hero-sheet-stats">
                <div class="hero-sheet-stat">
                  <span>{dgettext("ui", "Progresión")}</span>
                  <strong>{dgettext("ui", "Tabla PHB")}</strong>
                </div>
                <div class="hero-sheet-stat">
                  <span>{dgettext("ui", "Experiencia")}</span>
                  <strong>{@xp} XP</strong>
                </div>
                <div class="hero-sheet-stat" :if={@next_threshold}>
                  <span>{dgettext("ui", "Umbral nivel %{level}", level: @target_level)}</span>
                  <strong>{@next_threshold} XP</strong>
                </div>
              </div>
              <div :if={@can_level_up} class="level-up-callout">
                <strong>{dgettext("ui", "¡Puede subir a nivel %{level}!", level: @target_level)}</strong>
                <.link navigate={"/heroes/#{@hero.id}/level-up"} class="btn btn-sm">{dgettext("ui", "Subir de nivel →")}</.link>
              </div>
            </section>
          </div>

          <div class="hero-sheet-main">
            <section :if={non_empty?(@sheet.weapons)} class="hero-sheet-panel">
              <h2><i class="px px-swords" aria-hidden="true"></i>{dgettext("ui", "Armas")}</h2>
              <ul class="hero-sheet-list">
                <li :for={w <- @sheet.weapons}>
                  <span class="hero-sheet-line-main">{Catalog.weapon_label(w)}</span>
                  <span class="hero-sheet-line-meta">{weapon_meta(w)}</span>
                </li>
              </ul>
            </section>

            <section :if={non_empty?(@sheet.inventory)} class="hero-sheet-panel">
              <h2><i class="px px-potion" aria-hidden="true"></i>{dgettext("ui", "Equipamiento")}</h2>
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
              <h2><i class="px px-book" aria-hidden="true"></i>{dgettext("ui", "Hechizos")}</h2>
              <ul class="hero-sheet-list">
                <li :for={s <- @sheet.spells}>
                  <span class="hero-sheet-line-main">{Catalog.spell_label(s)}</span>
                  <span class="hero-sheet-line-meta">{spell_meta(s)}</span>
                </li>
              </ul>
            </section>

            <section :if={non_empty?(@sheet.skill_proficiencies)} class="hero-sheet-panel">
              <h2><i class="px px-d20" aria-hidden="true"></i>{dgettext("ui", "Habilidades")}</h2>
              <p class="hero-sheet-prose">{Catalog.skills(@sheet.skill_proficiencies)}</p>
            </section>

            <section :if={non_empty?(@sheet.languages)} class="hero-sheet-panel">
              <h2><i class="px px-scroll" aria-hidden="true"></i>{dgettext("ui", "Idiomas")}</h2>
              <p class="hero-sheet-prose">{Catalog.languages(@sheet.languages)}</p>
            </section>

            <section :if={non_empty?(@sheet.racial_traits)} class="hero-sheet-panel">
              <h2><i class="px px-eye" aria-hidden="true"></i>{dgettext("ui", "Rasgos raciales")}</h2>
              <ul class="hero-sheet-list">
                <li :for={t <- Catalog.racial_traits(@sheet.racial_traits)}>{t}</li>
              </ul>
            </section>

            <section :if={non_empty?(@sheet.class_features)} class="hero-sheet-panel">
              <h2><i class="px px-book" aria-hidden="true"></i>{dgettext("ui", "Características de clase")}</h2>
              <ul class="hero-sheet-list">
                <li :for={f <- Catalog.class_features(@sheet.class_features)}>{f}</li>
              </ul>
            </section>

            <section :if={@sheet.background_feature} class="hero-sheet-panel">
              <h2><i class="px px-quill" aria-hidden="true"></i>{dgettext("ui", "Característica de trasfondo")}</h2>
              <p class="hero-sheet-prose">{Translations.background_feature(@sheet.background_feature)}</p>
            </section>

            <section :if={non_empty?(@sheet.conditions)} class="hero-sheet-panel">
              <h2><i class="px px-skull" aria-hidden="true"></i>{dgettext("ui", "Condiciones")}</h2>
              <ul class="hero-sheet-list">
                <li :for={condition <- @sheet.conditions}>{condition_label(condition)}</li>
              </ul>
            </section>

            <section :if={present?(@sheet.backstory)} class="hero-sheet-panel full">
              <h2><i class="px px-scroll" aria-hidden="true"></i>{dgettext("ui", "Historia")}</h2>
              <p class="hero-sheet-prose">{@sheet.backstory}</p>
            </section>
          </div>
        </div>
      <% else %>
        <div class="empty">{dgettext("ui", "Héroe no encontrado.")}</div>
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
      if(w.finesse, do: dgettext("ui", "sutil")),
      if(w.ranged, do: dgettext("ui", "a distancia"))
    ]
    |> compact_join()
  end

  defp spell_meta(s) do
    [
      if(s.level == 0,
        do: dgettext("ui", "truco"),
        else: dgettext("ui", "nivel %{level}", level: s.level)
      ),
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
