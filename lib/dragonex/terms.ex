defmodule Dragonex.Terms do
  @moduledoc """
  Game vocabulary as the engine writes it in its own messages, per locale.

  The engine keeps stable English keys (`"longsword"`, `"piercing"`,
  `"fire bolt"`); this module renders them for the active `Dragonex.I18n`
  locale inside sentences: roll reasons, tool feedback and errors. It reuses
  `Heroes.Translations` and only adds what sentences need beyond a label:
  in-sentence casing, agreed damage phrases and natural monster attacks.
  Unknown keys fall back to the key itself, never to an empty string.
  """

  alias Dragonex.Heroes.Translations
  alias Dragonex.I18n

  # Natural attacks of the bestiary, absent from the hero creator's catalog.
  @natural %{
    "bite" => %{es: "mordisco", en: "bite"},
    "claw" => %{es: "garra", en: "claw"},
    "claws" => %{es: "garras", en: "claws"},
    "slam" => %{es: "golpe", en: "slam"},
    "gore" => %{es: "cornada", en: "gore"},
    "sting" => %{es: "aguijón", en: "sting"},
    "talons" => %{es: "garras", en: "talons"},
    "tentacle" => %{es: "tentáculo", en: "tentacle"},
    "tail" => %{es: "coletazo", en: "tail"},
    "beak" => %{es: "picotazo", en: "beak"},
    "fist" => %{es: "puñetazo", en: "fist"},
    "unarmed strike" => %{es: "golpe desarmado", en: "unarmed strike"},
    "unarmed" => %{es: "golpe desarmado", en: "unarmed strike"}
  }

  # SRD conditions plus the engine's own states.
  @conditions %{
    "blinded" => %{es: "cegado", en: "blinded"},
    "charmed" => %{es: "hechizado", en: "charmed"},
    "deafened" => %{es: "ensordecido", en: "deafened"},
    "frightened" => %{es: "asustado", en: "frightened"},
    "grappled" => %{es: "agarrado", en: "grappled"},
    "incapacitated" => %{es: "incapacitado", en: "incapacitated"},
    "invisible" => %{es: "invisible", en: "invisible"},
    "paralyzed" => %{es: "paralizado", en: "paralyzed"},
    "petrified" => %{es: "petrificado", en: "petrified"},
    "poisoned" => %{es: "envenenado", en: "poisoned"},
    "prone" => %{es: "derribado", en: "prone"},
    "restrained" => %{es: "apresado", en: "restrained"},
    "stunned" => %{es: "aturdido", en: "stunned"},
    "unconscious" => %{es: "inconsciente", en: "unconscious"},
    "exhaustion" => %{es: "agotamiento", en: "exhaustion"},
    "diseased" => %{es: "enfermo", en: "diseased"},
    "hidden" => %{es: "oculto", en: "hidden"}
  }

  # The 319 SRD spells carry their Spanish name; the curated catalog wins.
  @srd_es Map.new(Dragonex.Heroes.SRDSpells.all(), &{&1.name, &1.name_es})

  # Spanish damage types that read as nouns take «de»: «daño de fuego».
  @es_noun_damage ~w(acid cold fire force lightning poison thunder)
  @es_damage_noun %{"force" => "fuerza", "lightning" => "relámpago"}

  @doc "A weapon or natural attack inside a sentence: «arco corto», «mordisco»."
  def weapon(key, locale \\ I18n.locale())
  def weapon(nil, _locale), do: ""

  def weapon(key, locale) do
    key = key |> to_string() |> String.trim()
    lookup = String.downcase(key)

    case Map.get(@natural, lookup) do
      nil -> lookup |> Translations.weapon(locale) |> in_sentence(key, locale)
      labels -> I18n.label(labels, locale, key)
    end
  end

  @doc "A spell's proper name: «Rayo ígneo», «Fire Bolt»."
  def spell(key, locale \\ I18n.locale())
  def spell(nil, _locale), do: ""

  def spell(key, locale) do
    key = to_string(key)
    lookup = String.downcase(key)
    label = Translations.spell(lookup, locale)

    cond do
      label != lookup -> label
      locale == :es -> Map.get(@srd_es, lookup, key)
      Map.has_key?(@srd_es, lookup) -> title(lookup)
      true -> key
    end
  end

  defp title(key), do: key |> String.split(" ") |> Enum.map_join(" ", &String.capitalize/1)

  @doc "A condition as a state: «envenenado», «derribado» / «poisoned»."
  def condition(key, locale \\ I18n.locale())
  def condition(nil, _locale), do: ""

  def condition(key, locale) do
    key = key |> to_string() |> String.trim()
    I18n.label(Map.get(@conditions, String.downcase(key)), locale, key)
  end

  @doc "The bare damage type: «perforante», «fuego» / «piercing»."
  def damage_type(key, locale \\ I18n.locale())
  def damage_type(nil, _locale), do: ""

  def damage_type(key, :es) do
    key = to_string(key)
    Map.get(@es_damage_noun, key) || Translations.damage_type(key, :es)
  end

  def damage_type(key, locale), do: Translations.damage_type(to_string(key), locale)

  @doc "The damage phrase: «daño perforante», «daño de fuego» / «piercing damage»."
  def damage(key, locale \\ I18n.locale())
  def damage(nil, :es), do: "daño"
  def damage(nil, _locale), do: "damage"

  def damage(key, :es) do
    key = to_string(key)
    type = damage_type(key, :es)
    if key in @es_noun_damage, do: "daño de #{type}", else: "daño #{type}"
  end

  def damage(key, locale), do: "#{damage_type(key, locale)} damage"

  # Translations label items for menus («Espada larga»); a sentence wants the
  # common noun in lower case. An untranslated key stays as written.
  defp in_sentence(label, key, _locale) when label == key, do: key

  defp in_sentence(<<first::utf8, rest::binary>>, _key, _locale),
    do: String.downcase(<<first::utf8>>) <> rest

  defp in_sentence(label, _key, _locale), do: label
end
