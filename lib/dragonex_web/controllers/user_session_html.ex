defmodule DragonexWeb.UserSessionHTML do
  @moduledoc false
  use DragonexWeb, :html
  use Gettext, backend: Dragonex.Gettext

  def login(assigns) do
    ~H"""
    <div class="auth-wrap">
      <div class="auth-page win-open">
        <div class="auth-head">
          <i class="px px-torch" aria-hidden="true"></i>
          <h1>Dragonex</h1>
          <i class="px px-torch" aria-hidden="true"></i>
        </div>
        <div class="sub">{dgettext("ui", "Vuelve a la mesa, aventurero.")}</div>

        <p :if={Phoenix.Flash.get(@flash, :error)} class="flash flash-error">{Phoenix.Flash.get(@flash, :error)}</p>
        <p :if={Phoenix.Flash.get(@flash, :info)} class="flash flash-info">{Phoenix.Flash.get(@flash, :info)}</p>

        <form action="/login" method="post">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <label for="login-email">{dgettext("ui", "Email")}</label>
          <input id="login-email" type="email" name="email" required autocomplete="email" placeholder={dgettext("ui", "tu correo")} />
          <label for="login-password">{dgettext("ui", "Contraseña")}</label>
          <input id="login-password" type="password" name="password" required autocomplete="current-password" placeholder="••••••••" />
          <button class="btn btn-primary" type="submit">{dgettext("ui", "Entrar")}</button>
        </form>

        <div class="alt">
          {dgettext("ui", "¿Sin cuenta?")} <a href="/register">{dgettext("ui", "Crea una")}</a>
        </div>
      </div>
    </div>
    """
  end

  def register(assigns) do
    ~H"""
    <div class="auth-wrap">
      <div class="auth-page win-open">
        <div class="auth-head">
          <i class="px px-torch" aria-hidden="true"></i>
          <h1>Dragonex</h1>
          <i class="px px-torch" aria-hidden="true"></i>
        </div>
        <div class="sub">{dgettext("ui", "Crea tu cuenta de aventurero.")}</div>

        <p :if={Phoenix.Flash.get(@flash, :error)} class="flash flash-error">{Phoenix.Flash.get(@flash, :error)}</p>
        <p :if={Phoenix.Flash.get(@flash, :info)} class="flash flash-info">{Phoenix.Flash.get(@flash, :info)}</p>

        <form action="/register" method="post">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <label for="reg-name">{dgettext("ui", "Nombre de aventurero")}</label>
          <input id="reg-name" type="text" name="display_name" required autocomplete="nickname" placeholder="Gandalf" />
          <label for="reg-email">{dgettext("ui", "Email")}</label>
          <input id="reg-email" type="email" name="email" required autocomplete="email" placeholder={dgettext("ui", "tu correo")} />
          <label for="reg-password">{dgettext("ui", "Contraseña (mínimo 8)")}</label>
          <input id="reg-password" type="password" name="password" required minlength="8" autocomplete="new-password" placeholder="••••••••" />
          <button class="btn btn-primary" type="submit">{dgettext("ui", "Crear cuenta")}</button>
        </form>

        <div class="alt">
          {dgettext("ui", "¿Ya tienes cuenta?")} <a href="/login">{dgettext("ui", "Entra")}</a>
        </div>
      </div>
    </div>
    """
  end
end
