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

  alias Dragonex.{Character, Heroes, I18n}
  alias Dragonex.Heroes.{Catalog, Classes, Draft, Races, Scoring, Translations}

  attr(:form, :map, required: true)
  attr(:locale, :atom, default: :es)

  def identity_step(assigns) do
    ~H"""
    <div>
      <div class="step-label">Nombre</div>
      <input type="text" name="name" value={@form.name} phx-change="change" placeholder="Lyra, Thane, Vex…" />

      <div class="step-label">Sexo</div>
      <div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(120px,1fr));">
        <%= for sex <- ["hombre", "mujer", "no binario"] do %>
          <div class={"opt #{if @form.sex == sex, do: "sel", else: ""}"}
               phx-click="select" phx-value-field="sex" phx-value-value={sex}>
            <div class="on">{String.capitalize(sex)}</div>
          </div>
        <% end %>
      </div>

      <div class="step-label">Raza</div>
      <div class="grid">
        <%= for race <- Catalog.races(@locale) do %>
          <div class={"opt #{if @form.race == race.key, do: "sel", else: ""}"}
               phx-click="select" phx-value-field="race" phx-value-value={race.key}>
            <div class="on">{race.label}</div>
            <div class="od">{subrace_hint(race)}</div>
          </div>
        <% end %>
      </div>

      <div :if={@form.race && subraces_for(@form.race, @locale) != []}>
        <div class="step-label">Subraza</div>
        <select class="select-row" name="subrace" phx-change="change">
          <option value="">(elige subraza)</option>
          <%= for sr <- subraces_for(@form.race, @locale) do %>
            <option value={sr.key} selected={@form.subrace == sr.key}>{sr.label}</option>
          <% end %>
        </select>
      </div>

      <div class="step-label">Clase</div>
      <div class="grid">
        <%= for class <- Catalog.classes(@locale) do %>
          <div class={"opt #{if @form.class == class.key, do: "sel", else: ""}"}
               phx-click="select" phx-value-field="class" phx-value-value={class.key}>
            <div class="on">{class.label}</div>
            <div class="od">{class_hint(class)}</div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def heritage_step(assigns) do
    ~H"""
    <div>
      <div class="step-label">Trasfondo</div>
      <div class="grid">
        <%= for bg <- Catalog.backgrounds(@locale) do %>
          <div class={"opt #{if @form.background == bg.key, do: "sel", else: ""}"}
               phx-click="select" phx-value-field="background" phx-value-value={bg.key}>
            <div class="on">{bg.label}</div>
          </div>
        <% end %>
      </div>

      <div class="step-label">Puntuaciones de característica</div>
      <div class="grid" style="grid-template-columns:1fr 1fr;">
        <div class={"opt #{if @form.score_method == "auto", do: "sel", else: ""}"}
             phx-click="select" phx-value-field="score_method" phx-value-value="auto">
          <div class="on">Standard Array</div>
          <div class="od">Auto: 15·14·13·12·10·8</div>
        </div>
        <div class={"opt #{if @form.score_method == "pointbuy", do: "sel", else: ""}"}
             phx-click="select" phx-value-field="score_method" phx-value-value="pointbuy">
          <div class="on">Point Buy</div>
          <div class="od">27 pts · rango 8–15</div>
        </div>
      </div>

      <div :if={@form.score_method == "pointbuy"} style="margin-top:1rem;">
        <div class="step-label">
          Point Buy — Restantes: <strong style="color:#fc8;">{Scoring.point_buy_remaining(@form.pb)}</strong> pts
        </div>
        <div class="pb-grid">
          <%= for ab <- [:str, :dex, :con, :int, :wis, :cha] do %>
            <% val = @form.pb[ab]
               cost = Scoring.cost_for(val)
               ab_label = Translations.ability_short(ab, @locale) %>
            <div class="pb-row">
              <span class="pb-ab">{ab_label}</span>
              <button type="button" class="pb-btn" phx-click="pb_adjust" phx-value-ability={ab} phx-value-delta="-1">−</button>
              <span class="pb-val">{val}</span>
              <button type="button" class="pb-btn" phx-click="pb_adjust" phx-value-ability={ab} phx-value-delta="1">+</button>
              <span class="pb-cost">({cost}p)</span>
            </div>
          <% end %>
        </div>
        <div class="od" style="color:#555;font-size:.72rem;margin-top:.3rem;">
          Costes: 8→0, 9→1, 10→2, 11→3, 12→4, 13→5, 14→7, 15→9
        </div>
      </div>

      <div :if={@form.score_method == "auto"} class="od" style="text-align:center;color:#555;font-size:.78rem;margin-top:.3rem;">
        Asignado automáticamente según la prioridad de la clase.
      </div>

      <.skill_picker :if={@form.class} form={@form} locale={@locale} />
      <.language_picker :if={extra_langs(@form) > 0} form={@form} locale={@locale} count={extra_langs(@form)} />

    </div>
    """
  end

  defp skill_picker(assigns) do
    ~H"""
    <div style="margin-top:1rem;">
      <div class="step-label">
        Habilidades
        <span :if={skill_opts(@form.class)} style="color:#889;font-weight:normal;font-size:.78rem;">
          ({skill_selected_count(@form)}/{skill_opts(@form.class).count}) · el trasfondo añade las suyas gratis
        </span>
      </div>
      <div class="od" style="color:#555;font-size:.78rem;margin-bottom:.4rem;">
        Elige las habilidades de tu clase. Las del trasfondo se suman automáticamente.
      </div>
      <div class="spell-chips">
        <%= with %{count: count, options: options} <- skill_opts(@form.class) do %>
          <% selected = @form.skills_choice || [] %>
          <% full = length(selected) >= count %>
          <%= for opt <- options do %>
            <% on = opt.key in selected
               locked = full and not on %>
            <button type="button"
                    class={"spell-chip #{if on, do: "sel", else: ""} #{if locked, do: "locked", else: ""}"}
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
    <div style="margin-top:1rem;">
      <div class="step-label">
        Idiomas adicionales
        <span style="color:#889;font-weight:normal;font-size:.78rem;">
          ({lang_selected_count(@form)}/{@count})
        </span>
      </div>
      <div class="od" style="color:#555;font-size:.78rem;margin-bottom:.4rem;">
        Tu raza o trasfondo te deja elegir idiomas extra.
      </div>
      <div class="spell-chips">
        <%= for key <- extra_language_choices(@form, @locale) do %>
          <% on = key in (@form.extra_langs || [])
             locked = lang_selected_count(@form) >= @count and not on %>
          <button type="button"
                  class={"spell-chip #{if on, do: "sel", else: ""} #{if locked, do: "locked", else: ""}"}
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
      <div :if={is_nil(@form.class)}>
        <div class="od" style="text-align:center;color:#555;font-size:.85rem;">
          Elige una clase en el paso de Identidad para configurar su equipo.
        </div>
      </div>

      <div :if={@form.class}>
        <div class="step-label">Equipo inicial de {Translations.class(@form.class, @locale)}</div>
        <div class="od" style="color:#555;font-size:.78rem;margin-bottom:.6rem;">
          Elige una opción en cada grupo. Es el equipo inicial según D&D 5e.
        </div>

        <%= for group <- Catalog.equipment_for_class(@form.class, @locale) do %>
          <% selected = Map.get(@form.equipment, group.id, 0) %>
          <div class="equip-group">
            <div class="equip-group-label">
              <%= case group.id do %>
                <% :weapon -> %> Arma
                <% :side -> %> Secundaria
                <% :defense -> %> Defensa
                <% :armor -> %> Armadura
                <% :shield -> %> Escudo
                <% :ranged -> %> A distancia
                <% :thrown -> %> Arrojadiza
                <% :bow -> %> Arco
                <% :focus -> %> Foco
                <% :pack -> %> Mochila
                <% :ammo -> %> Munición
                <% :darts -> %> Dardos
                <% :daggers -> %> Dagas
                <% :tools -> %> Herramientas
                <% :dagger -> %> Daga
                <% :simple -> %> Arma simple
                <% :spellbook -> %> Grimorio
                <% _ -> %> Otro
              <% end %>
            </div>
            <div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(160px,1fr));">
              <%= for opt <- group.options do %>
                <div class={"opt #{if selected == opt.index, do: "sel", else: ""}"}
                     phx-click="equip" phx-value-group={group.id} phx-value-index={opt.index}>
                  <div class="on">{opt.label}</div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <div class="od" style="color:#555;font-size:.72rem;margin-top:.6rem;">
          El equipo del trasfondo se añade automáticamente más adelante.
        </div>
      </div>
    </div>
    """
  end

  def details_step(assigns) do
    ~H"""
    <div>
      <.spell_picker :if={Classes.caster?(@form.class)} form={@form} locale={@locale} custom={@custom} />
      <.custom_picker :if={has_custom?(@custom)} form={@form} custom={@custom} locale={@locale} />

      <div class="step-label">Historia (opcional)</div>
      <textarea name="backstory" phx-change="change" placeholder="Un ex-soldado que empuñó la espada de nuevo cuando su aldea ardió…">{@form.backstory}</textarea>
      <div class="od" style="color:#555;font-size:.78rem;margin-top:.3rem;">Vacío = se genera una por defecto.</div>
    </div>
    """
  end

  defp has_custom?(custom) do
    (custom[:weapons] || []) != [] or (custom[:items] || []) != []
  end

  attr(:form, :map, required: true)
  attr(:custom, :map, required: true)
  attr(:locale, :atom, default: :es)

  defp custom_picker(assigns) do
    ~H"""
    <div>
      <div class="step-label">Mi contenido (custom)</div>
      <div class="od" style="color:#555;font-size:.78rem;margin-bottom:.4rem;">
        Equipo que has creado en tu biblioteca. Toca para equipárselo (se añade al inicial).
      </div>

      <div :if={@custom.weapons != []} class="spell-group">
        <strong style="color:#7ab;font-size:.75rem;">ARMAS</strong>
        <div class="spell-chips">
          <%= for w <- Enum.filter(Catalog.weapons(@locale, custom: @custom), &(&1.source == :custom)) do %>
            <% selected = w.key in extra_weapons(@form) %>
            <button type="button" class={"spell-chip #{if selected, do: "sel", else: ""}"}
                    title={w.dice}
                    phx-click="extra_weapon_toggle" phx-value-key={w.key}>
              {w.label}
            </button>
          <% end %>
        </div>
      </div>

      <div :if={@custom.items != []} class="spell-group" style="margin-top:.6rem;">
        <strong style="color:#7ab;font-size:.75rem;">OBJETOS</strong>
        <div class="spell-chips">
          <%= for it <- Catalog.items(@locale, custom: @custom) do %>
            <% selected = it.key in extra_item_keys(@form) %>
            <button type="button" class={"spell-chip #{if selected, do: "sel", else: ""}"}
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
      <div class="step-label">Hechizos</div>
      <div class="od" style="color:#555;font-size:.78rem;margin-bottom:.4rem;">
        Toca para seleccionar/deseleccionar. No puedes pasar del cupo de tu clase.
      </div>
      <%= with {:ok, class} <- Classes.get(@form.class),
                sc <- class.spellcasting,
                picks <- Catalog.spells_for_class(@form.class, @locale, custom: @custom),
                custom <- @custom do %>
        <% cantrips_full = Draft.count_selected(@form, 0, custom) >= sc.cantrips
           level1_full = Draft.count_selected(@form, 1, custom) >= sc.spells_level1 %>
        <div class="spell-group">
          <strong style="color:#7ab;font-size:.75rem;">TRUCOS ({Draft.count_selected(@form, 0, custom)}/{sc.cantrips})</strong>
          <div class="spell-chips">
            <%= for entry <- picks.cantrips do %>
              <% selected = Draft.spell_selected?(@form, entry.key)
                 locked = cantrips_full and not selected %>
              <button type="button"
                      class={"spell-chip #{if selected, do: "sel", else: ""} #{if locked, do: "locked", else: ""}"}
                      disabled={locked}
                      title={entry.effect}
                      phx-click={if not locked, do: "spell_toggle"}
                      phx-value-spell={entry.key}>
                {entry.label}
              </button>
            <% end %>
          </div>
        </div>
        <div class="spell-group" style="margin-top:.6rem;">
          <strong style="color:#7ab;font-size:.75rem;">NIVEL 1 ({Draft.count_selected(@form, 1, custom)}/{sc.spells_level1})</strong>
          <div class="spell-chips">
            <%= for entry <- picks.level1 do %>
              <% selected = Draft.spell_selected?(@form, entry.key)
                 locked = level1_full and not selected %>
              <button type="button"
                      class={"spell-chip #{if selected, do: "sel", else: ""} #{if locked, do: "locked", else: ""}"}
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
        <div style="text-align:center;color:#889;font-size:.85rem;margin-top:1rem;">
          Si todo está bien, ¡guarda tu héroe!
        </div>
      <% else %>
        <div class="error">Revisa los pasos anteriores.</div>
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
      <div style="color:#fc8;font-size:.85rem;">
        {Catalog.race_label(@preview.race)} · {Catalog.class_label(@preview.class)} · Nivel {@preview.level}
        <span :if={@preview.sex}>· {String.capitalize(@preview.sex)}</span>
      </div>
      <div class="stats">
        <%= for ab <- [:str, :dex, :con, :int, :wis, :cha] do %>
          <% m = Character.modifier(@preview, ab)
             sign = if m >= 0, do: "+", else: "" %>
          <div>
            <strong>{Map.get(@preview, ab)}</strong>
            {Translations.ability_short(ab)} {sign}{m}
          </div>
        <% end %>
      </div>
      <div class="derived">
        <span>❤ {@preview.hp}/{@preview.max_hp}</span>
        <span>🛡 AC {@preview.ac}</span>
        <span>👁 {@preview.speed} ft</span>
        <span>Salvar: {Catalog.saving_throws(@preview.saving_proficiencies)}</span>
      </div>
      <div :if={@preview.weapons != []} class="spells">
        <strong>Armas:</strong> <%= Enum.map_join(@preview.weapons, ", ", fn w ->
          "#{Catalog.weapon_label(w)} (#{w.dice})"
        end) %>
      </div>
      <div :if={@preview.spells != []} class="spells">
        <strong>Hechizos:</strong>
        <%= Enum.map_join(@preview.spells, ", ", fn s ->
          label = Catalog.spell_label(s)
          if s.level == 0, do: "#{label} (truco)", else: "#{label} (N#{s.level})"
        end) %>
      </div>
      <div :if={@preview.skill_proficiencies != []} class="spells">
        <strong>Habilidades:</strong> {Catalog.skills(@preview.skill_proficiencies)}
      </div>
      <div :if={@preview.languages != []} class="spells">
        <strong>Idiomas:</strong> {Catalog.languages(@preview.languages)}
      </div>
      <div :if={@preview.racial_traits != []} class="spells">
        <strong>Rasgos raciales:</strong> {Enum.join(Catalog.racial_traits(@preview.racial_traits), ", ")}
      </div>
      <div :if={@preview.class_features != []} class="spells">
        <strong>Características de clase:</strong> {Enum.join(Catalog.class_features(@preview.class_features), ", ")}
      </div>
      <div :if={@preview.background_feature} class="spells">
        <strong>Trasfondo:</strong> {Translations.background_feature(@preview.background_feature)}
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------- view helpers

  defp subraces_for(race_key, locale), do: Catalog.subraces(race_key, locale)

  defp subrace_hint(%{subraces: []}), do: ""
  defp subrace_hint(%{subraces: subs}), do: "#{length(subs)} subrazas"

  defp class_hint(%{caster: true, hit_die: d}), do: "conjurador · d#{d}"
  defp class_hint(%{caster: false, hit_die: d}), do: "d#{d}"

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
