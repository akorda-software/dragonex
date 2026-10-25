defmodule DragonexWeb.AccountLive do
  @moduledoc """
  Tu cuenta: the player's own AI provider keys (D242).

  A key is checked against its provider (listing models is free) before it is
  saved, sealed, by `Dragonex.Accounts.put_api_key/3`. The plaintext travels
  only from the form to that check and save: it never lands in the socket
  assigns and is never rendered back — only its last characters are.
  """

  use Phoenix.LiveView, layout: {DragonexWeb.Layouts, :app}
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{Accounts, AIProviders}
  alias Dragonex.Accounts.KeyVault

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       keys: keys(socket.assigns.current_user),
       checking: nil,
       checking_ref: nil,
       errors: %{},
       saved: nil
     )}
  end

  @impl true
  def handle_event("save_key", %{"provider" => provider, "key" => key}, socket) do
    if AIProviders.get(provider) && is_nil(socket.assigns.checking) do
      parent = self()
      user_id = socket.assigns.current_user.id
      ref = make_ref()

      Task.Supervisor.start_child(ExAgent.TaskSupervisor, fn ->
        result =
          case String.trim(key) do
            "" ->
              {:error, :blank}

            key ->
              with {:ok, _models} <- AIProviders.list_models(provider, key) do
                {:ok, KeyVault.seal(key, user_id, provider)}
              end
          end

        send(parent, {:key_checked, ref, provider, result})
      end)

      {:noreply,
       assign(socket,
         checking: provider,
         checking_ref: ref,
         saved: nil,
         errors: Map.delete(socket.assigns.errors, provider)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_key", %{"provider" => provider}, socket) do
    # A pending replacement must not re-create a key after the player removes
    # it. The task only checks the provider; this process owns the write.
    socket =
      if socket.assigns.checking == provider,
        do: assign(socket, checking: nil, checking_ref: nil),
        else: socket

    if AIProviders.get(provider) do
      :ok = Accounts.delete_api_key(socket.assigns.current_user, provider)
    end

    {:noreply, assign(socket, keys: keys(socket.assigns.current_user), saved: nil)}
  end

  @impl true
  def handle_info(
        {:key_checked, ref, provider, result},
        %{assigns: %{checking: provider, checking_ref: ref}} = socket
      ) do
    # Carry ciphertext through the mailbox so even a failed callback's "last
    # message" cannot reveal the key. It is opened only for the accepted write,
    # never assigned or rendered. Cancelled checks do not touch storage.
    result =
      case result do
        {:ok, sealed} ->
          with {:ok, key} <- KeyVault.open(sealed, socket.assigns.current_user.id, provider) do
            Accounts.put_api_key(socket.assigns.current_user, provider, key)
          else
            :error -> {:error, :invalid}
          end

        error ->
          error
      end

    socket = assign(socket, checking: nil, checking_ref: nil)

    case result do
      :ok ->
        {:noreply, assign(socket, keys: keys(socket.assigns.current_user), saved: provider)}

      error ->
        {:noreply,
         assign(socket, errors: Map.put(socket.assigns.errors, provider, key_error(error)))}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp keys(user), do: Map.new(Accounts.list_api_keys(user), &{&1.provider, &1})

  defp key_error({:error, :blank}), do: dgettext("ui", "Pega la clave antes de guardarla.")

  defp key_error({:error, :invalid}),
    do: dgettext("ui", "Eso no parece una clave: sin espacios, entre 8 y 512 caracteres.")

  defp key_error(error), do: AIProviders.error_message(error)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, providers: AIProviders.all())

    ~H"""
    <div class="page page-narrow account">
      <.link navigate="/" class="nav-link">{dgettext("ui", "← partidas")}</.link>

      <header class="page-head">
        <div>
          <h1 class="page-title">{dgettext("ui", "Tu cuenta")}</h1>
          <p class="sub">{@current_user.display_name} · {@current_user.email}</p>
        </div>
        <%!-- On phones the header has no room for it: logging out lives here. --%>
        <form action="/logout" method="post" class="account-logout">
          <input type="hidden" name="_method" value="delete" />
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <button type="submit" class="btn btn-sm btn-ghost">{dgettext("ui", "cerrar sesión")}</button>
        </form>
      </header>

      <section class="panel" aria-labelledby="keys-title">
        <h2 id="keys-title">{dgettext("ui", "Claves de IA")}</h2>
        <p class="account-intro">
          {dgettext("ui", "Sin claves, tus mesas usan el modelo de la casa. Con una clave tuya puedes elegir cualquier modelo de ese proveedor en los Ajustes de IA de tus partidas; lo pagas tú, directamente al proveedor.")}
        </p>
        <p class="account-intro">
          {dgettext("ui", "Guardamos las claves cifradas y nunca te las volvemos a mostrar: solo sus últimos caracteres.")}
        </p>

        <div class="key-list">
          <div :for={p <- @providers} id={"key-#{p.id}"} class="key-row">
            <div class="key-head">
              <strong>{p.name}</strong>
              <span :if={@keys[p.id]} class="badge key-saved">{dgettext("ui", "Guardada · …%{hint}", hint: @keys[p.id].hint)}</span>
              <a href={p.keys_url} target="_blank" rel="noopener noreferrer" class="key-get">{dgettext("ui", "Conseguir una clave")}</a>
            </div>

            <form id={"key-form-#{p.id}"} class="key-form" phx-submit="save_key" autocomplete="off">
              <input type="hidden" name="provider" value={p.id} />
              <input
                type="password"
                name="key"
                autocomplete="off"
                spellcheck="false"
                placeholder={if @keys[p.id], do: dgettext("ui", "Pega otra clave para sustituirla"), else: dgettext("ui", "Pega tu clave")}
                aria-label={dgettext("ui", "Clave de %{provider}", provider: p.name)}
                aria-describedby={if @errors[p.id], do: "key-error-#{p.id}"}
                disabled={@checking != nil}
              />
              <button type="submit" class="btn btn-sm btn-primary" disabled={@checking != nil}>
                {if @checking == p.id, do: dgettext("ui", "Comprobando…"), else: dgettext("ui", "Guardar")}
              </button>
              <button
                :if={@keys[p.id]}
                type="button"
                class="btn btn-sm btn-danger"
                phx-click="delete_key"
                phx-value-provider={p.id}
                data-confirm={dgettext("ui", "¿Quitar tu clave de %{provider}? Las mesas que la usan volverán al modelo de la casa.", provider: p.name)}
              >
                {dgettext("ui", "Quitar")}
              </button>
            </form>
            <p :if={@errors[p.id]} id={"key-error-#{p.id}"} class="error" role="alert">{@errors[p.id]}</p>
            <p :if={@saved == p.id} class="key-ok" role="status">{dgettext("ui", "Clave comprobada y guardada.")}</p>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
