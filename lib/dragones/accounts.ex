defmodule Dragones.Accounts do
  @moduledoc """
  The accounts context: registration, authentication, and hero persistence.

  Passwords are hashed with bcrypt. Emails are case-insensitive (stored
  lowercased). Heroes are saved as encoded Character sheets (jsonb via Codec).
  """

  import Ecto.Query

  alias Dragones.{Codec, Repo}
  alias Dragones.Accounts.{CustomContent, Hero, User}
  alias Dragones.Games.Character, as: GameCharacter

  # Campos válidos para validar las mecánicas de `definition` por kind.
  # Fuente única: `Dragones.Accounts.CustomContent` (compartida con la UI).
  @abilities CustomContent.abilities()
  @spell_kinds CustomContent.spell_kinds()
  @item_kinds CustomContent.item_kinds()

  # El mismo patrón que usa el motor (Dragones.Dice.roll_expr/1): NdM[±K].
  @dice_pattern ~r/^(\d+)d(\d+)(?:([+-])(\d+))?$/

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

  @doc """
  Suma XP al héroe (sin subir de nivel automáticamente). El nivel real del
  personaje se mantiene hasta que el jugador confirme la subida en la pantalla
  de level-up; mientras tanto, la ficha marca "puede subir" si alcanza el umbral.
  """
  @spec grant_xp(User.t(), term(), integer()) ::
          {:ok, Hero.t()} | {:error, :not_found}
  def grant_xp(%User{} = user, id, amount) when is_integer(amount) do
    case get_user_hero(user, id) do
      nil ->
        {:error, :not_found}

      %Hero{} = hero ->
        sheet = hero_sheet(hero)
        updated = %{sheet | xp: (sheet.xp || 0) + max(amount, 0)}

        hero
        |> Ecto.Changeset.cast(%{sheet: Codec.encode_character(updated)}, [:sheet])
        |> Repo.update()
    end
  end

  @doc """
  Aplica una subida de nivel al héroe de la biblioteca (fuente de verdad).

  A diferencia de `update_hero/4`, **no se bloquea** si el héroe está en partida:
  el level-up vive aquí, y la partida se sincroniza desde el héroe. `choices`
  lleva las elecciones (`spells_added`, `asi`, `custom`); ver
  `Dragones.Heroes.apply_level_up/2`.
  """
  @spec level_up_hero(User.t(), term(), map()) ::
          {:ok, Hero.t()} | {:error, :not_found | String.t()}
  def level_up_hero(%User{} = user, id, choices \\ %{}) do
    case get_user_hero(user, id) do
      nil ->
        {:error, :not_found}

      %Hero{} = hero ->
        with {:ok, new_sheet} <-
               Dragones.Heroes.apply_level_up(hero_sheet(hero), normalize_choices(choices)) do
          hero
          |> Ecto.Changeset.cast(
            %{level: new_sheet.level, sheet: Codec.encode_character(new_sheet)},
            [:level, :sheet]
          )
          |> Repo.update()
        end
    end
  end

  defp normalize_choices(choices) when is_map(choices), do: choices
  defp normalize_choices(_), do: %{}

  # ------------------------------------------------------- custom content

  @doc "Lista el contenido custom de un usuario, opcionalmente filtrado por kind."
  @spec list_custom_content(User.t() | term(), String.t() | nil) :: [CustomContent.t()]
  def list_custom_content(user, kind \\ nil)

  def list_custom_content(%User{id: uid}, kind), do: list_custom_content(uid, kind)

  def list_custom_content(user_id, kind) do
    q =
      from(c in CustomContent,
        where: c.user_id == ^user_id,
        order_by: [asc: c.kind, asc: c.name_es]
      )

    if kind do
      Repo.all(where(q, [c], c.kind == ^kind))
    else
      Repo.all(q)
    end
  end

  @doc "Carga una fila de contenido custom por (kind, key) del usuario."
  @spec custom_content_by_keys(User.t() | term(), String.t(), String.t()) ::
          CustomContent.t() | nil
  def custom_content_by_keys(%User{id: uid}, kind, key),
    do: custom_content_by_keys(uid, kind, key)

  def custom_content_by_keys(user_id, kind, key) do
    Repo.one(
      from(c in CustomContent,
        where: c.user_id == ^user_id and c.kind == ^kind and c.key == ^key
      )
    )
  end

  @doc "Fetch una fila de contenido custom, asegurando que pertenece al usuario."
  @spec get_custom_content(User.t() | term(), term()) :: CustomContent.t() | nil
  def get_custom_content(%User{id: uid}, id), do: get_custom_content(uid, id)

  def get_custom_content(user_id, id) do
    Repo.one(from(c in CustomContent, where: c.id == ^id and c.user_id == ^user_id))
  end

  @doc """
  Convierte las filas de contenido custom en un **bundle neutro** listo para
  inyectar en el builder (`Heroes.build`) y en el `Catalog`, sin acoplar esos
  módulos al schema `CustomContent`.

      %{weapons: [%{key, name, definition}], spells: [...], items: [...]}

  Cada `key` va prefijada con `custom_` para no colisionar con las keys SRD, y
  `name` es el label legible (name_es) que el builder embebe en el `Character`.
  """
  @spec custom_bundle(User.t() | [CustomContent.t()]) :: map()
  def custom_bundle(%User{} = user), do: user |> list_custom_content() |> custom_bundle()

  def custom_bundle(rows) when is_list(rows) do
    empty = %{weapons: [], spells: [], items: []}

    Enum.reduce(rows, empty, fn cc, acc ->
      entry = %{key: "custom_#{cc.key}", name: cc.name_es, definition: cc.definition}

      case cc.kind do
        "weapon" -> %{acc | weapons: acc.weapons ++ [entry]}
        "spell" -> %{acc | spells: acc.spells ++ [entry]}
        "item" -> %{acc | items: acc.items ++ [entry]}
        _ -> acc
      end
    end)
  end

  @doc """
  Crea contenido custom validando sus mecánicas según el `kind` (dados
  parseables, `kind` de hechizo válido, etc.) antes de insertar.
  """
  @spec create_custom_content(User.t(), map()) ::
          {:ok, CustomContent.t()} | {:error, term()}
  def create_custom_content(%User{id: uid}, attrs) do
    kind = to_string(attrs[:kind] || attrs["kind"] || "")
    name = clean(attrs[:name_es] || attrs["name_es"])
    definition = attrs[:definition] || attrs["definition"]
    notes = clean(attrs[:notes] || attrs["notes"])
    key = key_for(attrs[:key] || attrs["key"], name)

    with :ok <- require_present(%{kind: kind, name: name, definition: definition}),
         :ok <- validate_kind(kind),
         {:ok, definition} <- validate_definition(kind, definition),
         :ok <- validate_key(kind, key) do
      %CustomContent{}
      |> CustomContent.changeset(%{
        user_id: uid,
        kind: kind,
        key: key,
        name_es: name,
        definition: definition,
        notes: notes
      })
      |> Repo.insert()
      |> normalize_conflict()
    end
  end

  @doc "Actualiza una fila existente, revalidando las mecánicas."
  @spec update_custom_content(User.t(), term(), map()) ::
          {:ok, CustomContent.t()} | {:error, term()}
  def update_custom_content(%User{} = user, id, attrs) do
    with %CustomContent{} = cc <- get_custom_content(user, id) do
      name = clean(attrs[:name_es] || attrs["name_es"]) || cc.name_es
      notes_raw = attrs[:notes] || attrs["notes"]
      notes = if is_nil(notes_raw), do: cc.notes, else: clean(notes_raw)
      definition = attrs[:definition] || attrs["definition"] || cc.definition
      kind = cc.kind
      # Si cambia el nombre y no llega key explícita, regenera el slug.
      key = key_for(attrs[:key] || attrs["key"], name)

      with {:ok, definition} <- validate_definition(kind, definition),
           :ok <- validate_key(kind, key) do
        cc
        |> CustomContent.changeset(%{
          key: key,
          name_es: name,
          definition: definition,
          notes: notes
        })
        |> Repo.update()
        |> normalize_conflict()
      end
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Borra una fila de contenido custom del usuario."
  @spec delete_custom_content(User.t(), term()) ::
          {:ok, CustomContent.t()} | {:error, :not_found}
  def delete_custom_content(%User{} = user, id) do
    with %CustomContent{} = cc <- get_custom_content(user, id) do
      Repo.delete(cc)
    else
      nil -> {:error, :not_found}
    end
  end

  # ----------------------------------------------------- custom validation

  defp clean(nil), do: nil
  defp clean(v) when is_binary(v), do: String.trim(v)

  defp require_present(%{kind: k}) when k in ["", nil], do: {:error, "kind es obligatorio"}
  defp require_present(%{name: n}) when n in ["", nil], do: {:error, "name_es es obligatorio"}

  defp require_present(%{definition: d}) when d in [nil, %{}],
    do: {:error, "definition es obligatorio"}

  defp require_present(_), do: :ok

  defp validate_kind(kind) do
    if kind in CustomContent.kinds(),
      do: :ok,
      else: {:error, "kind inválido (debe ser weapon, spell o item)"}
  end

  defp key_for(nil, name) when is_binary(name) and name != "", do: CustomContent.slugify(name)
  defp key_for("", name) when is_binary(name) and name != "", do: CustomContent.slugify(name)
  defp key_for(key, _name) when is_binary(key), do: CustomContent.slugify(key)

  defp validate_key(_kind, key) when is_binary(key) and byte_size(key) > 0, do: :ok
  defp validate_key(_kind, _), do: {:error, "key vacío tras normalizar"}

  defp validate_definition("weapon", defn),
    do: validate_weapon(defn)

  defp validate_definition("spell", defn),
    do: validate_spell(defn)

  defp validate_definition("item", defn),
    do: validate_item(defn)

  defp validate_definition(_, _), do: {:error, "definition inválido"}

  defp validate_weapon(defn) do
    with {:ok, dice} <- require_dice(get(defn, "dice")),
         :ok <- require_str(get(defn, "damage_type"), "damage_type"),
         :ok <- require_ability(get(defn, "attack_ability")),
         {:ok, finesse} <- as_bool(get(defn, "finesse"), false),
         {:ok, ranged} <- as_bool(get(defn, "ranged"), false) do
      {:ok,
       %{
         "dice" => dice,
         "damage_type" => get(defn, "damage_type"),
         "attack_ability" => get(defn, "attack_ability"),
         "finesse" => finesse,
         "ranged" => ranged
       }}
    end
  end

  defp validate_spell(defn) do
    with {:ok, level} <- require_level(get(defn, "level")),
         kind <- get(defn, "kind"),
         :ok <- require_member(kind, "kind", @spell_kinds),
         {:ok, save} <- validate_save_ability(kind, get(defn, "save_ability")),
         :ok <- optional_dice(get(defn, "dice")),
         :ok <- optional_str(get(defn, "damage_type"), "damage_type"),
         {:ok, classes} <- require_classes(get(defn, "classes")) do
      {:ok,
       %{
         "level" => level,
         "kind" => kind,
         "save_ability" => save,
         "dice" => get(defn, "dice"),
         "damage_type" => get(defn, "damage_type"),
         "effect" => get(defn, "effect"),
         "classes" => classes
       }}
    end
  end

  # Si kind == "save", save_ability es obligatoria y debe ser una ability válida.
  # Para :attack/:automatic, nil es válido (se ignora).
  defp validate_save_ability("save", nil),
    do: {:error, "save_ability es obligatoria cuando kind es 'save'"}

  defp validate_save_ability("save", ab) when is_atom(ab),
    do: validate_save_ability("save", Atom.to_string(ab))

  defp validate_save_ability("save", ab) when ab in @abilities, do: {:ok, ab}

  defp validate_save_ability("save", _),
    do: {:error, "save_ability debe ser una de str/dex/con/int/wis/cha"}

  defp validate_save_ability(_, ab) when is_atom(ab),
    do: validate_save_ability(nil, Atom.to_string(ab))

  defp validate_save_ability(_, ab) when ab in @abilities, do: {:ok, ab}
  defp validate_save_ability(_, ab) when ab in [nil, ""], do: {:ok, nil}
  defp validate_save_ability(_, _), do: {:error, "save_ability inválido"}

  defp validate_item(defn) do
    with {:ok, qty} <- require_qty(get(defn, "qty")),
         :ok <- require_member(get(defn, "kind"), "kind", @item_kinds) do
      {:ok,
       %{
         "qty" => qty,
         "kind" => get(defn, "kind"),
         "effect" => get(defn, "effect")
       }}
    end
  end

  defp get(defn, key), do: Dragones.MapUtil.get(defn, key)

  defp require_str(nil, field), do: {:error, "#{field} es obligatorio"}
  defp require_str(v, _) when is_binary(v) and byte_size(v) > 0, do: :ok
  defp require_str(_, field), do: {:error, "#{field} inválido"}

  defp optional_str(nil, _), do: :ok
  defp optional_str(v, _) when is_binary(v), do: :ok
  defp optional_str(_, field), do: {:error, "#{field} inválido"}

  defp require_member(nil, field, _), do: {:error, "#{field} es obligatorio"}

  defp require_member(v, field, list) do
    if v in list, do: :ok, else: {:error, "#{field} inválido"}
  end

  defp require_dice(nil), do: {:error, "dice es obligatorio"}
  defp require_dice(dice), do: valid_dice(dice)

  defp optional_dice(nil), do: :ok

  defp optional_dice(dice) do
    case valid_dice(dice) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp valid_dice(dice) when is_binary(dice) do
    if Regex.match?(@dice_pattern, String.trim(dice)),
      do: {:ok, String.trim(dice)},
      else: {:error, "dice no es una expresión válida (p. ej. 2d6, 1d8+2)"}
  end

  defp valid_dice(_), do: {:error, "dice debe ser texto"}

  defp require_level(nil), do: {:error, "level es obligatorio"}

  defp require_level(level) when level in 0..9, do: {:ok, level}

  defp require_level(level) when is_binary(level) do
    case Integer.parse(level) do
      {n, ""} when n in 0..9 -> {:ok, n}
      _ -> {:error, "level debe ser un entero 0–9"}
    end
  end

  defp require_level(_), do: {:error, "level debe ser un entero 0–9"}

  defp require_ability(nil), do: {:error, "attack_ability es obligatorio"}

  defp require_ability(ab) when ab in @abilities, do: :ok

  defp require_ability(ab) when is_atom(ab), do: require_ability(Atom.to_string(ab))

  defp require_ability(_), do: {:error, "attack_ability debe ser una de str/dex/con/int/wis/cha"}

  defp require_classes(nil), do: {:error, "classes es obligatorio"}

  defp require_classes(classes) when is_list(classes) do
    valid = MapSet.new(Dragones.Heroes.Classes.keys())
    classes = Enum.map(classes, &to_string/1)
    bad = Enum.reject(classes, &MapSet.member?(valid, &1))

    if bad == [],
      do: {:ok, classes},
      else: {:error, "classes contiene claves desconocidas: #{inspect(bad)}"}
  end

  defp require_classes(class) when is_binary(class), do: require_classes([class])
  defp require_classes(_), do: {:error, "classes debe ser una lista de clases"}

  defp require_qty(nil), do: {:ok, 1}

  defp require_qty(qty) when is_integer(qty) and qty >= 1, do: {:ok, qty}

  defp require_qty(qty) when is_binary(qty) do
    case Integer.parse(qty) do
      {n, ""} when n >= 1 -> {:ok, n}
      _ -> {:error, "qty debe ser un entero ≥ 1"}
    end
  end

  defp require_qty(_), do: {:error, "qty debe ser un entero ≥ 1"}

  defp as_bool(true, _), do: {:ok, true}
  defp as_bool(false, _), do: {:ok, false}
  defp as_bool(nil, default), do: {:ok, default}
  defp as_bool("true", _), do: {:ok, true}
  defp as_bool("false", _), do: {:ok, false}
  defp as_bool(_, _), do: {:error, "valor booleano inválido"}

  # El unique_constraint del changeset cae a {:error, changeset}; lo traducimos a
  # un {:error, :conflict} legible para la UI.
  defp normalize_conflict({:ok, cc}), do: {:ok, cc}

  defp normalize_conflict({:error, %Ecto.Changeset{} = cs}) do
    if Keyword.has_key?(cs.errors, :key),
      do: {:error, :conflict},
      else: {:error, cs}
  end

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
