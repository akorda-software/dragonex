defmodule Dragonex.Rules.Effects do
  @moduledoc "Pure rules for sourced spell effects stored in character condition entries."

  def blessed?(character) do
    Enum.any?(character.conditions, &bless_entry?/1)
  end

  def bless_bonus(character, roller) do
    if blessed?(character), do: roller.(4), else: 0
  end

  def shielded_by_faith?(character) do
    Enum.any?(character.conditions, &shield_of_faith_entry?/1)
  end

  # D96 Shield: postura armable — la entrada estructurada vive en conditions
  # y la expiración es eager (set_current_combatant/end_combat), así que aquí
  # basta con detectarla: cualquier entrada viva suma +5.
  def shielded?(%{conditions: conds}) when is_list(conds) do
    Enum.any?(conds, &shield_entry?/1)
  end

  def shielded?(_), do: false

  @doc """
  Effective AC without modifying the base sheet: Mage Armor base (D98),
  Defense, non-stacking Shield of Faith and Shield posture (D96).
  """
  def effective_ac(character) do
    base =
      if mage_armored?(character) and not wearing_armor?(character) do
        max(character.ac, 13 + Dragonex.Character.modifier(character, :dex))
      else
        character.ac
      end

    base + if(character.fighting_style == "defense", do: 1, else: 0) +
      if(shielded_by_faith?(character), do: 2, else: 0) +
      if(shielded?(character), do: 5, else: 0)
  end

  def mage_armored?(%{conditions: conds}) when is_list(conds) do
    Enum.any?(conds, &mage_armor_entry?/1)
  end

  def mage_armored?(_), do: false

  # Shield is stored as kind :armor but does not end Mage Armor (D98).
  def wearing_armor?(%{inventory: items}) when is_list(items) do
    Enum.any?(items, &armor_but_not_shield?/1)
  end

  def wearing_armor?(_), do: false

  def tag(nil, 0), do: nil
  def tag(tag, 0), do: tag
  def tag(nil, bonus), do: "(+#{bonus} Bless)"
  def tag(tag, bonus), do: tag <> " (+#{bonus} Bless)"

  def without_source(character, source) do
    %{
      character
      | conditions: Enum.reject(character.conditions, &linked_to?(&1, source))
    }
  end

  defp bless_entry?(%{"condition" => "blessed", "concentration" => "bless", "source" => source}),
    do: is_binary(source)

  defp bless_entry?(_), do: false

  defp shield_of_faith_entry?(%{
         "condition" => "shield_of_faith",
         "concentration" => "shield of faith",
         "source" => source
       }),
       do: is_binary(source)

  defp shield_of_faith_entry?(_), do: false

  defp shield_entry?(%{"condition" => "shielded"}), do: true
  defp shield_entry?(_), do: false

  defp mage_armor_entry?(%{"condition" => "mage_armor"}), do: true
  defp mage_armor_entry?(%{condition: "mage_armor"}), do: true
  defp mage_armor_entry?("mage_armor"), do: true
  defp mage_armor_entry?(_), do: false

  defp armor_but_not_shield?(%{kind: :armor, name: name}), do: not shield_name?(name)
  defp armor_but_not_shield?(%{"kind" => "armor", "name" => name}), do: not shield_name?(name)
  defp armor_but_not_shield?(_), do: false

  defp shield_name?(name) when is_binary(name), do: String.downcase(name) == "shield"
  defp shield_name?(_), do: false

  defp linked_to?(entry, source) do
    case source_of(entry) do
      ^source ->
        bless_entry?(entry) or shield_of_faith_entry?(entry)

      "hold_person:" <> rest ->
        rest == source and hold_person_entry?(entry)

      "faerie_fire:" <> rest ->
        rest == source and faerie_fire_entry?(entry)

      _ ->
        false
    end
  end

  defp source_of(%{"source" => source}) when is_binary(source), do: source
  defp source_of(_), do: nil

  defp hold_person_entry?(%{"condition" => "paralyzed", "concentration" => "hold person"}),
    do: true

  defp hold_person_entry?(_), do: false

  defp faerie_fire_entry?(%{"condition" => "faerie_fire", "concentration" => "faerie fire"}),
    do: true

  defp faerie_fire_entry?(_), do: false
end
