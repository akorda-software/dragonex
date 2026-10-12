defmodule DragonexWeb.HeroLive.New.Components do
  @moduledoc """
  Presentational function components for the hero creator wizard: the five
  steps (identity, heritage, equipment, details, review) and their pickers
  (skills, languages, spells, custom content) plus the live preview card.

  Extracted from `DragonexWeb.HeroLive.New` so the markup + its view helpers
  live apart from the LiveView's event handling and wizard navigation. The
  spell-cap bookkeeping the `spell_toggle` event needs lives in
  `Dragonex.Heroes.Draft`.
  """

  use Phoenix.Component
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{Character, Heroes, I18n}
  alias Dragonex.Heroes.{Catalog, Classes, Draft, Races, Scoring, Translations}

  attr(:form, :map, required: true)
  attr(:locale, :atom, default: :es)

  def identity_step(assigns) do
    ~H"""
    <div>
      <label class="step-label" for="hero-name">{dgettext("ui", "Nombre")}</label>
      <input id="hero-name" type="text" name="name" value={@form.name} phx-change="change" placeholder="Lyra, Thane, Vex…" />

      <div class="step-label">{dgettext("ui", "Sexo")}</div>
      <div class="grid grid-3">
        <%= for sex <- ["hombre", "mujer", "no binario"] do %>
          <button type="button" id={choice_id("sex", sex)} value={sex}
               class={"opt #{if @form.sex == sex, do: "sel", else: ""}"}
               aria-pressed={to_string(@form.sex == sex)}
               phx-click="select" phx-value-field="sex" phx-value-value={sex}>
            <span class="on">{sex_label(sex)}</span>
          </button>
        <% end %>
      </div>

      <div class="step-label">{dgettext("ui", "Raza")}</div>
      <div class="grid">
        <%= for race <- Catalog.races(@locale) do %>
          <button type="button" id={choice_id("race", race.key)} value={race.key}
               class={"opt #{if @form.race == race.key, do: "sel", else: ""}"}
               aria-pressed={to_string(@form.race == race.key)}
               phx-click="select" phx-value-field="race" phx-value-value={race.key}>
            <span class="on">{race.label}</span>
            <span class="od">{subrace_hint(race)}</span>
          </button>
        <% end %>
      </div>

      <div :if={@form.race && subraces_for(@form.race, @locale) != []}>
        <label class="step-label" for="hero-subrace">{dgettext("ui", "Subraza")}</label>
        <select id="hero-subrace" class="select-row" name="subrace" phx-change="change">
          <option value="">{dgettext("ui", "(elige subraza)")}</option>
          <%= for sr <- subraces_for(@form.race, @locale) do %>
            <option value={sr.key} selected={@form.subrace == sr.key}>{sr.label}</option>
          <% end %>
        </select>
      </div>

      <div class="step-label">{dgettext("ui", "Clase")}</div>
      <div class="grid">
        <%= for class <- Catalog.classes(@locale) do %>
          <button type="button" id={choice_id("class", class.key)} value={class.key}
               class={"opt #{if @form.class == class.key, do: "sel", else: ""}"}
               aria-pressed={to_string(@form.class == class.key)}
               phx-click="select" phx-value-field="class" phx-value-value={class.key}>
            <span class="on">{class.label}</span>
            <span class="od">{class_hint(class)}</span>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  def heritage_step(assigns) do
    ~H"""
    <div>
      <div class="step-label">{dgettext("ui", "Trasfondo")}</div>
      <div class="grid">
        <%= for bg <- Catalog.backgrounds(@locale) do %>
          <button type="button" id={choice_id("background", bg.key)} value={bg.key}
               class={"opt #{if @form.background == bg.key, do: "sel", else: ""}"}
               aria-pressed={to_string(@form.background == bg.key)}
               phx-click="select" phx-value-field="background" phx-value-value={bg.key}>
            <span class="on">{bg.label}</span>
          </button>
        <% end %>
      </div>

      <div class="step-label">{dgettext("ui", "Puntuaciones de característica")}</div>
      <div class="grid grid-2">
        <button type="button" id={choice_id("score-method", "auto")} value="auto"
             class={"opt #{if @form.score_method == "auto", do: "sel", else: ""}"}
             aria-pressed={to_string(@form.score_method == "auto")}
             phx-click="select" phx-value-field="score_method" phx-value-value="auto">
          <span class="on">{dgettext("ui", "Standard Array")}</span>
          <span class="od">{dgettext("ui", "Auto: 15·14·13·12·10·8")}</span>
        </button>
        <button type="button" id={choice_id("score-method", "pointbuy")} value="pointbuy"
             class={"opt #{if @form.score_method == "pointbuy", do: "sel", else: ""}"}
             aria-pressed={to_string(@form.score_method == "pointbuy")}
             phx-click="select" phx-value-field="score_method" phx-value-value="pointbuy">
          <span class="on">{dgettext("ui", "Point Buy")}</span>
          <span class="od">{dgettext("ui", "27 pts · rango 8–15")}</span>
        </button>
      </div>

      <div :if={@form.score_method == "pointbuy"}>
        <div class="step-label">
          {dgettext("ui", "Point Buy — Restantes:")} <strong>{Scoring.point_buy_remaining(@form.pb)}</strong> {dgettext("ui", "pts")}
        </div>
        <div class="pb-grid">
          <%= for ab <- [:str, :dex, :con, :int, :wis, :cha] do %>
            <% val = @form.pb[ab]
               cost = Scoring.cost_for(val)
               ab_label = Translations.ability_short(ab, @locale) %>
            <div class="pb-row">
              <span class="pb-ab">{ab_label}</span>
              <button type="button" class="btn pb-btn" aria-label={dgettext("ui", "Disminuir %{ability}", ability: Translations.ability(ab, @locale))} phx-click="pb_adjust" phx-value-ability={ab} phx-value-delta="-1">−</button>
              <span class="pb-val">{val}</span>
              <button type="button" class="btn pb-btn" aria-label={dgettext("ui", "Aumentar %{ability}", ability: Translations.ability(ab, @locale))} phx-click="pb_adjust" phx-value-ability={ab} phx-value-delta="1">+</button>
              <span class="pb-cost">({cost}p)</span>
            </div>
          <% end %>
        </div>
        <p class="hint-text">{dgettext("ui", "Costes: 8→0, 9→1, 10→2, 11→3, 12→4, 13→5, 14→7, 15→9")}</p>
      </div>

      <p :if={@form.score_method == "auto"} class="hint-text">
        {dgettext("ui", "Asignado automáticamente según la prioridad de la clase.")}
      </p>

      <.skill_picker :if={@form.class} form={@form} locale={@locale} />
      <.language_picker :if={extra_langs(@form) > 0} form={@form} locale={@locale} count={extra_langs(@form)} />

    </div>
    """
  end

  defp skill_picker(assigns) do
    ~H"""
    <div>
      <div class="step-label">
        {dgettext("ui", "Habilidades")}
        <span :if={skill_opts(@form.class)} class="count">
          ({skill_selected_count(@form)}/{skill_opts(@form.class).count}) · {dgettext("ui", "el trasfondo añade las suyas gratis")}
        </span>
      </div>
      <p class="hint-text">{dgettext("ui", "Elige las habilidades de tu clase. Las del trasfondo se suman automáticamente.")}</p>
      <div class="spell-chips">
        <%= with %{count: count, options: options} <- skill_opts(@form.class) do %>
          <% selected = @form.skills_choice || [] %>
          <% full = length(selected) >= count %>
          <%= for opt <- options do %>
            <% on = opt.key in selected
               locked = full and not on %>
            <button type="button"
                    class={"spell-chip #{if on, do: "sel", else: ""} #{if locked, do: "locked", else: ""}"}
                    aria-pressed={to_string(on)}
                    disabled={locked}
                    phx-click={if not locked, do: "skill_toggle"}
                    phx-value-skill={opt.key}>
              {opt.label}
            </button>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp language_picker(assigns) do
    ~H"""
    <div>
      <div class="step-label">
        {dgettext("ui", "Idiomas adicionales")}
        <span class="count">
          ({lang_selected_count(@form)}/{@count})
        </span>
      </div>
      <p class="hint-text">{dgettext("ui", "Tu raza o trasfondo te deja elegir idiomas extra.")}</p>
      <div class="spell-chips">
        <%= for key <- extra_language_choices(@form, @locale) do %>
          <% on = key in (@form.extra_langs || [])
             locked = lang_selected_count(@form) >= @count and not on %>
          <button type="button"
                  class={"spell-chip #{if on, do: "sel", else: ""} #{if locked, do: "locked", else: ""}"}
                  aria-pressed={to_string(on)}
                  disabled={locked}
                  phx-click={if not locked, do: "lang_toggle"}
                  phx-value-lang={key}>
            {Translations.language(key, @locale)}
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  def equipment_step(assigns) do
    ~H"""
    <div>
      <p :if={is_nil(@form.class)} class="hint-text">
        {dgettext("ui", "Elige una clase en el paso de Identidad para configurar su equipo.")}
      </p>

      <div :if={@form.class}>
        <div class="step-label">{dgettext("ui", "Equipo inicial de %{class}", class: Translations.class(@form.class, @locale))}</div>
        <p class="hint-text">{dgettext("ui", "Elige una opción en cada grupo. Es el equipo inicial según D&D 5e.")}</p>

        <%= for group <- Catalog.equipment_for_class(@form.class, @locale) do %>
          <% selected = Map.get(@form.equipment, group.id, 0) %>
          <div class="equip-group">
            <div class="equip-group-label">
              <%= case group.id do %>
                <% :weapon -> %> {dgettext("ui", "Arma")}
                <% :side -> %> {dgettext("ui", "Secundaria")}
                <% :defense -> %> {dgettext("ui", "Defensa")}
                <% :armor -> %> {dgettext("ui", "Armadura")}
                <% :shield -> %> {dgettext("ui", "Escudo")}
                <% :ranged -> %> {dgettext("ui", "A distancia")}
                <% :thrown -> %> {dgettext("ui", "Arrojadiza")}
                <% :bow -> %> {dgettext("ui", "Arco")}
                <% :focus -> %> {dgettext("ui", "Foco")}
                <% :pack -> %> {dgettext("ui", "Mochila")}
                <% :ammo -> %> {dgettext("ui", "Munición")}
                <% :darts -> %> {dgettext("ui", "Dardos")}
                <% :daggers -> %> {dgettext("ui", "Dagas")}
                <% :tools -> %> {dgettext("ui", "Herramientas")}
                <% :dagger -> %> {dgettext("ui", "Daga")}
                <% :simple -> %> {dgettext("ui", "Arma simple")}
                <% :spellbook -> %> {dgettext("ui", "Grimorio")}
                <% _ -> %> {dgettext("ui", "Otro")}
              <% end %>
            </div>
            <div class="grid grid-equip">
              <%= for opt <- group.options do %>
                <button type="button" id={choice_id("equipment-#{group.id}", opt.index)}
                     class={"opt #{if selected == opt.index, do: "sel", else: ""}"}
                     aria-pressed={to_string(selected == opt.index)}
                     phx-click="equip" phx-value-group={group.id} phx-value-index={opt.index}>
                  <span class="on">{opt.label}</span>
                </button>
              <% end %>
            </div>
          </div>
        <% end %>

        <p class="hint-text">{dgettext("ui", "El equipo del trasfondo se añade automáticamente más adelante.")}</p>
      </div>
    </div>
    """
  end

  def details_step(assigns) do
    ~H"""
    <div>
      <.spell_picker :if={Classes.caster?(@form.class)} form={@form} locale={@locale} custom={@custom} />
      <.custom_picker :if={has_custom?(@custom)} form={@form} custom={@custom} locale={@locale} />

      <label class="step-label" for="hero-backstory">{dgettext("ui", "Historia (opcional)")}</label>
      <textarea id="hero-backstory" name="backstory" phx-change="change" placeholder={dgettext("ui", "Un ex-soldado que empuñó la espada de nuevo cuando su aldea ardió…")}>{@form.backstory}</textarea>
      <p class="hint-text">{dgettext("ui", "Si lo dejas vacío, se genera una por defecto.")}</p>
    </div>
    """
  end

  defp choice_id(field, value),
    do: "hero-choice-#{field}-#{String.replace(to_string(value), " ", "-")}"

  defp has_custom?(custom) do
    (custom[:weapons] || []) != [] or (custom[:items] || []) != []
  end

  attr(:form, :map, required: true)
  attr(:custom, :map, required: true)
  attr(:locale, :atom, default: :es)

  defp custom_picker(assigns) do
    ~H"""
    <div>
      <div class="step-label">{dgettext("ui", "Mi contenido (custom)")}</div>
      <p class="hint-text">{dgettext("ui", "Equipo que has creado en tu biblioteca. Toca para equipárselo (se añade al inicial).")}</p>

      <div :if={@custom.weapons != []} class="spell-group">
        <strong>{dgettext("ui", "ARMAS")}</strong>
        <div class="spell-chips">
          <%= for w <- Enum.filter(Catalog.weapons(@locale, custom: @custom), &(&1.source == :custom)) do %>
            <% selected = w.key in extra_weapons(@form) %>
            <button type="button" class={"spell-chip #{if selected, do: "sel", else: ""}"}
                    aria-pressed={to_string(selected)}
                    title={w.dice}
                    phx-click="extra_weapon_toggle" phx-value-key={w.key}>
              {w.label}
            </button>
          <% end %>
        </div>
      </div>

      <div :if={@custom.items != []} class="spell-group">
        <strong>{dgettext("ui", "OBJETOS")}</strong>
        <div class="spell-chips">
          <%= for it <- Catalog.items(@locale, custom: @custom) do %>
            <% selected = it.key in extra_item_keys(@form) %>
            <button type="button" class={"spell-chip #{if selected, do: "sel", else: ""}"}
                    aria-pressed={to_string(selected)}
                    phx-click="extra_item_toggle" phx-value-key={it.key}>
              {it.label}
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp extra_weapons(form), do: form[:extra_equipment][:weapons] || []

  defp extra_item_keys(form) do
    Enum.map(form[:extra_equipment][:items] || [], fn
      %{key: k} -> k
      %{"key" => k} -> k
      _ -> nil
    end)
  end

  defp spell_picker(assigns) do
    ~H"""
    <div>
      <div class="step-label">{dgettext("ui", "Hechizos")}</div>
      <p class="hint-text">{dgettext("ui", "Toca para seleccionar o quitar. No puedes pasar del cupo de tu clase.")}</p>
      <%= with {:ok, class} <- Classes.get(@form.class),
                sc <- class.spellcasting,
                picks <- Catalog.spells_for_class(@form.class, @locale, custom: @custom),
                custom <- @custom do %>
        <% cantrips_full = Draft.count_selected(@form, 0, custom) >= sc.cantrips
           level1_full = Draft.count_selected(@form, 1, custom) >= sc.spells_level1 %>
        <div class="spell-group">
          <strong>{dgettext("ui", "TRUCOS")} ({Draft.count_selected(@form, 0, custom)}/{sc.cantrips})</strong>
          <div class="spell-chips">
            <%= for entry <- picks.cantrips do %>
              <% selected = Draft.spell_selected?(@form, entry.key)
                 locked = cantrips_full and not selected %>
              <button type="button"
                      class={"spell-chip #{if selected, do: "sel", else: ""} #{if locked, do: "locked", else: ""}"}
                      aria-pressed={to_string(selected)}
                      disabled={locked}
                      title={entry.effect}
                      phx-click={if not locked, do: "spell_toggle"}
                      phx-value-spell={entry.key}>
                {entry.label}
              </button>
            <% end %>
          </div>
        </div>
        <div class="spell-group">
          <strong>{dgettext("ui", "NIVEL %{level}", level: 1)} ({Draft.count_selected(@form, 1, custom)}/{sc.spells_level1})</strong>
          <div class="spell-chips">
            <%= for entry <- picks.level1 do %>
              <% selected = Draft.spell_selected?(@form, entry.key)
                 locked = level1_full and not selected %>
              <button type="button"
                      class={"spell-chip #{if selected, do: "sel", else: ""} #{if locked, do: "locked", else: ""}"}
                      aria-pressed={to_string(selected)}
                      disabled={locked}
                      title={entry.effect}
                      phx-click={if not locked, do: "spell_toggle"}
                      phx-value-spell={entry.key}>
                {entry.label}
              </button>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  def review_step(assigns) do
    ~H"""
    <div>
      <%= if @preview do %>
        <.preview_card preview={@preview} locale={@locale} />
        <p class="review-note">{dgettext("ui", "Si todo está bien, ¡guarda tu héroe!")}</p>
      <% else %>
        <div class="error">{dgettext("ui", "Revisa los pasos anteriores.")}</div>
      <% end %>
    </div>
    """
  end

  # --------------------------------------------------------------- preview card

  attr(:preview, Character, required: true)
  attr(:locale, :atom, default: :es)

  def preview_card(assigns) do
    ~H"""
    <div class="pv">
      <h3>{@preview.name}</h3>
      <div class="pv-role">
        {Catalog.race_label(@preview.race)} · {Catalog.class_label(@preview.class)} · {dgettext("ui", "Nivel %{level}", level: @preview.level)}
        <span :if={@preview.sex}>· {sex_label(@preview.sex)}</span>
      </div>
      <div class="stats">
        <%= for ab <- [:str, :dex, :con, :int, :wis, :cha] do %>
          <% m = Character.modifier(@preview, ab)
             sign = if m >= 0, do: "+", else: "" %>
          <div class="stat-box">
            <strong>{Map.get(@preview, ab)}</strong>
            <span>{Translations.ability_short(ab)} {sign}{m}</span>
          </div>
        <% end %>
      </div>
      <div class="derived">
        <span class="tag" title={dgettext("ui", "Puntos de golpe")}><i class="px px-heart" aria-hidden="true"></i>{dgettext("ui", "%{hp}/%{max_hp} PG", hp: @preview.hp, max_hp: @preview.max_hp)}</span>
        <span class="tag" title={dgettext("ui", "Clase de armadura")}><i class="px px-shield" aria-hidden="true"></i>{dgettext("ui", "CA %{ac}", ac: @preview.ac)}</span>
        <span class="tag" title={dgettext("ui", "Velocidad")}><i class="px px-boot" aria-hidden="true"></i>{@preview.speed} ft</span>
        <span class="tag">{dgettext("ui", "Salvaciones: %{saves}", saves: Catalog.saving_throws(@preview.saving_proficiencies))}</span>
      </div>
      <div :if={@preview.weapons != []} class="spells">
        <strong>{dgettext("ui", "Armas:")}</strong> <%= Enum.map_join(@preview.weapons, ", ", fn w ->
          "#{Catalog.weapon_label(w)} (#{w.dice})"
        end) %>
      </div>
      <div :if={@preview.spells != []} class="spells">
        <strong>{dgettext("ui", "Hechizos:")}</strong>
        <%= Enum.map_join(@preview.spells, ", ", fn s ->
          label = Catalog.spell_label(s)
          if s.level == 0,
            do: dgettext("ui", "%{spell} (truco)", spell: label),
            else: dgettext("ui", "%{spell} (N%{level})", spell: label, level: s.level)
        end) %>
      </div>
      <div :if={@preview.skill_proficiencies != []} class="spells">
        <strong>{dgettext("ui", "Habilidades:")}</strong> {Catalog.skills(@preview.skill_proficiencies)}
      </div>
      <div :if={@preview.languages != []} class="spells">
        <strong>{dgettext("ui", "Idiomas:")}</strong> {Catalog.languages(@preview.languages)}
      </div>
      <div :if={@preview.racial_traits != []} class="spells">
        <strong>{dgettext("ui", "Rasgos raciales:")}</strong> {Enum.join(Catalog.racial_traits(@preview.racial_traits), ", ")}
      </div>
      <div :if={@preview.class_features != []} class="spells">
        <strong>{dgettext("ui", "Características de clase:")}</strong> {Enum.join(Catalog.class_features(@preview.class_features), ", ")}
      </div>
      <div :if={@preview.background_feature} class="spells">
        <strong>{dgettext("ui", "Trasfondo:")}</strong> {Translations.background_feature(@preview.background_feature)}
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------- view helpers

  defp subraces_for(race_key, locale), do: Catalog.subraces(race_key, locale)

  defp subrace_hint(%{subraces: []}), do: ""

  defp subrace_hint(%{subraces: subs}),
    do: dgettext("ui", "%{count} subrazas", count: length(subs))

  defp class_hint(%{caster: true, hit_die: d}),
    do: dgettext("ui", "conjurador · d%{die}", die: d)

  defp class_hint(%{caster: false, hit_die: d}), do: "d#{d}"

  @doc """
  Etiqueta visible del sexo del héroe. Los valores guardados (`"hombre"`,
  `"mujer"`, `"no binario"`) son datos y no se traducen; solo su etiqueta.
  """
  def sex_label("hombre"), do: dgettext("ui", "Hombre")
  def sex_label("mujer"), do: dgettext("ui", "Mujer")
  def sex_label("no binario"), do: dgettext("ui", "No binario")
  def sex_label(sex) when is_binary(sex), do: String.capitalize(sex)

  # nº de idiomas extra que tocan según raza+subraza+trasfondo actuales
  defp extra_langs(form) do
    Heroes.extra_language_slots(form.race, form.subrace, form.background)
  end

  # opciones de skills de la clase, localizadas (o nil si no hay clase)
  defp skill_opts(nil), do: nil

  defp skill_opts(class_key) do
    Catalog.class_skill_options(class_key, I18n.locale())
  end

  defp skill_selected_count(form), do: length(form.skills_choice || [])

  defp lang_selected_count(form), do: length(form.extra_langs || [])

  # idiomas extra que se pueden elegir: todos los del SRD salvo los que la raza
  # (con subraza) ya concede gratis — evita marcar "Común" como extra.
  defp extra_language_choices(form, _locale) do
    known =
      case Races.get(form.race || "", form.subrace) do
        {:ok, race} -> MapSet.new(race.languages)
        _ -> MapSet.new()
      end

    Enum.reject(Translations.languages(), &MapSet.member?(known, &1))
  end
end
