defmodule Dragonex.Accounts.Google do
  @moduledoc """
  Sign in with Google (D245): OpenID Connect authorization-code flow with
  PKCE, no extra dependency.

  `authorize/1` builds the consent URL plus the one-time secrets the caller
  keeps in the session (`state`, PKCE `verifier`, `nonce`). `identity/3`
  trades the returned code for Google's ID token and reads who signed in.
  The token comes straight from Google's token endpoint over TLS, so OIDC
  Core §3.1.3.7 lets us trust it without checking its signature; we still
  check audience, issuer, expiry and nonce.

  Configured by `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`; without them
  the sign-in button is hidden. `config :dragonex, :google_http` adds Req
  options (tests stub the token endpoint with `plug:`).
  """

  @auth_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @issuers ["https://accounts.google.com", "accounts.google.com"]

  @type identity :: %{
          sub: String.t(),
          email: String.t(),
          email_verified: boolean(),
          name: String.t() | nil
        }

  @doc "Whether the deployment has a Google OAuth client."
  @spec configured?() :: boolean()
  def configured?, do: client_id() != nil and client_secret() != nil

  @doc """
  The URL that sends the browser to Google, and the secrets to keep in the
  session until the callback.
  """
  @spec authorize(String.t()) :: {String.t(), %{String.t() => String.t()}}
  def authorize(redirect_uri) do
    secrets = %{"state" => random(), "verifier" => random(), "nonce" => random()}

    query =
      URI.encode_query(%{
        "client_id" => client_id(),
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => "openid email profile",
        "state" => secrets["state"],
        "nonce" => secrets["nonce"],
        "code_challenge" => challenge(secrets["verifier"]),
        "code_challenge_method" => "S256",
        "prompt" => "select_account"
      })

    {@auth_url <> "?" <> query, secrets}
  end

  @doc "Trade the callback's code for the identity of who signed in."
  @spec identity(String.t(), %{String.t() => String.t()}, String.t()) ::
          {:ok, identity()} | {:error, atom()}
  def identity(code, %{"verifier" => verifier, "nonce" => nonce}, redirect_uri)
      when is_binary(code) do
    form = [
      code: code,
      client_id: client_id(),
      client_secret: client_secret(),
      redirect_uri: redirect_uri,
      grant_type: "authorization_code",
      code_verifier: verifier
    ]

    options = [form: form, receive_timeout: 10_000, retry: false] ++ http()

    case Req.post(@token_url, options) do
      {:ok, %{status: 200, body: %{"id_token" => token}}} -> claims(token, nonce)
      {:ok, _response} -> {:error, :rejected}
      {:error, _reason} -> {:error, :unreachable}
    end
  end

  def identity(_code, _secrets, _redirect_uri), do: {:error, :rejected}

  defp claims(token, nonce) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{} = c} <- Jason.decode(json),
         true <- c["aud"] == client_id(),
         true <- c["iss"] in @issuers,
         true <- is_integer(c["exp"]) and c["exp"] > System.os_time(:second),
         true <- c["nonce"] == nonce,
         true <- is_binary(c["sub"]) and is_binary(c["email"]) do
      {:ok,
       %{
         sub: c["sub"],
         email: c["email"],
         email_verified: c["email_verified"] in [true, "true"],
         name: c["name"]
       }}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp challenge(verifier),
    do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

  defp random, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp client_id, do: env("GOOGLE_CLIENT_ID")
  defp client_secret, do: env("GOOGLE_CLIENT_SECRET")

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp http, do: Application.get_env(:dragonex, :google_http, [])
end
