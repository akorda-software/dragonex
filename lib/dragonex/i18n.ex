defmodule Dragonex.I18n do
  @moduledoc """
  Localización para Dragonex.

  El proyecto es **monolingüe por ejecución**: una misma partida no mezcla
  idiomas, así que la locale es global (configurable, por defecto `:es`).
  Toda la capa de datos de D&D 5e (razas, clases, armas, hechizos…) vive
  identificada por una `key` estable e independiente del idioma; las
  traducciones se resuelven aquí y en `Dragonex.Heroes.Translations`.

  ## Diseño

    * Las **claves** (`key`) son siempre el identificador interno en inglés/slug
      (p. ej. `"fire_bolt"`, `"longsword"`, `"high elf"`). El motor, los tests y
      el codec las usan tal cual — nunca se traducen.
    * Las **etiquetas** (`label`) son el texto que ve el usuario, resuelto según
      la locale activa.
    * Cambiar toda la app de idioma es cambiar `locale/0` (o la config) y tener
      las traducciones del otro idioma disponibles.

  ## Persistencia de locale

  Hoy la locale es fija (`:es`). En el futuro podrá venir de:

    * config (`config :dragonex, :locale, :es`),
    * preferencia del usuario en DB,
    * `assigns` del LiveView.

  `with_locale/2` permite aislar un bloque (útil para tests o render con una
  locale distinta a la global).
  """

  @locales [:es, :en]
  @default_locale :es

  @doc "Locale activa."
  @spec locale() :: atom()
  def locale do
    Application.get_env(:dragonex, :locale, @default_locale)
  end

  @doc "Locales soportadas."
  @spec supported() :: [atom()]
  def supported, do: @locales

  @doc "Locale por defecto."
  @spec default_locale() :: atom()
  def default_locale, do: @default_locale

  @doc """
  Resuelve un mapa de etiquetas `%{es: ..., en: ...}` a la locale activa (o a la
  indicada). Si falta la traducción, cae a la otra locale y, si tampoco, a la
  propia `key` recibida como fallback.

      i18n_label(%{es: "Elfo", en: "Elf"}, :es)        # "Elfo"
      i18n_label(%{es: "Elfo", en: "Elf"}, :en)        # "Elf"
      i18n_label(%{es: nil, en: "Elf"}, :es, "elf")    # "Elf" (fallback en)
      i18n_label(nil, :es, "elf")                      # "elf"
  """
  @spec label(map() | nil, atom(), String.t() | nil) :: String.t() | nil
  def label(labels, locale, fallback \\ nil)

  def label(nil, _locale, fallback), do: fallback

  def label(labels, locale, fallback) when is_map(labels) do
    primary = Map.get(labels, locale)
    other = Enum.find_value(@locales -- [locale], &Map.get(labels, &1))
    primary || other || fallback
  end

  @doc """
  Ejecuta `fun` con una locale distinta a la global. Útil para tests o para
  renderizar contenido en el idioma de un participante concreto.

      I18n.with_locale(:en, fn -> Catalog.races(:en) end)
  """
  @spec with_locale(atom(), (-> term())) :: term()
  def with_locale(locale, fun) when locale in @locales and is_function(fun, 0) do
    prev = Application.get_env(:dragonex, :locale)
    Application.put_env(:dragonex, :locale, locale)

    try do
      fun.()
    after
      if prev do
        Application.put_env(:dragonex, :locale, prev)
      else
        Application.delete_env(:dragonex, :locale)
      end
    end
  end
end
