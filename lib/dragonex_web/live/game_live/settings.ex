defmodule DragonexWeb.GameLive.Settings do
  @moduledoc """
  The Ajustes de IA modal — provider / model / reasoning-effort selection for
  the running partida, plus its LiveView event & info handlers.

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
      reasoning = Dragonex.Models.reasoning()

      socket =
        socket
        |> assign(
          show_settings: true,
          settings_providers: Dragonex.Models.providers(),
          settings_provider: provider,
          settings_model: model,
          settings_custom_model: "",
          settings_reasoning: reasoning,
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
        settings_reasoning: :none,
        settings_models_status: :loading
      )
      |> fetch_models()

    {:noreply, socket}
  end

  def handle_event("settings_select_model", %{"model" => model}, socket) do
    reasoning =
      default_reasoning_for(
        socket.assigns.settings_provider,
        socket.assigns.settings_models,
        model
      )

    {:noreply,
     assign(socket,
       settings_model: model,
       settings_custom_model: "",
       settings_reasoning: reasoning
     )}
  end

  def handle_event("settings_custom_model", %{"value" => value}, socket),
    do: {:noreply, assign(socket, settings_custom_model: value || "")}

  def handle_event("settings_set_reasoning", %{"level" => level}, socket) do
    reasoning = if level == "none", do: :none, else: level
    {:noreply, assign(socket, settings_reasoning: reasoning)}
  end

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

      # Clamp the reasoning to a value the chosen model actually accepts (so we
      # never send e.g. "xhigh" to a model that only supports low/medium/high, or
      # :none to a mandatory-reasoning model).
      reasoning =
        clamp_reasoning(
          provider,
          socket.assigns.settings_models,
          model,
          socket.assigns.settings_reasoning
        )

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
  # dropdown stays valid) and clamp the reasoning to a value the model accepts.
  def handle_info({:settings_models, provider, result}, socket) do
    if socket.assigns.show_settings and socket.assigns.settings_provider == provider do
      case result do
        {:ok, models} ->
          current = socket.assigns.settings_model

          {model, custom} =
            if current != nil and Enum.any?(models, &(&1.id == current)),
              do: {current, ""},
              else: {nil, current || ""}

          reasoning =
            clamp_reasoning(provider, models, model, socket.assigns.settings_reasoning)

          {:noreply,
           assign(socket,
             settings_models: models,
             settings_model: model,
             settings_custom_model: custom,
             settings_reasoning: reasoning,
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

  # Find the model_info map for `model_id` in the fetched list (nil if absent,
  # e.g. a custom slug typed in the free-text field).
  defp find_model_info(_models, nil), do: nil

  defp find_model_info(models, model_id),
    do: Enum.find(models, &(&1.id == model_id))

  # --- thinking selector helpers -------------------------------------------
  #
  # The reasoning effort is dynamic per model: OpenRouter exposes each model's
  # supported efforts (+ a default and a mandatory flag); OpenCode carries no
  # metadata, so it falls back to a generic low/medium/high set.

  # Resolve what the thinking section should render for the selected model:
  #   * {:unsupported}                 — model explicitly has no reasoning
  #   * {:unknown}                      — reasoning metadata not curated yet
  #   * {:options, efforts, mandatory}  — render these effort buttons (+ Off unless mandatory)
  def thinking_state(_provider, models, model_id, custom) do
    if Dragonex.Models.backend() == :req_llm do
      {:fixed_off}
    else
      legacy_thinking_state(models, model_id, custom)
    end
  end

  defp legacy_thinking_state(models, model_id, custom) do
    if custom != "" do
      # Custom slug → no metadata, offer the generic set.
      {:options, sort_efforts(Dragonex.Models.generic_efforts()), false}
    else
      case find_model_info(models, model_id) do
        %{reasoning?: false} ->
          {:unsupported}

        %{reasoning?: nil} ->
          {:unknown}

        %{efforts: efforts, mandatory: mandatory} ->
          {:options, sort_efforts(efforts || Dragonex.Models.generic_efforts()), mandatory}

        _ ->
          {:unknown}
      end
    end
  end

  defp sort_efforts(efforts) do
    order = Dragonex.Models.effort_order()

    Enum.sort_by(efforts, fn e ->
      case Enum.find_index(order, &(&1 == e)) do
        nil -> 99
        idx -> idx
      end
    end)
  end

  defp effort_label("none"), do: dgettext("ui", "Off")
  defp effort_label("minimal"), do: dgettext("ui", "Mín")
  defp effort_label("low"), do: dgettext("ui", "Bajo")
  defp effort_label("medium"), do: dgettext("ui", "Medio")
  defp effort_label("high"), do: dgettext("ui", "Alto")
  defp effort_label("xhigh"), do: dgettext("ui", "Muy alto")
  defp effort_label("max"), do: dgettext("ui", "Máx")
  defp effort_label(other), do: String.capitalize(other)

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

  # Default reasoning when a model is first selected: the model's own default
  # effort, or :none (forced to a level when reasoning is mandatory).
  defp default_reasoning_for(_provider, models, model_id) do
    if Dragonex.Models.backend() == :req_llm do
      :none
    else
      case find_model_info(models, model_id) do
        %{reasoning?: false} -> :none
        %{default_effort: effort} when is_binary(effort) -> effort
        %{mandatory: true} -> "medium"
        _ -> :none
      end
    end
  end

  # Clamp a reasoning choice to a value the model actually accepts, so we never
  # send an invalid effort. `:none` is kept unless the model mandates reasoning.
  defp clamp_reasoning(provider, models, model_id, current) do
    if Dragonex.Models.backend() == :req_llm,
      do: :none,
      else: legacy_clamp_reasoning(provider, models, model_id, current)
  end

  defp legacy_clamp_reasoning(:openrouter, models, model_id, current) do
    case find_model_info(models, model_id) do
      nil ->
        current

      %{reasoning?: false} ->
        :none

      %{efforts: efforts, mandatory: mandatory, default_effort: default} ->
        cond do
          current == :none and mandatory -> default || "medium"
          is_binary(current) and (is_nil(efforts) or current in efforts) -> current
          true -> default || if mandatory, do: "medium", else: :none
        end
    end
  end

  # OpenCode has no per-model metadata → keep any generic low/medium/high, else :none.
  defp legacy_clamp_reasoning(:opencode, _models, _model_id, current) do
    case current do
      effort when effort in ["low", "medium", "high"] -> effort
      _ -> :none
    end
  end

  defp legacy_clamp_reasoning(_, _, _, _), do: :none

  # Server-side ownership guard for privileged actions (the buttons are UI-gated
  # by @is_creator, but a forged phx-click must be rejected here).
  defp creator?(%{assigns: assigns}), do: assigns[:is_creator] == true

  # ------------------------------------------------------------------ modal

  # The Ajustes de IA modal: provider switch, live model list (with free-text
  # fallback) and reasoning-effort selector. Creator-only; writing the selection
  # restarts the partida so the new model takes effect.
  attr(:show, :boolean, default: false)
  attr(:providers, :list, default: [])
  attr(:provider, :atom, default: nil)
  attr(:models, :list, default: [])
  attr(:models_status, :atom, default: :idle)
  attr(:model, :string, default: nil)
  attr(:custom_model, :string, default: "")
  attr(:reasoning, :any, default: :none)

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
          <%= case thinking_state(@provider, @models, @model, @custom_model) do %>
            <% {:fixed_off} -> %>
              <div class="settings-msg">{dgettext("ui", "Esta mesa usa el razonamiento desactivado.")}</div>
            <% {:unsupported} -> %>
              <div class="settings-msg warn">{dgettext("ui", "este modelo no soporta thinking")}</div>
            <% {:unknown} -> %>
              <div class="settings-msg warn">{dgettext("ui", "nivel de thinking sin confirmar para este modelo")}</div>
            <% {:options, efforts, mandatory} -> %>
              <div class="settings-reasoning">
                <button
                  :if={not mandatory}
                  type="button"
                  phx-click="settings_set_reasoning"
                  phx-value-level="none"
                  class={"settings-rbtn #{if @reasoning == :none, do: "sel", else: ""}"}
                >
                  {dgettext("ui", "Off")}
                </button>
                <button
                  :for={eff <- efforts}
                  type="button"
                  phx-click="settings_set_reasoning"
                  phx-value-level={eff}
                  class={"settings-rbtn #{if @reasoning == eff, do: "sel", else: ""}"}
                >
                  {effort_label(eff)}
                </button>
              </div>
          <% end %>
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
