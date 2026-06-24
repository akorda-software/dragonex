defmodule DragonesWeb.UserSessionHTML do
  @moduledoc false
  use DragonesWeb, :html

  def login(assigns) do
    ~H"""
    <div class="auth-page">
      <style>
        .auth-page{max-width:380px;margin:2rem auto;padding:2rem;font-family:Georgia,'Times New Roman',serif;}
        .auth-page h1{font-size:1.6rem;color:#fc8;text-align:center;margin-bottom:.4rem;}
        .auth-page .sub{text-align:center;color:#889;margin-bottom:1.5rem;font-size:.9rem;}
        .auth-page label{display:block;font-size:.8rem;color:#7ab;text-transform:uppercase;letter-spacing:.05em;margin:.6rem 0 .2rem;}
        .auth-page input[type=text],.auth-page input[type=email],.auth-page input[type=password]
          {width:100%;padding:.6rem;background:#1a1a1a;color:#eee;border:1px solid #444;border-radius:4px;font-size:1rem;box-sizing:border-box;font-family:inherit;}
        .auth-page input:focus{border-color:#a72;outline:none;}
        .auth-page .btn{width:100%;padding:.7rem;border-radius:6px;border:1px solid #a72;background:#3a2a1a;color:#fc8;font-size:1.05rem;cursor:pointer;margin-top:1.2rem;font-family:inherit;}
        .auth-page .btn:hover{background:#4a3520;}
        .auth-page .alt{text-align:center;margin-top:1rem;}
        .auth-page .alt a{color:#7ab;text-decoration:none;font-size:.85rem;}
        .auth-page .alt a:hover{text-decoration:underline;}
        .auth-page .flash{text-align:center;padding:.5rem;border-radius:4px;margin-bottom:1rem;font-size:.85rem;}
        .flash-error{background:#3a1a1a;border:1px solid #744;color:#f99;}
        .flash-info{background:#1a2a1a;border:1px solid #474;color:#9f9;}
        .auth-page .ornament{text-align:center;color:#a72;font-size:1.2rem;margin:1rem 0;}
      </style>

      <h1>⚔ Dragones</h1>
      <div class="sub">El DM por IA dirige D&D 5e</div>

      <p :if={Phoenix.Flash.get(@flash, :error)} class="flash flash-error">{Phoenix.Flash.get(@flash, :error)}</p>
      <p :if={Phoenix.Flash.get(@flash, :info)} class="flash flash-info">{Phoenix.Flash.get(@flash, :info)}</p>

      <div class="ornament">⚜ ⚜ ⚜</div>

      <form action="/login" method="post">
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <label>Email</label>
        <input type="email" name="email" required placeholder="heroe@reino.com" />
        <label>Contraseña</label>
        <input type="password" name="password" required placeholder="••••••••" />
        <button class="btn" type="submit">Entrar</button>
      </form>

      <div class="alt">
        ¿Sin cuenta? <a href="/register">Crear una</a>
      </div>
    </div>
    """
  end

  def register(assigns) do
    ~H"""
    <div class="auth-page">
      <style>
        .auth-page{max-width:380px;margin:2rem auto;padding:2rem;font-family:Georgia,'Times New Roman',serif;}
        .auth-page h1{font-size:1.6rem;color:#fc8;text-align:center;margin-bottom:.4rem;}
        .auth-page .sub{text-align:center;color:#889;margin-bottom:1.5rem;font-size:.9rem;}
        .auth-page label{display:block;font-size:.8rem;color:#7ab;text-transform:uppercase;letter-spacing:.05em;margin:.6rem 0 .2rem;}
        .auth-page input[type=text],.auth-page input[type=email],.auth-page input[type=password]
          {width:100%;padding:.6rem;background:#1a1a1a;color:#eee;border:1px solid #444;border-radius:4px;font-size:1rem;box-sizing:border-box;font-family:inherit;}
        .auth-page input:focus{border-color:#a72;outline:none;}
        .auth-page .btn{width:100%;padding:.7rem;border-radius:6px;border:1px solid #a72;background:#3a2a1a;color:#fc8;font-size:1.05rem;cursor:pointer;margin-top:1.2rem;font-family:inherit;}
        .auth-page .btn:hover{background:#4a3520;}
        .auth-page .alt{text-align:center;margin-top:1rem;}
        .auth-page .alt a{color:#7ab;text-decoration:none;font-size:.85rem;}
        .auth-page .alt a:hover{text-decoration:underline;}
        .auth-page .flash{text-align:center;padding:.5rem;border-radius:4px;margin-bottom:1rem;font-size:.85rem;}
        .flash-error{background:#3a1a1a;border:1px solid #744;color:#f99;}
        .flash-info{background:#1a2a1a;border:1px solid #474;color:#9f9;}
        .auth-page .ornament{text-align:center;color:#a72;font-size:1.2rem;margin:1rem 0;}
      </style>

      <h1>⚔ Dragones</h1>
      <div class="sub">Crea tu cuenta de aventurero</div>

      <p :if={Phoenix.Flash.get(@flash, :error)} class="flash flash-error">{Phoenix.Flash.get(@flash, :error)}</p>
      <p :if={Phoenix.Flash.get(@flash, :info)} class="flash flash-info">{Phoenix.Flash.get(@flash, :info)}</p>

      <div class="ornament">⚜ ⚜ ⚜</div>

      <form action="/register" method="post">
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <label>Nombre de aventurero</label>
        <input type="text" name="display_name" required placeholder="Gandalf" />
        <label>Email</label>
        <input type="email" name="email" required placeholder="heroe@reino.com" />
        <label>Contraseña (min 8)</label>
        <input type="password" name="password" required minlength="8" placeholder="••••••••" />
        <button class="btn" type="submit">Registrarse</button>
      </form>

      <div class="alt">
        ¿Ya tienes cuenta? <a href="/login">Entrar</a>
      </div>
    </div>
    """
  end
end
