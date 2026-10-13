defmodule DragonexWeb.GameLive.Settings do
  @moduledoc """
  The Ajustes de IA modal: who pays for the table's AI and which model plays
  it (D242). Creator-only, verified server-side on every privileged event.

  Sources:

    * **house** — the server's key. In production only the house model
      (`Dragonex.Models.house_model_id/0`); in dev, the env default.
    * **own:<provider>** — the creator's own key from Tu cuenta. Models come
      from that provider; applying one first runs a tiny real request
      (`Dragonex.AIProviders.probe/1`) so an incompatible model never reaches
      the table.
    * **server:<provider>** — dev only (`:open` mode): any OpenRouter/OpenCode
      model with the server keys.

  Applying restarts the Game with the new models (`Dragonex.Game.restart/2`
  saves the choice in `games.ai`), keeping world, turn and chronicle.
  """

  use Phoenix.Component
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{Accounts, AIProviders, GameAI, Games, Models}

  def handle_event("open_settings", _params, socket) do
    if not creator?(socket) do
      {:noreply, socket}
    else
      game = Games.get_game(socket.assigns.game_id)
      sources = sources(socket.assigns.current_user)

      {source, model} =
        case GameAI.selection(game) do
          %{source: :own, provider: p, model: m} -> {"own:" <> p, m}
          %{source: :server, provider: p, model: m} -> {"server:" <> p, m}
          _ -> {"house", nil}
        end

      source = if Enum.any?(sources, &(&1.key == source)), do: source, else: "house"

      socket
      |> assign(
        show_settings: true,
        settings_sources: sources,
        settings_source: source,
        settings_model: if(source == "house", do: nil, else: model),
        settings_custom_model: "",
        settings_models: [],
        settings_models_status: :idle,
        settings_error: nil,
        settings_checking: false
      )
      |> fetch_models()
      |> then(&{:noreply, &1})
    end
  end

  def handle_event("close_settings", _params, socket),
    do: {:noreply, assign(socket, show_settings: false, settings_checking: false)}

  def handle_event("settings_select_source", %{"source" => key}, socket) do
    if creator?(socket) and Enum.any?(socket.assigns.settings_sources, &(&1.key == key)) do
      socket
      |> assign(
        settings_source: key,
        settings_models: [],
        settings_model: nil,
        settings_custom_model: "",
        settings_models_status: :idle,
        settings_error: nil
      )
      |> fetch_models()
      |> then(&{:noreply, &1})
    else
      {:noreply, socket}
    end
  end

  def handle_event("settings_select_model", %{"model" => model}, socket),
    do: {:noreply, assign(socket, settings_model: model, settings_custom_model: "")}

  def handle_event("settings_custom_model", %{"value" => value}, socket),
    do: {:noreply, assign(socket, settings_custom_model: value || "")}

  def handle_event("settings_refresh_models", _params, socket),
    do: {:noreply, fetch_models(socket)}

  def handle_event("settings_apply", _params, socket) do
    if not creator?(socket) or socket.assigns.settings_checking do
      {:noreply, socket}
    else
      apply_source(socket, socket.assigns.settings_source)
    end
  end

  # The listing task of the source still selected; late answers are dropped.
  def handle_info({:settings_models, source, result}, socket) do
    if socket.assigns.show_settings and socket.assigns.settings_source == source do
      case result do
        {:ok, models} ->
          current = socket.assigns.settings_model

          {model, custom} =
            if current != nil and Enum.any?(models, &(&1.id == current)),
              do: {current, ""},
              else: {nil, current || ""}

          {:noreply,
           assign(socket,
             settings_models: models,
             settings_model: model,
             settings_custom_model: custom,
             settings_models_status: :ok
           )}

        {:error, :no_key} ->
          {:noreply, assign(socket, settings_models: [], settings_models_status: :no_key)}

        error ->
          {:noreply,
           assign(socket,
             settings_models: [],
             settings_models_status: :error,
             settings_error: AIProviders.error_message(error)
           )}
      end
    else
      {:noreply, socket}
    end
  end

  # The probe of an own-key model finished: restart the table or explain why not.
  def handle_info({:settings_probe, source, model_id, result}, socket) do
    if socket.assigns.show_settings and socket.assigns.settings_checking and
         socket.assigns.settings_source == source do
      socket = assign(socket, settings_checking: false)

      case result do
        {:ok, selection, models} -> restart(socket, selection, models)
        error -> {:noreply, assign(socket, settings_error: probe_error(error, model_id))}
      end
    else
      {:noreply, socket}
    end
  end

  # ----------------------------------------------------------------- apply

  defp apply_source(socket, "house") do
    selection = %{source: :house}
    {:ok, models} = GameAI.build(selection, nil)
    restart(socket, selection, models)
  end

  defp apply_source(socket, "server:" <> provider) do
    model = chosen_model(socket)

    case Models.prepare_selection(String.to_existing_atom(provider), model, :none) do
      {:ok, models} ->
        restart(socket, %{source: :server, provider: provider, model: model}, models)

      {:error, message} ->
        {:noreply, assign(socket, settings_error: message)}
    end
  end

  defp apply_source(socket, "own:" <> provider = source) do
    model_id = chosen_model(socket)
    user_id = socket.assigns.current_user.id

    metadata =
      case Enum.find(socket.assigns.settings_models, &(&1.id == model_id)) do
        %{metadata: metadata} -> metadata
        nil -> nil
      end

    cond do
      not is_binary(model_id) or model_id == "" ->
        {:noreply,
         assign(socket,
           settings_error: dgettext("ui", "Elige un modelo antes de aplicar los ajustes.")
         )}

      provider == "openrouter" and metadata == nil ->
        {:noreply,
         assign(socket,
           settings_error:
             dgettext(
               "ui",
               "Ese modelo no aparece en el catálogo de OpenRouter con herramientas y sin razonamiento obligatorio."
             )
         )}

      true ->
        selection = %{source: :own, provider: provider, model: model_id, metadata: metadata}
        parent = self()

        Task.Supervisor.start_child(ExAgent.TaskSupervisor, fn ->
          result =
            with {:ok, models} <- GameAI.build(selection, user_id),
                 :ok <- AIProviders.probe(models[:model]) do
              {:ok, selection, models}
            end

          send(parent, {:settings_probe, source, model_id, result})
        end)

        {:noreply, assign(socket, settings_checking: true, settings_error: nil)}
    end
  end

  defp apply_source(socket, _unknown), do: {:noreply, socket}

  defp restart(socket, selection, models) do
    game_id = socket.assigns.game_id

    case Dragonex.Game.restart(game_id, models ++ [ai: GameAI.encode(selection)]) do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(
          Dragonex.PubSub,
          "dragonex:game:#{game_id}",
          {:game_updated, game_id}
        )

        {:noreply, assign(socket, show_settings: false)}

      {:error, _} ->
        {:noreply,
         assign(socket,
           settings_error:
             dgettext(
               "ui",
               "No se pudieron aplicar los ajustes. Conservamos la configuración anterior; vuelve a abrir la partida."
             )
         )}
    end
  end

  defp chosen_model(socket) do
    case String.trim(socket.assigns.settings_custom_model || "") do
      "" -> socket.assigns.settings_model
      custom -> custom
    end
  end

  defp probe_error({:error, :missing_key}, _model),
    do: dgettext("ui", "Ya no tienes una clave guardada para este proveedor.")

  defp probe_error({:error, :incompatible}, _model),
    do:
      dgettext(
        "ui",
        "Este modelo no funciona con la mesa (herramientas o razonamiento). Elige otro."
      )

  defp probe_error(error, _model), do: AIProviders.error_message(error)

  # --------------------------------------------------------------- sources

  # House first, then the creator's own keys, then (dev only) the server keys.
  defp sources(user) do
    house = %{key: "house", kind: :house, name: dgettext("ui", "De la casa")}

    own =
      for %{provider: p, hint: hint} <- Accounts.list_api_keys(user), AIProviders.get(p) do
        %{key: "own:" <> p, kind: :own, provider: p, name: AIProviders.name(p), hint: hint}
      end

    server =
      if Models.server_mode() == :open,
        do:
          for(
            %{id: id, name: name, configured: true} <- Models.providers(),
            do: %{key: "server:#{id}", kind: :server, provider: to_string(id), name: name}
          ),
        else: []

    [house | own] ++ server
  end

  # Background listing for sources that offer a model choice; the answer
  # lands in handle_info({:settings_models, ...}).
  defp fetch_models(%{assigns: %{settings_source: "house"}} = socket), do: socket

  defp fetch_models(socket) do
    source = socket.assigns.settings_source
    user_id = socket.assigns.current_user.id
    parent = self()

    Task.Supervisor.start_child(ExAgent.TaskSupervisor, fn ->
      result =
        case source do
          "own:" <> provider ->
            case Accounts.api_key(user_id, provider) do
              {:ok, key} -> AIProviders.list_models(provider, key)
              :error -> {:error, :no_key}
            end

          "server:" <> provider ->
            Models.list_models(String.to_existing_atom(provider))
        end

      send(parent, {:settings_models, source, result})
    end)

    assign(socket, settings_models_status: :loading, settings_error: nil)
  end

  # Server-side ownership guard for privileged actions (the buttons are UI-gated
  # by @is_creator, but a forged phx-click must be rejected here).
  defp creator?(%{assigns: assigns}), do: assigns[:is_creator] == true

  # ------------------------------------------------------------------ modal

  attr(:show, :boolean, default: false)
  attr(:sources, :list, default: [])
  attr(:source, :string, default: "house")
  attr(:models, :list, default: [])
  attr(:models_status, :atom, default: :idle)
  attr(:model, :string, default: nil)
  attr(:custom_model, :string, default: "")
  attr(:error, :string, default: nil)
  attr(:checking, :boolean, default: false)

  def modal(assigns) do
    assigns =
      assign(assigns,
        current: Enum.find(assigns.sources, &(&1.key == assigns.source)),
        own?: Enum.any?(assigns.sources, &(&1.kind == :own)),
        fixed?: Models.server_mode() == :fixed,
        house_model: Models.house_model_id()
      )

    ~H"""
    <div :if={@show} class="modal settings-modal">
      <div class="settings-backdrop" phx-click="close_settings"></div>
      <div class="modal-box settings-box win-open" role="dialog" aria-labelledby="settings-title">
        <h2 id="settings-title"><i class="px px-gear" aria-hidden="true"></i>{dgettext("ui", "Ajustes de IA")}</h2>

        <div class="settings-section">
          <div class="settings-label">{dgettext("ui", "Quién paga la IA")}</div>
          <div class="settings-providers">
            <button
              :for={s <- @sources}
              type="button"
              phx-click="settings_select_source"
              phx-value-source={s.key}
              aria-pressed={to_string(@source == s.key)}
              class={"settings-pbtn #{if @source == s.key, do: "sel", else: ""}"}
            >
              <span class="settings-dot on"></span>
              {source_label(s)}
            </button>
          </div>
        </div>

        <div :if={@current && @current.kind == :house} class="settings-section">
          <div class="settings-msg">
            <%= if @fixed? do %>
              {dgettext("ui", "La mesa usa %{model} con la clave de Dragonex.", model: @house_model)}
            <% else %>
              {dgettext("ui", "La mesa usa el modelo por defecto del servidor.")}
            <% end %>
          </div>
          <p :if={not @own?} class="settings-hint">
            {dgettext("ui", "¿Quieres elegir otro modelo? Añade tu propia clave en")}
            <.link navigate="/cuenta">{dgettext("ui", "Tu cuenta")}</.link>.
          </p>
        </div>

        <div :if={@current && @current.kind != :house} class="settings-section">
          <div class="settings-label">
            {dgettext("ui", "Modelo")}
            <button type="button" phx-click="settings_refresh_models" class="settings-refresh" title={dgettext("ui", "Refrescar modelos")}>↻</button>
          </div>
          <%= cond do %>
            <% @models_status == :loading -> %>
              <div class="settings-msg">{dgettext("ui", "cargando modelos…")}</div>
            <% @models_status == :no_key -> %>
              <div class="settings-msg warn">{dgettext("ui", "sin API key para este provider — escribe el slug abajo")}</div>
            <% @models_status == :error -> %>
              <div class="settings-msg warn">{dgettext("ui", "no se pudieron cargar los modelos — escribe el slug abajo")}</div>
            <% @models_status == :ok -> %>
              <form id="settings-select-model" phx-change="settings_select_model">
                <select name="model" class="settings-select" aria-label={dgettext("ui", "Modelo")}>
                  <option value="" disabled selected={@model == nil}>{dgettext("ui", "(elige modelo)")}</option>
                  {Phoenix.HTML.Form.options_for_select(Enum.map(@models, &{&1.id, &1.id}), @model)}
                </select>
              </form>
            <% true -> %>
          <% end %>
          <form id="settings-custom-model" phx-change="settings_custom_model" phx-submit="settings_custom_model">
            <input
              type="text"
              name="value"
              class="settings-input"
              value={@custom_model}
              placeholder={
                if @current.kind == :own and @current.provider != "openrouter",
                  do: dgettext("ui", "o escribe el id de otro modelo"),
                  else: dgettext("ui", "o escribe un slug (ej: deepseek/deepseek-v4.1-flash)")
              }
              aria-label={dgettext("ui", "Modelo personalizado")}
            />
          </form>
          <p :if={@current.kind == :own} class="settings-hint">
            {dgettext("ui", "Se cobra en tu cuenta de %{provider}. Al aplicar, Dragonex hace una petición mínima para comprobar que el modelo funciona con la mesa.", provider: @current.name)}
          </p>
        </div>

        <p :if={@error} class="settings-msg warn" role="alert">{@error}</p>
        <p :if={@checking} class="settings-msg" role="status">{dgettext("ui", "Comprobando el modelo…")}</p>

        <div class="settings-actions">
          <button class="btn btn-ghost" phx-click="close_settings">{dgettext("ui", "Cancelar")}</button>
          <button class="btn btn-primary" phx-click="settings_apply" disabled={@checking}>{dgettext("ui", "Aplicar")}</button>
        </div>
        <p class="settings-hint">
          {dgettext("ui", "Al aplicar, se conserva el mundo, el turno y la crónica de la partida.")}
        </p>
      </div>
    </div>
    """
  end

  defp source_label(%{kind: :house} = s), do: s.name

  defp source_label(%{kind: :own} = s),
    do: dgettext("ui", "Tu %{provider} (…%{hint})", provider: s.name, hint: s.hint)

  defp source_label(%{kind: :server} = s),
    do: dgettext("ui", "Servidor: %{provider}", provider: s.name)
end
