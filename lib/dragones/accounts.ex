defmodule Dragones.Accounts do
  @moduledoc """
  The accounts context: registration, authentication, and hero persistence.

  Passwords are hashed with bcrypt. Emails are case-insensitive (stored
  lowercased). Heroes are saved as encoded Character sheets (jsonb via Codec).
  """

  import Ecto.Query

  alias Dragones.{Codec, Repo}
  alias Dragones.Accounts.{Hero, User}
  alias Dragones.Games.Character, as: GameCharacter

  # ----------------------------------------------------------------- users

  @doc "Register a new user. Returns {:ok, user} or {:error, changeset}."
  @spec register(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register(attrs) do
    %User{}
    |> user_registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Look up a user by email (case-insensitive), verify password."
  @spec authenticate(String.t(), String.t()) :: {:ok, User.t()} | {:error, :invalid}
  def authenticate(email, password) do
    lower = String.downcase(email)

    case Repo.one(from(u in User, where: u.email == ^lower)) do
      %User{password_hash: hash} = user ->
        if Bcrypt.verify_pass(password, hash),
          do: {:ok, user},
          else: {:error, :invalid}

      nil ->
        # Run a dummy verify to avoid timing attacks that reveal valid emails.
        Bcrypt.no_user_verify()
        {:error, :invalid}
    end
  end

  @doc "Fetch a user by id."
  @spec get_user(term()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  # ----------------------------------------------------------------- heroes

  @doc "List all heroes owned by a user, newest first."
  @spec list_heroes(User.t()) :: [Hero.t()]
  def list_heroes(%User{id: uid}), do: list_heroes(uid)

  @spec list_heroes(term()) :: [Hero.t()]
  def list_heroes(user_id) do
    Repo.all(from(h in Hero, where: h.user_id == ^user_id, order_by: [desc: h.inserted_at]))
  end

  @doc "Fetch a single hero by id."
  @spec get_hero(term()) :: Hero.t() | nil
  def get_hero(id), do: Repo.get(Hero, id)

  @doc "Fetch a hero, ensuring it belongs to the given user."
  @spec get_user_hero(User.t(), term()) :: Hero.t() | nil
  def get_user_hero(%User{id: uid}, id), do: get_user_hero(uid, id)

  @spec get_user_hero(term(), term()) :: Hero.t() | nil
  def get_user_hero(user_id, id) do
    Repo.one(from(h in Hero, where: h.id == ^id and h.user_id == ^user_id))
  end

  @doc """
  Save a built `Dragones.Character` as a hero for the given user.

  The character sheet is encoded through Codec so it round-trips identically
  to game characters — the wizard can import it without any conversion.
  """
  @spec save_hero(User.t(), Dragones.Character.t(), map() | nil) ::
          {:ok, Hero.t()} | {:error, term()}
  def save_hero(%User{id: uid}, %Dragones.Character{} = sheet, draft \\ nil) do
    encoded = Codec.encode_character(sheet)

    %Hero{}
    |> Ecto.Changeset.cast(
      %{
        user_id: uid,
        name: sheet.name,
        race: sheet.race,
        class: sheet.class,
        level: sheet.level,
        sheet: encoded,
        draft: draft
      },
      [:user_id, :name, :race, :class, :level, :sheet, :draft]
    )
    |> Repo.insert()
  end

  @doc "Update a saved hero, only while it has not been imported into any game."
  @spec update_hero(User.t(), term(), Dragones.Character.t(), map() | nil) ::
          {:ok, Hero.t()} | {:error, term()}
  def update_hero(%User{} = user, id, %Dragones.Character{} = sheet, draft \\ nil) do
    case get_user_hero(user, id) do
      nil ->
        {:error, :not_found}

      %Hero{} = hero ->
        if hero_used?(hero) do
          {:error, :in_game}
        else
          encoded = Codec.encode_character(sheet)

          hero
          |> Ecto.Changeset.cast(
            %{
              name: sheet.name,
              race: sheet.race,
              class: sheet.class,
              level: sheet.level,
              sheet: encoded,
              draft: draft
            },
            [:name, :race, :class, :level, :sheet, :draft]
          )
          |> Repo.update()
        end
    end
  end

  @doc "True when a saved hero has already been copied into at least one game."
  @spec hero_used?(Hero.t() | term()) :: boolean()
  def hero_used?(%Hero{id: id}), do: hero_used?(id)

  def hero_used?(id) do
    Repo.exists?(from(c in GameCharacter, where: c.hero_id == ^id))
  end

  @doc "Saved hero ids for this user that already appear in games."
  @spec used_hero_ids(User.t()) :: [integer()]
  def used_hero_ids(%User{id: uid}) do
    Repo.all(
      from(c in GameCharacter,
        join: h in Hero,
        on: c.hero_id == h.id,
        where: h.user_id == ^uid,
        distinct: true,
        select: h.id
      )
    )
  end

  @doc "Delete a hero."
  @spec delete_hero(term()) :: {:ok, Hero.t()} | {:error, :not_found}
  def delete_hero(id) do
    case Repo.get(Hero, id) do
      nil ->
        {:error, :not_found}

      hero ->
        if hero_used?(hero) do
          {:error, :in_game}
        else
          {:ok, Repo.delete!(hero)}
        end
    end
  end

  @doc "Decode a hero's stored sheet back into a `Dragones.Character` struct."
  @spec hero_sheet(Hero.t()) :: Dragones.Character.t()
  def hero_sheet(%Hero{sheet: sheet}), do: Codec.decode_character(sheet)

  # --------------------------------------------------------------- helpers

  defp user_registration_changeset(user, attrs) do
    email =
      (attrs[:email] || attrs["email"] || "") |> to_string() |> String.trim() |> String.downcase()

    user
    |> Ecto.Changeset.cast(
      %{
        email: email,
        display_name: attrs[:display_name] || attrs["display_name"],
        password: attrs[:password] || attrs["password"]
      },
      [:email, :display_name, :password]
    )
    |> Ecto.Changeset.validate_required([:email, :password])
    |> Ecto.Changeset.validate_format(:email, ~r/^[^\s]+@[^\s]+$/,
      message: "debe ser un email válido"
    )
    |> Ecto.Changeset.validate_length(:password, min: 8, max: 72)
    |> Ecto.Changeset.unique_constraint(:email)
    |> put_password_hash()
  end

  defp put_password_hash(changeset) do
    case Ecto.Changeset.get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        changeset
        |> Ecto.Changeset.put_change(:password_hash, Bcrypt.hash_pwd_salt(password))
    end
  end
end
