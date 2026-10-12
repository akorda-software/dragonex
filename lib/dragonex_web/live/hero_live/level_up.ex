defmodule DragonexWeb.HeroLive.LevelUp do
  @moduledoc """
  Pantalla de subida de nivel de un héroe, dentro del creador.

  Vive en la biblioteca del héroe (fuente de verdad): al confirmar, aplica el
  nivel + PG + elecciones (ASI, hechizos nuevos) al `Hero` vía
  `Accounts.level_up_hero/3`. Si el héroe está en partida, la partida se
  sincroniza desde aquí (ver `Dragonex.Games.sync_hero_level_up/3`).
  """

  use Phoenix.LiveView, layout: {DragonexWeb.Layouts, :app}
  use Gettext, backend: Dragonex.Gettext

  require Logger

  alias Dragonex.{Accounts, Heroes.Catalog, Heroes.Progression, Heroes.Translations}

  @asi_abilities %{
    "str" => :str,
    "dex" => :dex,
    "con" => :con,
    "int" => :int,
    "wis" => :wis,
    "cha" => :cha
  }
  @asi_steps %{"-1" => -1, "1" => 1}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    with %{} = hero <- Accounts.get_user_hero(user, id),
         %{} = sheet <- Accounts.hero_sheet(hero) do
      if sheet.level >= 20 do
        {:ok, Phoenix.LiveView.push_navigate(socket, to: "/heroes/#{hero.id}")}
      else
        {:ok, mount_level_up(socket, user, hero, sheet)}
      end
    else
      _ -> {:ok, Phoenix.LiveView.redirect(socket, to: "/heroes")}
    end
  end

  defp mount_level_up(socket, user, hero, sheet) do
    new_level = sheet.level + 1
    bundle = Accounts.custom_bundle(user)
    max_sl = Progression.max_spell_level(sheet.class, new_level)

    spells_by_level =
      if Progression.caster?(sheet.class) and max_sl >= 1 do
        Catalog.spells_for_class_up_to(sheet.class, max_sl, Dragonex.I18n.locale(),
          custom: bundle
        )
      else
        %{}
      end

    known = MapSet.new(Enum.map(sheet.spells || [], & &1.name))

    socket
    |> assign(:current_user, user)
    |> assign(:hero, hero)
    |> assign(:sheet, sheet)
    |> assign(:bundle, bundle)
    |> assign(:new_level, new_level)
    |> assign(:asi?, Progression.asi_at?(new_level))
    |> assign(:asi_points, Progression.asi_points())
    |> assign(:asi, %{str: 0, dex: 0, con: 0, int: 0, wis: 0, cha: 0})
    |> assign(:spells, [])
    |> assign(:spells_by_level, spells_by_level)
    |> assign(:known_spells, known)
    |> assign(:max_spell_level, max_sl)
    |> assign(:asi_error, nil)
    |> assign(:error, nil)
    |> assign_asi_remaining()
  end

  defp assign_asi_remaining(socket) do
    used = socket.assigns.asi |> Map.values() |> Enum.sum()
    assign(socket, :asi_remaining, socket.assigns.asi_points - used)
  end

  # --- eventos ---

  @impl true
  def handle_event("asi_adjust", %{} = params, socket) do
    with true <- socket.assigns.asi?,
         {:ok, key} <- Map.fetch(@asi_abilities, params["ability"]),
         {:ok, delta} <- Map.fetch(@asi_steps, params["delta"]) do
      current = socket.assigns.asi[key]
      score = Map.get(socket.assigns.sheet, key)

      new_value =
        cond do
          delta < 0 and current > 0 -> current - 1
          delta > 0 and socket.assigns.asi_remaining > 0 and score + current < 20 -> current + 1
          true -> current
        end

      {:noreply,
       socket
       |> update(:asi, &Map.put(&1, key, new_value))
       |> assign(:asi_error, nil)
       |> assign_asi_remaining()}
    else
      false ->
        {:noreply,
         assign(
           socket,
           :asi_error,
           dgettext("ui", "Esta subida no incluye mejora de características.")
         )}

      :error ->
        {:noreply, assign(socket, :asi_error, asi_input_error())}
    end
  end

  def handle_event("asi_adjust", _, socket),
    do: {:noreply, assign(socket, :asi_error, asi_input_error())}

  @impl true
  def handle_event("toggle_spell", %{"key" => key}, socket) do
    spells =
      if key in socket.assigns.spells,
        do: List.delete(socket.assigns.spells, key),
        else: socket.assigns.spells ++ [key]

    {:noreply, assign(socket, :spells, spells)}
  end

  @impl true
  def handle_event("confirm", _params, socket) do
    choices = %{
      expected_level: socket.assigns.sheet.level,
      asi: socket.assigns.asi,
      spells_added: socket.assigns.spells,
      custom: socket.assigns.bundle
    }

    case Accounts.level_up_hero(socket.assigns.current_user, socket.assigns.hero.id, choices) do
      {:ok, _leveled} ->
        # Sincroniza la subida a cualquier partida que use este héroe.
        sync_games(socket)

        {:noreply,
         Phoenix.LiveView.push_navigate(socket, to: "/heroes/#{socket.assigns.hero.id}")}

      {:error, :stale_level} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           dgettext(
             "ui",
             "Tu héroe ya ha cambiado. Revisa su ficha antes de volver a subir de nivel."
           )
         )
         |> Phoenix.LiveView.push_navigate(to: "/heroes/#{socket.assigns.hero.id}")}

      {:error, reason} when is_binary(reason) ->
        {:noreply, assign(socket, :error, reason)}

      {:error, _} ->
        {:noreply,
         assign(socket, :error, dgettext("ui", "No se pudo aplicar la subida de nivel."))}
    end
  end

  # Si el héroe está en partida, aplica los mismos deltas al Character vivo sin
  # pisar el estado transitorio (HP dañado, condiciones, slots). Lo enruta por el
  # GenServer `Game` en toda partida iniciada (single-writer), incluso si hace
  # falta rehidratar su proceso. `Games` solo escribe una sala configurándose.
  #
  # El héroe (fuente de verdad) YA subió al llegar aquí. Si la sincronización a
  # la partida falla (GenServer ocupado, call expira), la registramos pero NO
  # hacemos fallar la subida del héroe. Evita el antiguo `rescue _` que lo
  # tragaba en silencio; no se promete un reintento que el bucle no implementa.
  defp sync_games(socket) do
    %{current_user: user, hero: hero} = socket.assigns
    sheet = Accounts.hero_sheet(Accounts.get_user_hero(user, hero.id))

    for game_id <- Dragonex.Games.games_using_hero(hero.id) do
      try do
        case Dragonex.Games.sync_hero_level_up(game_id, hero.id, sheet) do
          {:ok, _} -> :ok
          {:error, reason} -> log_sync_error(game_id, hero.id, reason)
        end
      catch
        kind, reason ->
          log_sync_error(game_id, hero.id, {kind, reason})
      end
    end
  end

  defp log_sync_error(game_id, hero_id, reason) do
    Logger.warning(
      "dragonex level_up: sync a partida #{game_id} falló (héroe #{hero_id}): " <>
        inspect(reason)
    )
  end

  # --- render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page page-narrow lvlup">

      <div><.link navigate={"/heroes/#{@hero.id}"} class="nav-link">{dgettext("ui", "← ficha del héroe")}</.link></div>
      <header class="page-head">
        <div>
          <h1 class="page-title">{dgettext("ui", "Subir de nivel")}</h1>
          <p class="sub">{@sheet.name} · {Catalog.race_label(@sheet.race)} · {Catalog.class_label(@sheet.class)} · {dgettext("ui", "nivel %{level}", level: @sheet.level)} <span class="lvl-arrow">→ {@new_level}</span></p>
        </div>
      </header>

      <div class="panel win-open">
        <h2><i class="px px-potion" aria-hidden="true"></i>{dgettext("ui", "Lo que sube automáticamente")}</h2>
        <p class="auto">
          {dgettext(
            "ui",
            "Nivel %{level} · Puntos de golpe aumentados (dado medio + CON) · bonificador de competencia y huecos de conjuro recalculados.",
            level: @new_level
          )}
        </p>
        <p :if={length(Progression.features_at(@sheet.class, @new_level)) > 0} class="auto">
          {dgettext("ui", "Nuevas características: %{features}",
            features: format_features(@sheet.class, @new_level)
          )}
        </p>
      </div>

      <div :if={@asi_error} id="asi-choice-error" class="error" role="alert">{@asi_error}</div>

      <div :if={@asi?} class="panel">
        <h2><i class="px px-d20" aria-hidden="true"></i>{dgettext("ui", "Mejora de característica (ASI)")}</h2>
        <div class="asi-remaining">{dgettext("ui", "Puntos restantes:")} <strong>{@asi_remaining}</strong> / {@asi_points}</div>
        <%= for ab <- [:str, :dex, :con, :int, :wis, :cha] do %>
          <% base = Map.get(@sheet, ab)
             assigned = @asi[ab]
             new_score = base + assigned %>
          <div class="asi-row">
            <div>
              <span class="ab">{Translations.ability(ab)}</span>
              <span class="score">{base} → <strong>{new_score}</strong></span>
            </div>
            <div class="asi-controls">
              <button class="btn asi-btn" phx-click="asi_adjust" phx-value-ability={ab} phx-value-delta="-1" disabled={assigned <= 0} aria-label={dgettext("ui", "Quitar punto de %{ability}", ability: Translations.ability(ab))}>−</button>
              <span class="asi-val">{if assigned > 0, do: "+#{assigned}", else: "·"}</span>
              <button class="btn asi-btn" phx-click="asi_adjust" phx-value-ability={ab} phx-value-delta="1" disabled={@asi_remaining <= 0 or new_score >= 20} aria-label={dgettext("ui", "Añadir punto a %{ability}", ability: Translations.ability(ab))}>+</button>
            </div>
          </div>
        <% end %>
      </div>

      <div :if={map_size(@spells_by_level) > 0} class="panel">
        <h2><i class="px px-book" aria-hidden="true"></i>{dgettext("ui", "Hechizos nuevos (opcional)")}</h2>
        <p class="hint-text">{dgettext("ui", "Los atenuados ya los conoce.")}</p>
        <%= for level <- Enum.sort(Map.keys(@spells_by_level)) do %>
          <div class="spell-group">
            <div class="lvl">{if level == 0,
              do: dgettext("ui", "TRUCOS"),
              else: dgettext("ui", "NIVEL %{level}", level: level)}</div>
            <div class="spell-chips">
              <%= for entry <- @spells_by_level[level] do %>
                <% known = MapSet.member?(@known_spells, entry.key)
                   selected = entry.key in @spells %>
                <button class={"spell-chip #{if selected, do: "sel"} #{if known, do: "known"}"}
                        disabled={known}
                        title={entry.effect}
                        phx-click={if not known, do: "toggle_spell"}
                        phx-value-key={entry.key}>
                  {entry.label}
                </button>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <div :if={@error} class="error" role="alert">{@error}</div>

      <div class="form-actions">
        <button type="button" class="btn btn-primary" phx-click="confirm"
                phx-disable-with={dgettext("ui", "Aplicando subida…")}>{dgettext("ui", "Confirmar subida →")}</button>
        <.link navigate={"/heroes/#{@hero.id}"} class="btn btn-ghost">{dgettext("ui", "Cancelar")}</.link>
      </div>
    </div>
    """
  end

  defp asi_input_error,
    do: dgettext("ui", "Elige una característica y usa los botones de mejora disponibles.")

  defp format_features(class, level), do: Enum.join(Progression.features_at(class, level), ", ")
end
