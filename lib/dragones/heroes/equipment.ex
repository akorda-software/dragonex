defmodule Dragones.Heroes.Equipment do
  @moduledoc """
  SRD 5.1 equipment catalogue: weapons, armour, shields and common gear.

  Every entry is a pure declarative map — no state. The builder turns these into
  `Dragones.Weapon` / `Dragones.Item` structs and computes AC from armour data.

  ## Weapon → attack_ability rules (5e)

    * **Ranged** weapons (bows, crossbows, slings, blowgun, nets): `:dex`,
      `ranged: true` — the Combat layer always uses DEX.
    * **Finesse** melee weapons (dagger, rapier, scimitar, shortsword, whip):
      `:str` with `finesse: true` — Combat picks `max(str, dex)`.
    * **Thrown** weapons that are NOT finesse (javelin, handaxe, spear, light
      hammer, trident): `:str`, `ranged: false` — thrown melee still uses STR.
    * All other melee: `:str`.

  ## Armour → AC rules (5e)

    * **None**: `10 + dex_mod`.
    * **Light** (leather, padded): `base_ac + dex_mod` (full).
    * **Medium** (chain shirt, scale mail, breastplate, half plate):
      `base_ac + min(dex_mod, max_dex)`.
    * **Heavy** (chain mail, ring mail, splint, plate): `base_ac` (no dex).
    * **Shield**: `+2`.
  """

  alias Dragones.Weapon

  @type armor :: %{
          name: String.t(),
          type: :light | :medium | :heavy,
          base_ac: pos_integer(),
          max_dex: non_neg_integer() | :unlimited,
          stealth_disadvantage: boolean()
        }

  # ----------------------------------------------------------------- weapons

  @spec weapon(String.t()) :: Weapon.t() | nil
  def weapon(name) when is_binary(name), do: weapons()[name]

  @doc "All weapons keyed by lowercase name."
  @spec weapons() :: %{String.t() => Weapon.t()}
  def weapons do
    %{
      # --- simple melee ---
      "club" => melee("club", "1d4", "bludgeoning"),
      "dagger" => melee("dagger", "1d4", "piercing", finesse: true),
      "greatclub" => melee("greatclub", "1d8", "bludgeoning", two_handed: true),
      "handaxe" => melee("handaxe", "1d6", "slashing", thrown: true),
      "javelin" => melee("javelin", "1d6", "piercing", thrown: true),
      "light hammer" => melee("light hammer", "1d4", "bludgeoning", thrown: true),
      "mace" => melee("mace", "1d6", "bludgeoning"),
      "quarterstaff" => melee("quarterstaff", "1d6", "bludgeoning", two_handed: true),
      "sickle" => melee("sickle", "1d4", "slashing"),
      "spear" => melee("spear", "1d6", "piercing", thrown: true),
      # --- simple ranged ---
      "light crossbow" => ranged("light crossbow", "1d8", "piercing"),
      "dart" => ranged("dart", "1d4", "piercing"),
      "shortbow" => ranged("shortbow", "1d6", "piercing"),
      "sling" => ranged("sling", "1d4", "bludgeoning"),
      # --- martial melee ---
      "battleaxe" => melee("battleaxe", "1d8", "slashing"),
      "flail" => melee("flail", "1d8", "bludgeoning"),
      "glaive" => melee("glaive", "1d10", "slashing", two_handed: true),
      "greataxe" => melee("greataxe", "1d12", "slashing"),
      "greatsword" => melee("greatsword", "2d6", "slashing", two_handed: true),
      "halberd" => melee("halberd", "1d10", "slashing", two_handed: true),
      "lance" => melee("lance", "1d12", "piercing"),
      "longsword" => melee("longsword", "1d8", "slashing"),
      "maul" => melee("maul", "2d6", "bludgeoning", two_handed: true),
      "morningstar" => melee("morningstar", "1d8", "piercing"),
      "pike" => melee("pike", "1d10", "piercing", two_handed: true),
      "rapier" => melee("rapier", "1d8", "piercing", finesse: true),
      "scimitar" => melee("scimitar", "1d6", "slashing", finesse: true),
      "shortsword" => melee("shortsword", "1d6", "piercing", finesse: true),
      "trident" => melee("trident", "1d6", "piercing", thrown: true),
      "war pick" => melee("war pick", "1d8", "piercing"),
      "warhammer" => melee("warhammer", "1d8", "bludgeoning"),
      "whip" => melee("whip", "1d4", "slashing", finesse: true),
      # --- martial ranged ---
      "hand crossbow" => ranged("hand crossbow", "1d6", "piercing"),
      "heavy crossbow" => ranged("heavy crossbow", "1d10", "piercing"),
      "longbow" => ranged("longbow", "1d8", "piercing"),
      "blowgun" => ranged("blowgun", "1d1", "piercing")
    }
  end

  # Preserves original option list so thrown/finesse/two_handed intent is explicit
  # even though the Weapon struct only carries finesse/ranged.
  defp melee(name, dice, dmg, opts \\ []) do
    %Weapon{
      name: name,
      dice: dice,
      damage_type: dmg,
      attack_ability: :str,
      finesse: Keyword.get(opts, :finesse, false),
      ranged: false
    }
  end

  defp ranged(name, dice, dmg) do
    %Weapon{
      name: name,
      dice: dice,
      damage_type: dmg,
      attack_ability: :dex,
      finesse: false,
      ranged: true
    }
  end

  # ------------------------------------------------------------------- armour

  @spec armor(String.t()) :: armor() | nil
  def armor(name) when is_binary(name), do: armors()[name]

  @doc "All armours keyed by lowercase name."
  @spec armors() :: %{String.t() => armor()}
  def armors do
    %{
      "padded armor" => light("padded armor", 11, true),
      "leather armor" => light("leather armor", 11, false),
      "studded leather armor" => light("studded leather armor", 12, false),
      "hide armor" => medium("hide armor", 12, 2, false),
      "chain shirt" => medium("chain shirt", 13, 2, false),
      "scale mail" => medium("scale mail", 14, 2, true),
      "breastplate" => medium("breastplate", 14, 2, false),
      "half plate" => medium("half plate", 15, 2, true),
      "ring mail" => heavy("ring mail", 14, true),
      "chain mail" => heavy("chain mail", 16, true),
      "splint armor" => heavy("splint armor", 17, true),
      "plate armor" => heavy("plate armor", 18, true)
    }
  end

  defp light(name, ac, stealth?), do: %{name: name, type: :light, base_ac: ac, max_dex: :unlimited, stealth_disadvantage: stealth?}
  defp medium(name, ac, max_dex, stealth?), do: %{name: name, type: :medium, base_ac: ac, max_dex: max_dex, stealth_disadvantage: stealth?}
  defp heavy(name, ac, stealth?), do: %{name: name, type: :heavy, base_ac: ac, max_dex: 0, stealth_disadvantage: stealth?}

  # --------------------------------------------------------- AC computation

  @doc """
  Compute total AC from equipped armour, whether a shield is carried, and the
  DEX modifier.

  Unarmoured (`nil`) defaults to `10 + dex_mod`. Class features like Barbarian
  or Monk Unarmored Defence are handled by the builder, not here.
  """
  @spec compute_ac(armor() | nil, boolean(), integer()) :: non_neg_integer()
  def compute_ac(nil, _shield?, dex_mod), do: 10 + dex_mod

  def compute_ac(%{type: :light, base_ac: ac}, shield?, dex_mod) do
    add_shield(ac + dex_mod, shield?)
  end

  def compute_ac(%{type: :medium, base_ac: ac, max_dex: max}, shield?, dex_mod) do
    add_shield(ac + min(dex_mod, max), shield?)
  end

  def compute_ac(%{type: :heavy, base_ac: ac}, shield?, _dex_mod) do
    add_shield(ac, shield?)
  end

  defp add_shield(ac, true), do: ac + 2
  defp add_shield(ac, _), do: ac
end
