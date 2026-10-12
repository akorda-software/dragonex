defmodule Dragonex.Accounts.KeyVault do
  @moduledoc """
  Seals players' provider keys at rest with AES-256-GCM (D242).

  The 32-byte key is derived from the endpoint's `secret_key_base`, so no extra
  secret has to be deployed; rotating that base makes stored keys unreadable
  and players enter them again. Each ciphertext is bound to its owner and
  provider through the additional data, so a row copied onto another user or
  provider does not open.
  """

  @version 1
  @aad_prefix "dragonex api key v1"

  @spec seal(String.t(), term(), String.t()) :: binary()
  def seal(plaintext, user_id, provider) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key(),
        iv,
        plaintext,
        aad(user_id, provider),
        true
      )

    <<@version, iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>
  end

  @spec open(binary(), term(), String.t()) :: {:ok, String.t()} | :error
  def open(
        <<@version, iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>,
        user_id,
        provider
      ) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key(),
           iv,
           ciphertext,
           aad(user_id, provider),
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end

  def open(_sealed, _user_id, _provider), do: :error

  defp aad(user_id, provider), do: "#{@aad_prefix}|#{user_id}|#{provider}"

  defp key do
    base = Application.fetch_env!(:dragonex, DragonexWeb.Endpoint)[:secret_key_base]

    case :persistent_term.get({__MODULE__, base}, nil) do
      nil ->
        key = Plug.Crypto.KeyGenerator.generate(base, @aad_prefix, length: 32)
        :persistent_term.put({__MODULE__, base}, key)
        key

      key ->
        key
    end
  end
end
