defmodule Dragonex.Accounts.ApiKeysTest do
  @moduledoc """
  Players' own AI keys (D242): sealed at rest, bound to their owner and
  provider, and only ever shown back as their last characters.
  """

  use ExUnit.Case, async: true

  alias Dragonex.Accounts
  alias Dragonex.Accounts.{ApiKey, KeyVault}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dragonex.Repo)

    {:ok, user} =
      Accounts.register(%{
        email: "keys-#{Ecto.UUID.generate()}@dragonex.test",
        password: "password123",
        display_name: "Llaves"
      })

    %{user: user}
  end

  describe "KeyVault" do
    test "opens what it sealed for the same user and provider" do
      sealed = KeyVault.seal("sk-secret-value", 7, "openai")
      assert KeyVault.open(sealed, 7, "openai") == {:ok, "sk-secret-value"}
    end

    test "another user, provider or a tampered box cannot open it" do
      sealed = KeyVault.seal("sk-secret-value", 7, "openai")
      assert KeyVault.open(sealed, 8, "openai") == :error
      assert KeyVault.open(sealed, 7, "anthropic") == :error

      n = byte_size(sealed) - 1
      <<head::binary-size(^n), last>> = sealed
      assert KeyVault.open(head <> <<Bitwise.bxor(last, 1)>>, 7, "openai") == :error
      assert KeyVault.open("garbage", 7, "openai") == :error
    end

    test "the same key never seals to the same bytes and never in clear" do
      a = KeyVault.seal("sk-secret-value", 7, "openai")
      b = KeyVault.seal("sk-secret-value", 7, "openai")
      assert a != b
      refute a =~ "sk-secret-value"
    end
  end

  describe "api keys" do
    test "save, list by hint, read back for the engine and replace", %{user: user} do
      assert Accounts.list_api_keys(user) == []
      assert :ok = Accounts.put_api_key(user, "openai", "  sk-first-key-0001 ")

      assert [%{provider: "openai", hint: "0001"}] = Accounts.list_api_keys(user)
      assert Accounts.api_key(user.id, "openai") == {:ok, "sk-first-key-0001"}

      assert :ok = Accounts.put_api_key(user, "openai", "sk-second-key-0002")
      assert [%{hint: "0002"}] = Accounts.list_api_keys(user)
      assert Accounts.api_key(user.id, "openai") == {:ok, "sk-second-key-0002"}

      [row] = Dragonex.Repo.all(ApiKey)
      refute row.ciphertext =~ "sk-second-key-0002"
      refute inspect(row) =~ "ciphertext"
    end

    test "several providers per player, removed one by one", %{user: user} do
      :ok = Accounts.put_api_key(user, "openai", "sk-openai-key-1111")
      :ok = Accounts.put_api_key(user, "anthropic", "sk-ant-key-2222")

      assert Enum.map(Accounts.list_api_keys(user), & &1.provider) |> Enum.sort() ==
               ["anthropic", "openai"]

      :ok = Accounts.delete_api_key(user, "openai")
      assert Accounts.api_key(user.id, "openai") == :error
      assert {:ok, _} = Accounts.api_key(user.id, "anthropic")
    end

    test "rejects text that cannot be a key", %{user: user} do
      assert Accounts.put_api_key(user, "openai", "short") == {:error, :invalid}
      assert Accounts.put_api_key(user, "openai", "has a space inside") == {:error, :invalid}
      assert Accounts.list_api_keys(user) == []
    end

    test "another player's key is not readable", %{user: user} do
      :ok = Accounts.put_api_key(user, "openai", "sk-mine-only-3333")
      assert Accounts.api_key(user.id + 1, "openai") == :error
      assert Accounts.api_key(nil, "openai") == :error
    end
  end
end
