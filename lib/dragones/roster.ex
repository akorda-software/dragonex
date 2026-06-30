defmodule Dragones.Roster do
  @moduledoc """
  The creator wizard's catalogue of selectable characters: predefined PCs and
  monsters (`catalog/0`), plus the user's saved heroes (`hero_catalog/1`).

  Renamed from the old `Dragones.Scenario` — that collided confusingly with
  `Dragones.Scenarios` (the *story bibles*). This module builds the partida's
  starting roster; `Scenarios` supplies the campaign's narrative setup.
  """

  alias Dragones.{Archetypes, Monsters}

  @doc """
  The catalogue of selectable characters for the creator wizard: predefined PCs
  (each playable as `:human` or `:ai`) and monsters (always DM-controlled). Each
  entry carries a stable `key`, a label, the side, and a zero-arg builder that
  returns the `Dragones.Character` sheet.
  """
  @spec catalog() :: [map()]
  def catalog do
    [
      %{key: "fighter", name: "Thane", role: "fighter", side: "pc", builder: &Archetypes.fighter/0},
      %{key: "wizard", name: "Lyra", role: "wizard", side: "pc", builder: &Archetypes.wizard/0},
      %{key: "rogue", name: "Vex", role: "rogue", side: "pc", builder: &Archetypes.rogue/0},
      %{key: "goblin", name: "goblin", role: "monster", side: "enemy", builder: &Monsters.goblin/0},
      %{key: "kobold", name: "kobold", role: "monster", side: "enemy", builder: &Monsters.kobold/0},
      %{key: "bandit", name: "bandit", role: "monster", side: "enemy", builder: &Monsters.bandit/0},
      %{key: "skeleton", name: "skeleton", role: "monster", side: "enemy", builder: &Monsters.skeleton/0},
      %{key: "wolf", name: "wolf", role: "monster", side: "enemy", builder: &Monsters.wolf/0},
      %{key: "orc", name: "orc", role: "monster", side: "enemy", builder: &Monsters.orc/0},
      %{key: "ogre", name: "ogre", role: "monster", side: "enemy", builder: &Monsters.ogre/0}
    ]
  end

  @doc "Look up a catalogue entry by key."
  @spec catalog_entry(String.t()) :: map() | nil
  def catalog_entry(key) when is_binary(key),
    do: Enum.find(catalog(), &(&1.key == key))

  @doc """
  The user's saved heroes in catalogue format, for the wizard.
  Each entry has a stable `key` (`hero_<id>`), the hero's name as label,
  `side: "pc"`, and a `builder` that decodes the saved sheet.
  """
  @spec hero_catalog(Dragones.Accounts.User.t() | nil) :: [map()]
  def hero_catalog(nil), do: []

  def hero_catalog(%Dragones.Accounts.User{} = user) do
    user
    |> Dragones.Accounts.list_heroes()
    |> Enum.map(fn hero ->
      %{
        key: "hero_#{hero.id}",
        name: hero.name,
        role: hero.class,
        side: "pc",
        builder: fn -> Dragones.Accounts.hero_sheet(hero) end
      }
    end)
  end
end
