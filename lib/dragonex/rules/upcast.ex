defmodule Dragonex.Rules.Upcast do
  @moduledoc """
  Upcasting 5e RAW (ADR D74, mecánica M58): lanzar un hechizo con una casilla
  de nivel superior aplicando el escalado exacto de cada hechizo.

  El JSON del SRD no trae reglas de escalado estructuradas (las descripciones
  no incluyen el bloque "A niveles superiores"), así que la tabla vive AQUÍ,
  curada en código y auditada contra la descripción RAW 2014 de cada hechizo.
  Hechizos ausentes de la tabla no escalan (comportamiento previo del motor).

  La tabla vive en `Rules` (no en `Actions`) porque es **datos de reglas**, no
  orquestación (D1: el motor es fuente de verdad) — y mantiene `Actions` libre
  de tablas estáticas crecientes. Módulo puro, testeable con `async: true`.

  Cada entrada dice cómo escala el hechizo por cada nivel de casilla POR ENCIMA
  de su nivel base:

      %{per: 1, die: 6}  — +1d6 por nivel sobre la base (fireball, burning
                            hands, cure wounds, vampiric touch, …)
      %{per: 2, die: 8}  — +1d8 cada DOS niveles sobre la base (los niveles
                            impares no añaden nada: spiritual weapon a 4º)
      :dart              — magic missile: +1 dardo (+1d4+1) por nivel
      :sleep             — sleep: +2d8 por nivel sobre el 1º (D96)

  Excluidos a propósito (ADR D74): escalados multi-objetivo ("+1 objetivo":
  hold_person, invisibility…), multi-rayo (scorching_ray) y hechizos que el
  motor no resuelve con dados reales (mass_cure_wounds:
  SRD sin `dice`). flame_strike escala +1d6 al total aunque RAW reparte el extra
  entre fuego y radiante — el motor modela 4d6 de fuego único (simplificación
  documentada). Heal escala curación plana por su ruta propia (D87), no aquí.
  """

  alias Dragonex.Dice
  alias Dragonex.Spell

  @type scaling :: %{per: pos_integer(), die: pos_integer()} | :dart

  @upcast_scaling %{
    "burninghands" => %{per: 1, die: 6},
    "thunderwave" => %{per: 1, die: 8},
    "shatter" => %{per: 1, die: 8},
    "fireball" => %{per: 1, die: 6},
    "lightningbolt" => %{per: 1, die: 6},
    "blight" => %{per: 1, die: 8},
    "flamestrike" => %{per: 1, die: 6},
    "vampirictouch" => %{per: 1, die: 6},
    "spiritualweapon" => %{per: 2, die: 8},
    # D99 Spirit Guardians: +1d8 por nivel de casilla sobre 3º (RAW).
    "spiritguardians" => %{per: 1, die: 8},
    "magicmissile" => :dart,
    # D96 Sleep: RAW añade 2d8 por nivel sobre el 1º (no 1d8 — por eso
    # fila propia en vez del genérico %{per: 1, die: 8}).
    "sleep" => :sleep,
    "curewounds" => %{per: 1, die: 8},
    "healingword" => %{per: 1, die: 4},
    "prayerofhealing" => %{per: 1, die: 8}
  }

  @doc """
  Dados extra (expresión tipo `"2d6"`) que aporta lanzar `spell_name` (nivel
  base `base_level`) con una casilla de `cast_level`. `nil` cuando el hechizo
  no escala o el salto no añade dados (p. ej. cada-dos-niveles en nivel impar).
  """
  @spec extra_dice(String.t(), non_neg_integer(), non_neg_integer()) :: String.t() | nil
  def extra_dice(spell_name, base_level, cast_level) when cast_level > base_level do
    above = cast_level - base_level

    case Map.get(@upcast_scaling, normalize(spell_name)) do
      :dart ->
        "#{above}d4+#{above}"

      # D96: +2d8 por nivel sobre la base (RAW sleep).
      :sleep ->
        "#{2 * above}d8"

      %{per: per, die: die} ->
        if div(above, per) > 0, do: "#{div(above, per)}d#{die}", else: nil

      nil ->
        nil
    end
  end

  def extra_dice(_spell_name, _base_level, _cast_level), do: nil

  @doc "False Life (D89): one d4, +4 base and +5 temporary HP per higher slot."
  def false_life_dice(level) when is_integer(level) and level in 1..9,
    do: "1d4+#{4 + 5 * (level - 1)}"

  @doc """
  El hechizo con sus dados ya escalados a `cast_level`: combina la expresión
  base con los dados extra en UNA sola (`"8d6"` + `"1d6"` → `"9d6"`), de modo
  que el dado extra entra al mismo RollLog, al mismo desglose y a los mismos
  caminos (mitad en salvación, crit doblado, Empowered) que los dados base.
  Hechizos sin escalado (o `cast_level` == base) vuelven intactos.
  """
  @spec scaled_spell(Spell.t(), non_neg_integer()) :: Spell.t()
  def scaled_spell(%Spell{} = spell, cast_level) do
    case extra_dice(spell.name, spell.level, cast_level) do
      nil -> spell
      extra -> %{spell | dice: combine_dice(spell.dice, extra)}
    end
  end

  # "NdM±K" + "NdM±K" → "(N+N')dM±(K+K')". La tabla curada garantiza que el
  # dado extra usa las mismas caras que la base (dardos de magic missile: d4;
  # curaciones: d8/d4; daño: el mismo dado del hechizo).
  defp combine_dice(nil, extra), do: extra

  defp combine_dice(base, extra) do
    {n1, sides, k1} = Dice.parse_expr(base)
    {n2, _sides, k2} = Dice.parse_expr(extra)
    "#{n1 + n2}d#{sides}" <> flat(k1 + k2)
  end

  defp flat(0), do: ""
  defp flat(n) when n >= 0, do: "+#{n}"
  defp flat(n), do: "#{n}"

  defp normalize(name) when is_binary(name),
    do: name |> String.downcase() |> String.replace(~r/[\s_-]+/, "")
end
