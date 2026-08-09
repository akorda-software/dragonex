defmodule Dragones.Heroes.SRDSpells do
  @moduledoc """
  Hechizos del SRD 5.1 importados y traducidos al español.

  Carga `priv/srd/spells.es.json` (generado por `scripts/import_srd_spells.py`)
  en tiempo de compilación. Si el fichero no existe (p. ej. antes de correr el
  importer) devuelve `[]` sin romper la compilación.

  Cada entrada tiene la misma forma que `Dragones.Heroes.Spells` pero con los
  textos ya en español:

      %{name, name_es, level, school, kind, save_ability, dice, damage_type,
        effect, classes, range, casting_time, duration, concentration, ritual,
        source: :srd}

  `Dragones.Heroes.Spells.all/0` mezcla builtin + SRD (builtin gana en
  duplicados para conservar nuestras correcciones de mecánica).
  """

  @path Path.join(:code.priv_dir(:dragones), "srd/spells.es.json")

  @abilities ~w(str dex con int wis cha)
  @kinds ~w(attack save automatic)

  # Cargado UNA vez en compilación (no por cada llamada). @external_resource hace
  # que el módulo recompile cuando el JSON cambia (p. ej. tras re-correr el
  # importer), así en runtime el catálogo es gratis: clave para que el creador
  # no tenga lag al teclear/togglear hechizos.
  @external_resource @path
  @srd_all (case File.read(@path) do
              {:ok, raw} ->
                raw
                |> Jason.decode!(keys: :atoms)
                |> Enum.map(fn s ->
                  raw_name = s[:key] || s[:name]
                  key = raw_name |> to_string() |> String.downcase()
                  kind_val = s[:kind] && to_string(s[:kind])
                  save_val = s[:save_ability] && to_string(s[:save_ability])

                  %{
                    name: key,
                    name_es: s[:name_es] || key,
                    level: s[:level],
                    school: s[:school],
                    kind: (kind_val in @kinds && String.to_atom(kind_val)) || :automatic,
                    save_ability: (save_val in @abilities && String.to_atom(save_val)) || nil,
                    dice: s[:dice],
                    damage_type: s[:damage_type],
                    effect: s[:effect],
                    classes: s[:classes] || [],
                    range: s[:range],
                    casting_time: s[:casting_time],
                    duration: s[:duration],
                    concentration: s[:concentration],
                    ritual: s[:ritual],
                    source: :srd
                  }
                end)

              {:error, _} ->
                []
            end)

  @doc "Path del JSON (expuesto para tests/diagnóstico)."
  @spec path() :: String.t()
  def path, do: @path

  @doc "Todos los hechizos SRD importados (devuelve [] si el JSON no existe)."
  @spec all() :: [map()]
  def all, do: @srd_all

  @doc "¿Está disponible el fichero SRD importado?"
  @spec loaded?() :: boolean()
  def loaded?, do: @srd_all != []
end
