defmodule DragonexWeb.UserSessionHTML do
  @moduledoc false
  use DragonexWeb, :html
  use Gettext, backend: Dragonex.Gettext

  def login(assigns) do
    ~H"""
    <.auth_shell current={:login} flash={@flash}>
      <:intro>{dgettext("ui", "Vuelve a la mesa, aventurero.")}</:intro>
      <form action="/login" method="post">
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <label for="login-email">{dgettext("ui", "Email")}</label>
        <input id="login-email" type="email" name="email" value={@email} required autocomplete="email" placeholder={dgettext("ui", "tu correo")} />
        <label for="login-password">{dgettext("ui", "Contraseña")}</label>
        <input id="login-password" type="password" name="password" required autocomplete="current-password" placeholder="••••••••" />
        <button class="btn btn-primary auth-submit" type="submit">{dgettext("ui", "Entrar")}</button>
      </form>
    </.auth_shell>
    """
  end

  def register(assigns) do
    ~H"""
    <.auth_shell current={:register} flash={@flash}>
      <:intro>{dgettext("ui", "Crea tu cuenta de aventurero.")}</:intro>
      <form action="/register" method="post">
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <.field id="reg-name" name="display_name" type="text" label={dgettext("ui", "Nombre de aventurero")}
          value={@values["display_name"]} error={@errors["display_name"]} autocomplete="nickname" placeholder="Gandalf" />
        <.field id="reg-email" name="email" type="email" label={dgettext("ui", "Email")}
          value={@values["email"]} error={@errors["email"]} autocomplete="email" placeholder={dgettext("ui", "tu correo")} />
        <.field id="reg-password" name="password" type="password" label={dgettext("ui", "Contraseña (mínimo 8)")}
          error={@errors["password"]} autocomplete="new-password" placeholder="••••••••" minlength="8" />
        <.field id="reg-password-confirmation" name="password_confirmation" type="password"
          label={dgettext("ui", "Repite la contraseña")} error={@errors["password_confirmation"]}
          autocomplete="new-password" placeholder="••••••••" minlength="8" />
        <button class="btn btn-primary auth-submit" type="submit">{dgettext("ui", "Crear cuenta")}</button>
      </form>
    </.auth_shell>
    """
  end

  # The brand wordmark over a stone window between two torches, with the
  # Entrar / Crear cuenta tabs, the Google button (when configured) and the
  # email form of the current tab.
  attr(:current, :atom, required: true)
  attr(:flash, :map, required: true)
  slot(:intro, required: true)
  slot(:inner_block, required: true)

  defp auth_shell(assigns) do
    ~H"""
    <div class="auth-wrap">
      <img class="auth-mark" src="/assets/wordmark.svg" alt="Dragonex" width="610" height="150" />
      <div class="auth-stage">
        <i class="px px-torch auth-torch" aria-hidden="true"></i>
        <section class="auth-page win-open">
          <nav class="auth-tabs" aria-label={dgettext("ui", "Acceso")}>
            <a href="/login" class={if @current == :login, do: "is-current"} aria-current={if @current == :login, do: "page"}>{dgettext("ui", "Entrar")}</a>
            <a href="/register" class={if @current == :register, do: "is-current"} aria-current={if @current == :register, do: "page"}>{dgettext("ui", "Crear cuenta")}</a>
          </nav>
          <h1 class="sub">{render_slot(@intro)}</h1>

          <p :if={Phoenix.Flash.get(@flash, :error)} class="flash flash-error" role="alert">{Phoenix.Flash.get(@flash, :error)}</p>
          <p :if={Phoenix.Flash.get(@flash, :info)} class="flash flash-info" role="status">{Phoenix.Flash.get(@flash, :info)}</p>

          <%= if Dragonex.Accounts.Google.configured?() do %>
            <a href="/auth/google" class="btn btn-google">
              <svg class="g-logo" viewBox="0 0 48 48" width="20" height="20" aria-hidden="true">
                <path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z" />
                <path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z" />
                <path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z" />
                <path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z" />
              </svg>
              <span>{dgettext("ui", "Continuar con Google")}</span>
            </a>
            <p class="auth-or"><span>{dgettext("ui", "o con tu correo")}</span></p>
          <% end %>

          {render_slot(@inner_block)}
        </section>
        <i class="px px-torch auth-torch" aria-hidden="true"></i>
      </div>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:type, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, default: nil)
  attr(:error, :string, default: nil)
  attr(:rest, :global, include: ~w(autocomplete placeholder minlength))

  defp field(assigns) do
    ~H"""
    <label for={@id}>{@label}</label>
    <input id={@id} type={@type} name={@name} value={@value} required
      aria-invalid={@error && "true"} aria-describedby={@error && "#{@id}-error"} {@rest} />
    <p :if={@error} id={"#{@id}-error"} class="field-error">{@error}</p>
    """
  end
end
