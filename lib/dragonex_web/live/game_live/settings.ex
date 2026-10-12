defmodule DragonexWeb.GameLive.Settings do
  @moduledoc """
  The Ajustes de IA modal — provider / model selection for the running
  partida, plus its LiveView event & info handlers. Reasoning is always off
  (exAgent 2.x profiles are only built with reasoning disabled).

  Extracted from `DragonexWeb.GameLive.Show`. The selection is written to
  `Dragonex.ModelConfig` and applied by restarting the Game process, which
  rehydrates from Postgres with the new model wired into the DM agent.
  Creator-only (verified server-side on every privileged event).
  """

  use Phoenix.Component
  use Gettext, backend: Dragonex.Gettext

  def handle_event("open_settings", _params, socket) do
    # Privileged: the Ajustes modal swaps the (app-global) DM model and can
    # restart the partida. Creator-only, verified server-side.
    if not creator?(socket) do
      {:noreply, socket}
    else
      provider = Dragonex.Models.provider()
      model = Dragonex.Models.model()

      socket =
        socket
        |> assign(
          show_settings: true,
          settings_providers: Dragonex.Models.providers(),
          settings_provider: provider,
          settings_model: model,
          settings_custom_model: "",
          settings_models: [],
          settings_models_status: :loading
        )
        |> fetch_models()

      {:noreply, socket}
    end
  end

  def handle_event("close_settings", _params, socket),
    do: {:noreply, assign(socket, show_settings: false)}

  def handle_event("settings_select_provider", %{"provider" => pid}, socket) do
    provider =
      case pid do
        "openrouter" -> :openrouter
        "opencode" -> :opencode
        _ -> nil
      end

    socket =
      socket
      |> assign(
        settings_provider: provider,
        settings_models: [],
        settings_model: nil,
        settings_custom_model: "",
        settings_models_status: :loading
      )
      |> fetch_models()

    {:noreply, socket}
  end

  def handle_event("settings_select_model", %{"model" => model}, socket),
    do: {:noreply, assign(socket, settings_model: model, settings_custom_model: "")}

  def handle_event("settings_custom_model", %{"value" => value}, socket),
    do: {:noreply, assign(socket, settings_custom_model: value || "")}

  def handle_event("settings_refresh_models", _params, socket) do
    {:noreply, socket |> assign(settings_models_status: :loading) |> fetch_models()}
  end

  # Apply: persist the override, restart the partida with the new model, close.
  def handle_event("settings_apply", _params, socket) do
    if not creator?(socket) do
      {:noreply, socket}
    else
      provider = socket.assigns.settings_provider

      # Custom slug wins over the dropdown when filled.
      model =
        case String.trim(socket.assigns.settings_custom_model || "") do
          "" -> socket.assigns.settings_model
          custom -> custom
        end

      # Only reasoning-off profiles exist (Models.chat_model/5), so the saved
      # selection always disables it.
      reasoning = :none

      case Dragonex.Models.prepare_selection(provider, model, reasoning) do
        {:error, message} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, message)}

        {:ok, models} ->
          previous = Dragonex.ModelConfig.get()
          :ok = Dragonex.ModelConfig.set(provider: provider, model: model, reasoning: reasoning)

          result =
            if socket.assigns.game_id,
              do: Dragonex.Game.restart(socket.assigns.game_id, models),
              else: {:ok, nil}

          case result do
            {:ok, _} ->
              Phoenix.PubSub.broadcast(
                Dragonex.PubSub,
                "dragonex:game:#{socket.assigns.game_id}",
                {:game_updated, socket.assigns.game_id}
              )

              {:noreply, assign(socket, show_settings: false)}

            {:error, _} ->
              :ok = Dragonex.ModelConfig.set(Map.from_struct(previous) |> Map.to_list())

              {:noreply,
               Phoenix.LiveView.put_flash(
                 socket,
                 :error,
                 dgettext(
                   "ui",
                   "No se pudieron aplicar los ajustes. Conservamos la configuración anterior; vuelve a abrir la partida."
                 )
               )}
          end
      end
    end
  end

  # Live model catalogue for the Ajustes modal: a background task fetched the
  # provider's /models endpoint. Reconcile the in-modal selection with the list
  # (if the current model isn't offered, move it to the custom field so the
  # dropdown stays valid).
  def handle_info({:settings_models, provider, result}, socket) do
    if socket.assigns.show_settings and socket.assigns.settings_provider == provider do
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

        {:error, _} ->
          {:noreply, assign(socket, settings_models: [], settings_models_status: :error)}
      end
    else
      {:noreply, socket}
    end
  end

  # ------------------------------------------------------------ model helpers

  # Kick off a background fetch of the provider's live model list. The result
  # lands in handle_info({:settings_models, ...}). Uses ExAgent's TaskSupervisor
  # (already in the tree); start_child is fire-and-forget (no ref message).
  defp fetch_models(socket) do
    provider = socket.assigns.settings_provider

    if provider do
      parent = self()

      Task.Supervisor.start_child(ExAgent.TaskSupervisor, fn ->
        send(parent, {:settings_models, provider, Dragonex.Models.list_models(provider)})
      end)
    end

    socket
  end

  # The gear button's live label: provider/model + (reasoning) for the currently
  # effective config (override → env). Reflects what the running Game uses.
  def ai_button_label do
    provider = Dragonex.Models.provider()
    model = Dragonex.Models.model()
    effort = Dragonex.Models.reasoning() |> reasoning_short()
    "#{provider}/#{model} (#{effort})"
  end

  defp reasoning_short(:none), do: "off"
  defp reasoning_short(effort) when is_binary(effort), do: effort

  # Server-side ownership guard for privileged actions (the buttons are UI-gated
  # by @is_creator, but a forged phx-click must be rejected here).
  defp creator?(%{assigns: assigns}), do: assigns[:is_creator] == true

  # ------------------------------------------------------------------ modal

  # The Ajustes de IA modal: provider switch, live model list (with free-text
  # fallback) and the fixed reasoning-off notice. Creator-only; writing the
  # selection restarts the partida so the new model takes effect.
  attr(:show, :boolean, default: false)
  attr(:providers, :list, default: [])
  attr(:provider, :atom, default: nil)
  attr(:models, :list, default: [])
  attr(:models_status, :atom, default: :idle)
  attr(:model, :string, default: nil)
  attr(:custom_model, :string, default: "")

  def modal(assigns) do
    ~H"""
    <div :if={@show} class="modal settings-modal">
      <div class="settings-backdrop" phx-click="close_settings"></div>
      <div class="modal-box settings-box win-open">
        <h2><i class="px px-gear" aria-hidden="true"></i>{dgettext("ui", "Ajustes de IA")}</h2>

        <div class="settings-section">
          <div class="settings-label">{dgettext("ui", "Provider")}</div>
          <div class="settings-providers">
            <button
              :for={p <- @providers}
              type="button"
              phx-click="settings_select_provider"
              phx-value-provider={p.id}
              disabled={not p.configured}
              class={"settings-pbtn #{if @provider == p.id, do: "sel", else: ""}#{if not p.configured, do: " disabled", else: ""}"}
            >
              <span class={"settings-dot #{if p.configured, do: "on", else: "off"}"}></span>
              {p.name}
            </button>
          </div>
        </div>

        <div class="settings-section">
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
            <% true -> %>
              <form id="settings-select-model" phx-change="settings_select_model">
                <select name="model" class="settings-select">
                  <option value="" disabled={@model == nil}>{dgettext("ui", "(elige modelo)")}</option>
                  {Phoenix.HTML.Form.options_for_select(Enum.map(@models, &{&1.id, &1.id}), @model)}
                </select>
              </form>
          <% end %>
          <form id="settings-custom-model" phx-change="settings_custom_model" phx-submit="settings_custom_model">
            <input
              type="text"
              name="value"
              class="settings-input"
              value={@custom_model}
              placeholder={dgettext("ui", "o escribe un slug (ej: deepseek/deepseek-v4.1-flash)")}
              aria-label={dgettext("ui", "Modelo personalizado")}
            />
          </form>
        </div>

        <div class="settings-section">
          <div class="settings-label">{dgettext("ui", "Thinking (cuánto razona)")}</div>
          <div class="settings-msg">{dgettext("ui", "Esta mesa usa el razonamiento desactivado.")}</div>
        </div>

        <div class="settings-actions">
          <button class="btn btn-ghost" phx-click="close_settings">{dgettext("ui", "Cancelar")}</button>
          <button class="btn btn-primary" phx-click="settings_apply">{dgettext("ui", "Aplicar")}</button>
        </div>
        <p class="settings-hint">
          {dgettext("ui", "Al aplicar, se conserva el mundo, el turno y la crónica de la partida.")}
        </p>
      </div>
    </div>
    """
  end
end
