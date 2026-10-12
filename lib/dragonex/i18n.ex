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

  ## Locale por partida

  Cada partida guarda su idioma (`games.locale`). El proceso de la partida,
  sus beats, las herramientas y la LiveView de la mesa fijan esa locale con
  `put_locale/1`, que es local al proceso: dos mesas en idiomas distintos
  conviven sin pisarse. Sin locale de proceso rige la configurada
  (`config :dragonex, :locale`) y, por defecto, `:es`.
  """

  @locales [:es, :en]
  @default_locale :es

  @process_key {__MODULE__, :locale}

  @doc """
  Locale activa: la del proceso (`put_locale/1`), si no la configurada y, por
  defecto, `:es`. Cada partida fija la suya en sus procesos, así que dos mesas
  en idiomas distintos no se pisan.
  """
  @spec locale() :: atom()
  def locale do
    Process.get(@process_key) || Application.get_env(:dragonex, :locale, @default_locale)
  end

  @doc "Fija la locale de este proceso; `nil` vuelve a la configurada."
  @spec put_locale(atom() | String.t() | nil) :: atom() | nil
  def put_locale(nil) do
    Gettext.put_locale(Dragonex.Gettext, Atom.to_string(configured()))
    Process.delete(@process_key)
  end

  def put_locale(locale) do
    locale = normalize(locale)
    Process.put(@process_key, locale)
    # The message catalog follows the same per-process locale.
    Gettext.put_locale(Dragonex.Gettext, Atom.to_string(locale))
    locale
  end

  defp configured, do: Application.get_env(:dragonex, :locale, @default_locale)

  @doc """
  Adopta la locale que viaja en los `deps` de un beat. Las herramientas y
  capacidades del agente corren en procesos de exAgent que no heredan la del
  proceso de la partida.
  """
  @spec adopt(map() | term()) :: :ok
  def adopt(%{locale: locale}) when not is_nil(locale) do
    put_locale(locale)
    :ok
  end

  def adopt(_deps), do: :ok

  @doc "Locale válida a partir de un átomo o texto («en», :es…); si no, la por defecto."
  @spec normalize(term()) :: atom()
  def normalize(locale) when locale in @locales, do: locale
  def normalize("en"), do: :en
  def normalize("es"), do: :es
  def normalize(_), do: @default_locale

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
  Ejecuta `fun` con otra locale solo en este proceso. Útil para tests o para
  renderizar contenido en el idioma de una partida concreta.

      I18n.with_locale(:en, fn -> Catalog.races(:en) end)
  """
  @spec with_locale(atom(), (-> term())) :: term()
  def with_locale(locale, fun) when locale in @locales and is_function(fun, 0) do
    prev = Process.get(@process_key)
    put_locale(locale)

    try do
      fun.()
    after
      put_locale(prev)
    end
  end
end
