defmodule Dragones.Heroes.Spells do
  @moduledoc """
  SRD 5.1 spell data for level-1 casters (cantrips + 1st-level spells).

  Each entry carries the 5e mechanics the `Dragones.Spell` struct and the combat
  engine need, **except** `casting_ability` — that is set by the builder from
  the class's spellcasting ability, since the same spell can be cast by
  different classes with different abilities.

  `kind` follows `Dragones.Spell`:
    * `:save`      — target rolls a save vs `spell_save_dc`.
    * `:attack`    — caster rolls a spell attack vs AC.
    * `:automatic` — no roll (magic missile, buffs, heals).

  Only combat-relevant spells carry `dice`/`damage_type`; utility spells omit
  them (the combat engine treats nil-dice spells as doing 0 damage).
  """

  @type kind :: :save | :attack | :automatic

  @type ability :: :str | :dex | :con | :int | :wis | :cha

  @type spell_data :: %{
          name: String.t(),
          level: non_neg_integer(),
          kind: kind(),
          save_ability: ability() | nil,
          dice: String.t() | nil,
          damage_type: String.t() | nil,
          effect: String.t() | nil
        }

  @doc "Look up a spell by name (case-insensitive)."
  @spec get(String.t()) :: spell_data() | nil
  def get(name) when is_binary(name) do
    normalized = String.downcase(name)
    Enum.find(all(), &(String.downcase(&1.name) == normalized))
  end

  @doc "All spell data entries."
  @spec all() :: [spell_data()]
  def all do
    # --- cantrips ---
    [
      %{name: "fire bolt", level: 0, kind: :attack, save_ability: nil, dice: "1d10", damage_type: "fire", effect: "A streak of flame to a creature or object."},
      %{name: "ray of frost", level: 0, kind: :attack, save_ability: nil, dice: "1d8", damage_type: "cold", effect: "A frigid beam; target's speed drops 10 ft."},
      %{name: "acid splash", level: 0, kind: :save, save_ability: :dex, dice: "1d6", damage_type: "acid", effect: "A splash of acid at a creature."},
      %{name: "sacred flame", level: 0, kind: :save, save_ability: :dex, dice: "1d8", damage_type: "radiant", effect: "Radiant light; no cover bonus."},
      %{name: "vicious mockery", level: 0, kind: :save, save_ability: :wis, dice: "1d4", damage_type: "psychic", effect: "Target has disadvantage on its next attack."},
      %{name: "produce flame", level: 0, kind: :attack, save_ability: nil, dice: "1d8", damage_type: "fire", effect: "A flickering flame in your palm; can be hurled."},
      %{name: "eldritch blast", level: 0, kind: :attack, save_ability: nil, dice: "1d10", damage_type: "force", effect: "A beam of crackling energy."},
      %{name: "light", level: 0, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "An object shines bright light for 1 hour."},
      %{name: "mage hand", level: 0, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "A spectral hand to manipulate objects."},
      %{name: "prestidigitation", level: 0, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "A minor magical effect."},
      %{name: "druidcraft", level: 0, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "A tiny omen or natural sensory effect."},
      %{name: "guidance", level: 0, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "Target adds 1d4 to one ability check."},
      %{name: "thaumaturgy", level: 0, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "A minor wonder — voice, sound, flame."},
      %{name: "minor illusion", level: 0, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "A sound or image within 30 ft."},
      %{name: "shillelagh", level: 0, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "Your club or quarterstaff uses WIS and deals 1d8."},
      %{name: "dancing lights", level: 0, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "Four torches of light that move at will."},
      %{name: "resistance", level: 0, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "Target subtracts 1d4 from one saving throw."},
      %{name: "spare the dying", level: 0, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "A creature at 0 hp stabilizes."},
      # --- 1st level ---
      %{name: "magic missile", level: 1, kind: :automatic, save_ability: nil, dice: "3d4+3", damage_type: "force", effect: "Three darts of force; each deals 1d4+1 and always hits."},
      %{name: "shield", level: 1, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "Reaction; +5 AC until the start of your next turn."},
      %{name: "mage armor", level: 1, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "Target gains AC 13 + dex for 8 hours."},
      %{name: "burning hands", level: 1, kind: :save, save_ability: :dex, dice: "3d6", damage_type: "fire", effect: "A 15-ft cone of fire."},
      %{name: "thunderwave", level: 1, kind: :save, save_ability: :con, dice: "2d8", damage_type: "thunder", effect: "A wave of force; pushes targets 10 ft on a fail."},
      %{name: "charm person", level: 1, kind: :save, save_ability: :wis, dice: nil, damage_type: nil, effect: "Target regards you as a friendly acquaintance for 1 hour."},
      %{name: "sleep", level: 1, kind: :automatic, save_ability: nil, dice: "5d8", damage_type: nil, effect: "Creatures in an area fall asleep by HP pool."},
      %{name: "detect magic", level: 1, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "Sense the presence of magic within 30 ft."},
      %{name: "cure wounds", level: 1, kind: :automatic, save_ability: nil, dice: "1d8", damage_type: nil, effect: "Restore 1d8 + casting modifier HP to a creature you touch."},
      %{name: "healing word", level: 1, kind: :automatic, save_ability: nil, dice: "1d4", damage_type: nil, effect: "Bonus action; restore 1d4 + casting modifier HP."},
      %{name: "bless", level: 1, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "Up to 3 allies add 1d4 to attack rolls and saves."},
      %{name: "bane", level: 1, kind: :save, save_ability: :cha, dice: nil, damage_type: nil, effect: "Up to 3 foes subtract 1d4 from attacks and saves."},
      %{name: "guiding bolt", level: 1, kind: :attack, save_ability: nil, dice: "4d6", damage_type: "radiant", effect: "Target glows; next attack against it has advantage."},
      %{name: "shield of faith", level: 1, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "Target gains +2 AC for 10 minutes (concentration)."},
      %{name: "sanctuary", level: 1, kind: :save, save_ability: :wis, dice: nil, damage_type: nil, effect: "Foes must save or cannot target the warded creature."},
      %{name: "entangle", level: 1, kind: :save, save_ability: :str, dice: nil, damage_type: nil, effect: "Plants grasp creatures in a 20-ft square; restrained on fail."},
      %{name: "faerie fire", level: 1, kind: :save, save_ability: :dex, dice: nil, damage_type: nil, effect: "Objects glow; attacks vs affected foes have advantage."},
      %{name: "speak with animals", level: 1, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "Comprehend and speak with beasts for 10 minutes."},
      %{name: "heroism", level: 1, kind: :automatic, save_ability: nil, dice: nil, damage_type: nil, effect: "Target is immune to fear and gains temp HP each turn."},
      %{name: "tasha's hideous laughter", level: 1, kind: :save, save_ability: :wis, dice: nil, damage_type: nil, effect: "Target falls prone, incapacitated with laughter."},
      %{name: "hex", level: 1, kind: :save, save_ability: :con, dice: "1d6", damage_type: "necrotic", effect: "Target takes extra 1d6 necrotic when you hit it; disadvantage on a chosen ability."},
      %{name: "hellish rebuke", level: 1, kind: :save, save_ability: :dex, dice: "2d10", damage_type: "fire", effect: "Reaction; searing flames punish a nearby foe."},
      %{name: "witch bolt", level: 1, kind: :attack, save_ability: nil, dice: "1d12", damage_type: "lightning", effect: "A beam of lightning; can deal 1d12 each turn while concentrated."},
      %{name: "chromatic orb", level: 1, kind: :attack, save_ability: nil, dice: "3d8", damage_type: "acid", effect: "An orb of energy; choose acid/cold/fire/lightning/poison/thunder."}
    ]
  end
end
