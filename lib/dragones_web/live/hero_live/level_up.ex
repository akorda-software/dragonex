defmodule DragonesWeb.HeroLive.LevelUp do
  @moduledoc """
  Pantalla de subida de nivel de un héroe, dentro del creador.

  Vive en la biblioteca del héroe (fuente de verdad): al confirmar, aplica el
  nivel + PG + elecciones (ASI, hechizos nuevos) al `Hero` vía
  `Accounts.level_up_hero/3`. Si el héroe está en partida, la partida se
  sincroniza desde aquí (ver `Dragones.Games.sync_hero_level_up/2`).
  """

  use Phoenix.LiveView, layout: {DragonesWeb.Layouts, :app}

  require Logger

  alias Dragones.{Accounts, Heroes.Catalog, Heroes.Progression, Heroes.Translations}

  @impl true
  def mount(%{"id" => id}, session, socket) do
    case Accounts.get_user(session["user_id"]) do
      nil ->
        {:ok, Phoenix.LiveView.redirect(socket, to: "/login")}

      user ->
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
  end

  defp mount_level_up(socket, user, hero, sheet) do
    new_level = sheet.level + 1
    bundle = Accounts.custom_bundle(user)
    max_sl = Progression.max_spell_level(sheet.class, new_level)

    spells_by_level =
      if Progression.caster?(sheet.class) and max_sl >= 1 do
        Catalog.spells_for_class_up_to(sheet.class, max_sl, :es, custom: bundle)
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
    |> assign(:error, nil)
    |> assign_asi_remaining()
  end

  defp assign_asi_remaining(socket) do
    used = socket.assigns.asi |> Map.values() |> Enum.sum()
    assign(socket, :asi_remaining, socket.assigns.asi_points - used)
  end

  # --- eventos ---

  @impl true
  def handle_event("asi_adjust", %{"ability" => ab, "delta" => delta}, socket) do
    key = String.to_existing_atom(ab)
    delta = String.to_integer(delta)
    current = socket.assigns.asi[key]
    score = Map.get(socket.assigns.sheet, key)

    new_value =
      cond do
        delta < 0 and current > 0 -> current - 1
        delta > 0 and socket.assigns.asi_remaining > 0 and score + current < 20 -> current + 1
        true -> current
      end

    {:noreply, socket |> update(:asi, &Map.put(&1, key, new_value)) |> assign_asi_remaining()}
  end

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

      {:error, reason} when is_binary(reason) ->
        {:noreply, assign(socket, :error, reason)}

      {:error, _} ->
        {:noreply, assign(socket, :error, "No se pudo aplicar la subida de nivel.")}
    end
  end

  # Si el héroe está en partida, aplica los mismos deltas al Character vivo sin
  # pisar el estado transitorio (HP dañado, condiciones, slots). Lo enruta por el
  # GenServer `Game` cuando la partida está viva (single-writer); si no hay
  # proceso (partida no arrancada), escribe la snapshot+world vía `Games`.
  #
  # El héroe (fuente de verdad) YA subió al llegar aquí. Si la sincronización a
  # la partida falla (GenServer ocupado, call expira), la registramos pero NO
  # hacemos fallar la subida del héroe: la partida se alineará en el próximo
  # beat/rehydrate. Evita el antiguo `rescue _` que lo tragaba en silencio.
  defp sync_games(socket) do
    %{current_user: user, hero: hero} = socket.assigns
    sheet = Accounts.hero_sheet(Accounts.get_user_hero(user, hero.id))

    for game_id <- Dragones.Games.games_using_hero(hero.id) do
      try do
        case Dragones.Game.Supervisor.whereis(game_id) do
          nil ->
            Dragones.Games.sync_hero_level_up(game_id, hero.id, sheet)

          pid ->
            Dragones.Game.sync_hero_level_up(pid, hero.id, sheet)
        end
      catch
        kind, reason ->
          Logger.warning(
            "dragones level_up: sync a partida #{game_id} falló (héroe #{hero.id}): " <>
              inspect({kind, reason})
          )
      end
    end
  end

  # --- render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="lvlup">
      <style>
        .lvlup{width:min(780px,calc(100% - 2rem));margin:0 auto;padding:clamp(1rem,2vw,2rem) 0 2.5rem;font-family:Georgia,'Times New Roman',serif;color:#ddd;}
        .lvlup h1{color:#fc8;font-size:clamp(1.4rem,2vw,1.9rem);margin:.5rem 0 .2rem;}
        .lvlup .sub{color:#889;font-size:.9rem;margin-bottom:1.2rem;}
        .panel{background:rgba(22,22,22,.92);border:1px solid #333;border-radius:12px;padding:1.1rem;margin-bottom:1rem;}
        .panel h2{margin:0 0 .6rem;color:#7ab;font-size:.8rem;text-transform:uppercase;letter-spacing:.08em;font-weight:normal;}
        .auto{color:#9c9;font-size:.9rem;line-height:1.5;}
        .asi-row{display:flex;align-items:center;justify-content:space-between;padding:.5rem 0;border-bottom:1px solid #2a2a2a;}
        .asi-row:last-child{border-bottom:none;}
        .asi-row .ab{color:#ddd;}
        .asi-row .score{color:#889;font-size:.82rem;margin-left:.5rem;}
        .asi-controls{display:flex;align-items:center;gap:.6rem;}
        .asi-btn{width:30px;height:30px;border-radius:6px;border:1px solid #444;background:#222;color:#fc8;cursor:pointer;font-size:1rem;}
        .asi-btn:disabled{opacity:.3;cursor:default;}
        .asi-val{min-width:24px;text-align:center;color:#fc8;font-weight:bold;}
        .asi-remaining{margin-top:.6rem;font-size:.82rem;color:#aa9;}
        .spell-chips{display:flex;flex-wrap:wrap;gap:.35rem;}
        .spell-chip{padding:.25rem .6rem;border-radius:999px;border:1px solid #333;background:#1a1a1a;color:#889;font-size:.78rem;cursor:pointer;font-family:inherit;}
        .spell-chip.sel{background:#3a2a1a;border-color:#a72;color:#fc8;}
        .spell-chip.known{opacity:.4;cursor:default;}
        .spell-group{margin-bottom:.6rem;}
        .spell-group .lvl{color:#7ab;font-size:.72rem;margin-bottom:.25rem;}
        .btn{display:inline-flex;align-items:center;padding:.6rem 1.2rem;border-radius:8px;border:1px solid #a72;background:#3a2a1a;color:#fc8;font-size:.95rem;cursor:pointer;font-family:inherit;text-decoration:none;}
        .btn:hover{background:#4a3520;}
        .btn-ghost{background:#202020;border-color:#3a3a3a;color:#9cd;font-size:.8rem;padding:.4rem .8rem;}
        .error{color:#f99;background:#2a1a1a;border:1px solid #633;border-radius:8px;padding:.7rem;font-size:.85rem;}
        .nav-link{color:#7ab;text-decoration:none;font-size:.85rem;}
      </style>

      <div><.link navigate={"/heroes/#{@hero.id}"} class="nav-link">← ficha del héroe</.link></div>
      <h1>Subir de nivel</h1>
      <div class="sub">{@sheet.name} · {Catalog.race_label(@sheet.race)} · {Catalog.class_label(@sheet.class)} · nivel {@sheet.level} → <strong style="color:#fc8;">{@new_level}</strong></div>

      <div class="panel">
        <h2>Lo que sube automáticamente</h2>
        <p class="auto">
          Nivel {@new_level} · Puntos de golpe aumentados (dado medio + CON) ·
          bonificador de competencia y huecos de conjuro recalculados.
        </p>
        <p :if={length(Progression.features_at(@sheet.class, @new_level)) > 0} class="auto">
          Nuevas características: {format_features(@sheet.class, @new_level)}
        </p>
      </div>

      <div :if={@asi?} class="panel">
        <h2>Mejora de característica (ASI)</h2>
        <div class="asi-remaining">Puntos restantes: <strong style="color:#fc8;">{@asi_remaining}</strong> / {@asi_points}</div>
        <%= for ab <- [:str, :dex, :con, :int, :wis, :cha] do %>
          <% base = Map.get(@sheet, ab)
             assigned = @asi[ab]
             new_score = base + assigned %>
          <div class="asi-row">
            <div>
              <span class="ab">{Translations.ability(ab)}</span>
              <span class="score">{base} → <strong style="color:#fc8;">{new_score}</strong></span>
            </div>
            <div class="asi-controls">
              <button class="asi-btn" phx-click="asi_adjust" phx-value-ability={ab} phx-value-delta="-1" disabled={assigned <= 0}>−</button>
              <span class="asi-val">{if assigned > 0, do: "+#{assigned}", else: "·"}</span>
              <button class="asi-btn" phx-click="asi_adjust" phx-value-ability={ab} phx-value-delta="1" disabled={@asi_remaining <= 0 or new_score >= 20}>+</button>
            </div>
          </div>
        <% end %>
      </div>

      <div :if={map_size(@spells_by_level) > 0} class="panel">
        <h2>Hechizos nuevos (opcional)</h2>
        <div class="od" style="color:#555;font-size:.78rem;margin-bottom:.5rem;">Marcados en gris los que ya conoce.</div>
        <%= for level <- Enum.sort(Map.keys(@spells_by_level)) do %>
          <div class="spell-group">
            <div class="lvl">{if level == 0, do: "TRUCOS", else: "NIVEL #{level}"}</div>
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

      <div :if={@error} class="error">{@error}</div>

      <div style="display:flex;gap:.6rem;margin-top:1rem;">
        <button class="btn" phx-click="confirm">Confirmar subida →</button>
        <.link navigate={"/heroes/#{@hero.id}"} class="btn btn-ghost">Cancelar</.link>
      </div>
    </div>
    """
  end

  defp format_features(class, level), do: Enum.join(Progression.features_at(class, level), ", ")
end
