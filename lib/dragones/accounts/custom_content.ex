defmodule Dragones.Accounts.CustomContent do
  @moduledoc """
  Contenido de catálogo creado por un usuario: armas, hechizos u objetos que no
  existen en el SRD.

  Una sola tabla polimórfica: el `kind` discrimina el tipo y `definition` guarda
  las mecánicas en JSONB con la misma forma que las structs del motor
  (`Dragones.Weapon`/`Spell`/`Item`) para que encajen con el `Codec` y el
  `Catalog` sin conversión especial.

  El `key` es un slug estable y lowercased, único por `(user_id, kind, key)`. Es
  la clave que viaja al `Character` (con prefijo `custom_`) para no colisionar con
  las keys SRD.

  Las mecánicas se validan por `kind` en `Dragones.Accounts` (dados parseables,
  kind de hechizo válido, etc.); este módulo solo valida la estructura.
  """

  use Ecto.Schema

  alias Dragones.Accounts.User

  @kinds ~w(weapon spell item)
  @abilities ~w(str dex con int wis cha)
  @spell_kinds ~w(save attack automatic)
  @item_kinds ~w(gear armor ammo focus consumable magic)

  @type kind :: :weapon | :spell | :item

  @type t :: %__MODULE__{}

  schema "custom_contents" do
    belongs_to(:user, User)
    field(:kind, :string)
    field(:key, :string)
    field(:name_es, :string)
    field(:definition, :map)
    field(:notes, :string)

    timestamps(type: :naive_datetime)
  end

  @doc "Kinds de contenido custom soportados."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Las seis characteristics de D&D 5e (fuente única para validación y UI)."
  @spec abilities() :: [String.t()]
  def abilities, do: @abilities

  @doc "Kinds de tirada de hechizo."
  @spec spell_kinds() :: [String.t()]
  def spell_kinds, do: @spell_kinds

  @doc "Kinds de objeto de inventario custom."
  @spec item_kinds() :: [String.t()]
  def item_kinds, do: @item_kinds

  @doc "Construye un slug lowercased y seguro a partir de un nombre libre."
  @spec slugify(String.t()) :: String.t()
  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
    |> String.replace(~r/\s+/, "_")
  end

  @doc """
  Changeset estructural. La validación de mecánicas (dados, kind de hechizo…)
  la hace el contexto `Accounts` porque depende del `kind`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(cc, attrs) do
    cc
    |> Ecto.Changeset.cast(attrs, [:user_id, :kind, :key, :name_es, :definition, :notes])
    |> Ecto.Changeset.validate_required([:kind, :key, :name_es, :definition])
    |> Ecto.Changeset.validate_inclusion(:kind, @kinds)
    |> Ecto.Changeset.unique_constraint(:key,
      name: :custom_contents_user_id_kind_key_index
    )
  end
end
