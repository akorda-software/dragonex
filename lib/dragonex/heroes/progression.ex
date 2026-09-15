defmodule Dragonex.Heroes.Progression do
  @moduledoc """
  Reglas de progresión de D&D 5e para la subida de nivel.

  Fuente de verdad para:
    * la **tabla de XP** (cuánta experiencia hace falta para alcanzar cada nivel),
    * los **niveles de ASI** (mejora de característica: 4/8/12/16/19),
    * el **nivel máximo de hechizo** que puede conocer un conjurador según nivel,
    * las **features de clase** que se desbloquean al subir.

  Es un módulo puro (sin estado, sin DB) para que el builder, el `World`, la UI
  y los tests compartan las mismas definiciones.

  ## Simplificaciones de la v1 (documentadas)

    * **Pact Magic (D40)**: el brujo usa huecos de pacto (todos del mismo nivel,
      1º–5º, short rest). `max_spell_level` es el nivel de pacto, cap 5. Mystic
      Arcanum (6º–9º 1/long rest) y el escalado de daño por upcast quedan fuera.
    * **Hechizos conocidos**: las clases preparadoras (clérigo/druida) y de
      grimorio (mago) cambian su lista libremente al subir; las de lista cerrada
      (bardo/hechicero/brujo) reciben un cupo derivado. Aquí `spells_known/2`
      devuelve `nil` cuando no hay cap estricto (el jugador ajusta libremente).
    * **Dotes**: fuera de la v1; el ASI a 4/8/12/16/19 reparte +2 puntos.
    * **Features**: se modelan las que afectan a la ficha de forma
        mecánica inmediata (conjuración paladín/explorador a L2; Extra Attack
        a L5 en clases marciales, D35; Sneak Attack del rogue, D41; Action
        Surge del fighter a L2, D47; Ki/Flurry of Blows del monje a L2, D54;
        Font of Magic del hechicero a L2, D56). El resto de features por nivel sigue
        fuera de v1. Rage del bárbaro (D42) usa `rage_damage/1`, no el
        string `"rage"`.
  """

  # XP total necesario para ALCANZAR cada nivel (tabla de avances 5e).
  @xp_table %{
    1 => 0,
    2 => 300,
    3 => 900,
    4 => 2_700,
    5 => 6_500,
    6 => 14_000,
    7 => 23_000,
    8 => 34_000,
    9 => 48_000,
    10 => 64_000,
    11 => 85_000,
    12 => 100_000,
    13 => 120_000,
    14 => 140_000,
    15 => 165_000,
    16 => 195_000,
    17 => 225_000,
    18 => 265_000,
    19 => 305_000,
    20 => 355_000
  }

  # Niveles en los que se gana mejora de característica (ASI).
  @asi_levels [4, 8, 12, 16, 19]

  # Puntos a repartir en cada ASI (5e: +2 o equivalente).
  @asi_points 2

  @full_casters ~w(bard cleric druid sorcerer wizard)a
  @half_casters ~w(paladin ranger)a
  @pact_casters ~w(warlock)a
  @extra_attack_classes ~w(fighter barbarian paladin ranger monk)a

  # ------------------------------------------------------------ XP / nivel

  @doc "XP total necesaria para alcanzar `level` (0 para nivel 1, nil > 20)."
  @spec xp_threshold(pos_integer()) :: non_neg_integer() | nil
  def xp_threshold(level) when level in 1..20, do: @xp_table[level]
  def xp_threshold(_), do: nil

  @doc "Nivel que corresponde a una cantidad de XP (1–20)."
  @spec level_for_xp(non_neg_integer()) :: pos_integer()
  def level_for_xp(xp) when is_integer(xp) and xp >= 0 do
    @xp_table
    |> Enum.filter(fn {_lvl, thr} -> xp >= thr end)
    |> Enum.map(fn {lvl, _} -> lvl end)
    |> Enum.max(fn -> 1 end)
  end

  @doc "¿Tiene el héroe XP suficiente para subir desde `level`?"
  @spec can_level_up?(pos_integer(), non_neg_integer()) :: boolean()
  def can_level_up?(level, xp) when level in 1..19 do
    xp >= xp_threshold(level + 1)
  end

  def can_level_up?(20, _xp), do: false

  @doc "XP que falta para subir desde `level` (0 si ya puede, nil en nivel 20)."
  @spec xp_to_next_level(pos_integer(), non_neg_integer()) :: non_neg_integer() | nil
  def xp_to_next_level(20, _xp), do: nil

  def xp_to_next_level(level, xp) when level in 1..19 do
    max(0, xp_threshold(level + 1) - xp)
  end

  # ------------------------------------------------------------ ASI

  @doc "Niveles en los que se gana mejora de característica."
  @spec asi_levels() :: [pos_integer()]
  def asi_levels, do: @asi_levels

  @doc "¿Se gana ASI al alcanzar `level`?"
  @spec asi_at?(pos_integer()) :: boolean()
  def asi_at?(level), do: level in @asi_levels

  @doc "Puntos de característica a repartir en un ASI."
  @spec asi_points() :: pos_integer()
  def asi_points, do: @asi_points

  # ------------------------------------------------------------ conjuración

  @doc "¿Es la clase un conjurador (completo, parcial o de pacto)?"
  @spec caster?(String.t() | atom()) :: boolean()
  def caster?(class) do
    c = class_name(class)
    c in @full_casters or c in @half_casters or c in @pact_casters
  end

  @doc "Nivel máximo de hechizo que puede conocer un conjurador a `level` (0 si no lanza)."
  @spec max_spell_level(String.t() | atom(), pos_integer()) :: non_neg_integer()
  def max_spell_level(class, level) do
    cond do
      class_name(class) in @pact_casters -> min(div(level + 1, 2), 5)
      class_name(class) in @full_casters -> min(div(level + 1, 2), 9) |> max(0)
      class_name(class) in @half_casters -> half_caster_max(level)
      true -> 0
    end
  end

  # Paladín/explorador ganan conjuración a L2: L2-4 → 1º, L5-8 → 2º,
  # L9-12 → 3º, L13-16 → 4º, L17+ → 5º.
  defp half_caster_max(level) when level >= 17, do: 5
  defp half_caster_max(level) when level >= 13, do: 4
  defp half_caster_max(level) when level >= 9, do: 3
  defp half_caster_max(level) when level >= 5, do: 2
  defp half_caster_max(level) when level >= 2, do: 1
  defp half_caster_max(_), do: 0

  # ------------------------------------------------------------ hechizos conocidos

  @doc """
  Número de hechizos que la clase puede añadir al subir a `level`, o `nil` si no
  hay cap estricto (preparadores/grimorio: el jugador ajusta libremente).

  Simplificación v1: `nil` para todos. El flujo de subida deja elegir libremente.
  """
  @spec spells_known(String.t() | atom(), pos_integer()) :: non_neg_integer() | nil
  def spells_known(_class, _level), do: nil

  @doc """
  Número de trucos (cantrips) que la clase puede añadir al subir a `level`, o
  `nil` si no aplica. Simplificación v1: siempre `nil`.
  """
  @spec cantrips_known(String.t() | atom(), pos_integer()) :: non_neg_integer() | nil
  def cantrips_known(_class, _level), do: nil

  # ------------------------------------------------------------ features

  @doc """
  Features de clase que se desbloquean al ALCANZAR `level`.

  v1 modela las que afectan mecánicamente a la ficha: conjuración de
  paladín/explorador a L2 (`spellcasting`), Action Surge del fighter a
  L2 (`action_surge`, D47) y Extra Attack a L5 en las cinco clases
  marciales (`extra_attack`, D35). El N de golpes lo da
  `attack_count/2` (no el string): fighter L11/L20 no añade otro feature.
  """
  @spec features_at(String.t() | atom(), pos_integer()) :: [String.t()]
  def features_at(class, 2) do
    cond do
      class_name(class) in @half_casters -> ["spellcasting"]
      class_name(class) == :fighter -> ["action_surge"]
      true -> []
    end
  end

  def features_at(class, 5) do
    if class_name(class) in @extra_attack_classes, do: ["extra_attack"], else: []
  end

  def features_at(_class, _level), do: []

  @doc """
  Número de tiradas de ataque que resuelve una Acción de Ataque (D35).

  Tabla 5e; el motor es fuente de verdad (D1), no el string `extra_attack`
  en `class_features` — partidas viejas L5+ sin el feature siguen recibiendo
  el N correcto.

    * fighter: L1–4 → 1; L5–10 → 2; L11–19 → 3; L20 → 4
    * barbarian, paladin, ranger, monk: L5+ → 2; si no → 1
    * resto → 1
  """
  @spec attack_count(String.t() | atom(), pos_integer()) :: pos_integer()
  def attack_count(class, level) when is_integer(level) and level >= 1 do
    case class_name(class) do
      :fighter -> fighter_attack_count(level)
      c when c in @extra_attack_classes -> if(level >= 5, do: 2, else: 1)
      _ -> 1
    end
  end

  defp fighter_attack_count(level) when level >= 20, do: 4
  defp fighter_attack_count(level) when level >= 11, do: 3
  defp fighter_attack_count(level) when level >= 5, do: 2
  defp fighter_attack_count(_level), do: 1

  @doc """
  Dados de Sneak Attack (d6) según clase y nivel (D41).

  Tabla 5e; el motor es fuente de verdad (D1), no el string `sneak_attack`
  en `class_features` — partidas viejas L1 rogue sin el feature siguen
  recibiendo los dados. El string L1 del catálogo se queda (ficha/UI).

    * rogue: `div(level + 1, 2)` — L1=1, L3=2, L5=3, … L19=10
    * resto → 0
  """
  @spec sneak_attack_dice(String.t() | atom(), pos_integer()) :: non_neg_integer()
  def sneak_attack_dice(class, level) when is_integer(level) and level >= 1 do
    case class_name(class) do
      :rogue -> div(level + 1, 2)
      _ -> 0
    end
  end

  @doc """
  Bonus de daño de Rage según nivel (D42). Tabla 5e; el motor es fuente
  de verdad (D1), no el string `rage` en `class_features`.

    * L1–8 → +2; L9–15 → +3; L16–20 → +4
  """
  @spec rage_damage(pos_integer()) :: non_neg_integer()
  def rage_damage(level) when is_integer(level) and level >= 16, do: 4
  def rage_damage(level) when is_integer(level) and level >= 9, do: 3
  def rage_damage(level) when is_integer(level) and level >= 1, do: 2

  @doc """
  Dados de artes marciales del monje según nivel (D54).

  Tabla 5e; el motor es fuente de verdad (D1):

    * L1–4 → "1d4"; L5–10 → "1d6"; L11–16 → "1d8"; L17–20 → "1d10"
  """
  @spec martial_arts_die(pos_integer()) :: String.t()
  def martial_arts_die(level) when is_integer(level) and level >= 17, do: "1d10"
  def martial_arts_die(level) when is_integer(level) and level >= 11, do: "1d8"
  def martial_arts_die(level) when is_integer(level) and level >= 5, do: "1d6"
  def martial_arts_die(level) when is_integer(level) and level >= 1, do: "1d4"

  @doc """
  Dados del Aliento de dragón del dragontino según nivel (D70).

  Tabla 5e (sin ascendencia dracónica — fuego fijo, ver ADR); el motor
  es fuente de verdad (D1):

    * L1–4 → "2d6"; L5–10 → "3d6"; L11–16 → "4d6"; L17–20 → "5d6"
  """
  @spec breath_dice(pos_integer()) :: String.t()
  def breath_dice(level) when is_integer(level) and level >= 17, do: "5d6"
  def breath_dice(level) when is_integer(level) and level >= 11, do: "4d6"
  def breath_dice(level) when is_integer(level) and level >= 5, do: "3d6"
  def breath_dice(level) when is_integer(level) and level >= 1, do: "2d6"

  @doc """
  Puntos de ki máximos según clase y nivel (D54). Tabla 5e; el motor es
  fuente de verdad (D1):

    * monk L2+ → `level`; L1 → 0; resto → 0
  """
  @spec ki_points(String.t() | atom(), pos_integer()) :: non_neg_integer()
  def ki_points(class, level) when is_integer(level) and level >= 2 do
    if class_name(class) == :monk, do: level, else: 0
  end

  def ki_points(_class, _level), do: 0

  @doc """
  Puntos de hechicería máximos según clase y nivel (D56, Font of Magic).
  Tabla 5e; el motor es fuente de verdad (D1):

    * sorcerer L2+ → `level`; L1 → 0; resto → 0
  """
  @spec sorcery_points(String.t() | atom(), pos_integer()) :: non_neg_integer()
  def sorcery_points(class, level) when is_integer(level) and level >= 2 do
    if class_name(class) == :sorcerer, do: level, else: 0
  end

  def sorcery_points(_class, _level), do: 0

  @doc """
  Coste en puntos de hechicería de crear una casilla de nivel `level`
  (Font of Magic, D56). Tabla RAW 5e:

    * 1º → 2; 2º → 3; 3º → 5; 4º → 6; 5º → 7

  Casillas por encima de 5º no se pueden crear (RAW); devuelve `nil`.
  """
  @spec sorcery_slot_cost(integer()) :: pos_integer() | nil
  def sorcery_slot_cost(level)
      when is_integer(level) and level >= 1 and level <= 5,
      do: %{1 => 2, 2 => 3, 3 => 5, 4 => 6, 5 => 7}[level]

  def sorcery_slot_cost(_), do: nil

  # ------------------------------------------------------------ helpers

  defp class_name(class) when is_atom(class), do: class
  defp class_name(class) when is_binary(class), do: String.to_atom(class)
end
